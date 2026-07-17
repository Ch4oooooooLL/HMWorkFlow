"""Choose HM2019 penta-mig realization parameters from local mesh geometry."""
from __future__ import annotations

import math
import statistics

from geometry import add, angle_deg, centroid, cross, distance, dot, scale, sub, unit


def _clamp(value, lower, upper):
    return max(lower, min(upper, value))


def _component_points(model, component_id):
    node_ids = {node_id for element in model.elements if element.component_id == component_id for node_id in element.node_ids}
    return [model.nodes[node_id] for node_id in node_ids]


def _principal_axes(points):
    """Return orthonormal covariance eigenvectors using a small Jacobi solve."""
    center = centroid(points)
    matrix = [[0.0] * 3 for _ in range(3)]
    for point in points:
        delta = sub(point, center)
        for row in range(3):
            for column in range(3):
                matrix[row][column] += delta[row] * delta[column]
    vectors = [[1.0 if row == column else 0.0 for column in range(3)] for row in range(3)]
    for _ in range(24):
        p, q = max(((0, 1), (0, 2), (1, 2)), key=lambda pair: abs(matrix[pair[0]][pair[1]]))
        if abs(matrix[p][q]) <= 1.0e-12:
            break
        angle = 0.5 * math.atan2(2.0 * matrix[p][q], matrix[q][q] - matrix[p][p])
        cosine, sine = math.cos(angle), math.sin(angle)
        for index in range(3):
            aip, aiq = matrix[index][p], matrix[index][q]
            matrix[index][p] = cosine * aip - sine * aiq
            matrix[index][q] = sine * aip + cosine * aiq
        for index in range(3):
            api, aqi = matrix[p][index], matrix[q][index]
            matrix[p][index] = cosine * api - sine * aqi
            matrix[q][index] = sine * api + cosine * aqi
        for index in range(3):
            vip, viq = vectors[index][p], vectors[index][q]
            vectors[index][p] = cosine * vip - sine * viq
            vectors[index][q] = sine * vip + cosine * viq
    return [unit(tuple(vectors[row][column] for row in range(3))) for column in range(3)]


def _plate_thickness(points, fallback, preferred_axes=()):
    if len(points) < 4:
        return fallback
    preferred_spans = []
    for axis in preferred_axes:
        axis = unit(axis)
        if dot(axis, axis) <= 1.0e-16:
            continue
        projections = [dot(point, axis) for point in points]
        span = max(projections) - min(projections)
        if span > 1.0e-8:
            preferred_spans.append(span)
    if preferred_spans:
        return min(preferred_spans)
    axes = _principal_axes(points)
    spans = []
    for axis in axes:
        projections = [dot(point, axis) for point in points]
        span = max(projections) - min(projections)
        if span > 1.0e-8:
            spans.append(span)
    return min(spans) if spans else fallback


def _average_normal(chain):
    normals = [unit(normal) for item in chain["items"] for normal in item.target_normals if dot(normal, normal) > 1.0e-16]
    if not normals:
        return (0.0, 0.0, 0.0)
    reference = normals[0]
    aligned = [normal if dot(normal, reference) >= 0.0 else scale(normal, -1.0) for normal in normals]
    return unit(tuple(sum(normal[index] for normal in aligned) for index in range(3)))


def select(model, source_component_id, chain, settings, joint_type):
    node_ids = list(chain["node_ids"])
    points = [model.nodes[node_id] for node_id in node_ids]
    segments = [distance(points[index], points[index + 1]) for index in range(len(points) - 1)]
    if chain.get("is_closed") and len(points) > 2:
        segments.append(distance(points[-1], points[0]))
    mesh_size = statistics.median(value for value in segments if value > 1.0e-8)

    source_points = _component_points(model, source_component_id)
    source_normals = [normal for item in chain["items"] for normal in item.edge.face_normals]
    thickness = mesh_size if model.components[source_component_id].mesh_class == "SHELL" else _plate_thickness(source_points, mesh_size, source_normals)
    # A 0.8 x thickness leg produced oversized penta wedges on triangular
    # plate edges. Use a conservative 0.6 x thickness baseline and keep it
    # compatible with the local mesh without letting coarse edge spacing
    # inflate the weld section.
    weld_width = _clamp(0.6 * thickness, 0.25 * mesh_size, 0.8 * mesh_size)
    line_spacing = _clamp(0.5 * mesh_size, 0.65 * weld_width, 1.15 * weld_width)

    maximum_gap = max(item.maximum_distance for item in chain["items"])
    tolerance = max(maximum_gap + 1.25 * weld_width, 1.5 * mesh_size)
    tolerance = min(tolerance, 2.0 * float(settings["max_search_distance"]))
    tolerance = max(tolerance, maximum_gap * 1.25)

    target_normal = _average_normal(chain)
    orientation_reversed = False
    if dot(target_normal, target_normal) > 1.0e-16 and len(points) >= 2:
        tangent = unit(sub(points[1], points[0]))
        midpoint = scale(add(points[0], points[1]), 0.5)
        toward_solid = sub(centroid(source_points), midpoint)
        # HM2019 positive-side penta generation follows normal x seam tangent.
        # Reverse the nodelist when necessary so positive side always points
        # toward the source solid instead of away from the joint.
        if dot(cross(target_normal, tangent), toward_solid) < 0.0:
            node_ids.reverse()
            orientation_reversed = True

    target_normals = [normal for item in chain["items"] for normal in item.target_normals]
    perpendicular_error = min(
        (abs(min(angle_deg(source, target), 180.0 - angle_deg(source, target)) - 90.0) for source in source_normals for target in target_normals),
        default=180.0,
    )
    right_angled = joint_type == "T_JOINT" and perpendicular_error <= 5.0 and maximum_gap <= 0.25 * thickness

    return node_ids, {
        "mesh_size": round(mesh_size, 6),
        "source_thickness": round(thickness, 6),
        "line_spacing": round(line_spacing, 6),
        "weld_width": round(weld_width, 6),
        "realization_tolerance": round(tolerance, 6),
        "side_mode": "POSITIVE",
        "right_angled": bool(right_angled),
        "orientation_reversed": orientation_reversed,
        "parameter_strategy": "ADAPTIVE_GEOMETRY_V1",
    }
