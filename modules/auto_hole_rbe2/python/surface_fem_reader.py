"""Read the native OptiStruct FEM snapshot of HyperMesh-generated free faces."""
from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

try:
    from hmworkflow.core.hybrid_schema import SchemaError
    from hmworkflow.core.mesh_model import Component, Element, MeshModel
except ImportError:  # Standalone HM2019 entry compatibility.
    from hybrid_schema import SchemaError
    from mesh_model import Component, Element, MeshModel


class SurfaceFemError(SchemaError):
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
            raise SurfaceFemError(
                "{} is not numeric at line {}: {!r}".format(label, line_number, value)
            ) from exc


def _positive_int(value, label, line_number):
    try:
        result = int(value.strip())
    except (AttributeError, ValueError) as exc:
        raise SurfaceFemError(
            "{} is not an integer at line {}: {!r}".format(label, line_number, value)
        ) from exc
    if result <= 0:
        raise SurfaceFemError("{} must be positive at line {}".format(label, line_number))
    return result


def _fixed_fields(raw):
    line = raw.rstrip("\r\n")
    large = len(line) >= 8 and "*" in line[:8]
    width = 16 if large else 8
    return [line[:8].strip().rstrip("*")] + [
        line[index:index + width].strip() for index in range(8, len(line), width)
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


def _read_surface(path):
    nodes = {}
    shell_rows = []
    card_counts = Counter()
    for line_number, fields in _cards(path):
        card = fields[0].upper().rstrip("*")
        card_counts[card] += 1
        if card == "GRID":
            if len(fields) < 6:
                raise SurfaceFemError("GRID has too few fields at line {}".format(line_number))
            node_id = _positive_int(fields[1], "GRID ID", line_number)
            cp = fields[2].strip()
            if cp not in ("", "0"):
                raise SurfaceFemError("GRID {} uses unsupported CP={}".format(node_id, cp))
            if node_id in nodes:
                raise SurfaceFemError("duplicate GRID {} at line {}".format(node_id, line_number))
            nodes[node_id] = tuple(
                _number(fields[index], "GRID coordinate", line_number)
                for index in range(3, 6)
            )
        elif card in ("CTRIA3", "CQUAD4"):
            count = 3 if card == "CTRIA3" else 4
            if len(fields) < 3 + count:
                raise SurfaceFemError("{} has too few fields at line {}".format(card, line_number))
            shell_rows.append((
                line_number,
                _positive_int(fields[1], "{} ID".format(card), line_number),
                card,
                tuple(
                    _positive_int(value, "{} node".format(card), line_number)
                    for value in fields[3:3 + count]
                ),
            ))
    if not nodes or not shell_rows:
        other_cards = ", ".join(
            "{}={}".format(card, count)
            for card, count in card_counts.most_common(12)
            if card not in ("GRID", "CTRIA3", "CQUAD4")
        )
        detail = "GRID={}, CTRIA3/CQUAD4={}".format(len(nodes), len(shell_rows))
        if other_cards:
            detail += ", other cards: " + other_cards
        raise SurfaceFemError(
            "surface FEM must contain GRID and CTRIA3/CQUAD4 cards ({})".format(detail)
        )
    return nodes, shell_rows


def read_surface_fem_bundle(manifest_path):
    manifest_path = Path(manifest_path)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        raise SurfaceFemError("invalid surface FEM manifest: {}".format(exc)) from exc
    if manifest.get("format") != "hm_surface_faces_fem":
        raise SurfaceFemError("unsupported surface FEM bundle format")
    component_id = _positive_int(
        str(manifest.get("source_component_id", "")), "source component ID", 0
    )
    fem_name = str(manifest.get("fem_path", ""))
    if not fem_name or Path(fem_name).is_absolute():
        raise SurfaceFemError("surface FEM manifest requires a relative fem_path")
    nodes, rows = _read_surface(manifest_path.parent / fem_name)
    node_id_map = {}
    internal_ids = set()
    for index, pair in enumerate(manifest.get("node_id_map", [])):
        if not isinstance(pair, list) or len(pair) != 2:
            raise SurfaceFemError("node_id_map entry {} must contain two IDs".format(index))
        solver_id = _positive_int(str(pair[0]), "solver node ID", 0)
        internal_id = _positive_int(str(pair[1]), "internal node ID", 0)
        if solver_id in node_id_map or internal_id in internal_ids:
            raise SurfaceFemError("node_id_map contains duplicate IDs")
        node_id_map[solver_id] = internal_id
        internal_ids.add(internal_id)
    if node_id_map and set(nodes) != set(node_id_map):
        missing = sorted(set(nodes) - set(node_id_map))
        extra = sorted(set(node_id_map) - set(nodes))
        raise SurfaceFemError(
            "node_id_map does not match FEM GRID IDs; missing={} extra={}".format(
                missing[:20], extra[:20]
            )
        )
    if not node_id_map:
        node_id_map = {node_id: node_id for node_id in nodes}
    internal_nodes = {node_id_map[node_id]: xyz for node_id, xyz in nodes.items()}
    expected = {
        _positive_int(str(value), "surface element ID", 0)
        for value in manifest.get("element_ids", [])
    }
    known_nodes = set(nodes)
    elements = {}
    for line_number, element_id, card, node_ids in rows:
        if expected and element_id not in expected:
            continue
        missing = sorted(set(node_ids) - known_nodes)
        if missing:
            raise SurfaceFemError(
                "{} {} references missing GRID IDs {}".format(card, element_id, missing)
            )
        if element_id in elements:
            raise SurfaceFemError("duplicate shell element {}".format(element_id))
        internal_node_ids = tuple(node_id_map[node_id] for node_id in node_ids)
        elements[element_id] = Element(element_id, component_id, card, internal_node_ids)
    if expected and set(elements) != expected:
        missing = sorted(expected - set(elements))
        raise SurfaceFemError("surface FEM is missing exported elements {}".format(missing[:20]))
    component_name = str(
        manifest.get("source_component_name") or "COMP_{}".format(component_id)
    )
    return MeshModel(
        {component_id: Component(component_id, component_name, "SOLID")},
        internal_nodes,
        elements,
    )
