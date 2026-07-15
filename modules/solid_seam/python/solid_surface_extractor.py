"""Extract exterior faces from supported first-order solid elements."""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from typing import Dict, Iterable, List, Tuple

from geometry import centroid, triangle_area_normal
from schema import Element, MeshModel, SOLID_TYPES

FACE_TEMPLATES = {
    "CHEXA": ((0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)),
    "CPENTA": ((0, 2, 1), (3, 4, 5), (0, 1, 4, 3), (1, 2, 5, 4), (2, 0, 3, 5)),
    "CTETRA": ((0, 2, 1), (0, 1, 3), (1, 2, 3), (2, 0, 3)),
    "CPYRA": ((0, 3, 2, 1), (0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)),
}


@dataclass(frozen=True)
class SurfaceFace:
    face_id: str
    parent_element_id: int
    component_id: int
    node_ids: Tuple[int, ...]
    centroid: Tuple[float, float, float]
    normal: Tuple[float, float, float]
    area: float
    face_type: str


def _face_geometry(node_ids, nodes):
    points = [nodes[node] for node in node_ids]
    area, normal = triangle_area_normal(points[0], points[1], points[2])
    if len(points) == 4:
        extra, _ = triangle_area_normal(points[0], points[2], points[3])
        area += extra
    return centroid(points), normal, area


def extract_surface_faces(model: MeshModel, component_id: int) -> Tuple[List[SurfaceFace], List[str]]:
    occurrences: Dict[Tuple[int, ...], list] = defaultdict(list)
    for element in model.elements:
        if element.component_id != component_id or element.element_type not in SOLID_TYPES:
            continue
        for local_index, template in enumerate(FACE_TEMPLATES[element.element_type]):
            face_nodes = tuple(element.node_ids[i] for i in template)
            occurrences[tuple(sorted(face_nodes))].append((element, local_index, face_nodes))
    faces, warnings = [], []
    for key, items in occurrences.items():
        if len(items) > 2:
            warnings.append("NON_MANIFOLD_FACE:" + ",".join(map(str, key)))
        if len(items) != 1:
            continue
        element, local_index, face_nodes = items[0]
        center, normal, area = _face_geometry(face_nodes, model.nodes)
        faces.append(SurfaceFace(f"{element.element_id}:{local_index}", element.element_id, component_id, face_nodes, center, normal, area, f"FACE_{len(face_nodes)}"))
    return faces, warnings
