"""Represent shell elements as source faces for seam-edge recognition."""
from __future__ import annotations

from geometry import centroid, triangle_area_normal
from schema import SHELL_TYPES
from solid_surface_extractor import SurfaceFace


def extract_shell_faces(model, component_id):
    faces = []
    for element in model.elements:
        if element.component_id != component_id or element.element_type not in SHELL_TYPES:
            continue
        node_ids = tuple(element.node_ids[:4] if element.element_type in {"CQUAD4", "CQUAD8"} else element.node_ids[:3])
        points = [model.nodes[node_id] for node_id in node_ids]
        area, normal = triangle_area_normal(points[0], points[1], points[2])
        if len(points) == 4:
            extra, _ = triangle_area_normal(points[0], points[2], points[3])
            area += extra
        faces.append(SurfaceFace(f"{element.element_id}:0", element.element_id, component_id, node_ids, centroid(points), normal, area, f"FACE_{len(node_ids)}"))
    return faces, []
