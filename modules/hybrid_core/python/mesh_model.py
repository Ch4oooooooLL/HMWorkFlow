"""Compact mesh model shared by the four pure-data analyzers."""
from __future__ import annotations

import json
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple

try:
    from .schema import SchemaError, int_list, require_mapping, require_version
    from .worker_cache import get_file_resource
except ImportError:  # Standalone HM2019 entry compatibility.
    from schema import SchemaError, int_list, require_mapping, require_version
    from worker_cache import get_file_resource


_BINARY_MESH_MAGIC = b"HMWFMB1\x00"
_BINARY_ENDIAN_MARKER = 0x01020304
_BINARY_HEADER = struct.Struct("<iiii")
_BINARY_INT64 = struct.Struct("<q")
_BINARY_UINT32 = struct.Struct("<I")
_BINARY_NODE = struct.Struct("<qddd")
_BINARY_ELEMENT_IDS = struct.Struct("<qq")
_MAX_RECORDS = 100000000
_MAX_STRING_BYTES = 16 * 1024 * 1024


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
    path = Path(path).resolve()
    return get_file_resource("mesh_model", path, lambda: _read_mesh(path))


def _read_mesh(path: Path) -> MeshModel:
    try:
        with path.open("rb") as stream:
            magic = stream.read(len(_BINARY_MESH_MAGIC))
            if magic == _BINARY_MESH_MAGIC:
                return _read_binary_mesh_stream(stream, path)
    except OSError as exc:
        raise SchemaError("cannot read mesh {}: {}".format(path, exc)) from exc
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


def _read_exact(stream, size: int, label: str) -> bytes:
    data = stream.read(size)
    if len(data) != size:
        raise SchemaError("truncated binary mesh while reading {}".format(label))
    return data


def _read_binary_string(stream, label: str) -> str:
    size = _BINARY_UINT32.unpack(_read_exact(stream, _BINARY_UINT32.size, label + " length"))[0]
    if size > _MAX_STRING_BYTES:
        raise SchemaError("binary mesh {} is too large".format(label))
    try:
        return _read_exact(stream, size, label).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SchemaError("binary mesh {} is not UTF-8".format(label)) from exc


def _validate_record_count(value: int, label: str) -> int:
    if value < 0 or value > _MAX_RECORDS:
        raise SchemaError("invalid binary mesh {} {}".format(label, value))
    return value


def _read_binary_mesh_stream(stream, path: Path) -> MeshModel:
    marker, component_count, node_count, element_count = _BINARY_HEADER.unpack(
        _read_exact(stream, _BINARY_HEADER.size, "header")
    )
    if marker != _BINARY_ENDIAN_MARKER:
        raise SchemaError("unsupported binary mesh byte order in {}".format(path))
    component_count = _validate_record_count(component_count, "component count")
    node_count = _validate_record_count(node_count, "node count")
    element_count = _validate_record_count(element_count, "element count")

    components = {}
    for index in range(component_count):
        component_id = _BINARY_INT64.unpack(
            _read_exact(stream, _BINARY_INT64.size, "component ID")
        )[0]
        component_name = _read_binary_string(stream, "component name")
        mesh_class = _read_binary_string(stream, "mesh class").upper()
        if component_id <= 0 or component_id in components:
            raise SchemaError("invalid or duplicate component ID {}".format(component_id))
        components[component_id] = Component(component_id, component_name, mesh_class)

    nodes = {}
    for index in range(node_count):
        node_id, x, y, z = _BINARY_NODE.unpack(
            _read_exact(stream, _BINARY_NODE.size, "node")
        )
        if node_id <= 0 or node_id in nodes:
            raise SchemaError("invalid or duplicate node ID {}".format(node_id))
        nodes[node_id] = (x, y, z)

    known_node_ids = set(nodes)
    elements = {}
    for index in range(element_count):
        element_id, component_id = _BINARY_ELEMENT_IDS.unpack(
            _read_exact(stream, _BINARY_ELEMENT_IDS.size, "element IDs")
        )
        element_type = _read_binary_string(stream, "element type").upper()
        element_node_count = _BINARY_UINT32.unpack(
            _read_exact(stream, _BINARY_UINT32.size, "element node count")
        )[0]
        if element_node_count == 0 or element_node_count > 255:
            raise SchemaError("element {} has an invalid node count".format(element_id))
        node_ids = tuple(
            _BINARY_INT64.unpack(_read_exact(stream, _BINARY_INT64.size, "element node ID"))[0]
            for _ in range(element_node_count)
        )
        if element_id <= 0 or element_id in elements:
            raise SchemaError("invalid or duplicate element ID {}".format(element_id))
        if component_id not in components:
            raise SchemaError(
                "element {} references missing component {}".format(element_id, component_id)
            )
        if len(set(node_ids)) != len(node_ids):
            raise SchemaError("element {} contains duplicate node IDs".format(element_id))
        missing = sorted(set(node_ids) - known_node_ids)
        if missing:
            raise SchemaError("element {} references missing nodes {}".format(element_id, missing))
        elements[element_id] = Element(element_id, component_id, element_type, node_ids)

    if stream.read(1):
        raise SchemaError("binary mesh {} has trailing data".format(path))
    return MeshModel(components, nodes, elements)
