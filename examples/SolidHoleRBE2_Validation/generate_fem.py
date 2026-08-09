#!/usr/bin/env python3
"""Solid Through-Hole RIGIDS validation model generator (examples/SolidHoleRBE2_Validation).

Run from the repository root:

    runtime\\python\\windows-x64\\python.exe examples\\SolidHoleRBE2_Validation\\generate_fem.py

Deterministic, stdlib-only (Python 3.8+).  Produces an OptiStruct bulk deck of
HEXA/CPENTA solid plates covering the acceptance / rejection matrix of the
auto_hole_rbe2 module (free-face cylinder fit -> RBE2):

  C01  normal   coaxial multi-layer through-hole array (2 plates x 16 D16 holes)
  C02  normal   multi-diameter through-holes (D10 / D16 / D24)
  C03  observe  counterbore (D18 top / D10 bottom, conical step) -> module recovers
                the two cylindrical segments via adaptive refinement (2 RBE2)
  C04  observe  45-deg chamfered through-hole (D16) -> cylindrical wall recovered
                via adaptive refinement (1 RBE2, warning ADAPTIVE_PATCH_REFINEMENT)
  C05  reject   slot (rounded-rect) hole -> CYLINDER_FIT then BOUNDARY_LOOP_COUNT
  C06  observe  blind (flat-floor) hole -> wall still recognized as a cylinder
                (1 RBE2 for the wall); the floor cap is rejected
  C07  skip     existing RBE2 hole -> SKIP_EXISTING (pre-placed RBE2)
  C08  reject   through-hole tilted 40 deg from the plate normal ->
                LOOP_NORMAL_MISMATCH (loopNormalTolDeg=35 default)

Plates are meshed as multi-cell HEXA blocks with cylindrical hole walls (16-24
nodes around the wall, 5 axial layers).  No loads/constraints.  Units: mm / N / MPa.
This is a validation mesh, not a solve deck.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple, Callable

Point = Tuple[float, float, float]

CELL_SIZE = 120.0
BOUNDARY_NODES = 32
Z_LAYERS = 6  # 5 axial HEXA bands for a 40 mm plate

# Transition ring node counts and radial widths used by every cell cross-section.
RING_COUNTS = (16, 16, 16, 24, 32)
RING_OFFSETS = (0.0, 5.0, 12.0, 22.0, 34.0)  # radius = r0 + offset


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
        self._merge_index: Dict[int, Dict[Point, int]] = {}

    def add_component(self, component_id: int, name: str, color: int) -> Component:
        component = Component(component_id, name, component_id, color)
        self.components[component_id] = component
        self._merge_index[component_id] = {}
        return component

    def add_node(self, point: Point, component_id: int = 0, merge: bool = False) -> int:
        clean = tuple(round(float(v), 10) for v in point)
        if merge and component_id in self._merge_index:
            index = self._merge_index[component_id]
            existing = index.get(clean)
            if existing is not None:
                return existing
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


def ring_ellipse(model, component_id, center, z, r, count, ax=1.0, poly=None):
    """Build one ring of `count` nodes at height z.

    ax scales the x semi-axis (tilted holes are horizontal ellipses).  poly may
    be a list of unit direction vectors, or a callable poly(i, count) returning
    a point on the closed profile (used for the slot hole).  Nodes are
    coordinate-merged so shared cell edges and z-stacked plates stay connected.
    """
    ids = []
    for i in range(count):
        if poly is None:
            angle = 2.0 * math.pi * i / count
            x = center[0] + r * ax * math.cos(angle)
            y = center[1] + r * math.sin(angle)
        elif callable(poly):
            x, y = poly(i, count)
            x = center[0] + r * x
            y = center[1] + r * y
        else:
            x = center[0] + r * poly[i][0]
            y = center[1] + r * poly[i][1]
        ids.append(model.add_node((x, y, z), component_id=component_id, merge=True))
    return ids


def stadium_point(angle, r, L):
    """Boundary point of a stadium (rounded rectangle) in direction `angle`.

    Caps are circles of radius r centered at (+-L, 0); flats at y = +-r.
    The returned point has unit-scale coordinates (cap radius 1) so rings at
    radius R are the stadium scaled by R."""
    ux, uy = math.cos(angle), math.sin(angle)
    inside = r * r - L * L * uy * uy
    if inside >= 0.0:
        t = L * abs(ux) + math.sqrt(max(inside, 0.0))
        return (t * ux / r, t * uy / r)
    t = r / max(abs(uy), 1.0e-12)
    return (t * ux / r, t * uy / r)


def slot_ring(i, count, cap_r=6.0):
    """Unit-scale slot profile point for ring node i of a `count`-node ring.

    Stadium caps of radius 1 centered at (+-2, 0); the returned point has
    unit-scale coordinates (cap radius 1) so rings at radius R are the stadium
    scaled by R.  Slot overall: length 6 (cap-to-cap 4 + 2*1), width 2."""
    angle = 2.0 * math.pi * i / count
    return stadium_point(angle, 1.0, 2.0)


def connect_rings_2d(model, component_id, inner, outer) -> List[Tuple[int, ...]]:
    """All-quad/quad-tria connection between two coaxial rings (2D patch)."""
    result: List[Tuple[int, ...]] = []
    inner_count, outer_count = len(inner), len(outer)
    if inner_count == outer_count:
        for i in range(inner_count):
            j = (i + 1) % inner_count
            result.append((inner[i], outer[i], outer[j], inner[j]))
        return result
    inner_step = outer_step = 0
    tolerance = 1.0e-12
    while inner_step < inner_count or outer_step < outer_count:
        next_inner = (inner_step + 1.0) / inner_count if inner_step < inner_count else float("inf")
        next_outer = (outer_step + 1.0) / outer_count if outer_step < outer_count else float("inf")
        inner_id = inner[inner_step % inner_count]
        outer_id = outer[outer_step % outer_count]
        if abs(next_inner - next_outer) <= tolerance:
            ni = inner[(inner_step + 1) % inner_count]
            no = outer[(outer_step + 1) % outer_count]
            result.append((inner_id, outer_id, ni))
            result.append((ni, outer_id, no))
            inner_step += 1
            outer_step += 1
        elif next_inner < next_outer:
            result.append((inner_id, outer_id, inner[(inner_step + 1) % inner_count]))
            inner_step += 1
        else:
            result.append((inner_id, outer_id, outer[(outer_step + 1) % outer_count]))
            outer_step += 1
    return result


def square_boundary_ring(model, component_id, cell_origin, z, half, count=BOUNDARY_NODES):
    """32-node ray-intersection ring on the cell square (coordinate-merged)."""
    ids = []
    for i in range(count):
        angle = 2.0 * math.pi * i / count
        cosine, sine = math.cos(angle), math.sin(angle)
        scale = half / max(abs(cosine), abs(sine))
        x = cell_origin[0] + half + scale * cosine
        y = cell_origin[1] + half + scale * sine
        ids.append(model.add_node((x, y, z), component_id=component_id, merge=True))
    return ids


def cell_rings(model, component_id, cell_origin, z, r0, ax=1.0, poly=None, half=CELL_SIZE / 2.0, offsets=RING_OFFSETS):
    """All rings of one cell cross-section: hole ring .. square boundary."""
    center = (cell_origin[0] + half, cell_origin[1] + half, z)
    rings = []
    for count, offset in zip(RING_COUNTS, offsets):
        rings.append(ring_ellipse(model, component_id, center, z, r0 + offset, count, ax=ax, poly=poly))
    boundary = square_boundary_ring(model, component_id, cell_origin, z, half)
    rings.append(boundary)
    return rings, center


def cell_cross_section(model, component_id, cell_origin, z, r0, ax=1.0, poly=None, fill_hole=False, half=CELL_SIZE / 2.0, offsets=RING_OFFSETS):
    """2D all-quad/quad-tria mesh of one cell at height z with a central hole.

    Returns (ring0, quads) where ring0 is the hole ring node list and quads is the
    ordered list of 2D quads/tris in this cross-section.  When fill_hole is True a
    concentric disk fills the hole interior (used for the blind-hole floor)."""
    rings, _center = cell_rings(model, component_id, cell_origin, z, r0, ax=ax, poly=poly, half=half, offsets=offsets)
    quads: List[Tuple[int, ...]] = []
    for a, b in zip(rings, rings[1:]):
        quads.extend(connect_rings_2d(model, component_id, a, b))
    if fill_hole:
        ring0 = rings[0]
        count = len(ring0)
        disk_r1 = ring_ellipse(model, component_id, (_center[0], _center[1], z), z, r0 * 0.66, count, ax=1.0, poly=None)
        disk_r2 = ring_ellipse(model, component_id, (_center[0], _center[1], z), z, r0 * 0.33, count, ax=1.0, poly=None)
        quads.extend(connect_rings_2d(model, component_id, ring0, disk_r1))
        quads.extend(connect_rings_2d(model, component_id, disk_r1, disk_r2))
        center_node = model.add_node((_center[0], _center[1], z), component_id=component_id, merge=True)
        for i in range(count):
            j = (i + 1) % count
            quads.append((center_node, disk_r2[i], disk_r2[j]))
    return rings[0], quads


def extrude_plate(model, component_id, z_layers, layer_quads):
    """Create CHEXA/CPENTA between consecutive z layers.

    layer_quads[k] is the ordered 2D patch of layer k.  zip() pairs only the
    common prefix, which correctly leaves the blind-hole floor disk (present only
    at the floor layer) out of the upward extrusion."""
    for k in range(len(z_layers) - 1):
        for a, b in zip(layer_quads[k], layer_quads[k + 1]):
            if len(a) == 4 and len(b) == 4:
                model.add_element(component_id, "CHEXA", a + b)
            elif len(a) == 3 and len(b) == 3:
                model.add_element(component_id, "CPENTA", a + b)
            else:
                raise ValueError("cross-section topology mismatch between z layers")


def plate_with_hole(model, component_id, cell_origin, z0, z1, hole_spec):
    """Build one multi-cell solid plate with cylindrical through-holes.

    hole_spec: dict with r0 (base radius, mm), nz_layers, ax (ellipse x-scale),
    poly (slot unit directions), offsets (per-cell ring offset ladder) and
    z_profile(z) -> (r, ax, poly, fill) to allow chamfered, counterbored and
    tilted profiles.  Returns the list of hole records."""
    half = CELL_SIZE / 2.0
    nz = int(hole_spec.get("nz_layers", Z_LAYERS))
    z_layers = [z0 + (z1 - z0) * k / (nz - 1) for k in range(nz)]
    cells = hole_spec["cells"]
    offsets = hole_spec.get("offsets", RING_OFFSETS)
    records = []

    # build per-layer cross sections for every cell
    cross = {}  # (row, col) -> [ (ring0, quads) per z layer ]
    for row in range(cells[0]):
        for col in range(cells[1]):
            origin = (cell_origin[0] + col * CELL_SIZE, cell_origin[1] + row * CELL_SIZE)
            per_layer = []
            for z in z_layers:
                r, ax, poly, fill = hole_spec["z_profile"](z)
                ring0, quads = cell_cross_section(
                    model, component_id, origin, z, r, ax=ax, poly=poly, fill_hole=fill, half=half, offsets=offsets,
                )
                per_layer.append((ring0, quads))
            cross[(row, col)] = per_layer

    # extrude each cell vertically
    hole_index = 0
    for row in range(cells[0]):
        for col in range(cells[1]):
            per_layer = cross[(row, col)]
            layer_quads = [quads for _ring0, quads in per_layer]
            extrude_plate(model, component_id, z_layers, layer_quads)
            center = (cell_origin[0] + (col + 0.5) * CELL_SIZE, cell_origin[1] + (row + 0.5) * CELL_SIZE)
            r0 = hole_spec["r0"]
            records.append({
                "hole_index": hole_index + 1,
                "component_id": component_id,
                "center": list(center),
                "z_range": [z0, z1],
                "diameter": 2.0 * r0,
                "profile": hole_spec.get("profile", "circular"),
                "wall_node_count": len(per_layer[0][0]) * nz,
                "wall_node_ids": [n for ring0, _ in per_layer for n in ring0],
            })
            hole_index += 1
    return records


def build_model():
    model = Model()
    existing_rbe2 = []
    scenarios = []
    holes: List[Dict[str, object]] = []

    # ---- C01 coaxial multi-layer through-hole array -------------------------
    c01a = model.add_component(101, "B1_THROUGH_ARRAY_L1", 3)
    c01b = model.add_component(102, "B1_THROUGH_ARRAY_L2", 4)
    for comp_id, z0, z1 in ((101, 0.0, 40.0), (102, 60.0, 100.0)):
        spec = {
            "r0": 8.0,
            "cells": (4, 4),
            "profile": "circular",
            "z_profile": lambda z, r=8.0: (r, 1.0, None, False),
        }
        records = plate_with_hole(model, comp_id, (0.0, 0.0), z0, z1, spec)
        holes.extend(records)
        scenarios.append({
            "case_id": "C01",
            "component_id": comp_id,
            "name": model.components[comp_id].name,
            "z_range": [z0, z1],
            "holes": records,
        })

    # ---- C02 multi-diameter through-holes -----------------------------------
    dia_specs = (
        ("B2_D10", 103, 2000.0, 5.0),
        ("B2_D16", 104, 2400.0, 8.0),
        ("B2_D24", 105, 2800.0, 12.0),
    )
    for name, comp_id, x0, r0 in dia_specs:
        model.add_component(comp_id, name, 5 + comp_id - 103)
        spec = {"r0": r0, "cells": (1, 1), "profile": "circular",
                "z_profile": (lambda z, r=r0: (r, 1.0, None, False))}
        records = plate_with_hole(model, comp_id, (x0, 0.0), 0.0, 40.0, spec)
        holes.extend(records)
        scenarios.append({
            "case_id": "C02", "component_id": comp_id, "name": name,
            "z_range": [0.0, 40.0], "holes": records,
        })

    # ---- C03 counterbore (D18 top / D10 bottom, conical step) ---------------
    c03 = model.add_component(106, "B3_COUNTERBORE", 9)

    def cb_profile(z):
        if z <= 16.0:
            return 5.0, 1.0, None, False
        if z <= 20.0:
            t = (z - 16.0) / 4.0
            return 5.0 + 4.0 * t, 1.0, None, False
        return 9.0, 1.0, None, False

    records = plate_with_hole(model, 106, (3200.0, 0.0), 0.0, 40.0,
                              {"r0": 5.0, "cells": (1, 1), "profile": "counterbore",
                               "z_profile": cb_profile})
    holes.extend(records)
    scenarios.append({"case_id": "C03", "component_id": 106, "name": "B3_COUNTERBORE",
                      "z_range": [0.0, 40.0], "holes": records})

    # ---- C04 chamfered through-hole (D16, 45 deg both ends) -----------------
    c04 = model.add_component(107, "B4_CHAMFER", 10)

    def ch_profile(z):
        if z <= 5.0:
            t = z / 5.0
            return 13.0 - 5.0 * t, 1.0, None, False
        if z <= 35.0:
            return 8.0, 1.0, None, False
        t = (z - 35.0) / 5.0
        return 8.0 + 5.0 * t, 1.0, None, False

    records = plate_with_hole(model, 107, (3600.0, 0.0), 0.0, 40.0,
                              {"r0": 8.0, "cells": (1, 1), "profile": "chamfer",
                               "z_profile": ch_profile})
    holes.extend(records)
    scenarios.append({"case_id": "C04", "component_id": 107, "name": "B4_CHAMFER",
                      "z_range": [0.0, 40.0], "holes": records})

    # ---- C05 slot hole (stadium / rounded rectangle, non-circular) ----------
    # The slot unit profile reaches 3x in the major axis (caps centered at
    # +-2 with radius 1), so this cell uses a tighter offset ladder to keep the
    # outer rings inside the 120 mm cell (3 * (6 + 12) = 54 < 60).
    c05 = model.add_component(108, "B5_SLOT", 11)
    records = plate_with_hole(model, 108, (4000.0, 0.0), 0.0, 40.0,
                              {"r0": 6.0, "cells": (1, 1), "profile": "slot",
                               "offsets": (0.0, 3.0, 6.0, 9.0, 12.0),
                               "z_profile": (lambda z: (6.0, 1.0, slot_ring, False))})
    holes.extend(records)
    scenarios.append({"case_id": "C05", "component_id": 108, "name": "B5_SLOT",
                      "z_range": [0.0, 40.0], "holes": records})

    # ---- C06 blind hole (flat floor, wall D12 from z=16 to z=40) ------------
    c06 = model.add_component(109, "B6_BLIND", 12)

    def blind_profile(z):
        # z <= 16: hole filled by a disk (solid below the floor); z > 16: open
        # wall.  The disk at the z=16 floor layer leaves the wall with two end
        # loops (hole mouth + floor edge).
        return 6.0, 1.0, None, z <= 16.0

    records = plate_with_hole(model, 109, (4400.0, 0.0), 0.0, 40.0,
                              {"r0": 6.0, "cells": (1, 1), "profile": "blind",
                               "z_profile": blind_profile})
    holes.extend(records)
    scenarios.append({"case_id": "C06", "component_id": 109, "name": "B6_BLIND",
                      "z_range": [0.0, 40.0], "holes": records})

    # ---- C07 existing RBE2 hole (D16 through, pre-placed RBE2) --------------
    c07 = model.add_component(110, "B7_EXISTING_RBE2", 13)
    records = plate_with_hole(model, 110, (4800.0, 0.0), 0.0, 40.0,
                              {"r0": 8.0, "cells": (1, 1), "profile": "circular",
                               "z_profile": (lambda z: (8.0, 1.0, None, False))})
    holes.extend(records)
    scenarios.append({"case_id": "C07", "component_id": 110, "name": "B7_EXISTING_RBE2",
                      "z_range": [0.0, 40.0], "holes": records})
    # pre-placed RBE2 in an AUTO_RBE2_* output component; dependents = wall nodes
    wall_nodes = sorted(set(records[0]["wall_node_ids"]))
    out_comp_id = 210
    model.add_component(out_comp_id, "AUTO_RBE2_B7_EXISTING_RBE2", 14)
    center_node = model.add_node((4860.0, 60.0, 20.0))
    existing_rbe2.append({
        "element_id": model.next_element_id,
        "independent_node_id": center_node,
        "dependent_node_ids": wall_nodes,
        "component_id": out_comp_id,
    })

    # ---- C08 tilted through-hole (40 deg from plate normal) -----------------
    c08 = model.add_component(111, "B8_TILTED_40", 15)
    tilt = math.radians(40.0)
    half = CELL_SIZE / 2.0

    def tilt_profile(z, z_mid=20.0, tilt=tilt, r=7.0):
        ax = 1.0 / math.cos(tilt)
        return r, ax, None, False

    # tilted hole needs a wider cell so the ellipse fits inside the plate
    big_half = 110.0  # 220x220 cell
    z_layers = [0.0, 8.0, 16.0, 24.0, 32.0, 40.0]
    cell_origin = (5200.0, 0.0)
    cx0 = cell_origin[0] + big_half
    cy0 = cell_origin[1] + big_half
    r0 = 7.0
    per_layer = []
    for z in z_layers:
        r, ax, _poly, _fill = tilt_profile(z)
        center = (cx0 + (z - 20.0) * math.tan(tilt), cy0)
        rings = []
        for count, offset in zip(RING_COUNTS, RING_OFFSETS):
            rr = r + offset
            rings.append(ring_ellipse(model, 111, center, z, rr, count, ax=ax))
        boundary = square_boundary_ring(model, 111, cell_origin, z, big_half)
        rings.append(boundary)
        quads = []
        for a, b in zip(rings, rings[1:]):
            quads.extend(connect_rings_2d(model, 111, a, b))
        per_layer.append((rings[0], quads))
    layer_quads = [quads for _r, quads in per_layer]
    extrude_plate(model, 111, z_layers, layer_quads)
    records = [{
        "hole_index": 1,
        "component_id": 111,
        "center": [round(cx0, 6), round(cy0, 6), 20.0],
        "z_range": [0.0, 40.0],
        "diameter": 2.0 * r0,
        "profile": "tilted_40deg",
        "wall_node_count": len(per_layer[0][0]) * len(z_layers),
        "wall_node_ids": [n for ring0, _ in per_layer for n in ring0],
    }]
    holes.extend(records)
    scenarios.append({"case_id": "C08", "component_id": 111, "name": "B8_TILTED_40",
                      "z_range": [0.0, 40.0], "holes": records})

    model.holes = holes
    return model, scenarios, existing_rbe2


def validate(model, scenarios, existing_rbe2) -> Dict[str, object]:
    errors: List[str] = []
    for element in model.elements.values():
        expected = {"CHEXA": 8, "CPENTA": 6}.get(element.card)
        if expected is None or len(element.node_ids) != expected:
            errors.append("malformed {} {}".format(element.card, element.element_id))
        if len(set(element.node_ids)) != len(element.node_ids):
            errors.append("duplicate node on {} {}".format(element.card, element.element_id))
        for node_id in element.node_ids:
            if node_id not in model.nodes:
                errors.append("{} references missing node {}".format(element.element_id, node_id))

    for scenario in scenarios:
        component = model.components[scenario["component_id"]]
        if not component.element_ids:
            errors.append("component {} has no elements".format(scenario["component_id"]))
        for hole in scenario["holes"]:
            if hole["wall_node_count"] < 6:
                errors.append("hole wall below minWallNodes 6")

    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors))

    wall_checks = 0
    chexa = sum(1 for e in model.elements.values() if e.card == "CHEXA")
    cpenta = sum(1 for e in model.elements.values() if e.card == "CPENTA")
    return {
        "component_count": len(model.components),
        "node_count": len(model.nodes),
        "element_count": len(model.elements),
        "chexa_count": chexa,
        "cpenta_count": cpenta,
        "hole_count": len(model.holes),
        "existing_rbe2_count": len(existing_rbe2),
        "wall_node_checks": wall_checks,
    }


def write_fem(model, output, existing_rbe2) -> None:
    lines = [
        "$ Solid through-hole -> RIGIDS validation model (SolidHoleRBE2_Validation)",
        "$ HEXA/CPENTA solid input; free faces are generated by HyperMesh *findfaces.",
        "$ Units: mm, N, MPa. Not a production solve deck.",
        "$ Generated by examples/SolidHoleRBE2_Validation/generate_fem.py",
        "BEGIN BULK",
        '$HMNAME MAT 1 "VALIDATION_STEEL"',
        "MAT1,1,210000.0,,0.3,7.85E-9",
        "$ SOLID PROPERTIES",
    ]
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend((
            '$HMNAME PROP {} "{}_PSOLID"'.format(component.property_id, component.name),
            "PSOLID,{},1".format(component.property_id),
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
    lines.append("$ SOLID ELEMENTS GROUPED BY HYPERMESH COMPONENT")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend(("$HMCOMP ID {}".format(component.component_id), "$ " + component.name))
        for element_id in component.element_ids:
            element = model.elements[element_id]
            fields = [element.card, str(element.element_id), str(element.property_id)] + [str(n) for n in element.node_ids]
            lines.append(",".join(fields))
    if existing_rbe2:
        lines.append("$ PRE-PLACED RBE2 (C07 SKIP_EXISTING scenario) IN OUTPUT COMPONENT")
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
    for card, key in (("GRID", "node_count"), ("CHEXA", "chexa_count"), ("CPENTA", "cpenta_count")):
        if sum(line.startswith(card + ",") for line in lines) != stats[key]:
            raise ValueError("written {} count mismatch".format(card))


def manifest(model, scenarios, existing_rbe2, stats) -> Dict[str, object]:
    components = [
        {
            "component_id": component.component_id,
            "name": component.name,
            "element_count": len(component.element_ids),
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
            "hole_positions": [h["center"] for h in scenario["holes"]],
            "expected": SCENARIO_EXPECTED[scenario["case_id"]],
            "expected_results": SCENARIO_EXPECTED_RESULTS[scenario["case_id"]],
            "settings": SCENARIO_SETTINGS[scenario["case_id"]],
            "notes": SCENARIO_NOTES[scenario["case_id"]],
        }
        cases.append(case)
    return {
        "schema_version": "1.0",
        "purpose": "solid through-hole -> RIGIDS acceptance/observation matrix for auto_hole_rbe2",
        "generator": "examples/SolidHoleRBE2_Validation/generate_fem.py",
        "fem": "SolidHoleRBE2_Validation.fem",
        "parameters": {
            "cell_size": CELL_SIZE,
            "z_layers": Z_LAYERS,
            "ring_node_counts": list(RING_COUNTS),
            "ring_offsets": list(RING_OFFSETS),
            "default_settings": {
                "featureAngleDeg": 78.0, "loopNormalTolDeg": 35.0, "cylFitTol": 0.25,
                "loopRadiusTol": 0.35, "minWallNodes": 6, "minLoopNodes": 4,
                "minRadius": 0.0, "maxRadius": 0.0, "requireInnerNormal": False,
                "innerNormalMaxDot": -0.05, "eps": 1.0e-9,
            },
        },
        "statistics": stats,
        "components": components,
        "cases": cases,
        "holes": model.holes,
        "existing_rbe2": existing_rbe2,
        "warning": "Validation geometry only; no loads/constraints. Only C07 pre-places an RBE2.",
    }


SCENARIO_TITLES = {
    "C01": "正常：同轴多层实体板贯通孔阵列（2 板 x 16 孔，D16）",
    "C02": "正常：多孔径混合（D10 / D16 / D24 单孔板）",
    "C03": "观察：沉孔（上段 D18 / 下段 D10，锥环过渡）→ 自适细分恢复两段圆柱",
    "C04": "观察：45° 倒角贯通孔（D16）→ 自适细分恢复圆柱壁",
    "C05": "失败：长圆孔（圆角矩形，20 节点）→ CYLINDER_FIT / BOUNDARY_LOOP_COUNT 拒绝",
    "C06": "观察：未贯通盲孔（平底）→ 孔壁仍被识别为圆柱；孔底端面被拒",
    "C07": "跳过：预置 RBE2 的孔 → SKIP_EXISTING 防重复",
    "C08": "失败：斜孔 40°（不垂直自由面）→ LOOP_NORMAL_MISMATCH 拒绝",
}

SCENARIO_EXPECTED = {
    "C01": "每个板孔壁识别为 1 个候选：共 32 个 RBE2（D16，长度 40mm），两板同轴",
    "C02": "3 个候选 RBE2：D10 / D16 / D24",
    "C03": "2 个候选：上段 D18（长 20mm）与下段 D10（长 16mm），带 ADAPTIVE_PATCH_REFINEMENT 警告；锥环段并入其中一段",
    "C04": "1 个候选：D16 圆柱壁经自适细分恢复，带 ADAPTIVE_PATCH_REFINEMENT 警告",
    "C05": "0 候选：初始 CYLINDER_FIT，细分后各面片 BOUNDARY_LOOP_COUNT:1",
    "C06": "1 个候选：盲孔孔壁 D12（长 24mm）被识别；孔底端面 BOUNDARY_LOOP_COUNT 拒绝。若需排除盲孔须人工复核",
    "C07": "候选被识别但依赖节点集与既有 RBE2 一致 → SKIP_EXISTING，不创建",
    "C08": "0 候选：环法线与轴夹角 40° > loopNormalTolDeg 35°，LOOP_NORMAL_MISMATCH（细分后记录为 BOUNDARY_LOOP_COUNT）",
}

SCENARIO_EXPECTED_RESULTS = {
    "C01": {"candidate_count": 32, "create_count": 32, "rejected_count": 0},
    "C02": {"candidate_count": 3, "create_count": 3, "rejected_count": 0},
    "C03": {"candidate_count": 2, "create_count": 2, "adaptive_count": 2, "rejected_count": 0},
    "C04": {"candidate_count": 1, "create_count": 1, "adaptive_count": 1, "rejected_count": 0},
    "C05": {"candidate_count": 0, "create_count": 0, "rejected_count": 1, "initial_reason": "CYLINDER_FIT", "final_reasons": ["BOUNDARY_LOOP_COUNT:1"]},
    "C06": {"candidate_count": 1, "create_count": 1, "rejected_count": 1},
    "C07": {"candidate_count": 1, "create_count": 0, "skip_existing_count": 1, "rejected_count": 0},
    "C08": {"candidate_count": 0, "create_count": 0, "rejected_count": 1, "initial_reason": "LOOP_NORMAL_MISMATCH", "final_reasons": ["BOUNDARY_LOOP_COUNT:1"]},
}

SCENARIO_SETTINGS = {
    "C01": {"featureAngleDeg": 78.0, "loopNormalTolDeg": 35.0, "cylFitTol": 0.25, "minRadius": 0.0, "maxRadius": 0.0},
    "C02": {"featureAngleDeg": 78.0, "loopNormalTolDeg": 35.0, "cylFitTol": 0.25, "minRadius": 0.0, "maxRadius": 0.0},
    "C03": {"featureAngleDeg": 78.0, "loopNormalTolDeg": 35.0, "cylFitTol": 0.25, "note": "adaptive refinement recovers sub-cylinders"},
    "C04": {"featureAngleDeg": 78.0, "loopNormalTolDeg": 35.0, "cylFitTol": 0.25, "note": "chamfer split off by refinement scanning down to 20 deg"},
    "C05": {"featureAngleDeg": 78.0, "loopNormalTolDeg": 35.0, "cylFitTol": 0.25, "note": "slot radial deviation > cylFitTol"},
    "C06": {"featureAngleDeg": 78.0, "loopNormalTolDeg": 35.0, "cylFitTol": 0.25, "note": "wall has 2 end loops (hole mouth + floor edge) so it qualifies"},
    "C07": {"existing_rbe2_check": "wall node set match"},
    "C08": {"loopNormalTolDeg": 35.0, "tilt_deg": 40.0, "note": "40 > 35 deg normal-angle tolerance"},
}

SCENARIO_NOTES = {
    "C01": "孔壁 16 节点 x 6 层 = 96 节点，D16 半径 8mm，圆柱拟合余量充足（径向偏差 < cylFitTol 0.25）。两板 Z=0..40 与 60..100，同轴 16 孔。",
    "C02": "三块独立单孔板，孔径 10/16/24mm，分别落在 DEFAULTS min/maxRadius 未限制的区间。",
    "C03": "上段 r=9（D18, z20..40）、下段 r=5（D10, z0..16）、z16..20 为 45° 锥环。整段圆柱拟合因半径突变失败，自适细分按特征角扫描恢复两段圆柱；锥环并入其中一段。若期望整孔单 RBE2，需人工复核。",
    "C04": "两端 45° 倒角 r8→13，中部圆柱 r8。初始 CYLINDER_FIT/LOOP_RADIUS_MISMATCH，细分在特征角 ~20° 分离倒角，恢复圆柱壁 D16。",
    "C05": "圆角矩形孔（两半圆弧 + 直边，20 节点）。径向偏差远超 cylFitTol → CYLINDER_FIT；细分后子面片各自只有 1 条边界环 → BOUNDARY_LOOP_COUNT:1。",
    "C06": "孔从顶面钻至 z=16（孔深 24mm），平底端面。孔壁（z16..40）两端口环（孔口 + 孔底边）→ 识别为 D12 圆柱；平底端面法线与壁面差 90° 独立成段，只有 1 条环 → 拒绝。",
    "C07": "预置 RBE2 依赖节点 = 孔壁 96 节点；模块 annotate 命中同一依赖节点集 → SKIP_EXISTING。",
    "C08": "孔轴与板面法线夹角 40°，环法线为竖直、轴倾斜，|dot|=cos40°=0.766 < cos(35°)=0.819 → LOOP_NORMAL_MISMATCH。30° 倾斜时 |dot|=0.866>0.819 会被接受（在容差内）。",
}


def parse_args():
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=directory / "SolidHoleRBE2_Validation.fem")
    parser.add_argument("--manifest", type=Path, default=directory / "SolidHoleRBE2_Validation_manifest.json")
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
