"""Small dependency-free 3-D geometry helpers."""
from __future__ import annotations

import math
from typing import Iterable, Sequence, Tuple

Point = Tuple[float, float, float]


def add(a: Point, b: Point) -> Point:
    return a[0] + b[0], a[1] + b[1], a[2] + b[2]


def sub(a: Point, b: Point) -> Point:
    return a[0] - b[0], a[1] - b[1], a[2] - b[2]


def scale(a: Point, value: float) -> Point:
    return a[0] * value, a[1] * value, a[2] * value


def dot(a: Point, b: Point) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a: Point, b: Point) -> Point:
    return a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]


def norm(a: Point) -> float:
    return math.sqrt(dot(a, a))


def unit(a: Point) -> Point:
    length = norm(a)
    return (0.0, 0.0, 0.0) if length <= 1.0e-12 else scale(a, 1.0 / length)


def distance(a: Point, b: Point) -> float:
    return norm(sub(a, b))


def centroid(points: Sequence[Point]) -> Point:
    count = float(len(points))
    return tuple(sum(point[i] for point in points) / count for i in range(3))  # type: ignore[return-value]


def angle_deg(a: Point, b: Point) -> float:
    denominator = norm(a) * norm(b)
    if denominator <= 1.0e-12:
        return 0.0
    return math.degrees(math.acos(max(-1.0, min(1.0, dot(a, b) / denominator))))


def triangle_area_normal(a: Point, b: Point, c: Point) -> Tuple[float, Point]:
    raw = cross(sub(b, a), sub(c, a))
    return 0.5 * norm(raw), unit(raw)


def point_segment_distance(point: Point, a: Point, b: Point) -> float:
    ab = sub(b, a)
    denom = dot(ab, ab)
    if denom <= 1.0e-16:
        return distance(point, a)
    t = max(0.0, min(1.0, dot(sub(point, a), ab) / denom))
    return distance(point, add(a, scale(ab, t)))


def point_triangle_distance(point: Point, a: Point, b: Point, c: Point) -> float:
    # Christer Ericson, Real-Time Collision Detection, closest-point regions.
    ab, ac, ap = sub(b, a), sub(c, a), sub(point, a)
    d1, d2 = dot(ab, ap), dot(ac, ap)
    if d1 <= 0.0 and d2 <= 0.0:
        return distance(point, a)
    bp = sub(point, b)
    d3, d4 = dot(ab, bp), dot(ac, bp)
    if d3 >= 0.0 and d4 <= d3:
        return distance(point, b)
    vc = d1 * d4 - d3 * d2
    if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
        return distance(point, add(a, scale(ab, d1 / (d1 - d3))))
    cp = sub(point, c)
    d5, d6 = dot(ab, cp), dot(ac, cp)
    if d6 >= 0.0 and d5 <= d6:
        return distance(point, c)
    vb = d5 * d2 - d1 * d6
    if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
        return distance(point, add(a, scale(ac, d2 / (d2 - d6))))
    va = d3 * d6 - d5 * d4
    if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
        return distance(point, add(b, scale(sub(c, b), (d4 - d3) / ((d4 - d3) + (d5 - d6)))))
    normal = unit(cross(ab, ac))
    return abs(dot(ap, normal))


def bbox(points: Iterable[Point]) -> Tuple[Point, Point]:
    pts = list(points)
    return tuple(min(p[i] for p in pts) for i in range(3)), tuple(max(p[i] for p in pts) for i in range(3))  # type: ignore[return-value]


def expanded_bbox_intersects(a, b, padding: float) -> bool:
    return all(a[0][i] - padding <= b[1][i] and b[0][i] - padding <= a[1][i] for i in range(3))
