"""Dependency-free 3D geometry primitives."""
from __future__ import annotations

import math
from typing import Iterable, Sequence, Tuple

Point = Tuple[float, float, float]
EPSILON = 1.0e-12


def add(a: Sequence[float], b: Sequence[float]) -> Point:
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def subtract(a: Sequence[float], b: Sequence[float]) -> Point:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def scale(a: Sequence[float], factor: float) -> Point:
    return (a[0] * factor, a[1] * factor, a[2] * factor)


def dot(a: Sequence[float], b: Sequence[float]) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a: Sequence[float], b: Sequence[float]) -> Point:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def norm(a: Sequence[float]) -> float:
    return math.sqrt(dot(a, a))


def normalize(a: Sequence[float], epsilon: float = EPSILON) -> Point:
    length = norm(a)
    if length <= epsilon:
        raise ValueError("cannot normalize a near-zero vector")
    return scale(a, 1.0 / length)


def distance_squared(a: Sequence[float], b: Sequence[float]) -> float:
    delta = subtract(a, b)
    return dot(delta, delta)


def distance(a: Sequence[float], b: Sequence[float]) -> float:
    return math.sqrt(distance_squared(a, b))


def centroid(points: Iterable[Sequence[float]]) -> Point:
    rows = list(points)
    if not rows:
        raise ValueError("centroid requires at least one point")
    total = (0.0, 0.0, 0.0)
    for point in rows:
        total = add(total, point)
    return scale(total, 1.0 / len(rows))


def project_point_on_line(point: Sequence[float], center: Sequence[float], axis: Sequence[float]) -> Point:
    direction = normalize(axis)
    return add(center, scale(direction, dot(subtract(point, center), direction)))


def point_line_distance(point: Sequence[float], center: Sequence[float], axis: Sequence[float]) -> float:
    return distance(point, project_point_on_line(point, center, axis))


def angle_degrees(a: Sequence[float], b: Sequence[float]) -> float:
    denominator = norm(a) * norm(b)
    if denominator <= EPSILON:
        raise ValueError("angle requires non-zero vectors")
    cosine = max(-1.0, min(1.0, dot(a, b) / denominator))
    return math.degrees(math.acos(cosine))
