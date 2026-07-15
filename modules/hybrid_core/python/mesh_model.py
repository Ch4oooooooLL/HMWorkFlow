"""Compact mesh model shared by the four pure-data analyzers."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple

from schema import SchemaError, int_list, require_mapping, require_version


@dataclass(frozen=True)
class Component:
    component_id: int
    component_name: str
    mesh_class: str


@dataclass(frozen=True)
class Element:
    element_id: int
    component_id: int
    element_type: str
    node_ids: Tuple[int, ...]


@dataclass
class MeshModel:
    components: Dict[int, Component]
    nodes: Dict[int, Tuple[float, float, float]]
    elements: Dict[int, Element]

    def elements_for_components(self, component_ids: Iterable[int]) -> List[Element]:
        selected = set(component_ids)
        index = getattr(self, "_elements_by_component", None)
        if index is None:
            index = {}
            for item in self.elements.values():
                index.setdefault(item.component_id, []).append(item)
            self._elements_by_component = index
        return [item for component_id in selected for item in index.get(component_id, [])]


def load_json(path: Path) -> Dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SchemaError("cannot read JSON {}: {}".format(path, exc)) from exc
    return require_mapping(data, str(path))


def read_mesh(path: Path) -> MeshModel:
    data = load_json(path)
    require_version(data, "mesh")
    components = {}
    for raw in data.get("components", []):
        raw = require_mapping(raw, "mesh.components[]")
        component_id = int(raw["component_id"])
        if component_id <= 0 or component_id in components:
            raise SchemaError("invalid or duplicate component ID {}".format(component_id))
        components[component_id] = Component(
            component_id,
            str(raw.get("component_name", "COMP_{}".format(component_id))),
            str(raw.get("mesh_class", "UNKNOWN")).upper(),
        )
    nodes = {}
    for raw in data.get("nodes", []):
        if not isinstance(raw, list) or len(raw) != 4:
            raise SchemaError("mesh.nodes entries must be [id, x, y, z]")
        node_id = int(raw[0])
        if node_id <= 0 or node_id in nodes:
            raise SchemaError("invalid or duplicate node ID {}".format(node_id))
        nodes[node_id] = (float(raw[1]), float(raw[2]), float(raw[3]))
    # Build this index once.  Reconstructing set(nodes) for every element made
    # validation O(element_count * node_count) on large HyperMesh exports.
    known_node_ids = set(nodes)
    elements = {}
    for raw in data.get("elements", []):
        raw = require_mapping(raw, "mesh.elements[]")
        element_id = int(raw["element_id"])
        component_id = int(raw["component_id"])
        node_ids = tuple(int_list(raw.get("node_ids"), "element.node_ids", unique=True))
        if element_id <= 0 or element_id in elements:
            raise SchemaError("invalid or duplicate element ID {}".format(element_id))
        if component_id not in components:
            raise SchemaError("element {} references missing component {}".format(element_id, component_id))
        missing = sorted(set(node_ids) - known_node_ids)
        if missing:
            raise SchemaError("element {} references missing nodes {}".format(element_id, missing))
        elements[element_id] = Element(
            element_id, component_id, str(raw.get("element_type", "UNKNOWN")).upper(), node_ids
        )
    return MeshModel(components, nodes, elements)
