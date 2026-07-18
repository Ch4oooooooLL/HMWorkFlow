"""Read a native HyperMesh/OptiStruct shell selection export."""
from __future__ import annotations

import json
import re
from pathlib import Path

from mesh_model import Component, Element, MeshModel


class FemMeshError(ValueError):
    pass


def _compact_number(value, label, line_number):
    text = value.strip()
    if not text:
        raise FemMeshError("{} is empty at line {}".format(label, line_number))
    try:
        return float(text.replace("D", "E").replace("d", "e"))
    except ValueError:
        compact = re.sub(r"(?<=\d)([+-]\d+)$", r"E\1", text)
        try:
            return float(compact)
        except ValueError as exc:
            raise FemMeshError(
                "{} is not numeric at line {}: {!r}".format(label, line_number, value)
            ) from exc


def _positive_int(value, label, line_number):
    text = value.strip()
    try:
        result = int(text)
    except ValueError as exc:
        raise FemMeshError(
            "{} is not an integer at line {}: {!r}".format(label, line_number, value)
        ) from exc
    if result <= 0:
        raise FemMeshError("{} must be positive at line {}".format(label, line_number))
    return result


def _fixed_fields(raw):
    line = raw.rstrip("\r\n")
    large = len(line) >= 8 and "*" in line[:8]
    width = 16 if large else 8
    first = line[:8].strip().rstrip("*")
    return [first] + [
        line[index : index + width].strip()
        for index in range(8, len(line), width)
    ]


def _raw_cards(path):
    current = None
    current_line = 0
    with Path(path).open("r", encoding="utf-8-sig", errors="replace") as stream:
        for line_number, raw in enumerate(stream, 1):
            stripped = raw.strip()
            if not stripped or stripped.startswith("$"):
                continue
            upper = stripped.upper()
            if upper in ("BEGIN BULK", "BEGINBULK", "ENDDATA"):
                continue
            fields = (
                [field.strip() for field in raw.rstrip("\r\n").split(",")]
                if "," in raw
                else _fixed_fields(raw)
            )
            marker = fields[0].strip()
            continuation = marker == "" or marker == "*" or marker == "+" or marker.startswith("+")
            if continuation:
                if current is not None:
                    current.extend(fields[1:])
                continue
            if current is not None:
                yield current_line, current
            current = fields
            current_line = line_number
    if current is not None:
        yield current_line, current


def read_shell_fem(path, component_id, component_name="SOURCE_COMPONENT"):
    """Return GRID/CTRIA3/CQUAD4 data as the shared MeshModel."""
    component_id = int(component_id)
    nodes = {}
    pending_elements = []
    for line_number, fields in _raw_cards(Path(path)):
        card = fields[0].upper().rstrip("*")
        if card == "GRID":
            if len(fields) < 6:
                raise FemMeshError("GRID has too few fields at line {}".format(line_number))
            node_id = _positive_int(fields[1], "GRID ID", line_number)
            cp = fields[2].strip() if len(fields) > 2 else ""
            if cp not in ("", "0"):
                raise FemMeshError(
                    "GRID {} uses unsupported CP={} at line {}".format(node_id, cp, line_number)
                )
            if node_id in nodes:
                raise FemMeshError("duplicate GRID {} at line {}".format(node_id, line_number))
            nodes[node_id] = (
                _compact_number(fields[3], "GRID X", line_number),
                _compact_number(fields[4], "GRID Y", line_number),
                _compact_number(fields[5], "GRID Z", line_number),
            )
        elif card in ("CTRIA3", "CQUAD4"):
            expected = 3 if card == "CTRIA3" else 4
            if len(fields) < 3 + expected:
                raise FemMeshError("{} has too few fields at line {}".format(card, line_number))
            element_id = _positive_int(fields[1], "{} ID".format(card), line_number)
            node_ids = tuple(
                _positive_int(value, "{} node".format(card), line_number)
                for value in fields[3 : 3 + expected]
            )
            pending_elements.append((line_number, element_id, card, node_ids))

    if not nodes:
        raise FemMeshError("FEM selection contains no GRID cards: {}".format(path))
    elements = {}
    known_node_ids = set(nodes)
    for line_number, element_id, card, node_ids in pending_elements:
        if element_id in elements:
            raise FemMeshError("duplicate element {} at line {}".format(element_id, line_number))
        missing = sorted(set(node_ids) - known_node_ids)
        if missing:
            raise FemMeshError(
                "{} {} references missing GRID IDs {}".format(card, element_id, missing)
            )
        elements[element_id] = Element(element_id, component_id, card, node_ids)
    if not elements:
        raise FemMeshError("FEM selection contains no CTRIA3/CQUAD4 cards: {}".format(path))
    component = Component(component_id, str(component_name), "SHELL")
    return MeshModel({component_id: component}, nodes, elements)


def read_shell_fem_bundle(manifest_path):
    """Read one selected-components FEM and restore HyperMesh component ownership."""
    manifest_path = Path(manifest_path)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        raise FemMeshError("invalid selected-component FEM manifest: {}".format(exc)) from exc
    if manifest.get("format") != "hm_selected_components_fem":
        raise FemMeshError("unsupported FEM bundle format")
    entries = manifest.get("components")
    if not isinstance(entries, list) or not entries:
        raise FemMeshError("FEM bundle contains no component ownership entries")

    components = {}
    ownership = {}
    for entry in entries:
        component_id = _positive_int(str(entry.get("component_id", "")), "component ID", 0)
        component_name = str(entry.get("component_name") or "COMP_{}".format(component_id))
        components[component_id] = Component(component_id, component_name, "SHELL")
        for raw_element_id in entry.get("element_ids", []):
            element_id = _positive_int(str(raw_element_id), "element ID", 0)
            previous = ownership.get(element_id)
            if previous is not None and previous != component_id:
                raise FemMeshError(
                    "element {} is assigned to components {} and {}".format(
                        element_id, previous, component_id
                    )
                )
            ownership[element_id] = component_id

    fem_path = manifest_path.parent / str(manifest.get("fem_path", ""))
    first_component_id = min(components)
    raw_model = read_shell_fem(
        fem_path, first_component_id, components[first_component_id].component_name
    )
    elements = {}
    for element_id, element in raw_model.elements.items():
        if element_id not in ownership:
            raise FemMeshError(
                "FEM shell element {} has no HyperMesh component mapping".format(element_id)
            )
        elements[element_id] = Element(
            element_id, ownership[element_id], element.element_type, element.node_ids
        )
    return MeshModel(components, raw_model.nodes, elements)
