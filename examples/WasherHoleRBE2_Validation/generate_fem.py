#!/usr/bin/env python3
"""Shell Washer-Hole RIGIDS validation model generator (examples/WasherHoleRBE2_Validation).

Run from the repository root:

    runtime\\python\\windows-x64\\python.exe examples\\WasherHoleRBE2_Validation\\generate_fem.py

Deterministic, stdlib-only (Python 3.8+).  Produces an OptiStruct bulk deck of
shell plates covering the acceptance / rejection matrix of the
shell_washer_hole_rbe2 module:

  C01  normal   multi-size circular washer holes (D8/D12/D18/D26, all 4 bands)
  C02  normal   oval (2:1) elongated holes
  C03  normal   same array as C01 but module run with rigidType=RBE3
  C04  reject   D<6 small hole (r=2) -> DIAMETER_RANGE
  C05  reject   D>30 large hole (D40) -> DIAMETER_RANGE
  C06  skip     existing RIGIDS hole -> SKIP_EXISTING (pre-placed RBE2)
  C07  boundary hole flush against plate edge -> truncated washer ring
  C08  reject   rectangular 30x6 hole -> NOT_CIRCULAR_OR_OVAL

Every scenario is a separate component (plate) laid out along X with >= 300 mm
separation.  Washer ring densities and layer widths follow config/washer_rules.txt.
No RBE2 cards are pre-created except the deliberately pre-placed one in C06.
Units: mm / N / MPa.  This is a validation mesh, not a solve deck.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

Point = Tuple[float, float, float]

CELL_SIZE = 120.0
OUTER_CELL_SEGMENTS = 32
SUPPORT_FIRST_STEP = 8.0
SUPPORT_SECOND_STEP = 8.0
PLATE_THICKNESS = 1.0

# config/washer_rules.txt: 6<D<=9 -> 8 nodes, 4,6 ; 9<D<=13 -> 10, 4,6 ;
# 13<D<=20 -> 12, 6,8 ; 20<D<=30 -> 16, 8,8.
WASHER_BANDS = {
    "D8":  {"diameter": 8.0,  "segments": 8,  "widths": (4.0, 6.0)},
    "D12": {"diameter": 12.0, "segments": 10, "widths": (4.0, 6.0)},
    "D18": {"diameter": 18.0, "segments": 12, "widths": (6.0, 8.0)},
    "D26": {"diameter": 26.0, "segments": 16, "widths": (8.0, 8.0)},
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
    property_id: int
    color: int
    element_ids: List[int] = field(default_factory=list)


class Model:
    def __init__(self) -> None:
        self.nodes: Dict[int, Point] = {}
        self.elements: Dict[int, Element] = {}
        self.components: Dict[int, Component] = {}
        self.holes: List[Dict[str, object]] = []
        self.next_node_id = 1
        self.next_element_id = 1
        self._merge_index: Dict[int, Dict[Tuple[float, float, float], int]] = {}

    def add_component(self, component_id: int, name: str, color: int) -> Component:
        component = Component(component_id, name, component_id, color)
        self.components[component_id] = component
        self._merge_index[component_id] = {}
        return component

    def add_node(self, point: Point, merge: bool = False, component_id: int = 0) -> int:
        clean = tuple(round(float(v), 10) for v in point)
        if merge and component_id in self._merge_index:
            index = self._merge_index[component_id]
            if clean in index:
                return index[clean]
            node_id = self.next_node_id
            self.next_node_id += 1
            self.nodes[node_id] = clean
            index[clean] = node_id
            return node_id
        node_id = self.next_node_id
        self.next_node_id += 1
        self.nodes[node_id] = clean
        return node_id

    def add_element(self, component_id: int, card: str, node_ids: Sequence[int]) -> int:
        element_id = self.next_element_id
        self.next_element_id += 1
        item = Element(card, element_id, self.components[component_id].property_id, tuple(node_ids))
        self.elements[element_id] = item
        self.components[component_id].element_ids.append(element_id)
        return element_id


def ring_nodes(model, component_id, center, radius, segments, ellipse=(1.0, 1.0)) -> List[int]:
    return [
        model.add_node(
            (
                center[0] + radius * ellipse[0] * math.cos(2.0 * math.pi * i / segments),
                center[1] + radius * ellipse[1] * math.sin(2.0 * math.pi * i / segments),
                center[2],
            )
        )
        for i in range(segments)
    ]


def square_boundary_nodes(model, component_id, center) -> List[int]:
    half = CELL_SIZE / 2.0
    result = []
    for i in range(OUTER_CELL_SEGMENTS):
        angle = 2.0 * math.pi * i / OUTER_CELL_SEGMENTS
        cosine, sine = math.cos(angle), math.sin(angle)
        scale = half / max(abs(cosine), abs(sine))
        result.append(
            model.add_node(
                (center[0] + scale * cosine, center[1] + scale * sine, center[2]),
                merge=True, component_id=component_id,
            )
        )
    return result


def rectangle_boundary_nodes(model, component_id, center, half_x, half_y) -> List[int]:
    """Ray-intersection nodes on a rectangle [cx-hx, cx+hx] x [cy-hy, cy+hy]."""
    result = []
    for i in range(OUTER_CELL_SEGMENTS):
        angle = 2.0 * math.pi * i / OUTER_CELL_SEGMENTS
        cosine, sine = math.cos(angle), math.sin(angle)
        if abs(cosine) > 1.0e-12:
            t_x = half_x / abs(cosine)
        else:
            t_x = float("inf")
        if abs(sine) > 1.0e-12:
            t_y = half_y / abs(sine)
        else:
            t_y = float("inf")
        t = min(t_x, t_y)
        result.append(
            model.add_node(
                (center[0] + t * cosine, center[1] + t * sine, center[2]),
                merge=True, component_id=component_id,
            )
        )
    return result


def interpolated_ring_nodes(model, component_id, center, circular_radius, rect_radius) -> List[int]:
    result = []
    for i in range(OUTER_CELL_SEGMENTS):
        angle = 2.0 * math.pi * i / OUTER_CELL_SEGMENTS
        cosine, sine = math.cos(angle), math.sin(angle)
        radius = circular_radius + rect_radius[i]
        result.append(model.add_node((center[0] + radius * cosine, center[1] + radius * sine, center[2])))
    return result


def add_equal_ring(model, component_id, inner, outer) -> List[int]:
    if len(inner) != len(outer):
        raise ValueError("equal ring requires matching node counts")
    result = []
    for i in range(len(inner)):
        nxt = (i + 1) % len(inner)
        result.append(model.add_element(component_id, "CQUAD4", (inner[i], outer[i], outer[nxt], inner[nxt])))
    return result


def add_transition_ring(model, component_id, inner, outer) -> List[int]:
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


def _ring_radius(center, point):
    return math.hypot(point[0] - center[0], point[1] - center[1])


def add_hole_cell(
    model,
    component_id,
    center,
    spec,
    hole_index,
) -> Dict[str, object]:
    diameter = float(spec["diameter"])
    segments = int(spec["segments"])
    width_1, width_2 = (float(v) for v in spec["widths"])
    shape = spec.get("shape", "circular")
    ellipse = spec.get("ellipse", (1.0, 1.0))
    if shape == "circular":
        inner = ring_nodes(model, component_id, center, diameter / 2.0, segments)
        washer_1 = ring_nodes(model, component_id, center, diameter / 2.0 + width_1, segments)
        washer_2 = ring_nodes(model, component_id, center, diameter / 2.0 + width_1 + width_2, segments)
    elif shape == "oval":
        a, b = float(ellipse[0]), float(ellipse[1])
        inner = ring_nodes(model, component_id, center, 1.0, segments, ellipse=(a, b))
        washer_1 = ring_nodes(model, component_id, center, 1.0, segments, ellipse=(a + width_1, b + width_1))
        washer_2 = ring_nodes(model, component_id, center, 1.0, segments, ellipse=(a + width_1 + width_2, b + width_1 + width_2))
    else:
        raise ValueError("unsupported shape {}".format(shape))

    washer_1_elements = add_equal_ring(model, component_id, inner, washer_1)
    washer_2_elements = add_equal_ring(model, component_id, washer_1, washer_2)

    outer_radius = max(_ring_radius(center, model.nodes[n]) for n in washer_2)
    radius_16 = outer_radius + SUPPORT_FIRST_STEP
    support_16 = ring_nodes(model, component_id, center, radius_16, 16)
    transition_elements = add_transition_ring(model, component_id, washer_2, support_16)
    radius_32 = radius_16 + SUPPORT_SECOND_STEP
    support_32 = ring_nodes(model, component_id, center, radius_32, OUTER_CELL_SEGMENTS)
    transition_elements.extend(add_transition_ring(model, component_id, support_16, support_32))

    morph_layer_count = max(2, int(math.ceil((CELL_SIZE / 2.0 - radius_32) / 10.0)))
    previous = support_32
    morph_rings = []
    for layer in range(1, morph_layer_count):
        fraction = layer / float(morph_layer_count)
        ring = []
        for i in range(OUTER_CELL_SEGMENTS):
            angle = 2.0 * math.pi * i / OUTER_CELL_SEGMENTS
            cosine, sine = math.cos(angle), math.sin(angle)
            square_radius = (CELL_SIZE / 2.0) / max(abs(cosine), abs(sine))
            radius = radius_32 + fraction * (square_radius - radius_32)
            ring.append(model.add_node((center[0] + radius * cosine, center[1] + radius * sine, center[2])))
        transition_elements.extend(add_equal_ring(model, component_id, previous, ring))
        morph_rings.append(ring)
        previous = ring
    cell_boundary = square_boundary_nodes(model, component_id, center)
    transition_elements.extend(add_equal_ring(model, component_id, previous, cell_boundary))

    hole = {
        "component_id": component_id,
        "hole_index": hole_index,
        "center": list(center),
        "diameter": diameter,
        "shape": shape,
        "axis_ratio": float(ellipse[0]) / float(ellipse[1]) if shape == "oval" else 1.0,
        "hole_edge_node_count": segments,
        "washer_layer_widths": [width_1, width_2],
        "inner_loop_node_ids": inner,
        "washer_loop_1_node_ids": washer_1,
        "washer_loop_2_node_ids": washer_2,
        "washer_layer_1_element_ids": washer_1_elements,
        "washer_layer_2_element_ids": washer_2_elements,
        "transition_element_ids": transition_elements,
        "cell_boundary_node_ids": cell_boundary,
    }
    model.holes.append(hole)
    return hole


def add_rect_hole_cell(model, component_id, center, spec, hole_index) -> Dict[str, object]:
    """Rectangle hole (corners + edge midpoints) with scaled washer rings."""
    wx, wy = float(spec["rect_wx"]), float(spec["rect_wy"])
    pts = [
        (wx / 2.0, wy / 2.0), (0.0, wy / 2.0), (-wx / 2.0, wy / 2.0), (-wx / 2.0, 0.0),
        (-wx / 2.0, -wy / 2.0), (0.0, -wy / 2.0), (wx / 2.0, -wy / 2.0), (wx / 2.0, 0.0),
    ]

    def ring_scale(factor):
        return [model.add_node((center[0] + p[0] * factor, center[1] + p[1] * factor, center[2])) for p in pts]

    inner = ring_scale(1.0)
    washer_1 = ring_scale(1.3)
    washer_2 = ring_scale(1.6)
    add_equal_ring(model, component_id, inner, washer_1)
    add_equal_ring(model, component_id, washer_1, washer_2)

    outer_radius = max(math.hypot(p[0] * 1.6, p[1] * 1.6) for p in pts)
    radius_16 = outer_radius + SUPPORT_FIRST_STEP
    support_16 = ring_nodes(model, component_id, center, radius_16, 16)
    add_transition_ring(model, component_id, washer_2, support_16)
    radius_32 = radius_16 + SUPPORT_SECOND_STEP
    support_32 = ring_nodes(model, component_id, center, radius_32, OUTER_CELL_SEGMENTS)
    add_transition_ring(model, component_id, support_16, support_32)

    morph_layer_count = max(3, int(math.ceil((CELL_SIZE / 2.0 - radius_32) / 10.0)))
    previous = support_32
    for layer in range(1, morph_layer_count):
        fraction = layer / float(morph_layer_count)
        ring = []
        for i in range(OUTER_CELL_SEGMENTS):
            angle = 2.0 * math.pi * i / OUTER_CELL_SEGMENTS
            cosine, sine = math.cos(angle), math.sin(angle)
            square_radius = (CELL_SIZE / 2.0) / max(abs(cosine), abs(sine))
            radius = radius_32 + fraction * (square_radius - radius_32)
            ring.append(model.add_node((center[0] + radius * cosine, center[1] + radius * sine, center[2])))
        add_equal_ring(model, component_id, previous, ring)
        previous = ring
    cell_boundary = square_boundary_nodes(model, component_id, center)
    add_equal_ring(model, component_id, previous, cell_boundary)

    hole = {
        "component_id": component_id,
        "hole_index": hole_index,
        "center": list(center),
        "diameter": round(2.0 * sum(math.hypot(p[0], p[1]) for p in pts) / len(pts), 6),
        "shape": "rectangular",
        "rect_dims": [wx, wy],
        "hole_edge_node_count": 8,
        "washer_layer_widths": [0.0, 0.0],
        "inner_loop_node_ids": inner,
        "washer_loop_1_node_ids": washer_1,
        "washer_loop_2_node_ids": washer_2,
        "cell_boundary_node_ids": cell_boundary,
    }
    model.holes.append(hole)
    return hole


def add_edge_hole_cell(model, component_id, cell_center, spec, hole_index, edge_offset) -> Dict[str, object]:
    """Single-cell plate (120x120) with the hole offset `edge_offset` mm from the
    RIGHT cell edge.  All rings are concentric on the hole center.  Elements are
    kept only when every node lies inside the cell rectangle AND the four node
    coordinates are distinct (zero-width ring elements at angles clipped by the
    right edge are dropped).  The right-side washer/support rings are therefore
    truncated by the plate edge, which is the boundary condition the module
    should reject."""
    half = CELL_SIZE / 2.0
    hole_center = (cell_center[0] + (half - edge_offset), cell_center[1], cell_center[2])
    x0 = cell_center[0] - half
    x1 = cell_center[0] + half
    y0 = cell_center[1] - half
    y1 = cell_center[1] + half

    diameter = float(spec["diameter"])
    segments = int(spec["segments"])
    width_1, width_2 = (float(v) for v in spec["widths"])
    r0 = diameter / 2.0
    radius_16 = r0 + width_1 + width_2 + SUPPORT_FIRST_STEP
    radius_32 = radius_16 + SUPPORT_SECOND_STEP

    def in_bounds(node_id):
        x, y, _ = model.nodes[node_id]
        return x0 - 1.0e-9 <= x <= x1 + 1.0e-9 and y0 - 1.0e-9 <= y <= y1 + 1.0e-9

    def add_clipped_ring(inner, outer):
        """Connect two coaxial node rings, skipping elements that fall outside
        the cell rectangle or collapse to zero width (clipped angles)."""
        count = len(inner)
        if count != len(outer):
            raise ValueError("clipped ring requires equal node counts")
        for i in range(count):
            j = (i + 1) % count
            quad = (inner[i], outer[i], outer[j], inner[j])
            if not all(in_bounds(n) for n in quad):
                continue
            coords = {model.nodes[n] for n in quad}
            if len(coords) < 4:
                continue
            model.add_element(component_id, "CQUAD4", quad)

    inner = ring_nodes(model, component_id, hole_center, r0, segments)
    washer_1 = ring_nodes(model, component_id, hole_center, r0 + width_1, segments)
    washer_2 = ring_nodes(model, component_id, hole_center, r0 + width_1 + width_2, segments)
    support_16 = ring_nodes(model, component_id, hole_center, radius_16, 16)
    support_32 = ring_nodes(model, component_id, hole_center, radius_32, OUTER_CELL_SEGMENTS)

    add_clipped_ring(inner, washer_1)
    add_clipped_ring(washer_1, washer_2)
    add_transition_ring_clipped(model, component_id, washer_2, support_16, in_bounds)
    add_transition_ring_clipped(model, component_id, support_16, support_32, in_bounds)

    # Outer target radius per angle: ray intersection with the cell rectangle
    # measured from the hole center, clamped to radius_32 (never shrink inward).
    target_radius = []
    for i in range(OUTER_CELL_SEGMENTS):
        angle = 2.0 * math.pi * i / OUTER_CELL_SEGMENTS
        cosine, sine = math.cos(angle), math.sin(angle)
        t = float("inf")
        if abs(cosine) > 1.0e-12:
            t = min(t, (x1 - hole_center[0]) / cosine if cosine > 0 else (x0 - hole_center[0]) / cosine)
        if abs(sine) > 1.0e-12:
            t = min(t, (y1 - hole_center[1]) / sine if sine > 0 else (y0 - hole_center[1]) / sine)
        target_radius.append(max(t, radius_32))

    morph_layer_count = max(3, int(math.ceil((half - radius_32) / 10.0)))
    previous = support_32
    for layer in range(1, morph_layer_count):
        fraction = layer / float(morph_layer_count)
        ring = []
        for i in range(OUTER_CELL_SEGMENTS):
            angle = 2.0 * math.pi * i / OUTER_CELL_SEGMENTS
            rr = radius_32 + fraction * (target_radius[i] - radius_32)
            ring.append(
                model.add_node(
                    (hole_center[0] + rr * math.cos(angle), hole_center[1] + rr * math.sin(angle), hole_center[2]),
                    merge=True, component_id=component_id,
                )
            )
        add_clipped_ring(previous, ring)
        previous = ring
    boundary = [
        model.add_node(
            (hole_center[0] + rr * math.cos(2.0 * math.pi * i / OUTER_CELL_SEGMENTS),
             hole_center[1] + rr * math.sin(2.0 * math.pi * i / OUTER_CELL_SEGMENTS),
             hole_center[2]),
            merge=True, component_id=component_id,
        )
        for i, rr in enumerate(target_radius)
    ]
    add_clipped_ring(previous, boundary)

    hole = {
        "component_id": component_id,
        "hole_index": hole_index,
        "center": list(hole_center),
        "diameter": diameter,
        "shape": "circular",
        "hole_edge_node_count": segments,
        "washer_layer_widths": [width_1, width_2],
        "edge_offset_mm": edge_offset,
        "inner_loop_node_ids": inner,
        "washer_loop_1_node_ids": washer_1,
        "washer_loop_2_node_ids": washer_2,
        "cell_boundary_node_ids": boundary,
    }
    model.holes.append(hole)
    return hole


def add_transition_ring_clipped(model, component_id, inner, outer, in_bounds) -> List[int]:
    """Transition between rings of unequal density, dropping out-of-cell or
    zero-width elements (used by the edge-clipped C07 cell)."""
    inner_count, outer_count = len(inner), len(outer)
    if inner_count == outer_count:
        count = inner_count
        result = []
        for i in range(count):
            j = (i + 1) % count
            quad = (inner[i], outer[i], outer[j], inner[j])
            if not all(in_bounds(n) for n in quad) or len({model.nodes[n] for n in quad}) < 4:
                continue
            result.append(model.add_element(component_id, "CQUAD4", quad))
        return result
    inner_step = outer_step = 0
    result = []
    tolerance = 1.0e-12
    while inner_step < inner_count or outer_step < outer_count:
        next_inner = (inner_step + 1.0) / inner_count if inner_step < inner_count else float("inf")
        next_outer = (outer_step + 1.0) / outer_count if outer_step < outer_count else float("inf")
        inner_id = inner[inner_step % inner_count]
        outer_id = outer[outer_step % outer_count]
        if abs(next_inner - next_outer) <= tolerance:
            ni = inner[(inner_step + 1) % inner_count]
            no = outer[(outer_step + 1) % outer_count]
            for tria in ((inner_id, outer_id, ni), (ni, outer_id, no)):
                if all(in_bounds(n) for n in tria) and len({model.nodes[n] for n in tria}) == 3:
                    result.append(model.add_element(component_id, "CTRIA3", tria))
            inner_step += 1
            outer_step += 1
        elif next_inner < next_outer:
            tria = (inner_id, outer_id, inner[(inner_step + 1) % inner_count])
            if all(in_bounds(n) for n in tria) and len({model.nodes[n] for n in tria}) == 3:
                result.append(model.add_element(component_id, "CTRIA3", tria))
            inner_step += 1
        else:
            tria = (inner_id, outer_id, outer[(outer_step + 1) % outer_count])
            if all(in_bounds(n) for n in tria) and len({model.nodes[n] for n in tria}) == 3:
                result.append(model.add_element(component_id, "CTRIA3", tria))
            outer_step += 1
    return result


def cell_center(origin, col, row):
    return (origin[0] + (col + 0.5) * CELL_SIZE, origin[1] + (row + 0.5) * CELL_SIZE, origin[2])


def build_array(model, component_id, origin, columns, rows, diameter_cycle):
    holes = []
    index = 0
    for row in range(rows):
        for col in range(columns):
            spec = WASHER_BANDS[diameter_cycle[index % len(diameter_cycle)]]
            center = cell_center(origin, col, row)
            holes.append(add_hole_cell(model, component_id, center, spec, index + 1))
            index += 1
    return holes


def component_is_connected(model, component):
    node_to_elements = {}
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


def mesh_quality(model):
    maximum_aspect = 0.0
    minimum_angle = 180.0
    maximum_quad_skew = 0.0
    aspect_failures = angle_failures = skew_failures = degenerate = 0
    for element in model.elements.values():
        points = [model.nodes[node_id] for node_id in element.node_ids]
        if len(set(element.node_ids)) != len(element.node_ids):
            degenerate += 1
            continue
        edge_lengths = []
        angles = []
        for index, point in enumerate(points):
            nxt = points[(index + 1) % len(points)]
            previous = points[(index - 1) % len(points)]
            edge_lengths.append(math.hypot(nxt[0] - point[0], nxt[1] - point[1]))
            a = (previous[0] - point[0], previous[1] - point[1])
            b = (nxt[0] - point[0], nxt[1] - point[1])
            denominator = math.hypot(*a) * math.hypot(*b)
            if denominator <= 0.0:
                degenerate += 1
                break
            cosine = max(-1.0, min(1.0, (a[0] * b[0] + a[1] * b[1]) / denominator))
            angles.append(math.degrees(math.acos(cosine)))
        else:
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
        "degenerate_element_count": degenerate,
        "aspect_ratio_over_5_count": aspect_failures,
        "corner_angle_under_20_count": angle_failures,
        "quad_angle_deviation_over_45_count": skew_failures,
    }


def free_edge_loop_count(model, component_id):
    """Count closed free-edge loops for a shell component (holes + outer boundary).

    Every plate node has degree 2 in the free-edge graph, so each connected
    component of that graph is exactly one closed loop.  Returns -1 if any
    node has a degree other than 2 (branched / clipped boundary)."""
    from collections import defaultdict

    incidence = defaultdict(list)
    for element_id in model.components[component_id].element_ids:
        element = model.elements[element_id]
        nodes = element.node_ids
        for i in range(len(nodes)):
            edge = tuple(sorted((nodes[i], nodes[(i + 1) % len(nodes)])))
            incidence[edge].append(element_id)
    free_edges = [edge for edge, attached in incidence.items() if len(attached) == 1]

    adjacency = defaultdict(set)
    for a, b in free_edges:
        adjacency[a].add(b)
        adjacency[b].add(a)
    for node, neighbors in adjacency.items():
        if len(neighbors) != 2:
            return -1
    parent = {}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for node in adjacency:
        parent[node] = node
    for a, b in free_edges:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra
    return len({find(node) for node in adjacency})


def validate(model, scenarios, existing_rbe2) -> Dict[str, object]:
    errors = []
    for scenario in scenarios:
        component_id = scenario["component_id"]
        component = model.components[component_id]
        expected_holes = scenario["expected_holes"]
        if len([h for h in model.holes if h["component_id"] == component_id]) != expected_holes:
            errors.append("scenario {} hole count mismatch".format(scenario["case_id"]))
        if not component_is_connected(model, component):
            errors.append("component {} is not connected".format(component_id))
        loops = free_edge_loop_count(model, component_id)
        if scenario["case_id"] == "C07":
            # Edge-clipped plate boundary is intentionally ragged; only require
            # the (intact) hole loop to be present.
            if loops < 1:
                errors.append("scenario C07 has no closed free-edge loop (hole loop missing)")
        elif loops != expected_holes + 1:
            errors.append("scenario {} free-edge loop count {} != expected {}".format(scenario["case_id"], loops, expected_holes + 1))

    for hole in model.holes:
        center = hole["center"]
        for axis, coord in zip(("x", "y", "z"), center):
            if not math.isfinite(coord):
                errors.append("hole at non-finite coordinate")
        if hole["hole_edge_node_count"] < 8:
            errors.append("hole edge density below module minimum 8")

    for element in model.elements.values():
        expected_nodes = {"CQUAD4": 4, "CTRIA3": 3}
        if element.card not in expected_nodes or len(element.node_ids) != expected_nodes[element.card]:
            errors.append("malformed {} {}".format(element.card, element.element_id))
        if len(set(element.node_ids)) != len(element.node_ids) or any(n not in model.nodes for n in element.node_ids):
            errors.append("invalid nodes on element {}".format(element.element_id))

    quality = mesh_quality(model)
    strict_quality = {"C01", "C02", "C03", "C04", "C05", "C06"}
    for scenario in scenarios:
        component_id = scenario["component_id"]
        sub = Model()
        sub.nodes = model.nodes
        sub.next_element_id = 1
        for element_id in model.components[component_id].element_ids:
            element = model.elements[element_id]
            sub.elements[element_id] = element
        per_comp = mesh_quality(sub)
        if scenario["case_id"] in strict_quality:
            if per_comp["aspect_ratio_over_5_count"]:
                errors.append("scenario {} has {} elements above aspect 5".format(scenario["case_id"], per_comp["aspect_ratio_over_5_count"]))
            if per_comp["corner_angle_under_20_count"]:
                errors.append("scenario {} has {} elements below 20 deg".format(scenario["case_id"], per_comp["corner_angle_under_20_count"]))
        if per_comp["degenerate_element_count"]:
            errors.append("scenario {} has degenerate elements".format(scenario["case_id"]))

    if quality["degenerate_element_count"]:
        errors.append("degenerate elements present")

    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors))

    return {
        "component_count": len(model.components),
        "node_count": len(model.nodes),
        "element_count": len(model.elements),
        "cquad4_count": sum(item.card == "CQUAD4" for item in model.elements.values()),
        "ctria3_count": sum(item.card == "CTRIA3" for item in model.elements.values()),
        "washer_hole_count": len(model.holes),
        "existing_rbe2_count": len(existing_rbe2),
        "strict_quality_components": sorted(strict_quality),
        "boundary_relaxed_quality_components": ["107", "108"],
        **quality,
    }


def write_fem(model, output, existing_rbe2) -> None:
    lines = [
        "$ Shell washer-hole -> RIGIDS validation model (WasherHoleRBE2_Validation)",
        "$ Shell-only input. Units: mm, N, MPa. Not a production solve deck.",
        "$ Generated by examples/WasherHoleRBE2_Validation/generate_fem.py",
        "BEGIN BULK",
        '$HMNAME MAT 1 "VALIDATION_STEEL"',
        "MAT1,1,210000.0,,0.3,7.85E-9",
        "$ SHELL PROPERTIES",
    ]
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend((
            '$HMNAME PROP {} "{}_PSHELL"'.format(component.property_id, component.name),
            "PSHELL,{},1,{:.3f}".format(component.property_id, PLATE_THICKNESS),
        ))
    lines.append("$ COMPONENTS")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend((
            '$HMNAME COMP {} "{}"'.format(component.component_id, component.name),
            "$HWCOLOR COMP {} {}".format(component.component_id, component.color),
        ))
    lines.append("$ NODES")
    for node_id, point in sorted(model.nodes.items()):
        lines.append("GRID,{},,{:.9g},{:.9g},{:.9g}".format(node_id, *point))
    lines.append("$ SHELL ELEMENTS GROUPED BY HYPERMESH COMPONENT")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend(("$HMCOMP ID {}".format(component.component_id), "$ " + component.name))
        for element_id in component.element_ids:
            element = model.elements[element_id]
            fields = [element.card, str(element.element_id), str(element.property_id)] + [str(n) for n in element.node_ids]
            lines.append(",".join(fields))
    if existing_rbe2:
        lines.append("$ PRE-PLACED RBE2 (C06 SKIP_EXISTING scenario) IN OUTPUT COMPONENT")
        for row in existing_rbe2:
            lines.append("$HMCOMP ID {}".format(row["component_id"]))
            dependent = row["dependent_node_ids"]
            first = ",".join(str(v) for v in dependent[:4])
            lines.append("RBE2,{},{},123456,{}".format(row["element_id"], row["independent_node_id"], first))
            remaining = dependent[4:]
            for offset in range(0, len(remaining), 7):
                lines.append("+,{}".format(",".join(str(v) for v in remaining[offset:offset + 7])))
    lines.extend(("ENDDATA", ""))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def validate_written_fem(output, stats) -> None:
    lines = output.read_text(encoding="utf-8").splitlines()
    if "BEGIN BULK" not in lines or lines[-1] != "ENDDATA":
        raise ValueError("FEM is missing BEGIN BULK or terminal ENDDATA")
    for card, key in (("GRID", "node_count"), ("CQUAD4", "cquad4_count"), ("CTRIA3", "ctria3_count")):
        if sum(line.startswith(card + ",") for line in lines) != stats[key]:
            raise ValueError("written {} count mismatch".format(card))


def build_model():
    model = Model()
    scenarios = []
    existing_rbe2 = []

    # --- C01 / C03 array plates --------------------------------------------
    # C01 A1_WASHER_ARRAY: 6x6 = 36 holes, cycle D8/D12/D18/D26 -> 9 per band
    c01 = model.add_component(101, "A1_WASHER_ARRAY", 3)
    origin = (0.0, 0.0, 0.0)
    a1_holes = build_array(model, 101, origin, 6, 6, ("D8", "D12", "D18", "D26"))
    scenarios.append({
        "case_id": "C01", "component_id": 101, "name": "A1_WASHER_ARRAY", "expected_holes": 36,
        "holes": a1_holes, "origin": origin, "grid": (6, 6), "cycle": ["D8", "D12", "D18", "D26"],
    })

    # C03 A3_RBE3_ARRAY: 6x4 = 24 holes, cycle D8/D12/D18 -> 8 per band
    c03 = model.add_component(103, "A3_RBE3_ARRAY", 5)
    origin = (2400.0, 0.0, 0.0)
    a3_holes = build_array(model, 103, origin, 6, 4, ("D8", "D12", "D18"))
    scenarios.append({
        "case_id": "C03", "component_id": 103, "name": "A3_RBE3_ARRAY", "expected_holes": 24,
        "holes": a3_holes, "origin": origin, "grid": (6, 4), "cycle": ["D8", "D12", "D18"],
    })

    # --- C02 oval plate (2:1 ellipse, 2x2 cells) ----------------------------
    c02 = model.add_component(102, "A2_OVAL_HOLES", 4)
    origin = (1400.0, 0.0, 0.0)
    oval_holes = []
    for row in range(2):
        for col in range(2):
            center = cell_center(origin, col, row)
            spec = {"diameter": 12.0, "segments": 20, "widths": (6.0, 8.0), "shape": "oval", "ellipse": (12.0, 6.0)}
            oval_holes.append(add_hole_cell(model, 102, center, spec, row * 2 + col + 1))
    scenarios.append({
        "case_id": "C02", "component_id": 102, "name": "A2_OVAL_HOLES", "expected_holes": 4,
        "holes": oval_holes, "origin": origin, "grid": (2, 2),
    })

    # --- C04 small hole (r=2 -> D4, DIAMETER_RANGE) -------------------------
    c04 = model.add_component(104, "A4_SMALL_HOLE_D4", 6)
    center = (3500.0 + CELL_SIZE / 2.0, CELL_SIZE / 2.0, 0.0)
    small = add_hole_cell(model, 104, center, {"diameter": 4.0, "segments": 8, "widths": (2.0, 3.0)}, 1)
    scenarios.append({"case_id": "C04", "component_id": 104, "name": "A4_SMALL_HOLE_D4", "expected_holes": 1, "holes": [small]})

    # --- C05 large hole (D40, DIAMETER_RANGE) -------------------------------
    c05 = model.add_component(105, "A5_LARGE_HOLE_D40", 7)
    center = (4000.0 + CELL_SIZE / 2.0, CELL_SIZE / 2.0, 0.0)
    large = add_hole_cell(model, 105, center, {"diameter": 40.0, "segments": 16, "widths": (8.0, 8.0)}, 1)
    scenarios.append({"case_id": "C05", "component_id": 105, "name": "A5_LARGE_HOLE_D40", "expected_holes": 1, "holes": [large]})

    # --- C06 existing RIGIDS hole (D12, pre-placed RBE2) --------------------
    c06 = model.add_component(106, "A6_EXISTING_RBE2", 8)
    center = (4500.0 + CELL_SIZE / 2.0, CELL_SIZE / 2.0, 0.0)
    a6 = add_hole_cell(model, 106, center, {"diameter": 12.0, "segments": 10, "widths": (4.0, 6.0)}, 1)
    # pre-placed RBE2 in an AUTO_RBE2_* output component; dependents = hole loop + washer ring 1
    out_comp_id = 206
    model.add_component(out_comp_id, "AUTO_RBE2_A6_EXISTING_RBE2", 9)
    center_node = model.add_node(center)
    dependents = sorted(set(a6["inner_loop_node_ids"]) | set(a6["washer_loop_1_node_ids"]))
    existing_rbe2.append({
        "element_id": model.next_element_id,
        "independent_node_id": center_node,
        "dependent_node_ids": dependents,
        "component_id": out_comp_id,
    })
    scenarios.append({"case_id": "C06", "component_id": 106, "name": "A6_EXISTING_RBE2", "expected_holes": 1, "holes": [a6]})

    # --- C07 edge-flush hole (D12 at 8 mm from right plate edge) ------------
    c07 = model.add_component(107, "A7_EDGE_HOLE", 10)
    origin = (5000.0, 0.0, 0.0)
    cell_center_07 = (origin[0] + CELL_SIZE / 2.0, CELL_SIZE / 2.0, 0.0)
    a7 = add_edge_hole_cell(model, 107, cell_center_07, {"diameter": 12.0, "segments": 10, "widths": (4.0, 6.0)}, 1, edge_offset=8.0)
    scenarios.append({"case_id": "C07", "component_id": 107, "name": "A7_EDGE_HOLE", "expected_holes": 1, "holes": [a7]})

    # --- C08 rectangular hole (30x6, NOT_CIRCULAR_OR_OVAL) ------------------
    c08 = model.add_component(108, "A8_RECT_HOLE", 11)
    center = (5500.0 + CELL_SIZE / 2.0, CELL_SIZE / 2.0, 0.0)
    a8 = add_rect_hole_cell(model, 108, center, {"rect_wx": 30.0, "rect_wy": 6.0}, 1)
    scenarios.append({"case_id": "C08", "component_id": 108, "name": "A8_RECT_HOLE", "expected_holes": 1, "holes": [a8]})

    return model, scenarios, existing_rbe2


def hole_positions(hole):
    return [round(float(v), 6) for v in hole["center"]]


def manifest(model, scenarios, existing_rbe2, stats):
    components = [
        {
            "component_id": component.component_id,
            "name": component.name,
            "element_count": len(component.element_ids),
            "connected_shell_plane": True,
        }
        for component in sorted(model.components.values(), key=lambda item: item.component_id)
    ]
    cases = []
    for scenario in scenarios:
        case = {
            "case_id": scenario["case_id"],
            "title": SCENARIO_TITLES[scenario["case_id"]],
            "component_ids": [scenario["component_id"]],
            "component_names": [scenario["name"]],
            "hole_count": len(scenario["holes"]),
            "hole_positions": [hole_positions(h) for h in scenario["holes"]],
            "expected": SCENARIO_EXPECTED[scenario["case_id"]],
            "expected_results": SCENARIO_EXPECTED_RESULTS[scenario["case_id"]],
            "settings": SCENARIO_SETTINGS[scenario["case_id"]],
            "notes": SCENARIO_NOTES[scenario["case_id"]],
        }
        if "grid" in scenario:
            case["grid"] = list(scenario["grid"])
        if "cycle" in scenario:
            case["diameter_cycle"] = list(scenario["cycle"])
        cases.append(case)
    for hole in model.holes:
        hole.setdefault("center", [round(float(v), 12) for v in hole["center"]])
    return {
        "schema_version": "1.0",
        "purpose": "shell washer-hole -> RIGIDS acceptance/rejection matrix for shell_washer_hole_rbe2",
        "generator": "examples/WasherHoleRBE2_Validation/generate_fem.py",
        "fem": "WasherHoleRBE2_Validation.fem",
        "parameters": {
            "cell_size": CELL_SIZE,
            "outer_cell_segments": OUTER_CELL_SEGMENTS,
            "washer_rule_source": "config/washer_rules.txt",
            "rigid_type_default": "RBE2",
            "dof": "123456",
        },
        "statistics": stats,
        "components": components,
        "cases": cases,
        "holes": model.holes,
        "existing_rbe2": existing_rbe2,
        "warning": "Validation geometry only; no loads or constraints. Only C06 pre-places an RBE2.",
    }


SCENARIO_TITLES = {
    "C01": "正常：多尺寸圆形 washer 孔阵列（D8/D12/D18/D26，覆盖 4 个 washer 区间）",
    "C02": "正常：椭圆长孔（长短轴 2:1，识别为 oval）",
    "C03": "正常：同 C01 布局，模块以 rigidType=RBE3 运行",
    "C04": "失败：D<6 小孔（r=2mm，D4）应 ignore",
    "C05": "失败：D>30 大孔（D40）无 washer 处理",
    "C06": "跳过：预置 RBE2 的孔 → SKIP_EXISTING 防重复",
    "C07": "边界：孔贴板边（距边 8mm，washer 环被截断）",
    "C08": "失败：矩形孔（30x6，长宽比 5）不识别为圆/椭圆",
}

SCENARIO_EXPECTED = {
    "C01": "识别并创建 36 个 RBE2（每区间 9 个），孔径与 washer 环密度按 washer_rules.txt",
    "C02": "识别并创建 4 个 RBE2，shape=oval，等效直径约 18.5mm，长轴 24 / 短轴 12",
    "C03": "识别 24 个孔并创建 24 个 RBE3（与 C01 同布局逻辑，仅刚性类型不同）",
    "C04": "不识别：孔直径 4 < 6，拒绝原因 DIAMETER_RANGE",
    "C05": "不识别：孔直径 40 > 30，拒绝原因 DIAMETER_RANGE",
    "C06": "孔被识别为候选，但依赖节点集与既有 RBE2 一致 → recommended_action=SKIP_EXISTING，不创建",
    "C07": "孔环可识别（D12），但 washer 第一环被板边截断 → washer 校验拒绝（观察 OUTER_RING_IRREGULAR / OUTER_NODE_COUNT 等）",
    "C08": "不识别：轴比 5.1 > 3.5，拒绝原因 NOT_CIRCULAR_OR_OVAL",
}

SCENARIO_EXPECTED_RESULTS = {
    "C01": {"candidate_count": 36, "create_count": 36, "rejected_count": 1},
    "C02": {"candidate_count": 4, "create_count": 4, "rejected_count": 1},
    "C03": {"candidate_count": 24, "create_count": 24, "rejected_count": 1},
    "C04": {"candidate_count": 0, "create_count": 0, "rejected_count": 2},
    "C05": {"candidate_count": 0, "create_count": 0, "rejected_count": 2},
    "C06": {"candidate_count": 1, "create_count": 0, "skip_existing_count": 1, "rejected_count": 1},
    "C07": {"candidate_count": 0, "create_count": 0, "rejected_count": 2},
    "C08": {"candidate_count": 0, "create_count": 0, "rejected_count": 2},
}

SCENARIO_SETTINGS = {
    "C01": {"MIN_HOLE_DIAMETER": 6.0, "MAX_HOLE_DIAMETER": 30.0, "ALLOW_OVAL_HOLES": True, "rigidType": "RBE2", "INNER_WASHER_NODE_LOOPS": 2},
    "C02": {"MIN_HOLE_DIAMETER": 6.0, "MAX_HOLE_DIAMETER": 30.0, "ALLOW_OVAL_HOLES": True, "MAX_OVAL_AXIS_RATIO": 3.5, "rigidType": "RBE2"},
    "C03": {"MIN_HOLE_DIAMETER": 6.0, "MAX_HOLE_DIAMETER": 30.0, "ALLOW_OVAL_HOLES": True, "rigidType": "RBE3"},
    "C04": {"MIN_HOLE_DIAMETER": 6.0, "MAX_HOLE_DIAMETER": 30.0, "rigidType": "RBE2"},
    "C05": {"MIN_HOLE_DIAMETER": 6.0, "MAX_HOLE_DIAMETER": 30.0, "rigidType": "RBE2"},
    "C06": {"MIN_HOLE_DIAMETER": 6.0, "MAX_HOLE_DIAMETER": 30.0, "rigidType": "RBE2", "existing_rbe2_check": "dependent node set match"},
    "C07": {"MIN_HOLE_DIAMETER": 6.0, "MAX_HOLE_DIAMETER": 30.0, "rigidType": "RBE2", "edge_offset_mm": 8.0},
    "C08": {"MIN_HOLE_DIAMETER": 6.0, "MAX_HOLE_DIAMETER": 30.0, "ALLOW_OVAL_HOLES": True, "MAX_OVAL_AXIS_RATIO": 3.5, "rigidType": "RBE2"},
}

SCENARIO_NOTES = {
    "C01": "每个 cell 的 hole 环 8/10/12/16 节点 + 两层 washer（4,6 / 4,6 / 6,8 / 8,8），与 config/washer_rules.txt 一致。",
    "C02": "椭圆 20 节点、均匀角度采样，radial_rel<0.45、axis_ratio=2.0<3.5，外环为同心放大椭圆，应通过 OVAL 校验。",
    "C03": "同 A1 网格但独立组件；在 HyperMesh 中将刚性类型切到 RBE3 后运行，预期输出 RBE3 卡（fem_delta.rbe3_lines）。",
    "C04": "washer 环仍按规范建模，但孔径 D4<6 在 validate_hole 阶段即拒绝，无需完整 washer。",
    "C05": "D40 在 DIAMETER_RANGE 上限之外被拒绝；板上外轮廓环也会被拒（D 更大）。",
    "C06": "预置 RBE2 的依赖节点 = 孔环 + 第一层 washer 环节点（20 个）；模块 annotate 命中同一依赖节点集 → SKIP_EXISTING。",
    "C07": "孔中心距右板边 8mm < 第一层 washer 环半径 10mm，右侧 washer 单元被裁剪 → 外环不完整。此为边界观察场景，拒绝原因以实际日志为准。",
    "C08": "矩形 30x6，8 节点（4 角 + 4 边中点），等效直径约 24.3 在 6~30 内，但 axis_ratio=5.1>3.5 → NOT_CIRCULAR_OR_OVAL。注意：正六边形孔 radial_rel≈0.073<0.08 会被当作圆接受（模块宽容度）。",
}


def parse_args():
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=directory / "WasherHoleRBE2_Validation.fem")
    parser.add_argument("--manifest", type=Path, default=directory / "WasherHoleRBE2_Validation_manifest.json")
    return parser.parse_args()


def main():
    args = parse_args()
    model, scenarios, existing_rbe2 = build_model()
    stats = validate(model, scenarios, existing_rbe2)
    write_fem(model, args.output.resolve(), existing_rbe2)
    validate_written_fem(args.output.resolve(), stats)
    args.manifest.resolve().write_text(
        json.dumps(manifest(model, scenarios, existing_rbe2, stats), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({"fem": str(args.output.resolve()), "manifest": str(args.manifest.resolve()), **stats}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
