"""Evaluate segmented patches using the current Tcl thresholds."""
from __future__ import annotations

import math

from geometry import (
    add, centroid, dot, norm, normalize, point_line_distance,
    project_point_on_line, scale, subtract,
)
from loop_builder import boundary_loops


def _loop_normal(model, nodes, epsilon):
    nx = ny = nz = 0.0
    for index, node_id in enumerate(nodes):
        x1, y1, z1 = model.nodes[node_id]
        x2, y2, z2 = model.nodes[nodes[(index + 1) % len(nodes)]]
        nx += (y1 - y2) * (z1 + z2)
        ny += (z1 - z2) * (x1 + x2)
        nz += (x1 - x2) * (y1 + y2)
    return normalize((nx, ny, nz), epsilon)


def _mean_radius(model, nodes, center, axis):
    return sum(point_line_distance(model.nodes[node], center, axis) for node in nodes) / len(nodes)


def evaluate(model, segment, faces_by_id, settings):
    wall_nodes = sorted({node for face_id in segment for node in faces_by_id[face_id].node_ids})
    if len(wall_nodes) < settings["minWallNodes"]:
        return None, "TOO_FEW_WALL_NODES"
    loops = boundary_loops(segment, faces_by_id)
    if len(loops) != 2:
        return None, "BOUNDARY_LOOP_COUNT:{}".format(len(loops))
    loops.sort(key=lambda row: (min(row), row))
    loop1, loop2 = loops
    if min(len(loop1), len(loop2)) < settings["minLoopNodes"]:
        return None, "TOO_FEW_LOOP_NODES"
    center1 = centroid(model.nodes[node] for node in loop1)
    center2 = centroid(model.nodes[node] for node in loop2)
    axis_vector = subtract(center2, center1)
    length = norm(axis_vector)
    if length < settings["eps"]:
        return None, "ZERO_LENGTH"
    axis = normalize(axis_vector, settings["eps"])
    center = scale(add(center1, center2), 0.5)
    try:
        normal1 = _loop_normal(model, loop1, settings["eps"])
        normal2 = _loop_normal(model, loop2, settings["eps"])
    except ValueError:
        return None, "INVALID_LOOP_NORMAL"
    cos_loop = math.cos(math.radians(settings["loopNormalTolDeg"]))
    if abs(dot(normal1, axis)) < cos_loop or abs(dot(normal2, axis)) < cos_loop:
        return None, "LOOP_NORMAL_MISMATCH"
    radius1 = _mean_radius(model, loop1, center, axis)
    radius2 = _mean_radius(model, loop2, center, axis)
    radius = _mean_radius(model, wall_nodes, center, axis)
    if radius < settings["eps"]:
        return None, "ZERO_RADIUS"
    if settings["minRadius"] > 0.0 and radius < settings["minRadius"]:
        return None, "RADIUS_BELOW_MIN"
    if settings["maxRadius"] > 0.0 and radius > settings["maxRadius"]:
        return None, "RADIUS_ABOVE_MAX"
    loop_radius_deviation = abs(radius1 - radius2) / radius
    if loop_radius_deviation > settings["loopRadiusTol"]:
        return None, "LOOP_RADIUS_MISMATCH"
    deviations = [abs(point_line_distance(model.nodes[node], center, axis) - radius) for node in wall_nodes]
    radius_deviation = max(deviations) / radius
    if radius_deviation > settings["cylFitTol"]:
        return None, "CYLINDER_FIT"
    if settings["requireInnerNormal"]:
        signs = []
        for face_id in segment:
            face = faces_by_id[face_id]
            face_center = centroid(model.nodes[node] for node in face.node_ids)
            radial_vector = subtract(face_center, project_point_on_line(face_center, center, axis))
            if norm(radial_vector) > settings["eps"]:
                signs.append(dot(face.normal, normalize(radial_vector, settings["eps"])))
        if signs and sum(signs) / len(signs) > settings["innerNormalMaxDot"]:
            return None, "NOT_INNER_SURFACE"
    loop_rows = []
    for nodes, loop_center, loop_normal, loop_radius in (
        (loop1, center1, normal1, radius1), (loop2, center2, normal2, radius2)
    ):
        loop_rows.append({
            "node_ids": nodes,
            "center": [round(value, 12) for value in loop_center],
            "normal": [round(value, 12) for value in loop_normal],
            "mean_radius": round(loop_radius, 12),
        })
    confidence = max(0.0, min(1.0, 1.0 - 0.7 * radius_deviation - 0.3 * loop_radius_deviation))
    return {
        "segment_face_ids": list(segment),
        "wall_node_ids": wall_nodes,
        "boundary_loops": loop_rows,
        "center": [round(value, 12) for value in center],
        "axis": [round(value, 12) for value in axis],
        "diameter": round(2.0 * radius, 12),
        "length": round(length, 12),
        "radius_deviation": round(radius_deviation, 12),
        "loop_radius_deviation": round(loop_radius_deviation, 12),
        "confidence": round(confidence, 6),
        "confidence_level": "HIGH" if confidence >= 0.9 else "REVIEW" if confidence >= 0.7 else "LOW",
        "warnings": [],
        "reject_reasons": [],
    }, ""
