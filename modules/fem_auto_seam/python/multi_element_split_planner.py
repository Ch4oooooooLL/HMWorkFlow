"""Plan a constrained polyline split across a coplanar first-order shell patch.

The planner is intentionally independent from HyperMesh.  It replaces only
the target elements crossed by the projected path, shares newly inserted GRID
placeholders across adjacent mother elements, and preserves target component
and property ownership.  It supports open and closed paths and is the offline
counterpart of a local FE imprint.
"""
from __future__ import annotations

import math

try:
    from hmworkflow.mesh_seam_weld.element_projection import cross, dot, norm, unit
    from hmworkflow.mesh_seam_weld.local_split_planner import _plane, _polygon_area, _project, _triangulate
    from hmworkflow.mesh_seam_weld.quality_guard import element_metrics
except ImportError:
    from element_projection import cross, dot, norm, unit
    from local_split_planner import _plane, _polygon_area, _project, _triangulate
    from quality_guard import element_metrics


def _sub(a, b):
    return tuple(a[index] - b[index] for index in range(3))


def _lerp(a, b, value):
    return tuple(a[index] + value * (b[index] - a[index]) for index in range(3))


def _orient(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _distance2(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def _edge_parameter(point, first, second):
    direction = (second[0] - first[0], second[1] - first[1])
    denominator = direction[0] * direction[0] + direction[1] * direction[1]
    if denominator <= 1.0e-24:
        return 0.0, float("inf")
    parameter = ((point[0] - first[0]) * direction[0] + (point[1] - first[1]) * direction[1]) / denominator
    nearest = (first[0] + parameter * direction[0], first[1] + parameter * direction[1])
    return parameter, _distance2(point, nearest)


def _clip_segment_convex(first, second, polygon, tolerance):
    """Return the parameter interval inside an oriented convex polygon."""
    sign = 1.0 if _polygon_area(polygon) >= 0.0 else -1.0
    low, high = 0.0, 1.0
    for index, edge_first in enumerate(polygon):
        edge_second = polygon[(index + 1) % len(polygon)]
        value_first = sign * _orient(edge_first, edge_second, first)
        value_second = sign * _orient(edge_first, edge_second, second)
        inside_first = value_first >= -tolerance
        inside_second = value_second >= -tolerance
        if not inside_first and not inside_second:
            return None
        if inside_first == inside_second:
            continue
        denominator = value_first - value_second
        if abs(denominator) <= 1.0e-24:
            return None
        crossing = value_first / denominator
        if not inside_first:
            low = max(low, crossing)
        else:
            high = min(high, crossing)
        if high - low <= tolerance:
            return None
    return low, high


def _chain(boundary, start, end):
    result = [boundary[start]]
    index = start
    while index != end:
        index = (index + 1) % len(boundary)
        result.append(boundary[index])
    return result


def _dedupe_cycle(values):
    result = []
    for value in values:
        if not result or result[-1] != value:
            result.append(value)
    if len(result) > 1 and result[0] == result[-1]:
        result.pop()
    return result


def _element_normal(element, coordinates):
    ids = element.node_ids
    return unit(cross(_sub(coordinates[ids[1]], coordinates[ids[0]]), _sub(coordinates[ids[2]], coordinates[ids[0]])))


def plan_multi_element_split(model, target_component_id, source_node_ids, closed=False, settings=None, target_points=None):
    settings = settings or {}
    source = list(source_node_ids)
    minimum = 3 if closed else 2
    if len(source) < minimum:
        return {"status": "MANUAL_REVIEW", "warnings": ["constraint path is too short"]}
    target_elements = sorted(model.elements_for_components([int(target_component_id)]), key=lambda row: row.element_id)
    if not target_elements or any(row.element_type not in ("CTRIA3", "CQUAD4") for row in target_elements):
        return {"status": "MANUAL_REVIEW", "warnings": ["target must contain only first-order CTRIA3/CQUAD4 shells"]}
    properties = getattr(model, "element_properties", {})
    if any(int(properties.get(row.element_id, 0)) <= 0 for row in target_elements):
        return {"status": "MANUAL_REVIEW", "warnings": ["target shell property is unresolved"]}

    reference = target_elements[0]
    plane = _plane(list(reference.node_ids), model.nodes)
    local_nodes = {}
    edge_lengths = []
    plane_tolerance = float(settings.get("planarity_tolerance", 1.0e-6))
    for element in target_elements:
        for node_id in element.node_ids:
            if node_id in local_nodes:
                continue
            _, local, distance = _project(model.nodes[node_id], plane)
            if distance > plane_tolerance:
                return {"status": "MANUAL_REVIEW", "warnings": ["target patch is not coplanar"]}
            local_nodes[node_id] = local
        ids = element.node_ids
        edge_lengths.extend(_distance2(local_nodes[ids[index]], local_nodes[ids[(index + 1) % len(ids)]]) for index in range(len(ids)))
    scale = sum(edge_lengths) / max(1, len(edge_lengths))
    tolerance = max(1.0e-8, scale * float(settings.get("split_tolerance_ratio", 1.0e-7)))

    projected_3d, projected_2d = [], []
    maximum_distance = float(settings.get("search_distance", float("inf")))
    if target_points is not None and len(target_points) != len(source):
        return {"status": "MANUAL_REVIEW", "warnings": ["target projection point count does not match the source path"]}
    for source_index, node_id in enumerate(source):
        if node_id not in model.nodes:
            return {"status": "MANUAL_REVIEW", "warnings": ["source path references a missing GRID"]}
        projection_input = tuple(target_points[source_index]) if target_points is not None else model.nodes[node_id]
        point, local, plane_distance = _project(projection_input, plane)
        distance = norm(_sub(model.nodes[node_id], point))
        if plane_distance > plane_tolerance:
            return {"status": "MANUAL_REVIEW", "warnings": ["planned target point is outside the target plane"]}
        if distance > maximum_distance:
            return {"status": "MANUAL_REVIEW", "warnings": ["source path exceeds target projection distance"]}
        projected_3d.append(point)
        projected_2d.append(local)

    target_edge_set = set()
    for element in target_elements:
        ids = element.node_ids
        target_edge_set.update(tuple(sorted((ids[index], ids[(index + 1) % len(ids)]))) for index in range(len(ids)))
    existing_target_path = []
    for local in projected_2d:
        matches = [(distance, node_id) for node_id, target_local in local_nodes.items() for distance in [_distance2(local, target_local)] if distance <= tolerance]
        if not matches:
            existing_target_path = []
            break
        existing_target_path.append(min(matches)[1])
    if existing_target_path and len(set(existing_target_path)) == len(existing_target_path):
        path_pairs = list(zip(existing_target_path, existing_target_path[1:]))
        if closed:
            path_pairs.append((existing_target_path[-1], existing_target_path[0]))
        if all(tuple(sorted(pair)) in target_edge_set for pair in path_pairs):
            return {
                "status": "READY",
                "warnings": [],
                "target_node_ids": existing_target_path,
                "new_nodes": [],
                "replacement_elements": [],
                "delete_element_ids": [],
                "original_connectivity": {},
                "read_elements": [],
                "coordinates": dict(model.nodes),
            }

    segments = list(zip(range(len(source) - 1), range(1, len(source))))
    if closed:
        segments.append((len(source) - 1, 0))
    pieces_by_element = {}
    for segment_index, (first_index, second_index) in enumerate(segments):
        first, second = projected_2d[first_index], projected_2d[second_index]
        if _distance2(first, second) <= tolerance:
            return {"status": "MANUAL_REVIEW", "warnings": ["constraint path contains a collapsed segment"]}
        for element in target_elements:
            polygon = [local_nodes[node_id] for node_id in element.node_ids]
            clipped = _clip_segment_convex(first, second, polygon, tolerance)
            if clipped is None:
                continue
            low, high = clipped
            if high - low <= tolerance:
                continue
            pieces_by_element.setdefault(element.element_id, []).append({
                "start": segment_index + low,
                "end": segment_index + high,
                "start_2d": (first[0] + low * (second[0] - first[0]), first[1] + low * (second[1] - first[1])),
                "end_2d": (first[0] + high * (second[0] - first[0]), first[1] + high * (second[1] - first[1])),
                "start_3d": _lerp(projected_3d[first_index], projected_3d[second_index], low),
                "end_3d": _lerp(projected_3d[first_index], projected_3d[second_index], high),
            })
    if not pieces_by_element:
        return {"status": "MANUAL_REVIEW", "warnings": ["projected path does not cross the target patch"]}
    coverage = sorted((piece["start"], piece["end"]) for pieces in pieces_by_element.values() for piece in pieces)
    merged_coverage = []
    for start, end in coverage:
        if merged_coverage and start <= merged_coverage[-1][1] + 4.0 * tolerance:
            merged_coverage[-1][1] = max(merged_coverage[-1][1], end)
        else:
            merged_coverage.append([start, end])
    expected_end = float(len(segments))
    if not merged_coverage or merged_coverage[0][0] > 4.0 * tolerance or merged_coverage[-1][1] < expected_end - 4.0 * tolerance:
        return {"status": "MANUAL_REVIEW", "warnings": ["projected path is not fully covered by the target patch"]}
    if any(merged_coverage[index + 1][0] - merged_coverage[index][1] > 4.0 * tolerance for index in range(len(merged_coverage) - 1)):
        return {"status": "MANUAL_REVIEW", "warnings": ["projected target path crosses a gap or hole"]}

    coordinate_map = dict(model.nodes)
    placeholder_coordinates = {}
    point_registry = {}
    next_placeholder = -1

    def node_for(point_2d, point_3d):
        nonlocal next_placeholder
        for node_id, local in local_nodes.items():
            if _distance2(point_2d, local) <= tolerance:
                return node_id
        key = (int(round(point_2d[0] / tolerance)), int(round(point_2d[1] / tolerance)))
        existing = point_registry.get(key)
        if existing is not None and _distance2(point_2d, placeholder_coordinates[existing][0]) <= 2.0 * tolerance:
            return existing
        node_id = next_placeholder
        next_placeholder -= 1
        point_registry[key] = node_id
        placeholder_coordinates[node_id] = (point_2d, point_3d)
        coordinate_map[node_id] = point_3d
        return node_id

    replacements = []
    deleted = []
    original_connectivity = {}
    global_vertices = []
    for element_id in sorted(pieces_by_element):
        element = model.elements[element_id]
        pieces = sorted(pieces_by_element[element_id], key=lambda row: (row["start"], row["end"]))
        merged = []
        for piece in pieces:
            if merged and abs(piece["start"] - merged[-1]["end"]) <= 4.0 * tolerance and _distance2(piece["start_2d"], merged[-1]["end_2d"]) <= 4.0 * tolerance:
                merged[-1]["end"] = piece["end"]
                merged[-1]["end_2d"] = piece["end_2d"]
                merged[-1]["end_3d"] = piece["end_3d"]
            else:
                merged.append(dict(piece))
        if closed and len(merged) > 1 and merged[0]["start"] <= 4.0 * tolerance and merged[-1]["end"] >= expected_end - 4.0 * tolerance and _distance2(merged[0]["start_2d"], merged[-1]["end_2d"]) <= 4.0 * tolerance:
            wrapped = dict(merged[-1])
            wrapped["end"] = merged[0]["end"] + expected_end
            wrapped["end_2d"] = merged[0]["end_2d"]
            wrapped["end_3d"] = merged[0]["end_3d"]
            merged = [wrapped] + merged[1:-1]
        if len(merged) != 1:
            return {"status": "MANUAL_REVIEW", "warnings": ["constraint enters one target shell more than once"]}
        piece = merged[0]
        path_values = [(piece["start"], piece["start_2d"], piece["start_3d"])]
        first_integer = int(math.floor(piece["start"] + 1.0e-9)) + 1
        last_integer = int(math.ceil(piece["end"] - 1.0e-9))
        for value in range(first_integer, last_integer + 1):
            if piece["start"] + tolerance < value < piece["end"] - tolerance:
                vertex_index = value % len(source)
                path_values.append((float(value), projected_2d[vertex_index], projected_3d[vertex_index]))
        path_values.append((piece["end"], piece["end_2d"], piece["end_3d"]))
        path_values.sort(key=lambda row: row[0])
        path_ids = [node_for(local, point) for _, local, point in path_values]
        if len(set(path_ids)) != len(path_ids):
            return {"status": "MANUAL_REVIEW", "warnings": ["constraint path collapses on an existing target node"]}
        for (value, _, _), node_id in zip(path_values, path_ids):
            if closed and value > expected_end + 4.0 * tolerance:
                value -= expected_end
            if closed and abs(value - expected_end) <= 4.0 * tolerance:
                global_vertices.append((0.0, node_id))
            global_vertices.append((value, node_id))

        polygon_ids = list(element.node_ids)
        polygon = [local_nodes[node_id] for node_id in polygon_ids]
        insertions = {}
        endpoint_ids = (path_ids[0], path_ids[-1])
        endpoint_points = (path_values[0][1], path_values[-1][1])
        for endpoint_id, point in zip(endpoint_ids, endpoint_points):
            if endpoint_id in polygon_ids:
                continue
            matches = []
            for edge_index in range(len(polygon_ids)):
                parameter, distance = _edge_parameter(point, polygon[edge_index], polygon[(edge_index + 1) % len(polygon_ids)])
                if distance <= 4.0 * tolerance and -tolerance <= parameter <= 1.0 + tolerance:
                    matches.append((distance, edge_index, max(0.0, min(1.0, parameter))))
            if not matches:
                return {"status": "MANUAL_REVIEW", "warnings": ["constraint endpoint is not on a mother-shell boundary"]}
            _, edge_index, parameter = min(matches)
            insertions.setdefault(edge_index, []).append((parameter, endpoint_id))
        boundary = []
        for edge_index, node_id in enumerate(polygon_ids):
            boundary.append(node_id)
            for _, inserted in sorted(insertions.get(edge_index, [])):
                if inserted != node_id and inserted != polygon_ids[(edge_index + 1) % len(polygon_ids)]:
                    boundary.append(inserted)
        boundary = _dedupe_cycle(boundary)
        if endpoint_ids[0] not in boundary or endpoint_ids[1] not in boundary:
            return {"status": "MANUAL_REVIEW", "warnings": ["constraint endpoints were not inserted into target boundary"]}
        start_index, end_index = boundary.index(endpoint_ids[0]), boundary.index(endpoint_ids[1])
        if start_index == end_index:
            return {"status": "MANUAL_REVIEW", "warnings": ["constraint has identical boundary endpoints"]}
        side_a = _dedupe_cycle(_chain(boundary, start_index, end_index) + list(reversed(path_ids[1:-1])))
        side_b = _dedupe_cycle(_chain(boundary, end_index, start_index) + path_ids[1:-1])
        local_map = dict(local_nodes)
        local_map.update({node_id: values[0] for node_id, values in placeholder_coordinates.items()})
        try:
            triangles = []
            for polygon_side in (side_a, side_b):
                if len(polygon_side) < 3:
                    raise ValueError("constraint creates a degenerate target polygon")
                triangles.extend(_triangulate(polygon_side, [local_map[node_id] for node_id in polygon_side]))
        except ValueError as exc:
            return {"status": "MANUAL_REVIEW", "warnings": [str(exc)]}

        original_normal = _element_normal(element, model.nodes)
        mother_replacements = []
        for node_ids in triangles:
            metrics = element_metrics(node_ids, coordinate_map)
            if not metrics["valid"] or metrics["aspect_ratio"] > float(settings.get("max_split_aspect_ratio", 50.0)):
                return {"status": "MANUAL_REVIEW", "warnings": ["replacement shell fails split quality preflight"]}
            replacement_normal = unit(cross(_sub(coordinate_map[node_ids[1]], coordinate_map[node_ids[0]]), _sub(coordinate_map[node_ids[2]], coordinate_map[node_ids[0]])))
            if dot(original_normal, replacement_normal) <= 0.0:
                node_ids = [node_ids[0], node_ids[2], node_ids[1]]
            mother_replacements.append({
                "element_type": "CTRIA3",
                "node_ids": node_ids,
                "property_id": int(properties[element.element_id]),
                "component_id": element.component_id,
                "original_element_id": element.element_id,
            })
        original_area = element_metrics(element.node_ids, model.nodes)["area"]
        replacement_area = sum(element_metrics(row["node_ids"], coordinate_map)["area"] for row in mother_replacements)
        if original_area <= 0.0 or abs(replacement_area - original_area) / original_area > 1.0e-6:
            return {"status": "MANUAL_REVIEW", "warnings": ["replacement shells do not preserve mother-shell area"]}
        replacements.extend(mother_replacements)
        deleted.append(element.element_id)
        original_connectivity[str(element.element_id)] = list(element.node_ids)

    global_vertices.sort(key=lambda row: (row[0], row[1]))
    ordered_target = []
    ordered_parameters = []
    for parameter, node_id in global_vertices:
        if ordered_parameters and abs(parameter - ordered_parameters[-1]) <= 4.0 * tolerance:
            if ordered_target[-1] != node_id:
                return {"status": "MANUAL_REVIEW", "warnings": ["adjacent target shells disagree on a shared split node"]}
            continue
        ordered_parameters.append(parameter)
        ordered_target.append(node_id)
    if not ordered_parameters or ordered_parameters[0] > 4.0 * tolerance or ordered_parameters[-1] < expected_end - 4.0 * tolerance:
        return {"status": "MANUAL_REVIEW", "warnings": ["projected path is not fully covered by the target patch"]}
    if closed and ordered_target[-1] == ordered_target[0]:
        ordered_target.pop()
        ordered_parameters.pop()
    if len(ordered_target) < minimum:
        return {"status": "MANUAL_REVIEW", "warnings": ["split target path is too short"]}

    final_edges = set()
    deleted_set = set(deleted)
    for element in target_elements:
        if element.element_id in deleted_set:
            continue
        ids = element.node_ids
        final_edges.update(tuple(sorted((ids[index], ids[(index + 1) % len(ids)]))) for index in range(len(ids)))
    for replacement in replacements:
        ids = replacement["node_ids"]
        final_edges.update(tuple(sorted((ids[index], ids[(index + 1) % len(ids)]))) for index in range(len(ids)))
    constraint_pairs = list(zip(ordered_target, ordered_target[1:]))
    if closed:
        constraint_pairs.append((ordered_target[-1], ordered_target[0]))
    if any(tuple(sorted(pair)) not in final_edges for pair in constraint_pairs):
        return {"status": "MANUAL_REVIEW", "warnings": ["planned target path is not a continuous edge in the replacement mesh"]}

    new_nodes = [
        {"node_id": node_id, "coordinates": list(values[1])}
        for node_id, values in sorted(placeholder_coordinates.items(), reverse=True)
    ]
    return {
        "status": "READY",
        "warnings": [],
        "target_node_ids": ordered_target,
        "new_nodes": new_nodes,
        "replacement_elements": replacements,
        "delete_element_ids": sorted(deleted),
        "original_connectivity": original_connectivity,
        "read_elements": sorted(deleted),
        "coordinates": coordinate_map,
    }
