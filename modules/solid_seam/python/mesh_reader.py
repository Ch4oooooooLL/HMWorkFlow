"""Read and normalize the JSON mesh export."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict

from schema import Component, Element, MeshModel, SHELL_TYPES, SOLID_TYPES, SchemaError, require_version


def load_json(path: Path) -> Dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SchemaError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise SchemaError(f"JSON root must be an object: {path}")
    return data


def read_mesh(path: Path) -> MeshModel:
    data = load_json(path)
    require_version(data, "mesh_data")
    components = {}
    for raw in data.get("components", []):
        item = Component(int(raw["component_id"]), str(raw.get("component_name", raw["component_id"])), str(raw["mesh_class"]).upper())
        components[item.component_id] = item
    nodes = {}
    for raw in data.get("nodes", []):
        xyz = raw.get("xyz", [])
        if len(xyz) != 3:
            raise SchemaError(f"node {raw.get('node_id')} must have three coordinates")
        nodes[int(raw["node_id"])] = tuple(float(value) for value in xyz)
    elements = []
    for raw in data.get("elements", []):
        item = Element(int(raw["element_id"]), int(raw["component_id"]), str(raw["element_type"]).upper(), tuple(int(n) for n in raw["node_ids"]))
        expected = {"CHEXA": 8, "CPENTA": 6, "CTETRA": 4, "CPYRA": 5, "CTRIA3": 3, "CTRIA6": 6, "CQUAD4": 4, "CQUAD8": 8}
        if item.element_type not in SOLID_TYPES | SHELL_TYPES or len(item.node_ids) != expected[item.element_type]:
            raise SchemaError(f"unsupported or malformed element {item.element_id}: {item.element_type}")
        if item.component_id not in components or any(n not in nodes for n in item.node_ids):
            raise SchemaError(f"element {item.element_id} references an unknown component or node")
        elements.append(item)
    return MeshModel(components, nodes, elements, list(data.get("existing_connectors", [])))
