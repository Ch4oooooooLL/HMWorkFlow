"""Spec-faithful FEM weld recognition evidence for the V2 Python core.

The public rows intentionally retain the legacy fields consumed by Tcl while
adding ordered support runs, physical-skin evidence, hard-gate decisions and
stable reason codes.  This module never mutates the source ``MeshModel``.
"""
from __future__ import annotations

import math
import sys
from collections import defaultdict, deque
from pathlib import Path

try:
    from hmworkflow.mesh_seam_weld.element_projection import cross, dot, norm, unit
except ImportError:
    from element_projection import cross, dot, norm, unit

try:
    from shell_weld_detection import connected_edge_paths
except ImportError:
    COMMON_DIR = Path(__file__).resolve().parents[2] / "hybrid_core" / "python"
    if str(COMMON_DIR) not in sys.path:
        sys.path.insert(0, str(COMMON_DIR))
    from shell_weld_detection import connected_edge_paths


def _sub(first, second):
    return tuple(first[index] - second[index] for index in range(3))


def _add(first, second):
    return tuple(first[index] + second[index] for index in range(3))


def _scale(vector, value):
    return tuple(component * value for component in vector)


def _distance(first, second):
    return norm(_sub(first, second))


def _clamp(value, lower=0.0, upper=1.0):
    return max(lower, min(upper, value))


def _angle(first, second):
    return math.degrees(math.acos(_clamp(abs(dot(first, second)), 0.0, 1.0)))


def _percentile(values, percentile):
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return 0.0
    position = (len(ordered) - 1) * float(percentile)
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def _bounds(points):
    return (
        min(point[0] for point in points), max(point[0] for point in points),
        min(point[1] for point in points), max(point[1] for point in points),
        min(point[2] for point in points), max(point[2] for point in points),
    )


def _bounds_near_point(bounds, point, maximum):
    return all(bounds[axis * 2] - maximum <= point[axis] <= bounds[axis * 2 + 1] + maximum for axis in range(3))


def _canonical(first, second):
    return (first, second) if first < second else (second, first)


class _FacetGrid:
    """Conservative local index for target physical-skin triangles."""

    def __init__(self, facets, cell_size, maximum_cells_per_facet=128):
        self.facets = list(facets)
        self.cell_size = max(float(cell_size), 1.0e-6)
        self.cells = defaultdict(list)
        self.overflow = []
        for index, facet in enumerate(self.facets):
            bounds = facet["bounds"]
            lower = self._key((bounds[0], bounds[2], bounds[4]))
            upper = self._key((bounds[1], bounds[3], bounds[5]))
            count = (upper[0] - lower[0] + 1) * (upper[1] - lower[1] + 1) * (upper[2] - lower[2] + 1)
            if count > maximum_cells_per_facet:
                self.overflow.append(index)
                continue
            for x_index in range(lower[0], upper[0] + 1):
                for y_index in range(lower[1], upper[1] + 1):
                    for z_index in range(lower[2], upper[2] + 1):
                        self.cells[(x_index, y_index, z_index)].append(index)

    def _key(self, point):
        return tuple(int(math.floor(value / self.cell_size)) for value in point)

    def query(self, bounds):
        lower = self._key((bounds[0], bounds[2], bounds[4]))
        upper = self._key((bounds[1], bounds[3], bounds[5]))
        matches = set(self.overflow)
        for x_index in range(lower[0], upper[0] + 1):
            for y_index in range(lower[1], upper[1] + 1):
                for z_index in range(lower[2], upper[2] + 1):
                    matches.update(self.cells.get((x_index, y_index, z_index), ()))
        return [self.facets[index] for index in sorted(matches)]


def _element_edges(element):
    ids = element.node_ids
    for index, first in enumerate(ids):
        second = ids[(index + 1) % len(ids)]
        yield _canonical(first, second), 1 if first < second else -1


def _raw_normal(element, nodes):
    return unit(cross(_sub(nodes[element.node_ids[1]], nodes[element.node_ids[0]]), _sub(nodes[element.node_ids[2]], nodes[element.node_ids[0]])))


def _oriented_shells(model, topologies):
    """Orient normals per connected shell island and expose unsafe topology."""
    result = {}
    for component_id in sorted(topologies):
        elements = sorted(model.elements_for_components([component_id]), key=lambda row: row.element_id)
        incidence = defaultdict(list)
        raw = {}
        for element in elements:
            try:
                raw[element.element_id] = _raw_normal(element, model.nodes)
            except ValueError:
                continue
            for edge, direction in _element_edges(element):
                incidence[edge].append((element.element_id, direction))
        neighbors = defaultdict(list)
        non_manifold = set()
        for edge, owners in incidence.items():
            if len(owners) > 2:
                non_manifold.update(owner[0] for owner in owners)
            elif len(owners) == 2:
                first, second = owners
                # Adjacent consistently oriented shells traverse their common
                # edge in opposite directions.
                relation = -1 if first[1] == second[1] else 1
                neighbors[first[0]].append((second[0], relation))
                neighbors[second[0]].append((first[0], relation))
        signs = {}
        islands = {}
        inconsistent = set()
        island_id = 0
        for seed in sorted(raw):
            if seed in signs:
                continue
            island_id += 1
            signs[seed] = 1
            islands[seed] = island_id
            queue = deque([seed])
            while queue:
                current = queue.popleft()
                for neighbor, relation in neighbors[current]:
                    wanted = signs[current] * relation
                    if neighbor in signs:
                        if signs[neighbor] != wanted:
                            inconsistent.update((current, neighbor))
                        continue
                    signs[neighbor] = wanted
                    islands[neighbor] = island_id
                    queue.append(neighbor)
        result[component_id] = {
            "normal": {element_id: _scale(raw[element_id], signs.get(element_id, 1)) for element_id in raw},
            "island": islands,
            "non_manifold": non_manifold,
            "inconsistent": inconsistent,
        }
    return result


def _base_thickness(model, element_id):
    property_id = getattr(model, "element_properties", {}).get(element_id)
    value = getattr(model, "pshell", {}).get(property_id, {}).get("thickness", 0.0)
    try:
        return max(0.0, float(value))
    except (TypeError, ValueError):
        return 0.0


def _vertex_thicknesses(model, element):
    base = _base_thickness(model, element.element_id)
    raw = getattr(model, "element_nodal_thicknesses", {}).get(element.element_id)
    if not raw:
        return tuple(base for _ in element.node_ids), False
    values = []
    variable = False
    for value in raw:
        if value is None:
            values.append(base)
        else:
            thickness = float(value)
            values.append(max(0.0, thickness))
            variable = variable or abs(thickness - base) > 1.0e-9
    return tuple(values), variable


def _zoffs(model, element, thicknesses):
    value = getattr(model, "element_zoffs", {}).get(element.element_id, 0.0)
    if value == "TOP":
        return tuple(-0.5 * thickness for thickness in thicknesses)
    if value == "BOTTOM":
        return tuple(0.5 * thickness for thickness in thicknesses)
    try:
        return tuple(float(value or 0.0) for _ in thicknesses)
    except (TypeError, ValueError):
        return tuple(0.0 for _ in thicknesses)


def _physical_facets(model, topologies, oriented):
    facets = defaultdict(list)
    component_bounds = {}
    mesh_sizes = defaultdict(list)
    component_thicknesses = defaultdict(list)
    for component_id in sorted(topologies):
        for element in sorted(model.elements_for_components([component_id]), key=lambda row: row.element_id):
            normal = oriented[component_id]["normal"].get(element.element_id)
            if normal is None:
                continue
            thicknesses, variable = _vertex_thicknesses(model, element)
            offsets = _zoffs(model, element, thicknesses)
            ids = element.node_ids
            for index, first in enumerate(ids):
                mesh_sizes[component_id].append(_distance(model.nodes[first], model.nodes[ids[(index + 1) % len(ids)]]))
            component_thicknesses[component_id].extend(thicknesses)
            triangles = ((0, 1, 2),) if len(ids) == 3 else ((0, 1, 2), (0, 2, 3))
            for skin_sign, skin in ((1.0, "TOP"), (-1.0, "BOTTOM")):
                vertices = [
                    _add(model.nodes[node_id], _scale(normal, offsets[index] + skin_sign * 0.5 * thicknesses[index]))
                    for index, node_id in enumerate(ids)
                ]
                for triangle in triangles:
                    points = tuple(vertices[index] for index in triangle)
                    physical_offset = sum(
                        offsets[index] + skin_sign * 0.5 * thicknesses[index]
                        for index in triangle
                    ) / 3.0
                    facets[component_id].append({
                        "element_id": element.element_id,
                        "points": points,
                        "bounds": _bounds(points),
                        "normal": normal,
                        "skin": skin,
                        "thickness": sum(thicknesses[index] for index in triangle) / 3.0,
                        "physical_offset": physical_offset,
                        "variable_thickness": variable,
                        "island_id": oriented[component_id]["island"].get(element.element_id, 0),
                    })
        points = [point for facet in facets[component_id] for point in facet["points"]]
        if points:
            component_bounds[component_id] = _bounds(points)
    mesh_size = {component_id: _percentile(values, 0.5) for component_id, values in mesh_sizes.items()}
    return {
        "facets": facets,
        "bounds": component_bounds,
        "mesh_size": mesh_size,
        "thickness": {component_id: _percentile(values, 0.5) for component_id, values in component_thicknesses.items()},
        "indexes": {
            component_id: _FacetGrid(rows, mesh_size.get(component_id, 1.0))
            for component_id, rows in facets.items() if rows
        },
    }


def build_physical_geometry_context(model, topologies):
    """Build reusable oriented-normal and physical-skin caches."""
    oriented = _oriented_shells(model, topologies)
    return oriented, _physical_facets(model, topologies, oriented)


def _closest_point_triangle(point, first, second, third):
    """Closest point on a triangle (Ericson region tests)."""
    ab, ac, ap = _sub(second, first), _sub(third, first), _sub(point, first)
    d1, d2 = dot(ab, ap), dot(ac, ap)
    if d1 <= 0.0 and d2 <= 0.0:
        return first
    bp = _sub(point, second)
    d3, d4 = dot(ab, bp), dot(ac, bp)
    if d3 >= 0.0 and d4 <= d3:
        return second
    vc = d1 * d4 - d3 * d2
    if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
        return _add(first, _scale(ab, d1 / (d1 - d3)))
    cp = _sub(point, third)
    d5, d6 = dot(ab, cp), dot(ac, cp)
    if d6 >= 0.0 and d5 <= d6:
        return third
    vb = d5 * d2 - d1 * d6
    if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
        return _add(first, _scale(ac, d2 / (d2 - d6)))
    va = d3 * d6 - d5 * d4
    if va <= 0.0 and d4 - d3 >= 0.0 and d5 - d6 >= 0.0:
        return _add(second, _scale(_sub(third, second), (d4 - d3) / ((d4 - d3) + (d5 - d6))))
    denominator = 1.0 / (va + vb + vc)
    return _add(first, _add(_scale(ab, vb * denominator), _scale(ac, vc * denominator)))


def _nearest_hit(point, component_id, geometry, maximum):
    if component_id not in geometry["bounds"] or not _bounds_near_point(geometry["bounds"][component_id], point, maximum):
        return None
    best = None
    query = (point[0] - maximum, point[0] + maximum, point[1] - maximum, point[1] + maximum, point[2] - maximum, point[2] + maximum)
    index = geometry["indexes"].get(component_id)
    candidate_facets = index.query(query) if index is not None else geometry["facets"][component_id]
    for facet in candidate_facets:
        bounds = facet["bounds"]
        if bounds[0] > query[1] or bounds[1] < query[0] or bounds[2] > query[3] or bounds[3] < query[2] or bounds[4] > query[5] or bounds[5] < query[4]:
            continue
        projected = _closest_point_triangle(point, *facet["points"])
        distance = _distance(point, projected)
        key = (distance, facet["element_id"], facet["skin"])
        if distance <= maximum and (best is None or key < best[0]):
            mesh_point = _add(projected, _scale(facet["normal"], -facet["physical_offset"]))
            best = (key, dict(facet, point=projected, mesh_point=mesh_point, distance=distance))
    return best[1] if best else None


def _geometry_tolerance(settings, source_h, target_h, source_t, target_t):
    values = [
        float(settings.get("geometry_abs_floor_mm", 0.5)),
        float(settings.get("geometry_mesh_ratio_auto", 0.35)) * min(max(source_h, 1.0e-9), max(target_h, 1.0e-9)),
    ]
    if source_t > 0.0 and target_t > 0.0:
        values.append(float(settings.get("geometry_thickness_ratio_auto", 0.15)) * min(source_t, target_t))
    return max(values)


def _point_in_polygon_2d(point, polygon):
    inside = False
    for index, first in enumerate(polygon):
        second = polygon[(index + 1) % len(polygon)]
        if (first[1] > point[1]) != (second[1] > point[1]):
            crossing = (
                (second[0] - first[0]) * (point[1] - first[1]) /
                (second[1] - first[1]) + first[0]
            )
            if point[0] < crossing:
                inside = not inside
    return inside


def _polygon_area_2d(polygon):
    return abs(sum(
        first[0] * polygon[(index + 1) % len(polygon)][1] -
        polygon[(index + 1) % len(polygon)][0] * first[1]
        for index, first in enumerate(polygon)
    )) * 0.5


def _classify_boundary_paths(paths, model, owner_by_edge, oriented):
    """Mark closed free-edge paths as OUTER or INNER per shell island.

    Splitting a rectangular/curved loop at corners turns its children into
    open segments, so checking ``segment.closed`` loses the fact that a seam
    came from a slot rim.  Classify the parent loops before segmentation and
    preserve that evidence on every child.
    """
    closed = [path for path in paths if path.get("closed") and not path.get("branched")]
    metadata = []
    for path in closed:
        owners = {
            owner_by_edge.get(_canonical(first, second))
            for first, second in path.get("edge_pairs", [])
        } - {None}
        island_ids = {oriented["island"].get(owner, 0) for owner in owners}
        normals = [oriented["normal"].get(owner) for owner in owners]
        normals = [value for value in normals if value is not None]
        if not normals:
            path["boundary_class"] = "OUTER"
            continue
        average = tuple(sum(value[axis] for value in normals) for axis in range(3))
        drop_axis = max(range(3), key=lambda axis: abs(average[axis]))
        keep_axes = [axis for axis in range(3) if axis != drop_axis]
        polygon = [tuple(model.nodes[node_id][axis] for axis in keep_axes) for node_id in path["node_ids"]]
        metadata.append((path, island_ids, polygon, _polygon_area_2d(polygon)))
    for path, island_ids, polygon, area in metadata:
        path["boundary_class"] = "OUTER"
        for other, other_islands, container, container_area in metadata:
            if other is path or island_ids.isdisjoint(other_islands) or container_area <= area:
                continue
            if all(_point_in_polygon_2d(point, container) for point in polygon):
                path["boundary_class"] = "INNER"
                break
    return paths


def _split_boundary(path, model, owner_by_edge, oriented, settings):
    ids = list(path["node_ids"])
    if len(ids) < 2:
        return []
    closed = bool(path.get("closed"))
    edge_count = len(ids) if closed else len(ids) - 1
    turn_limit = float(settings.get("boundary_split_turn_angle_deg", 30.0))
    # A stamped/curved web may rotate gradually while its complete lower edge
    # remains supported by one face.  Splitting at the historical 20 degrees
    # produced short fragments which then failed the minimum-length gate.
    # Keep a sharp-fold split, but let ordinary formed geometry remain one
    # chain; local source/target angles are still checked at every sample.
    normal_limit = float(settings.get("boundary_split_source_normal_change_deg", 45.0))
    breaks = set()
    if not closed:
        breaks.update((0, len(ids) - 1))
    for index in range(len(ids)):
        if not closed and index in (0, len(ids) - 1):
            continue
        previous = ids[(index - 1) % len(ids)]
        current = ids[index]
        following = ids[(index + 1) % len(ids)]
        try:
            incoming = unit(_sub(model.nodes[current], model.nodes[previous]))
            outgoing = unit(_sub(model.nodes[following], model.nodes[current]))
            turn = math.degrees(math.acos(_clamp(dot(incoming, outgoing), -1.0, 1.0)))
        except ValueError:
            turn = 180.0
        first_owner = owner_by_edge.get(_canonical(previous, current))
        second_owner = owner_by_edge.get(_canonical(current, following))
        normal_change = 0.0
        if first_owner and second_owner:
            first_normal = oriented["normal"].get(first_owner)
            second_normal = oriented["normal"].get(second_owner)
            if first_normal and second_normal:
                normal_change = _angle(first_normal, second_normal)
        if turn > turn_limit or normal_change > normal_limit:
            breaks.add(index)
    if closed and not breaks:
        return [{"node_ids": ids, "closed": True, "parent": path}]
    ordered_breaks = sorted(breaks)
    if closed:
        segments = []
        for position, start in enumerate(ordered_breaks):
            end = ordered_breaks[(position + 1) % len(ordered_breaks)]
            segment = [ids[start]]
            cursor = start
            while cursor != end:
                cursor = (cursor + 1) % len(ids)
                segment.append(ids[cursor])
            if len(segment) >= 2:
                segments.append({"node_ids": segment, "closed": False, "parent": path})
        return segments
    return [
        {"node_ids": ids[start:end + 1], "closed": False, "parent": path}
        for start, end in zip(ordered_breaks, ordered_breaks[1:])
        if end > start
    ]


def _edge_samples(first, second, nodes, source_h):
    length = _distance(nodes[first], nodes[second])
    count = max(2, int(math.ceil(length / max(0.5 * source_h, 1.0e-9))))
    return [
        _add(nodes[first], _scale(_sub(nodes[second], nodes[first]), index / float(count)))
        for index in range(count + 1)
    ]


def _sample_support(point, source_id, source_normal, source_h, source_t, target_ids, geometry, settings):
    configured_search = float(settings.get("search_distance", 12.0))
    search = configured_search * float(settings.get("potential_search_multiplier", 1.25))
    angle_review_min = float(settings.get("t_angle_review_min_deg", max(0.0, float(settings.get("minimum_t_normal_angle", 70.0)) - 5.0)))
    angle_review_max = float(settings.get("t_angle_review_max_deg", 115.0))
    recall_pass = bool(settings.get("t_recall_candidate_pass", False))
    if recall_pass:
        # Broad candidate discovery accepts every non-coplanar generalized T
        # angle.  A visually valid joint may be 40/140 degrees after midsurface
        # extraction, especially on a sloped or curved base.  The small lower
        # bound only separates coplanar PATCH relations from T relations.
        angle_review_min = min(angle_review_min, float(settings.get("t_recall_angle_min_deg", 20.0)))
        angle_review_max = max(angle_review_max, float(settings.get("t_recall_angle_max_deg", 90.0)))
    candidates = []
    for target_id in target_ids:
        target_h = geometry["mesh_size"].get(target_id, source_h)
        target_t = geometry["thickness"].get(target_id, 0.0)
        # A midsurface T joint does not put the two exported midsurface edges
        # at zero distance.  The legitimate construction clearance contains
        # half of both shell thicknesses, plus the setback left for a weld toe
        # / bevel.  Treat that as the local edge-to-face contact envelope.
        bevel_clearance = max(
            float(settings.get("t_bevel_clearance_mm", 2.0)),
            float(settings.get("t_bevel_source_thickness_ratio", 0.50)) * source_t,
            float(settings.get("t_bevel_mesh_ratio", 0.25)) * min(source_h, target_h),
        )
        # ``hit`` is already on the target physical skin, not its midsurface.
        # Therefore the target half-thickness has already been consumed by
        # the projection.  The remaining skin-space allowance is the source
        # half-thickness plus weld-toe/bevel setback.  Expressed midsurface to
        # midsurface this is exactly 0.5*(source_t+target_t)+bevel_clearance.
        contact_envelope = 0.5 * source_t + bevel_clearance
        review_multiplier = float(settings.get("geometry_review_multiplier", 3.0))
        if recall_pass:
            review_multiplier = max(
                review_multiplier, float(settings.get("t_recall_distance_multiplier", 3.0)),
            )
        # ``search_distance`` is a user proximity hint, not a hard thickness
        # ceiling.  Thick midsurface shells can have a legitimate physical
        # contact envelope wider than that fixed value.
        support_search = max(search, contact_envelope * review_multiplier)
        hit = _nearest_hit(point, target_id, geometry, support_search)
        if hit is None:
            continue
        offset = _sub(point, hit["point"])
        normal_distance = abs(dot(offset, hit["normal"]))
        tangential_distance = math.sqrt(max(0.0, hit["distance"] ** 2 - normal_distance ** 2))
        angle = _angle(source_normal, hit["normal"])
        if not angle_review_min <= angle <= angle_review_max:
            continue
        base_tolerance = _geometry_tolerance(
            settings, source_h, target_h,
            source_t, hit["thickness"],
        )
        tolerance = max(base_tolerance, contact_envelope)
        review_tolerance = tolerance * review_multiplier
        # Closest-point projection is clamped to individual triangle edges.
        # On a warped quad, a curved mesh or the outer edge of the target this
        # produces a small tangential residual even when the physical shells
        # meet.  Use the same mesh/thickness-relative geometry tolerance as
        # the normal residual instead of the historical absolute 1e-6 gate.
        # The strict AUTO distance check below still prevents welding a free
        # edge which is materially outside the target footprint.
        tangential_tolerance = max(
            float(settings.get("ray_tolerance", 1.0e-7)) * 100.0,
            float(settings.get("geometry_abs_floor_mm", 0.5)) * 0.1,
            base_tolerance * float(settings.get("t_tangential_tolerance_ratio", 0.10)),
        )
        if recall_pass:
            # At a target boundary, closest-point projection is clamped to
            # mesh edges.  Independent source/target discretizations can then
            # leave a residual of several millimetres even though the visible
            # source edge lies over the bottom face.  Admit up to a fraction
            # of one local element for candidate generation; Create Patch is
            # still limited to the selected target elements.
            tangential_tolerance = max(
                tangential_tolerance,
                float(settings.get("t_recall_tangential_mesh_ratio", 1.0)) * min(source_h, target_h),
            )
        if tangential_distance > tangential_tolerance:
            continue
        if hit["distance"] > review_tolerance:
            continue
        angle_score = 1.0 - abs(90.0 - angle) / 25.0
        score = 0.75 * (1.0 - hit["distance"] / max(review_tolerance, 1.0e-9)) + 0.25 * _clamp(angle_score)
        candidates.append(dict(
            hit, component_id=target_id, angle=angle,
            auto_tolerance=tolerance, tangential_distance=tangential_distance,
            tangential_tolerance=tangential_tolerance,
            score=score,
        ))
    candidates.sort(key=lambda row: (-row["score"], row["distance"], row["component_id"], row["element_id"], row["skin"]))
    return {
        "best": candidates[0] if candidates else None,
        "second": candidates[1] if len(candidates) > 1 else None,
        "candidates": candidates,
    }


def _ordered_reason_codes(values):
    order = [
        "NON_MANIFOLD_REGION", "NORMAL_INCONSISTENT", "BOUNDARY_BRANCH",
        "INNER_BOUNDARY_SOURCE", "SHORT_WELD", "PARTIAL_COVERAGE",
        "TARGET_GAP", "HOLE_INTERRUPTION", "TARGET_AMBIGUITY",
        "DUPLICATE_TARGET_SUPPORT", "ANGLE_BORDERLINE", "SKIN_ERROR_BORDERLINE",
        "PROJECTION_JUMP", "TARGET_NORMAL_JUMP", "CURVED_TARGET", "MULTI_TARGET_UNCERTAIN",
        "MESH_EDITOR_COMPONENT_TRANSITION", "VARIABLE_THICKNESS_UNCERTAIN",
        "BRIDGED_SMALL_GAP", "MULTI_TARGET_CONTINUOUS",
    ]
    unique = set(values)
    return [value for value in order if value in unique] + sorted(unique - set(order))


def _candidate_from_edges(model, source_id, segment, edge_rows, start, end, parent_coverage, parent_gap_reason, source_h, source_t, owner_by_edge, oriented, geometry, settings):
    selected = edge_rows[start:end + 1]
    node_ids = segment["node_ids"][start:end + 2]
    length = sum(row["length"] for row in selected)
    # Select target support at chain level, not independently at every point.
    # A side wall or bracket which wins only at an endpoint must not hijack an
    # otherwise complete edge-to-bottom-face relation.  Genuine multi-target
    # seams retain every target that owns a material fraction of the chain.
    ordered_samples = []
    for edge_index, row in enumerate(selected):
        ordered_samples.extend(row["samples"] if edge_index == 0 else row["samples"][1:])
    best_counts = defaultdict(int)
    near_counts = defaultdict(int)
    ambiguity_window = float(settings.get("ambiguity_auto_min_score_margin", 0.50))
    for sample in ordered_samples:
        if sample.get("best") is not None:
            best_counts[int(sample["best"]["component_id"])] += 1
            best_score = float(sample["best"]["score"])
            for candidate in sample.get("candidates", []):
                if (
                    float(candidate["distance"]) <= float(candidate["auto_tolerance"]) or
                    best_score - float(candidate["score"]) < ambiguity_window
                ):
                    near_counts[int(candidate["component_id"])] += 1
    retained_targets = set()
    if best_counts:
        dominant_target = min(best_counts, key=lambda value: (-best_counts[value], value))
        # Two endpoint hits are a common side-wall/bracket distraction, not a
        # reason to reject the bottom face supporting the rest of the edge.
        # Require at least three samples as well as a material chain fraction.
        minimum_samples = max(
            3,
            int(math.ceil(float(settings.get("t_target_min_support_ratio", 0.12)) * len(ordered_samples))),
        )
        retained_targets = {
            component_id for component_id, count in best_counts.items()
            if count >= minimum_samples
        }
        retained_targets.update(
            component_id for component_id, count in near_counts.items()
            if count >= minimum_samples
        )
        retained_targets.add(dominant_target)
    for sample in [value for row in selected for value in row["samples"]]:
        choices = [
            candidate for candidate in sample.get("candidates", [])
            if int(candidate["component_id"]) in retained_targets
        ]
        sample["best"] = choices[0] if choices else None
        sample["second"] = choices[1] if len(choices) > 1 else None
    all_samples = [sample for row in selected for sample in row["samples"]]
    supported = [sample for sample in all_samples if sample["best"] is not None]
    if not supported:
        return None
    target_ids = []
    for sample in supported:
        target_id = int(sample["best"]["component_id"])
        if target_id not in target_ids:
            target_ids.append(target_id)
    distances = [sample["best"]["distance"] for sample in supported]
    angles = [sample["best"]["angle"] for sample in supported]
    tolerances = [sample["best"]["auto_tolerance"] for sample in supported]
    projections = [sample["best"]["point"] for sample in supported]
    node_projections = []
    for edge_index, row in enumerate(selected):
        endpoint_samples = (row["samples"][0], row["samples"][-1])
        if edge_index == 0 and endpoint_samples[0]["best"] is not None:
            node_projections.append(endpoint_samples[0]["best"]["mesh_point"])
        if endpoint_samples[1]["best"] is not None:
            node_projections.append(endpoint_samples[1]["best"]["mesh_point"])
    if len(node_projections) != len(node_ids):
        node_projections = []
    coverage = len(supported) / float(len(all_samples))
    # AUTO is a property of this contiguous supported subchain.  Coverage of
    # unrelated edges elsewhere on the same outer boundary must not veto it.
    # Real gaps *inside* the seam are carried separately by parent_gap_reason.
    effective_coverage = coverage
    reasons = []
    parent = segment["parent"]
    # T recognition is deliberately edge-local.  The topology or shape of
    # the rest of the source component does not invalidate a complete free
    # edge which is supported by the target face.
    if parent.get("branched"):
        reasons.append("BOUNDARY_BRANCH")
    if parent.get("boundary_class") == "INNER":
        reasons.append("INNER_BOUNDARY_SOURCE")
    if effective_coverage < float(settings.get("t_coverage_auto", 0.98)):
        reasons.append("PARTIAL_COVERAGE")
    if parent_gap_reason:
        reasons.append(parent_gap_reason)
    if length < float(settings.get("minimum_t_length", 15.0)):
        reasons.append("SHORT_WELD")
    angle_auto_min = float(settings.get(
        "t_angle_auto_min_deg", settings.get("minimum_t_normal_angle", 70.0),
    ))
    angle_auto_max = float(settings.get("t_angle_auto_max_deg", 100.0))
    if min(angles) < angle_auto_min or max(angles) > angle_auto_max:
        reasons.append("ANGLE_BORDERLINE")
    if _percentile(distances, 0.95) > _percentile(tolerances, 0.95) or max(distances) > max(tolerances):
        reasons.append("SKIN_ERROR_BORDERLINE")
    ambiguity_margin = 1.0
    alternatives = defaultdict(float)
    ambiguous_samples = 0
    ambiguity_samples_considered = 0
    for sample in supported:
        is_interior = 0 < int(sample.get("edge_sample_index", 0)) < int(sample.get("edge_sample_count", 1)) - 1
        if is_interior:
            ambiguity_samples_considered += 1
        second = sample.get("second")
        if second is None or int(second["component_id"]) == int(sample["best"]["component_id"]):
            continue
        margin = float(sample["best"]["score"]) - float(second["score"])
        ambiguity_margin = min(ambiguity_margin, margin)
        alternatives[int(second["component_id"])] = max(alternatives[int(second["component_id"])], float(second["score"]))
        if is_interior and margin < float(settings.get("ambiguity_auto_min_score_margin", 0.50)):
            ambiguous_samples += 1
    if alternatives and ambiguous_samples / float(max(1, ambiguity_samples_considered)) >= float(settings.get("ambiguity_sample_ratio", 0.25)):
        reasons.append("TARGET_AMBIGUITY")
    # Runs are edge based, preserving component transitions even though Tcl
    # still receives one nodes + components job.
    cumulative = [0.0]
    for row in selected:
        cumulative.append(cumulative[-1] + row["length"])
    support_runs = []
    for index, row in enumerate(selected):
        best_ids = [sample["best"]["component_id"] for sample in row["samples"] if sample["best"] is not None]
        if not best_ids:
            continue
        component_id = min(set(best_ids), key=lambda value: (-best_ids.count(value), value))
        if support_runs and support_runs[-1]["component_id"] == component_id:
            support_runs[-1]["source_s_end"] = cumulative[index + 1]
            support_runs[-1]["source_node_index_end"] = index + 1
        else:
            support_runs.append({
                "component_id": int(component_id),
                "source_s_begin": cumulative[index],
                "source_s_end": cumulative[index + 1],
                "source_node_index_begin": index,
                "source_node_index_end": index + 1,
            })
    unsupported = [index for index, row in enumerate(selected) if not any(sample["best"] is not None for sample in row["samples"])]
    internal_gap = sum(selected[index]["length"] for index in unsupported if 0 < index < len(selected) - 1)
    gap_count = 0
    if unsupported:
        gap_count = 1 + sum(1 for first, second in zip(unsupported, unsupported[1:]) if second != first + 1)
    if internal_gap > 0.0:
        reasons.append("HOLE_INTERRUPTION" if len(target_ids) == 1 else "TARGET_GAP")
    max_normal_variation = 0.0
    max_normal_jump = 0.0
    target_normals = [sample["best"]["normal"] for sample in supported]
    if target_normals:
        reference = target_normals[0]
        max_normal_variation = max(_angle(reference, value) for value in target_normals)
        max_normal_jump = max(
            [_angle(first, second) for first, second in zip(target_normals, target_normals[1:])] or [0.0]
        )
        if max_normal_jump > float(settings.get("target_normal_jump_auto_max_deg", 30.0)):
            reasons.append("TARGET_NORMAL_JUMP")
        if max_normal_variation > float(settings.get("curved_target_auto_max_normal_variation_deg", 12.0)):
            reasons.append("CURVED_TARGET")
    projection_jump = False
    sample_points = [row["point"] for row in all_samples if row["best"] is not None]
    projected_points = [row["best"]["point"] for row in all_samples if row["best"] is not None]
    for first_p, second_p, first_q, second_q in zip(sample_points, sample_points[1:], projected_points, projected_points[1:]):
        source_step = _distance(first_p, second_p)
        if source_step > 1.0e-9 and _distance(first_q, second_q) > float(settings.get("projection_jump_ratio", 2.5)) * source_step + max(tolerances):
            projection_jump = True
            break
    if projection_jump:
        reasons.append("PROJECTION_JUMP")
    if len(target_ids) > 1:
        if internal_gap <= float(settings.get("small_gap_auto_length_over_h", 0.25)) * source_h and not projection_jump:
            reasons.append("MULTI_TARGET_CONTINUOUS")
            reasons.append("MESH_EDITOR_COMPONENT_TRANSITION") if bool(settings.get("review_multi_target_realization", False)) else None
        else:
            reasons.append("MULTI_TARGET_UNCERTAIN")
    source_owner_ids = [owner_by_edge.get(_canonical(first, second)) for first, second in zip(node_ids, node_ids[1:])]
    unsafe_owners = {value for value in source_owner_ids if value}
    if unsafe_owners & oriented["non_manifold"]:
        reasons.append("NON_MANIFOLD_REGION")
    if unsafe_owners & oriented["inconsistent"]:
        reasons.append("NORMAL_INCONSISTENT")
    # Ti is interpolated into the physical-skin facets above, so variable
    # thickness is evidence rather than an automatic downgrade in V2.
    # Global curvature is diagnostic evidence, not a contradiction.  If each
    # local sample meets the angle/skin/continuity gates, a curved supporting
    # face is just as trustworthy as a planar one.
    blocking = set(reasons) - {
        # A branch elsewhere on the component boundary is only diagnostic.
        # The selected supported edge is evaluated from its own owner faces;
        # remote component topology must not veto it.
        "BOUNDARY_BRANCH", "MULTI_TARGET_CONTINUOUS", "BRIDGED_SMALL_GAP", "CURVED_TARGET",
    }
    decision = "AUTO" if not blocking else "REVIEW"
    confidence = _clamp(
        0.35 + 0.25 * effective_coverage + 0.15 * (1.0 - _percentile(distances, 0.95) / max(_percentile(tolerances, 0.95), 1.0e-9)) +
        0.15 * (1.0 - abs(90.0 - sum(angles) / len(angles)) / 25.0) + 0.10 * min(1.0, ambiguity_margin / max(float(settings.get("ambiguity_auto_min_score_margin", 0.40)), 1.0e-9))
    )
    reason_codes = _ordered_reason_codes(reasons)
    focus = tuple(sum(point[axis] for point in projections) / len(projections) for axis in range(3))
    island_ids = {oriented["island"].get(owner_id, 0) for owner_id in unsafe_owners}
    return {
        "candidate_id": "",
        "candidate_type": "T_SEAM",
        "decision": decision,
        "source_component_id": int(source_id),
        "target_component_id": int(target_ids[0]),
        "target_component_ids": target_ids,
        "source_node_ids": [int(value) for value in node_ids],
        "source_edge_pairs": [[int(first), int(second)] for first, second in zip(node_ids, node_ids[1:])],
        "source_path": [{"node_id": int(value), "coordinates": list(model.nodes[value])} for value in node_ids],
        "target_projection_points": [list(point) for point in node_projections],
        "target_hint_element_ids": sorted({sample["best"]["element_id"] for sample in supported}),
        "support_runs": support_runs,
        "closed": False,
        "length": round(length, 9),
        "confidence": round(confidence, 6),
        "projection_coverage": round(effective_coverage, 6),
        "complete_source_edges": coverage >= 1.0 - 1.0e-9,
        "auto_eligible": decision == "AUTO",
        "recognition_status": "TRUSTED" if decision == "AUTO" else "POTENTIAL",
        "status": "AUTO_READY" if decision == "AUTO" else "REVIEW_REQUIRED",
        "distance": {"minimum": min(distances), "average": sum(distances) / len(distances), "maximum": max(distances)},
        "normal_angle": round(sum(angles) / len(angles), 6),
        "reason_codes": reason_codes,
        "reasons": [
            "ordered free-edge chain is supported by exact target physical-skin facets",
            "nearest edge row of a source face fully falling on the target projects completely onto the target",
        ],
        "warnings": reason_codes if decision != "AUTO" else [],
        "source": {
            "component_id": int(source_id), "island_id": min(island_ids) if island_ids else 0,
            "chain_id": 0, "node_ids": [int(value) for value in node_ids], "length": round(length, 9),
        },
        "target": {"component_ids": target_ids, "support_runs": support_runs},
        "geometry": {
            "coverage_ratio": round(effective_coverage, 6),
            "angle_mean_deg": round(sum(angles) / len(angles), 6),
            "angle_max_error_deg": round(max(abs(90.0 - value) for value in angles), 6),
            "skin_error_mean": round(sum(distances) / len(distances), 9),
            "skin_error_p95": round(_percentile(distances, 0.95), 9),
            "skin_error_max": round(max(distances), 9),
            "gap_count": gap_count,
            "max_internal_gap": round(internal_gap, 9),
            "target_normal_variation_deg": round(max_normal_variation, 6),
            "target_normal_jump_deg": round(max_normal_jump, 6),
            "ambiguity_margin": round(ambiguity_margin, 6),
        },
        "review": {
            "primary_reason": reason_codes[0] if reason_codes else "",
            "reason_codes": reason_codes,
            "alternative_targets": [{"component_id": key, "score": round(value, 6)} for key, value in sorted(alternatives.items())],
            "focus_xyz": [round(value, 9) for value in focus],
        },
        "realization": {"mode": "ORIGINAL_TARGET", "execution_level": 0},
    }


def mesh_continuous(source_node_ids, target_node_ids, minimum_ratio=0.5, minimum_nodes=2):
    """True when the source nodes are merged into the target component mesh.

    Shared GRID nodes mean the two components are already connected: the FEM
    transfers load through those nodes, so no weld seam exists there and the
    relation must not become a candidate.
    """
    ids = list(source_node_ids)
    if not ids or not target_node_ids:
        return False
    shared = sum(1 for node_id in ids if node_id in target_node_ids)
    return shared >= max(int(minimum_nodes), int(math.ceil(float(minimum_ratio) * len(ids))))


def _same_target_path_contains(container, fragment):
    """Node overlap alone is not coverage (adjacent edges share a node)."""
    targets = lambda row: set(row.get("target_component_ids", []))
    edges = lambda row: {_canonical(*pair) for pair in row.get("source_edge_pairs", [])}
    fragment_edges = edges(fragment)
    return (targets(container) == targets(fragment) and bool(fragment_edges)
            and fragment_edges <= edges(container))


def detect_t_candidates(
        model, settings, topologies, source_ids=None,
        geometry_context=None, defer_missing_fallback=False):
    """Detect T candidates from ordered free-edge chains and physical skins."""
    recall_pass = bool(settings.get("t_recall_candidate_pass", False))
    recall_first = bool(settings.get("t_recall_first_mode", True))
    if geometry_context is None:
        oriented_all, geometry = build_physical_geometry_context(model, topologies)
    else:
        oriented_all, geometry = geometry_context
    target_ids = sorted(topologies)
    component_nodes = {component_id: topology.node_ids for component_id, topology in topologies.items()}
    rows = []
    chain_serial = 0

    def segment_rows(source_id, segment, oriented, owner_by_edge, active_settings):
        """Candidate rows of one free-edge segment under ``active_settings``.

        Returns ``(rows, supported_fraction)``.  The fraction is the share of
        the segment's edge length that found support.  The caller re-evaluates
        a segment with the broad envelope when the strict pass reported only a
        small fragment of it (see the supplementary pass below).
        """
        ids = segment["node_ids"]
        if len(ids) < 2:
            return [], 0.0
        edge_lengths = [_distance(model.nodes[first], model.nodes[second]) for first, second in zip(ids, ids[1:])]
        source_h = _percentile(edge_lengths, 0.5)
        source_t = geometry["thickness"].get(source_id, 0.0)
        edge_rows = []
        for first, second, edge_length in zip(ids, ids[1:], edge_lengths):
            owner_id = owner_by_edge.get(_canonical(first, second))
            source_normal = oriented["normal"].get(owner_id)
            if source_normal is None:
                samples = []
            else:
                # A target which already shares this edge's GRID nodes is part
                # of the same continuous mesh; the edge is not a weld seam
                # against it and must not be supported by it.
                connected_targets = {
                    component_id for component_id in target_ids
                    if component_id != source_id and
                    mesh_continuous((first, second), component_nodes.get(component_id, ()), 1.0, 2)
                }
                edge_targets = [
                    value for value in target_ids
                    if value != source_id and value not in connected_targets
                ]
                samples = []
                if edge_targets:
                    sample_points = _edge_samples(first, second, model.nodes, source_h)
                    for sample_index, point in enumerate(sample_points):
                        support = _sample_support(point, source_id, source_normal, source_h, source_t, edge_targets, geometry, active_settings)
                        support["point"] = point
                        support["edge_sample_index"] = sample_index
                        support["edge_sample_count"] = len(sample_points)
                        samples.append(support)
            edge_rows.append({"first": first, "second": second, "length": edge_length, "samples": samples})
        supported_flags = [
            bool(row["samples"]) and
            sum(sample["best"] is not None for sample in row["samples"]) / float(len(row["samples"])) >=
            float(active_settings.get("t_edge_review_coverage", 0.67))
            for row in edge_rows
        ]
        if not any(supported_flags):
            return [], 0.0
        parent_coverage = sum(row["length"] for row, supported in zip(edge_rows, supported_flags) if supported) / max(sum(edge_lengths), 1.0e-9)
        internal_unsupported = [
            index for index, supported in enumerate(supported_flags)
            if not supported and any(supported_flags[:index]) and any(supported_flags[index + 1:])
        ]
        parent_gap_reason = ""
        if internal_unsupported:
            left = max(index for index in range(internal_unsupported[0]) if supported_flags[index])
            right = min(index for index in range(internal_unsupported[-1] + 1, len(supported_flags)) if supported_flags[index])
            left_targets = [sample["best"]["component_id"] for sample in edge_rows[left]["samples"] if sample["best"] is not None]
            right_targets = [sample["best"]["component_id"] for sample in edge_rows[right]["samples"] if sample["best"] is not None]
            parent_gap_reason = "HOLE_INTERRUPTION" if set(left_targets) & set(right_targets) else "TARGET_GAP"
        indexes = [index for index, supported in enumerate(supported_flags) if supported]
        groups = []
        start = previous = indexes[0]
        for index in indexes[1:]:
            if index != previous + 1:
                groups.append((start, previous))
                start = index
            previous = index
        groups.append((start, previous))
        produced = []
        for start, end in groups:
            row = _candidate_from_edges(
                model, source_id, segment, edge_rows, start, end, parent_coverage, parent_gap_reason,
                source_h, source_t, owner_by_edge, oriented, geometry, active_settings,
            )
            if row is not None:
                # Length is a creation/quality concern, not evidence that the
                # local edge-to-face relation does not exist.  Keep even short
                # curve fragments as candidates.
                produced.append(row)
        return produced, parent_coverage

    missing_sources = set()
    for source_id in sorted(topologies):
        if source_ids is not None and source_id not in source_ids:
            continue
        topology = topologies[source_id]
        owner_by_edge = {_canonical(first, second): owner for first, second, owner in topology.free_edges}
        oriented = oriented_all[source_id]
        boundaries = connected_edge_paths(topology.free_edges, model.nodes)
        boundaries = _classify_boundary_paths(boundaries, model, owner_by_edge, oriented)
        source_rows = []
        failed_segments = []
        partial_segments = []
        minimum_coverage = float(settings.get("t_recall_min_coverage", 0.5))
        for boundary in boundaries:
            for segment in _split_boundary(boundary, model, owner_by_edge, oriented, settings):
                chain_serial += 1
                produced, supported_fraction = segment_rows(
                    source_id, segment, oriented, owner_by_edge, settings)
                if produced:
                    for row in produced:
                        row["recall_candidate_fallback"] = recall_pass
                        row["source"]["chain_id"] = chain_serial
                    source_rows.extend(produced)
                    if supported_fraction < minimum_coverage:
                        partial_segments.append((segment, chain_serial, produced))
                else:
                    failed_segments.append((segment, chain_serial))
        rows.extend(source_rows)
        if not recall_first or recall_pass:
            continue
        if not source_rows:
            missing_sources.add(source_id)
            continue
        # A component which already has strict rows may still own further
        # weldable free-edge chains (an oblique T beside a square T on the
        # same web).  Re-evaluate the unclaimed chains with the broad envelope.
        # A chain the strict pass covered only below the coverage floor counts
        # as unclaimed too: a grazing fragment (the two nodes where a web's end
        # edge touches the skin) must not hide the full generalized-T seam the
        # same chain makes against its real partner.  Chains the strict pass
        # already reported across the floor are left alone, so a genuine gap
        # split (two supported runs around an element-free void) is never fused
        # back into one continuous row.
        relaxed_settings = dict(settings)
        relaxed_settings["t_recall_candidate_pass"] = True
        relaxed_settings["t_edge_review_coverage"] = float(
            settings.get("t_recall_edge_review_coverage", 0.01)
        )
        for segment, chain_id in failed_segments:
            for row in segment_rows(source_id, segment, oriented, owner_by_edge, relaxed_settings)[0]:
                if float(row.get("projection_coverage", 0.0)) < minimum_coverage:
                    continue
                row["recall_candidate_fallback"] = True
                row["source"]["chain_id"] = chain_id
                rows.append(row)
        for segment, chain_id, strict_rows in partial_segments:
            for row in segment_rows(source_id, segment, oriented, owner_by_edge, relaxed_settings)[0]:
                if float(row.get("projection_coverage", 0.0)) < minimum_coverage:
                    continue
                if any(_same_target_path_contains(other, row) for other in strict_rows):
                    continue  # the strict fragment already reports this chain
                # A complete recalled main edge supersedes its short strict
                # fragment.  Do not execute both against the same mother mesh.
                if float(row.get("projection_coverage", 0.0)) >= 0.98:
                    replaced = [other for other in strict_rows
                                if _same_target_path_contains(row, other)]
                    rows[:] = [other for other in rows
                               if not any(other is old for old in replaced)]
                row["recall_candidate_fallback"] = True
                row["source"]["chain_id"] = chain_id
                rows.append(row)
    # Run the broad, recall-oriented geometry envelope for source components
    # for which the normal detector found no T edge at all.  This prevents
    # relaxed tangential/coverage gates from adding side-edge noise beside
    # already-good seams, while eliminating the field failure mode of
    # returning zero T candidates for an otherwise weldable component.
    if recall_first and not recall_pass and missing_sources and not defer_missing_fallback:
        fallback_settings = dict(settings)
        fallback_settings["t_recall_candidate_pass"] = True
        fallback_settings["t_edge_review_coverage"] = float(
            settings.get("t_recall_edge_review_coverage", 0.01)
        )
        minimum_coverage = float(settings.get("t_recall_min_coverage", 0.5))
        strict_pairs = {
            (int(row["source_component_id"]), int(target_id))
            for row in rows for target_id in row.get("target_component_ids", [])
        }
        fallback_rows = detect_t_candidates(
            model, fallback_settings, topologies, source_ids=missing_sources,
            geometry_context=(oriented_all, geometry),
        )
        rows.extend(
            row for row in fallback_rows
            if float(row.get("projection_coverage", 0.0)) >= minimum_coverage
            and not any(
                (int(target_id), int(row["source_component_id"])) in strict_pairs
                for target_id in row.get("target_component_ids", [])
            )
        )
    return rows


def enrich_non_t_candidate(row, model, settings, topologies):
    """Add the V2 schema/hard-gate vocabulary to existing PATCH review rows."""
    row = dict(row)
    reason_codes = list(row.get("reason_codes", []))
    boundary_class = str(row.get("boundary_class", "OUTER"))
    if boundary_class == "INNER":
        policy = str(settings.get("patch_inner_loop_policy", "auto_all")).lower()
        if policy != "auto_all":
            reason_codes.append("INNER_BOUNDARY_SOURCE")
    warning_text = " ".join(str(value).lower() for value in row.get("warnings", []))
    if "hole" in warning_text:
        reason_codes.append("HOLE_INTERRUPTION")
    if row.get("ambiguous_relation"):
        reason_codes.append("TARGET_AMBIGUITY")
    if not row.get("auto_eligible") and not reason_codes:
        reason_codes.append("WELD_TYPE_AMBIGUITY")
    target_ids = [int(value) for value in row.get("target_component_ids", [row.get("target_component_id", 0)]) if int(value) > 0]
    length = float(row.get("length", 0.0))
    support_runs = [{
        "component_id": target_ids[0], "source_s_begin": 0.0, "source_s_end": length,
        "source_node_index_begin": 0, "source_node_index_end": max(0, len(row.get("source_node_ids", [])) - 1),
    }] if target_ids else []
    decision = "AUTO" if row.get("auto_eligible") and not reason_codes else "REVIEW"
    row.update({
        "decision": decision,
        "target_component_ids": target_ids,
        "support_runs": support_runs,
        "reason_codes": _ordered_reason_codes(reason_codes),
        "auto_eligible": decision == "AUTO",
        "recognition_status": "TRUSTED" if decision == "AUTO" else "POTENTIAL",
        "status": "AUTO_READY" if decision == "AUTO" else "REVIEW_REQUIRED",
        "target": {"component_ids": target_ids, "support_runs": support_runs},
    })
    row["source"] = {
        "component_id": int(row.get("source_component_id", 0)), "island_id": 0, "chain_id": 0,
        "node_ids": [int(value) for value in row.get("source_node_ids", [])], "length": length,
    }
    row.setdefault("geometry", {
        "coverage_ratio": float(row.get("projection_coverage", 1.0)),
        "angle_mean_deg": float(row.get("normal_angle", 0.0)),
        "skin_error_mean": float(row.get("distance", {}).get("average", 0.0)),
        "skin_error_p95": float(row.get("distance", {}).get("maximum", 0.0)),
        "skin_error_max": float(row.get("distance", {}).get("maximum", 0.0)),
        "gap_count": 0, "max_internal_gap": 0.0, "target_normal_variation_deg": 0.0,
        "target_normal_jump_deg": 0.0,
        "ambiguity_margin": 0.0 if row.get("ambiguous_relation") else 1.0,
    })
    row["review"] = {
        "primary_reason": row["reason_codes"][0] if row["reason_codes"] else "",
        "reason_codes": row["reason_codes"], "alternative_targets": [],
        "focus_xyz": list(row.get("center", (0.0, 0.0, 0.0))),
    }
    row["realization"] = {"mode": "ORIGINAL_TARGET", "execution_level": 0}
    return row
