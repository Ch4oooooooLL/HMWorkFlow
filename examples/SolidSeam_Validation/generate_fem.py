#!/usr/bin/env python3
"""Generate one meshed, plate-like OptiStruct FEM for Solid Seam validation.

All scenarios are placed in one deck and separated along global X. Positive
T-joint cases use a large target shell which fully contains the orthogonal
projection of the source solid plate. Solids and shells are intentionally
multi-element meshes rather than one-element visual placeholders.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple

Point = Tuple[float, float, float]
CASE_PITCH = 320.0
GAP = 5.0
EXPECTED_RESULTS = {
    "C01": {"analyzed_pair_count": 1, "candidate_count": 2, "closed_candidate_count": 0},
    "C02": {"analyzed_pair_count": 2, "candidate_count": 4, "closed_candidate_count": 0},
    "C03": {"analyzed_pair_count": 1, "candidate_count": 4, "closed_candidate_count": 0},
    "C04": {"analyzed_pair_count": 4, "candidate_count": 8, "closed_candidate_count": 0},
    "C05": {"analyzed_pair_count": 2, "candidate_count": 2, "closed_candidate_count": 0},
    "C06": {"analyzed_pair_count": 1, "candidate_count": 0, "closed_candidate_count": 0},
    "C07": {"analyzed_pair_count": 1, "candidate_count": 1, "closed_candidate_count": 1},
    "C08A": {"analyzed_pair_count": 1, "candidate_count": 4, "closed_candidate_count": 0},
    "C08B": {"analyzed_pair_count": 1, "candidate_count": 4, "closed_candidate_count": 0},
    "C09": {"analyzed_pair_count": 0, "candidate_count": None, "closed_candidate_count": None},
    "C10": {"analyzed_pair_count": 0, "candidate_count": None, "closed_candidate_count": None},
    "C11": {"analyzed_pair_count": 6, "candidate_count": 20, "closed_candidate_count": 0},
}


@dataclass(frozen=True)
class Element:
    card: str
    element_id: int
    property_id: int
    node_ids: Tuple[int, ...]


@dataclass
class Component:
    component_id: int
    name: str
    mesh_class: str
    color: int
    element_ids: List[int] = field(default_factory=list)


@dataclass
class Model:
    nodes: Dict[int, Point] = field(default_factory=dict)
    elements: Dict[int, Element] = field(default_factory=dict)
    components: Dict[int, Component] = field(default_factory=dict)
    properties: Dict[int, Tuple[str, str]] = field(default_factory=dict)
    cases: List[Dict[str, object]] = field(default_factory=list)
    next_node_id: int = 1
    next_element_id: int = 1

    def component(self, component_id: int, name: str, mesh_class: str, color: int = 11) -> Component:
        if component_id in self.components:
            raise ValueError("duplicate component ID {}".format(component_id))
        item = Component(component_id, name, mesh_class, color)
        self.components[component_id] = item
        if mesh_class in ("SOLID", "SHELL"):
            card = "PSOLID" if mesh_class == "SOLID" else "PSHELL"
            self.properties[component_id] = (card, name + "_" + card)
        return item

    def property(self, property_id: int, card: str, name: str) -> None:
        self.properties[property_id] = (card, name)

    def node(self, point: Point) -> int:
        node_id = self.next_node_id
        self.next_node_id += 1
        self.nodes[node_id] = tuple(float(value) for value in point)
        return node_id

    def element(self, component_id: int, card: str, node_ids: Sequence[int], property_id: int = 0) -> int:
        element_id = self.next_element_id
        self.next_element_id += 1
        item = Element(card, element_id, property_id or component_id, tuple(node_ids))
        self.elements[element_id] = item
        self.components[component_id].element_ids.append(element_id)
        return element_id


def add(a: Point, b: Point) -> Point:
    return a[0] + b[0], a[1] + b[1], a[2] + b[2]


def scale(a: Point, value: float) -> Point:
    return a[0] * value, a[1] * value, a[2] * value


def add_shell_grid(model: Model, component_id: int, origin: Point, u: Point, v: Point, nu: int, nv: int, property_id: int = 0) -> List[int]:
    """Add a regular CQUAD4 grid spanning origin + [0,u] + [0,v]."""
    grid: Dict[Tuple[int, int], int] = {}
    for j in range(nv + 1):
        for i in range(nu + 1):
            point = add(origin, add(scale(u, i / float(nu)), scale(v, j / float(nv))))
            grid[(i, j)] = model.node(point)
    elements = []
    for j in range(nv):
        for i in range(nu):
            elements.append(model.element(component_id, "CQUAD4", (grid[(i, j)], grid[(i + 1, j)], grid[(i + 1, j + 1)], grid[(i, j + 1)]), property_id))
    return elements


def structured_nodes(model: Model, origin: Point, size: Point, divisions: Tuple[int, int, int]) -> Dict[Tuple[int, int, int], int]:
    nx, ny, nz = divisions
    grid = {}
    for k in range(nz + 1):
        for j in range(ny + 1):
            for i in range(nx + 1):
                grid[(i, j, k)] = model.node((origin[0] + size[0] * i / nx, origin[1] + size[1] * j / ny, origin[2] + size[2] * k / nz))
    return grid


def add_hexa_plate(model: Model, component_id: int, origin: Point, size: Point, divisions: Tuple[int, int, int], property_id: int = 0) -> List[int]:
    grid = structured_nodes(model, origin, size, divisions)
    nx, ny, nz = divisions
    result = []
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                nodes = (grid[(i, j, k)], grid[(i + 1, j, k)], grid[(i + 1, j + 1, k)], grid[(i, j + 1, k)], grid[(i, j, k + 1)], grid[(i + 1, j, k + 1)], grid[(i + 1, j + 1, k + 1)], grid[(i, j + 1, k + 1)])
                result.append(model.element(component_id, "CHEXA", nodes, property_id))
    return result


def add_tetra_plate(model: Model, component_id: int, origin: Point, size: Point, divisions: Tuple[int, int, int]) -> List[int]:
    grid = structured_nodes(model, origin, size, divisions)
    nx, ny, nz = divisions
    result = []
    local_tets = ((0, 1, 2, 6), (0, 2, 3, 6), (0, 3, 7, 6), (0, 7, 4, 6), (0, 4, 5, 6), (0, 5, 1, 6))
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                corners = (grid[(i, j, k)], grid[(i + 1, j, k)], grid[(i + 1, j + 1, k)], grid[(i, j + 1, k)], grid[(i, j, k + 1)], grid[(i + 1, j, k + 1)], grid[(i + 1, j + 1, k + 1)], grid[(i, j + 1, k + 1)])
                for template in local_tets:
                    result.append(model.element(component_id, "CTETRA", tuple(corners[index] for index in template)))
    return result


def add_pyra_plate(model: Model, component_id: int, origin: Point, size: Point, divisions: Tuple[int, int, int]) -> List[int]:
    grid = structured_nodes(model, origin, size, divisions)
    nx, ny, nz = divisions
    result = []
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                c = (grid[(i, j, k)], grid[(i + 1, j, k)], grid[(i + 1, j + 1, k)], grid[(i, j + 1, k)], grid[(i, j, k + 1)], grid[(i + 1, j, k + 1)], grid[(i + 1, j + 1, k + 1)], grid[(i, j + 1, k + 1)])
                center = model.node((origin[0] + size[0] * (i + 0.5) / nx, origin[1] + size[1] * (j + 0.5) / ny, origin[2] + size[2] * (k + 0.5) / nz))
                for face in ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)):
                    result.append(model.element(component_id, "CPYRA", tuple(c[index] for index in face) + (center,)))
    return result


def add_penta_plate(model: Model, component_id: int, origin: Point, length: float = 80.0, width: float = 50.0, thickness: float = 10.0, divisions: int = 6) -> List[int]:
    """Mesh a right-triangular plate and extrude it through its thickness."""
    layers: List[Dict[Tuple[int, int], int]] = []
    for z in (0.0, thickness):
        layer = {}
        for j in range(divisions + 1):
            for i in range(divisions + 1 - j):
                layer[(i, j)] = model.node((origin[0] + length * i / divisions, origin[1] + width * j / divisions, origin[2] + z))
        layers.append(layer)
    triangles = []
    for j in range(divisions):
        for i in range(divisions - j):
            triangles.append(((i, j), (i + 1, j), (i, j + 1)))
            if i + j <= divisions - 2:
                triangles.append(((i + 1, j), (i + 1, j + 1), (i, j + 1)))
    result = []
    for triangle in triangles:
        result.append(model.element(component_id, "CPENTA", tuple(layers[0][key] for key in triangle) + tuple(layers[1][key] for key in triangle)))
    return result


def add_case(model: Model, case_id: str, title: str, component_ids: Sequence[int], expected_mode: str, expected: str, settings: Dict[str, object] = None, projection_check: str = "", notes: str = "") -> None:
    model.cases.append({"case_id": case_id, "title": title, "component_ids": list(component_ids), "component_names": [model.components[item].name for item in component_ids], "expected_mode": expected_mode, "expected": expected, "expected_results": EXPECTED_RESULTS[case_id], "settings": settings or {}, "projection_check": projection_check, "notes": notes})


def horizontal_target(model: Model, component_id: int, x0: float, y0: float, z: float, length: float, width: float, nx: int, ny: int) -> None:
    add_shell_grid(model, component_id, (x0, y0, z), (length, 0, 0), (0, width, 0), nx, ny)


def build_required_cases(model: Model) -> None:
    # C01: vertical plate 80 x 50 x 10 above a 120 x 70 shell. Its complete
    # 80 x 10 footprint is inside the shell with >=20 mm margin.
    x = 0.0
    model.component(101, "C01_SOLID_VERTICAL_PLATE", "SOLID", 3)
    model.component(102, "C01_SHELL_BASE_LARGE", "SHELL", 6)
    add_hexa_plate(model, 101, (x + 20, 30, GAP), (80, 10, 50), (8, 2, 5))
    horizontal_target(model, 102, x, 0, 0, 120, 70, 12, 7)
    add_case(model, "C01", "meshed vertical CHEXA plate on a large shell", (101, 102), "SOLID_SHELL_PAIR", "two long T-seam candidates along the two sides of the plate footprint", projection_check="solid footprint x=[20,100], y=[30,40] is fully inside shell x=[0,120], y=[0,70]")

    # C02: two meshed vertical plates on one common large shell.
    x = CASE_PITCH
    model.component(201, "C02_SOLID_PLATE_A", "SOLID", 3)
    model.component(202, "C02_SOLID_PLATE_B", "SOLID", 4)
    model.component(203, "C02_SHELL_COMMON_LARGE", "SHELL", 6)
    add_hexa_plate(model, 201, (x + 20, 30, GAP), (60, 10, 40), (6, 2, 4))
    add_hexa_plate(model, 202, (x + 110, 30, GAP), (60, 10, 40), (6, 2, 4))
    horizontal_target(model, 203, x, 0, 0, 190, 70, 19, 7)
    add_case(model, "C02", "two meshed CHEXA plates on one large shell", (201, 202, 203), "MULTI_SOLID_SHELL", "two Solid-Shell pairs; each plate contributes two long T-seam candidates", projection_check="both 60 x 10 footprints are fully inside the 190 x 70 shell")

    # C03: triangular plate 80 x 50 x 10. Two orthogonal shell grids fully
    # contain the projections of the x=0 and y=0 rectangular side faces.
    x = 2 * CASE_PITCH
    model.component(301, "C03_SOLID_RIGHT_PENTA_PLATE", "SOLID", 5)
    model.component(302, "C03_SHELL_L_SECTION_LARGE", "SHELL", 9)
    add_penta_plate(model, 301, (x + 20, 20, 20), 80, 50, 10, 6)
    add_shell_grid(model, 302, (x + 15, 10, 10), (0, 70, 0), (0, 0, 30), 7, 3)
    add_shell_grid(model, 302, (x + 10, 15, 10), (100, 0, 0), (0, 0, 30), 10, 3)
    add_case(model, "C03", "meshed CPENTA triangular plate with two large orthogonal shells", (301, 302), "SOLID_SHELL_PAIR", "candidate chains are found on both orthogonal rectangular faces", projection_check="the full 50 x 10 and 80 x 10 side-face projections are inside the two shell grids")

    # C04: horizontal 80 x 60 x 10 solid plate with one larger shell outside
    # each of its four edge faces. Every side projection is fully contained.
    x = 3 * CASE_PITCH
    model.component(401, "C04_SOLID_HORIZONTAL_PLATE", "SOLID", 3)
    for component_id, name, color in ((402, "C04_SHELL_FRONT_LARGE", 6), (403, "C04_SHELL_RIGHT_LARGE", 7), (404, "C04_SHELL_BACK_LARGE", 8), (405, "C04_SHELL_LEFT_LARGE", 9)):
        model.component(component_id, name, "SHELL", color)
    add_hexa_plate(model, 401, (x + 30, 30, 20), (80, 60, 10), (8, 6, 2))
    add_shell_grid(model, 402, (x + 20, 25, 10), (100, 0, 0), (0, 0, 30), 10, 3)
    add_shell_grid(model, 403, (x + 115, 20, 10), (0, 80, 0), (0, 0, 30), 8, 3)
    add_shell_grid(model, 404, (x + 120, 95, 10), (-100, 0, 0), (0, 0, 30), 10, 3)
    add_shell_grid(model, 405, (x + 25, 100, 10), (0, -80, 0), (0, 0, 30), 8, 3)
    add_case(model, "C04", "meshed plate with four large side shells", (401, 402, 403, 404, 405), "MULTI_SOLID_SHELL", "four Solid-Shell pairs; each shell covers one complete side-face projection", projection_check="each 80 x 10 or 60 x 10 solid side projection has at least 5 mm shell margin")


def build_additional_cases(model: Model) -> None:
    # C05: plate-like Solid-Solid T pair.
    x = 4 * CASE_PITCH
    model.component(501, "C05_SOLID_BASE_PLATE", "SOLID", 3)
    model.component(502, "C05_SOLID_VERTICAL_PLATE", "SOLID", 4)
    add_hexa_plate(model, 501, (x, 0, 0), (140, 80, 10), (14, 8, 2))
    add_hexa_plate(model, 502, (x + 30, 35, 15), (80, 10, 50), (8, 2, 5))
    add_case(model, "C05", "plate-like Solid-Solid T pair", (501, 502), "SOLID_SOLID_PAIR", "Solid-Solid mode is enabled and detects the nearby vertical plate footprint", projection_check="vertical plate footprint is fully inside the horizontal solid base projection")

    # C06: same valid projection but gap exceeds max_search_distance.
    x = 5 * CASE_PITCH
    model.component(601, "C06_SOLID_VERTICAL_PLATE", "SOLID", 3)
    model.component(602, "C06_SHELL_LARGE_TOO_FAR", "SHELL", 2)
    add_hexa_plate(model, 601, (x + 20, 30, 35), (80, 10, 50), (8, 2, 5))
    horizontal_target(model, 602, x, 0, 0, 120, 70, 12, 7)
    add_case(model, "C06", "large shell but excessive gap", (601, 602), "SOLID_SHELL_PAIR", "zero candidates with default max_search_distance=25", projection_check="projection is contained; only the 35 mm gap makes the case invalid")

    # C07: horizontal plate over a larger shell; bottom perimeter is closed.
    x = 6 * CASE_PITCH
    model.component(701, "C07_SOLID_CLOSED_PLATE", "SOLID", 3)
    model.component(702, "C07_SHELL_UNDER_PLATE_LARGE", "SHELL", 6)
    add_hexa_plate(model, 701, (x + 20, 20, GAP), (80, 60, 12), (8, 6, 2))
    horizontal_target(model, 702, x, 0, 0, 120, 100, 12, 10)
    add_case(model, "C07", "closed bottom perimeter of a meshed plate", (701, 702), "SOLID_SHELL_PAIR", "one closed perimeter candidate with max_chain_turn_angle_deg=100", {"max_chain_turn_angle_deg": 100.0, "allow_closed_loop": True}, "the full 80 x 60 plate projection is inside the 120 x 100 shell")

    # C08A/B: plate-like CTETRA and CPYRA volume meshes.
    x = 7 * CASE_PITCH
    model.component(801, "C08A_SOLID_TETRA_PLATE", "SOLID", 5)
    model.component(802, "C08A_SHELL_BASE_LARGE", "SHELL", 6)
    add_tetra_plate(model, 801, (x + 20, 20, GAP), (80, 60, 12), (8, 6, 1))
    horizontal_target(model, 802, x, 0, 0, 120, 100, 12, 10)
    add_case(model, "C08A", "meshed CTETRA plate", (801, 802), "SOLID_SHELL_PAIR", "CTETRA plate is classified as SOLID and produces bottom-edge candidates", projection_check="80 x 60 projection is fully inside 120 x 100 shell")
    model.component(803, "C08B_SOLID_PYRA_PLATE", "SOLID", 7)
    model.component(804, "C08B_SHELL_BASE_LARGE", "SHELL", 8)
    add_pyra_plate(model, 803, (x + 170, 20, GAP), (80, 60, 12), (4, 3, 1))
    horizontal_target(model, 804, x + 150, 0, 0, 120, 100, 12, 10)
    add_case(model, "C08B", "meshed CPYRA plate", (803, 804), "SOLID_SHELL_PAIR", "CPYRA plate is classified as SOLID and produces bottom-edge candidates", projection_check="80 x 60 projection is fully inside 120 x 100 shell")

    # C09: two large shell grids, no solid.
    x = 8 * CASE_PITCH
    model.component(901, "C09_SHELL_ONLY_A", "SHELL", 6)
    model.component(902, "C09_SHELL_ONLY_B", "SHELL", 8)
    horizontal_target(model, 901, x, 0, 0, 120, 80, 12, 8)
    horizontal_target(model, 902, x, 0, 5, 120, 80, 12, 8)
    add_case(model, "C09", "meshed Shell-Shell rejection", (901, 902), "BLOCKED", "selection stops before Python with Shell-Shell guidance")

    # C10: multi-element CHEXA and shell grid in one HM component.
    x = 9 * CASE_PITCH
    model.component(1001, "C10_MIXED_BLOCKED", "MIXED", 2)
    model.component(1002, "C10_SHELL_TARGET_LARGE", "SHELL", 6)
    model.property(10011, "PSOLID", "C10_MIXED_SOLID_PROP")
    model.property(10012, "PSHELL", "C10_MIXED_SHELL_PROP")
    add_hexa_plate(model, 1001, (x + 20, 20, GAP), (80, 60, 10), (8, 6, 2), 10011)
    add_shell_grid(model, 1001, (x, 0, 30), (120, 0, 0), (0, 100, 0), 12, 10, 10012)
    horizontal_target(model, 1002, x, 0, 0, 120, 100, 12, 10)
    add_case(model, "C10", "multi-element Mixed component rejection", (1001, 1002), "BLOCKED", "component 1001 is MIXED and recognition does not start", notes="If the importer ignores $HMCOMP ID, move both C10 element types into one component manually.")

    # C11: 2 vertical solid plates x 3 large shell targets = 6 analyzed pairs.
    x = 10 * CASE_PITCH
    for component_id, name, mesh_class, color in ((1101, "C11_SOLID_PLATE_A", "SOLID", 3), (1102, "C11_SOLID_PLATE_B", "SOLID", 4), (1103, "C11_SHELL_BASE", "SHELL", 6), (1104, "C11_SHELL_FRONT", "SHELL", 7), (1105, "C11_SHELL_BACK", "SHELL", 8)):
        model.component(component_id, name, mesh_class, color)
    add_hexa_plate(model, 1101, (x + 20, 30, GAP), (60, 12, 50), (6, 2, 5))
    add_hexa_plate(model, 1102, (x + 110, 30, GAP), (60, 12, 50), (6, 2, 5))
    horizontal_target(model, 1103, x, 0, 0, 190, 80, 19, 8)
    add_shell_grid(model, 1104, (x, 25, 0), (190, 0, 0), (0, 0, 70), 19, 7)
    add_shell_grid(model, 1105, (x + 190, 47, 0), (-190, 0, 0), (0, 0, 70), 19, 7)
    add_case(model, "C11", "2x3 matrix with fully meshed plates and shells", (1101, 1102, 1103, 1104, 1105), "MULTI_SOLID_SHELL", "exactly six Solid-Shell pairs are analyzed and no Solid-Solid pair is analyzed", projection_check="each target shell covers the corresponding projection of both solid plates")


def validate(model: Model) -> Dict[str, int]:
    expected = {"CHEXA": 8, "CPENTA": 6, "CTETRA": 4, "CPYRA": 5, "CQUAD4": 4}
    errors = []
    for element in model.elements.values():
        if element.card not in expected or len(element.node_ids) != expected[element.card]:
            errors.append("malformed {} {}".format(element.card, element.element_id))
        if element.property_id not in model.properties:
            errors.append("element {} has missing property {}".format(element.element_id, element.property_id))
        if any(node not in model.nodes for node in element.node_ids):
            errors.append("element {} references missing nodes".format(element.element_id))
    for component in model.components.values():
        if not component.element_ids:
            errors.append("empty component {}".format(component.component_id))
        if component.mesh_class == "SOLID" and len(component.element_ids) < 4:
            errors.append("solid component {} is not sufficiently meshed".format(component.component_id))
        if component.mesh_class == "SHELL" and len(component.element_ids) < 4:
            errors.append("shell component {} is not sufficiently meshed".format(component.component_id))
    if len(model.cases) != 12:
        errors.append("expected exactly 12 selectable cases")
    if {case["case_id"] for case in model.cases} != set(EXPECTED_RESULTS):
        errors.append("case IDs do not match EXPECTED_RESULTS")
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors))
    return {"nodes": len(model.nodes), "elements": len(model.elements), "components": len(model.components), "cases": len(model.cases), **{card.lower(): sum(item.card == card for item in model.elements.values()) for card in expected}}


def card_lines(element: Element) -> List[str]:
    fields = [element.card, str(element.element_id), str(element.property_id)] + [str(node) for node in element.node_ids]
    return [",".join(fields)] if len(fields) <= 9 else [",".join(fields[:9]), ",".join(["+"] + fields[9:])]


def write_fem(model: Model, output: Path) -> None:
    lines = ["$ Solid Seam combined validation deck", "$ Multi-element plate solids and projection-containing shell targets", "$ Generated by examples/SolidSeam_Validation/generate_fem.py", "$ Units: mm, N, MPa. Test geometry only.", "BEGIN BULK", '$HMNAME MAT 1 "SSV_STEEL"', "MAT1,1,210000.0,,0.3,7.85E-9", "$ PROPERTIES"]
    for property_id, (card, name) in sorted(model.properties.items()):
        lines.append('$HMNAME PROP {} "{}"'.format(property_id, name))
        lines.append("PSOLID,{},1".format(property_id) if card == "PSOLID" else "PSHELL,{},1,1.0".format(property_id))
    lines.append("$ COMPONENT NAMES")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend(('$HMNAME COMP {} "{}"'.format(component.component_id, component.name), "$HWCOLOR COMP {} {}".format(component.component_id, component.color)))
    lines.append("$ NODES")
    for node_id, point in sorted(model.nodes.items()):
        lines.append("GRID,{},,{:.9g},{:.9g},{:.9g}".format(node_id, *point))
    lines.append("$ ELEMENTS GROUPED BY HYPERMESH COMPONENT")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend(("$HMCOMP ID {}".format(component.component_id), "$ " + component.name))
        for element_id in component.element_ids:
            lines.extend(card_lines(model.elements[element_id]))
    lines.extend(("ENDDATA", ""))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def validate_written_fem(output: Path, stats: Dict[str, int]) -> None:
    lines = output.read_text(encoding="utf-8").splitlines()
    if "BEGIN BULK" not in lines or not lines or lines[-1] != "ENDDATA":
        raise ValueError("FEM is missing BEGIN BULK or terminal ENDDATA")
    for card in ("CHEXA", "CPENTA", "CTETRA", "CPYRA", "CQUAD4"):
        actual = sum(line.startswith(card + ",") for line in lines)
        if actual != stats[card.lower()]:
            raise ValueError("written {} count {} != {}".format(card, actual, stats[card.lower()]))
    oversized = [(index, line) for index, line in enumerate(lines, 1) if line and not line.startswith("$") and len(line.split(",")) > 9]
    if oversized:
        raise ValueError("free-format card exceeds nine fields at line {}".format(oversized[0][0]))


def manifest(model: Model, stats: Dict[str, int]) -> Dict[str, object]:
    return {"schema_version": "1.1", "generator": "generate_fem.py", "fem": "SolidSeam_Combined_Validation.fem", "geometry_rules": {"solid_shape": "plate-like; two in-plane dimensions exceed thickness", "t_joint_projection": "complete solid projection must lie inside target shell plane", "default_gap": GAP, "case_pitch": CASE_PITCH}, "statistics": stats, "default_detection_settings": {"search_distance": 15.0, "max_search_distance": 25.0, "min_weld_length": 20.0, "min_valid_ratio": 0.7, "feature_angle_deg": 35.0, "max_chain_turn_angle_deg": 60.0}, "cases": model.cases, "components": [{"component_id": item.component_id, "name": item.name, "mesh_class": item.mesh_class, "element_count": len(item.element_ids), "element_ids": item.element_ids} for item in sorted(model.components.values(), key=lambda value: value.component_id)], "warning": "Geometry-only validation deck. Connector realization requires verified HM2019 command profiles."}


def parse_args() -> argparse.Namespace:
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=directory / "SolidSeam_Combined_Validation.fem")
    parser.add_argument("--manifest", type=Path, default=directory / "SolidSeam_Combined_Validation_manifest.json")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    model = Model()
    build_required_cases(model)
    build_additional_cases(model)
    stats = validate(model)
    write_fem(model, args.output.resolve())
    validate_written_fem(args.output.resolve(), stats)
    args.manifest.resolve().write_text(json.dumps(manifest(model, stats), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"fem": str(args.output.resolve()), "manifest": str(args.manifest.resolve()), **stats}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
