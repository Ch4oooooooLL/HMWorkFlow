"""Read a native HyperMesh/OptiStruct shell selection export."""
from __future__ import annotations

import json
import math
import re
from pathlib import Path

try:
    from hmworkflow.core.mesh_model import Component, Element, MeshModel
except ImportError:  # Standalone HM2019 entry compatibility.
    from mesh_model import Component, Element, MeshModel


class FemMeshError(ValueError):
    pass


def _triangle_area(first, second, third):
    a = tuple(second[index] - first[index] for index in range(3))
    b = tuple(third[index] - first[index] for index in range(3))
    cross = (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
    return 0.5 * math.sqrt(sum(value*value for value in cross))


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
    current_lines = []
    current_line = 0
    with Path(path).open("r", encoding="utf-8-sig", errors="replace") as stream:
        for line_number, raw in enumerate(stream, 1):
            stripped = raw.strip()
            if not stripped:
                continue
            if stripped.startswith("$"):
                # Component ownership markers are comment cards, but the
                # offline writer must reproduce $HMCOMP grouping for the
                # whole-model replacement FEM.  Keep only those two markers;
                # every other HyperMesh comment card is cosmetic.
                if not (stripped.startswith("$HMNAME") or stripped.startswith("$HMCOMP")):
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
                    current_lines.append(raw.rstrip("\r\n"))
                continue
            if current is not None:
                yield current_line, current, current_lines
            current = fields
            current_lines = [raw.rstrip("\r\n")]
            current_line = line_number
    if current is not None:
        yield current_line, current, current_lines


def read_shell_fem(path, component_id, component_name="SOURCE_COMPONENT"):
    """Return GRID/CTRIA3/CQUAD4 data as the shared MeshModel."""
    component_id = int(component_id)
    nodes = {}
    pending_elements = []
    properties = {}
    materials = {}
    skipped_element_cards = {}
    skipped_degenerate_elements = []
    # Cards outside the shell topology are preserved verbatim so the whole
    # model can be rebuilt after Python modifies the shell seams.  Each group
    # keeps the $HMCOMP/$HMNAME component context that was active when the
    # source export wrote it, which lets the writer re-emit non-shell element
    # cards under the correct component marker.
    other_card_lines = []
    current_component = 0
    unsupported_cards = {"CTRIA6", "CQUAD8", "CTETRA", "CPENTA", "CHEXA", "CPYRAM", "CWELD", "CSEAM", "CROD", "CONROD", "CBAR", "CBEAM", "RBE2", "RBE3", "CELAS1", "CELAS2", "CBUSH", "PLOTEL"}
    for line_number, fields, raw_lines in _raw_cards(Path(path)):
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
        elif card in ("$HMNAME", "$HMCOMP"):
            # HyperMesh writes these markers space-separated (for example
            # "$HMCOMP ID 5"), so the fixed-width split can merge the keyword
            # and the ID into one field.  Fall back to whitespace tokens.
            marker_id = None
            if len(fields) >= 3 and fields[1].upper() in ("COMP", "ID"):
                marker_id = fields[2]
            else:
                tokens = [token for token in re.split(r"\s+", raw_lines[0].strip()) if token]
                if len(tokens) >= 3 and tokens[1].upper() in ("COMP", "ID"):
                    marker_id = tokens[2]
            if marker_id is not None:
                current_component = _positive_int(marker_id, "{} ID".format(card), line_number)
        elif card in unsupported_cards:
            # FEM Automatic Seam only consumes first-order shell topology.
            # Other element families can legitimately coexist in a full
            # vehicle export and must not abort the complete detection run.
            skipped_element_cards[card] = skipped_element_cards.get(card, 0) + 1
            other_card_lines.append([current_component] + list(raw_lines))
            continue
        elif card in ("CTRIA3", "CQUAD4"):
            expected = 3 if card == "CTRIA3" else 4
            if len(fields) < 3 + expected:
                raise FemMeshError("{} has too few fields at line {}".format(card, line_number))
            element_id = _positive_int(fields[1], "{} ID".format(card), line_number)
            property_id = _positive_int(fields[2], "{} PID".format(card), line_number)
            node_ids = tuple(
                _positive_int(value, "{} node".format(card), line_number)
                for value in fields[3 : 3 + expected]
            )
            if len(set(node_ids)) != len(node_ids):
                skipped_degenerate_elements.append(element_id)
                continue
            pending_elements.append((line_number, element_id, property_id, card, node_ids))
        elif card == "PSHELL":
            if len(fields) >= 4:
                property_id = _positive_int(fields[1], "PSHELL PID", line_number)
                properties[property_id] = {"material_id": _positive_int(fields[2], "PSHELL MID1", line_number), "thickness": _compact_number(fields[3], "PSHELL T", line_number)}
        elif card == "MAT1":
            material_id = _positive_int(fields[1], "MAT1 MID", line_number)
            materials[material_id] = fields[2:]
        else:
            # Loads, constraints, sets, coordinate systems and any other
            # model-level card are preserved verbatim so the whole model can
            # be rebuilt from the edited FEM without losing data.
            other_card_lines.append([current_component] + list(raw_lines))

    if not nodes:
        raise FemMeshError("FEM selection contains no GRID cards: {}".format(path))
    elements = {}
    known_node_ids = set(nodes)
    element_properties = {}
    for line_number, element_id, property_id, card, node_ids in pending_elements:
        if element_id in elements:
            raise FemMeshError("duplicate element {} at line {}".format(element_id, line_number))
        missing = sorted(set(node_ids) - known_node_ids)
        if missing:
            raise FemMeshError(
                "{} {} references missing GRID IDs {}".format(card, element_id, missing)
            )
        points = [nodes[node_id] for node_id in node_ids]
        area = _triangle_area(points[0], points[1], points[2])
        if card == "CQUAD4": area += _triangle_area(points[0], points[2], points[3])
        if area <= 1.0e-12:
            skipped_degenerate_elements.append(element_id)
            continue
        elements[element_id] = Element(element_id, component_id, card, node_ids)
        element_properties[element_id] = property_id
    component = Component(component_id, str(component_name), "SHELL")
    model = MeshModel({component_id: component}, nodes, elements)
    model.element_properties = element_properties
    model.pshell = properties
    model.materials = materials
    model.skipped_element_cards = skipped_element_cards
    model.skipped_degenerate_elements = sorted(skipped_degenerate_elements)
    model.other_card_lines = other_card_lines
    return model


def read_shell_fem_bundle(manifest_path):
    """Read one selected-components FEM and restore HyperMesh component ownership."""
    manifest_path = Path(manifest_path)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        raise FemMeshError("invalid selected-component FEM manifest: {}".format(exc)) from exc
    if manifest.get("format") not in ("hm_selected_components_fem", "hm_auto_shell_seam_fem", "hm_model_fem"):
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
    model = MeshModel(components, raw_model.nodes, elements)
    model.element_properties = dict(getattr(raw_model, "element_properties", {}))
    model.pshell = dict(getattr(raw_model, "pshell", {}))
    model.materials = dict(getattr(raw_model, "materials", {}))
    model.skipped_element_cards = dict(getattr(raw_model, "skipped_element_cards", {}))
    model.skipped_degenerate_elements = list(getattr(raw_model, "skipped_degenerate_elements", []))
    model.other_card_lines = list(getattr(raw_model, "other_card_lines", []))
    model.component_metadata = {int(entry["component_id"]): dict(entry) for entry in entries}
    return model
