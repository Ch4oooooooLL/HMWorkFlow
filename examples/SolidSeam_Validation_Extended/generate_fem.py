#!/usr/bin/env python3
"""Generate an extended meshed OptiStruct FEM for Solid Seam Connector validation.

Extends examples/SolidSeam_Validation with thirteen scenarios covering every
joint classification (T / LAP / BUTT / ANGLED), closed-loop perimeter, mixed
element types, multi-component matrices, and the negative controls
(excessive gap, mixed-component block, sub-minimum weld length, chain split
at a 90-degree elbow).

All scenarios share one deck and are separated along global X. Solids are
plate-like and multi-element; shells are regular multi-element grids.
Components never share nodes at the joint (assembled-part semantics).

Only the Python standard library is required (Python 3.8+).
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

Point = Tuple[float, float, float]
Vec = Tuple[float, float, float]
CASE_PITCH = 320.0
GAP = 5.0

EXPECTED_RESULTS = {
    "S01": {"analyzed_pair_count": 1, "candidate_count": 2, "closed_candidate_count": 0},
    "S02": {"analyzed_pair_count": 1, "candidate_count": 1, "closed_candidate_count": 0},
    "S03": {"analyzed_pair_count": 1, "candidate_count": 1, "closed_candidate_count": 0},
    "S04": {"analyzed_pair_count": 1, "candidate_count": 1, "closed_candidate_count": 0},
    "S05": {"analyzed_pair_count": 1, "candidate_count": 2, "closed_candidate_count": 0},
    "S06": {"analyzed_pair_count": 1, "candidate_count": 1, "closed_candidate_count": 1},
    "S07": {"analyzed_pair_count": 2, "candidate_count": 4, "closed_candidate_count": 0},
    "S08": {"analyzed_pair_count": 1, "candidate_count": 4, "closed_candidate_count": 0},
    "S09": {"analyzed_pair_count": 1, "candidate_count": 4, "closed_candidate_count": 0},
    "S10": {"analyzed_pair_count": 1, "candidate_count": 0, "closed_candidate_count": 0},
    "S11": {"analyzed_pair_count": 0, "candidate_count": None, "closed_candidate_count": None},
    "S12": {"analyzed_pair_count": 1, "candidate_count": 0, "closed_candidate_count": 0},
    "S13": {"analyzed_pair_count": 1, "candidate_count": 2, "closed_candidate_count": 0},
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


def addv(a: Vec, b: Vec) -> Vec:
    return a[0] + b[0], a[1] + b[1], a[2] + b[2]


def scale(a: Vec, value: float) -> Vec:
    return a[0] * value, a[1] * value, a[2] * value


def lin(a: Vec, b: Vec, t: float) -> Vec:
    return a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t


def add_shell_grid(model: Model, component_id: int, origin: Point, u: Vec, v: Vec, nu: int, nv: int, property_id: int = 0) -> List[int]:
    """Add a regular CQUAD4 grid spanning origin + [0,u] + [0,v]."""
    grid: Dict[Tuple[int, int], int] = {}
    for j in range(nv + 1):
        for i in range(nu + 1):
            point = add(origin, addv(scale(u, i / float(nu)), scale(v, j / float(nv))))
            grid[(i, j)] = model.node(point)
    elements = []
    for j in range(nv):
        for i in range(nu):
            elements.append(model.element(component_id, "CQUAD4", (grid[(i, j)], grid[(i + 1, j)], grid[(i + 1, j + 1)], grid[(i, j + 1)]), property_id))
    return elements


def add_box_solid(model: Model, component_id: int, origin: Point, u: Vec, v: Vec, w: Vec, nu: int, nv: int, nw: int, property_id: int = 0, card: str = "CHEXA") -> List[int]:
    """Mesh a (possibly skewed) parallelepiped spanned by u, v, w from origin."""
    grid: Dict[Tuple[int, int, int], int] = {}
    for k in range(nw + 1):
        for j in range(nv + 1):
            for i in range(nu + 1):
                point = add(origin, addv(addv(scale(u, i / float(nu)), scale(v, j / float(nv))), scale(w, k / float(nw))))
                grid[(i, j, k)] = model.node(point)
    result = []
    if card == "CHEXA":
        for k in range(nw):
            for j in range(nv):
                for i in range(nu):
                    nodes = (grid[(i, j, k)], grid[(i + 1, j, k)], grid[(i + 1, j + 1, k)], grid[(i, j + 1, k)],
                             grid[(i, j, k + 1)], grid[(i + 1, j, k + 1)], grid[(i + 1, j + 1, k + 1)], grid[(i, j + 1, k + 1)])
                    result.append(model.element(component_id, "CHEXA", nodes, property_id))
    else:  # CPENTA: split each hexa into two wedges along a stable diagonal.
        for k in range(nw):
            for j in range(nv):
                for i in range(nu):
                    c = (grid[(i, j, k)], grid[(i + 1, j, k)], grid[(i + 1, j + 1, k)], grid[(i, j + 1, k)],
                         grid[(i, j, k + 1)], grid[(i + 1, j, k + 1)], grid[(i + 1, j + 1, k + 1)], grid[(i, j + 1, k + 1)])
                    result.append(model.element(component_id, "CPENTA", (c[0], c[1], c[2], c[4], c[5], c[6])))
                    result.append(model.element(component_id, "CPENTA", (c[0], c[2], c[3], c[4], c[6], c[7])))
    return result


def add_hexa_plate(model: Model, component_id: int, origin: Point, size: Point, divisions: Tuple[int, int, int], property_id: int = 0) -> List[int]:
    return add_box_solid(model, component_id, origin, (size[0], 0, 0), (0, size[1], 0), (0, 0, size[2]), divisions[0], divisions[1], divisions[2], property_id, "CHEXA")


def add_tetra_plate(model: Model, component_id: int, origin: Point, size: Point, divisions: Tuple[int, int, int]) -> List[int]:
    grid = structured_nodes(model, origin, size, divisions)
    nx, ny, nz = divisions
    result = []
    local_tets = ((0, 1, 2, 6), (0, 2, 3, 6), (0, 3, 7, 6), (0, 7, 4, 6), (0, 4, 5, 6), (0, 5, 1, 6))
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                corners = (grid[(i, j, k)], grid[(i + 1, j, k)], grid[(i + 1, j + 1, k)], grid[(i, j + 1, k)],
                           grid[(i, j, k + 1)], grid[(i + 1, j, k + 1)], grid[(i + 1, j + 1, k + 1)], grid[(i, j + 1, k + 1)])
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
                c = (grid[(i, j, k)], grid[(i + 1, j, k)], grid[(i + 1, j + 1, k)], grid[(i, j + 1, k)],
                     grid[(i, j, k + 1)], grid[(i + 1, j, k + 1)], grid[(i + 1, j + 1, k + 1)], grid[(i, j + 1, k + 1)])
                center = model.node((origin[0] + size[0] * (i + 0.5) / nx, origin[1] + size[1] * (j + 0.5) / ny, origin[2] + size[2] * (k + 0.5) / nz))
                for face in ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)):
                    result.append(model.element(component_id, "CPYRA", tuple(c[index] for index in face) + (center,)))
    return result


def structured_nodes(model: Model, origin: Point, size: Point, divisions: Tuple[int, int, int]) -> Dict[Tuple[int, int, int], int]:
    nx, ny, nz = divisions
    grid = {}
    for k in range(nz + 1):
        for j in range(ny + 1):
            for i in range(nx + 1):
                grid[(i, j, k)] = model.node((origin[0] + size[0] * i / nx, origin[1] + size[1] * j / ny, origin[2] + size[2] * k / nz))
    return grid


def horizontal_target(model: Model, component_id: int, x0: float, y0: float, z: float, length: float, width: float, nx: int, ny: int) -> None:
    add_shell_grid(model, component_id, (x0, y0, z), (length, 0, 0), (0, width, 0), nx, ny)


def add_case(model: Model, case_id: str, title: str, component_ids: Sequence[int], expected_mode: str, expected: str, settings: Dict[str, object] = None, projection_check: str = "", notes: str = "") -> None:
    model.cases.append({"case_id": case_id, "title": title, "component_ids": list(component_ids), "component_names": [model.components[item].name for item in component_ids], "expected_mode": expected_mode, "expected": expected, "expected_results": EXPECTED_RESULTS[case_id], "settings": settings or {}, "projection_check": projection_check, "notes": notes})


def build_required_cases(model: Model) -> None:
    # S01: T_JOINT. Vertical CHEXA plate on a large shell; the two 80 mm side
    # footprints become the candidate chains.
    x = 0.0
    model.component(101, "S01_SOLID_T_PLATE", "SOLID", 3)
    model.component(102, "S01_SHELL_BASE", "SHELL", 6)
    add_hexa_plate(model, 101, (x + 20, 30, GAP), (80, 10, 50), (8, 2, 5))
    horizontal_target(model, 102, x, 0, 0, 120, 70, 12, 7)
    add_case(model, "S01", "vertical CHEXA plate on a large shell (T)", (101, 102), "SOLID_SHELL_PAIR", "two long T-seam candidates along the two sides of the plate footprint", projection_check="solid footprint x=[20,100], y=[30,40] is fully inside shell x=[0,120], y=[0,70]")

    # S02: LAP_JOINT. Two horizontal solid plates, the upper one overlapping
    # the lower one by 40 x 40 mm; normals are parallel so the classifier
    # resolves to LAP (low boundary ratio).
    x = CASE_PITCH
    model.component(201, "S02_SOLID_LAP_LOWER", "SOLID", 4)
    model.component(202, "S02_SOLID_LAP_UPPER", "SOLID", 5)
    add_hexa_plate(model, 201, (x, 0, 0), (100, 60, 8), (10, 6, 2))
    add_hexa_plate(model, 202, (x - 20, 10, 13), (60, 40, 8), (6, 4, 2))
    add_case(model, "S02", "two horizontal solid plates in 40 mm lap overlap", (201, 202), "SOLID_SOLID_PAIR", "LAP joint candidate along the overlap region", projection_check="upper plate overlap region x=[x,x+40], y=[10,50] lies on the lower plate x=[x,x+100], y=[0,60]", notes="the overhanging part of the upper plate has no support and is not a candidate")

    # S03: BUTT_JOINT. Two vertical plates end-to-end with a 1 mm gap; both
    # normals are parallel and the end faces dominate -> BUTT classification.
    x = 2 * CASE_PITCH
    model.component(301, "S03_SOLID_BUTT_A", "SOLID", 3)
    model.component(302, "S03_SOLID_BUTT_B", "SOLID", 4)
    add_box_solid(model, 301, (x, 10, 20), (80, 0, 0), (0, 10, 0), (0, 0, 30), 8, 2, 3)
    add_box_solid(model, 302, (x, 21, 20), (80, 0, 0), (0, 10, 0), (0, 0, 30), 8, 2, 3)
    add_case(model, "S03", "two vertical plates butt-joined with 1 mm gap", (301, 302), "SOLID_SOLID_PAIR", "BUTT joint candidate along the vertical end-face chain", projection_check="end faces at y=20 / y=21 face each other over the full 80 x 30 extent", notes="gap of 1 mm is far below the adaptive realization tolerance")

    # S04: ANGLED_JOINT. A horizontal plate meets a plate tilted 30 deg from
    # the horizontal; the 30 deg normal angle maps to ANGLED_JOINT.
    x = 3 * CASE_PITCH
    model.component(401, "S04_SOLID_HORIZONTAL", "SOLID", 3)
    model.component(402, "S04_SOLID_ANGLED", "SOLID", 5)
    add_hexa_plate(model, 401, (x, 20, 5), (80, 30, 10), (8, 3, 2))
    cos30, sin30 = math.cos(math.radians(30.0)), math.sin(math.radians(30.0))
    add_box_solid(model, 402, (x + 81, 25, 5), (80, 0, 0), (0, -sin30, cos30), (0, cos30, sin30), 8, 2, 4)
    add_case(model, "S04", "horizontal plate against a 30 deg tilted plate", (401, 402), "SOLID_SOLID_PAIR", "ANGLED joint candidate at the tilted end faces", projection_check="both end faces overlap a vertical band 80 mm long; gap is 1 mm", notes="30 deg normal angle is inside the ANGLED band (20..40 deg)")

    # S05: Solid-Solid T. Vertical plate standing on a horizontal solid base.
    x = 4 * CASE_PITCH
    model.component(501, "S05_SOLID_BASE", "SOLID", 4)
    model.component(502, "S05_SOLID_VERT", "SOLID", 3)
    add_hexa_plate(model, 501, (x, 0, 0), (140, 80, 10), (14, 8, 2))
    add_hexa_plate(model, 502, (x + 30, 35, 15), (80, 10, 50), (8, 2, 5))
    add_case(model, "S05", "vertical CHEXA plate on a solid base (Solid-Solid T)", (501, 502), "SOLID_SOLID_PAIR", "two T candidates along the vertical plate sides", projection_check="vertical plate footprint x=[x+30,x+110], y=[35,45] is fully inside the base projection")

    # S06: closed perimeter. Horizontal plate on a shell; the perimeter chain
    # is closed when the turn-angle limit is relaxed (mirrors SolidSeam C07).
    x = 5 * CASE_PITCH
    model.component(601, "S06_SOLID_CLOSED_PLATE", "SOLID", 3)
    model.component(602, "S06_SHELL_UNDER", "SHELL", 6)
    add_hexa_plate(model, 601, (x + 20, 20, GAP), (80, 60, 12), (8, 6, 2))
    horizontal_target(model, 602, x, 0, 0, 120, 100, 12, 10)
    add_case(model, "S06", "closed bottom perimeter of a horizontal plate", (601, 602), "SOLID_SHELL_PAIR", "one closed perimeter candidate with max_chain_turn_angle_deg=100", {"max_chain_turn_angle_deg": 100.0, "allow_closed_loop": True}, "the full 80 x 60 plate projection is inside the 120 x 100 shell")

    # S07: 2 vertical solids x 1 shell -> two analyzed pairs, four candidates.
    x = 6 * CASE_PITCH
    model.component(701, "S07_SOLID_A", "SOLID", 3)
    model.component(702, "S07_SOLID_B", "SOLID", 4)
    model.component(703, "S07_SHELL_BASE", "SHELL", 6)
    add_hexa_plate(model, 701, (x + 20, 30, GAP), (60, 12, 50), (6, 2, 5))
    add_hexa_plate(model, 702, (x + 110, 30, GAP), (60, 12, 50), (6, 2, 5))
    horizontal_target(model, 703, x, 0, 0, 190, 80, 19, 8)
    add_case(model, "S07", "two vertical solids on one common shell", (701, 702, 703), "MULTI_SOLID_SHELL", "two Solid-Shell pairs, four T candidates", projection_check="both footprints x=[x+20,x+80] and x=[x+110,x+170], y=[30,42] are inside the shell")

    # S08: CTETRA horizontal plate on a shell. With the default turn-angle
    # limit the closed perimeter splits into four edge candidates.
    x = 7 * CASE_PITCH
    model.component(801, "S08_SOLID_TETRA", "SOLID", 5)
    model.component(802, "S08_SHELL_BASE", "SHELL", 6)
    add_tetra_plate(model, 801, (x + 20, 20, GAP), (80, 60, 12), (8, 6, 1))
    horizontal_target(model, 802, x, 0, 0, 120, 100, 12, 10)
    add_case(model, "S08", "meshed CTETRA horizontal plate", (801, 802), "SOLID_SHELL_PAIR", "CTETRA plate classified as SOLID produces four bottom-edge candidates", projection_check="80 x 60 projection is fully inside 120 x 100 shell")

    # S09: CPENTA + CPYRA elements in one solid plate on a shell.
    x = 8 * CASE_PITCH
    model.component(901, "S09_SOLID_PENTA_PYRA", "SOLID", 7)
    model.component(902, "S09_SHELL_BASE", "SHELL", 8)
    add_box_solid(model, 901, (x + 20, 20, GAP), (40, 0, 0), (0, 60, 0), (0, 0, 12), 4, 6, 1, card="CPENTA")
    add_pyra_plate(model, 901, (x + 60, 20, GAP), (40, 60, 12), (4, 6, 1))
    horizontal_target(model, 902, x, 0, 0, 120, 100, 12, 10)
    add_case(model, "S09", "mixed CPENTA + CPYRA plate on a shell", (901, 902), "SOLID_SHELL_PAIR", "solid mixed-mesh plate produces bottom-edge candidates", projection_check="80 x 60 combined projection is fully inside 120 x 100 shell", notes="CPENTA and CPYRA live in one component; the classifier must handle the mixed element set")

    # S10: same valid projection but gap 60 mm exceeds max_search_distance.
    x = 9 * CASE_PITCH
    model.component(1001, "S10_SOLID_FAR", "SOLID", 3)
    model.component(1002, "S10_SHELL_BASE", "SHELL", 2)
    add_hexa_plate(model, 1001, (x + 20, 30, 60), (80, 10, 50), (8, 2, 5))
    horizontal_target(model, 1002, x, 0, 0, 120, 70, 12, 7)
    add_case(model, "S10", "valid projection but excessive 60 mm gap", (1001, 1002), "SOLID_SHELL_PAIR", "zero candidates with default max_search_distance=25", projection_check="projection is contained; only the 60 mm gap makes the case invalid")

    # S11: mixed mesh (solid + shell) in one component is blocked up front.
    x = 10 * CASE_PITCH
    model.component(1101, "S11_MIXED_BLOCKED", "MIXED", 2)
    model.component(1102, "S11_SHELL_TARGET", "SHELL", 6)
    model.property(11011, "PSOLID", "S11_MIXED_SOLID_PROP")
    model.property(11012, "PSHELL", "S11_MIXED_SHELL_PROP")
    add_hexa_plate(model, 1101, (x + 20, 20, GAP), (80, 60, 10), (8, 6, 2), 11011)
    add_shell_grid(model, 1101, (x, 0, 30), (120, 0, 0), (0, 100, 0), 12, 10, 11012)
    horizontal_target(model, 1102, x, 0, 0, 120, 100, 12, 10)
    add_case(model, "S11", "mixed solid+shell component is rejected", (1101, 1102), "BLOCKED", "component 1101 is MIXED and recognition does not start", notes="if the importer ignores $HMCOMP ID, move both element types into one component manually")

    # S12: sub-minimum weld length. The 12 mm footprint is below
    # min_weld_length=20 so no candidate survives.
    x = 11 * CASE_PITCH
    model.component(1201, "S12_SOLID_SHORT", "SOLID", 3)
    model.component(1202, "S12_SHELL_BASE", "SHELL", 6)
    add_hexa_plate(model, 1201, (x + 20, 30, GAP), (12, 10, 40), (2, 2, 4))
    horizontal_target(model, 1202, x, 0, 0, 120, 70, 12, 7)
    add_case(model, "S12", "footprint shorter than min_weld_length", (1201, 1202), "SOLID_SHELL_PAIR", "no candidate; the 12 mm edges are below min_weld_length=20", projection_check="solid footprint x=[x+20,x+32], y=[30,40] is inside the shell")

    # S13: L-shaped vertical plate. The bottom chain turns 90 deg at the
    # elbow; with the default max_chain_turn_angle_deg=60 the chain splits
    # into two straight candidates.
    x = 12 * CASE_PITCH
    model.component(1301, "S13_SOLID_ELBOW", "SOLID", 5)
    model.component(1302, "S13_SHELL_BASE", "SHELL", 6)
    add_box_solid(model, 1301, (x + 10, 20, GAP), (70, 0, 0), (0, 10, 0), (0, 0, 50), 7, 2, 5)
    add_box_solid(model, 1301, (x + 70, 20, GAP), (10, 0, 0), (0, 70, 0), (0, 0, 50), 2, 7, 5)
    horizontal_target(model, 1302, x, 0, 0, 110, 110, 11, 11)
    add_case(model, "S13", "L-shaped elbow plate on a shell (chain split)", (1301, 1302), "SOLID_SHELL_PAIR", "the 90 deg elbow splits the perimeter into two straight candidates", projection_check="the full L footprint x=[x+10,x+80], y=[20,90] is inside the shell", notes="with max_chain_turn_angle_deg=100 the two candidates would merge into one L chain")


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
    if len(model.cases) != 13:
        errors.append("expected exactly 13 selectable cases")
    if {case["case_id"] for case in model.cases} != set(EXPECTED_RESULTS):
        errors.append("case IDs do not match EXPECTED_RESULTS")
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors))
    return {"nodes": len(model.nodes), "elements": len(model.elements), "components": len(model.components), "cases": len(model.cases), **{card.lower(): sum(item.card == card for item in model.elements.values()) for card in expected}}


def card_lines(element: Element) -> List[str]:
    fields = [element.card, str(element.element_id), str(element.property_id)] + [str(node) for node in element.node_ids]
    return [",".join(fields)] if len(fields) <= 9 else [",".join(fields[:9]), ",".join(["+"] + fields[9:])]


def write_fem(model: Model, output: Path) -> None:
    lines = ["$ Solid Seam extended validation deck", "$ 13 scenarios: T / LAP / BUTT / ANGLED / closed loop / mixed / negative controls", "$ Generated by examples/SolidSeam_Validation_Extended/generate_fem.py", "$ Units: mm, N, MPa. Test geometry only.", "BEGIN BULK", '$HMNAME MAT 1 "SSVE_STEEL"', "MAT1,1,210000.0,,0.3,7.85E-9", "$ PROPERTIES"]
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
    return {"schema_version": "1.0", "generator": "examples/SolidSeam_Validation_Extended/generate_fem.py", "fem": "SolidSeam_Extended_Validation.fem", "geometry_rules": {"solid_shape": "plate-like; two in-plane dimensions exceed thickness", "t_joint_projection": "complete solid projection must lie inside target shell plane", "default_gap": GAP, "case_pitch": CASE_PITCH, "joint_classification": "normal-angle closest <= 20 deg parallel (BUTT high boundary ratio / LAP otherwise), |closest-90| <= 20 deg T, 20..40 deg ANGLED"}, "statistics": stats, "default_detection_settings": {"search_distance": 15.0, "max_search_distance": 25.0, "min_weld_length": 20.0, "min_valid_ratio": 0.7, "feature_angle_deg": 35.0, "max_chain_turn_angle_deg": 60.0}, "cases": model.cases, "components": [{"component_id": item.component_id, "name": item.name, "mesh_class": item.mesh_class, "element_count": len(item.element_ids), "element_ids": item.element_ids} for item in sorted(model.components.values(), key=lambda value: value.component_id)], "warning": "Geometry-only validation deck. Candidate counts are topological predictions; the exact realization output is decided by HyperMesh 2019/2022."}


def parse_args() -> argparse.Namespace:
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=directory / "SolidSeam_Extended_Validation.fem")
    parser.add_argument("--manifest", type=Path, default=directory / "SolidSeam_Extended_Validation_manifest.json")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    model = Model()
    build_required_cases(model)
    stats = validate(model)
    write_fem(model, args.output.resolve())
    validate_written_fem(args.output.resolve(), stats)
    args.manifest.resolve().write_text(json.dumps(manifest(model, stats), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"fem": str(args.output.resolve()), "manifest": str(args.manifest.resolve()), **stats}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
