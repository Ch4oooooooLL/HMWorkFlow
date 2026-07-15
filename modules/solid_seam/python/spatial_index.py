"""Dependency-free AABB coarse index with exact point-to-triangle distance."""
from __future__ import annotations

from geometry import bbox, point_triangle_distance


class TriangleIndex:
    def __init__(self, triangles):
        self.items = [(bbox(triangle.points), triangle) for triangle in triangles]

    def nearest(self, point, max_distance=float("inf")):
        best_distance, best_triangle = max_distance, None
        for bounds, triangle in self.items:
            lower = sum(max(bounds[0][i] - point[i], 0.0, point[i] - bounds[1][i]) ** 2 for i in range(3)) ** 0.5
            if lower > best_distance:
                continue
            current = point_triangle_distance(point, *triangle.points)
            if current < best_distance:
                best_distance, best_triangle = current, triangle
        return best_distance, best_triangle
