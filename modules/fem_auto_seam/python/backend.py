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
import re
from pathlib import Path

try:
    from hmworkflow.core.mesh_model import Component, Element, MeshModel
except ImportError:
    from mesh_model import Component, Element, MeshModel

try:
    from hmworkflow.mesh_seam_weld.element_projection import angle_degrees, cross, dot, norm, unit
    from hmworkflow.mesh_seam_weld.local_split_planner import _plane, _project, _triangulate
    from .multi_element_split_planner import plan_multi_element_split
    from hmworkflow.mesh_seam_weld.quality_guard import element_metrics, validate_strip_connectivity, validate_weld_elements
    from .seam_neighborhood_optimizer import optimize_seam_neighborhood
    from hmworkflow.mesh_seam_weld.shell_topology import build as build_topology
    from hmworkflow.mesh_seam_weld.weld_strip_planner import plan_zipper
except ImportError:
    from element_projection import angle_degrees, cross, dot, norm, unit
    from local_split_planner import _plane, _project, _triangulate
    from multi_element_split_planner import plan_multi_element_split
    from quality_guard import element_metrics, validate_strip_connectivity, validate_weld_elements
    from seam_neighborhood_optimizer import optimize_seam_neighborhood
    from shell_topology import build as build_topology
    from weld_strip_planner import plan_zipper

try:
    from shell_weld_detection import connected_edge_paths
except ImportError:
    from hmworkflow.hybrid_core.shell_weld_detection import connected_edge_paths


DEFAULT_SETTINGS = {
    "search_distance": 10.0,
    "minimum_t_length": 15.0,
    "minimum_patch_length": 15.0,
    "minimum_t_normal_angle": 30.0,
    "maximum_patch_normal_angle": 15.0,
    "maximum_distance_variation_ratio": 0.35,
    "ray_tolerance": 1.0e-7,
    "near_edge_distance": 8.0,
    "near_edge_tangent_angle": 20.0,
    "small_hole_diameter": 30.0,
    "maximum_split_aspect_ratio": 100.0,
    "maximum_weld_aspect_ratio": 100.0,
    "maximum_weld_triangle_ratio": 0.75,
}


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


def _triangle_hit(point, direction, triangle, nodes, maximum, tolerance):
    a, b, c = (nodes[node_id] for node_id in triangle)
    normal = cross(_sub(b, a), _sub(c, a))
    denominator = dot(normal, direction)
    if abs(denominator) <= tolerance:
        return None
    ray_parameter = dot(normal, _sub(a, point)) / denominator
    if ray_parameter < -tolerance or ray_parameter > maximum + tolerance:
        return None
    hit = _add(point, _scale(direction, ray_parameter))
    v0, v1, v2 = _sub(b, a), _sub(c, a), _sub(hit, a)
    d00, d01, d11 = dot(v0, v0), dot(v0, v1), dot(v1, v1)
    determinant = d00 * d11 - d01 * d01
    if abs(determinant) <= tolerance:
        return None
    v = (d11 * dot(v2, v0) - d01 * dot(v2, v1)) / determinant
    w = (d00 * dot(v2, v1) - d01 * dot(v2, v0)) / determinant
    u = 1.0 - v - w
    if min(u, v, w) < -tolerance:
        return None
    return {"point": hit, "distance": max(0.0, ray_parameter), "normal": unit(normal)}


def _ray_hit_element(point, direction, element, nodes, maximum, tolerance):
    ids = element.node_ids
    triangles = (ids[:3],) if len(ids) == 3 else ((ids[0], ids[1], ids[2]), (ids[0], ids[2], ids[3]))
    hits = []
    for triangle in triangles:
        hit = _triangle_hit(point, direction, triangle, nodes, maximum, tolerance)
        if hit is not None:
            hits.append(hit)
    return min(hits, key=lambda row: row["distance"]) if hits else None


def _ray_hits_component(point, direction, elements, nodes, maximum, tolerance):
    hits = []
    for element in elements:
        hit = _ray_hit_element(point, direction, element, nodes, maximum, tolerance)
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


def _edge_hit_intervals(first, second, direction, target_elements, nodes, maximum, tolerance, samples=17):
    def hit_at(parameter):
        point = _add(nodes[first], _scale(_sub(nodes[second], nodes[first]), parameter))
        return _ray_hits_component(point, direction, target_elements, nodes, maximum, tolerance)

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


def _t_candidates(model, settings, topologies):
    maximum = float(settings["search_distance"])
    tolerance = float(settings["ray_tolerance"])
    minimum_angle = float(settings["minimum_t_normal_angle"])
    by_component = {component_id: sorted(model.elements_for_components([component_id]), key=lambda row: row.element_id) for component_id in topologies}
    rows = []
    for source_id, source_topology in sorted(topologies.items()):
        owner_by_id = {element.element_id: element for element in by_component[source_id]}
        owner_by_edge = {tuple(sorted((first, second))): owner_id for first, second, owner_id in source_topology.free_edges}
        source_paths = connected_edge_paths(source_topology.free_edges, model.nodes)
        for target_id, target_elements in by_component.items():
            if target_id == source_id:
                continue
            target_normal = _component_normal(target_elements, model.nodes)
            if target_normal is None:
                continue
            for boundary in source_paths:
                if boundary["branched"]:
                    continue
                path_nodes = boundary["node_ids"]
                path_pairs = list(zip(path_nodes, path_nodes[1:]))
                if boundary["closed"]:
                    path_pairs.append((path_nodes[-1], path_nodes[0]))
                intervals = []
                contexts = {}
                for edge_index, (first, second) in enumerate(path_pairs):
                    owner = owner_by_id.get(owner_by_edge.get(tuple(sorted((first, second)))))
                    if owner is None:
                        continue
                    try:
                        direction, source_normal = _edge_outward_direction((first, second), owner, model.nodes)
                    except ValueError:
                        continue
                    normal_angle = angle_degrees(source_normal, target_normal)
                    if normal_angle < minimum_angle:
                        continue
                    edge_intervals, hit_at = _edge_hit_intervals(first, second, direction, target_elements, model.nodes, maximum, tolerance)
                    contexts[edge_index] = {"first": first, "second": second, "hit_at": hit_at, "angle": normal_angle}
                    for interval in edge_intervals:
                        row = dict(interval)
                        row.update({"start": edge_index + interval["start"], "end": edge_index + interval["end"], "edge_index": edge_index})
                        intervals.append(row)
                if not intervals:
                    continue
                intervals.sort(key=lambda row: (row["start"], row["end"]))
                groups = []
                for interval in intervals:
                    if groups and interval["start"] <= groups[-1]["end"] + 2.0e-6:
                        groups[-1]["end"] = max(groups[-1]["end"], interval["end"])
                        groups[-1]["intervals"].append(interval)
                    else:
                        groups.append({"start": interval["start"], "end": interval["end"], "intervals": [interval]})
                path_limit = float(len(path_pairs))
                if boundary["closed"] and len(groups) > 1 and groups[0]["start"] <= 2.0e-6 and groups[-1]["end"] >= path_limit - 2.0e-6:
                    wrapped = {"start": groups[-1]["start"], "end": groups[0]["end"] + path_limit, "intervals": groups[-1]["intervals"] + groups[0]["intervals"]}
                    groups = [wrapped] + groups[1:-1]

                def source_point(parameter):
                    normalized = parameter % path_limit if boundary["closed"] else min(parameter, path_limit)
                    if not boundary["closed"] and normalized >= path_limit:
                        return model.nodes[path_nodes[-1]], path_nodes[-1], len(path_pairs) - 1, 1.0
                    edge_index = min(int(math.floor(normalized)), len(path_pairs) - 1)
                    local = normalized - edge_index
                    first, second = path_pairs[edge_index]
                    point = _add(model.nodes[first], _scale(_sub(model.nodes[second], model.nodes[first]), local))
                    node_id = first if local <= 2.0e-6 else (second if 1.0 - local <= 2.0e-6 else 0)
                    return point, node_id, edge_index, local

                for group in groups:
                    values = [group["start"]]
                    values.extend(float(value) for value in range(int(math.floor(group["start"])) + 1, int(math.ceil(group["end"]))) if group["start"] + 2.0e-6 < value < group["end"] - 2.0e-6)
                    values.append(group["end"])
                    source_path = []
                    target_points = []
                    distances = []
                    target_elements_used = set()
                    valid = True
                    for value in values:
                        point, node_id, edge_index, local = source_point(value)
                        context = contexts.get(edge_index)
                        hit = context["hit_at"](local) if context is not None else None
                        if hit is None and local <= 2.0e-6:
                            previous = (edge_index - 1) % len(path_pairs)
                            previous_context = contexts.get(previous)
                            hit = previous_context["hit_at"](1.0) if previous_context is not None else None
                        if hit is None:
                            valid = False
                            break
                        source_path.append({"node_id": node_id, "coordinates": list(point)})
                        target_points.append(list(hit["point"]))
                        distances.append(hit["distance"])
                        target_elements_used.add(hit["element_id"])
                    if not valid or len(source_path) < 2:
                        continue
                    length = sum(_distance(tuple(source_path[index]["coordinates"]), tuple(source_path[index + 1]["coordinates"])) for index in range(len(source_path) - 1))
                    average = sum(distances) / len(distances)
                    variation = (max(distances) - min(distances)) / max(average, 1.0e-9)
                    angles = [contexts[index]["angle"] for index in {source_point(value)[2] for value in values} if index in contexts]
                    angle = sum(angles) / len(angles) if angles else minimum_angle
                    auto = length >= float(settings["minimum_t_length"]) and variation <= float(settings["maximum_distance_variation_ratio"])
                    involved_edges = []
                    for interval in group["intervals"]:
                        context = contexts[interval["edge_index"]]
                        involved_edges.append([context["first"], context["second"]])
                    rows.append({
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
                        "auto_eligible": auto,
                        "status": "AUTO_READY" if auto else "REVIEW_REQUIRED",
                        "distance": {"minimum": min(distances), "average": average, "maximum": max(distances)},
                        "normal_angle": round(angle, 6),
                        "reasons": ["source free-edge extension intersects a continuous target shell region"],
                        "warnings": [] if auto else ["T candidate does not pass automatic hard gates"],
                    })
    return rows


def _component_area(elements, nodes):
    return sum(_element_area(element, nodes) for element in elements)


def _bidirectional_hit(point, normal, elements, nodes, maximum, tolerance):
    hits = []
    for direction in (normal, tuple(-value for value in normal)):
        hit = _ray_hits_component(point, direction, elements, nodes, maximum, tolerance)
        if hit is not None:
            hits.append(hit)
    return min(hits, key=lambda row: (row["distance"], row["element_id"])) if hits else None


def _patch_candidates(model, settings, topologies):
    maximum = float(settings["search_distance"])
    tolerance = float(settings["ray_tolerance"])
    maximum_angle = float(settings["maximum_patch_normal_angle"])
    by_component = {component_id: sorted(model.elements_for_components([component_id]), key=lambda row: row.element_id) for component_id in topologies}
    rows = []
    component_ids = sorted(by_component)
    for index, first_id in enumerate(component_ids):
        for second_id in component_ids[index + 1:]:
            first_elements, second_elements = by_component[first_id], by_component[second_id]
            first_normal = _component_normal(first_elements, model.nodes)
            second_normal = _component_normal(second_elements, model.nodes)
            if first_normal is None or second_normal is None:
                continue
            angle = angle_degrees(first_normal, second_normal)
            if angle > maximum_angle:
                continue
            first_area, second_area = _component_area(first_elements, model.nodes), _component_area(second_elements, model.nodes)
            if abs(first_area - second_area) <= max(first_area, second_area) * 0.02:
                continue
            source_id, target_id = (first_id, second_id) if first_area < second_area else (second_id, first_id)
            source_elements, target_elements = by_component[source_id], by_component[target_id]
            target_normal = _component_normal(target_elements, model.nodes)
            source_nodes = sorted(topologies[source_id].node_ids)
            node_hits = [_bidirectional_hit(model.nodes[node_id], target_normal, target_elements, model.nodes, maximum, tolerance) for node_id in source_nodes]
            containment_points = [model.nodes[node_id] for node_id in source_nodes]
            containment_points.extend(_midpoint(model.nodes[first], model.nodes[second]) for first, second, _ in topologies[source_id].free_edges)
            containment_points.extend(tuple(sum(model.nodes[node_id][axis] for node_id in element.node_ids) / len(element.node_ids) for axis in range(3)) for element in source_elements)
            hits = [_bidirectional_hit(point, target_normal, target_elements, model.nodes, maximum, tolerance) for point in containment_points]
            if any(hit is None for hit in hits) or any(hit is None for hit in node_hits):
                continue
            distances = [hit["distance"] for hit in hits]
            hit_by_node = {node_id: hit for node_id, hit in zip(source_nodes, node_hits)}
            average = sum(distances) / len(distances)
            variation = (max(distances) - min(distances)) / max(average, 1.0e-9)
            paths = connected_edge_paths(topologies[source_id].free_edges, model.nodes)
            closed_paths = [path for path in paths if path["closed"] and not path["branched"]]
            if not closed_paths:
                continue
            outer = max(closed_paths, key=lambda row: row["length"])
            inner = [path for path in closed_paths if path is not outer]
            hole_rows = [{"length": path["length"], "equivalent_diameter": path["length"] / math.pi, "node_ids": path["node_ids"]} for path in inner]
            small_holes = [row for row in hole_rows if row["equivalent_diameter"] < float(settings["small_hole_diameter"])]
            group_id = "PATCH_{}_{}".format(source_id, target_id)
            group_auto = not small_holes and variation <= float(settings["maximum_distance_variation_ratio"])
            for path_index, path in enumerate(closed_paths, 1):
                length = _path_length(path["node_ids"], model.nodes, True)
                auto = group_auto and length >= float(settings["minimum_patch_length"])
                confidence = _candidate_confidence(1.0, variation, max(0.0, 1.0 - angle / max(maximum_angle, 1.0)))
                warnings = []
                if small_holes:
                    warnings.append("patch contains an internal hole below the automatic diameter limit")
                rows.append({
                    "candidate_id": "",
                    "candidate_type": "PATCH_SEAM",
                    "patch_group_id": group_id,
                    "patch_loop_index": path_index,
                    "source_component_id": source_id,
                    "target_component_id": target_id,
                    "source_node_ids": path["node_ids"],
                    "source_edge_pairs": path["edge_pairs"],
                    "target_hint_element_ids": sorted({hit["element_id"] for hit in hits}),
                    "target_projection_points": [list(hit_by_node[node_id]["point"]) for node_id in path["node_ids"]],
                    "closed": True,
                    "length": round(length, 9),
                    "confidence": confidence,
                    "auto_eligible": auto,
                    "status": "AUTO_READY" if auto else "REVIEW_REQUIRED",
                    "distance": {"minimum": min(distances), "average": average, "maximum": max(distances)},
                    "normal_angle": round(angle, 6),
                    "hole_summary": hole_rows,
                    "reasons": ["smaller parallel shell is fully projected inside a larger target shell"],
                    "warnings": warnings if warnings else ([] if auto else ["patch candidate does not pass automatic hard gates"]),
                })
    return rows


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
    for index, first_id in enumerate(component_ids):
        for second_id in component_ids[index + 1:]:
            matched = []
            for first_a, first_b, owner in topologies[first_id].free_edges:
                first_vector = _sub(model.nodes[first_b], model.nodes[first_a])
                if norm(first_vector) <= 1.0e-12:
                    continue
                best = None
                for second_a, second_b, _ in topologies[second_id].free_edges:
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


def detect_candidates(model, settings=None):
    resolved = dict(DEFAULT_SETTINGS)
    if settings:
        resolved.update(settings)
    topologies = build_topology(model)
    candidates = _t_candidates(model, resolved, topologies)
    candidates.extend(_patch_candidates(model, resolved, topologies))
    candidates.extend(_near_edge_candidates(model, resolved, topologies))
    candidates.sort(key=lambda row: (row["candidate_type"], row["source_component_id"], row["target_component_id"], tuple(row["source_node_ids"])))
    for index, row in enumerate(candidates, 1):
        row["candidate_id"] = "B{:06d}".format(index)
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
    topology = build_topology(model).get(source_component_id)
    if topology is None:
        return {"status": "FAILED", "warnings": ["source component topology is unavailable"]}
    element_insertions = {}
    realized = []
    created_nodes = []
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
            return {"status": "FAILED", "warnings": ["partial T endpoint is not inside one unique source free edge"]}
        owner_id, first, second, parameter = matches[0]
        node_id = _allocate(node_counter)
        model.nodes[node_id] = point
        point_nodes[key] = node_id
        created_nodes.append(node_id)
        element_insertions.setdefault(owner_id, {}).setdefault(tuple(sorted((first, second))), []).append(node_id)
        realized.append(node_id)

    deleted, created = [], []
    for element_id, edge_insertions in sorted(element_insertions.items()):
        element = model.elements.get(element_id)
        if element is None:
            return {"status": "FAILED", "warnings": ["source mother shell became stale during boundary insertion"]}
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
            return {"status": "FAILED", "warnings": [str(exc)]}
        property_id = int(model.element_properties[element_id])
        original_area = element_metrics(element.node_ids, model.nodes)["area"]
        replacement_area = sum(element_metrics(node_ids, model.nodes)["area"] for node_ids in triangles)
        if original_area <= 0.0 or abs(replacement_area - original_area) / original_area > 1.0e-7:
            return {"status": "FAILED", "warnings": ["source boundary insertion does not preserve mother-shell area"]}
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
            model.element_properties[new_element_id] = property_id
            created.append(new_element_id)
    if hasattr(model, "_elements_by_component"):
        delattr(model, "_elements_by_component")
    return {"status": "READY", "node_ids": realized, "created_node_ids": created_nodes, "deleted_element_ids": deleted, "created_element_ids": created}


def realize_candidates(model, candidates, settings=None):
    resolved = dict(DEFAULT_SETTINGS)
    if settings:
        resolved.update(settings)
    components = dict(model.components)
    nodes = dict(model.nodes)
    elements = dict(model.elements)
    result = MeshModel(components, nodes, elements)
    result.element_properties = dict(getattr(model, "element_properties", {}))
    result.pshell = dict(getattr(model, "pshell", {}))
    result.materials = dict(getattr(model, "materials", {}))
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
        snapshot = {
            "components": dict(components), "nodes": dict(nodes), "elements": dict(elements),
            "element_properties": dict(result.element_properties), "pshell": dict(result.pshell),
            "counters": (node_counter[0], element_counter[0], component_counter[0], property_counter[0]),
        }
        def restore_snapshot():
            components.clear(); components.update(snapshot["components"])
            nodes.clear(); nodes.update(snapshot["nodes"])
            elements.clear(); elements.update(snapshot["elements"])
            result.element_properties.clear(); result.element_properties.update(snapshot["element_properties"])
            result.pshell.clear(); result.pshell.update(snapshot["pshell"])
            node_counter[0], element_counter[0], component_counter[0], property_counter[0] = snapshot["counters"]
            if hasattr(result, "_elements_by_component"):
                delattr(result, "_elements_by_component")

        source_materialization = _materialize_source_path(result, candidate, node_counter, element_counter)
        if source_materialization["status"] != "READY":
            restore_snapshot()
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
            restore_snapshot()
            reports.append({"candidate_id": candidate["candidate_id"], "status": "FAILED", "created_weld_elements": 0, "warnings": split["warnings"]})
            continue
        coordinate_map = dict(split["coordinates"])
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
            restore_snapshot()
            reports.append({"candidate_id": candidate["candidate_id"], "status": "FAILED", "created_weld_elements": 0, "warnings": [str(exc)]})
            continue
        quality = validate_weld_elements(weld, coordinate_map, max_aspect_ratio=float(resolved["maximum_weld_aspect_ratio"]))
        continuity = validate_strip_connectivity(weld, source_node_ids, split["target_node_ids"])
        if not quality["passed"] or not continuity["passed"]:
            warnings = [row["reason"] for row in quality["failed_elements"] + continuity["failed_elements"]]
            restore_snapshot()
            reports.append({"candidate_id": candidate["candidate_id"], "status": "FAILED", "created_weld_elements": 0, "warnings": warnings})
            continue

        placeholder_map = {}
        for node in split["new_nodes"]:
            actual = _allocate(node_counter)
            placeholder_map[int(node["node_id"])] = actual
            nodes[actual] = tuple(float(value) for value in node["coordinates"])
        def remap(node_ids):
            return tuple(placeholder_map.get(int(node_id), int(node_id)) for node_id in node_ids)

        for element_id in split["delete_element_ids"]:
            elements.pop(element_id, None)
            result.element_properties.pop(element_id, None)
        created_mother = []
        for replacement in split["replacement_elements"]:
            element_id = _allocate(element_counter)
            node_ids = remap(replacement["node_ids"])
            elements[element_id] = Element(element_id, int(replacement["component_id"]), replacement["element_type"], node_ids)
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
            result.element_properties[element_id] = seam_property_id
            created_weld.append(element_id)
        if hasattr(result, "_elements_by_component"):
            delattr(result, "_elements_by_component")
        reports.append({
            "candidate_id": candidate["candidate_id"],
            "status": "CREATED",
            "candidate_type": candidate["candidate_type"],
            "deleted_mother_elements": split["delete_element_ids"],
            "created_mother_elements": created_mother,
            "created_node_ids": sorted(source_materialization["created_node_ids"] + list(placeholder_map.values())),
            "created_source_node_ids": sorted(source_materialization["created_node_ids"]),
            "created_target_node_ids": sorted(placeholder_map.values()),
            "deleted_source_elements": source_materialization["deleted_element_ids"],
            "created_source_elements": source_materialization["created_element_ids"],
            "created_weld_element_ids": created_weld,
            "created_weld_elements": len(created_weld),
            "seam_component_id": seam_component_id,
            "seam_component_name": seam_name,
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


def plan_candidate_deltas(model, candidates, settings=None, criteria_path=None, param_path=None):
    """Build sequential, preallocated HM-import plans from the FEM backend.

    Each candidate is realized against the accumulated result so shared-source
    and multi-target cases remain deterministic.  Optional neighborhood moves
    are attached to the final ready plan and therefore execute only after all
    preceding topology deltas have been applied.
    """
    resolved = dict(DEFAULT_SETTINGS)
    if settings:
        resolved.update(settings)
    current = model
    plans = []
    reports = []
    for candidate in candidates:
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
        before = current
        after, candidate_reports = realize_candidates(before, [candidate], resolved)
        report = candidate_reports[0]
        reports.append(report)
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
        new_node_ids = sorted(set(after.nodes).difference(before.nodes))
        deleted_element_ids = sorted(set(before.elements).difference(after.elements))
        new_element_ids = sorted(set(after.elements).difference(before.elements))
        seam_component_id = int(report["seam_component_id"])
        replacement_elements = []
        weld_elements = []
        for element_id in new_element_ids:
            element = after.elements[element_id]
            row = _element_row(element, getattr(after, "element_properties", {}).get(element_id, 0))
            if element.component_id == seam_component_id:
                weld_elements.append(row)
            else:
                replacement_elements.append(row)
        original_connectivity = {
            str(element_id): [int(value) for value in before.elements[element_id].node_ids]
            for element_id in deleted_element_ids
        }
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
            "new_nodes": [{"node_id": node_id, "coordinates": list(after.nodes[node_id])} for node_id in new_node_ids],
            "replacement_elements": replacement_elements,
            "weld_elements": weld_elements,
            "output_component_id": seam_component_id,
            "output_component_name": str(report["seam_component_name"]),
            "property_id": int(weld_elements[0]["property_id"]) if weld_elements else 0,
            "read_nodes": sorted({value for element_id in deleted_element_ids for value in before.elements[element_id].node_ids}),
            "write_nodes": new_node_ids,
            "read_elements": deleted_element_ids,
            "delete_elements": deleted_element_ids,
            "original_connectivity": original_connectivity,
            "max_new_failed_elements": int(resolved.get("max_new_failed_elements", 0)),
        }
        plans.append(plan)
        current = after

    optimization = {"status": "DISABLED", "moves": []}
    ready_plans = [plan for plan in plans if plan["status"] == "READY"]
    if ready_plans and bool(resolved.get("optimize_neighborhood", True)):
        before_coordinates = dict(current.nodes)
        optimization = optimize_seam_neighborhood(
            current,
            reports,
            criteria_path,
            param_path,
            layers=int(resolved.get("optimization_layers", 2)),
            iterations=int(resolved.get("optimization_iterations", 4)),
            settings={"maximum_node_move": resolved.get("optimization_max_node_move", None)} if resolved.get("optimization_max_node_move") is not None else {},
        )
        if optimization.get("moves"):
            last = ready_plans[-1]
            last["move_nodes"] = list(optimization["moves"])
            moved_ids = sorted(int(row["node_id"]) for row in optimization["moves"])
            last["read_nodes"] = sorted(set(last["read_nodes"]).union(moved_ids))
            last["write_nodes"] = sorted(set(last["write_nodes"]).union(moved_ids))
            # Moves must describe the coordinates present after earlier plans,
            # not coordinates already changed in the final in-memory result.
            for move in last["move_nodes"]:
                move["from"] = list(before_coordinates[int(move["node_id"])])
    return {
        "schema_version": "1.0",
        "plans": plans,
        "realization_reports": reports,
        "optimization": optimization,
        "result_model": current,
    }


def write_fem_bundle(model, fem_path, manifest_path=None):
    fem_path = Path(fem_path)
    manifest_path = Path(manifest_path) if manifest_path else fem_path.with_suffix(".manifest.json")
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
            lines.append("{},{},{},{}".format(element.element_type, element.element_id, property_id, ",".join(str(value) for value in element.node_ids)))
            element_ids.append(element.element_id)
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
