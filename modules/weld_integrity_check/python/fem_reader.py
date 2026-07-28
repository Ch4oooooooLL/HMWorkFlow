"""Read a native selected-component OptiStruct FEM export."""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Sequence, Tuple


class FemInputError(ValueError):
    pass


def _number(value: str, label: str, line_number: int) -> float:
    text = value.strip().replace("D", "E").replace("d", "e")
    text = re.sub(r"(?<=\d)([+-]\d+)$", r"E\1", text)
    try:
        return float(text)
    except ValueError as exc:
        raise FemInputError(
            "{} is not numeric at line {}: {!r}".format(label, line_number, value)
        ) from exc


def _positive_int(value: Any, label: str, line_number: int) -> int:
    try:
        result = int(str(value).strip())
    except ValueError as exc:
        raise FemInputError(
            "{} is not an integer at line {}: {!r}".format(label, line_number, value)
        ) from exc
    if result <= 0:
        raise FemInputError("{} must be positive at line {}".format(label, line_number))
    return result


def _fixed_fields(raw: str) -> List[str]:
    line = raw.rstrip("\r\n")
    large = len(line) >= 8 and "*" in line[:8]
    width = 16 if large else 8
    return [line[:8].strip().rstrip("*")] + [
        line[index : index + width].strip()
        for index in range(8, len(line), width)
    ]


def _cards(path: Path) -> Iterable[Tuple[int, Sequence[str]]]:
    current = None
    current_line = 0
    with path.open("r", encoding="utf-8-sig", errors="replace") as stream:
        for line_number, raw in enumerate(stream, 1):
            stripped = raw.strip()
            if not stripped or stripped.startswith("$"):
                continue
            if stripped.upper() in ("BEGIN BULK", "BEGINBULK", "ENDDATA"):
                continue
            fields = (
                [field.strip() for field in raw.rstrip("\r\n").split(",")]
                if "," in raw
                else _fixed_fields(raw)
            )
            marker = fields[0].strip()
            if marker in ("", "*", "+") or marker.startswith("+"):
                if current is not None:
                    current.extend(fields[1:])
                continue
            if current is not None:
                yield current_line, current
            current = fields
            current_line = line_number
    if current is not None:
        yield current_line, current


def read_fem_bundle(manifest_path: Path) -> Tuple[List[Dict[str, Any]], Dict[int, Tuple[float, float, float]], List[Dict[str, Any]]]:
    manifest_path = Path(manifest_path)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        raise FemInputError("invalid FEM manifest: {}".format(exc)) from exc
    if manifest.get("format") != "hm_weld_integrity_fem":
        raise FemInputError("unsupported FEM manifest format")

    entries = manifest.get("components")
    if not isinstance(entries, list) or not entries:
        raise FemInputError("FEM manifest contains no component entries")
    components_by_id: Dict[int, Dict[str, Any]] = {}
    ownership: Dict[int, int] = {}
    for entry in entries:
        component_id = _positive_int(entry.get("component_id", ""), "component ID", 0)
        components_by_id[component_id] = {
            "id": component_id,
            "name": str(entry.get("component_name") or "COMP_{}".format(component_id)),
            "entity_type": "shell",
        }
        for raw_element_id in entry.get("element_ids", []):
            element_id = _positive_int(raw_element_id, "element ID", 0)
            previous = ownership.get(element_id)
            if previous is not None and previous != component_id:
                raise FemInputError(
                    "element {} is assigned to components {} and {}".format(
                        element_id, previous, component_id
                    )
                )
            ownership[element_id] = component_id

    fem_path = manifest_path.parent / str(manifest.get("fem_path", ""))
    if not fem_path.is_file():
        raise FemInputError("FEM file does not exist: {}".format(fem_path))
    nodes: Dict[int, Tuple[float, float, float]] = {}
    pending: List[Tuple[int, int, str, List[int]]] = []
    for line_number, fields in _cards(fem_path):
        card = fields[0].upper().rstrip("*")
        if card == "GRID":
            if len(fields) < 6:
                raise FemInputError("GRID has too few fields at line {}".format(line_number))
            node_id = _positive_int(fields[1], "GRID ID", line_number)
            cp = fields[2].strip() if len(fields) > 2 else ""
            if cp not in ("", "0"):
                raise FemInputError(
                    "GRID {} uses unsupported CP={} at line {}".format(node_id, cp, line_number)
                )
            nodes[node_id] = (
                _number(fields[3], "GRID X", line_number),
                _number(fields[4], "GRID Y", line_number),
                _number(fields[5], "GRID Z", line_number),
            )
        elif card in ("CTRIA3", "CQUAD4"):
            node_count = 3 if card == "CTRIA3" else 4
            if len(fields) < 3 + node_count:
                raise FemInputError("{} has too few fields at line {}".format(card, line_number))
            element_id = _positive_int(fields[1], "{} ID".format(card), line_number)
            node_ids = [
                _positive_int(value, "{} node".format(card), line_number)
                for value in fields[3 : 3 + node_count]
            ]
            pending.append((line_number, element_id, card, node_ids))

    if not nodes:
        raise FemInputError("FEM selection contains no GRID cards: {}".format(fem_path))
    elements: List[Dict[str, Any]] = []
    shell_component_ids = set()
    known_node_ids = set(nodes)
    seen_element_ids = set()
    for line_number, element_id, card, node_ids in pending:
        if element_id in seen_element_ids:
            raise FemInputError("duplicate shell element {} at line {}".format(element_id, line_number))
        seen_element_ids.add(element_id)
        component_id = ownership.get(element_id)
        if component_id is None:
            raise FemInputError(
                "FEM shell element {} has no HyperMesh component mapping".format(element_id)
            )
        missing = sorted(set(node_ids) - known_node_ids)
        if missing:
            raise FemInputError(
                "{} {} references missing GRID IDs {}".format(card, element_id, missing)
            )
        shell_component_ids.add(component_id)
        elements.append({
            "element_id": element_id,
            "component_id": component_id,
            "element_type": card,
            "node_ids": node_ids,
        })
    if len(shell_component_ids) < 2:
        raise FemInputError(
            "at least two selected components must contain CTRIA3/CQUAD4 elements"
        )
    components = [
        components_by_id[component_id] for component_id in sorted(shell_component_ids)
    ]
    return components, nodes, elements
