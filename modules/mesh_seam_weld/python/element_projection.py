"""Dependency-free projections used by automatic shell seam detection."""
from __future__ import annotations

import math


def _sub(a, b): return tuple(a[i] - b[i] for i in range(3))
def _add(a, b): return tuple(a[i] + b[i] for i in range(3))
def _scale(a, value): return tuple(a[i] * value for i in range(3))
def dot(a, b): return sum(a[i] * b[i] for i in range(3))
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def norm(a): return math.sqrt(dot(a, a))
def unit(a):
    length = norm(a)
    if length <= 1.0e-12: raise ValueError("degenerate vector")
    return tuple(value / length for value in a)


def triangle_normal(a, b, c):
    return unit(cross(_sub(b, a), _sub(c, a)))


def closest_point_on_segment(point, first, second):
    direction = _sub(second, first); denominator = dot(direction, direction)
    if denominator <= 1.0e-24: return first, 0.0
    parameter = max(0.0, min(1.0, dot(_sub(point, first), direction) / denominator))
    return _add(first, _scale(direction, parameter)), parameter


def project_point_to_triangle(point, a, b, c):
    """Return closest point, barycentric weights, distance and location."""
    normal = triangle_normal(a, b, c)
    projected = _sub(point, _scale(normal, dot(_sub(point, a), normal)))
    v0, v1, v2 = _sub(b, a), _sub(c, a), _sub(projected, a)
    d00, d01, d11 = dot(v0, v0), dot(v0, v1), dot(v1, v1)
    denominator = d00*d11 - d01*d01
    if abs(denominator) <= 1.0e-18: raise ValueError("degenerate triangle")
    v = (d11*dot(v2, v0)-d01*dot(v2, v1))/denominator
    w = (d00*dot(v2, v1)-d01*dot(v2, v0))/denominator; u = 1.0-v-w
    if min(u, v, w) >= -1.0e-10:
        closest, weights = projected, (u, v, w)
    else:
        choices = []
        for indices, edge in (((0,1),(a,b)), ((1,2),(b,c)), ((2,0),(c,a))):
            candidate, parameter = closest_point_on_segment(point, *edge)
            weight = [0.0, 0.0, 0.0]; weight[indices[0]] = 1.0-parameter; weight[indices[1]] = parameter
            choices.append((norm(_sub(point, candidate)), candidate, tuple(weight)))
        _, closest, weights = min(choices, key=lambda row: row[0])
    zeros = sum(abs(value) <= 1.0e-9 for value in weights)
    location = "NODE" if zeros >= 2 else ("EDGE" if zeros == 1 else "FACE")
    return {"point": closest, "barycentric": weights, "distance": norm(_sub(point, closest)), "location": location, "normal": normal}


def project_point_to_element(point, node_ids, coordinates):
    if len(node_ids) not in (3, 4): raise ValueError("only CTRIA3/CQUAD4 projection is supported")
    triangles = [(0,1,2)] if len(node_ids) == 3 else [(0,1,2),(0,2,3)]
    results = []
    for triangle in triangles:
        result = project_point_to_triangle(point, *(coordinates[node_ids[index]] for index in triangle))
        result["triangle_node_ids"] = [node_ids[index] for index in triangle]; results.append(result)
    return min(results, key=lambda row: (row["distance"], row["triangle_node_ids"]))


def angle_degrees(first, second, unsigned=True):
    value = max(-1.0, min(1.0, dot(unit(first), unit(second))))
    angle = math.degrees(math.acos(value))
    return min(angle, 180.0-angle) if unsigned else angle
