"""Read the small, auditable OptiStruct FEM snapshot exported by Tcl."""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

try:
    from hmworkflow.core.mesh_model import Component, Element, MeshModel
except ImportError:  # Standalone HM2019 entry compatibility.
    from mesh_model import Component, Element, MeshModel


class FemParseError(ValueError):
    pass


@dataclass
class FemSnapshot:
    model: MeshModel
    existing_segments: Dict[Tuple[int, int], int]


def _number(text: str, label: str, line: int) -> float:
    value = text.strip()
    try:
        return float(value)
    except ValueError:
        # Nastran also permits compact exponents such as 1.25-3.
        compact = re.sub(r"(?<=\d)([+-]\d+)$", r"E\1", value)
        try:
            return float(compact)
        except ValueError as exc:
            raise FemParseError("{} is not numeric at line {}: {!r}".format(label, line, text)) from exc


def _integer(text: str, label: str, line: int) -> int:
    try:
        value = int(text.strip())
    except ValueError as exc:
        raise FemParseError("{} is not an integer at line {}: {!r}".format(label, line, text)) from exc
    if value <= 0:
        raise FemParseError("{} must be positive at line {}".format(label, line))
    return value


def _cards(path: Path):
    current = None
    start_line = 0
    with Path(path).open("r", encoding="utf-8-sig", errors="strict") as stream:
        for line_number, raw in enumerate(stream, 1):
            text = raw.strip()
            if not text or text.startswith("$"):
                continue
            if "," not in text:
                if text.upper() in ("BEGIN BULK", "BEGINBULK", "ENDDATA"):
                    continue
                raise FemParseError(
                    "unsupported fixed-field FEM record at line {}; expected comma-separated export".format(
                        line_number
                    )
                )
            fields = [field.strip() for field in text.split(",")]
            if fields[0] in ("+", "*") or fields[0].startswith("+"):
                if current is None:
                    raise FemParseError("orphan continuation at line {}".format(line_number))
                current.extend(fields[1:])
                continue
            if current is not None:
                yield start_line, current
            current = fields
            start_line = line_number
    if current is not None:
        yield start_line, current


def read_fem(path: Path) -> FemSnapshot:
    nodes = {}  # type: Dict[int, Tuple[float, float, float]]
    rigid_rows = []  # type: List[Tuple[int, List[str]]]
    beam_rows = []  # type: List[Tuple[int, List[str]]]
    for line, fields in _cards(Path(path)):
        card = fields[0].upper().rstrip("*")
        if card == "GRID":
            if len(fields) < 6:
                raise FemParseError("GRID has fewer than six fields at line {}".format(line))
            node_id = _integer(fields[1], "GRID ID", line)
            if node_id in nodes:
                raise FemParseError("duplicate GRID {} at line {}".format(node_id, line))
            cp = fields[2].strip()
            if cp not in ("", "0"):
                raise FemParseError(
                    "GRID {} uses unsupported local coordinate system CP={} at line {}".format(
                        node_id, cp, line
                    )
                )
            nodes[node_id] = (
                _number(fields[3], "GRID X", line),
                _number(fields[4], "GRID Y", line),
                _number(fields[5], "GRID Z", line),
            )
        elif card == "RBE2":
            rigid_rows.append((line, fields))
        elif card in ("CBEAM", "CBAR"):
            beam_rows.append((line, fields))

    elements = {}
    for line, fields in rigid_rows:
        if len(fields) < 6:
            raise FemParseError("RBE2 has too few fields at line {}".format(line))
        element_id = _integer(fields[1], "RBE2 EID", line)
        center_id = _integer(fields[2], "RBE2 GN", line)
        dependent_ids = [
            _integer(value, "RBE2 GM", line) for value in fields[4:] if value.strip()
        ]
        node_ids = [center_id] + dependent_ids
        for node_id in node_ids:
            if node_id not in nodes:
                raise FemParseError(
                    "RBE2 {} references missing GRID {} (card starts at line {})".format(
                        element_id, node_id, line
                    )
                )
        if element_id in elements:
            raise FemParseError("duplicate RBE2 {} at line {}".format(element_id, line))
        elements[element_id] = Element(element_id, 1, "RBE2", tuple(node_ids))

    existing = {}
    for line, fields in beam_rows:
        if len(fields) < 5:
            raise FemParseError("{} has too few fields at line {}".format(fields[0], line))
        element_id = _integer(fields[1], "beam EID", line)
        node_1 = _integer(fields[3], "beam GA", line)
        node_2 = _integer(fields[4], "beam GB", line)
        for node_id in (node_1, node_2):
            if node_id not in nodes:
                raise FemParseError(
                    "{} {} references missing GRID {} (line {})".format(
                        fields[0].upper(), element_id, node_id, line
                    )
                )
        existing[tuple(sorted((node_1, node_2)))] = element_id

    if not nodes:
        raise FemParseError("FEM snapshot contains no GRID cards: {}".format(Path(path)))
    if not elements:
        raise FemParseError("FEM snapshot contains no RBE2 cards: {}".format(Path(path)))
    component = Component(1, "RBE2_SELECTION", "RIGID")
    return FemSnapshot(MeshModel({1: component}, nodes, elements), existing)
