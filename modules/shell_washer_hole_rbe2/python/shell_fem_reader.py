"""Read a native selected-components OptiStruct FEM export."""
from __future__ import annotations

import json
import re
from pathlib import Path

from hybrid_schema import SchemaError
from mesh_model import Component, Element, MeshModel


class FemMeshError(SchemaError):
    pass


def _number(value, label, line_number):
    text = value.strip().replace("D", "E").replace("d", "e")
    try:
        return float(text)
    except ValueError:
        compact = re.sub(r"(?<=\d)([+-]\d+)$", r"E\1", text)
        try:
            return float(compact)
        except ValueError as exc:
            raise FemMeshError(
                "{} is not numeric at line {}: {!r}".format(label, line_number, value)
            ) from exc


def _positive_int(value, label, line_number):
    try:
        result = int(value.strip())
    except (AttributeError, ValueError) as exc:
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
    return [line[:8].strip().rstrip("*")] + [
        line[index:index + width].strip()
        for index in range(8, len(line), width)
    ]


def _cards(path):
    current = None
    current_line = 0
    with Path(path).open("r", encoding="utf-8-sig", errors="replace") as stream:
        for line_number, raw in enumerate(stream, 1):
            stripped = raw.strip()
            if not stripped or stripped.startswith("$"):
                continue
            if stripped.upper() in ("BEGIN BULK", "BEGINBULK", "ENDDATA"):
                continue
            fields = (
                [field.strip() for field in raw.rstrip("\r\n").split(",")]
                if "," in raw else _fixed_fields(raw)
            )
            marker = fields[0].strip()
            if marker in ("", "*", "+") or marker.startswith("+"):
                if current is not None:
                    current.extend(fields[1:])
                continue
            if current is not None:
                yield current_line, current
            current, current_line = fields, line_number
    if current is not None:
        yield current_line, current


def _read_shell_fem(path):
    nodes = {}
    pending = []
    for line_number, fields in _cards(path):
        card = fields[0].upper().rstrip("*")
        if card == "GRID":
            if len(fields) < 6:
                raise FemMeshError("GRID has too few fields at line {}".format(line_number))
            node_id = _positive_int(fields[1], "GRID ID", line_number)
            if node_id in nodes:
                raise FemMeshError("duplicate GRID {} at line {}".format(node_id, line_number))
            cp = fields[2].strip()
            if cp not in ("", "0"):
                raise FemMeshError("GRID {} uses unsupported CP={}".format(node_id, cp))
            nodes[node_id] = tuple(
                _number(fields[index], "GRID coordinate", line_number)
                for index in range(3, 6)
            )
        elif card in ("CTRIA3", "CQUAD4"):
            count = 3 if card == "CTRIA3" else 4
            if len(fields) < 3 + count:
                raise FemMeshError("{} has too few fields at line {}".format(card, line_number))
            pending.append((
                line_number,
                _positive_int(fields[1], "{} ID".format(card), line_number),
                card,
                tuple(
                    _positive_int(value, "{} node".format(card), line_number)
                    for value in fields[3:3 + count]
                ),
            ))
    if not nodes:
        raise FemMeshError("FEM selection contains no GRID cards: {}".format(path))
    if not pending:
        raise FemMeshError("FEM selection contains no CTRIA3/CQUAD4 cards: {}".format(path))
    return nodes, pending


def read_shell_fem_bundle(manifest_path):
    """Restore HyperMesh component ownership using the Tcl export manifest."""
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
        if component_id in components:
            raise FemMeshError("duplicate component {} in FEM manifest".format(component_id))
        name = str(entry.get("component_name") or "COMP_{}".format(component_id))
        components[component_id] = Component(component_id, name, "SHELL")
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

    fem_name = str(manifest.get("fem_path", ""))
    if not fem_name or Path(fem_name).is_absolute():
        raise FemMeshError("FEM manifest must contain a relative fem_path")
    fem_path = manifest_path.parent / fem_name
    nodes, pending = _read_shell_fem(fem_path)
    known_nodes = set(nodes)
    elements = {}
    for line_number, element_id, card, node_ids in pending:
        component_id = ownership.get(element_id)
        if component_id is None:
            raise FemMeshError(
                "FEM shell element {} has no HyperMesh component mapping".format(element_id)
            )
        if element_id in elements:
            raise FemMeshError("duplicate shell element {} at line {}".format(element_id, line_number))
        missing = sorted(set(node_ids) - known_nodes)
        if missing:
            raise FemMeshError(
                "{} {} references missing GRID IDs {}".format(card, element_id, missing)
            )
        elements[element_id] = Element(element_id, component_id, card, node_ids)
    return MeshModel(components, nodes, elements)
