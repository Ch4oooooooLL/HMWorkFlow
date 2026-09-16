"""Standalone FEM-only seam detection and realization backend.

This module deliberately has no HyperMesh or UI dependency.  It detects:

* open T seams, including curved paths, partial overlap and multiple targets;
* closed patch seams for a smaller parallel shell contained by a larger shell;
* nearby free-edge pairs as review-only candidates.

Auto-eligible T/patch candidates are realized by a local multi-element shell
split followed by a shell zipper.  The result can be written as a complete,
round-trippable OptiStruct FEM bundle for algorithm validation.
"""
from __future__ import annotations

import json
import math
import multiprocessing
import os
import re
import sys
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

try:
    from hmworkflow.core.mesh_model import Component, Element, MeshModel
except ImportError:
    from mesh_model import Component, Element, MeshModel

try:
    from hmworkflow.mesh_seam_weld.element_projection import angle_degrees, cross, dot, norm, unit
    from hmworkflow.mesh_seam_weld.local_split_planner import _plane, _project, _triangulate
    from .multi_element_split_planner import plan_multi_element_split
    from .recognition_v2 import build_physical_geometry_context, detect_t_candidates as detect_t_candidates_v2, enrich_non_t_candidate, mesh_continuous
    from hmworkflow.mesh_seam_weld.quality_guard import element_metrics, validate_strip_connectivity, validate_weld_elements
    from hmworkflow.mesh_seam_weld.shell_topology import build as build_topology
    from hmworkflow.mesh_seam_weld.weld_strip_planner import plan_zipper
except ImportError:
    from element_projection import angle_degrees, cross, dot, norm, unit
    from local_split_planner import _plane, _project, _triangulate
    from multi_element_split_planner import plan_multi_element_split
    from recognition_v2 import build_physical_geometry_context, detect_t_candidates as detect_t_candidates_v2, enrich_non_t_candidate, mesh_continuous
    from quality_guard import element_metrics, validate_strip_connectivity, validate_weld_elements
    from shell_topology import build as build_topology
    from weld_strip_planner import plan_zipper

try:
    from shell_weld_detection import build_component_topology, connected_edge_paths, find_candidate_component_pairs
except ImportError:
    from hmworkflow.hybrid_core.shell_weld_detection import build_component_topology, connected_edge_paths, find_candidate_component_pairs


DEFAULT_SETTINGS = {
    "search_distance": 10.0,
    "potential_search_multiplier": 1.25,
    "potential_angle_margin": 10.0,
    "potential_length_ratio": 0.75,
    "minimum_t_length": 15.0,
    "minimum_patch_length": 15.0,
    "minimum_t_normal_angle": 70.0,
    "maximum_patch_normal_angle": 15.0,
    "maximum_distance_variation_ratio": 0.35,
    "ray_tolerance": 1.0e-7,
    "near_edge_distance": 8.0,
    "near_edge_tangent_angle": 20.0,
    "small_hole_diameter": 30.0,
    "maximum_split_aspect_ratio": 100.0,
    "maximum_weld_aspect_ratio": 100.0,
    "maximum_weld_triangle_ratio": 0.75,
    "python_workers": 0,
    "include_legacy_near_edges": False,
    # V2 recognition gates.  They remain request-overridable and are kept in
    # one settings table so geometry code contains no decision magic numbers.
    "boundary_split_turn_angle_deg": 30.0,
    "boundary_split_source_normal_change_deg": 45.0,
    "t_angle_auto_min_deg": 70.0,
    "t_angle_auto_max_deg": 100.0,
    "t_angle_review_min_deg": 65.0,
    "t_angle_review_max_deg": 115.0,
    "t_coverage_auto": 0.98,
    "geometry_abs_floor_mm": 0.5,
    "geometry_mesh_ratio_auto": 0.35,
    "geometry_thickness_ratio_auto": 0.15,
    "geometry_review_multiplier": 3.0,
    "t_tangential_tolerance_ratio": 0.10,
    "t_bevel_clearance_mm": 2.0,
    "t_bevel_source_thickness_ratio": 0.50,
    "t_bevel_mesh_ratio": 0.25,
    "t_target_min_support_ratio": 0.12,
    "t_edge_review_coverage": 0.67,
    # Candidate recall accepts generalized T intersections and excludes only
    # near-coplanar faces (handled by PATCH).  The reported angle remains
    # diagnostic, while Tcl/Create Patch decides realizability.
    "t_recall_angle_min_deg": 20.0,
    "t_recall_angle_max_deg": 90.0,
    "t_recall_distance_multiplier": 3.0,
    "t_recall_tangential_mesh_ratio": 1.0,
    "t_recall_edge_review_coverage": 0.01,
    # Supplementary relaxed rows (a chain the strict pass missed on a source
    # component which already owns strict rows) must clear this sample
    # coverage, so a chain that merely brushes a face at one end stays out.
    "t_recall_min_coverage": 0.5,
    # Components which already share GRID nodes are one continuous mesh; the
    # FEM transfers load there, so no weld seam is missing.
    "ignore_shared_nodes": True,
    "min_continuous_nodes": 3,
    "patch_review_min_coverage": 0.25,
    "ambiguity_auto_min_score_margin": 0.40,
    "ambiguity_sample_ratio": 0.25,
    "curved_target_auto_max_normal_variation_deg": 12.0,
    "target_normal_jump_auto_max_deg": 30.0,
    "projection_jump_ratio": 2.5,
    "small_gap_auto_length_over_h": 0.25,
    # A patch opening larger than ``small_hole_diameter`` is a genuine exposed
    # patch boundary and is welded together with the outer perimeter.  Smaller
    # fastener openings are filtered before rows are built, so they neither
    # create welds nor veto an otherwise valid patch.
    "patch_inner_loop_policy": "auto_all",
    "review_multi_target_realization": False,
    "t_recall_first_mode": True,
    # Broaden delivery within the supported geometry envelope.  Coverage,
    # ambiguity, topology and duplicate safety gates remain mandatory.
    "submit_all_weld_candidates": True,
}


_DETECTION_CONTEXT = {}


class _AabbGrid:
    """Conservative uniform-grid broad phase for shell elements and edges."""

    def __init__(self, rows, cell_size, maximum_cells_per_row=256):
        self.cell_size = max(float(cell_size), 1.0e-9)
        self.rows = {int(row_id): value for row_id, _, value in rows}
        self.bounds_by_id = {int(row_id): bounds for row_id, bounds, _ in rows}
        self.triangles = {}
        self.cells = defaultdict(list)
        self.overflow = []
        for row_id, bounds, _ in rows:
            lower = self._key((bounds[0], bounds[2], bounds[4]))
            upper = self._key((bounds[1], bounds[3], bounds[5]))
            cell_count = (upper[0] - lower[0] + 1) * (upper[1] - lower[1] + 1) * (upper[2] - lower[2] + 1)
            if cell_count > int(maximum_cells_per_row):
                # A malformed or vehicle-spanning shell must not allocate
                # millions of Python lists. Keep it in a conservative overflow
                # bucket that participates in every exact query instead.
                self.overflow.append(int(row_id))
                continue
            for ix in range(lower[0], upper[0] + 1):
                for iy in range(lower[1], upper[1] + 1):
                    for iz in range(lower[2], upper[2] + 1):
                        self.cells[(ix, iy, iz)].append(int(row_id))

    def _key(self, point):
        return tuple(int(math.floor(float(value) / self.cell_size)) for value in point)

    def query_bounds(self, bounds):
        lower = self._key((bounds[0], bounds[2], bounds[4]))
        upper = self._key((bounds[1], bounds[3], bounds[5]))
        matches = set(self.overflow)
        for ix in range(lower[0], upper[0] + 1):
            for iy in range(lower[1], upper[1] + 1):
                for iz in range(lower[2], upper[2] + 1):
                    matches.update(self.cells.get((ix, iy, iz), ()))
        return [self.rows[row_id] for row_id in sorted(matches)]


def _bounds_for_points(points):
    return (
        min(point[0] for point in points), max(point[0] for point in points),
        min(point[1] for point in points), max(point[1] for point in points),
        min(point[2] for point in points), max(point[2] for point in points),
    )


def _bounds_overlap(first, second, maximum):
    return all(
        first[axis * 2] - maximum <= second[axis * 2 + 1]
        and second[axis * 2] - maximum <= first[axis * 2 + 1]
        for axis in range(3)
    )


def _bounds_within(inner, outer, maximum):
    """True when ``inner`` can project onto ``outer`` within ``maximum``."""
    return all(
        outer[axis * 2] - maximum <= inner[axis * 2]
        and inner[axis * 2 + 1] <= outer[axis * 2 + 1] + maximum
        for axis in range(3)
    )


def _bounds_diagonal(bounds):
    return math.sqrt(
        (bounds[1] - bounds[0]) ** 2 +
        (bounds[3] - bounds[2]) ** 2 +
        (bounds[5] - bounds[4]) ** 2
    )


def _detection_context(model, topologies, maximum):
    """Shared lazy per-component caches for one detection pass.

    Every expensive derived structure (element lists, AABB grids, average
    normals, areas, closed free-edge loops) is built on first use so a worker
    task only pays for the components its sources actually touch.
    """
    return {
        "model": model,
        "topologies": topologies,
        "maximum": float(maximum),
        "elements": {},
        "elements_by_id": {},
        "element_indexes": {},
        "normals": {},
        "areas": {},
        "closed_loops": {},
        "edge_owners": {},
        "physical_geometry": None,
    }


def _context_elements(shared, component_id):
    elements = shared["elements"].get(component_id)
    if elements is None:
        elements = sorted(shared["model"].elements_for_components([component_id]), key=lambda row: row.element_id)
        shared["elements"][component_id] = elements
    return elements


def _context_element_map(shared, component_id):
    mapping = shared["elements_by_id"].get(component_id)
    if mapping is None:
        mapping = {element.element_id: element for element in _context_elements(shared, component_id)}
        shared["elements_by_id"][component_id] = mapping
    return mapping


def _context_index(shared, component_id):
    index = shared["element_indexes"].get(component_id)
    if index is None:
        elements = _context_elements(shared, component_id)
        index = False
        if elements:
            nodes = shared["model"].nodes
            rows = []
            all_points = []
            if shared["physical_geometry"] is None:
                _, shared["physical_geometry"] = build_physical_geometry_context(shared["model"], shared["topologies"])
            physical_facets = shared["physical_geometry"]["facets"].get(component_id, [])
            facets_by_element = defaultdict(list)
            for facet in physical_facets:
                facets_by_element[int(facet["element_id"])].append(facet)
            for element in elements:
                element_facets = facets_by_element.get(element.element_id, [])
                points = [point for facet in element_facets for point in facet["points"]]
                if not points:
                    points = [nodes[node_id] for node_id in element.node_ids]
                all_points.extend(points)
                rows.append((element.element_id, _bounds_for_points(points), element))
            bounds = _bounds_for_points(all_points)
            diagonal = math.sqrt(
                (bounds[1] - bounds[0]) ** 2 +
                (bounds[3] - bounds[2]) ** 2 +
                (bounds[5] - bounds[4]) ** 2
            )
            # Per-component grids keep long shell components from collapsing
            # into one near-global bucket while avoiding millions of cells.
            cell_size = max(shared["maximum"], diagonal / max(math.sqrt(len(elements)), 1.0), 1.0e-6)
            index = _AabbGrid(rows, cell_size)
            index.triangles = {}
            for element in elements:
                element_facets = facets_by_element.get(element.element_id, [])
                if not element_facets:
                    index.triangles[element.element_id] = _element_triangles(element, nodes)
                    continue
                cached = []
                for facet in element_facets:
                    a, second, third = facet["points"]
                    edge1, edge2 = _sub(second, a), _sub(third, a)
                    normal = cross(edge1, edge2)
                    d00, d01, d11 = dot(edge1, edge1), dot(edge1, edge2), dot(edge2, edge2)
                    cached.append((a, edge1, edge2, normal, d00, d01, d11, d00 * d11 - d01 * d01))
                index.triangles[element.element_id] = tuple(cached)
        shared["element_indexes"][component_id] = index
    return index or None


def _context_normal(shared, component_id):
    normal = shared["normals"].get(component_id)
    if normal is None:
        normal = _component_normal(_context_elements(shared, component_id), shared["model"].nodes)
        shared["normals"][component_id] = normal
    return normal


def _context_area(shared, component_id):
    area = shared["areas"].get(component_id)
    if area is None:
        area = _component_area(_context_elements(shared, component_id), shared["model"].nodes)
        shared["areas"][component_id] = area
    return area


def _context_edge_owners(shared, component_id):
    owners = shared["edge_owners"].get(component_id)
    if owners is None:
        owners = {
            tuple(sorted((first, second))): owner_id
            for first, second, owner_id in shared["topologies"][component_id].free_edges
        }
        shared["edge_owners"][component_id] = owners
    return owners


def _context_closed_loops(shared, component_id):
    """Outer closed free-edge loops of one component plus their interior holes."""
    entry = shared["closed_loops"].get(component_id)
    if entry is None:
        model = shared["model"]
        topology = shared["topologies"][component_id]
        paths = connected_edge_paths(topology.free_edges, model.nodes)
        closed = [path for path in paths if path["closed"] and not path["branched"]]
        normal = _context_normal(shared, component_id)
        if normal is None:
            outers, holes = list(closed), {}
        else:
            outers, holes = _classify_closed_loops(closed, model.nodes, normal)
        entry = [
            {
                "path": path,
                "holes": holes.get(id(path), []),
                "bounds": _bounds_for_points([model.nodes[node_id] for node_id in path["node_ids"]]),
            }
            for path in outers
        ]
        shared["closed_loops"][component_id] = entry
    return entry


def _context_weld_loops(shared, component_id):
    """Every weldable closed free-edge loop: outer loops and their holes.

    A hole in a patch is still a free edge lying on the target - the base is
    exposed through the opening and the patch edge around it is a real weld
    seam.  Hole loops therefore participate in patch detection like any other
    loop; only fastener-sized openings below the automatic hole diameter are
    skipped (by the caller).
    """
    model = shared["model"]
    loops = []
    for entry in _context_closed_loops(shared, component_id):
        entry["path"]["boundary_class"] = "OUTER"
        loops.append(entry)
        for hole in entry["holes"]:
            hole["boundary_class"] = "INNER"
            loops.append({
                "path": hole,
                "holes": [],
                "bounds": _bounds_for_points([model.nodes[node_id] for node_id in hole["node_ids"]]),
                "is_hole": True,
            })
    return loops


def _component_edge_indexes(topologies, nodes, maximum):
    indexes = {}
    for component_id, topology in topologies.items():
        rows = []
        for edge_id, edge in enumerate(topology.free_edges):
            first, second, _ = edge
            rows.append((edge_id, _bounds_for_points((nodes[first], nodes[second])), edge))
        if rows:
            bounds = topology.bounds
            diagonal = math.sqrt(
                (bounds[1] - bounds[0]) ** 2 +
                (bounds[3] - bounds[2]) ** 2 +
                (bounds[5] - bounds[4]) ** 2
            )
            cell_size = max(float(maximum), diagonal / max(math.sqrt(len(rows)), 1.0), 1.0e-6)
            indexes[component_id] = _AabbGrid(rows, cell_size)
    return indexes


def _sub(a, b):
    return tuple(a[index] - b[index] for index in range(3))


def _add(a, b):
    return tuple(a[index] + b[index] for index in range(3))


def _scale(a, value):
    return tuple(a[index] * value for index in range(3))


def _distance(a, b):
    return norm(_sub(a, b))


def _midpoint(a, b):
    return tuple((a[index] + b[index]) * 0.5 for index in range(3))


def _element_normal(element, nodes):
    ids = element.node_ids
    return unit(cross(_sub(nodes[ids[1]], nodes[ids[0]]), _sub(nodes[ids[2]], nodes[ids[0]])))


def _element_area(element, nodes):
    ids = element.node_ids
    first = 0.5 * norm(cross(_sub(nodes[ids[1]], nodes[ids[0]]), _sub(nodes[ids[2]], nodes[ids[0]])))
    if len(ids) == 3:
        return first
    return first + 0.5 * norm(cross(_sub(nodes[ids[2]], nodes[ids[0]]), _sub(nodes[ids[3]], nodes[ids[0]])))


def _element_triangles(element, nodes):
    """Precompute constant triangle data for one shell element.

    Each row carries the first vertex, both edge vectors, the geometric
    normal, and the barycentric determinant so per-ray tests skip every
    cross-product and dot-product that does not depend on the ray.
    """
    ids = element.node_ids
    triangles = (ids,) if len(ids) == 3 else ((ids[0], ids[1], ids[2]), (ids[0], ids[2], ids[3]))
    rows = []
    for triangle in triangles:
        a = nodes[triangle[0]]
        edge1 = _sub(nodes[triangle[1]], a)
        edge2 = _sub(nodes[triangle[2]], a)
        normal = cross(edge1, edge2)
        d00, d01, d11 = dot(edge1, edge1), dot(edge1, edge2), dot(edge2, edge2)
        rows.append((a, edge1, edge2, normal, d00, d01, d11, d00 * d11 - d01 * d01))
    return tuple(rows)


def _triangle_hit(point, direction, cached, maximum, tolerance):
    a, edge1, edge2, normal, d00, d01, d11, determinant = cached
    denominator = dot(normal, direction)
    if abs(denominator) <= tolerance:
        return None
    ray_parameter = dot(normal, _sub(a, point)) / denominator
    if ray_parameter < -tolerance or ray_parameter > maximum + tolerance:
        return None
    hit = _add(point, _scale(direction, ray_parameter))
    v2 = _sub(hit, a)
    u = 1.0 - (d11 * dot(v2, edge1) - d01 * dot(v2, edge2)) / determinant - (d00 * dot(v2, edge2) - d01 * dot(v2, edge1)) / determinant
    v = (d11 * dot(v2, edge1) - d01 * dot(v2, edge2)) / determinant
    if min(u, v) < -tolerance or u + v > 1.0 + tolerance:
        return None
    return {"point": hit, "distance": max(0.0, ray_parameter)}


def _ray_hit_element(point, direction, element, nodes, maximum, tolerance, triangles=None):
    if triangles is None:
        triangles = _element_triangles(element, nodes)
    hits = []
    for cached in triangles:
        hit = _triangle_hit(point, direction, cached, maximum, tolerance)
        if hit is not None:
            hits.append(hit)
    return min(hits, key=lambda row: row["distance"]) if hits else None


def _ray_hits_component(point, direction, elements, nodes, maximum, tolerance, element_index=None):
    if element_index is not None:
        endpoint = _add(point, _scale(direction, maximum))
        padding = max(float(tolerance), element_index.cell_size * float(tolerance) * 4.0, 1.0e-9)
        px, py, pz = point
        ex, ey, ez = endpoint
        query_bounds = (
            (px if px < ex else ex) - padding, (px if px > ex else ex) + padding,
            (py if py < ey else ey) - padding, (py if py > ey else ey) + padding,
            (pz if pz < ez else ez) - padding, (pz if pz > ez else ez) + padding,
        )
        elements = element_index.query_bounds(query_bounds)
        segment = query_bounds
    else:
        segment = None
    hits = []
    for element in elements:
        if segment is not None:
            bounds = element_index.bounds_by_id.get(element.element_id)
            if bounds is not None and (
                bounds[0] > segment[1] or bounds[1] < segment[0] or
                bounds[2] > segment[3] or bounds[3] < segment[2] or
                bounds[4] > segment[5] or bounds[5] < segment[4]
            ):
                continue
        hit = _ray_hit_element(
            point, direction, element, nodes, maximum, tolerance,
            element_index.triangles.get(element.element_id) if element_index is not None else None,
        )
        if hit is not None:
            hit = dict(hit)
            hit["element_id"] = element.element_id
            hits.append(hit)
    return min(hits, key=lambda row: (row["distance"], row["element_id"])) if hits else None


def _component_normal(elements, nodes):
    normals = []
    for element in elements:
        try:
            normals.append(_element_normal(element, nodes))
        except ValueError:
            continue
    if not normals:
        return None
    reference = normals[0]
    aligned = [tuple(-value for value in normal) if dot(normal, reference) < 0.0 else normal for normal in normals]
    average = tuple(sum(normal[index] for normal in aligned) / len(aligned) for index in range(3))
    try:
        return unit(average)
    except ValueError:
        return None


def _edge_outward_direction(edge, owner, nodes):
    first, second = edge
    tangent = unit(_sub(nodes[second], nodes[first]))
    normal = _element_normal(owner, nodes)
    direction = unit(cross(tangent, normal))
    midpoint = _midpoint(nodes[first], nodes[second])
    centroid = tuple(sum(nodes[node_id][axis] for node_id in owner.node_ids) / len(owner.node_ids) for axis in range(3))
    if dot(_sub(centroid, midpoint), direction) > 0.0:
        direction = tuple(-value for value in direction)
    return direction, normal


def _path_length(node_ids, nodes, closed=False):
    pairs = list(zip(node_ids, node_ids[1:]))
    if closed:
        pairs.append((node_ids[-1], node_ids[0]))
    return sum(_distance(nodes[first], nodes[second]) for first, second in pairs)


def _candidate_confidence(coverage, distance_variation, angle_score, continuity=1.0):
    distance_score = max(0.0, 1.0 - distance_variation)
    return round(min(0.99, 0.30 + 0.30 * coverage + 0.15 * distance_score + 0.15 * angle_score + 0.10 * continuity), 6)


def _edge_hit_intervals(first, second, direction, target_elements, nodes, maximum, tolerance, element_index=None, samples=17):
    memo = {}

    def hit_at(parameter):
        if parameter in memo:
            return memo[parameter]
        point = _add(nodes[first], _scale(_sub(nodes[second], nodes[first]), parameter))
        hit = _ray_hits_component(point, direction, target_elements, nodes, maximum, tolerance, element_index)
        memo[parameter] = hit
        return hit

    parameters = [index / float(samples - 1) for index in range(samples)]
    hits = [hit_at(parameter) for parameter in parameters]

    def transition(false_parameter, true_parameter):
        low, high = false_parameter, true_parameter
        false_on_low = hit_at(low) is None
        for _ in range(36):
            middle = (low + high) * 0.5
            middle_false = hit_at(middle) is None
            if middle_false == false_on_low:
                low = middle
            else:
                high = middle
        boundary = high if false_on_low else low
        return boundary, hit_at(boundary)

    intervals = []
    index = 0
    while index < len(parameters):
        if hits[index] is None:
            index += 1
            continue
        run_start = index
        while index + 1 < len(parameters) and hits[index + 1] is not None:
            index += 1
        run_end = index
        if run_start == 0:
            start_parameter, start_hit = parameters[run_start], hits[run_start]
        else:
            start_parameter, start_hit = transition(parameters[run_start - 1], parameters[run_start])
        if run_end == len(parameters) - 1:
            end_parameter, end_hit = parameters[run_end], hits[run_end]
        else:
            end_parameter, end_hit = transition(parameters[run_end], parameters[run_end + 1])
        if end_parameter - start_parameter > tolerance and start_hit is not None and end_hit is not None:
            intervals.append({"start": start_parameter, "end": end_parameter, "start_hit": start_hit, "end_hit": end_hit})
        index += 1
    return intervals, hit_at


def _nearest_edge_band(strict_maximum, tolerance):
    # Edges whose hit distance ties the group minimum within this band count
    # as the "nearest" edge row of the face (e.g. the whole bottom edge row of
    # a web standing on a base plate).
    return max(float(tolerance), 0.1 * float(strict_maximum))


def _nearest_edge_intervals(group, contexts, band):
    """Whole-edge hit intervals of the group's nearest edge row, sorted."""
    distances = []
    for interval in group["intervals"]:
        for boundary_hit in (interval["start_hit"], interval["end_hit"]):
            if boundary_hit is not None:
                distances.append(boundary_hit["distance"])
    if not distances:
        return []
    minimum = min(distances)
    nearest = []
    for interval in group["intervals"]:
        complete = (
            abs(interval["start"] - round(interval["start"])) <= 2.0e-6
            and abs(interval["end"] - round(interval["end"])) <= 2.0e-6
        )
        if not complete:
            continue
        boundary_distances = [
            boundary_hit["distance"]
            for boundary_hit in (interval["start_hit"], interval["end_hit"])
            if boundary_hit is not None
        ]
        if boundary_distances and min(boundary_distances) <= minimum + band:
            nearest.append(interval)
    return sorted(nearest, key=lambda row: (row["start"], row["end"]))


def _contiguous_interval_runs(intervals):
    runs = []
    for interval in intervals:
        if runs and interval["start"] <= runs[-1]["end"] + 2.0e-6:
            runs[-1]["end"] = max(runs[-1]["end"], interval["end"])
            runs[-1]["intervals"].append(interval)
        else:
            runs.append({"start": interval["start"], "end": interval["end"], "intervals": [interval]})
    return runs


def _face_fully_on_target(model, adjacent_element_ids, element_map, target_elements, target_normal, maximum, tolerance, target_index):
    """True when every sample of the source face projects onto the target.

    The face is the region bounded by the source free-edge path: all nodes and
    element centroids of the path-adjacent source shells must reach the target
    along the target normal within the search distance.  The sample budget
    scales with the face itself so a large girder web is not rejected by a
    fixed point cap that small fixtures never reach.
    """
    nodes = model.nodes
    points = []
    seen_nodes = set()
    point_limit = max(2500, 6 * len(adjacent_element_ids))
    for element_id in adjacent_element_ids:
        element = element_map.get(element_id)
        if element is None:
            continue
        for node_id in element.node_ids:
            if node_id not in seen_nodes:
                seen_nodes.add(node_id)
                points.append(nodes[node_id])
        points.append(tuple(sum(nodes[node_id][axis] for node_id in element.node_ids) / len(element.node_ids) for axis in range(3)))
        if len(points) > point_limit:
            return False
    if not points:
        return False
    for point in points:
        if _bidirectional_hit(point, target_normal, target_elements, nodes, maximum, tolerance, target_index) is None:
            return False
    return True


def _strict_failure_warnings(complete_edges, length, minimum_length, variation, maximum_variation, angle, strict_minimum_angle, distances, strict_maximum, tolerance):
    """Name the exact trusted gates a demoted T relation failed, so review
    logs show why the relation was not automatic."""
    warnings = []
    if not complete_edges:
        warnings.append("T relation covers only part of a source free edge")
    if length < minimum_length:
        warnings.append("T relation length {:.3g} is below the minimum {:.3g}".format(length, minimum_length))
    if variation > maximum_variation:
        warnings.append("T hit distance variation {:.3g} exceeds the maximum {:.3g}".format(variation, maximum_variation))
    if angle < strict_minimum_angle:
        warnings.append("T normal angle {:.3g} deg is below the minimum {:.3g}".format(angle, strict_minimum_angle))
    if max(distances) > strict_maximum + tolerance:
        warnings.append("T hit distance {:.3g} exceeds the search distance {:.3g}".format(max(distances), strict_maximum))
    return warnings or ["T relation is outside a trusted tolerance gate"]


def _t_candidate_row(source_id, target_id, source_path, target_points, distances, target_elements_used, involved_edges, length, angle, variation, coverage, complete_edges, auto_eligible, trusted_reason=False, warnings=None):
    return {
        "candidate_id": "",
        "candidate_type": "T_SEAM",
        "source_component_id": source_id,
        "target_component_id": target_id,
        "source_path": source_path,
        "source_node_ids": [row["node_id"] for row in source_path],
        "source_edge_pairs": involved_edges,
        "target_hint_element_ids": sorted(target_elements_used),
        "target_projection_points": target_points,
        "closed": False,
        "length": round(length, 9),
        "confidence": _candidate_confidence(1.0, variation, min(1.0, angle / 90.0)),
        "projection_coverage": round(coverage, 6),
        "complete_source_edges": bool(complete_edges),
        "auto_eligible": bool(auto_eligible),
        "recognition_status": "TRUSTED" if auto_eligible else "POTENTIAL",
        "status": "AUTO_READY" if auto_eligible else "REVIEW_REQUIRED",
        "distance": {"minimum": min(distances), "average": sum(distances) / len(distances), "maximum": max(distances)},
        "normal_angle": round(angle, 6),
        "reasons": (
            ["nearest edge row of a source face fully falling on the target projects completely onto the target"]
            if trusted_reason
            else ["source free-edge extension intersects a continuous target shell region"]
        ),
        "warnings": warnings if warnings is not None else ([] if auto_eligible else ["T relation is partial, ambiguous, or outside a trusted tolerance gate"]),
    }


def _t_candidates(model, settings, topologies, source_ids=None, shared=None):
    strict_maximum = float(settings["search_distance"])
    maximum = strict_maximum * float(settings.get("potential_search_multiplier", 1.25))
    tolerance = float(settings["ray_tolerance"])
    strict_minimum_angle = float(settings["minimum_t_normal_angle"])
    minimum_angle = max(
        0.0,
        strict_minimum_angle - float(settings.get("potential_angle_margin", 10.0)),
    )
    minimum_length = float(settings["minimum_t_length"])
    potential_length_ratio = float(settings.get("potential_length_ratio", 0.75))
    maximum_variation = float(settings["maximum_distance_variation_ratio"])
    nearest_band = _nearest_edge_band(strict_maximum, tolerance)
    if shared is None:
        shared = _detection_context(model, topologies, maximum)
    nodes = model.nodes
    rows = []
    for source_id in sorted(topologies):
        if source_ids is not None and source_id not in source_ids:
            continue
        source_topology = topologies[source_id]
        element_map = _context_element_map(shared, source_id)
        source_paths = connected_edge_paths(source_topology.free_edges, nodes)
        # Outward edge geometry is computed once per source component; the
        # swept bounds double as a broad-phase filter per candidate target.
        edge_geometry = {}
        for first, second, owner_id in source_topology.free_edges:
            key = (first, second)
            if key in edge_geometry:
                continue
            owner = element_map.get(owner_id)
            if owner is None:
                continue
            try:
                direction, source_normal = _edge_outward_direction((first, second), owner, nodes)
            except ValueError:
                continue
            swept = _bounds_for_points((
                nodes[first], nodes[second],
                _add(nodes[first], _scale(direction, maximum)),
                _add(nodes[second], _scale(direction, maximum)),
            ))
            edge_geometry[key] = (direction, source_normal, swept)
        if not edge_geometry:
            continue
        # Component bounds are a conservative superset of any edge sweep; each
        # pair is still element-filtered by the swept-bounds query below.
        neighbor_ids = [
            target_id for target_id in sorted(topologies)
            if target_id != source_id and _bounds_overlap(source_topology.bounds, topologies[target_id].bounds, maximum)
        ]
        # The face-fall-on check proves the whole source face projects onto the
        # target footprint, so its ray range must cover the face's full
        # standoff; the weld search distance alone would reject any web taller
        # than that distance even when it stands squarely on the target.
        face_maximum = maximum + _bounds_diagonal(source_topology.bounds)
        for target_id in neighbor_ids:
            target_normal = _context_normal(shared, target_id)
            if target_normal is None:
                continue
            target_elements = _context_elements(shared, target_id)
            target_index = _context_index(shared, target_id)
            index_padding = 0.0
            if target_index is not None:
                index_padding = max(tolerance, target_index.cell_size * tolerance * 4.0, 1.0e-9)
            for boundary in source_paths:
                if boundary["branched"]:
                    continue
                path_nodes = boundary["node_ids"]
                path_pairs = list(zip(path_nodes, path_nodes[1:]))
                if boundary["closed"]:
                    path_pairs.append((path_nodes[-1], path_nodes[0]))
                intervals = []
                edge_contexts = {}
                for edge_index, (first, second) in enumerate(path_pairs):
                    key = (first, second) if first < second else (second, first)
                    geometry = edge_geometry.get(key)
                    if geometry is None:
                        continue
                    direction, source_normal, swept = geometry
                    normal_angle = angle_degrees(source_normal, target_normal)
                    if normal_angle < minimum_angle:
                        continue
                    if target_index is not None:
                        # Skip every ray sample when the edge sweep cannot reach
                        # this target's elements at all.
                        near = target_index.query_bounds((
                            swept[0] - index_padding, swept[1] + index_padding,
                            swept[2] - index_padding, swept[3] + index_padding,
                            swept[4] - index_padding, swept[5] + index_padding,
                        ))
                        if not near:
                            continue
                    edge_intervals, hit_at = _edge_hit_intervals(
                        first, second, direction, target_elements, nodes,
                        maximum, tolerance, target_index,
                    )
                    edge_contexts[edge_index] = {"first": first, "second": second, "hit_at": hit_at, "angle": normal_angle}
                    for interval in edge_intervals:
                        row = dict(interval)
                        row.update({"start": edge_index + interval["start"], "end": edge_index + interval["end"], "edge_index": edge_index})
                        intervals.append(row)
                if not intervals:
                    continue
                intervals.sort(key=lambda row: (row["start"], row["end"]))
                groups = _contiguous_interval_runs(intervals)
                path_limit = float(len(path_pairs))
                if boundary["closed"] and len(groups) > 1 and groups[0]["start"] <= 2.0e-6 and groups[-1]["end"] >= path_limit - 2.0e-6:
                    wrapped = {"start": groups[-1]["start"], "end": groups[0]["end"] + path_limit, "intervals": groups[-1]["intervals"] + groups[0]["intervals"]}
                    groups = [wrapped] + groups[1:-1]

                def source_point(parameter):
                    normalized = parameter % path_limit if boundary["closed"] else min(parameter, path_limit)
                    if not boundary["closed"] and normalized >= path_limit:
                        return nodes[path_nodes[-1]], path_nodes[-1], len(path_pairs) - 1, 1.0
                    edge_index = min(int(math.floor(normalized)), len(path_pairs) - 1)
                    local = normalized - edge_index
                    first, second = path_pairs[edge_index]
                    point = _add(nodes[first], _scale(_sub(nodes[second], nodes[first]), local))
                    node_id = first if local <= 2.0e-6 else (second if 1.0 - local <= 2.0e-6 else 0)
                    return point, node_id, edge_index, local

                def assemble(values):
                    source_path = []
                    target_points = []
                    distances = []
                    target_elements_used = set()
                    for value in values:
                        point, node_id, edge_index, local = source_point(value)
                        edge_context = edge_contexts.get(edge_index)
                        hit = edge_context["hit_at"](local) if edge_context is not None else None
                        if hit is None and local <= 2.0e-6:
                            previous = (edge_index - 1) % len(path_pairs)
                            previous_context = edge_contexts.get(previous)
                            hit = previous_context["hit_at"](1.0) if previous_context is not None else None
                        if hit is None:
                            return None
                        source_path.append({"node_id": node_id, "coordinates": list(point)})
                        target_points.append(list(hit["point"]))
                        distances.append(hit["distance"])
                        target_elements_used.add(hit["element_id"])
                    if len(source_path) < 2:
                        return None
                    return source_path, target_points, distances, target_elements_used

                def edge_angles(values):
                    indices = {source_point(value)[2] for value in values}
                    angles = [edge_contexts[index]["angle"] for index in indices if index in edge_contexts]
                    return sum(angles) / len(angles) if angles else minimum_angle

                def involved_edge_pairs(interval_rows):
                    return [
                        [edge_contexts[interval["edge_index"]]["first"], edge_contexts[interval["edge_index"]]["second"]]
                        for interval in interval_rows
                    ]

                for group in groups:
                    values = [group["start"]]
                    values.extend(float(value) for value in range(int(math.floor(group["start"])) + 1, int(math.ceil(group["end"]))) if group["start"] + 2.0e-6 < value < group["end"] - 2.0e-6)
                    values.append(group["end"])
                    assembled = assemble(values)
                    if assembled is None:
                        continue
                    source_path, target_points, distances, target_elements_used = assembled
                    length = sum(_distance(tuple(source_path[index]["coordinates"]), tuple(source_path[index + 1]["coordinates"])) for index in range(len(source_path) - 1))
                    if length < minimum_length * potential_length_ratio:
                        continue
                    average = sum(distances) / len(distances)
                    variation = (max(distances) - min(distances)) / max(average, 1.0e-9)
                    angle = edge_angles(values)
                    # A trusted T seed must represent one or more complete
                    # source free edges.  A clipped interval is deliberately
                    # retained as a potential relation, but must never be sent
                    # to the automatic mesh-weld executor.
                    complete_edges = all(
                        abs(interval["start"] - round(interval["start"])) <= 2.0e-6
                        and abs(interval["end"] - round(interval["end"])) <= 2.0e-6
                        for interval in group["intervals"]
                    )
                    strict_geometry = (
                        complete_edges
                        and length >= minimum_length
                        and variation <= maximum_variation
                        and angle >= strict_minimum_angle
                        and max(distances) <= strict_maximum + tolerance
                    )
                    involved_edges = involved_edge_pairs(group["intervals"])
                    coverage = sum(interval["end"] - interval["start"] for interval in group["intervals"]) / max(float(len(group["intervals"])), 1.0)
                    if strict_geometry:
                        rows.append(_t_candidate_row(
                            source_id, target_id, source_path, target_points, distances,
                            target_elements_used, involved_edges, length, angle, variation,
                            coverage, complete_edges, True,
                        ))
                        continue
                    # Extended rule: a source face that falls completely on the
                    # target is trusted once its nearest edge row projects onto
                    # the target completely, even when unrelated side or upper
                    # edges poison the whole-group completeness check.
                    extended_rows = []
                    nearest_intervals = _nearest_edge_intervals(group, edge_contexts, nearest_band)
                    for run in _contiguous_interval_runs(nearest_intervals):
                        # Sample the run through its own intervals: a shared
                        # corner node must keep the hit of the edge it belongs
                        # to, not the next edge's ray that may land somewhere
                        # else entirely (e.g. an upturned flange).
                        run_path = []
                        run_points = []
                        run_distances = []
                        run_elements = set()
                        run_angles = []
                        broken = False
                        for interval in run["intervals"]:
                            context = edge_contexts[interval["edge_index"]]
                            run_angles.append(context["angle"])
                            first, second = context["first"], context["second"]
                            for local, boundary_hit in ((0.0, interval["start_hit"]), (1.0, interval["end_hit"])):
                                if local <= 2.0e-6 and run_path and run_path[-1]["node_id"] == first:
                                    continue
                                if boundary_hit is None:
                                    broken = True
                                    break
                                point = _add(nodes[first], _scale(_sub(nodes[second], nodes[first]), local))
                                run_path.append({"node_id": first if local <= 2.0e-6 else second, "coordinates": list(point)})
                                run_points.append(list(boundary_hit["point"]))
                                run_distances.append(boundary_hit["distance"])
                                run_elements.add(boundary_hit["element_id"])
                            if broken:
                                break
                        if broken or len(run_path) < 2:
                            continue
                        run_length = sum(_distance(tuple(run_path[index]["coordinates"]), tuple(run_path[index + 1]["coordinates"])) for index in range(len(run_path) - 1))
                        if run_length < minimum_length:
                            continue
                        run_average = sum(run_distances) / len(run_distances)
                        run_variation = (max(run_distances) - min(run_distances)) / max(run_average, 1.0e-9)
                        run_angle = sum(run_angles) / len(run_angles)
                        run_auto = (
                            run_variation <= maximum_variation
                            and run_angle >= strict_minimum_angle
                            and max(run_distances) <= strict_maximum + tolerance
                            and _face_fully_on_target(
                                model, boundary["adjacent_element_ids"], element_map,
                                target_elements, target_normal, face_maximum, tolerance, target_index,
                            )
                        )
                        if not run_auto:
                            continue
                        extended_rows.append(_t_candidate_row(
                            source_id, target_id, run_path, run_points, run_distances,
                            run_elements, involved_edge_pairs(run["intervals"]), run_length,
                            run_angle, run_variation, 1.0, True, True, trusted_reason=True,
                        ))
                    if extended_rows:
                        rows.extend(extended_rows)
                        continue
                    potential_warnings = _strict_failure_warnings(
                        complete_edges, length, minimum_length, variation, maximum_variation,
                        angle, strict_minimum_angle, distances, strict_maximum, tolerance,
                    )
                    if nearest_intervals:
                        potential_warnings.append(
                            "extended nearest-edge rule did not qualify: the source face must fall completely on the target"
                        )
                    rows.append(_t_candidate_row(
                        source_id, target_id, source_path, target_points, distances,
                        target_elements_used, involved_edges, length, angle, variation,
                        coverage, complete_edges, False, warnings=potential_warnings,
                    ))
    return rows


def _component_area(elements, nodes):
    return sum(_element_area(element, nodes) for element in elements)


def _bidirectional_hit(point, normal, elements, nodes, maximum, tolerance, element_index=None):
    hits = []
    for direction in (normal, tuple(-value for value in normal)):
        hit = _ray_hits_component(point, direction, elements, nodes, maximum, tolerance, element_index)
        if hit is not None:
            hits.append(hit)
    return min(hits, key=lambda row: (row["distance"], row["element_id"])) if hits else None


def _loop_plane_basis(normal):
    reference = (1.0, 0.0, 0.0)
    if abs(dot(normal, reference)) > 0.9:
        reference = (0.0, 1.0, 0.0)
    axis_u = unit(cross(normal, reference))
    axis_v = unit(cross(normal, axis_u))
    return axis_u, axis_v


def _point_in_polygon(point, polygon):
    inside = False
    count = len(polygon)
    for index in range(count):
        ax, ay = polygon[index]
        bx, by = polygon[(index + 1) % count]
        if (ay > point[1]) != (by > point[1]):
            crossing = (bx - ax) * (point[1] - ay) / (by - ay) + ax
            if point[0] < crossing:
                inside = not inside
    return inside


def _polygon_area_2d(polygon):
    total = 0.0
    count = len(polygon)
    for index in range(count):
        ax, ay = polygon[index]
        bx, by = polygon[(index + 1) % count]
        total += ax * by - bx * ay
    return abs(total) * 0.5


def _classify_closed_loops(closed_paths, nodes, normal):
    """Split closed free-edge loops into outer loops and their interior holes.

    Components routinely carry several disjoint patch meshes.  Treating every
    non-largest loop as a hole (the historical rule) misclassified the smaller
    patches and disabled the whole component, so containment is now decided
    geometrically on the loop plane.
    """
    if not closed_paths:
        return [], {}
    if len(closed_paths) == 1 or normal is None:
        return list(closed_paths), {}
    axis_u, axis_v = _loop_plane_basis(normal)
    polygons = {}
    for index, path in enumerate(closed_paths):
        points = [nodes[node_id] for node_id in path["node_ids"]]
        if len(points) < 3:
            continue
        polygons[index] = tuple((dot(point, axis_u), dot(point, axis_v)) for point in points)
    outers = []
    holes = {}
    for index, path in enumerate(closed_paths):
        polygon = polygons.get(index)
        if polygon is None:
            outers.append(path)
            continue
        container = None
        container_area = None
        polygon_area = _polygon_area_2d(polygon)
        for other_index, other_polygon in polygons.items():
            if other_index == index:
                continue
            # A hole lies fully inside its container and is strictly smaller;
            # testing one vertex alone misclassifies overlapping sibling
            # patches (one component carrying several repair patches).
            if not all(_point_in_polygon(point, other_polygon) for point in polygon):
                continue
            area = _polygon_area_2d(other_polygon)
            if area <= polygon_area:
                continue
            if container is None or area < container_area:
                container, container_area = closed_paths[other_index], area
        if container is None:
            outers.append(path)
        else:
            holes.setdefault(id(container), []).append(path)
    return outers, holes


def _loop_projection_hits(model, shared, source_id, path, target_normal, target_elements, target_index, maximum, tolerance):
    """Bidirectional normal hits for one closed loop's containment samples."""
    nodes = model.nodes
    node_hits = [
        _bidirectional_hit(nodes[node_id], target_normal, target_elements, nodes, maximum, tolerance, target_index)
        for node_id in path["node_ids"]
    ]
    edge_pairs = [tuple(pair) for pair in path["edge_pairs"]]
    owners = _context_edge_owners(shared, source_id)
    element_map = _context_element_map(shared, source_id)
    extra_hits = []
    for first, second in edge_pairs:
        midpoint = _midpoint(nodes[first], nodes[second])
        extra_hits.append(_bidirectional_hit(midpoint, target_normal, target_elements, nodes, maximum, tolerance, target_index))
    for element_id in sorted({owners[tuple(sorted(pair))] for pair in edge_pairs if tuple(sorted(pair)) in owners}):
        element = element_map.get(element_id)
        if element is None:
            continue
        centroid = tuple(sum(nodes[node_id][axis] for node_id in element.node_ids) / len(element.node_ids) for axis in range(3))
        extra_hits.append(_bidirectional_hit(centroid, target_normal, target_elements, nodes, maximum, tolerance, target_index))
    return node_hits, extra_hits


def _patch_row(source_id, target_id, group_id, loop_index, path, hole_rows, small_holes, node_hits, extra_hits, contained, angle, maximum_angle, settings, strict_maximum, tolerance, length, areas_differ=True, beyond_warning=False):
    distances = [hit["distance"] for hit in list(node_hits) + list(extra_hits) if hit is not None]
    if distances:
        average = sum(distances) / len(distances)
        variation = (max(distances) - min(distances)) / max(average, 1.0e-9)
        distance_summary = {"minimum": min(distances), "average": average, "maximum": max(distances)}
    else:
        variation = 1.0
        distance_summary = {"minimum": 0.0, "average": 0.0, "maximum": 0.0}
    samples = len(node_hits) + len(extra_hits)
    hit_count = sum(hit is not None for hit in list(node_hits) + list(extra_hits))
    coverage = hit_count / float(samples) if samples else 0.0
    minimum_length = float(settings["minimum_patch_length"])
    maximum_variation = float(settings["maximum_distance_variation_ratio"])
    auto = (
        contained
        and areas_differ
        and bool(distances)
        and variation <= maximum_variation
        and angle <= float(settings["maximum_patch_normal_angle"])
        and max(distances) <= strict_maximum + tolerance
        and length >= minimum_length
    )
    confidence = _candidate_confidence(1.0, variation, max(0.0, 1.0 - angle / max(maximum_angle, 1.0)))
    warnings = []
    if small_holes:
        warnings.append("fastener-sized patch openings are excluded from the weld path")
    if beyond_warning:
        warnings.append("patch loop extends beyond the target footprint")
    return {
        "candidate_id": "",
        "candidate_type": "PATCH_SEAM",
        "patch_group_id": group_id,
        "patch_loop_index": loop_index,
        "source_component_id": source_id,
        "target_component_id": target_id,
        "source_node_ids": path["node_ids"],
        "source_edge_pairs": path["edge_pairs"],
        "target_hint_element_ids": sorted({
            hit["element_id"] for hit in list(node_hits) + list(extra_hits) if hit is not None
        }),
        "target_projection_points": [
            list(hit["point"]) for hit in node_hits if hit is not None
        ],
        "closed": True,
        "boundary_class": str(path.get("boundary_class", "OUTER")),
        "length": round(length, 9),
        "confidence": confidence,
        "projection_coverage": round(coverage, 6),
        "fully_contained": bool(contained),
        "auto_eligible": auto,
        "recognition_status": "TRUSTED" if auto else "POTENTIAL",
        "status": "AUTO_READY" if auto else "REVIEW_REQUIRED",
        "distance": distance_summary,
        "normal_angle": round(angle, 6),
        "hole_summary": hole_rows,
        "reasons": ["smaller parallel shell is fully projected inside a larger target shell"],
        "warnings": warnings if warnings else ([] if auto else ["parallel components overlap only partially or miss a trusted tolerance gate"]),
    }


def _loop_mesh_continuous(path, target_topology):
    """True when a weld loop is already merged into the partner component mesh."""
    if target_topology is None:
        return False
    return mesh_continuous(path.get("node_ids") or [], target_topology.node_ids)


def _patch_candidates(model, settings, topologies, shared=None):
    strict_maximum = float(settings["search_distance"])
    maximum = strict_maximum * float(settings.get("potential_search_multiplier", 1.25))
    tolerance = float(settings["ray_tolerance"])
    strict_maximum_angle = float(settings["maximum_patch_normal_angle"])
    maximum_angle = strict_maximum_angle + float(settings.get("potential_angle_margin", 10.0))
    minimum_length = float(settings["minimum_patch_length"])
    potential_length_ratio = float(settings.get("potential_length_ratio", 0.75))
    small_hole_diameter = float(settings["small_hole_diameter"])
    if shared is None:
        shared = _detection_context(model, topologies, maximum)
    nodes = model.nodes
    rows = []
    candidate_pairs = set(find_candidate_component_pairs(topologies, maximum))
    component_ids = sorted(topologies)
    for first_index, first_id in enumerate(component_ids):
        for second_id in component_ids[first_index + 1:]:
            if (first_id, second_id) not in candidate_pairs:
                continue
            first_normal = _context_normal(shared, first_id)
            second_normal = _context_normal(shared, second_id)
            if first_normal is None or second_normal is None:
                continue
            angle = angle_degrees(first_normal, second_normal)
            if angle > maximum_angle:
                continue
            first_area = _context_area(shared, first_id)
            second_area = _context_area(shared, second_id)
            areas_differ = abs(first_area - second_area) > max(first_area, second_area) * 0.02
            # A patch relation is proven per closed loop: the loop's own
            # boundary must project completely onto the partner component.
            # Component area only breaks ties and guards the potential
            # fallback, because one component may carry several patches whose
            # total area says nothing about each patch footprint.
            direction_results = []
            contained_sources = []
            for source_id, target_id in ((first_id, second_id), (second_id, first_id)):
                loops = _context_weld_loops(shared, source_id)
                if not loops:
                    continue
                target_elements = _context_elements(shared, target_id)
                target_index = _context_index(shared, target_id)
                target_normal = _context_normal(shared, target_id)
                target_bounds = topologies[target_id].bounds
                direction_rows = []
                any_contained = False
                deferred_loops = []
                for loop in loops:
                    path = loop["path"]
                    if _loop_mesh_continuous(path, topologies[target_id]):
                        # The loop is merged into the partner mesh: the two
                        # components already share those GRID nodes, so the
                        # patch is connected and no seam is missing.
                        continue
                    length = _path_length(path["node_ids"], nodes, True)
                    if length < minimum_length * potential_length_ratio:
                        continue
                    if loop.get("is_hole") and length / math.pi < small_hole_diameter:
                        # Fastener-sized openings are not weld seams.
                        continue
                    if not _bounds_within(loop["bounds"], target_bounds, maximum):
                        deferred_loops.append((path, length))
                        continue
                    node_hits, extra_hits = _loop_projection_hits(
                        model, shared, source_id, path, target_normal,
                        target_elements, target_index, maximum, tolerance,
                    )
                    hit_count = sum(hit is not None for hit in node_hits + extra_hits)
                    if hit_count == 0:
                        continue
                    contained = hit_count == len(node_hits) + len(extra_hits)
                    any_contained = any_contained or contained
                    direction_rows.append((path, length, node_hits, extra_hits, contained, False))
                if any_contained:
                    # Sibling loops of a proven patch keep their review row even
                    # when they hang past the target footprint.
                    for path, length in deferred_loops:
                        direction_rows.append((
                            path, length, [None] * len(path["node_ids"]), [], False, True,
                        ))
                    direction_results.append((source_id, target_id, direction_rows))
                    contained_sources.append(source_id)
            coincident_relations = []
            if len(contained_sources) == 2:
                # Coincident footprints: keep the smaller-area source side and
                # remember the suppressed direction so ambiguity accounting
                # still sees the proven-but-dropped relation (a three-plate
                # stack must not weld its top plate straight onto the base).
                keep_source = first_id if first_area <= second_area else second_id
                suppressed_source = second_id if keep_source == first_id else first_id
                coincident_relations = [(suppressed_source, keep_source)]
                direction_results = [row for row in direction_results if row[0] == keep_source]
            if not direction_results:
                # Historical fallback: neither loop proved containment, so the
                # smaller-area component keeps its potential review rows.
                source_id, target_id = (first_id, second_id) if first_area <= second_area else (second_id, first_id)
                loops = _context_weld_loops(shared, source_id)
                if not loops:
                    continue
                target_elements = _context_elements(shared, target_id)
                target_index = _context_index(shared, target_id)
                target_normal = _context_normal(shared, target_id)
                fallback_rows = []
                for loop in loops:
                    path = loop["path"]
                    if _loop_mesh_continuous(path, topologies[target_id]):
                        continue
                    length = _path_length(path["node_ids"], nodes, True)
                    if length < minimum_length * potential_length_ratio:
                        continue
                    if loop.get("is_hole") and length / math.pi < small_hole_diameter:
                        continue
                    node_hits, extra_hits = _loop_projection_hits(
                        model, shared, source_id, path, target_normal,
                        target_elements, target_index, maximum, tolerance,
                    )
                    hit_count = sum(hit is not None for hit in node_hits + extra_hits)
                    if hit_count < max(
                        2,
                        int(math.ceil(
                            len(node_hits + extra_hits) *
                            float(settings.get("patch_review_min_coverage", 0.25))
                        )),
                    ):
                        continue
                    fallback_rows.append((path, length, node_hits, extra_hits, False, False))
                if fallback_rows:
                    direction_results.append((source_id, target_id, fallback_rows))
            for source_id, target_id, direction_rows in direction_results:
                group_id = "PATCH_{}_{}".format(source_id, target_id)
                for loop_index, (path, length, node_hits, extra_hits, contained, beyond) in enumerate(direction_rows, 1):
                    hole_rows = [
                        {"length": hole["length"], "equivalent_diameter": hole["length"] / math.pi, "node_ids": hole["node_ids"]}
                        for hole in _loop_holes_for(shared, source_id, path)
                    ]
                    small_holes = [row for row in hole_rows if row["equivalent_diameter"] < small_hole_diameter]
                    row = _patch_row(
                        source_id, target_id, group_id, loop_index, path, hole_rows,
                        small_holes, node_hits, extra_hits, contained, angle,
                        maximum_angle, settings, strict_maximum, tolerance, length,
                        areas_differ=areas_differ, beyond_warning=beyond,
                    )
                    if coincident_relations:
                        row["coincident_relations"] = [list(pair) for pair in coincident_relations]
                    rows.append(row)
    return rows


def _loop_holes_for(shared, source_id, path):
    for loop in _context_closed_loops(shared, source_id):
        if loop["path"] is path:
            return loop["holes"]
    return []


def _edge_match_distance(first_edge, second_edge, nodes):
    a, b = (nodes[node_id] for node_id in first_edge)
    c, d = (nodes[node_id] for node_id in second_edge)
    forward = (_distance(a, c) + _distance(b, d)) * 0.5
    reverse = (_distance(a, d) + _distance(b, c)) * 0.5
    return min(forward, reverse)


def _near_edge_candidates(model, settings, topologies):
    maximum = float(settings["near_edge_distance"])
    tangent_limit = float(settings["near_edge_tangent_angle"])
    rows = []
    component_ids = sorted(topologies)
    candidate_pairs = set(find_candidate_component_pairs(topologies, maximum))
    edge_indexes = _component_edge_indexes(topologies, model.nodes, maximum)
    for index, first_id in enumerate(component_ids):
        for second_id in component_ids[index + 1:]:
            if (first_id, second_id) not in candidate_pairs:
                continue
            matched = []
            for first_a, first_b, owner in topologies[first_id].free_edges:
                first_vector = _sub(model.nodes[first_b], model.nodes[first_a])
                if norm(first_vector) <= 1.0e-12:
                    continue
                best = None
                first_bounds = _bounds_for_points((model.nodes[first_a], model.nodes[first_b]))
                expanded = (
                    first_bounds[0] - maximum, first_bounds[1] + maximum,
                    first_bounds[2] - maximum, first_bounds[3] + maximum,
                    first_bounds[4] - maximum, first_bounds[5] + maximum,
                )
                target_edges = edge_indexes[second_id].query_bounds(expanded)
                for second_a, second_b, _ in target_edges:
                    second_vector = _sub(model.nodes[second_b], model.nodes[second_a])
                    if norm(second_vector) <= 1.0e-12:
                        continue
                    angle = angle_degrees(first_vector, second_vector)
                    if angle > tangent_limit:
                        continue
                    distance = _edge_match_distance((first_a, first_b), (second_a, second_b), model.nodes)
                    if distance <= maximum and (best is None or distance < best[0]):
                        best = (distance, second_a, second_b)
                if best is not None:
                    matched.append((first_a, first_b, owner, best))
            if not matched:
                continue
            edges = [(first, second, owner) for first, second, owner, _ in matched]
            for path in connected_edge_paths(edges, model.nodes):
                if path["branched"]:
                    continue
                path_matches = [entry for entry in matched if set(entry[:2]).issubset(path["node_ids"])]
                distances = [entry[3][0] for entry in path_matches]
                if not distances:
                    continue
                target_edge_pairs = sorted({tuple(sorted((entry[3][1], entry[3][2]))) for entry in path_matches})
                target_node_ids = sorted({node_id for edge in target_edge_pairs for node_id in edge})
                rows.append({
                    "candidate_id": "",
                    "candidate_type": "NEAR_FREE_EDGES",
                    "source_component_id": first_id,
                    "target_component_id": second_id,
                    "source_node_ids": path["node_ids"],
                    "source_edge_pairs": path["edge_pairs"],
                    "target_node_ids": target_node_ids,
                    "target_edge_pairs": [list(edge) for edge in target_edge_pairs],
                    "closed": bool(path["closed"]),
                    "length": round(_path_length(path["node_ids"], model.nodes, bool(path["closed"])), 9),
                    "confidence": round(max(0.05, 0.75 * (1.0 - sum(distances) / len(distances) / max(maximum, 1.0e-9))), 6),
                    "auto_eligible": False,
                    "status": "REVIEW_REQUIRED",
                    "distance": {"minimum": min(distances), "average": sum(distances) / len(distances), "maximum": max(distances)},
                    "reasons": ["two free-edge paths are close and similarly directed"],
                    "warnings": ["nearby free edges require manual weld creation"],
                })
    return rows


def _initialize_detection_worker(model, settings, topologies):
    global _DETECTION_CONTEXT
    maximum = float(settings["search_distance"]) * float(settings.get("potential_search_multiplier", 1.25))
    _DETECTION_CONTEXT = {
        "model": model,
        "settings": settings,
        "topologies": topologies,
        "context": _detection_context(model, topologies, maximum),
        "t_geometry": None,
    }


def _worker_t_geometry():
    """Build the immutable physical-skin cache at most once per worker.

    The strict detector can invoke a relaxed recall pass.  Rebuilding normals,
    facets and spatial indexes for that second pass used to roughly double the
    CPU and peak allocation of every Windows worker.
    """
    geometry = _DETECTION_CONTEXT.get("t_geometry")
    if geometry is None:
        geometry = build_physical_geometry_context(
            _DETECTION_CONTEXT["model"], _DETECTION_CONTEXT["topologies"])
        _DETECTION_CONTEXT["t_geometry"] = geometry
        # PATCH uses the same physical facets.  If the process later receives
        # that task, share them instead of materializing a second copy.
        _DETECTION_CONTEXT["context"]["physical_geometry"] = geometry[1]
    return geometry


def _parallel_detection_task(task):
    kind, source_ids = task
    model = _DETECTION_CONTEXT["model"]
    settings = _DETECTION_CONTEXT["settings"]
    topologies = _DETECTION_CONTEXT["topologies"]
    shared = _DETECTION_CONTEXT["context"]
    if kind == "T":
        return detect_t_candidates_v2(
            model, settings, topologies, set(source_ids),
            geometry_context=_worker_t_geometry(),
            defer_missing_fallback=True,
        )
    if kind == "T_RECALL":
        relaxed = dict(settings)
        relaxed["t_recall_candidate_pass"] = True
        relaxed["t_edge_review_coverage"] = float(
            settings.get("t_recall_edge_review_coverage", 0.01))
        return detect_t_candidates_v2(
            model, relaxed, topologies, set(source_ids),
            geometry_context=_worker_t_geometry(),
        )
    if kind == "PATCH":
        return _patch_candidates(model, settings, topologies, shared)
    if kind == "NEAR":
        return _near_edge_candidates(model, settings, topologies)
    raise ValueError("unsupported detection task {}".format(kind))


def _resolved_worker_count(settings, component_count, element_count):
    configured = int(settings.get("python_workers", 0) or 0)
    if configured < 0:
        raise ValueError("python_workers must not be negative")
    available = max(1, int(os.cpu_count() or 1))
    # Recognition runs in a separate Python process while HyperMesh waits, so
    # reserving one logical CPU only left compute capacity idle.  Keep the
    # conservative eight-process memory cap but use every available core under
    # that cap; users can still set an explicit lower value.
    workers = configured if configured else min(8, available)
    workers = min(workers, max(1, component_count + 2))
    if workers < 2 or component_count < 4 or element_count < int(settings.get("parallel_min_elements", 2000)):
        return 1
    return workers


def resolved_worker_count_for_model(model, settings):
    component_ids = {element.component_id for element in model.elements.values()}
    return _resolved_worker_count(settings, len(component_ids), len(model.elements))


def _balanced_source_groups(topologies, component_ids, partition_count):
    """Greedily balance source components by free-edge detection work."""
    partition_count = max(1, min(int(partition_count), len(component_ids)))
    groups = [[] for _ in range(partition_count)]
    loads = [0 for _ in range(partition_count)]
    weighted = sorted(
        (int(component_id) for component_id in component_ids),
        key=lambda component_id: (
            -len(topologies[component_id].free_edges),
            -len(topologies[component_id].element_ids),
            component_id,
        ),
    )
    for component_id in weighted:
        target = min(range(partition_count), key=lambda index: (loads[index], index))
        groups[target].append(component_id)
        loads[target] += max(
            1,
            len(topologies[component_id].free_edges),
            len(topologies[component_id].element_ids) // 8,
        )
    return [sorted(group) for group in groups if group]


def _t_relation_key(candidate):
    edges = tuple(sorted(tuple(sorted(int(value) for value in pair)) for pair in candidate.get("source_edge_pairs", [])))
    return int(candidate["source_component_id"]), edges


def _apply_relation_ambiguity(candidates):
    """Downgrade relations that cannot select one unambiguous target.

    Geometry detection intentionally keeps every plausible hit.  Trust is a
    separate, conservative decision: one source T edge may land on only one
    target, and one patch component may project onto only one target.  A
    target carrying several distinct patches is not ambiguous - each patch
    loop is an independent weld.
    """
    t_targets = defaultdict(set)
    patch_targets = defaultdict(set)
    for row in candidates:
        if row["candidate_type"] == "T_SEAM":
            t_targets[_t_relation_key(row)].add(int(row["target_component_id"]))
        elif row["candidate_type"] == "PATCH_SEAM":
            source = int(row["source_component_id"])
            patch_targets[source].add(int(row["target_component_id"]))
            # A coincident pair suppresses its larger-source direction, but
            # that proven containment still counts: the suppressed component
            # must not become a trusted weld onto further targets (the
            # three-plate stack phantom weld through the middle plate).
            for suppressed_source, suppressed_target in row.get("coincident_relations", []):
                patch_targets[int(suppressed_source)].add(int(suppressed_target))

    for row in candidates:
        reason = ""
        if row["candidate_type"] == "T_SEAM" and len(t_targets[_t_relation_key(row)]) > 1:
            reason = "one source edge extension intersects multiple target components"
        elif row["candidate_type"] == "PATCH_SEAM":
            source = int(row["source_component_id"])
            if len(patch_targets[source]) > 1:
                reason = "one patch component projects onto multiple target components"
        if reason:
            row["auto_eligible"] = False
            row["recognition_status"] = "POTENTIAL"
            row["status"] = "REVIEW_REQUIRED"
            row.setdefault("warnings", []).append(reason)
            row["ambiguous_relation"] = True
        else:
            row.setdefault("ambiguous_relation", False)
    return candidates


def build_recognition_plan(candidates, recall_first=True, submit_all=True):
    """Deliver supported paths; recall settings never bypass mesh safety gates."""
    trusted = []
    potential_rows = []
    for row in candidates:
        standard_trusted = row.get("recognition_status") == "TRUSTED" and row.get("auto_eligible")
        target_ids = [
            int(value) for value in row.get("target_component_ids", [row.get("target_component_id", 0)])
            if value is not None and int(value) > 0
        ]
        source_nodes = [int(value) for value in row.get("source_node_ids", []) if int(value) > 0]
        direct_delivery = (
            bool(submit_all)
            and row.get("candidate_type") in ("T_SEAM", "PATCH_SEAM")
            and bool(source_nodes)
            and bool(target_ids)
        )
        # Recall can deliver a generalized T angle marked REVIEW.  The common
        # safety gate below still excludes unsupported or ambiguous geometry.
        if row.get("recall_candidate_fallback"):
            local_topology_blockers = {"INNER_BOUNDARY_SOURCE"}
        else:
            local_topology_blockers = {
                "INNER_BOUNDARY_SOURCE", "SHORT_WELD", "ANGLE_BORDERLINE",
                "SKIN_ERROR_BORDERLINE",
            }
        recall_trusted = (
            bool(recall_first)
            and row.get("candidate_type") == "T_SEAM"
            and row.get("duplicate_status", "NEW") == "NEW"
            and len(source_nodes) >= 2
            and bool(target_ids)
            and not (set(row.get("reason_codes", [])) & local_topology_blockers)
        )
        # Only evidence that would produce a wrong or duplicate weld blocks
        # delivery.  Coverage shortfalls, projection jumps and skin error are
        # tolerance findings: the mesh executor still validates the result, so
        # they stay diagnostics instead of suppressing the candidate.
        blockers = {
            "TARGET_AMBIGUITY", "MULTI_TARGET_UNCERTAIN", "NON_MANIFOLD_REGION",
            "NORMAL_INCONSISTENT", "INNER_BOUNDARY_SOURCE", "SHORT_WELD",
        }
        safe = (
            row.get("duplicate_status", "NEW") == "NEW"
            and not row.get("ambiguous_relation", False)
            and not (set(row.get("reason_codes", [])) & blockers)
            and float(row.get("projection_coverage", 1.0)) >= 0.5
            and float(row.get("length", 0.0)) >= 1.0e-9
            and len(source_nodes) >= (3 if row.get("closed", False) else 2)
            and len(source_nodes) == len(set(source_nodes))
        )
        if safe and (direct_delivery or standard_trusted or recall_trusted):
            seed = {
                "candidate_id": str(row["candidate_id"]),
                "weld_type": "T" if row["candidate_type"] == "T_SEAM" else "PATCH",
                "source_component_id": int(row["source_component_id"]),
                "target_component_ids": target_ids,
                "source_node_ids": source_nodes,
                "closed_loop": bool(row.get("closed", False)),
                "confidence": float(row.get("confidence", 0.0)),
                "support_runs": list(row.get("support_runs", [])),
                "reason_codes": list(row.get("reason_codes", [])),
                "delivery_mode": (
                    "ALL_CANDIDATES" if direct_delivery else
                    "RECALL_FIRST" if recall_trusted and not standard_trusted else
                    "STANDARD"
                ),
            }
            if seed["source_node_ids"]:
                trusted.append(seed)
        else:
            potential_rows.append(row)

    # T relations are grouped only when they describe the same source edge;
    # unrelated weld locations on one component remain separate review sets.
    grouped = {}
    patch_rows = []
    for row in potential_rows:
        if row["candidate_type"] == "T_SEAM":
            key = ("T",) + _t_relation_key(row)
            group = grouped.setdefault(key, {"candidate_ids": [], "component_ids": set(), "weld_types": set(), "reasons": set()})
            group["candidate_ids"].append(str(row["candidate_id"]))
            group["component_ids"].add(int(row["source_component_id"]))
            group["component_ids"].update(
                int(value) for value in row.get("target_component_ids", [row["target_component_id"]])
                if int(value) > 0
            )
            group["component_ids"].update(
                int(value["component_id"])
                for value in row.get("review", {}).get("alternative_targets", [])
                if int(value.get("component_id", 0)) > 0
            )
            group["weld_types"].add("T")
            group["reasons"].update(str(value) for value in row.get("reason_codes", row.get("warnings", [])))
        elif row["candidate_type"] == "PATCH_SEAM":
            patch_rows.append(row)

    # Parallel patch relations form connected component clusters.  This makes
    # a three-plate stack one set while keeping spatially unrelated pairs apart.
    remaining = list(patch_rows)
    patch_serial = 0
    while remaining:
        patch_serial += 1
        cluster = [remaining.pop(0)]
        component_ids = {
            int(cluster[0]["source_component_id"]),
            int(cluster[0]["target_component_id"]),
        }
        changed = True
        while changed:
            changed = False
            keep = []
            for row in remaining:
                ids = {int(row["source_component_id"]), int(row["target_component_id"])}
                if component_ids & ids:
                    cluster.append(row)
                    component_ids.update(ids)
                    changed = True
                else:
                    keep.append(row)
            remaining = keep
        grouped[("PATCH", patch_serial)] = {
            "candidate_ids": [str(row["candidate_id"]) for row in cluster],
            "component_ids": component_ids,
            "weld_types": {"PATCH"},
            "reasons": {str(value) for row in cluster for value in row.get("warnings", [])},
        }

    merged_groups = []
    for key in sorted(grouped, key=str):
        incoming = grouped[key]
        matches = [group for group in merged_groups if len(group["component_ids"] & incoming["component_ids"]) >= 2]
        if not matches:
            merged_groups.append(incoming)
            continue
        primary = matches[0]
        for field in ("component_ids", "weld_types", "reasons"):
            primary[field].update(incoming[field])
        primary["candidate_ids"].extend(incoming["candidate_ids"])
        for redundant in matches[1:]:
            for field in ("component_ids", "weld_types", "reasons"):
                primary[field].update(redundant[field])
            primary["candidate_ids"].extend(redundant["candidate_ids"])
            merged_groups.remove(redundant)

    potential_groups = []
    for serial, group in enumerate(merged_groups, 1):
        potential_groups.append({
            "group_id": "POTENTIAL_{:04d}".format(serial),
            "set_name": "FEM_SEAM_REVIEW_{:04d}".format(serial),
            "component_ids": sorted(group["component_ids"]),
            "candidate_ids": sorted(set(group["candidate_ids"])),
            "weld_types": sorted(group["weld_types"]),
            "reasons": sorted(group["reasons"]),
        })
    return {"trusted_seeds": trusted, "potential_groups": potential_groups}


def detect_candidates(model, settings=None):
    resolved = dict(DEFAULT_SETTINGS)
    if settings:
        resolved.update(settings)
    topologies = build_topology(model)
    # The input FEM is now the complete model, so detection must stay scoped
    # to the components the engineer selected.  Filtering the topology map
    # keeps source sweeps, patch and near-edge searches, and the worker count
    # identical to the historical selected-only export behavior.
    selected = {int(value) for value in resolved.get("selected_component_ids", [])}
    if selected:
        topologies = {
            component_id: topology
            for component_id, topology in topologies.items()
            if component_id in selected
        }
    worker_count = _resolved_worker_count(resolved, len(topologies), len(model.elements))
    detection_maximum = float(resolved["search_distance"]) * float(resolved.get("potential_search_multiplier", 1.25))
    candidates = []
    if worker_count > 1:
        component_ids = sorted(topologies)
        # Reserve one slot for PATCH and another only when the optional legacy
        # near-edge pass is enabled.  The old unconditional two-slot reserve
        # left a core idle during the normal recognition workflow.
        auxiliary_tasks = 1 + int(bool(resolved.get("include_legacy_near_edges", False)))
        t_partitions = max(1, worker_count - auxiliary_tasks)
        source_groups = _balanced_source_groups(topologies, component_ids, t_partitions)
        tasks = [("T", group) for group in source_groups if group]
        tasks.append(("PATCH", ()))
        if bool(resolved.get("include_legacy_near_edges", False)):
            tasks.append(("NEAR", ()))
        try:
            context = multiprocessing.get_context("spawn")
            original_executable = sys.executable
            hidden_executable = Path(original_executable).with_name("pythonw.exe")
            if os.name == "nt" and hidden_executable.is_file():
                # python.exe creates one visible console per spawned worker when
                # HyperMesh itself has no console. pythonw.exe uses the same
                # runtime and multiprocessing pipes without flashing windows.
                multiprocessing.set_executable(str(hidden_executable))
            try:
                with ProcessPoolExecutor(
                    max_workers=worker_count,
                    mp_context=context,
                    initializer=_initialize_detection_worker,
                    initargs=(model, resolved, topologies),
                ) as executor:
                    strict_t_rows = []
                    for task, rows in zip(tasks, executor.map(_parallel_detection_task, tasks)):
                        if task[0] == "T":
                            strict_t_rows.extend(rows)
                        else:
                            candidates.extend(rows)

                    # Missing-source recall depends on reverse relations from
                    # every source component.  Running it independently inside
                    # each partition created extra REVIEW rows (and made output
                    # depend on worker count).  Perform a second pool wave only
                    # for sources without a strict/local-supplementary row, then
                    # apply the same global reverse-pair suppression as serial.
                    sources_with_rows = {
                        int(row["source_component_id"]) for row in strict_t_rows
                    }
                    missing_sources = [
                        component_id for component_id in component_ids
                        if component_id not in sources_with_rows
                    ]
                    fallback_rows = []
                    if (bool(resolved.get("t_recall_first_mode", True)) and
                            missing_sources):
                        fallback_partitions = min(worker_count, len(missing_sources))
                        fallback_groups = _balanced_source_groups(
                            topologies, missing_sources, fallback_partitions)
                        fallback_tasks = [
                            ("T_RECALL", group) for group in fallback_groups if group
                        ]
                        for rows in executor.map(_parallel_detection_task, fallback_tasks):
                            fallback_rows.extend(rows)
                    strict_pairs = {
                        (int(row["source_component_id"]), int(target_id))
                        for row in strict_t_rows
                        for target_id in row.get("target_component_ids", [])
                    }
                    minimum_coverage = float(resolved.get("t_recall_min_coverage", 0.5))
                    strict_t_rows.extend(
                        row for row in fallback_rows
                        if float(row.get("projection_coverage", 0.0)) >= minimum_coverage
                        and not any(
                            (int(target_id), int(row["source_component_id"])) in strict_pairs
                            for target_id in row.get("target_component_ids", [])
                        )
                    )
                    candidates.extend(strict_t_rows)
            finally:
                multiprocessing.set_executable(original_executable)
        except Exception:
            # Embedded/locked-down Python installations may prohibit child
            # processes. Preserve the exact serial path instead of failing the
            # engineering task solely because parallel startup was unavailable.
            shared = _detection_context(model, topologies, detection_maximum)
            candidates = detect_t_candidates_v2(model, resolved, topologies)
            candidates.extend(_patch_candidates(model, resolved, topologies, shared))
            if bool(resolved.get("include_legacy_near_edges", False)):
                candidates.extend(_near_edge_candidates(model, resolved, topologies))
    else:
        shared = _detection_context(model, topologies, detection_maximum)
        candidates = detect_t_candidates_v2(model, resolved, topologies)
        candidates.extend(_patch_candidates(model, resolved, topologies, shared))
        if bool(resolved.get("include_legacy_near_edges", False)):
            candidates.extend(_near_edge_candidates(model, resolved, topologies))
    candidates = _apply_relation_ambiguity(candidates)
    candidates = [
        row if row.get("candidate_type") == "T_SEAM" else enrich_non_t_candidate(row, model, resolved, topologies)
        for row in candidates
    ]
    candidates.sort(key=lambda row: (row["candidate_type"], row["source_component_id"], row["target_component_id"], tuple(row["source_node_ids"])))
    if selected:
        candidates = [
            row for row in candidates
            if int(row["source_component_id"]) in selected
            and (not row.get("target_component_id") or int(row["target_component_id"]) in selected)
        ]
    for index, row in enumerate(candidates, 1):
        row["candidate_id"] = "B{:06d}".format(index)
        if row.get("candidate_type") == "T_SEAM" and isinstance(row.get("source"), dict):
            # Worker partitions have independent local chain counters.  The
            # public value must be stable across serial/parallel execution.
            row["source"]["chain_id"] = index
        row["joint_type"] = {"T_SEAM": "T_PATH", "PATCH_SEAM": "L_SURF"}.get(row["candidate_type"], "REVIEW")
        row["duplicate_status"] = "NEW"
        source_topology = topologies.get(int(row["source_component_id"]))
        source_owners = {}
        if source_topology is not None:
            source_owners = {tuple(sorted((first, second))): owner for first, second, owner in source_topology.free_edges}
        row["source_element_ids"] = sorted({source_owners[tuple(sorted(pair))] for pair in row.get("source_edge_pairs", []) if tuple(sorted(pair)) in source_owners})
        target_nodes = set(int(value) for value in row.get("target_node_ids", []) if int(value) > 0)
        for element_id in row.get("target_hint_element_ids", []):
            if int(element_id) in model.elements:
                target_nodes.update(model.elements[int(element_id)].node_ids)
        row["target_hint_node_ids"] = sorted(target_nodes)
    return candidates


def _thickness_name(component_name):
    match = re.search(r"_T(\d+(?:[.]\d+)?)", component_name, flags=re.IGNORECASE)
    return "SEAM_T{}".format(match.group(1)) if match else "SEAM_UNASSIGNED"


def _allocate(counter):
    counter[0] += 1
    return counter[0]


def _element_index_add(model, element):
    index = getattr(model, "_elements_by_component", None)
    if index is not None:
        index.setdefault(element.component_id, []).append(element)
    signatures = getattr(model, "_element_signature_index", None)
    if signatures is not None:
        signature = tuple(sorted(int(value) for value in element.node_ids))
        signatures.setdefault(signature, set()).add(int(element.element_id))


def _element_index_remove(model, element):
    index = getattr(model, "_elements_by_component", None)
    if index is not None:
        rows = index.get(element.component_id, [])
        index[element.component_id] = [row for row in rows if row.element_id != element.element_id]
    signatures = getattr(model, "_element_signature_index", None)
    if signatures is not None:
        signature = tuple(sorted(int(value) for value in element.node_ids))
        ids = signatures.get(signature, set())
        ids.discard(int(element.element_id))
        if not ids:
            signatures.pop(signature, None)


def _ensure_element_signature_index(model):
    index = {}
    for element in model.elements.values():
        signature = tuple(sorted(int(value) for value in element.node_ids))
        index.setdefault(signature, set()).add(int(element.element_id))
    model._element_signature_index = index
    return index


def _point_on_segment(point, first, second, tolerance):
    direction = _sub(second, first)
    denominator = dot(direction, direction)
    if denominator <= 1.0e-24:
        return None
    parameter = dot(_sub(point, first), direction) / denominator
    nearest = _add(first, _scale(direction, parameter))
    if -tolerance <= parameter <= 1.0 + tolerance and _distance(point, nearest) <= tolerance:
        return max(0.0, min(1.0, parameter))
    return None


def _materialize_source_path(model, candidate, node_counter, element_counter, tolerance=1.0e-6):
    source_path = candidate.get("source_path")
    if not source_path:
        return {"status": "READY", "node_ids": list(candidate["source_node_ids"]), "created_node_ids": [], "deleted_element_ids": [], "created_element_ids": []}
    source_component_id = int(candidate["source_component_id"])
    source_component = model.components.get(source_component_id)
    source_elements = model.elements_for_components([source_component_id])
    topology_rows = build_component_topology(
        [{"component_id": source_component_id, "component_name": source_component.component_name if source_component else "COMP_{}".format(source_component_id)}],
        model.nodes,
        [{
            "element_id": element.element_id, "component_id": element.component_id,
            "element_type": element.element_type, "node_ids": list(element.node_ids),
        } for element in source_elements],
    )
    topology = topology_rows.get(source_component_id)
    if topology is None:
        return {"status": "FAILED", "warnings": ["source component topology is unavailable"]}
    element_insertions = {}
    realized = []
    created_nodes = []
    created_elements = []
    deleted_elements = {}
    node_start, element_start = node_counter[0], element_counter[0]

    def rollback(warnings):
        for element_id in created_elements:
            created_element = model.elements.pop(element_id, None)
            if created_element is not None:
                _element_index_remove(model, created_element)
            model.element_properties.pop(element_id, None)
        for element_id, (element, property_id) in deleted_elements.items():
            model.elements[element_id] = element
            _element_index_add(model, element)
            model.element_properties[element_id] = property_id
        for node_id in created_nodes:
            model.nodes.pop(node_id, None)
        node_counter[0], element_counter[0] = node_start, element_start
        return {"status": "FAILED", "warnings": list(warnings)}

    point_nodes = {}
    for entry in source_path:
        existing = int(entry.get("node_id", 0))
        point = tuple(float(value) for value in entry["coordinates"])
        if existing > 0:
            realized.append(existing)
            continue
        key = tuple(int(round(value / tolerance)) for value in point)
        if key in point_nodes:
            realized.append(point_nodes[key])
            continue
        matches = []
        for first, second, owner_id in topology.free_edges:
            parameter = _point_on_segment(point, model.nodes[first], model.nodes[second], tolerance)
            if parameter is not None and tolerance < parameter < 1.0 - tolerance:
                matches.append((owner_id, first, second, parameter))
        if len(matches) != 1:
            return rollback(["partial T endpoint is not inside one unique source free edge"])
        owner_id, first, second, parameter = matches[0]
        node_id = _allocate(node_counter)
        model.nodes[node_id] = point
        point_nodes[key] = node_id
        created_nodes.append(node_id)
        element_insertions.setdefault(owner_id, {}).setdefault(tuple(sorted((first, second))), []).append(node_id)
        realized.append(node_id)

    deleted, created = [], created_elements
    for element_id, edge_insertions in sorted(element_insertions.items()):
        element = model.elements.get(element_id)
        if element is None:
            return rollback(["source mother shell became stale during boundary insertion"])
        polygon = list(element.node_ids)
        augmented = []
        for index, first in enumerate(polygon):
            second = polygon[(index + 1) % len(polygon)]
            augmented.append(first)
            inserted = edge_insertions.get(tuple(sorted((first, second))), [])
            inserted.sort(key=lambda node_id: _point_on_segment(model.nodes[node_id], model.nodes[first], model.nodes[second], tolerance))
            augmented.extend(inserted)
        plane = _plane(polygon, model.nodes)
        local = {node_id: _project(model.nodes[node_id], plane)[1] for node_id in augmented}
        try:
            triangles = _triangulate(augmented, [local[node_id] for node_id in augmented])
        except ValueError as exc:
            return rollback([str(exc)])
        property_id = int(model.element_properties[element_id])
        original_area = element_metrics(element.node_ids, model.nodes)["area"]
        replacement_area = sum(element_metrics(node_ids, model.nodes)["area"] for node_ids in triangles)
        if original_area <= 0.0 or abs(replacement_area - original_area) / original_area > 1.0e-7:
            return rollback(["source boundary insertion does not preserve mother-shell area"])
        deleted_elements[element_id] = (element, property_id)
        _element_index_remove(model, element)
        del model.elements[element_id]
        del model.element_properties[element_id]
        deleted.append(element_id)
        original_normal = _element_normal(element, model.nodes)
        for node_ids in triangles:
            replacement_normal = unit(cross(_sub(model.nodes[node_ids[1]], model.nodes[node_ids[0]]), _sub(model.nodes[node_ids[2]], model.nodes[node_ids[0]])))
            if dot(original_normal, replacement_normal) <= 0.0:
                node_ids = [node_ids[0], node_ids[2], node_ids[1]]
            new_element_id = _allocate(element_counter)
            model.elements[new_element_id] = Element(new_element_id, source_component_id, "CTRIA3", tuple(node_ids))
            _element_index_add(model, model.elements[new_element_id])
            model.element_properties[new_element_id] = property_id
            created.append(new_element_id)
    return {
        "status": "READY", "node_ids": realized, "created_node_ids": created_nodes,
        "deleted_element_ids": deleted, "created_element_ids": created,
        "_transaction": {
            "node_start": node_start, "element_start": element_start,
            "deleted_elements": deleted_elements,
        },
    }


def _rollback_source_materialization(model, source_materialization, node_counter, element_counter):
    transaction = source_materialization.get("_transaction", {})
    for element_id in source_materialization.get("created_element_ids", []):
        created_element = model.elements.pop(element_id, None)
        if created_element is not None:
            _element_index_remove(model, created_element)
        model.element_properties.pop(element_id, None)
    for element_id, row in transaction.get("deleted_elements", {}).items():
        element, property_id = row
        model.elements[element_id] = element
        _element_index_add(model, element)
        model.element_properties[element_id] = property_id
    for node_id in source_materialization.get("created_node_ids", []):
        model.nodes.pop(node_id, None)
    node_counter[0] = int(transaction.get("node_start", node_counter[0]))
    element_counter[0] = int(transaction.get("element_start", element_counter[0]))


def realize_candidates(model, candidates, settings=None):
    resolved = dict(DEFAULT_SETTINGS)
    if settings:
        resolved.update(settings)
    components = dict(model.components)
    nodes = dict(model.nodes)
    elements = dict(model.elements)
    result = MeshModel(components, nodes, elements)
    result.element_properties = dict(getattr(model, "element_properties", {}))
    result.element_zoffs = dict(getattr(model, "element_zoffs", {}))
    result.element_nodal_thicknesses = dict(getattr(model, "element_nodal_thicknesses", {}))
    result.pshell = dict(getattr(model, "pshell", {}))
    result.materials = dict(getattr(model, "materials", {}))
    # Maintain this index incrementally during planning. Rebuilding it by
    # scanning the entire vehicle for every candidate was a dominant O(C*N)
    # cost on whole-vehicle models.
    result.elements_for_components([])
    _ensure_element_signature_index(result)
    id_state = resolved.get("id_state", {}) or {}
    node_counter = [max(max(nodes) if nodes else 0, int(id_state.get("max_node_id", 0)))]
    element_counter = [max(max(elements) if elements else 0, int(id_state.get("max_element_id", 0)))]
    component_counter = [max(max(components) if components else 0, int(id_state.get("max_component_id", 0)))]
    property_counter = [max(result.pshell) if result.pshell else max(result.element_properties.values(), default=0)]
    reports = []
    for candidate in candidates:
        if not candidate.get("auto_eligible") or candidate.get("candidate_type") not in ("T_SEAM", "PATCH_SEAM"):
            reports.append({"candidate_id": candidate["candidate_id"], "status": "REVIEW_REQUIRED", "created_weld_elements": 0})
            continue
        source_materialization = _materialize_source_path(result, candidate, node_counter, element_counter)
        if source_materialization["status"] != "READY":
            reports.append({"candidate_id": candidate["candidate_id"], "status": "FAILED", "created_weld_elements": 0, "warnings": source_materialization["warnings"]})
            continue
        source_node_ids = source_materialization["node_ids"]
        split = plan_multi_element_split(
            result,
            candidate["target_component_id"],
            source_node_ids,
            closed=bool(candidate.get("closed")),
            settings={
                "search_distance": resolved["search_distance"],
                "max_split_aspect_ratio": resolved["maximum_split_aspect_ratio"],
                "split_tolerance_ratio": 1.0e-6,
            },
            target_points=candidate.get("target_projection_points"),
        )
        if split["status"] != "READY":
            _rollback_source_materialization(result, source_materialization, node_counter, element_counter)
            reports.append({"candidate_id": candidate["candidate_id"], "status": "FAILED", "created_weld_elements": 0, "warnings": split["warnings"]})
            continue
        coordinate_map = dict(split["coordinates"])
        invalid_replacements = []
        replacement_signatures = set()
        replaced_ids = {int(value) for value in split["delete_element_ids"]}
        for index, replacement in enumerate(split["replacement_elements"]):
            node_ids = tuple(int(value) for value in replacement["node_ids"])
            signature = tuple(sorted(node_ids))
            try:
                metrics = element_metrics(node_ids, coordinate_map)
            except (KeyError, ValueError) as exc:
                invalid_replacements.append("replacement {} has unresolved GRID data: {}".format(index, exc))
                continue
            if replacement.get("element_type") not in ("CTRIA3", "CQUAD4"):
                invalid_replacements.append("replacement {} has unsupported shell card".format(index))
            elif signature in replacement_signatures:
                invalid_replacements.append("replacement {} duplicates another planned shell".format(index))
            elif result._element_signature_index.get(signature, set()) - replaced_ids:
                invalid_replacements.append("replacement {} duplicates an existing shell".format(index))
            elif not metrics["valid"]:
                invalid_replacements.append("replacement {} is degenerate".format(index))
            replacement_signatures.add(signature)
        if invalid_replacements:
            _rollback_source_materialization(result, source_materialization, node_counter, element_counter)
            reports.append({"candidate_id": candidate["candidate_id"], "status": "FAILED", "created_weld_elements": 0, "warnings": invalid_replacements})
            continue
        try:
            weld = plan_zipper(
                source_node_ids,
                split["target_node_ids"],
                coordinate_map,
                closed=bool(candidate.get("closed")),
                allow_end_tria=True,
                max_tria_ratio=float(resolved["maximum_weld_triangle_ratio"]),
            )
        except ValueError as exc:
            _rollback_source_materialization(result, source_materialization, node_counter, element_counter)
            reports.append({"candidate_id": candidate["candidate_id"], "status": "FAILED", "created_weld_elements": 0, "warnings": [str(exc)]})
            continue
        quality = validate_weld_elements(weld, coordinate_map, max_aspect_ratio=float(resolved["maximum_weld_aspect_ratio"]))
        continuity = validate_strip_connectivity(weld, source_node_ids, split["target_node_ids"])
        for index, element in enumerate(weld):
            signature = tuple(sorted(int(value) for value in element["node_ids"]))
            if signature in replacement_signatures or result._element_signature_index.get(signature, set()) - replaced_ids:
                quality["passed"] = False
                quality["failed_elements"].append({"index": index, "reason": "weld cell duplicates a retained shell"})
        if not quality["passed"] or not continuity["passed"]:
            warnings = [row["reason"] for row in quality["failed_elements"] + continuity["failed_elements"]]
            _rollback_source_materialization(result, source_materialization, node_counter, element_counter)
            reports.append({"candidate_id": candidate["candidate_id"], "status": "FAILED", "created_weld_elements": 0, "warnings": warnings})
            continue

        placeholder_map = {}
        for node in split["new_nodes"]:
            actual = _allocate(node_counter)
            placeholder_map[int(node["node_id"])] = actual
            nodes[actual] = tuple(float(value) for value in node["coordinates"])
        def remap(node_ids):
            return tuple(placeholder_map.get(int(node_id), int(node_id)) for node_id in node_ids)

        original_connectivity = {
            str(element_id): [int(value) for value in row[0].node_ids]
            for element_id, row in source_materialization.get("_transaction", {}).get("deleted_elements", {}).items()
        }
        for element_id in split["delete_element_ids"]:
            if element_id in elements:
                original_connectivity[str(element_id)] = [int(value) for value in elements[element_id].node_ids]
        for element_id in split["delete_element_ids"]:
            deleted_element = elements.pop(element_id, None)
            if deleted_element is not None:
                _element_index_remove(result, deleted_element)
            result.element_properties.pop(element_id, None)
        created_mother = []
        for replacement in split["replacement_elements"]:
            element_id = _allocate(element_counter)
            node_ids = remap(replacement["node_ids"])
            elements[element_id] = Element(element_id, int(replacement["component_id"]), replacement["element_type"], node_ids)
            _element_index_add(result, elements[element_id])
            result.element_properties[element_id] = int(replacement["property_id"])
            created_mother.append(element_id)

        seam_component_id = _allocate(component_counter)
        source_name = components[candidate["source_component_id"]].component_name
        seam_name = "{}_{}".format(_thickness_name(source_name), candidate["candidate_id"])
        components[seam_component_id] = Component(seam_component_id, seam_name, "SHELL")
        source_property_ids = [result.element_properties.get(element.element_id) for element in result.elements_for_components([candidate["source_component_id"]])]
        # A selected-component HM export can contain valid shell PIDs without
        # exporting the corresponding PSHELL cards.  The property still exists
        # in the live model and is the safest PID for the imported seam.
        source_property_ids = [int(value) for value in source_property_ids if value is not None and int(value) > 0]
        if source_property_ids:
            # Reuse a property that already exists in the live model.  HM2019
            # then imports every weld shell with a valid PID and no separate
            # property/material delta is required.
            seam_property_id = int(source_property_ids[0])
        else:
            seam_property_id = _allocate(property_counter)
            result.pshell[seam_property_id] = {"material_id": 1, "thickness": 1.0}
        created_weld = []
        for planned in weld:
            element_id = _allocate(element_counter)
            node_ids = remap(planned["node_ids"])
            elements[element_id] = Element(element_id, seam_component_id, planned["element_type"], node_ids)
            _element_index_add(result, elements[element_id])
            result.element_properties[element_id] = seam_property_id
            created_weld.append(element_id)
        all_created_nodes = sorted(source_materialization["created_node_ids"] + list(placeholder_map.values()))
        replacement_ids = list(source_materialization["created_element_ids"]) + created_mother
        deleted_ids = list(source_materialization["deleted_element_ids"]) + list(split["delete_element_ids"])
        reports.append({
            "candidate_id": candidate["candidate_id"],
            "status": "CREATED",
            "candidate_type": candidate["candidate_type"],
            "deleted_mother_elements": split["delete_element_ids"],
            "created_mother_elements": created_mother,
            "created_node_ids": all_created_nodes,
            "created_source_node_ids": sorted(source_materialization["created_node_ids"]),
            "created_target_node_ids": sorted(placeholder_map.values()),
            "deleted_source_elements": source_materialization["deleted_element_ids"],
            "created_source_elements": source_materialization["created_element_ids"],
            "created_weld_element_ids": created_weld,
            "created_weld_elements": len(created_weld),
            "seam_component_id": seam_component_id,
            "seam_component_name": seam_name,
            "deleted_element_ids": deleted_ids,
            "original_connectivity": original_connectivity,
            "new_node_rows": [{"node_id": node_id, "coordinates": list(nodes[node_id])} for node_id in all_created_nodes],
            "replacement_element_rows": [_element_row(elements[element_id], result.element_properties.get(element_id, 0)) for element_id in replacement_ids],
            "weld_element_rows": [_element_row(elements[element_id], result.element_properties.get(element_id, 0)) for element_id in created_weld],
        })
    return result, reports


def _element_row(element, property_id=0):
    return {
        "element_id": int(element.element_id),
        "component_id": int(element.component_id),
        "element_type": str(element.element_type),
        "node_ids": [int(value) for value in element.node_ids],
        "property_id": int(property_id),
    }


def plan_candidate_deltas(model, candidates, settings=None):
    """Build sequential, preallocated HM-import plans from the FEM backend.

    Each candidate is realized against the accumulated result so shared-source
    and multi-target cases remain deterministic. HyperMesh owns the final
    neighborhood remesh; Python only identifies replacement-shell seeds and
    seam nodes that the native batch operation must preserve.
    """
    resolved = dict(DEFAULT_SETTINGS)
    if settings:
        resolved.update(settings)
    plans = []
    current, reports = realize_candidates(model, candidates, resolved)
    for candidate, report in zip(candidates, reports):
        transfer_fields = {
            "candidate_type": str(candidate.get("candidate_type", "UNKNOWN")),
            "confidence": float(candidate.get("confidence", 0.0)),
            "auto_eligible": bool(candidate.get("auto_eligible", False)),
            "source_component_id": int(candidate.get("source_component_id", 0)),
            "target_component_id": int(candidate.get("target_component_id", 0)),
            "source_node_ids": [int(value) for value in candidate.get("source_node_ids", [])],
            "target_node_ids": [int(value) for value in candidate.get("target_node_ids", [])],
            "length": float(candidate.get("length", 0.0)),
        }
        if report.get("status") != "CREATED":
            plans.append({
                "candidate_id": candidate["candidate_id"],
                **transfer_fields,
                "mode": "NONE",
                "realization_mode": "NONE",
                "status": "MANUAL_REVIEW" if report.get("status") == "REVIEW_REQUIRED" else "FAILED",
                "warnings": list(report.get("warnings", candidate.get("warnings", []))),
                "move_nodes": [], "delete_element_ids": [], "new_nodes": [],
                "replacement_elements": [], "weld_elements": [], "read_nodes": [],
                "write_nodes": [], "read_elements": [], "delete_elements": [],
                "original_connectivity": {}, "property_id": 0,
            })
            continue
        new_nodes = list(report.get("new_node_rows", []))
        new_node_ids = [int(row["node_id"]) for row in new_nodes]
        deleted_element_ids = [int(value) for value in report.get("deleted_element_ids", [])]
        seam_component_id = int(report["seam_component_id"])
        replacement_elements = list(report.get("replacement_element_rows", []))
        weld_elements = list(report.get("weld_element_rows", []))
        original_connectivity = dict(report.get("original_connectivity", {}))
        read_nodes = sorted({int(value) for node_ids in original_connectivity.values() for value in node_ids})
        plan = {
            "candidate_id": candidate["candidate_id"],
            **transfer_fields,
            "mode": "OFFLINE_IMPRINT_SPLIT",
            "realization_mode": "OFFLINE_IMPRINT_SPLIT",
            "status": "READY",
            "warnings": [],
            "ids_preallocated": True,
            "move_nodes": [],
            "delete_element_ids": deleted_element_ids,
            "new_nodes": new_nodes,
            "replacement_elements": replacement_elements,
            "weld_elements": weld_elements,
            "output_component_id": seam_component_id,
            "output_component_name": str(report["seam_component_name"]),
            "property_id": int(weld_elements[0]["property_id"]) if weld_elements else 0,
            "read_nodes": read_nodes,
            "write_nodes": new_node_ids,
            "read_elements": deleted_element_ids,
            "delete_elements": deleted_element_ids,
            "original_connectivity": original_connectivity,
            "max_new_failed_elements": int(resolved.get("max_new_failed_elements", 0)),
        }
        plans.append(plan)

    ready_plans = [plan for plan in plans if plan["status"] == "READY"]
    remesh_seed_ids = sorted({
        int(element["element_id"])
        for plan in ready_plans
        for element in plan["replacement_elements"]
    })
    protected_node_ids = sorted({
        int(node_id)
        for plan in ready_plans
        for element in plan["weld_elements"]
        for node_id in element["node_ids"]
    }.union({
        int(node["node_id"])
        for plan in ready_plans
        for node in plan["new_nodes"]
    }))
    remesh = {
        "status": "PLANNED" if remesh_seed_ids else "NOT_REQUIRED",
        "seed_element_ids": remesh_seed_ids,
        "protected_node_ids": protected_node_ids,
        "expand_layers": int(resolved.get("remesh_expand_layers", 2)),
        "element_size": float(resolved.get("remesh_element_size", 8.0)),
        "feature_angle": float(resolved.get("remesh_feature_angle", 30.0)),
        "execution_mode": "HYPERMESH_BATCH_AUTOMESH",
    }
    return {
        "schema_version": "1.0",
        "plans": plans,
        "realization_reports": reports,
        "remesh": remesh,
        "result_model": current,
    }


def write_fem_bundle(model, fem_path, manifest_path=None):
    fem_path = Path(fem_path)
    manifest_path = Path(manifest_path) if manifest_path else fem_path.with_suffix(".manifest.json")
    passthrough = {}
    for group in getattr(model, "other_card_lines", []):
        component_id = int(group[0]) if group and group[0] not in ("", None) else 0
        passthrough.setdefault(component_id, []).append(group[1:])
    lines = ["$ HMWF_OFFLINE_AUTO_SEAM_MODEL", "BEGIN BULK"]
    for node_id, coordinates in sorted(model.nodes.items()):
        lines.append("GRID,{},,{:.12g},{:.12g},{:.12g}".format(node_id, *coordinates))
    by_component = {}
    for element in model.elements.values():
        by_component.setdefault(element.component_id, []).append(element)
    component_rows = []
    for component_id, component in sorted(model.components.items()):
        lines.append('$HMNAME COMP {} "{}"'.format(component_id, component.component_name.replace('"', "")))
        lines.append("$HMCOMP ID {}".format(component_id))
        element_ids = []
        for element in sorted(by_component.get(component_id, []), key=lambda row: row.element_id):
            property_id = int(getattr(model, "element_properties", {}).get(element.element_id, 1))
            zoffs = getattr(model, "element_zoffs", {}).get(element.element_id)
            nodal = getattr(model, "element_nodal_thicknesses", {}).get(element.element_id)
            if zoffs is None and not nodal:
                lines.append("{},{},{},{}".format(element.element_type, element.element_id, property_id, ",".join(str(value) for value in element.node_ids)))
            else:
                zoffs_text = "" if zoffs is None else (str(zoffs) if isinstance(zoffs, str) else "{:.12g}".format(float(zoffs)))
                values = [element.element_type, str(element.element_id), str(property_id)]
                values.extend(str(value) for value in element.node_ids)
                values.extend(("", zoffs_text))
                # Fill the first Bulk Data row through column 10, then put Ti
                # in columns 4 onward of the continuation row.
                values.extend("" for _ in range(10 - len(values)))
                lines.append(",".join(values))
                thickness_values = tuple(nodal or ())
                if thickness_values:
                    lines.append("+,,,{}".format(",".join(
                        "" if value is None else "{:.12g}".format(float(value))
                        for value in thickness_values
                    )))
            element_ids.append(element.element_id)
        for group in passthrough.get(component_id, []):
            lines.extend(group)
        component_rows.append({"component_id": component_id, "component_name": component.component_name, "element_ids": element_ids})
    for property_id, values in sorted(getattr(model, "pshell", {}).items()):
        lines.append("PSHELL,{},{},{:.12g}".format(property_id, int(values["material_id"]), float(values["thickness"])))
    materials = getattr(model, "materials", {}) or {1: ["210000", "", "0.3"]}
    for material_id, fields in sorted(materials.items()):
        if isinstance(fields, dict):
            young, poisson = fields.get("young", 210000.0), fields.get("poisson", 0.3)
            lines.append("MAT1,{},{},,{}".format(material_id, young, poisson))
        else:
            lines.append("MAT1,{},{}".format(material_id, ",".join(str(value) for value in fields)))
    for group in passthrough.get(0, []):
        lines.extend(group)
    lines.extend(("ENDDATA", ""))
    fem_path.parent.mkdir(parents=True, exist_ok=True)
    fem_path.write_text("\n".join(lines), encoding="utf-8")
    manifest = {
        "schema_version": "1.0",
        "format": "hm_auto_shell_seam_fem",
        "fem_path": fem_path.name,
        "components": component_rows,
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def write_json(path, data):
    Path(path).write_text(json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
