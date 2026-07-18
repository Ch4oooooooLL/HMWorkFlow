"""Classify exterior-surface boundary and feature edges."""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from typing import Dict, List, Tuple

try:
    from .geometry import angle_deg, distance
    from .schema import MeshModel
    from .solid_surface_extractor import SurfaceFace
except ImportError:  # Standalone HM2019 entry compatibility.
    from geometry import angle_deg, distance
    from schema import MeshModel
    from solid_surface_extractor import SurfaceFace


@dataclass(frozen=True)
class SolidEdge:
    node_ids: Tuple[int, int]
    edge_class: str
    length: float
    face_ids: Tuple[str, ...]
    face_normals: Tuple[Tuple[float, float, float], ...]


def extract_candidate_edges(model: MeshModel, faces: List[SurfaceFace], feature_angle_deg: float, edge_prefix="SOLID") -> List[SolidEdge]:
    refs: Dict[Tuple[int, int], list] = defaultdict(list)
    for face in faces:
        for index, first in enumerate(face.node_ids):
            second = face.node_ids[(index + 1) % len(face.node_ids)]
            refs[tuple(sorted((first, second)))].append(face)
    result = []
    for edge, adjacent in refs.items():
        edge_class = "IGNORE"
        if len(adjacent) == 1:
            edge_class = f"{edge_prefix}_BOUNDARY_EDGE"
        elif len(adjacent) == 2 and angle_deg(adjacent[0].normal, adjacent[1].normal) >= feature_angle_deg:
            edge_class = f"{edge_prefix}_FEATURE_EDGE"
        if edge_class != "IGNORE":
            result.append(SolidEdge(edge, edge_class, distance(model.nodes[edge[0]], model.nodes[edge[1]]), tuple(face.face_id for face in adjacent), tuple(face.normal for face in adjacent)))
    return result
