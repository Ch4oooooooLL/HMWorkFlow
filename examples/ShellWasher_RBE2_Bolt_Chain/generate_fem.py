#!/usr/bin/env python3
"""Generate large, continuous shell plates for washer -> RBE2 -> bolt tests.

The OptiStruct deck contains shell elements only.  Each of four large parallel
plates is a conformal multi-hole mesh: neighbouring cells share boundary nodes,
every hole has two washer layers, and corresponding holes are coaxial through
all planes so the downstream RBE2 bolt connector can create adjacent segments.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

Point = Tuple[float, float, float]

PLANE_Z = (0.0, 20.0, 40.0, 60.0)
PLATE_COLUMNS = 16
PLATE_ROWS = 12
CELL_SIZE = 120.0
OUTER_CELL_SEGMENTS = 32
SUPPORT_FIRST_STEP = 8.0
SUPPORT_SECOND_STEP = 8.0

# Representative values strictly inside all washer bands in
# config/washer_rules.txt. Widths are radial widths of washer layers 1 and 2.
WASHER_CASES = (
    {"case_id": "W08", "diameter": 8.0, "segments": 8, "widths": (4.0, 6.0)},
    {"case_id": "W12", "diameter": 12.0, "segments": 10, "widths": (4.0, 6.0)},
    {"case_id": "W18", "diameter": 18.0, "segments": 12, "widths": (6.0, 8.0)},
    {"case_id": "W26", "diameter": 26.0, "segments": 16, "widths": (8.0, 8.0)},
)


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
    property_id: int
    color: int
    element_ids: List[int] = field(default_factory=list)


@dataclass
class Model:
    nodes: Dict[int, Point] = field(default_factory=dict)
    elements: Dict[int, Element] = field(default_factory=dict)
    components: Dict[int, Component] = field(default_factory=dict)
    holes: List[Dict[str, object]] = field(default_factory=list)
    next_node_id: int = 1
    next_element_id: int = 1
    merged_node_index: Dict[Tuple[float, float, float], int] = field(default_factory=dict)

    def add_component(self, component_id: int, name: str, color: int) -> Component:
        component = Component(component_id, name, component_id, color)
        self.components[component_id] = component
        return component

    def add_node(self, point: Point, merge: bool = False) -> int:
        clean = tuple(round(float(value), 10) for value in point)
        if merge and clean in self.merged_node_index:
            return self.merged_node_index[clean]
        node_id = self.next_node_id
        self.next_node_id += 1
        self.nodes[node_id] = clean
        if merge:
            self.merged_node_index[clean] = node_id
        return node_id

    def add_element(self, component_id: int, card: str, node_ids: Sequence[int]) -> int:
        element_id = self.next_element_id
        self.next_element_id += 1
        item = Element(card, element_id, self.components[component_id].property_id, tuple(node_ids))
        self.elements[element_id] = item
        self.components[component_id].element_ids.append(element_id)
        return element_id


def ring_nodes(model: Model, center: Point, radius: float, segments: int) -> List[int]:
    return [
        model.add_node(
            (
                center[0] + radius * math.cos(2.0 * math.pi * index / segments),
                center[1] + radius * math.sin(2.0 * math.pi * index / segments),
                center[2],
            )
        )
        for index in range(segments)
    ]


def square_boundary_nodes(model: Model, center: Point) -> List[int]:
    """Return angularly ordered nodes on one square cell boundary.

    Boundary nodes are merged by coordinates. Consequently adjacent cells are
    topologically connected and each layer is one continuous shell plane.
    """
    half = CELL_SIZE / 2.0
    result = []
    for index in range(OUTER_CELL_SEGMENTS):
        angle = 2.0 * math.pi * index / OUTER_CELL_SEGMENTS
        cosine, sine = math.cos(angle), math.sin(angle)
        scale = half / max(abs(cosine), abs(sine))
        result.append(model.add_node((center[0] + scale * cosine, center[1] + scale * sine, center[2]), merge=True))
    return result


def interpolated_ring_nodes(
    model: Model,
    center: Point,
    circular_radius: float,
    fraction_to_square: float,
) -> List[int]:
    """Create a rounded-square support ring with uniform angular density."""
    half = CELL_SIZE / 2.0
    result = []
    for index in range(OUTER_CELL_SEGMENTS):
        angle = 2.0 * math.pi * index / OUTER_CELL_SEGMENTS
        cosine, sine = math.cos(angle), math.sin(angle)
        square_radius = half / max(abs(cosine), abs(sine))
        radius = circular_radius + fraction_to_square * (square_radius - circular_radius)
        result.append(model.add_node((center[0] + radius * cosine, center[1] + radius * sine, center[2])))
    return result


def add_equal_ring(model: Model, component_id: int, inner: Sequence[int], outer: Sequence[int]) -> List[int]:
    if len(inner) != len(outer):
        raise ValueError("equal ring requires matching node counts")
    result = []
    for index in range(len(inner)):
        nxt = (index + 1) % len(inner)
        result.append(model.add_element(component_id, "CQUAD4", (inner[index], outer[index], outer[nxt], inner[nxt])))
    return result


def add_transition_ring(model: Model, component_id: int, inner: Sequence[int], outer: Sequence[int]) -> List[int]:
    """Conformally fill between circular and square loops of unequal density."""
    inner_count, outer_count = len(inner), len(outer)
    if inner_count == outer_count:
        return add_equal_ring(model, component_id, inner, outer)
    inner_step = outer_step = 0
    result = []
    tolerance = 1.0e-12
    while inner_step < inner_count or outer_step < outer_count:
        next_inner = (inner_step + 1.0) / inner_count if inner_step < inner_count else float("inf")
        next_outer = (outer_step + 1.0) / outer_count if outer_step < outer_count else float("inf")
        inner_id = inner[inner_step % inner_count]
        outer_id = outer[outer_step % outer_count]
        if abs(next_inner - next_outer) <= tolerance:
            next_inner_id = inner[(inner_step + 1) % inner_count]
            next_outer_id = outer[(outer_step + 1) % outer_count]
            result.append(model.add_element(component_id, "CTRIA3", (inner_id, outer_id, next_inner_id)))
            result.append(model.add_element(component_id, "CTRIA3", (next_inner_id, outer_id, next_outer_id)))
            inner_step += 1
            outer_step += 1
        elif next_inner < next_outer:
            result.append(model.add_element(component_id, "CTRIA3", (inner_id, outer_id, inner[(inner_step + 1) % inner_count])))
            inner_step += 1
        else:
            result.append(model.add_element(component_id, "CTRIA3", (inner_id, outer_id, outer[(outer_step + 1) % outer_count])))
            outer_step += 1
    return result


def add_perforated_cell(
    model: Model,
    component_id: int,
    plane_index: int,
    row: int,
    column: int,
    case: Dict[str, object],
    center: Point,
) -> None:
    diameter = float(case["diameter"])
    segments = int(case["segments"])
    width_1, width_2 = (float(value) for value in case["widths"])
    radii = (diameter / 2.0, diameter / 2.0 + width_1, diameter / 2.0 + width_1 + width_2)
    if radii[-1] >= CELL_SIZE / 2.0:
        raise ValueError("washer does not fit cell")

    inner_loop = ring_nodes(model, center, radii[0], segments)
    washer_loop_1 = ring_nodes(model, center, radii[1], segments)
    washer_loop_2 = ring_nodes(model, center, radii[2], segments)
    washer_1_elements = add_equal_ring(model, component_id, inner_loop, washer_loop_1)
    washer_2_elements = add_equal_ring(model, component_id, washer_loop_1, washer_loop_2)

    # Stage the support mesh through 16- and 32-node circular loops before
    # morphing it into the square cell. This avoids long fan triangles and
    # keeps edge-length growth controlled outside the accepted washer mesh.
    radius_16 = radii[2] + SUPPORT_FIRST_STEP
    support_16 = ring_nodes(model, center, radius_16, 16)
    transition_elements = add_transition_ring(model, component_id, washer_loop_2, support_16)
    radius_32 = radius_16 + SUPPORT_SECOND_STEP
    support_32 = ring_nodes(model, center, radius_32, OUTER_CELL_SEGMENTS)
    transition_elements.extend(add_transition_ring(model, component_id, support_16, support_32))

    morph_layer_count = max(2, int(math.ceil((CELL_SIZE / 2.0 - radius_32) / 10.0)))
    previous = support_32
    morph_rings: List[List[int]] = []
    for layer in range(1, morph_layer_count):
        ring = interpolated_ring_nodes(model, center, radius_32, layer / float(morph_layer_count))
        transition_elements.extend(add_equal_ring(model, component_id, previous, ring))
        morph_rings.append(ring)
        previous = ring
    cell_boundary = square_boundary_nodes(model, center)
    transition_elements.extend(add_equal_ring(model, component_id, previous, cell_boundary))

    model.holes.append(
        {
            "plane_index": plane_index + 1,
            "component_id": component_id,
            "row": row + 1,
            "column": column + 1,
            "case_id": case["case_id"],
            "center": list(center),
            "diameter": diameter,
            "hole_edge_node_count": segments,
            "washer_layer_widths": [width_1, width_2],
            "inner_loop_node_ids": inner_loop,
            "washer_loop_1_node_ids": washer_loop_1,
            "washer_loop_2_node_ids": washer_loop_2,
            "support_16_node_ids": support_16,
            "support_32_node_ids": support_32,
            "support_morph_layer_count": morph_layer_count,
            "cell_boundary_node_ids": cell_boundary,
            "washer_layer_1_element_ids": washer_1_elements,
            "washer_layer_2_element_ids": washer_2_elements,
            "transition_element_ids": transition_elements,
        }
    )


def cell_center(row: int, column: int, z_value: float) -> Point:
    x_min = -0.5 * PLATE_COLUMNS * CELL_SIZE
    y_min = -0.5 * PLATE_ROWS * CELL_SIZE
    return (x_min + (column + 0.5) * CELL_SIZE, y_min + (row + 0.5) * CELL_SIZE, z_value)


def build_model() -> Model:
    model = Model()
    for plane_index, z_value in enumerate(PLANE_Z):
        component_id = 101 + plane_index
        model.add_component(component_id, "LARGE_SHELL_PLANE_{:02d}_Z{:g}".format(plane_index + 1, z_value), 3 + plane_index)
        for row in range(PLATE_ROWS):
            for column in range(PLATE_COLUMNS):
                case = WASHER_CASES[(row * PLATE_COLUMNS + column) % len(WASHER_CASES)]
                add_perforated_cell(model, component_id, plane_index, row, column, case, cell_center(row, column, z_value))
    return model


def component_is_connected(model: Model, component: Component) -> bool:
    node_to_elements: Dict[int, List[int]] = {}
    for element_id in component.element_ids:
        for node_id in model.elements[element_id].node_ids:
            node_to_elements.setdefault(node_id, []).append(element_id)
    pending = [component.element_ids[0]]
    visited = set()
    while pending:
        element_id = pending.pop()
        if element_id in visited:
            continue
        visited.add(element_id)
        for node_id in model.elements[element_id].node_ids:
            pending.extend(node_to_elements[node_id])
    return len(visited) == len(component.element_ids)


def mesh_quality(model: Model) -> Dict[str, float]:
    """Calculate lightweight planar checks for the generated stress model."""
    maximum_aspect = 0.0
    minimum_angle = 180.0
    maximum_quad_skew = 0.0
    aspect_failures = angle_failures = skew_failures = 0
    for element in model.elements.values():
        points = [model.nodes[node_id] for node_id in element.node_ids]
        edge_lengths = []
        angles = []
        for index, point in enumerate(points):
            nxt = points[(index + 1) % len(points)]
            previous = points[(index - 1) % len(points)]
            edge_lengths.append(math.hypot(nxt[0] - point[0], nxt[1] - point[1]))
            a = (previous[0] - point[0], previous[1] - point[1])
            b = (nxt[0] - point[0], nxt[1] - point[1])
            denominator = math.hypot(*a) * math.hypot(*b)
            cosine = max(-1.0, min(1.0, (a[0] * b[0] + a[1] * b[1]) / denominator))
            angles.append(math.degrees(math.acos(cosine)))
        aspect = max(edge_lengths) / min(edge_lengths)
        maximum_aspect = max(maximum_aspect, aspect)
        minimum_angle = min(minimum_angle, min(angles))
        if aspect > 5.0:
            aspect_failures += 1
        if min(angles) < 20.0:
            angle_failures += 1
        if element.card == "CQUAD4":
            skew = max(abs(angle - 90.0) for angle in angles)
            maximum_quad_skew = max(maximum_quad_skew, skew)
            if skew > 45.0 + 1.0e-6:
                skew_failures += 1
    return {
        "maximum_edge_aspect_ratio": round(maximum_aspect, 6),
        "minimum_corner_angle_deg": round(minimum_angle, 6),
        "maximum_quad_angle_deviation_deg": round(maximum_quad_skew, 6),
        "aspect_ratio_over_5_count": aspect_failures,
        "corner_angle_under_20_count": angle_failures,
        "quad_angle_deviation_over_45_count": skew_failures,
    }


def validate(model: Model) -> Dict[str, int]:
    errors: List[str] = []
    expected_holes = len(PLANE_Z) * PLATE_ROWS * PLATE_COLUMNS
    if len(model.components) != len(PLANE_Z):
        errors.append("expected four shell-plane components")
    if len(model.holes) != expected_holes:
        errors.append("expected {} washer holes".format(expected_holes))

    expected_by_diameter = {float(case["diameter"]): (int(case["segments"]), tuple(case["widths"])) for case in WASHER_CASES}
    for hole in model.holes:
        expected_segments, expected_widths = expected_by_diameter[float(hole["diameter"])]
        if int(hole["hole_edge_node_count"]) != expected_segments:
            errors.append("{} has wrong edge density".format(hole["case_id"]))
        if tuple(hole["washer_layer_widths"]) != expected_widths:
            errors.append("{} has wrong washer widths".format(hole["case_id"]))

    expected_nodes = {"CQUAD4": 4, "CTRIA3": 3}
    for element in model.elements.values():
        if element.card not in expected_nodes or len(element.node_ids) != expected_nodes[element.card]:
            errors.append("malformed {} {}".format(element.card, element.element_id))
        if len(set(element.node_ids)) != len(element.node_ids) or any(node_id not in model.nodes for node_id in element.node_ids):
            errors.append("invalid nodes on element {}".format(element.element_id))
    for component in model.components.values():
        if not component_is_connected(model, component):
            errors.append("component {} is not one connected shell plane".format(component.component_id))

    stacks: Dict[Tuple[float, float], List[Dict[str, object]]] = {}
    for hole in model.holes:
        stacks.setdefault(tuple(hole["center"][:2]), []).append(hole)
    if len(stacks) != PLATE_ROWS * PLATE_COLUMNS or any(len(stack) != len(PLANE_Z) for stack in stacks.values()):
        errors.append("coaxial stack count mismatch")
    quality = mesh_quality(model)
    if quality["aspect_ratio_over_5_count"]:
        errors.append("{} elements exceed edge aspect ratio 5".format(quality["aspect_ratio_over_5_count"]))
    if quality["corner_angle_under_20_count"]:
        errors.append("{} elements have a corner angle below 20 deg".format(quality["corner_angle_under_20_count"]))
    if quality["quad_angle_deviation_over_45_count"]:
        errors.append("{} quads exceed 45 deg angle deviation".format(quality["quad_angle_deviation_over_45_count"]))
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors))

    return {
        "component_count": len(model.components),
        "node_count": len(model.nodes),
        "element_count": len(model.elements),
        "cquad4_count": sum(item.card == "CQUAD4" for item in model.elements.values()),
        "ctria3_count": sum(item.card == "CTRIA3" for item in model.elements.values()),
        "washer_hole_count": len(model.holes),
        "holes_per_plane": PLATE_ROWS * PLATE_COLUMNS,
        "coaxial_stack_count": len(stacks),
        "expected_rbe2_count": len(model.holes),
        "expected_adjacent_bolt_count": len(stacks) * (len(PLANE_Z) - 1),
        **quality,
    }


def write_fem(model: Model, output: Path) -> None:
    lines = [
        "$ Large shell plates: washer-hole -> RBE2 -> bolt validation model",
        "$ Shell-only input. Units: mm, N, MPa. Not a production solve deck.",
        "$ Generated by examples/ShellWasher_RBE2_Bolt_Chain/generate_fem.py",
        "BEGIN BULK",
        '$HMNAME MAT 1 "CHAIN_TEST_STEEL"',
        "MAT1,1,210000.0,,0.3,7.85E-9",
        "$ SHELL PROPERTIES",
    ]
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend(('$HMNAME PROP {} "{}_PSHELL"'.format(component.property_id, component.name), "PSHELL,{},1,1.0".format(component.property_id)))
    lines.append("$ COMPONENTS")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend(('$HMNAME COMP {} "{}"'.format(component.component_id, component.name), "$HWCOLOR COMP {} {}".format(component.component_id, component.color)))
    lines.append("$ NODES")
    for node_id, point in sorted(model.nodes.items()):
        lines.append("GRID,{},,{:.9g},{:.9g},{:.9g}".format(node_id, *point))
    lines.append("$ SHELL ELEMENTS GROUPED BY HYPERMESH COMPONENT")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend(("$HMCOMP ID {}".format(component.component_id), "$ " + component.name))
        for element_id in component.element_ids:
            element = model.elements[element_id]
            fields = [element.card, str(element.element_id), str(element.property_id)] + [str(node_id) for node_id in element.node_ids]
            lines.append(",".join(fields))
    lines.extend(("ENDDATA", ""))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def validate_written_fem(output: Path, stats: Dict[str, int]) -> None:
    lines = output.read_text(encoding="utf-8").splitlines()
    if "BEGIN BULK" not in lines or not lines or lines[-1] != "ENDDATA":
        raise ValueError("FEM is missing BEGIN BULK or terminal ENDDATA")
    for card, key in (("GRID", "node_count"), ("CQUAD4", "cquad4_count"), ("CTRIA3", "ctria3_count")):
        if sum(line.startswith(card + ",") for line in lines) != stats[key]:
            raise ValueError("written {} count mismatch".format(card))


def manifest(model: Model, stats: Dict[str, int]) -> Dict[str, object]:
    plate_size = [PLATE_COLUMNS * CELL_SIZE, PLATE_ROWS * CELL_SIZE]
    return {
        "schema_version": "2.0",
        "generator": "generate_fem.py",
        "fem": "ShellWasher_RBE2_Bolt_Chain.fem",
        "purpose": "large continuous shell planes for washer RBE2 creation followed by adjacent RBE2 bolt creation",
        "units": "mm, N, MPa",
        "statistics": stats,
        "plate_layout": {"size_xy": plate_size, "rows": PLATE_ROWS, "columns": PLATE_COLUMNS, "cell_size": CELL_SIZE, "plane_z": list(PLANE_Z)},
        "washer_rule_source": "../../config/washer_rules.txt",
        "washer_rule_cases": list(WASHER_CASES),
        "recommended_workflow": [
            "select all four LARGE_SHELL_PLANE components in shell_washer_hole_rbe2",
            "create one RBE2 per accepted washer hole",
            "select generated RBE2 components in rbe2_bolt_connector",
            "create adjacent CBEAM bolt segments with axisMode=AUTO",
        ],
        "recommended_bolt_settings": {"axisMode": "AUTO", "gapTol": 100.0, "offsetTol": 5.0, "elemType": "CBEAM"},
        "expected": {
            "accepted_washer_holes": stats["washer_hole_count"],
            "created_rbe2": stats["expected_rbe2_count"],
            "coaxial_rbe2_groups": stats["coaxial_stack_count"],
            "adjacent_bolt_segments": stats["expected_adjacent_bolt_count"],
            "bolt_segment_length": 20.0,
        },
        "components": [
            {"component_id": component.component_id, "name": component.name, "z": PLANE_Z[index], "element_count": len(component.element_ids), "connected_shell_plane": True}
            for index, component in enumerate(sorted(model.components.values(), key=lambda item: item.component_id))
        ],
        "holes": model.holes,
        "warning": "Validation geometry only; no loads, constraints, RBE2 cards, or bolt cards are pre-created.",
    }


def parse_args() -> argparse.Namespace:
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=directory / "ShellWasher_RBE2_Bolt_Chain.fem")
    parser.add_argument("--manifest", type=Path, default=directory / "ShellWasher_RBE2_Bolt_Chain_manifest.json")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    model = build_model()
    stats = validate(model)
    write_fem(model, args.output.resolve())
    validate_written_fem(args.output.resolve(), stats)
    args.manifest.resolve().write_text(json.dumps(manifest(model, stats), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"fem": str(args.output.resolve()), "manifest": str(args.manifest.resolve()), **stats}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
