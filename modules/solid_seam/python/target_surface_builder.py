"""Build target triangles for shell and solid components."""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Tuple

try:
    from .geometry import bbox, triangle_area_normal
    from .schema import MeshModel, SHELL_TYPES
    from .solid_surface_extractor import extract_surface_faces
except ImportError:  # Standalone HM2019 entry compatibility.
    from geometry import bbox, triangle_area_normal
    from schema import MeshModel, SHELL_TYPES
    from solid_surface_extractor import extract_surface_faces


@dataclass(frozen=True)
class TargetTriangle:
    component_id: int
    node_ids: Tuple[int, int, int]
    points: Tuple[tuple, tuple, tuple]
    normal: tuple


def _triangulate(node_ids):
    corners = tuple(node_ids[:4] if len(node_ids) in {4, 8} else node_ids[:3])
    return (corners,) if len(corners) == 3 else ((corners[0], corners[1], corners[2]), (corners[0], corners[2], corners[3]))


def build_target_surface(model: MeshModel, component_id: int):
    component = model.components[component_id]
    raw_triangles = []
    if component.mesh_class == "SHELL":
        for element in model.elements:
            if element.component_id == component_id and element.element_type in SHELL_TYPES:
                raw_triangles.extend(_triangulate(element.node_ids))
    else:
        faces, _ = extract_surface_faces(model, component_id)
        for face in faces:
            raw_triangles.extend(_triangulate(face.node_ids))
    triangles = []
    for nodes in raw_triangles:
        points = tuple(model.nodes[node] for node in nodes)
        _, normal = triangle_area_normal(*points)
        triangles.append(TargetTriangle(component_id, nodes, points, normal))
    target_bbox = bbox(point for triangle in triangles for point in triangle.points) if triangles else None
    return triangles, target_bbox
