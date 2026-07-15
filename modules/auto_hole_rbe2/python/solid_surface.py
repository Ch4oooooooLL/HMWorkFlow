"""Extract stable exterior faces from supported first-order solid elements."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Tuple

from geometry import cross, norm, normalize, subtract
from mesh_model import MeshModel
from topology import exterior_faces, solid_faces


@dataclass(frozen=True)
class Face:
    face_id: str
    element_id: int
    node_ids: Tuple[int, ...]
    normal: Tuple[float, float, float]


def face_normal(model: MeshModel, node_ids: Tuple[int, ...], epsilon: float):
    p0 = model.nodes[node_ids[0]]
    for index in range(1, len(node_ids) - 1):
        value = cross(subtract(model.nodes[node_ids[index]], p0), subtract(model.nodes[node_ids[index + 1]], p0))
        if norm(value) > epsilon:
            return normalize(value, epsilon)
    return (0.0, 0.0, 0.0)


def extract(model: MeshModel, component_ids, epsilon: float) -> Tuple[List[Face], List[str]]:
    elements = model.elements_for_components(component_ids)
    warnings = []
    supported = []
    for element in elements:
        try:
            solid_faces(element)
            supported.append(element)
        except ValueError:
            warnings.append("UNSUPPORTED_ELEMENT:{}:{}".format(element.element_id, element.element_type))
    index_by_key = {}
    for element in supported:
        for face_index, nodes in enumerate(solid_faces(element), 1):
            index_by_key[(element.element_id, tuple(nodes))] = face_index
    faces = []
    for element_id, nodes in exterior_faces(supported):
        face_index = index_by_key[(element_id, tuple(nodes))]
        faces.append(Face(
            "E{}F{}".format(element_id, face_index),
            element_id,
            tuple(nodes),
            face_normal(model, tuple(nodes), epsilon),
        ))
    faces.sort(key=lambda item: (item.element_id, item.face_id))
    return faces, warnings
