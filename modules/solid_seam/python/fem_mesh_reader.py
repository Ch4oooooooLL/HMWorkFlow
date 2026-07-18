"""Read a selected-component OptiStruct FEM export for solid seam detection."""
from __future__ import annotations

import re
from pathlib import Path

try:
    from .schema import Component, Element, MeshModel, SHELL_TYPES, SOLID_TYPES, SchemaError
except ImportError:  # Standalone HM2019 entry compatibility.
    from schema import Component, Element, MeshModel, SHELL_TYPES, SOLID_TYPES, SchemaError


_HMNAME = re.compile(r'^\s*\$HMNAME\s+COMP\s+(\d+)\s*"([^"]*)"', re.IGNORECASE)
_EXPECTED = {
    "CTETRA": 4, "CPYRA": 5, "CPENTA": 6, "CHEXA": 8,
    "CTRIA3": 3, "CTRIA6": 6, "CQUAD4": 4, "CQUAD8": 8,
}


def _number(text, label, line_number):
    value = text.strip().replace("D", "E").replace("d", "e")
    value = re.sub(r"(?<=\d)([+-]\d+)$", r"E\1", value)
    try:
        return float(value)
    except ValueError as exc:
        raise SchemaError(f"{label} is not numeric at line {line_number}: {text!r}") from exc


def _fields(raw):
    if "," in raw:
        return [item.strip() for item in raw.rstrip("\r\n").split(",")]
    line = raw.rstrip("\r\n")
    large = "*" in line[:8]
    width = 16 if large else 8
    return [line[:8].strip().rstrip("*")] + [line[i:i + width].strip() for i in range(8, len(line), width)]


def _cards(path):
    current = None
    current_line = 0
    with Path(path).open("r", encoding="utf-8-sig", errors="replace") as stream:
        for line_number, raw in enumerate(stream, 1):
            stripped = raw.strip()
            if not stripped or stripped.startswith("$") or stripped.upper() in {"BEGIN BULK", "BEGINBULK", "ENDDATA"}:
                continue
            fields = _fields(raw)
            marker = fields[0].strip()
            if marker in {"", "*", "+"} or marker.startswith("+"):
                if current is not None:
                    current.extend(fields[1:])
                continue
            if current is not None:
                yield current_line, current
            current, current_line = fields, line_number
    if current is not None:
        yield current_line, current


def read_fem(path: Path, component_id=None) -> MeshModel:
    names = {}
    with Path(path).open("r", encoding="utf-8-sig", errors="replace") as stream:
        for raw in stream:
            match = _HMNAME.match(raw)
            if match:
                names[int(match.group(1))] = match.group(2)

    nodes, pending = {}, []
    for line_number, fields in _cards(path):
        card = fields[0].upper().rstrip("*")
        if card == "GRID":
            if len(fields) < 6:
                raise SchemaError(f"GRID has too few fields at line {line_number}")
            node_id = int(fields[1])
            cp = fields[2].strip()
            if cp not in {"", "0"}:
                raise SchemaError(f"GRID {node_id} uses unsupported CP={cp}")
            nodes[node_id] = tuple(_number(fields[i], "GRID coordinate", line_number) for i in range(3, 6))
        elif card in _EXPECTED:
            count = _EXPECTED[card]
            if len(fields) < 3 + count:
                raise SchemaError(f"{card} has too few fields at line {line_number}")
            deck_component_id = int(fields[2])
            pending.append(Element(int(fields[1]), int(component_id) if component_id is not None else deck_component_id, card, tuple(int(value) for value in fields[3:3 + count])))

    if not nodes or not pending:
        raise SchemaError(f"FEM selection contains no supported mesh: {path}")
    classes = {}
    for element in pending:
        mesh_class = "SOLID" if element.element_type in SOLID_TYPES else "SHELL"
        previous = classes.get(element.component_id)
        if previous and previous != mesh_class:
            raise SchemaError(f"component {element.component_id} mixes solid and shell elements")
        classes[element.component_id] = mesh_class
        missing = set(element.node_ids) - set(nodes)
        if missing:
            raise SchemaError(f"element {element.element_id} references missing GRID IDs {sorted(missing)}")
    components = {}
    for cid, mesh_class in classes.items():
        name = names.get(cid)
        if name is None and component_id is not None:
            name = names.get(int(component_id)) or (next(iter(names.values())) if len(names) == 1 else None)
        components[cid] = Component(cid, name or f"COMP_{cid}", mesh_class)
    return MeshModel(components, nodes, pending, [])
