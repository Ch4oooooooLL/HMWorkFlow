"""Distance-based candidate edge detection."""
from __future__ import annotations

from dataclasses import dataclass

try:
    from .geometry import add, point_segment_distance, scale
except ImportError:  # Standalone HM2019 entry compatibility.
    from geometry import add, point_segment_distance, scale


@dataclass
class DetectedEdge:
    edge: object
    average_distance: float
    maximum_distance: float
    valid_ratio: float
    target_normals: tuple
    target_boundary_ratio: float


def _samples(a, b, length, step):
    count = max(1, int(length / max(step, 1.0e-9)))
    return [add(a, scale((b[0] - a[0], b[1] - a[1], b[2] - a[2]), index / count)) for index in range(count + 1)]


def detect_edges(model, edges, index, settings):
    search = float(settings["search_distance"])
    maximum = float(settings["max_search_distance"])
    min_ratio = float(settings["min_valid_ratio"])
    average_length = sum(edge.length for edge in edges) / max(len(edges), 1)
    step = max(average_length * 0.75, 1.0e-6)
    detected = []
    for edge in edges:
        points = _samples(model.nodes[edge.node_ids[0]], model.nodes[edge.node_ids[1]], edge.length, step)
        nearest = [index.nearest(point, maximum) for point in points]
        distances = [value[0] for value in nearest]
        valid = [value <= search and nearest[index_value][1] is not None for index_value, value in enumerate(distances)]
        ratio = sum(valid) / float(len(valid))
        if ratio >= min_ratio and sum(distances) / len(distances) <= search and max(distances) <= maximum and any(item[1] is not None for item in nearest):
            boundary_hits = 0
            for point, nearest_item in zip(points, nearest):
                triangle = nearest_item[1]
                if triangle is None:
                    continue
                edge_distance = min(point_segment_distance(point, triangle.points[i], triangle.points[(i + 1) % 3]) for i in range(3))
                if edge_distance <= search:
                    boundary_hits += 1
            detected.append(DetectedEdge(edge, sum(distances) / len(distances), max(distances), ratio, tuple(item[1].normal for item in nearest if item[1] is not None), boundary_hits / float(len(points))))
    return detected
