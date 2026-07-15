"""Small dependency-free uniform-grid index for candidate searches."""
from __future__ import annotations

import math
from collections import defaultdict
from typing import Dict, Iterable, List, Sequence, Tuple


class PointGrid:
    def __init__(self, rows: Iterable[Tuple[int, Sequence[float]]], cell_size: float) -> None:
        if cell_size <= 0.0:
            raise ValueError("cell_size must be positive")
        self.cell_size = float(cell_size)
        self.points = {}  # type: Dict[int, Tuple[float, float, float]]
        self.cells = defaultdict(list)
        for item_id, point in rows:
            xyz = (float(point[0]), float(point[1]), float(point[2]))
            self.points[int(item_id)] = xyz
            self.cells[self._key(xyz)].append(int(item_id))

    def _key(self, point: Sequence[float]) -> Tuple[int, int, int]:
        return tuple(int(math.floor(value / self.cell_size)) for value in point)  # type: ignore

    def query_radius(self, point: Sequence[float], radius: float) -> List[int]:
        if radius < 0.0:
            raise ValueError("radius must be non-negative")
        center = self._key(point)
        span = int(math.ceil(radius / self.cell_size))
        radius_squared = radius * radius
        matches = []
        for ix in range(center[0] - span, center[0] + span + 1):
            for iy in range(center[1] - span, center[1] + span + 1):
                for iz in range(center[2] - span, center[2] + span + 1):
                    for item_id in self.cells.get((ix, iy, iz), []):
                        xyz = self.points[item_id]
                        distance_squared = sum((xyz[index] - point[index]) ** 2 for index in range(3))
                        if distance_squared <= radius_squared:
                            matches.append(item_id)
        return sorted(matches)
