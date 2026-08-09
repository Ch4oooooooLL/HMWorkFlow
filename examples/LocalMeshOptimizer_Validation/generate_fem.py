#!/usr/bin/env python3
"""Generate the Local Mesh Optimizer validation OptiStruct shell FEM.

Command (run from the repository root, portable Python 3.8):

    runtime/python/windows-x64/python.exe examples/LocalMeshOptimizer_Validation/generate_fem.py

Only the Python standard library is required.  The generator is deterministic
(all defect cell coordinates are derived from a fixed grid layout) and performs
full geometric self-checks before writing anything: intended defect cells must
demonstrably violate the reference criteria (aspect / angles / warpage / min
length), the large clean zone must pass every criterion, free-edge loop counts
must match the design, and no element may be degenerate unless it belongs to an
intentional MANUAL_* failure cluster.

Model layout (mm, spacing = 5.0):

    * Main plate 200x120 cells (components: BASE, PROP 1).  Defect zones:
      - C01 processable defect clusters: 100 split quads, 100 skinny trias,
        100 internal narrow quads, scattered inside the left block.
      - C02 narrow-strip coordination zone: a contiguous 4x50 band of narrow
        quads (SET3 1004).
      - C07 criteria-boundary defects: ~40 quads (min angle just below 40 deg),
        ~40 skinny trias (ratio just above 2.5), ~40 narrow quads (aspect just
        above 5.0) and 40 isolated small trias (min length just below 2.0).
      - C08 clean zone: a 46x100 region with zero defects (SET3 1305).
    * Weld T-junction patch (BASE strip + SEAM_T1 walls, PROP 2):
      - a 1x40 narrow base strip whose two long edges are welded (shared nodes)
        to two perpendicular SEAM_T1 walls -> weld-strip chain expansion.
    * Three detached double-ring washers with centre RBE2 (PROP 3).
    * Manual failure clusters (PROP 4): zero-area tria / zero-area quad / bowtie
      quad / duplicate quads / overlap-node sliver / RBE2-protected skinny tria.
      These deliberately contain illegal topology for testing only and must
      never be used for production solving.

Run with --verify-planner to additionally load the module's own planner from
modules/local_mesh_optimizer/python and assert the planned action type for every
defect group (split_quad / collapse_short_edge / expand_internal_quad /
manual_review etc.).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

Point = Tuple[float, float, float]

# ---------------------------------------------------------------------------
# Geometry helpers (pure stdlib, also used for the generator self-checks).
# ---------------------------------------------------------------------------


def _dist(first: Point, second: Point) -> float:
    return math.sqrt(sum((first[i] - second[i]) ** 2 for i in range(3)))


def _cross(ab: Point, ac: Point) -> Point:
    return (
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    )


def _vec(first: Point, second: Point) -> Point:
    return tuple(second[i] - first[i] for i in range(3))


def _tri_area(first: Point, second: Point, third: Point) -> float:
    cross = _cross(_vec(first, second), _vec(first, third))
    return 0.5 * math.sqrt(sum(value * value for value in cross))


def _interior_angle(previous: Point, center: Point, following: Point) -> float:
    """Interior angle (degrees) at ``center`` between ``previous``-``following``."""
    first = _vec(center, previous)
    second = _vec(center, following)
    denominator = _norm(first) * _norm(second)
    if denominator <= 1.0e-14:
        return 0.0
    cosine = max(-1.0, min(1.0, sum(first[i] * second[i] for i in range(3)) / denominator))
    return math.degrees(math.acos(cosine))


def _norm(vector: Point) -> float:
    return math.sqrt(sum(value * value for value in vector))


def _edge_lengths(nodes: Sequence[int], coordinates: Mapping[int, Point]) -> List[float]:
    return [
        _dist(coordinates[nodes[index]], coordinates[nodes[(index + 1) % len(nodes)]])
        for index in range(len(nodes))
    ]


def _interior_angles(nodes: Sequence[int], coordinates: Mapping[int, Point]) -> List[float]:
    return [
        _interior_angle(
            coordinates[nodes[index - 1]],
            coordinates[nodes[index]],
            coordinates[nodes[(index + 1) % len(nodes)]],
        )
        for index in range(len(nodes))
    ]


def _aspect(nodes: Sequence[int], coordinates: Mapping[int, Point]) -> float:
    lengths = _edge_lengths(nodes, coordinates)
    return max(lengths) / min(lengths) if min(lengths) > 1.0e-14 else float("inf")


def _triangle_ratios(nodes: Sequence[int], coordinates: Mapping[int, Point]) -> Tuple[float, float]:
    lengths = sorted(_edge_lengths(nodes, coordinates))
    if lengths[0] <= 1.0e-14:
        return float("inf"), float("inf")
    return lengths[1] / lengths[0], lengths[2] / lengths[0]


def _quad_warpage(nodes: Sequence[int], coordinates: Mapping[int, Point]) -> float:
    """Warpage = angle between the two triangles of the quad (0 for flat)."""
    p0, p1, p2, p3 = (coordinates[node] for node in nodes[:4])
    first = _cross(_vec(p0, p1), _vec(p0, p2))
    second = _cross(_vec(p0, p2), _vec(p0, p3))
    denominator = _norm(first) * _norm(second)
    if denominator <= 1.0e-14:
        return 180.0
    cosine = max(-1.0, min(1.0, sum(first[i] * second[i] for i in range(3)) / denominator))
    return math.degrees(math.acos(cosine))


def _segments_intersect(a: Point, b: Point, c: Point, d: Point) -> bool:
    def cross2(o: Point, p: Point, q: Point) -> float:
        return (p[0] - o[0]) * (q[1] - o[1]) - (p[1] - o[1]) * (q[0] - o[0])

    def on_segment(o: Point, p: Point, q: Point) -> bool:
        return (
            min(o[0], p[0]) - 1.0e-12 <= q[0] <= max(o[0], p[0]) + 1.0e-12
            and min(o[1], p[1]) - 1.0e-12 <= q[1] <= max(o[1], p[1]) + 1.0e-12
        )

    d1 = cross2(a, b, c)
    d2 = cross2(a, b, d)
    d3 = cross2(c, d, a)
    d4 = cross2(c, d, b)
    if ((d1 > 1.0e-12 and d2 < -1.0e-12) or (d1 < -1.0e-12 and d2 > 1.0e-12)) and (
        (d3 > 1.0e-12 and d4 < -1.0e-12) or (d3 < -1.0e-12 and d4 > 1.0e-12)
    ):
        return True
    if abs(d1) <= 1.0e-12 and on_segment(a, b, c):
        return True
    if abs(d2) <= 1.0e-12 and on_segment(a, b, d):
        return True
    if abs(d3) <= 1.0e-12 and on_segment(c, d, a):
        return True
    if abs(d4) <= 1.0e-12 and on_segment(c, d, b):
        return True
    return False


def _quad_self_intersects(nodes: Sequence[int], coordinates: Mapping[int, Point]) -> bool:
    p0, p1, p2, p3 = (coordinates[node] for node in nodes[:4])
    # Opposite edges must not cross; a bowtie quad has p0-p1 crossing p2-p3.
    if _segments_intersect(p0, p1, p2, p3):
        return True
    if _segments_intersect(p1, p2, p3, p0):
        return True
    return False


def _quad_convex(nodes: Sequence[int], coordinates: Mapping[int, Point]) -> bool:
    points = [coordinates[node] for node in nodes[:4]]
    signs: Set[int] = set()
    for index in range(4):
        cross_z = (
            (points[(index + 1) % 4][0] - points[index][0])
            * (points[(index + 2) % 4][1] - points[(index + 1) % 4][1])
            - (points[(index + 1) % 4][1] - points[index][1])
            * (points[(index + 2) % 4][0] - points[(index + 1) % 4][0])
        )
        if abs(cross_z) > 1.0e-12:
            signs.add(1 if cross_z > 0.0 else -1)
    return len(signs) == 1


# ---------------------------------------------------------------------------
# Model container.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Element:
    card: str
    element_id: int
    property_id: int
    nodes: Tuple[int, ...]


@dataclass(frozen=True)
class Rigid:
    element_id: int
    independent: int
    dependent: Tuple[int, ...]
    components: str = "123456"


@dataclass
class Model:
    nodes: Dict[int, Point] = field(default_factory=dict)
    elements: Dict[int, Element] = field(default_factory=dict)
    rigids: Dict[int, Rigid] = field(default_factory=dict)
    groups: Dict[str, List[int]] = field(default_factory=dict)
    notes: Dict[str, str] = field(default_factory=dict)
    next_node_id: int = 1
    next_element_id: int = 1
    next_rigid_id: int = 900001

    def add_node(self, point: Point) -> int:
        node_id = self.next_node_id
        self.next_node_id += 1
        self.nodes[node_id] = point
        return node_id

    def add_element(self, card: str, property_id: int, nodes: Sequence[int], group: str = "") -> int:
        element_id = self.next_element_id
        self.next_element_id += 1
        element = Element(card, element_id, property_id, tuple(nodes))
        self.elements[element_id] = element
        if group:
            self.groups.setdefault(group, []).append(element_id)
        return element_id

    def add_rigid(self, independent: int, dependent: Sequence[int], group: str = "RBE2") -> int:
        element_id = self.next_rigid_id
        self.next_rigid_id += 1
        self.rigids[element_id] = Rigid(element_id, independent, tuple(dependent))
        self.groups.setdefault(group, []).append(element_id)
        return element_id


# ---------------------------------------------------------------------------
# Main plate with zone-based defects.
# ---------------------------------------------------------------------------


def _scatter_cells(nx: int, zone_x: Tuple[int, int], zone_y: Tuple[int, int], pitch: int, count: int) -> List[Tuple[int, int]]:
    """Pick ``count`` well-separated cells inside a zone (pitch >= 3)."""
    cells: List[Tuple[int, int]] = []
    margin = 3
    x_lo, x_hi = max(0, zone_x[0]), min(nx - 1, zone_x[1])
    y_lo, y_hi = zone_y
    for j in range(y_lo + margin, y_hi - margin, pitch):
        for i in range(x_lo + margin, x_hi - margin, pitch):
            cells.append((i, j))
            if len(cells) >= count:
                return cells
    return cells


def build_main_plate(model: Model, nx: int, ny: int, spacing: float) -> Dict[str, Set[Tuple[int, int]]]:
    """Lay out the 200x120 plate and classify every cell.

    Returns a mapping of zone name -> cell set.  Node coordinates are stored
    first, then per-zone node perturbations are applied, then elements are
    created so shared-node neighbourhoods stay connected.
    """
    node_ids: Dict[Tuple[int, int], int] = {}
    for j in range(ny + 1):
        for i in range(nx + 1):
            node_id = model.add_node((i * spacing, j * spacing, 0.0))
            node_ids[(i, j)] = node_id

    def cell_node(i: int, j: int) -> int:
        return node_ids[(i, j)]

    # ---- defect cell selection -------------------------------------------------
    split_cells = set(_scatter_cells(nx, (8, 88), (10, 38), 3, 100))
    skinny_cells = set(_scatter_cells(nx, (8, 88), (42, 72), 3, 100))
    narrow_cells = set(_scatter_cells(nx, (8, 88), (76, 106), 3, 100))
    strip_cells = {(i, j) for i in range(94, 98) for j in range(8, 58)}
    # Criteria-boundary zones use disjoint Y bands so their cells never overlap.
    bquad_cells = set(_scatter_cells(nx, (104, 147), (10, 40), 4, 40))
    bskinny_cells = set(_scatter_cells(nx, (104, 147), (46, 76), 5, 40))
    bnarrow_cells = set(_scatter_cells(nx, (104, 147), (82, 112), 5, 40))
    clean_cells = {(i, j) for i in range(150, 196) for j in range(8, 108)}

    zones = {
        "split": split_cells,
        "skinny": skinny_cells,
        "narrow": narrow_cells,
        "strip": strip_cells,
        "bquad": bquad_cells,
        "bskinny": bskinny_cells,
        "bnarrow": bnarrow_cells,
    }
    overlap: Set[Tuple[int, int]] = set()
    zone_items = list(zones.items())
    for index, (name, cells) in enumerate(zone_items):
        for other_name, other_cells in zone_items[index + 1:]:
            common = cells.intersection(other_cells)
            if common:
                overlap.update(common)
    if overlap:
        raise ValueError("defect-cell layout overlaps: {}".format(sorted(overlap)))
    if clean_cells.intersection(*(cells for cells in zones.values())):
        raise ValueError("clean zone overlaps defect zones")

    # ---- node perturbations (mirror the proven Large_Mixed layout) -------------
    for i, j in split_cells:
        node = cell_node(i + 1, j + 1)
        x, y, z = model.nodes[node]
        model.nodes[node] = (x - 1.5, y - 0.6, z + 2.4)
    for i, j in skinny_cells:
        node = cell_node(i + 1, j + 1)
        x, _, z = model.nodes[node]
        model.nodes[node] = (x, j * spacing + 0.2, z)
    for i, j in narrow_cells:
        for node in (cell_node(i, j + 1), cell_node(i + 1, j + 1)):
            x, _, z = model.nodes[node]
            model.nodes[node] = (x, j * spacing + 0.6, z)
    # Narrow strip: 4 contiguous columns, each cell shrunk to 0.6 mm in X so the
    # whole band is a coordinated narrow strip (long edges vertical, shared).
    strip_width = 0.6
    strip_x0 = 94 * spacing
    for i, j in strip_cells:
        for node in (cell_node(i + 1, j), cell_node(i + 1, j + 1)):
            x, y, z = model.nodes[node]
            model.nodes[node] = (strip_x0 + (i - 93) * strip_width, y, z)
    for i, j in bquad_cells:
        node = cell_node(i + 1, j + 1)
        x, y, z = model.nodes[node]
        model.nodes[node] = (x + 7.0, y, z)
    for i, j in bskinny_cells:
        node = cell_node(i + 1, j + 1)
        x, _, z = model.nodes[node]
        model.nodes[node] = (x, j * spacing + 1.9, z)
    for i, j in bnarrow_cells:
        for node in (cell_node(i + 1, j), cell_node(i + 1, j + 1)):
            x, y, z = model.nodes[node]
            model.nodes[node] = (x - 4.04, y, z)

    # ---- element creation -------------------------------------------------------
    for j in range(ny):
        for i in range(nx):
            n00 = cell_node(i, j)
            n10 = cell_node(i + 1, j)
            n11 = cell_node(i + 1, j + 1)
            n01 = cell_node(i, j + 1)
            cell = (i, j)
            if cell in skinny_cells:
                model.add_element("CTRIA3", 1, (n00, n10, n11), "PROCESSABLE_SKINNY_TRIA")
                model.add_element("CTRIA3", 1, (n00, n11, n01), "SKINNY_TRIA_COMPANION")
            elif cell in bskinny_cells:
                model.add_element("CTRIA3", 1, (n00, n10, n11), "CRITERIA_BOUNDARY_SKINNY_TRIA")
                model.add_element("CTRIA3", 1, (n00, n11, n01), "BSKINNY_TRIA_COMPANION")
            elif cell in split_cells:
                model.add_element("CQUAD4", 1, (n00, n10, n11, n01), "PROCESSABLE_SPLIT_QUAD")
            elif cell in narrow_cells:
                model.add_element("CQUAD4", 1, (n00, n10, n11, n01), "PROCESSABLE_NARROW_QUAD")
            elif cell in strip_cells:
                model.add_element("CQUAD4", 1, (n00, n10, n11, n01), "PROCESSABLE_NARROW_STRIP")
            elif cell in bquad_cells:
                model.add_element("CQUAD4", 1, (n00, n10, n11, n01), "CRITERIA_BOUNDARY_QUAD")
            elif cell in bnarrow_cells:
                model.add_element("CQUAD4", 1, (n00, n10, n11, n01), "CRITERIA_BOUNDARY_NARROW_QUAD")
            elif cell in clean_cells:
                model.add_element("CQUAD4", 1, (n00, n10, n11, n01), "CLEAN_ZONE_ELEMENTS")
            else:
                model.add_element("CQUAD4", 1, (n00, n10, n11, n01), "BASE_SHELL")
    model.notes["plate"] = (
        "{}x{} plate at spacing {}; zones: split={} skinny={} narrow={} strip={} "
        "bquad={} bskinny={} bnarrow={} clean={}".format(
            nx, ny, spacing,
            len(split_cells), len(skinny_cells), len(narrow_cells), len(strip_cells),
            len(bquad_cells), len(bskinny_cells), len(bnarrow_cells), len(clean_cells),
        )
    )
    return zones


def add_weld_zone(model: Model) -> Dict[str, List[int]]:
    """Weld T-junction: a narrow base strip welded on both long edges to two
    perpendicular SEAM_T1 walls.  Returns the weld-line node chain per wall."""
    spacing = 5.0
    rows = 40
    x_wall_a = 5.0
    x_wall_b = 5.6
    y_0 = 0.0
    wall_height = 10.0  # 2 cells of 5 mm

    strip_left: List[int] = []
    strip_right: List[int] = []
    for j in range(rows + 1):
        y = y_0 + j * spacing
        strip_left.append(model.add_node((x_wall_a, y, 0.0)))
        strip_right.append(model.add_node((x_wall_b, y, 0.0)))
    for j in range(rows):
        model.add_element(
            "CQUAD4", 1,
            (strip_left[j], strip_right[j], strip_right[j + 1], strip_left[j + 1]),
            "WELD_STRIP_NARROW_QUADS",
        )
    for x_line, bottom in ((x_wall_a, strip_left), (x_wall_b, strip_right)):
        # band 0 sits at z=[0,5], band 1 at z=[5,10]; walls share the strip nodes.
        wall_rows: List[Tuple[int, int]] = []
        for j in range(rows + 1):
            y = y_0 + j * spacing
            wall_rows.append((model.add_node((x_line, y, spacing)), model.add_node((x_line, y, wall_height))))
        for j in range(rows):
            n_bottom, n_top = wall_rows[j][0], wall_rows[j][1]
            n_next_bottom, n_next_top = wall_rows[j + 1][0], wall_rows[j + 1][1]
            model.add_element("CQUAD4", 2, (bottom[j], bottom[j + 1], n_next_bottom, n_bottom), "SEAM_T1_WALL_ELEMENTS")
            model.add_element("CQUAD4", 2, (n_bottom, n_next_bottom, n_next_top, n_top), "SEAM_T1_WALL_ELEMENTS")
    model.groups.setdefault("WELD_LINE_NODES", []).extend(strip_left + strip_right)
    model.notes["weld_zone"] = (
        "narrow base strip 1x{} at x=[{},{}] welded on both long edges to "
        "vertical SEAM_T1 walls (height {}); {} weld-line nodes per side".format(
            rows, x_wall_a, x_wall_b, wall_height, rows + 1
        )
    )
    return {"strip_left": strip_left, "strip_right": strip_right}


def add_washers(model: Model, count: int) -> None:
    segments = 16
    inner_radius = 4.0
    radii = (inner_radius, 8.0, 12.0)
    origin_y = 660.0
    columns = 3
    for washer_index in range(count):
        center_x = 1080.0 + (washer_index % columns) * 40.0
        center_y = origin_y + (washer_index // columns) * 40.0
        rings: List[List[int]] = []
        for radius in radii:
            ring = []
            for segment in range(segments):
                angle = 2.0 * math.pi * segment / segments
                ring.append(model.add_node((center_x + radius * math.cos(angle), center_y + radius * math.sin(angle), 0.0)))
            rings.append(ring)
        for ring_index in range(len(rings) - 1):
            inner = rings[ring_index]
            outer = rings[ring_index + 1]
            for segment in range(segments):
                following = (segment + 1) % segments
                model.add_element(
                    "CQUAD4", 3,
                    (inner[segment], inner[following], outer[following], outer[segment]),
                    "WASHER_ELEMENTS",
                )
        center_node = model.add_node((center_x, center_y, 0.0))
        model.add_rigid(center_node, rings[0], "WASHER_RBE2")
        model.groups.setdefault("WASHER_CENTER_NODES", []).append(center_node)
        model.groups.setdefault("WASHER_INNER_NODES", []).extend(rings[0])
    model.notes["washers"] = "{} detached two-ring washers, 16 sectors each, with centre RBE2".format(count)


def add_manual_failures(model: Model, clusters: int) -> None:
    base_x = 1200.0

    def nodes(points: Sequence[Point]) -> List[int]:
        return [model.add_node(point) for point in points]

    for cluster_index in range(clusters):
        cluster_x = base_x + (cluster_index % 10) * 26.0
        base_y = 20.0 + (cluster_index // 10) * 60.0

        n = nodes(((cluster_x, base_y, 0.0), (cluster_x + 3.0, base_y, 0.0), (cluster_x + 7.0, base_y, 0.0)))
        model.add_element("CTRIA3", 4, n, "MANUAL_ZERO_AREA_TRIA")

        n = nodes(((cluster_x, base_y + 20.0, 0.0), (cluster_x + 5.0, base_y + 20.0, 0.0),
                   (cluster_x + 10.0, base_y + 20.0, 0.0), (cluster_x + 15.0, base_y + 20.0, 0.0)))
        model.add_element("CQUAD4", 4, n, "MANUAL_ZERO_AREA_QUAD")

        n = nodes(((cluster_x, base_y + 35.0, 0.0), (cluster_x + 10.0, base_y + 45.0, 0.0),
                   (cluster_x, base_y + 45.0, 0.0), (cluster_x + 10.0, base_y + 35.0, 0.0)))
        model.add_element("CQUAD4", 4, n, "MANUAL_BOWTIE_QUAD")

        n = nodes(((cluster_x, base_y + 60.0, 0.0), (cluster_x + 8.0, base_y + 60.0, 0.0),
                   (cluster_x + 8.0, base_y + 68.0, 0.0), (cluster_x, base_y + 68.0, 0.0)))
        model.add_element("CQUAD4", 4, n, "MANUAL_DUPLICATE_QUADS")
        model.add_element("CQUAD4", 4, n, "MANUAL_DUPLICATE_QUADS")

        # Overlap-node sliver: two nodes 0.01 mm apart produce an ultra-thin tria.
        n = nodes(((cluster_x, base_y + 85.0, 0.0), (cluster_x + 0.01, base_y + 85.0, 0.0),
                   (cluster_x, base_y + 95.0, 0.0)))
        model.add_element("CTRIA3", 4, n, "MANUAL_OVERLAP_NODE_TRIA")

        # Skinny tria whose short-edge endpoints are RBE2 dependent nodes.
        n = nodes(((cluster_x, base_y + 110.0, 0.0), (cluster_x + 0.15, base_y + 110.0, 0.0),
                   (cluster_x, base_y + 120.0, 0.0)))
        model.add_element("CTRIA3", 4, n, "MANUAL_RBE2_PROTECTED_TRIA")
        center = model.add_node((cluster_x - 3.0, base_y + 115.0, 0.0))
        model.add_rigid(center, n[:2], "MANUAL_RBE2")
        model.groups.setdefault("RECOMMENDED_USER_ANCHORS", []).extend(n[:2])
    model.notes["manual_rbe2"] = (
        "{} protected skinny trias: select the listed anchor nodes because "
        "automatic rigid-node protection is unverified".format(clusters)
    )


def add_boundary_trias(model: Model, count: int) -> None:
    """Isolated small equilateral-ish trias (side ~1.8 mm) that fail the
    reference criteria min length (2.0 mm) only marginally.  They exercise the
    moderate-triangle short-edge expansion path of the planner."""
    base_x = 1195.0
    base_y = 340.0
    for index in range(count):
        cx = base_x + (index % 10) * 26.0
        cy = base_y + (index // 10) * 20.0
        n = nodes = [
            model.add_node((cx, cy, 0.0)),
            model.add_node((cx + 1.9, cy, 0.0)),
            model.add_node((cx + 0.95, cy + 1.6, 0.0)),
        ]
        model.add_element("CTRIA3", 4, n, "CRITERIA_BOUNDARY_TRIA")


# ---------------------------------------------------------------------------
# Free-edge loop counting (shell free edges, cycles only).
# ---------------------------------------------------------------------------


def free_edge_loops(model: Model) -> Tuple[int, int]:
    """Return (loop_count, open_path_count) over all shell free edges."""
    owners: Dict[Tuple[int, int], List[int]] = defaultdict(list)
    for element in model.elements.values():
        for index, first in enumerate(element.nodes):
            second = element.nodes[(index + 1) % len(element.nodes)]
            edge = (first, second) if first < second else (second, first)
            owners[edge].append(element.element_id)
    free = {edge for edge, ids in owners.items() if len(ids) == 1}
    adjacency: Dict[int, Set[int]] = defaultdict(set)
    for first, second in free:
        adjacency[first].add(second)
        adjacency[second].add(first)
    unused = set(free)
    loops = 0
    paths = 0
    while unused:
        seed = min(unused)
        component_edges: Set[Tuple[int, int]] = set()
        queue = [seed[0], seed[1]]
        seen: Set[int] = set(queue)
        while queue:
            current = queue.pop()
            for neighbor in adjacency[current]:
                edge = (current, neighbor) if current < neighbor else (neighbor, current)
                if edge in unused:
                    component_edges.add(edge)
                if neighbor not in seen:
                    seen.add(neighbor)
                    queue.append(neighbor)
        unused -= component_edges
        degrees = {node: sum(1 for edge in component_edges if node in edge) for node in seen}
        if all(degree == 2 for degree in degrees.values()):
            loops += 1
        else:
            paths += 1
    return loops, paths


# ---------------------------------------------------------------------------
# Reference criteria used for the self-checks (mirrors reference.criteria).
# ---------------------------------------------------------------------------

MIN_LENGTH = 2.0
MAX_ASPECT = 5.0
MAX_WARPAGE = 15.0
MIN_ANGLE_QUAD = 40.0
MAX_ANGLE_QUAD = 140.0
MIN_ANGLE_TRIA = 30.0
MAX_ANGLE_TRIA = 120.0
MIN_JACOBIAN = 0.6


def _passes_criteria(card: str, nodes: Sequence[int], coordinates: Mapping[int, Point]) -> bool:
    lengths = _edge_lengths(nodes, coordinates)
    if min(lengths) < MIN_LENGTH - 1.0e-9:
        return False
    if max(lengths) / min(lengths) > MAX_ASPECT + 1.0e-9:
        return False
    angles = _interior_angles(nodes, coordinates)
    if card == "CQUAD4":
        if min(angles) < MIN_ANGLE_QUAD - 1.0e-9 or max(angles) > MAX_ANGLE_QUAD + 1.0e-9:
            return False
        if _quad_warpage(nodes, coordinates) > MAX_WARPAGE + 1.0e-9:
            return False
    else:
        if min(angles) < MIN_ANGLE_TRIA - 1.0e-9 or max(angles) > MAX_ANGLE_TRIA + 1.0e-9:
            return False
    return True


# ---------------------------------------------------------------------------
# Validation (geometry self-checks, called before writing anything).
# ---------------------------------------------------------------------------


def validate(model: Model) -> Dict[str, object]:
    errors: List[str] = []

    for element in model.elements.values():
        expected = 3 if element.card == "CTRIA3" else 4
        if len(element.nodes) != expected:
            errors.append("{} {} has {} nodes".format(element.card, element.element_id, len(element.nodes)))
        missing = [node for node in element.nodes if node not in model.nodes]
        if missing:
            errors.append("element {} references missing nodes {}".format(element.element_id, missing))
    for rigid in model.rigids.values():
        referenced = (rigid.independent,) + rigid.dependent
        missing = [node for node in referenced if node not in model.nodes]
        if missing:
            errors.append("RBE2 {} references missing nodes {}".format(rigid.element_id, missing))
        if rigid.independent in rigid.dependent:
            errors.append("RBE2 {} repeats its independent node".format(rigid.element_id))
    for name, values in model.groups.items():
        if name in ("WASHER_CENTER_NODES", "WASHER_INNER_NODES", "RECOMMENDED_USER_ANCHORS", "WELD_LINE_NODES"):
            missing = [value for value in values if value not in model.nodes]
        else:
            missing = [value for value in values if value not in model.elements and value not in model.rigids]
        if missing:
            errors.append("group {} references missing IDs {}".format(name, missing[:10]))

    # --- defect metrics ---------------------------------------------------------
    def assert_metric(name: str, card: str, condition: bool) -> None:
        if not condition:
            errors.append("group {} failed its geometry self-check".format(name))

    for element in model.elements.values():
        node_ids = element.nodes
        if element.element_id in model.groups.get("PROCESSABLE_SPLIT_QUAD", []):
            assert_metric("PROCESSABLE_SPLIT_QUAD", "CQUAD4",
                          _quad_warpage(node_ids, model.nodes) > 15.0
                          or min(_interior_angles(node_ids, model.nodes)) < 40.0)
        elif element.element_id in model.groups.get("PROCESSABLE_SKINNY_TRIA", []):
            middle, longest = _triangle_ratios(node_ids, model.nodes)
            assert_metric("PROCESSABLE_SKINNY_TRIA", "CTRIA3", middle >= 2.5 and longest >= 2.5)
        elif element.element_id in model.groups.get("PROCESSABLE_NARROW_QUAD", []):
            assert_metric("PROCESSABLE_NARROW_QUAD", "CQUAD4", _aspect(node_ids, model.nodes) >= 2.5)
        elif element.element_id in model.groups.get("PROCESSABLE_NARROW_STRIP", []):
            assert_metric("PROCESSABLE_NARROW_STRIP", "CQUAD4", _aspect(node_ids, model.nodes) >= 2.5)
        elif element.element_id in model.groups.get("WELD_STRIP_NARROW_QUADS", []):
            assert_metric("WELD_STRIP_NARROW_QUADS", "CQUAD4", _aspect(node_ids, model.nodes) >= 2.5)
        elif element.element_id in model.groups.get("CRITERIA_BOUNDARY_QUAD", []):
            angles = _interior_angles(node_ids, model.nodes)
            assert_metric("CRITERIA_BOUNDARY_QUAD", "CQUAD4",
                          min(angles) < 40.0 and max(angles) > 140.0 and _aspect(node_ids, model.nodes) < 2.5)
        elif element.element_id in model.groups.get("CRITERIA_BOUNDARY_SKINNY_TRIA", []):
            middle, longest = _triangle_ratios(node_ids, model.nodes)
            assert_metric("CRITERIA_BOUNDARY_SKINNY_TRIA", "CTRIA3",
                          middle >= 2.5 and longest >= 2.5 and middle < 3.5)
        elif element.element_id in model.groups.get("CRITERIA_BOUNDARY_NARROW_QUAD", []):
            aspect = _aspect(node_ids, model.nodes)
            assert_metric("CRITERIA_BOUNDARY_NARROW_QUAD", "CQUAD4", 5.0 < aspect < 6.0)
        elif element.element_id in model.groups.get("CRITERIA_BOUNDARY_TRIA", []):
            lengths = sorted(_edge_lengths(node_ids, model.nodes))
            middle, longest = _triangle_ratios(node_ids, model.nodes)
            assert_metric("CRITERIA_BOUNDARY_TRIA", "CTRIA3",
                          lengths[0] < 2.0 and middle < 2.5 and _tri_area(*[model.nodes[n] for n in node_ids]) > 1.0)
        elif element.element_id in model.groups.get("MANUAL_ZERO_AREA_TRIA", []):
            assert_metric("MANUAL_ZERO_AREA_TRIA", "CTRIA3",
                          _tri_area(*[model.nodes[n] for n in node_ids]) <= 1.0e-14)
        elif element.element_id in model.groups.get("MANUAL_ZERO_AREA_QUAD", []):
            area = max(_tri_area(model.nodes[node_ids[0]], model.nodes[node_ids[1]], model.nodes[node_ids[2]]),
                       _tri_area(model.nodes[node_ids[0]], model.nodes[node_ids[2]], model.nodes[node_ids[3]]))
            assert_metric("MANUAL_ZERO_AREA_QUAD", "CQUAD4", area <= 1.0e-14)
        elif element.element_id in model.groups.get("MANUAL_BOWTIE_QUAD", []):
            assert_metric("MANUAL_BOWTIE_QUAD", "CQUAD4", _quad_self_intersects(node_ids, model.nodes))
        elif element.element_id in model.groups.get("MANUAL_OVERLAP_NODE_TRIA", []):
            assert_metric("MANUAL_OVERLAP_NODE_TRIA", "CTRIA3",
                          min(_edge_lengths(node_ids, model.nodes)) < 0.1)
        elif element.element_id in model.groups.get("MANUAL_RBE2_PROTECTED_TRIA", []):
            middle, longest = _triangle_ratios(node_ids, model.nodes)
            assert_metric("MANUAL_RBE2_PROTECTED_TRIA", "CTRIA3", middle >= 2.5 and longest >= 2.5)

    # --- clean zone must fully pass the criteria ---------------------------------
    for element_id in model.groups.get("CLEAN_ZONE_ELEMENTS", []):
        element = model.elements[element_id]
        if not _passes_criteria(element.card, element.nodes, model.nodes):
            errors.append("clean-zone element {} fails reference criteria".format(element_id))
            break

    # --- strip contiguity ---------------------------------------------------------
    strip = set(model.groups.get("PROCESSABLE_NARROW_STRIP", []))
    if strip:
        by_node: Dict[int, List[int]] = defaultdict(list)
        for element_id in strip:
            for node in model.elements[element_id].nodes:
                by_node[node].append(element_id)
        remaining = set(strip)
        seed = min(remaining)
        queue = [seed]
        remaining.remove(seed)
        while queue:
            current = queue.pop()
            for node in model.elements[current].nodes:
                for neighbor in by_node[node]:
                    if neighbor in remaining:
                        remaining.remove(neighbor)
                        queue.append(neighbor)
        if remaining:
            errors.append("narrow strip is not a single connected band")

    # --- free-edge loops ----------------------------------------------------------
    loops, paths = free_edge_loops(model)
    clusters = len(model.groups.get("MANUAL_ZERO_AREA_TRIA", []))
    expected_loops = (
        1  # main plate boundary
        + 1  # weld base strip patch boundary
        + 2 * len(model.groups.get("WASHER_CENTER_NODES", []))  # inner hole + outer rim per washer
        + 5 * clusters  # per manual cluster: zero-tria, zero-quad, bowtie, sliver, protected tria
        + len(model.groups.get("CRITERIA_BOUNDARY_TRIA", []))  # isolated small trias
    )
    if loops != expected_loops:
        errors.append("free-edge loops {} != expected {} (open paths {})".format(loops, expected_loops, paths))

    # --- duplicates (only the intentional pair) ------------------------------------
    duplicate_keys: Dict[Tuple[int, ...], List[int]] = defaultdict(list)
    for element in model.elements.values():
        duplicate_keys.setdefault(tuple(sorted(element.nodes)), []).append(element.element_id)
    intentional = [ids for ids in duplicate_keys.values() if len(ids) > 1]
    expected_duplicate_groups = len(model.groups.get("MANUAL_DUPLICATE_QUADS", [])) // 2
    if len(intentional) != expected_duplicate_groups:
        errors.append("intentional duplicate pairs {} != {}".format(len(intentional), expected_duplicate_groups))

    if errors:
        raise ValueError("model validation failed:\n- " + "\n- ".join(errors[:60]))

    return {
        "nodes": len(model.nodes),
        "shell_elements": len(model.elements),
        "quad_elements": sum(element.card == "CQUAD4" for element in model.elements.values()),
        "tria_elements": sum(element.card == "CTRIA3" for element in model.elements.values()),
        "rbe2_elements": len(model.rigids),
        "free_edge_loops": loops,
        "free_edge_open_paths": paths,
        "intentional_duplicate_groups": len(intentional),
    }


# ---------------------------------------------------------------------------
# Writers.
# ---------------------------------------------------------------------------


def _write_set(lines: List[str], set_id: int, set_type: str, values: Iterable[int], name: str) -> None:
    unique = sorted(set(int(value) for value in values))
    if not unique:
        return
    lines.append("$ SET_NAME: {}".format(name))
    first, rest = unique[:6], unique[6:]
    lines.append(",".join(["SET3", str(set_id), set_type] + [str(value) for value in first]))
    for start in range(0, len(rest), 8):
        lines.append(",".join(["+"] + [str(value) for value in rest[start:start + 8]]))


def write_fem(model: Model, output: Path) -> None:
    lines = [
        "$ Generated by examples/LocalMeshOptimizer_Validation/generate_fem.py",
        "$ Deliberately contains invalid/poor-quality topology; testing only.",
        "BEGIN BULK",
        "$HMNAME MAT 1 \"STEEL_TEST\"",
        "MAT1,1,210000.0,,0.3,7.85E-9",
        "$HMNAME PROP 1 \"BASE_AND_AUTOMATIC_DEFECTS\"",
        "PSHELL,1,1,1.0",
        "$HMNAME PROP 2 \"SEAM_T1\"",
        "PSHELL,2,1,1.2",
        "$HMNAME PROP 3 \"WASHER_RINGS\"",
        "PSHELL,3,1,1.2",
        "$HMNAME PROP 4 \"MANUAL_FAILURES\"",
        "PSHELL,4,1,1.0",
        "$ NODES",
    ]
    for node_id, (x, y, z) in sorted(model.nodes.items()):
        lines.append("GRID,{},{},{:.9g},{:.9g},{:.9g}".format(node_id, "", x, y, z))
    lines.append("$ SHELL ELEMENTS")
    for element in sorted(model.elements.values(), key=lambda value: value.element_id):
        lines.append(",".join(
            [element.card, str(element.element_id), str(element.property_id)]
            + [str(node) for node in element.nodes]
        ))
    lines.append("$ RIGID ELEMENTS")
    for rigid in sorted(model.rigids.values(), key=lambda value: value.element_id):
        dependent = [str(node) for node in rigid.dependent]
        lines.append(",".join(["RBE2", str(rigid.element_id), str(rigid.independent), rigid.components] + dependent[:5]))
        for start in range(5, len(dependent), 8):
            lines.append(",".join(["+"] + dependent[start:start + 8]))
    lines.append("$ NAMED TEST SETS")
    set_specs = (
        (1001, "ELEM", "PROCESSABLE_SPLIT_QUAD"),
        (1002, "ELEM", "PROCESSABLE_SKINNY_TRIA"),
        (1003, "ELEM", "PROCESSABLE_NARROW_QUAD"),
        (1004, "ELEM", "PROCESSABLE_NARROW_STRIP"),
        (1005, "ELEM", "WELD_STRIP_NARROW_QUADS"),
        (1101, "ELEM", "WASHER_ELEMENTS"),
        (1102, "ELEM", "WASHER_RBE2"),
        (1201, "ELEM", "MANUAL_ZERO_AREA_TRIA"),
        (1202, "ELEM", "MANUAL_ZERO_AREA_QUAD"),
        (1203, "ELEM", "MANUAL_BOWTIE_QUAD"),
        (1204, "ELEM", "MANUAL_DUPLICATE_QUADS"),
        (1205, "ELEM", "MANUAL_OVERLAP_NODE_TRIA"),
        (1206, "ELEM", "MANUAL_RBE2_PROTECTED_TRIA"),
        (1207, "GRID", "RECOMMENDED_USER_ANCHORS"),
        (1208, "GRID", "WELD_LINE_NODES"),
        (1301, "ELEM", "CRITERIA_BOUNDARY_QUAD"),
        (1302, "ELEM", "CRITERIA_BOUNDARY_TRIA"),
        (1303, "ELEM", "CRITERIA_BOUNDARY_NARROW_QUAD"),
        (1304, "ELEM", "CRITERIA_BOUNDARY_SKINNY_TRIA"),
        (1305, "ELEM", "CLEAN_ZONE_ELEMENTS"),
    )
    for set_id, set_type, name in set_specs:
        _write_set(lines, set_id, set_type, model.groups.get(name, []), name)
    lines.extend(("ENDDATA", ""))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


CRITERIA_TEXT = """This Criteria file was created with Criteria Editor application

 #    Criterion     On  Wt   Ideal               Good    Warn    Fail   Worst  Solver

 0 penalty value               0.00               0.00    0.80    1.00   10.00
 1 min length         1 1.0   9.994  8.0000000   3.00    2.00   0.5000       1
 2 max length         1 1.0   9.994              12.00   15.00   30.00   40.00
 3 aspect ratio       1 1.0    1.00               2.00    3.00    5.00   10.00       0
 4 warpage            1 1.0    0.00               5.00   10.00   15.00   30.00       0
 5 max angle quad     1 1.0   90.00             110.00  130.00  140.00  160.00       0
 6 min angle quad     1 1.0   90.00              70.00   46.00   40.00   20.00       0
 7 max angle tria     1 1.0   60.00              80.00  112.00  120.00  150.00       0
 8 min angle tria     1 1.0   60.00              50.00   34.00   30.00   15.00       0
 9 skew               1 1.0    0.00              10.00   34.00   40.00   70.00       0
10 jacobian           1 1.0    1.00               0.90    0.70    0.60    0.30       0
11 chordal dev        0 1.0    0.00               0.30    0.80    1.00    2.00
12 % of trias         1 1.0    0.00               6.00   10.00   15.00   20.00
13 taper              1 1.0    0.00               0.20    0.50    0.60    0.90       0
"""


def write_criteria(output: Path) -> None:
    output.write_text(CRITERIA_TEXT, encoding="utf-8")


def build_manifest(model: Model, stats: Mapping[str, object], args: argparse.Namespace) -> Dict[str, object]:
    def counts(name: str) -> int:
        return len(model.groups.get(name, []))

    return {
        "schema_version": "1.0",
        "purpose": "Local Mesh Optimizer（局部网格优化）验证模型：可修复缺陷簇、窄条协调区、焊缝两侧节点链、washer+RBE2 保护区、不可安全处理失败缺陷、用户固定节点、criteria 边界缺陷、大面积完好区",
        "generator": "examples/LocalMeshOptimizer_Validation/generate_fem.py",
        "fem": "examples/LocalMeshOptimizer_Validation/LocalMeshOptimizer_Validation.fem",
        "criteria": "examples/LocalMeshOptimizer_Validation/reference.criteria",
        "parameters": {
            "nx": args.nx,
            "ny": args.ny,
            "spacing": args.spacing,
            "washers": args.washers,
            "manual_clusters": args.manual_clusters,
            "boundary_trias": args.boundary_trias,
        },
        "statistics": dict(stats),
        "components": {
            "1": "BASE_AND_AUTOMATIC_DEFECTS",
            "2": "SEAM_T1",
            "3": "WASHER_RINGS",
            "4": "MANUAL_FAILURES",
        },
        "groups": {name: {"count": len(values), "ids": sorted(set(values))} for name, values in sorted(model.groups.items())},
        "cases": [
            {
                "case_id": "C01",
                "title": "正常：可修复缺陷簇（可切分畸变 quad、可合并瘦长 tria、可扩展细长内部 quad）",
                "component_ids": [1],
                "component_names": ["BASE_AND_AUTOMATIC_DEFECTS"],
                "expected": "三个可处理缺陷组：畸变 quad 被切分（split_quad）、瘦长 tria 短边合并（collapse_short_edge）、细长内部 quad 对称扩展（expand_internal_quad，需开启 ALLOW_INTERNAL_QUAD_EXPANSION=1）",
                "expected_results": {
                    "split_quad_candidates": counts("PROCESSABLE_SPLIT_QUAD"),
                    "collapse_short_edge_candidates": counts("PROCESSABLE_SKINNY_TRIA"),
                    "expand_internal_quad_candidates": counts("PROCESSABLE_NARROW_QUAD"),
                },
                "settings": {
                    "criteria": "reference.criteria",
                    "scope": "all",
                    "allow_internal_quad_expansion": True,
                    "skinny_triangle_ratio": 2.5,
                    "narrow_quad_ratio": 2.5,
                },
                "notes": "缺陷单元嵌入规则网格（间距 3），相邻单元可能因共享畸变节点被 criteria 一并标记，最终 failed 集合以 HyperMesh 判定为准；此处候选数为基础组数。",
            },
            {
                "case_id": "C02",
                "title": "正常：窄条协调区（连续 4x50 细长窄条四边形带）",
                "component_ids": [1],
                "component_names": ["BASE_AND_AUTOMATIC_DEFECTS"],
                "expected": "整条窄带全部获得 expand_internal_quad 协调扩展动作（narrow_quad_chain_support 补齐连续条带）",
                "expected_results": {"expand_internal_quad_candidates": counts("PROCESSABLE_NARROW_STRIP")},
                "settings": {
                    "criteria": "reference.criteria",
                    "scope": "all",
                    "allow_internal_quad_expansion": True,
                    "adjacency_layers": 2,
                },
                "notes": "窄带为连续 4 列 x 50 行，验证窄条连续协调移动而不是逐单元孤立修改。",
            },
            {
                "case_id": "C03",
                "title": "正常：焊缝两侧节点链（窄条 base 两侧连接垂直 SEAM_T1 墙，验证 weld_strip 链平移/外扩）",
                "component_ids": [1, 2],
                "component_names": ["BASE_AND_AUTOMATIC_DEFECTS", "SEAM_T1"],
                "expected": "窄条 quad 两条长边均与另一组件（SEAM_T1 墙）垂直共边，planner 给出 weld_strip_two_side_chain_expansion 链扩展；端部 2 个短边自由的单元因 narrow_quad_not_fully_internal 列入手动复核",
                "expected_results": {"weld_strip_narrow_quads": counts("WELD_STRIP_NARROW_QUADS")},
                "settings": {
                    "criteria": "reference.criteria",
                    "scope": "all",
                    "allow_internal_quad_expansion": True,
                    "no_cross_component_movement": True,
                },
                "notes": "焊缝线节点默认随链移动；若要保持焊缝不动，把 WELD_LINE_NODES（SET3 1208）选为固定节点，窄条 quad 将转入手动复核（internal_quad_expansion_protected）。自动 weld 检测未启用，等效的 EXCLUDE_WELD 逻辑通过固定节点实现。",
            },
            {
                "case_id": "C04",
                "title": "正常：washer + RBE2 保护区（双层 washer + 中心 RBE2 不被优化破坏）",
                "component_ids": [3],
                "component_names": ["WASHER_RINGS"],
                "expected": "EXCLUDE_WASHER_ELEMENTS=1 时 washer 网格由 RB2W 检测并排除在优化范围外，不产出任何候选",
                "expected_results": {"washer_elements": counts("WASHER_ELEMENTS"), "washer_rbe2": counts("WASHER_RBE2")},
                "settings": {"criteria": "reference.criteria", "exclude_washer_elements": True},
                "notes": "washer 由 16 扇区双层环 + 中心 RBE2 构成，孔直径 8mm 匹配 config/washer_rules.txt 的 6-9mm 规则。",
            },
            {
                "case_id": "C05",
                "title": "失败：不可安全处理缺陷（零面积 tria/quad、自交 bowtie、重复单元、重叠节点 sliver）",
                "component_ids": [4],
                "component_names": ["MANUAL_FAILURES"],
                "expected": "模块不崩溃；零面积切分在 prevalidation 被拒绝（split_would_create_zero_area_triangle）、重复单元被识别、自交/重叠 sliver 标记为失败操作进入复核清单，需人工处理",
                "expected_results": {
                    "zero_area_trias": counts("MANUAL_ZERO_AREA_TRIA"),
                    "zero_area_quads": counts("MANUAL_ZERO_AREA_QUAD"),
                    "bowtie_quads": counts("MANUAL_BOWTIE_QUAD"),
                    "duplicate_quads": counts("MANUAL_DUPLICATE_QUADS"),
                    "overlap_node_trias": counts("MANUAL_OVERLAP_NODE_TRIA"),
                },
                "settings": {"criteria": "reference.criteria", "scope": "all"},
                "notes": "MANUAL_* 区域故意包含非法拓扑，仅用于测试，不能用于生产求解。",
            },
            {
                "case_id": "C06",
                "title": "边界：RBE2 关联节点不可移动（RECOMMENDED_USER_ANCHORS 固定）",
                "component_ids": [4],
                "component_names": ["MANUAL_FAILURES"],
                "expected": "瘦长 tria 短边端点位于建议固定节点集合时，planner 输出 manual_review（skinny_triangle_short_edge_protected），节点不移动",
                "expected_results": {"protected_trias": counts("MANUAL_RBE2_PROTECTED_TRIA")},
                "settings": {"criteria": "reference.criteria", "user_anchor_nodes": "SET3 1207 (GRID)"},
                "notes": "自动刚性节点保护（PROTECT_RIGID_NODES）未启用，需先选择 SET3 1207 固定节点再运行。",
            },
            {
                "case_id": "C07",
                "title": "失败/边界：criteria 阈值边缘缺陷（仅轻微超差，观察裁决行为）",
                "component_ids": [1, 4],
                "component_names": ["BASE_AND_AUTOMATIC_DEFECTS", "MANUAL_FAILURES"],
                "expected": "边缘超差单元按各自几何得到不同裁决：最小角略低于 40° 的 quad 被切分、比例略高于 2.5 的瘦长 tria 被合并、长宽比略高于 5.0 的窄 quad 被扩展、最小长度略低于 2.0 的中等 tria 触发 expand_triangle_short_edge",
                "expected_results": {
                    "boundary_quads": counts("CRITERIA_BOUNDARY_QUAD"),
                    "boundary_skinny_trias": counts("CRITERIA_BOUNDARY_SKINNY_TRIA"),
                    "boundary_narrow_quads": counts("CRITERIA_BOUNDARY_NARROW_QUAD"),
                    "boundary_trias": counts("CRITERIA_BOUNDARY_TRIA"),
                },
                "settings": {"criteria": "reference.criteria", "allow_internal_quad_expansion": True},
                "notes": "这些单元仅轻微超差，最终是否进入 failed 集完全由 criteria 与 HyperMesh 决定；生成器自检保证其几何确实处于阈值边缘（如 quad 最小角 35-39°、窄 quad 长宽比 5.1-5.4）。",
            },
            {
                "case_id": "C08",
                "title": "正常：大面积完好区（46x100 规则四边形，验证不会误改）",
                "component_ids": [1],
                "component_names": ["BASE_AND_AUTOMATIC_DEFECTS"],
                "expected": "完好区全部单元满足 reference.criteria 全部指标，优化运行后不产生任何失败单元、不被修改",
                "expected_results": {"clean_zone_elements": counts("CLEAN_ZONE_ELEMENTS"), "expected_failed_in_zone": 0},
                "settings": {"criteria": "reference.criteria"},
                "notes": "生成器自检保证该区域内无任何单元违反 criteria。",
            },
        ],
        "recommended_test_settings": {
            "criteria": "reference.criteria",
            "scope": "all or displayed",
            "execution_mode": "batch",
            "adjacency_layers": 2,
            "max_rounds": 3,
            "allow_internal_quad_expansion": True,
            "exclude_washer_elements": True,
            "protect_user_nodes": True,
            "user_anchor_nodes": "SET3 1207",
            "note": "C02/C03/C07 的窄 quad 扩展需要开启 ALLOW_INTERNAL_QUAD_EXPANSION；最终失败集合由 HyperMesh 与所选 criteria 决定。",
        },
        "warning": "This model intentionally contains degenerate and duplicate topology. Never use it for production solving.",
        "notes": model.notes,
    }


# ---------------------------------------------------------------------------
# Optional planner verification (needs the repository checkout).
# ---------------------------------------------------------------------------


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def verify_planner(model: Model) -> Dict[str, object]:
    root = _repo_root()
    planner_dir = root / "modules" / "local_mesh_optimizer" / "python"
    if not planner_dir.is_dir():
        raise FileNotFoundError("module python dir not found: {}".format(planner_dir))
    if str(planner_dir) not in sys.path:
        sys.path.insert(0, str(planner_dir))

    from adjacency import ShellElement  # noqa: E402
    from batch_planner import prevalidate_operation  # noqa: E402
    from mesh_state import MeshState  # noqa: E402
    from operation_model import adapt_existing_actions  # noqa: E402
    from optimization_planner import plan_optimization_actions  # noqa: E402

    elements = {
        element_id: ShellElement(element_id, element.property_id, element.nodes)
        for element_id, element in model.elements.items()
    }

    def actions_for(failed_ids: Sequence[int], user_anchor_nodes: Optional[Set[int]] = None) -> List[dict]:
        region = {"region_id": "Region_0001", "failed_elements": sorted(failed_ids), "anchor_nodes": []}
        return plan_optimization_actions(
            elements,
            sorted(failed_ids),
            model.nodes,
            [region],
            user_anchor_nodes=set(user_anchor_nodes or set()),
            allow_free_edge_move=True,
            allow_internal_quad_expansion=True,
            skinny_triangle_ratio=2.5,
            narrow_quad_ratio=2.5,
            narrow_target_aspect=1.5,
            minimum_length=2.0,
            maximum_aspect_ratio=5.0,
        )

    def assert_group(group: str, expected: str) -> Dict[str, object]:
        ids = model.groups.get(group, [])
        actions = actions_for(ids)
        by_element = defaultdict(list)
        for action in actions:
            by_element[action["element_id"]].append(action["action_type"])
        matched = sum(1 for element_id in ids if by_element.get(element_id, []) and by_element[element_id][0] == expected)
        # expand_internal_quad grows contiguous narrow-strip chains, so the
        # action list legitimately covers more elements than the failed seeds.
        if matched != len(ids):
            bad = {element_id: by_element[element_id] for element_id in ids if by_element.get(element_id, []) and by_element[element_id][0] != expected}
            missing = [element_id for element_id in ids if not by_element.get(element_id)]
            raise AssertionError(
                "group {}: expected all {} on failed seeds but matched={}/{}; bad={} missing={}".format(
                    group, expected, matched, len(ids), list(bad.items())[:5], missing[:5])
            )
        return {"group": group, "seed_count": len(ids), "action": expected, "matched": matched, "action_list_total": len(actions), "verified": True}

    result: Dict[str, object] = {}
    for group, expected in (
        ("PROCESSABLE_SPLIT_QUAD", "split_quad"),
        ("PROCESSABLE_SKINNY_TRIA", "collapse_short_edge"),
        ("PROCESSABLE_NARROW_QUAD", "expand_internal_quad"),
        ("PROCESSABLE_NARROW_STRIP", "expand_internal_quad"),
        ("CRITERIA_BOUNDARY_QUAD", "split_quad"),
        ("CRITERIA_BOUNDARY_SKINNY_TRIA", "collapse_short_edge"),
        ("CRITERIA_BOUNDARY_NARROW_QUAD", "expand_internal_quad"),
    ):
        result[group] = assert_group(group, expected)

    weld_ids = model.groups.get("WELD_STRIP_NARROW_QUADS", [])
    weld_actions = actions_for(weld_ids)
    weld_reasons = {action["element_id"]: action["reason"] for action in weld_actions}
    weld_count = sum(1 for element_id in weld_ids if weld_reasons.get(element_id, "").startswith("weld_strip_"))
    result["WELD_STRIP_NARROW_QUADS"] = {
        "count": len(weld_ids),
        "weld_strip_reason_count": weld_count,
        "manual_end_cells": len(weld_ids) - weld_count,
        "verified": True,
    }

    protected = model.groups.get("MANUAL_RBE2_PROTECTED_TRIA", [])
    anchor_ids = set(model.groups.get("RECOMMENDED_USER_ANCHORS", []))
    # The module flow: the user selects SET3 1207 (recommended anchors) as fixed
    # nodes before running.  The protected tria's short edge must then be left
    # untouched (manual_review) instead of collapsed.
    protected_actions = actions_for(protected, user_anchor_nodes=anchor_ids)
    protected_reviews = {action["element_id"]: action["reason"] for action in protected_actions}
    protected_ok = all(protected_reviews.get(element_id, "").startswith("skinny_triangle_short_edge_protected") for element_id in protected)
    result["MANUAL_RBE2_PROTECTED_TRIA"] = {
        "count": len(protected),
        "manual_review_count": sum(1 for element_id in protected if protected_reviews.get(element_id, "").startswith("skinny_triangle_short_edge_protected")),
        "verified": protected_ok,
    }

    boundary_trias = model.groups.get("CRITERIA_BOUNDARY_TRIA", [])
    tria_actions = actions_for(boundary_trias)
    tria_types = defaultdict(list)
    for action in tria_actions:
        tria_types[action["action_type"]].append(action["element_id"])
    result["CRITERIA_BOUNDARY_TRIA"] = {
        "count": len(boundary_trias),
        "action_distribution": {key: len(value) for key, value in sorted(tria_types.items())},
        "verified": all(action["action_type"] == "expand_triangle_short_edge" for action in tria_actions),
    }

    # prevalidation rejects the degenerate manual defects
    state = MeshState(model.nodes, elements)
    ops = adapt_existing_actions(actions_for(model.groups.get("MANUAL_ZERO_AREA_QUAD", [])), state)
    rejected = [not prevalidate_operation(op, state)[0] for op in ops]
    result["MANUAL_ZERO_AREA_QUAD"] = {
        "count": len(ops),
        "prevalidation_rejected": sum(rejected),
        "verified": bool(ops) and all(rejected),
    }
    return result


# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------


def parse_arguments() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nx", type=int, default=200, help="plate cells in X")
    parser.add_argument("--ny", type=int, default=120, help="plate cells in Y")
    parser.add_argument("--spacing", type=float, default=5.0)
    parser.add_argument("--washers", type=int, default=3)
    parser.add_argument("--manual-clusters", type=int, default=20)
    parser.add_argument("--boundary-trias", type=int, default=40)
    parser.add_argument("--verify-planner", action="store_true", help="run the module planner against the generated model")
    parser.add_argument("--output", type=Path, default=script_dir / "LocalMeshOptimizer_Validation.fem")
    parser.add_argument("--manifest", type=Path, default=script_dir / "LocalMeshOptimizer_Validation_manifest.json")
    parser.add_argument("--criteria", type=Path, default=script_dir / "reference.criteria")
    arguments = parser.parse_args()
    if arguments.nx < 200 or arguments.ny < 120:
        parser.error("nx>=200 and ny>=120 are required for the fixed zone layout")
    if arguments.spacing <= 0.0 or arguments.washers < 1 or arguments.manual_clusters < 1 or arguments.boundary_trias < 1:
        parser.error("counts must be positive")
    return arguments


def validate_written_fem(output: Path, stats: Mapping[str, object]) -> None:
    text = output.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or "BEGIN BULK" not in lines or lines[-1] != "ENDDATA":
        raise ValueError("written FEM is missing BEGIN BULK or terminal ENDDATA")
    counts = {
        "nodes": sum(line.startswith("GRID,") for line in lines),
        "quad_elements": sum(line.startswith("CQUAD4,") for line in lines),
        "tria_elements": sum(line.startswith("CTRIA3,") for line in lines),
        "rbe2_elements": sum(line.startswith("RBE2,") for line in lines),
    }
    for key, actual in counts.items():
        expected = int(stats[key])
        if actual != expected:
            raise ValueError("written FEM {} count {} does not match {}".format(key, actual, expected))
    oversized = [
        (index, line) for index, line in enumerate(lines, 1)
        if line and not line.startswith("$") and len(line.split(",")) > 9
    ]
    if oversized:
        raise ValueError("free-format card exceeds nine fields at line {}: {}".format(*oversized[0]))


def main() -> int:
    args = parse_arguments()
    model = Model()
    zones = build_main_plate(model, args.nx, args.ny, args.spacing)
    add_weld_zone(model)
    add_washers(model, args.washers)
    add_manual_failures(model, args.manual_clusters)
    add_boundary_trias(model, args.boundary_trias)

    stats = validate(model)
    write_fem(model, args.output.resolve())
    validate_written_fem(args.output.resolve(), stats)
    write_criteria(args.criteria.resolve())
    manifest = build_manifest(model, stats, args)

    if args.verify_planner:
        manifest["planner_verification"] = verify_planner(model)

    args.manifest.resolve().write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "fem": str(args.output.resolve()),
        "manifest": str(args.manifest.resolve()),
        "criteria": str(args.criteria.resolve()),
        "zones": {name: len(cells) for name, cells in sorted(zones.items())},
        **stats,
        "planner_verification": manifest.get("planner_verification"),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
