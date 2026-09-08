#!/usr/bin/env python3
"""femlib.py -- shared OptiStruct bulk-data (.fem) builder library for the
HMWorkFlow model generation suite (tools/model_generation).

Fresh implementation, stdlib-only, deterministic.  Card conventions follow
what HyperMesh 2019/2022 import cleanly (see existing examples for reference):

    BEGIN BULK
    $HMNAME MAT  <id> "<name>"
    MAT1,<id>,E,,NU,RHO
    $HMNAME PROP <id> "<name>"
    PSHELL,<id>,MID,T   /  PSOLID,<id>,MID   /  PBAR,... / PBUSH,...
    $HMNAME COMP <id> "<name>"
    $HWCOLOR COMP <id> <color>
    GRID,<id>,,X,Y,Z
    CQUAD4,<eid>,PID,N1,N2,N3,N4     (CTRIA3 / CHEXA / CPENTA / CTETRA)
    RBE2,<eid>,INDEP,DOF,D1,D2,D3,D4  (+ continuations, 7 per line)
    RBE3,<eid>,REFG,REFC,WT1,G1,WT2,G2,... (+ continuations)
    CBEAM/CBAR/CBUSH,<eid>,PID,GA,GB
    $HMCOMP ID <comp_id>   (groups following elements into a component)
    ENDDATA

Coordinates and lengths are in mm; forces in N; masses in tonne (mm_N_s_tonne).
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

Point = Tuple[float, float, float]
EPS = 1.0e-9

# ---------------------------------------------------------------------------
# Core entities
# ---------------------------------------------------------------------------


@dataclass
class Material:
    mid: int
    name: str
    E: float = 210000.0
    nu: float = 0.3
    rho: float = 7.85e-9  # tonne/mm^3 (steel)


@dataclass
class Property:
    pid: int
    name: str
    card: str  # PSHELL | PSOLID | PBAR | PBUSH | PBEAM
    mid: int = 1
    thickness: float = 0.0  # PSHELL
    area: float = 0.0  # PBAR
    i1: float = 0.0
    i2: float = 0.0
    j: float = 0.0
    k: Tuple[float, ...] = ()  # PBUSH stiffnesses


@dataclass
class Element:
    card: str
    eid: int
    pid: int
    node_ids: Tuple[int, ...]
    component_id: int = 0


@dataclass
class Component:
    cid: int
    name: str
    color: int = 1
    property: Optional[Property] = None
    element_ids: List[int] = field(default_factory=list)


class Model:
    """Deterministic FE model builder.  Node/element ids are assigned in
    creation order; coordinates are rounded to 1e-9."""

    def __init__(self, title: str = ""):
        self.title = title
        self.nodes: Dict[int, Point] = {}
        self.elements: Dict[int, Element] = {}
        self.components: Dict[int, Component] = {}
        self.materials: Dict[int, Material] = {}
        self.properties: Dict[int, Property] = {}
        self.next_node_id = 1
        self.next_element_id = 1
        self.next_component_id = 1001
        self.next_property_id = 2001
        self.next_material_id = 1
        self._index: Dict[Tuple[float, float, float], int] = {}

    # -- id allocation ------------------------------------------------------

    def new_node_id(self) -> int:
        nid = self.next_node_id
        self.next_node_id += 1
        return nid

    def new_element_id(self) -> int:
        eid = self.next_element_id
        self.next_element_id += 1
        return eid

    def add_material(self, name: str = "STEEL", E: float = 210000.0, nu: float = 0.3,
                     rho: float = 7.85e-9, mid: Optional[int] = None) -> Material:
        if mid is None:
            mid = self.next_material_id
            self.next_material_id += 1
        mat = Material(mid, name, E, nu, rho)
        self.materials[mid] = mat
        return mat

    def add_property(self, card: str, name: str, mid: int = 1, **kw) -> Property:
        pid = self.next_property_id
        self.next_property_id += 1
        prop = Property(pid, name, card, mid, **kw)
        self.properties[pid] = prop
        return prop

    def add_component(self, name: str, color: int = 1, prop: Optional[Property] = None) -> Component:
        """Create a component.  HyperMesh associates a property with the
        component of the SAME id on .fem import (elements follow their
        property into the component; unassociated properties land in the
        misc component and drag every element with them).  The property id is
        therefore rebound to the component id here, and sharing one property
        across components is rejected -- callers must create one property per
        component (same name is fine, ids differ)."""
        cid = self.next_component_id
        self.next_component_id += 1
        if prop is not None:
            if any(c.property is prop for c in self.components.values()):
                raise ValueError(
                    "shared property '{}' is not allowed: HyperMesh links a property "
                    "to the component with the same id on .fem import, so every "
                    "component needs its own property object".format(prop.name))
            old_pid = prop.pid
            if old_pid != cid:
                if old_pid in self.properties:
                    del self.properties[old_pid]
                prop.pid = cid
                self.properties[cid] = prop
        comp = Component(cid, name, color, prop)
        self.components[cid] = comp
        return comp

    # -- geometry -----------------------------------------------------------

    def node(self, x: float, y: float, z: float, merge: bool = True) -> int:
        """Add a node, optionally merging exact duplicates (1e-9 rounding)."""
        p = (round(float(x), 9), round(float(y), 9), round(float(z), 9))
        if merge:
            hit = self._index.get(p)
            if hit is not None:
                return hit
        nid = self.new_node_id()
        self.nodes[nid] = p
        if merge:
            self._index[p] = nid
        return nid

    def add_node_unmerged(self, x: float, y: float, z: float) -> int:
        """Add a node WITHOUT merging: each call creates a new id even for
        identical coordinates (needed for non-shared-node weld interfaces)."""
        return self.node(x, y, z, merge=False)

    def elem(self, comp: Component, card: str, node_ids: Sequence[int]) -> int:
        eid = self.new_element_id()
        el = Element(card, eid, comp.property.pid if comp.property else 0, tuple(int(n) for n in node_ids), comp.cid)
        self.elements[eid] = el
        comp.element_ids.append(eid)
        return eid

    # -- bulk utilities ------------------------------------------------------

    def node_positions(self, node_ids: Sequence[int]) -> List[Point]:
        return [self.nodes[n] for n in node_ids]

    def elements_of(self, comp: Component) -> List[Element]:
        return [self.elements[eid] for eid in comp.element_ids]

    def bbox(self, node_ids: Optional[Iterable[int]] = None) -> Tuple[float, float, float, float, float, float]:
        ids = node_ids if node_ids is not None else self.nodes.keys()
        xs = [self.nodes[n][0] for n in ids]
        ys = [self.nodes[n][1] for n in ids]
        zs = [self.nodes[n][2] for n in ids]
        return (min(xs), min(ys), min(zs), max(xs), max(ys), max(zs))

    # -- stats ---------------------------------------------------------------

    def stats(self) -> Dict[str, object]:
        cards: Dict[str, int] = {}
        for el in self.elements.values():
            cards[el.card] = cards.get(el.card, 0) + 1
        return {
            "component_count": len(self.components),
            "node_count": len(self.nodes),
            "element_count": len(self.elements),
            "element_cards": cards,
            "material_count": len(self.materials),
            "property_count": len(self.properties),
        }

    # -- writer ---------------------------------------------------------------

    def write_fem(self, path) -> None:
        lines: List[str] = []
        if self.title:
            lines.append("$ " + self.title)
        lines.append("$ Units: mm, N, tonne.  Validation geometry, not a solve deck.")
        lines.append("BEGIN BULK")
        for mid, mat in sorted(self.materials.items()):
            lines.append('$HMNAME MAT {} "{}"'.format(mid, mat.name))
            lines.append("MAT1,{},{}.,,{},{}".format(mid, _f(mat.E), _f(mat.nu), _f(mat.rho)))
        lines.append("$ PROPERTIES")
        for pid, prop in sorted(self.properties.items()):
            lines.append('$HMNAME PROP {} "{}"'.format(pid, prop.name))
            if prop.card == "PSHELL":
                lines.append("PSHELL,{},{},{:.4f}".format(pid, prop.mid, prop.thickness))
            elif prop.card == "PSOLID":
                lines.append("PSOLID,{},{}".format(pid, prop.mid))
            elif prop.card == "PBAR":
                lines.append("PBAR,{},{},{},{},{},{},{}".format(
                    pid, prop.mid, _f(prop.area), _f(prop.i1), _f(prop.i2), _f(prop.j), _f(0.0)))
            elif prop.card == "PBUSH":
                ks = ",".join(_f(k) for k in (prop.k if prop.k else (0.0,) * 6))
                lines.append("PBUSH,{},{}".format(pid, ks))
            else:
                raise ValueError("unsupported property card " + prop.card)
        lines.append("$ COMPONENTS")
        for cid, comp in sorted(self.components.items()):
            lines.append('$HMNAME COMP {} "{}"'.format(cid, comp.name))
            lines.append("$HWCOLOR COMP {} {}".format(cid, comp.color))
        lines.append("$ NODES")
        for nid, p in sorted(self.nodes.items()):
            lines.append("GRID,{},,{},{},{}".format(nid, _f(p[0]), _f(p[1]), _f(p[2])))
        lines.append("$ ELEMENTS GROUPED BY HYPERMESH COMPONENT")
        for cid, comp in sorted(self.components.items()):
            lines.append("$HMCOMP ID {}".format(cid))
            lines.append("$ " + comp.name)
            for eid in comp.element_ids:
                el = self.elements[eid]
                lines.append(_element_line(el))
        lines.append("ENDDATA")
        lines.append("")
        import os
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))


def _f(value: float) -> str:
    return "{:.9g}".format(float(value)).replace("e", "E")


_NODES_PER_CARD = {
    "CQUAD4": 4, "CQUAD8": 8, "CTRIA3": 3, "CTRIA6": 6,
    "CHEXA": 8, "CPENTA": 6, "CTETRA": 4, "CTETRA10": 10,
    "CBEAM": 2, "CBAR": 2, "CBUSH": 2, "CROD": 2,
}


def _element_line(el: Element) -> str:
    card = el.card
    if card in ("RBE2",):
        return _rbe2_line(el)
    if card == "RBE3":
        return _rbe3_line(el)
    if card in _NODES_PER_CARD:
        nodes = [str(n) for n in el.node_ids]
        # hmbatch free-field readers silently drop lines with more than 10
        # comma-separated fields (verified on 2019.0.0.70 / 22.0: a single-line
        # CHEXA imports as 0 elements with a success return).  Continue the
        # node list on a "+C" line; all node-list cards keep field semantics.
        if 3 + len(nodes) > 10:
            return "{},{},{},{},+C\n+C,{}".format(
                card, el.eid, el.pid, ",".join(nodes[:6]), ",".join(nodes[6:]))
        return "{},{},{},{}".format(card, el.eid, el.pid, ",".join(nodes))
    raise ValueError("unsupported element card " + card)


def _rbe2_line(el: Element) -> str:
    """RBE2,<eid>,<indep>,<dof>,<dep1>,<dep2>,<dep3>,<dep4> then continuations
    with up to 7 dependents per line (matches the convention HM accepts)."""
    nid, dof = el.node_ids[0], el.node_ids[1]
    deps = list(el.node_ids[2:])
    head = deps[:4]
    rest = deps[4:]
    lines = ["RBE2,{},{},{},{}".format(el.eid, nid, dof, ",".join(str(d) for d in head))]
    for offset in range(0, len(rest), 7):
        lines.append("+,{}".format(",".join(str(d) for d in rest[offset:offset + 7])))
    return "\n".join(lines)


def _rbe3_line(el: Element) -> str:
    """RBE3,<eid>,<refg>,<refc>,<wt1>,<g1>,<wt2>,<g2>,... (+ continuations)."""
    nid, dof = el.node_ids[0], el.node_ids[1]
    deps = list(el.node_ids[2:])
    pairs = []
    for d in deps:
        pairs.extend(("1.0", str(d)))
    lines = ["RBE3,{},{},{},{}".format(el.eid, nid, dof, ",".join(pairs[:6]))]
    rest = pairs[6:]
    for offset in range(0, len(rest), 8):
        lines.append("+,{}".format(",".join(rest[offset:offset + 8])))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Mesh helpers (structured, deterministic)
# ---------------------------------------------------------------------------


def ring_nodes(model: Model, comp: Component, center: Point, radius: float,
               segments: int, ellipse: Tuple[float, float] = (1.0, 1.0),
               z: Optional[float] = None) -> List[int]:
    """`segments` nodes on a (possibly elliptical) ring at radius."""
    zz = center[2] if z is None else z
    return [
        model.node(
            center[0] + radius * ellipse[0] * math.cos(2.0 * math.pi * i / segments),
            center[1] + radius * ellipse[1] * math.sin(2.0 * math.pi * i / segments),
            zz,
        )
        for i in range(segments)
    ]


def square_ring_nodes(model: Model, comp: Component, center: Point, half: float,
                      segments: int, z: Optional[float] = None) -> List[int]:
    """`segments` nodes on a square boundary with UNIFORM spacing along the
    perimeter (4*segments//4 edges, `segments` must be a multiple of 4).

    Perimeter-uniform parameterisation keeps every edge evenly subdivided, so
    the ring conforms node-for-node with an adjacent Cartesian strip that uses
    the same edge spacing (cell_size / (segments/4))."""
    assert segments % 4 == 0, "square ring segments must be a multiple of 4"
    zz = center[2] if z is None else z
    edge_len = 2.0 * half
    pitch = 4.0 * edge_len / segments  # node spacing along the perimeter
    result = []
    for i in range(segments):
        arc = i * pitch  # distance along perimeter from the right-mid point
        edge, off = divmod(arc, edge_len)  # edge: 0 right,1 top,2 left,3 bottom
        e = int(edge)
        if e == 0:
            x, y = half, -half + off
        elif e == 1:
            x, y = half - off, half
        elif e == 2:
            x, y = -half, half - off
        else:
            x, y = -half + off, -half
        result.append(model.node(center[0] + x, center[1] + y, zz))
    return result


def connect_rings(model: Model, comp: Component, inner: Sequence[int], outer: Sequence[int]) -> List[int]:
    """Connect two rings into quads (equal node counts)."""
    ids = []
    for i in range(len(inner)):
        j = (i + 1) % len(inner)
        ids.append(model.elem(comp, "CQUAD4", (inner[i], outer[i], outer[j], inner[j])))
    return ids


def transition_rings(model: Model, comp: Component, inner: Sequence[int], outer: Sequence[int]) -> List[int]:
    """Connect rings of unequal density with quad/tria transition elements."""
    inner_count, outer_count = len(inner), len(outer)
    if inner_count == outer_count:
        return connect_rings(model, comp, inner, outer)
    istep = ostep = 0
    result = []
    tol = 1.0e-12
    while istep < inner_count or ostep < outer_count:
        ni = (istep + 1.0) / inner_count if istep < inner_count else float("inf")
        no = (ostep + 1.0) / outer_count if ostep < outer_count else float("inf")
        i0 = inner[istep % inner_count]
        o0 = outer[ostep % outer_count]
        if abs(ni - no) <= tol:
            i1 = inner[(istep + 1) % inner_count]
            o1 = outer[(ostep + 1) % outer_count]
            result.append(model.elem(comp, "CTRIA3", (i0, o0, i1)))
            result.append(model.elem(comp, "CTRIA3", (i1, o0, o1)))
            istep += 1
            ostep += 1
        elif ni < no:
            result.append(model.elem(comp, "CTRIA3", (i0, o0, inner[(istep + 1) % inner_count])))
            istep += 1
        else:
            result.append(model.elem(comp, "CTRIA3", (i0, o0, outer[(ostep + 1) % outer_count])))
            ostep += 1
    return result


def washer_hole_cell(model: Model, comp: Component, center: Point, diameter: float,
                     hole_segments: int, washer_widths: Sequence[float],
                     cell_size: float = 120.0, outer_segments: int = 32,
                     support_first_step: float = 8.0, support_second_step: float = 8.0,
                     morph_step: float = 10.0) -> Dict[str, object]:
    """Meshes one washer hole cell: hole ring + 2 washer rings + support rings
    + morph layers to a square cell boundary.  Returns node/element id maps."""
    r0 = diameter / 2.0
    inner = ring_nodes(model, comp, center, r0, hole_segments)
    w1 = ring_nodes(model, comp, center, r0 + washer_widths[0], hole_segments)
    w2 = ring_nodes(model, comp, center, r0 + washer_widths[0] + washer_widths[1], hole_segments)
    ring_elems = connect_rings(model, comp, inner, w1)
    ring_elems += connect_rings(model, comp, w1, w2)
    outer_radius = r0 + washer_widths[0] + washer_widths[1]
    r16 = outer_radius + support_first_step
    s16 = ring_nodes(model, comp, center, r16, 16)
    ring_elems += transition_rings(model, comp, w2, s16)
    r32 = r16 + support_second_step
    s32 = ring_nodes(model, comp, center, r32, outer_segments)
    ring_elems += transition_rings(model, comp, s16, s32)
    half = cell_size / 2.0
    layers = max(2, int(math.ceil((half - r32) / morph_step)))
    prev = s32
    for layer in range(1, layers):
        fraction = layer / float(layers)
        ring = []
        for i in range(outer_segments):
            angle = 2.0 * math.pi * i / outer_segments
            c, s = math.cos(angle), math.sin(angle)
            square_r = half / max(abs(c), abs(s))
            r = r32 + fraction * (square_r - r32)
            ring.append(model.node(center[0] + r * c, center[1] + r * s, center[2]))
        ring_elems += connect_rings(model, comp, prev, ring)
        prev = ring
    boundary = square_ring_nodes(model, comp, center, half, outer_segments)
    ring_elems += connect_rings(model, comp, prev, boundary)
    return {
        "center": center, "diameter": diameter,
        "inner_loop_node_ids": inner,
        "washer_loop_1_node_ids": w1,
        "washer_loop_2_node_ids": w2,
        "washer_element_ids": ring_elems,
        "cell_boundary_node_ids": boundary,
    }


def rect_plate_mesh(model: Model, comp: Component, origin: Point, width: float, height: float,
                    nx: int, ny: int, z: Optional[float] = None) -> Dict[str, object]:
    """Structured quad mesh of an axis-aligned rectangle [x0,x0+w] x [y0,y0+h]."""
    x0, y0 = origin[0], origin[1]
    zz = origin[2] if z is None else z
    grid: List[List[int]] = []
    for j in range(ny + 1):
        row = []
        for i in range(nx + 1):
            row.append(model.node(x0 + width * i / nx, y0 + height * j / ny, zz))
        grid.append(row)
    for j in range(ny):
        for i in range(nx):
            model.elem(comp, "CQUAD4", (grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]))
    return {"grid": grid, "origin": origin, "nx": nx, "ny": ny}


def hex_block_mesh(model: Model, comp: Component, origin: Point, dx: float, dy: float, dz: float,
                   nx: int, ny: int, nz: int) -> Dict[str, object]:
    """Structured hexa mesh of an axis-aligned box.  All nodes are merged so
    shared faces between adjacent blocks connect automatically."""
    x0, y0, z0 = origin
    grid: Dict[Tuple[int, int, int], int] = {}
    for k in range(nz + 1):
        for j in range(ny + 1):
            for i in range(nx + 1):
                grid[(i, j, k)] = model.node(
                    x0 + dx * i / nx, y0 + dy * j / ny, z0 + dz * k / nz)
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                n1 = grid[(i, j, k)]
                n2 = grid[(i + 1, j, k)]
                n3 = grid[(i + 1, j + 1, k)]
                n4 = grid[(i, j + 1, k)]
                n5 = grid[(i, j, k + 1)]
                n6 = grid[(i + 1, j, k + 1)]
                n7 = grid[(i + 1, j + 1, k + 1)]
                n8 = grid[(i, j + 1, k + 1)]
                model.elem(comp, "CHEXA", (n1, n2, n3, n4, n5, n6, n7, n8))
    return {"grid": grid, "origin": origin, "nx": nx, "ny": ny, "nz": nz}


def hex_block_with_holes(model: Model, comp: Component, origin: Point, dx: float, dy: float, dz: float,
                         holes: Sequence[Tuple[float, float, float, float]],  # (x,y,radius,segments)
                         nz: int, cell_size: float = 120.0, outer_segments: int = 32,
                         morph_step: float = 12.0) -> Dict[str, object]:
    """Hexa mesh of a box containing cylindrical through-holes.

    Layout rule: every hole sits inside its own square `cell` (cell_size x
    cell_size); cells tile the block in a row and must not overlap; holes are
    centred on the block's Y mid-line, and `dy` must equal `cell_size`.  The
    polar cell mesh (hole wall -> square cell boundary) is extruded in Z; the
    strips between / around the cells are Cartesian hexa regions whose Y rows
    match the cell edge spacing (outer_segments must be a multiple of 4)."""
    x0, y0, z0 = origin
    n_cell_rows = int(round(dy / cell_size))
    assert abs(dy / cell_size - n_cell_rows) < 1e-9, "dy must be a multiple of cell_size"
    half = cell_size / 2.0
    spacing = cell_size / (outer_segments // 4)  # cell edge pitch
    holes = sorted(holes, key=lambda h: (h[1], h[0]))
    for hx, hy, radius, segs in holes:
        assert x0 + half - EPS <= hx <= x0 + dx - half + EPS, "hole cell out of block"
        assert abs((hy - y0 - half) % cell_size) < 1.0 or abs(((hy - y0 - half) % cell_size) - cell_size) < 1.0, \
            "holes must sit on the cell grid (y0+half+k*cell_size)"
    for a, b in zip(holes, holes[1:]):
        assert not (abs(a[0] - b[0]) < cell_size - 1.0e-6 and abs(a[1] - b[1]) < cell_size - 1.0e-6), \
            "hole cells overlap"
    nrows = n_cell_rows * (outer_segments // 4)

    # --- polar cell footprints (nodes in the XY plane at z = z0) -----------
    def cell_rings(hx: float, hy: float, radius: float, segments: int) -> List[List[int]]:
        center = (hx, hy, z0)
        r0 = radius
        rings: List[List[int]] = []
        rings.append(ring_nodes(model, comp, center, r0, segments, z=z0))
        w = 4.0
        rings.append(ring_nodes(model, comp, center, r0 + w, segments, z=z0))
        rings.append(ring_nodes(model, comp, center, r0 + 2 * w, segments, z=z0))
        outer_r = r0 + 2 * w
        rings.append(ring_nodes(model, comp, center, outer_r + 8.0, 16, z=z0))
        rings.append(ring_nodes(model, comp, center, outer_r + 16.0, outer_segments, z=z0))
        r32 = outer_r + 16.0
        layers = max(2, int(math.ceil((half - r32) / morph_step)))
        prev = rings[-1]
        for layer in range(1, layers):
            fraction = layer / float(layers)
            ring = []
            for i in range(outer_segments):
                angle = 2.0 * math.pi * i / outer_segments
                c, s = math.cos(angle), math.sin(angle)
                square_r = half / max(abs(c), abs(s))
                r = r32 + fraction * (square_r - r32)
                ring.append(model.node(hx + r * c, hy + r * s, z0))
            rings.append(ring)
            prev = ring
        rings.append(square_ring_nodes(model, comp, center, half, outer_segments, z=z0))
        return rings

    cells = [cell_rings(h[0], h[1], h[2], h[3]) for h in holes]

    # --- XY-plane connectivities (per cell: ring-to-ring) -------------------
    plane_elems: List[List[List[int]]] = []
    for rings in cells:
        cell_quads: List[List[int]] = []
        for a, b in zip(rings, rings[1:]):
            if len(a) == len(b):
                for i in range(len(a)):
                    j = (i + 1) % len(a)
                    cell_quads.append([a[i], b[i], b[j], a[j]])
            else:
                cell_quads.extend(_transition_quads(a, b))
        plane_elems.append(cell_quads)

    # --- Cartesian strips between / around cells ----------------------------
    strip_regions: List[Tuple[float, float]] = []
    cursor = x0
    for hx in sorted(h[0] for h in holes):
        if hx - half > cursor + EPS:
            strip_regions.append((cursor, hx - half))
        cursor = hx + half
    if cursor < x0 + dx - EPS:
        strip_regions.append((cursor, x0 + dx))

    strip_nodes: Dict[Tuple[int, int, int], int] = {}
    strip_quads: List[List[int]] = []
    for si, (sx0, sx1) in enumerate(strip_regions):
        ncols = max(1, int(round((sx1 - sx0) / spacing)))
        for r in range(nrows + 1):
            for c in range(ncols + 1):
                strip_nodes[(si, c, r)] = model.node(sx0 + (sx1 - sx0) * c / ncols, y0 + dy * r / nrows, z0)
        for r in range(nrows):
            for c in range(ncols):
                strip_quads.append([strip_nodes[(si, c, r)], strip_nodes[(si, c + 1, r)],
                                    strip_nodes[(si, c + 1, r + 1)], strip_nodes[(si, c, r + 1)]])

    # --- extrude every XY node through Z ------------------------------------
    xy_nodes: Set[int] = set()
    for rings in cells:
        for ring in rings:
            xy_nodes.update(ring)
    for si in range(len(strip_regions)):
        ncols = max(1, int(round((strip_regions[si][1] - strip_regions[si][0]) / spacing)))
        for r in range(nrows + 1):
            for c in range(ncols + 1):
                xy_nodes.add(strip_nodes[(si, c, r)])
    layer_ids: Dict[int, Dict[int, int]] = {}
    for k in range(nz + 1):
        zz = z0 + dz * k / nz
        layer_ids[k] = {xy: model.node(model.nodes[xy][0], model.nodes[xy][1], zz) for xy in xy_nodes}

    for k in range(nz):
        lo, hi = layer_ids[k], layer_ids[k + 1]
        for cell_quads in plane_elems:
            for q in cell_quads:
                if len(q) == 4:
                    model.elem(comp, "CHEXA", (lo[q[0]], lo[q[1]], lo[q[2]], lo[q[3]],
                                                hi[q[0]], hi[q[1]], hi[q[2]], hi[q[3]]))
                elif len(q) == 3:
                    model.elem(comp, "CPENTA", (lo[q[0]], lo[q[1]], lo[q[2]],
                                                 hi[q[0]], hi[q[1]], hi[q[2]]))
                else:
                    raise ValueError("unsupported XY cell connectivity " + str(q))
        for q in strip_quads:
            model.elem(comp, "CHEXA", (lo[q[0]], lo[q[1]], lo[q[2]], lo[q[3]],
                                        hi[q[0]], hi[q[1]], hi[q[2]], hi[q[3]]))
    # per-hole 3D wall rings (hole ring node ids at every layer) for RBE2
    # dependents / verification
    hole_rings_3d: List[Dict[int, List[int]]] = []
    for rings in cells:
        hole_xy = rings[0]
        hole_rings_3d.append({k: [layer_ids[k][xy] for xy in hole_xy] for k in range(nz + 1)})
    return {"hole_count": len(holes), "cells": cells, "nz": nz, "strips": strip_regions,
            "hole_rings_3d": hole_rings_3d}


def _transition_quads(inner: Sequence[int], outer: Sequence[int]) -> List[List[int]]:
    """Return quad/tria connectivities between rings of different density."""
    inner_count, outer_count = len(inner), len(outer)
    if inner_count == outer_count:
        return [[inner[i], outer[i], outer[(i + 1) % outer_count], inner[(i + 1) % inner_count]]
                for i in range(inner_count)]
    result: List[List[int]] = []
    istep = ostep = 0
    tol = 1.0e-12
    while istep < inner_count or ostep < outer_count:
        ni = (istep + 1.0) / inner_count if istep < inner_count else float("inf")
        no = (ostep + 1.0) / outer_count if ostep < outer_count else float("inf")
        i0 = inner[istep % inner_count]
        o0 = outer[ostep % outer_count]
        if abs(ni - no) <= tol:
            i1 = inner[(istep + 1) % inner_count]
            o1 = outer[(ostep + 1) % outer_count]
            result.append([i0, o0, i1])
            result.append([i1, o0, o1])
            istep += 1
            ostep += 1
        elif ni < no:
            result.append([i0, o0, inner[(istep + 1) % inner_count]])
            istep += 1
        else:
            result.append([i0, o0, outer[(ostep + 1) % outer_count]])
            ostep += 1
    return result


# ---------------------------------------------------------------------------
# Analysis helpers (verification)
# ---------------------------------------------------------------------------


def free_edges(model: Model, comp: Component) -> Dict[Tuple[int, int], int]:
    """Map of free edge (sorted node pair) -> element id (only edges attached
    to exactly one element)."""
    incidence: Dict[Tuple[int, int], List[int]] = {}
    for el in model.elements_of(comp):
        nodes = el.node_ids
        for i in range(len(nodes)):
            edge = tuple(sorted((nodes[i], nodes[(i + 1) % len(nodes)])))
            incidence.setdefault(edge, []).append(el.eid)
    return {edge: attached[0] for edge, attached in incidence.items() if len(attached) == 1}


def free_edge_loops(model: Model, comp: Component) -> List[List[int]]:
    """Closed free-edge loops (list of node id chains) for a shell component."""
    edges = free_edges(model, comp)
    adj: Dict[int, List[int]] = {}
    for (a, b) in edges:
        adj.setdefault(a, []).append(b)
        adj.setdefault(b, []).append(a)
    loops: List[List[int]] = []
    used: Set[int] = set()
    for start in sorted(adj):
        if start in used or len(adj[start]) != 2:
            continue
        loop = [start]
        prev, cur = start, adj[start][0]
        while cur != start:
            if cur in used:
                break
            loop.append(cur)
            nxts = [n for n in adj[cur] if n != prev]
            if len(nxts) != 1:
                break
            prev, cur = cur, nxts[0]
        if cur == start and len(loop) >= 4:
            loops.append(loop)
            used.update(loop)
    return loops


def coincident_node_pairs(model: Model, comp_a: Component, comp_b: Component,
                          tol: float = 0.5) -> List[Tuple[int, int]]:
    """Nodes of comp_b within `tol` of comp_a nodes (positions of comp_a keyed
    by rounded coordinates)."""
    a_pos: Dict[Tuple[float, float, float], int] = {}
    for el in model.elements_of(comp_a):
        for n in el.node_ids:
            p = model.nodes[n]
            a_pos.setdefault((round(p[0] / tol), round(p[1] / tol), round(p[2] / tol)), n)
    pairs = []
    seen: Set[Tuple[int, int]] = set()
    for el in model.elements_of(comp_b):
        for n in el.node_ids:
            p = model.nodes[n]
            key = (round(p[0] / tol), round(p[1] / tol), round(p[2] / tol))
            hit = a_pos.get(key)
            if hit is not None and (hit, n) not in seen:
                pairs.append((hit, n))
                seen.add((hit, n))
    return pairs


def quad_quality(points: Sequence[Point]) -> Dict[str, float]:
    """Aspect ratio, min corner angle, max deviation from the ideal corner
    angle (90 for quads, 60 for trias) for a planar element.  Pure stdlib
    (runs on the portable Python 3.8 runtime, no numpy)."""
    pts = [tuple(float(v) for v in p) for p in points]
    n = len(pts)
    ideal = 90.0 if n == 4 else 60.0

    def sub(a, b):
        return (a[0] - b[0], a[1] - b[1], a[2] - b[2])

    def dot(a, b):
        return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

    def cross(a, b):
        return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
                a[0] * b[1] - a[1] * b[0])

    def norm(a):
        return math.sqrt(dot(a, a))

    # best-fit plane normal via the first three points
    normal = cross(sub(pts[1], pts[0]), sub(pts[2], pts[0]))
    nl = norm(normal)
    if nl < 1e-12:
        return {"aspect": float("inf"), "min_angle": 0.0, "max_dev": 180.0}
    normal = (normal[0] / nl, normal[1] / nl, normal[2] / nl)
    # project points onto the plane
    proj = []
    for p in pts:
        d = dot(p, normal)
        proj.append((p[0] - d * normal[0], p[1] - d * normal[1], p[2] - d * normal[2]))
    edges = [sub(proj[(i + 1) % n], proj[i]) for i in range(n)]
    lengths = [norm(e) for e in edges]
    min_len = min(lengths)
    aspect = max(lengths) / max(min_len, 1e-12)
    angles = []
    for i in range(n):
        a = edges[i - 1]
        b = (-edges[i][0], -edges[i][1], -edges[i][2])
        denom = norm(a) * norm(b)
        cosv = dot(a, b) / denom if denom > 0 else 0.0
        angles.append(math.degrees(math.acos(max(-1.0, min(1.0, cosv)))))
    return {"aspect": round(aspect, 4), "min_angle": round(min(angles), 4),
            "max_dev": round(max(abs(a - ideal) for a in angles), 4)}


def mesh_quality_stats(model: Model, comp: Component) -> Dict[str, object]:
    """Per-component quality statistics (aspect / angle / skew failures)."""
    stats = {"elements": 0, "aspect_over_5": 0, "angle_under_20": 0, "quad_dev_over_45": 0,
             "degenerate": 0, "max_aspect": 0.0, "min_angle": 180.0, "max_quad_dev": 0.0}
    for el in model.elements_of(comp):
        if el.card not in ("CQUAD4", "CTRIA3"):
            continue
        pts = [model.nodes[n] for n in el.node_ids]
        if len(set(el.node_ids)) != len(el.node_ids):
            stats["degenerate"] += 1
            continue
        q = quad_quality(pts)
        stats["max_aspect"] = max(stats["max_aspect"], q["aspect"])
        stats["min_angle"] = min(stats["min_angle"], q["min_angle"])
        if q["aspect"] > 5.0:
            stats["aspect_over_5"] += 1
        if q["min_angle"] < 20.0:
            stats["angle_under_20"] += 1
        if el.card == "CQUAD4":
            stats["max_quad_dev"] = max(stats["max_quad_dev"], q["max_dev"])
            if q["max_dev"] > 45.0:
                stats["quad_dev_over_45"] += 1
        stats["elements"] += 1
    return stats


def verify_fem_file(path) -> Dict[str, object]:
    """Parse a written .fem and return card counts / sanity checks."""
    text = open(path, encoding="utf-8").read()
    if "BEGIN BULK" not in text or "ENDDATA" not in text:
        raise ValueError("FEM missing BEGIN BULK/ENDDATA")
    counts: Dict[str, int] = {}
    comp_names: List[str] = []
    for line in text.splitlines():
        m = re.match(r"^(GRID|CQUAD4|CTRIA3|CHEXA|CPENTA|CTETRA|RBE2|RBE3|CBEAM|CBAR|CBUSH|MAT1|PSHELL|PSOLID|PBAR|PBUSH|SPOINT),(.*)$", line)
        if m:
            card = m.group(1)
            counts[card] = counts.get(card, 0) + 1
        m2 = re.match(r'^\$HMNAME COMP \d+ "(.*)"$', line)
        if m2:
            comp_names.append(m2.group(1))
    return {"counts": counts, "component_names": comp_names}


def write_manifest(path, data: Dict[str, object]) -> None:
    import os
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
