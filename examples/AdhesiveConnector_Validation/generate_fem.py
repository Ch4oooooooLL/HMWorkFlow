#!/usr/bin/env python3
"""Generate one shell-mesh OptiStruct FEM for Adhesive Connector validation.

All scenarios are placed in one deck and separated along global X (pitch
>= 300 mm).  Every scenario is a set of parallel shell plates with a separate
glue PATCH component carrying the location elements on the mid-gap plane, which
matches the reference geometry of `runtime/adhesive_probe_model.fem`.

The module under test (`modules/adhesive_connector.tcl`) works as follows
(confirmed against the source and its unit tests):

  * pick location shell elements (打胶区域), then >= 2 link components;
  * before creating the Area connector, `cleanLocationElems` projects each
    location element's face samples (4 corners + 4 edge midpoints + centroid)
    along the element normal onto EVERY target component's shell footprint;
    an element is kept only if every sample lands inside the footprint within
    `tolerance` (default 50.0, fixed).  Out-of-footprint elements are removed
    and never submitted to HyperMesh;
  * if nothing remains, the module warns "No elements remain after cleaning"
    and stops; otherwise it calls
    `*CE_ConnectorCreateByMarkAndRealizeWithDetails ... area ... optistruct
    1001 <adhesives> <tol> ...` and requires the connector to end REALIZED
    (RBE3 + HEXA8 adhesives).

This script re-implements that projection logic in pure Python (same sample
points, same 3-D point-in-triangle fan test, same tolerance check) so the
manifest records the exact expected kept/rejected location-element counts
before any HyperMesh run.  Values are verifiable: the projection distance to
each target plate is the scenario gap (<= tolerance for the success cases,
> tolerance for the gap-too-large failure), and the overhang in the
out-of-bounds case is an exact multiple of the 10 mm cell size.

Run from the repository root:

    runtime\\python\\windows-x64\\python.exe examples\\AdhesiveConnector_Validation\\generate_fem.py

Dependencies: Python 3.8+ standard library only.  Deterministic (no RNG).
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

Point = Tuple[float, float, float]

TOLERANCE = 50.0  # module default, fixed
COATS = 1
THICKNESS = 1.0
CELL = 10.0  # mm mesh size
GAP = 2.0  # default plate gap in mm


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
    color: int
    element_ids: List[int] = field(default_factory=list)


@dataclass
class Model:
    nodes: Dict[int, Point] = field(default_factory=dict)
    elements: Dict[int, Element] = field(default_factory=dict)
    components: Dict[int, Component] = field(default_factory=dict)
    cases: List[Dict[str, object]] = field(default_factory=list)
    next_node_id: int = 1
    next_element_id: int = 1

    def component(self, component_id: int, name: str, color: int = 11) -> Component:
        if component_id in self.components:
            raise ValueError("duplicate component ID {}".format(component_id))
        item = Component(component_id, name, color)
        self.components[component_id] = item
        return item

    def node(self, point: Point) -> int:
        node_id = self.next_node_id
        self.next_node_id += 1
        self.nodes[node_id] = tuple(float(value) for value in point)
        return node_id

    def element(self, component_id: int, card: str, node_ids: Sequence[int]) -> int:
        element_id = self.next_element_id
        self.next_element_id += 1
        item = Element(card, element_id, component_id, tuple(node_ids))
        self.elements[element_id] = item
        self.components[component_id].element_ids.append(element_id)
        return element_id


# --------------------------------------------------------------------------
# Mesh builders
# --------------------------------------------------------------------------

def rect_cells(ncx: int, ncy: int) -> List[Tuple[int, int]]:
    """All cell indices of an ncx x ncy grid (sorted, deterministic)."""
    return [(i, j) for j in range(ncy) for i in range(ncx)]


def add_shell_grid(
    model: Model,
    component_id: int,
    origin: Point,
    ncx: int,
    ncy: int,
    cells: Optional[List[Tuple[int, int]]] = None,
    reverse: bool = False,
) -> Dict[Tuple[int, int], int]:
    """Regular CQUAD4 grid.  `cells` selects a sub-region (default all);
    only the nodes touched by the selected cells are created.
    `reverse` flips the node winding so the face normal points -Z."""
    if cells is None:
        cells = rect_cells(ncx, ncy)
    cells = sorted(set(cells))
    needed = set()
    for (i, j) in cells:
        needed.update(((i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)))
    grid: Dict[Tuple[int, int], int] = {}
    for (i, j) in sorted(needed):
        grid[(i, j)] = model.node((origin[0] + i * CELL, origin[1] + j * CELL, origin[2]))
    for (i, j) in cells:
        if reverse:
            nodes = (grid[(i, j)], grid[(i, j + 1)], grid[(i + 1, j + 1)], grid[(i + 1, j)])
        else:
            nodes = (grid[(i, j)], grid[(i + 1, j)], grid[(i + 1, j + 1)], grid[(i, j + 1)])
        model.element(component_id, "CQUAD4", nodes)
    return grid


def cell_points(origin: Point, i: int, j: int) -> List[Point]:
    """The four corner coordinates of cell (i, j) on the 10 mm grid."""
    x0, y0, z = origin
    x1, y1 = x0 + (i + 1) * CELL, y0 + (j + 1) * CELL
    return [
        (x0 + i * CELL, y0 + j * CELL, z),
        (x1, y0 + j * CELL, z),
        (x1, y1, z),
        (x0 + i * CELL, y1, z),
    ]


# --------------------------------------------------------------------------
# Exact re-implementation of ::AdhesiveConnector::cleanLocationElemsFallback
# --------------------------------------------------------------------------

def vsub(a: Point, b: Point) -> Point:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vadd(a: Point, b: Point) -> Point:
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def vscale(a: Point, s: float) -> Point:
    return (a[0] * s, a[1] * s, a[2] * s)


def dot(a: Point, b: Point) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a: Point, b: Point) -> Point:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def norm(a: Point) -> float:
    return math.sqrt(dot(a, a))


def polygon_normal(points: List[Point]) -> Optional[Point]:
    if len(points) < 3:
        return None
    origin = points[0]
    for index in range(1, len(points) - 1):
        a = vsub(points[index], origin)
        b = vsub(points[index + 1], origin)
        n = cross(a, b)
        length = norm(n)
        if length > 1.0e-12:
            return (n[0] / length, n[1] / length, n[2] / length)
    return None


def point_in_triangle(p: Point, a: Point, b: Point, c: Point) -> bool:
    """Mirror ::AdhesiveConnector::pointInTriangle (3-D, fan triangle a-b-c)."""
    v0 = vsub(c, a)
    v1 = vsub(b, a)
    v2 = vsub(p, a)
    dot00 = dot(v0, v0)
    dot01 = dot(v0, v1)
    dot02 = dot(v0, v2)
    dot11 = dot(v1, v1)
    dot12 = dot(v1, v2)
    denominator = dot00 * dot11 - dot01 * dot01
    if abs(denominator) <= 1.0e-14:
        return False
    u = (dot11 * dot02 - dot01 * dot12) / denominator
    v = (dot00 * dot12 - dot01 * dot02) / denominator
    eps = 1.0e-7
    return u >= -eps and v >= -eps and u + v <= 1.0 + eps


def point_in_polygon(p: Point, points: List[Point]) -> bool:
    """Mirror ::AdhesiveConnector::pointInPolygon (fan from points[0])."""
    origin = points[0]
    for index in range(1, len(points) - 1):
        if point_in_triangle(p, origin, points[index], points[index + 1]):
            return True
    return False


def projection_hits_polygon(point: Point, direction: Point, polygon: List[Point], tolerance: float) -> bool:
    """Mirror ::AdhesiveConnector::projectionHitsPolygon."""
    normal = polygon_normal(polygon)
    if normal is None:
        return False
    denominator = dot(direction, normal)
    if abs(denominator) <= 1.0e-10:
        return False
    distance = dot(vsub(polygon[0], point), normal) / denominator
    if abs(distance) > tolerance + 1.0e-7:
        return False
    projected = vadd(point, vscale(direction, distance))
    return point_in_polygon(projected, polygon)


def sample_points(points: List[Point]) -> List[Point]:
    """Mirror ::AdhesiveConnector::samplePoints: corners + edge midpoints + centroid."""
    samples = list(points)
    count = len(points)
    for index in range(count):
        a = points[index]
        b = points[(index + 1) % count]
        samples.append(vadd(a, vscale(vsub(b, a), 0.5)))
    center = vscale(
        (sum(p[0] for p in points), sum(p[1] for p in points), sum(p[2] for p in points)),
        1.0 / count,
    )
    samples.append(center)
    return samples


class PolygonIndex:
    """2-D spatial bin of shell polygons (mirrors the module's polygon grid:
    in-plane cells expand by one cell so a projected sample is never missed;
    the normal-axis expansion by `tolerance` is irrelevant for the axis-aligned
    plates used here, and a brute-force cross-check is run per scenario)."""

    def __init__(self, polygons: List[List[Point]]) -> None:
        self.polygons = polygons
        spans = []
        for poly in polygons:
            xs = [p[0] for p in poly]
            ys = [p[1] for p in poly]
            spans.append(max(max(xs) - min(xs), max(ys) - min(ys)))
        typical = sum(spans) / len(spans) if spans else 0.0
        self.cell = max(2.0 * typical, 1.0e-6)
        self.grid: Dict[Tuple[int, int], List[int]] = {}
        for index, poly in enumerate(polygons):
            xs = [p[0] for p in poly]
            ys = [p[1] for p in poly]
            x0 = int(math.floor((min(xs) - self.cell) / self.cell))
            x1 = int(math.floor((max(xs) + self.cell) / self.cell))
            y0 = int(math.floor((min(ys) - self.cell) / self.cell))
            y1 = int(math.floor((max(ys) + self.cell) / self.cell))
            for ix in range(x0, x1 + 1):
                for iy in range(y0, y1 + 1):
                    self.grid.setdefault((ix, iy), []).append(index)

    def hits(self, samples: List[Point], direction: Point, tolerance: float) -> bool:
        for point in samples:
            hit = False
            key = (int(math.floor(point[0] / self.cell)), int(math.floor(point[1] / self.cell)))
            for index in self.grid.get(key, ()):
                if projection_hits_polygon(point, direction, self.polygons[index], tolerance):
                    hit = True
                    break
            if not hit:
                return False
        return True

    def hits_bruteforce(self, samples: List[Point], direction: Point, tolerance: float) -> bool:
        for point in samples:
            if not any(projection_hits_polygon(point, direction, poly, tolerance) for poly in self.polygons):
                return False
        return True


def simulate_cleaning(
    patch_elems: List[Tuple[int, int, Point]],
    target_polys: List[List[Point]],
    tolerance: float,
    verify_grid: bool = True,
) -> Tuple[List[Tuple[int, int]], List[Tuple[int, int]]]:
    """Keep only patch elements whose samples project inside the target footprint.
    Returns (kept [(i, j)], rejected [(i, j)]).  `verify_grid` re-checks the
    spatial-index result against a brute-force scan for exactness."""
    target_index = PolygonIndex(target_polys)
    kept: List[Tuple[int, int]] = []
    rejected: List[Tuple[int, int]] = []
    for i, j, origin in patch_elems:
        points = cell_points(origin, i, j)
        direction = polygon_normal(points)
        if direction is None:
            rejected.append((i, j))
            continue
        samples = sample_points(points)
        indexed = target_index.hits(samples, direction, tolerance)
        if verify_grid and indexed != target_index.hits_bruteforce(samples, direction, tolerance):
            raise ValueError("spatial index disagreed with brute force at cell ({},{})".format(i, j))
        if indexed:
            kept.append((i, j))
        else:
            rejected.append((i, j))
    return kept, rejected


# --------------------------------------------------------------------------
# Scenario builders
# --------------------------------------------------------------------------

def rect_boundary(ncx: int, ncy: int) -> int:
    """Boundary edges of a rectangular cell region."""
    return 2 * ncx + 2 * ncy


def l_boundary(w: int, h: int, v_w: int, v_h: int) -> int:
    """Boundary edges of an L shape made of a full-width bottom bar (w x h)
    plus a tall bar on the left (v_w x v_h): 2w + 2h + 2*v_h."""
    return 2 * w + 2 * h + 2 * v_h


def build_cases(model: Model) -> None:
    # ------------------------------------------------------------------
    # A01 正常：矩形打胶带 (gap 2 mm, band fully inside the target plate)
    # ------------------------------------------------------------------
    model.component(101, "A01_PLATE_A", 3)
    model.component(102, "A01_PLATE_B", 6)
    model.component(103, "A01_LOCATION", 13)
    add_shell_grid(model, 101, (0.0, 0.0, 0.0), 32, 24)
    add_shell_grid(model, 102, (0.0, 0.0, GAP), 32, 24)
    band_cells = rect_cells(20, 12)  # x in [60,260], y in [60,180]
    add_shell_grid(model, 103, (60.0, 60.0, GAP / 2.0), 20, 12, band_cells)
    kept, rejected = simulate_cleaning(
        [(i, j, (60.0, 60.0, GAP / 2.0)) for (i, j) in band_cells],
        [cell_points((0.0, 0.0, GAP), i, j) for i in range(32) for j in range(24)],
        TOLERANCE,
    )
    assert len(kept) == 240 and len(rejected) == 0, (len(kept), len(rejected))
    model.cases.append(
        {
            "case_id": "A01",
            "title": "正常：矩形打胶带（间隙 2 mm，胶带完整落在目标板上）",
            "component_ids": [101, 102, 103],
            "component_names": ["A01_PLATE_A", "A01_PLATE_B", "A01_LOCATION"],
            "expected": "realize 成功：Area 连接器创建并实现为 adhesives（RBE3+HEXA8），全部 location 单元保留",
            "expected_results": {
                "kept_location_elems": len(kept),
                "rejected_location_elems": len(rejected),
                "expected_connector_count": 1,
                "expected_connector_state": "REALIZED",
            },
            "settings": {"tolerance": TOLERANCE, "coats": COATS, "thickness_type": "CONST_THICKNESS", "const_thickness": THICKNESS, "gap_mm": GAP, "band_mm": (60, 260, 60, 180)},
            "notes": "正向场景。location=组件 103 全部单元；links=101,102。投影距离=|gap/2|=1 mm，远小于 tolerance=50。",
        }
    )

    # ------------------------------------------------------------------
    # A02 正常：L 形打胶带 (L-shaped band on an L-shaped target plate)
    # ------------------------------------------------------------------
    model.component(201, "A02_PLATE_A", 3)
    model.component(202, "A02_PLATE_B_L", 6)
    model.component(203, "A02_LOCATION_L", 13)
    add_shell_grid(model, 201, (400.0, 0.0, 0.0), 30, 20)
    # B is L-shaped: full 300x200 minus top-right corner 160..300 x 100..200
    l_plate_cells = [(i, j) for j in range(20) for i in range(30) if not (i >= 16 and j >= 10)]
    add_shell_grid(model, 202, (400.0, 0.0, GAP), 30, 20, l_plate_cells)
    # L-shaped band: horizontal bar y 40..80 x 40..260 + vertical bar x 40..80 y 80..160
    l_band_cells = [(i, j) for j in range(0, 4) for i in range(0, 22)]
    l_band_cells += [(i, j) for j in range(4, 12) for i in range(0, 4)]
    add_shell_grid(model, 203, (440.0, 40.0, GAP / 2.0), 22, 12, l_band_cells)
    kept, rejected = simulate_cleaning(
        [(i, j, (440.0, 40.0, GAP / 2.0)) for (i, j) in l_band_cells],
        [cell_points((400.0, 0.0, GAP), i, j) for (i, j) in l_plate_cells],
        TOLERANCE,
    )
    assert len(kept) == 120 and len(rejected) == 0, (len(kept), len(rejected))
    model.cases.append(
        {
            "case_id": "A02",
            "title": "正常：L 形打胶带（胶带沿 L 形路径，目标板同为 L 形）",
            "component_ids": [201, 202, 203],
            "component_names": ["A02_PLATE_A", "A02_PLATE_B_L", "A02_LOCATION_L"],
            "expected": "realize 成功：L 形 location 单元全部保留，Area 连接器实现为 adhesives",
            "expected_results": {
                "kept_location_elems": len(kept),
                "rejected_location_elems": len(rejected),
                "expected_connector_count": 1,
                "expected_connector_state": "REALIZED",
            },
            "settings": {"tolerance": TOLERANCE, "coats": COATS, "thickness_type": "CONST_THICKNESS", "const_thickness": THICKNESS, "gap_mm": GAP},
            "notes": "L 形条带=横条 y[40,80]x[40,260]（88 单元）+ 竖条 x[40,80]y[80,160]（32 单元）。目标板 L 形缺口=右上角 140x100 被挖空；条带完整落在 L 形足印内。",
        }
    )

    # ------------------------------------------------------------------
    # A03 正常：多胶带（一个 location 组件连接 3 个 link 组件 A/B/C）
    # ------------------------------------------------------------------
    model.component(301, "A03_PLATE_A", 3)
    model.component(302, "A03_PLATE_B", 6)
    model.component(303, "A03_PLATE_C", 9)
    model.component(304, "A03_LOCATION", 13)
    add_shell_grid(model, 301, (800.0, 0.0, 0.0), 32, 24)
    add_shell_grid(model, 302, (800.0, 0.0, GAP), 32, 24)
    add_shell_grid(model, 303, (800.0, 0.0, 2 * GAP), 32, 24)
    band_cells = rect_cells(20, 12)
    add_shell_grid(model, 304, (860.0, 60.0, GAP / 2.0), 20, 12, band_cells)
    patch_elems = [(i, j, (860.0, 60.0, GAP / 2.0)) for (i, j) in band_cells]
    target_polys = [
        [cell_points((800.0, 0.0, 0.0), i, j) for i in range(32) for j in range(24)],
        [cell_points((800.0, 0.0, GAP), i, j) for i in range(32) for j in range(24)],
        [cell_points((800.0, 0.0, 2 * GAP), i, j) for i in range(32) for j in range(24)],
    ]
    kept_all = rejected_all = 0
    for target in target_polys:
        kept, rejected = simulate_cleaning(patch_elems, target, TOLERANCE)
        kept_all, rejected_all = len(kept), len(rejected)
        assert len(kept) == 240 and len(rejected) == 0, (len(kept), len(rejected))
    model.cases.append(
        {
            "case_id": "A03",
            "title": "正常：多胶带（同一 location 组件连接 A/B/C 三个 link 组件）",
            "component_ids": [301, 302, 303, 304],
            "component_names": ["A03_PLATE_A", "A03_PLATE_B", "A03_PLATE_C", "A03_LOCATION"],
            "expected": "realize 成功：1 个 Area 连接器实现为 adhesives，link 数量=3，location 单元全部保留",
            "expected_results": {
                "kept_location_elems": kept_all,
                "rejected_location_elems": rejected_all,
                "link_component_count": 3,
                "expected_connector_count": 1,
                "expected_connector_state": "REALIZED",
            },
            "settings": {"tolerance": TOLERANCE, "coats": COATS, "thickness_type": "CONST_THICKNESS", "const_thickness": THICKNESS, "gap_mm": [GAP, 2 * GAP]},
            "notes": "B、C 均位于 A 上方并完全覆盖胶带足印；每个 location 单元必须同时投影进 A、B、C 三个组件（距离 1/1/3 mm）。links=[A,B,C]。",
        }
    )

    # ------------------------------------------------------------------
    # A04 正常：小间隙变体（间隙 0.5 mm 与 3 mm 各一对）
    # ------------------------------------------------------------------
    model.component(401, "A04_PLATE_A_GAP05", 3)
    model.component(402, "A04_PLATE_B_GAP05", 6)
    model.component(403, "A04_LOCATION_GAP05", 13)
    model.component(404, "A04_PLATE_A_GAP3", 3)
    model.component(405, "A04_PLATE_B_GAP3", 6)
    model.component(406, "A04_LOCATION_GAP3", 13)
    band_cells = rect_cells(16, 12)  # x in [80,240], y in [60,180]
    add_shell_grid(model, 401, (1200.0, 0.0, 0.0), 32, 24)
    add_shell_grid(model, 402, (1200.0, 0.0, 0.5), 32, 24)
    add_shell_grid(model, 403, (1280.0, 60.0, 0.25), 16, 12, band_cells)
    kept1, rejected1 = simulate_cleaning(
        [(i, j, (1280.0, 60.0, 0.25)) for (i, j) in band_cells],
        [cell_points((1200.0, 0.0, 0.5), i, j) for i in range(32) for j in range(24)],
        TOLERANCE,
    )
    assert len(kept1) == 192 and len(rejected1) == 0, (len(kept1), len(rejected1))
    add_shell_grid(model, 404, (1580.0, 0.0, 0.0), 32, 24)
    add_shell_grid(model, 405, (1580.0, 0.0, 3.0), 32, 24)
    add_shell_grid(model, 406, (1660.0, 60.0, 1.5), 16, 12, band_cells)
    kept2, rejected2 = simulate_cleaning(
        [(i, j, (1660.0, 60.0, 1.5)) for (i, j) in band_cells],
        [cell_points((1580.0, 0.0, 3.0), i, j) for i in range(32) for j in range(24)],
        TOLERANCE,
    )
    assert len(kept2) == 192 and len(rejected2) == 0, (len(kept2), len(rejected2))
    model.cases.append(
        {
            "case_id": "A04",
            "title": "正常：小间隙变体（间隙 0.5 mm 与 3 mm 各一对）",
            "component_ids": [401, 402, 403, 404, 405, 406],
            "component_names": ["A04_PLATE_A_GAP05", "A04_PLATE_B_GAP05", "A04_LOCATION_GAP05", "A04_PLATE_A_GAP3", "A04_PLATE_B_GAP3", "A04_LOCATION_GAP3"],
            "expected": "两对均 realize 成功：投影距离 0.25/0.75/1.5 mm 均远小于 tolerance=50",
            "expected_results": {
                "pair_gap_0_5": {"kept_location_elems": len(kept1), "rejected_location_elems": len(rejected1)},
                "pair_gap_3_0": {"kept_location_elems": len(kept2), "rejected_location_elems": len(rejected2)},
                "expected_connector_count": 2,
                "expected_connector_state": "REALIZED",
            },
            "settings": {"tolerance": TOLERANCE, "coats": COATS, "thickness_type": "CONST_THICKNESS", "const_thickness": THICKNESS, "gap_mm": [0.5, 3.0]},
            "notes": "每对独立运行一次模块。间隙小于一个单元尺度时仍满足 tolerance 校验。",
        }
    )

    # ------------------------------------------------------------------
    # A05 失败：胶区越界（部分条带单元悬出目标板右边界）
    # ------------------------------------------------------------------
    model.component(501, "A05_PLATE_A", 3)
    model.component(502, "A05_PLATE_B_NARROW", 6)
    model.component(503, "A05_LOCATION_OVERHANG", 13)
    add_shell_grid(model, 501, (2000.0, 0.0, 0.0), 32, 24)
    add_shell_grid(model, 502, (2040.0, 20.0, GAP), 16, 20)
    overhang_cells = rect_cells(24, 16)  # x in [2040,2280], y in [40,200]
    add_shell_grid(model, 503, (2040.0, 40.0, GAP / 2.0), 24, 16, overhang_cells)
    kept, rejected = simulate_cleaning(
        [(i, j, (2040.0, 40.0, GAP / 2.0)) for (i, j) in overhang_cells],
        [cell_points((2040.0, 20.0, GAP), i, j) for i in range(16) for j in range(20)],
        TOLERANCE,
    )
    # Band x in [2040, 2280]; B covers x in [2040, 2200] -> 8 columns overhang.
    assert len(kept) == 256 and len(rejected) == 128, (len(kept), len(rejected))
    model.cases.append(
        {
            "case_id": "A05",
            "title": "失败：胶区越界（条带 80 mm 悬出目标板右边界，投影剔除越界单元）",
            "component_ids": [501, 502, 503],
            "component_names": ["A05_PLATE_A", "A05_PLATE_B_NARROW", "A05_LOCATION_OVERHANG"],
            "expected": "realize 继续成功但仅保留 256 个在足印内的 location 单元；128 个越界单元被投影剔除，模块消息提示 kept/rejected 数量",
            "expected_results": {
                "kept_location_elems": len(kept),
                "rejected_location_elems": len(rejected),
                "expected_connector_count": 1,
                "expected_connector_state": "REALIZED",
            },
            "settings": {"tolerance": TOLERANCE, "coats": COATS, "thickness_type": "CONST_THICKNESS", "const_thickness": THICKNESS, "gap_mm": GAP, "overhang_mm": 80.0},
            "notes": "越界量=80 mm=8 列 x16 行=128 单元。目标板 B 仅覆盖 x[2040,2200]；x>2200 的条带单元样本投影落在 B 足印外被剔除。单元被剔除而非报错，连接器仍可创建。",
        }
    )

    # ------------------------------------------------------------------
    # A06 失败：间隙过大（gap 150 mm >> tolerance 50 -> 全部剔除）
    # ------------------------------------------------------------------
    model.component(601, "A06_PLATE_A", 3)
    model.component(602, "A06_PLATE_B_FAR", 6)
    model.component(603, "A06_LOCATION_FAR", 13)
    add_shell_grid(model, 601, (2400.0, 0.0, 0.0), 32, 24)
    add_shell_grid(model, 602, (2400.0, 0.0, 150.0), 32, 24)
    band_cells = rect_cells(20, 12)
    add_shell_grid(model, 603, (2460.0, 60.0, 75.0), 20, 12, band_cells)
    kept, rejected = simulate_cleaning(
        [(i, j, (2460.0, 60.0, 75.0)) for (i, j) in band_cells],
        [cell_points((2400.0, 0.0, 150.0), i, j) for i in range(32) for j in range(24)],
        TOLERANCE,
    )
    assert len(kept) == 0 and len(rejected) == 240, (len(kept), len(rejected))
    model.cases.append(
        {
            "case_id": "A06",
            "title": "失败：间隙过大（间隙 150 mm，投影距离超出 tolerance=50，全部剔除）",
            "component_ids": [601, 602, 603],
            "component_names": ["A06_PLATE_A", "A06_PLATE_B_FAR", "A06_LOCATION_FAR"],
            "expected": "清洗后 0 个 location 单元 -> 模块弹窗 'No elements remain after cleaning'，不创建连接器",
            "expected_results": {
                "kept_location_elems": len(kept),
                "rejected_location_elems": len(rejected),
                "expected_connector_count": 0,
                "expected_behavior": "warning 'No elements remain after cleaning'; 停止",
            },
            "settings": {"tolerance": TOLERANCE, "coats": COATS, "thickness_type": "CONST_THICKNESS", "const_thickness": THICKNESS, "gap_mm": 150.0},
            "notes": "注意：模块固定 tolerance=50，投影距离检查 abs(distance) > tolerance 才剔除。15 mm 间隙（<50）仍会成功，故本场景用 150 mm 才能触发距离剔除失败。",
        }
    )

    # ------------------------------------------------------------------
    # A07 边界：胶区贴边（条带边缘与目标板边缘完全平齐）
    # ------------------------------------------------------------------
    model.component(701, "A07_PLATE_A", 3)
    model.component(702, "A07_PLATE_B", 6)
    model.component(703, "A07_LOCATION_FLUSH", 13)
    add_shell_grid(model, 701, (2800.0, 0.0, 0.0), 32, 24)
    add_shell_grid(model, 702, (2800.0, 0.0, GAP), 32, 24)
    flush_cells = rect_cells(32, 16)  # full width x in [2800,3120], y in [40,200]
    add_shell_grid(model, 703, (2800.0, 40.0, GAP / 2.0), 32, 16, flush_cells)
    kept, rejected = simulate_cleaning(
        [(i, j, (2800.0, 40.0, GAP / 2.0)) for (i, j) in flush_cells],
        [cell_points((2800.0, 0.0, GAP), i, j) for i in range(32) for j in range(24)],
        TOLERANCE,
    )
    assert len(kept) == 512 and len(rejected) == 0, (len(kept), len(rejected))
    model.cases.append(
        {
            "case_id": "A07",
            "title": "边界：胶区贴边（条带左右边缘与目标板左右边缘平齐，观察边界单元处理）",
            "component_ids": [701, 702, 703],
            "component_names": ["A07_PLATE_A", "A07_PLATE_B", "A07_LOCATION_FLUSH"],
            "expected": "边界样本恰在目标板边界上，pointInTriangle 的 1e-7 容差接受边界点 -> 512 个单元全部保留，realize 成功",
            "expected_results": {
                "kept_location_elems": len(kept),
                "rejected_location_elems": len(rejected),
                "expected_connector_count": 1,
                "expected_connector_state": "REALIZED",
            },
            "settings": {"tolerance": TOLERANCE, "coats": COATS, "thickness_type": "CONST_THICKNESS", "const_thickness": THICKNESS, "gap_mm": GAP},
            "notes": "条带 x[2800,3120] 与 B 的 x 范围完全重合；最外侧两列的角点/边中点恰在 B 的边界线上，被点内测试的 epsilon 容差接受。",
        }
    )

    # ------------------------------------------------------------------
    # A08 失败：空 location 组件（只选 link 不选 location）
    # ------------------------------------------------------------------
    model.component(801, "A08_PLATE_A", 3)
    model.component(802, "A08_PLATE_B", 6)
    model.component(803, "A08_LOCATION_EMPTY", 13)
    add_shell_grid(model, 801, (3200.0, 0.0, 0.0), 32, 24)
    add_shell_grid(model, 802, (3200.0, 0.0, GAP), 32, 24)
    # component 803 intentionally empty
    model.cases.append(
        {
            "case_id": "A08",
            "title": "失败：空 location 组件（只选 link 组件，不选 location 单元）",
            "component_ids": [801, 802, 803],
            "component_names": ["A08_PLATE_A", "A08_PLATE_B", "A08_LOCATION_EMPTY"],
            "expected": "pickInputs 阶段提示 '请选择 location 单元和至少两个目标组件'，不进入清洗/创建，模型不修改",
            "expected_results": {
                "kept_location_elems": 0,
                "rejected_location_elems": 0,
                "expected_connector_count": 0,
                "expected_behavior": "picker 拒绝：无 location 单元；或选中空组件后无单元可选",
            },
            "settings": {"tolerance": TOLERANCE, "coats": COATS, "thickness_type": "CONST_THICKNESS", "const_thickness": THICKNESS, "gap_mm": GAP},
            "notes": "组件 803 无单元。操作：仅将 801/802 作为 links 选择（跳过 location elems），模块应拒绝并提示。",
        }
    )


# --------------------------------------------------------------------------
# Validation / self checks
# --------------------------------------------------------------------------

def edge_usage(model: Model) -> Tuple[int, Dict[int, int]]:
    """Return (total boundary edges, per-component boundary edge count)."""
    usage: Dict[Tuple[int, int], int] = {}
    comp_edges: Dict[int, Dict[Tuple[int, int], int]] = {}
    for element in model.elements.values():
        nodes = element.node_ids
        for index in range(len(nodes)):
            a, b = nodes[index], nodes[(index + 1) % len(nodes)]
            key = (min(a, b), max(a, b))
            usage[key] = usage.get(key, 0) + 1
            comp_usage = comp_edges.setdefault(element.property_id, {})
            comp_usage[key] = comp_usage.get(key, 0) + 1
    boundary = sum(1 for count in usage.values() if count == 1)
    per_comp = {
        comp_id: sum(1 for count in comp_usage.values() if count == 1)
        for comp_id, comp_usage in comp_edges.items()
    }
    return boundary, per_comp


def validate(model: Model) -> Dict[str, int]:
    errors = []

    # Node ids must be a dense 1..N sequence
    if set(model.nodes) != set(range(1, len(model.nodes) + 1)):
        errors.append("node ids are not a dense 1..N sequence")

    for element in model.elements.values():
        if element.card != "CQUAD4" or len(element.node_ids) != 4:
            errors.append("malformed element {}".format(element.element_id))
        if any(node not in model.nodes for node in element.node_ids):
            errors.append("element {} references missing node".format(element.element_id))
        pts = [model.nodes[n] for n in element.node_ids]
        if norm(cross(vsub(pts[1], pts[0]), vsub(pts[3], pts[0]))) <= 0.0:
            errors.append("degenerate quad {}".format(element.element_id))

    if len({tuple(e.node_ids) for e in model.elements.values()}) != len(model.elements):
        errors.append("duplicate element connectivity found")

    if len(model.cases) != 8:
        errors.append("expected exactly 8 cases, got {}".format(len(model.cases)))

    _, per_comp = edge_usage(model)
    expected_boundary = {
        101: rect_boundary(32, 24), 102: rect_boundary(32, 24), 103: rect_boundary(20, 12),
        201: rect_boundary(30, 20), 202: l_boundary(30, 10, 16, 10), 203: l_boundary(22, 4, 4, 8),
        301: rect_boundary(32, 24), 302: rect_boundary(32, 24), 303: rect_boundary(32, 24), 304: rect_boundary(20, 12),
        401: rect_boundary(32, 24), 402: rect_boundary(32, 24), 403: rect_boundary(16, 12),
        404: rect_boundary(32, 24), 405: rect_boundary(32, 24), 406: rect_boundary(16, 12),
        501: rect_boundary(32, 24), 502: rect_boundary(16, 20), 503: rect_boundary(24, 16),
        601: rect_boundary(32, 24), 602: rect_boundary(32, 24), 603: rect_boundary(20, 12),
        701: rect_boundary(32, 24), 702: rect_boundary(32, 24), 703: rect_boundary(32, 16),
        801: rect_boundary(32, 24), 802: rect_boundary(32, 24),
    }
    for comp_id, expected in expected_boundary.items():
        actual = per_comp.get(comp_id)
        if actual != expected:
            errors.append("component {} boundary edges {} != expected {}".format(comp_id, actual, expected))
    if model.components[803].element_ids:
        errors.append("A08_LOCATION_EMPTY must have no elements")

    # Numeric sanity: plate plane z positions
    def plane_z(comp_ids):
        return {model.nodes[n][2] for cid in comp_ids for eid in model.components[cid].element_ids for n in model.elements[eid].node_ids}

    if plane_z([101, 102]) != {0.0, GAP}:
        errors.append("A01 plate z positions wrong")
    if plane_z([601, 602]) != {0.0, 150.0}:
        errors.append("A06 gap not 150")
    if plane_z([701, 702]) != {0.0, GAP}:
        errors.append("A07 plate z positions wrong")

    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors))
    quads = sum(1 for e in model.elements.values() if e.card == "CQUAD4")
    return {
        "nodes": len(model.nodes),
        "elements": len(model.elements),
        "quads": quads,
        "components": len(model.components),
        "cases": len(model.cases),
    }


# --------------------------------------------------------------------------
# FEM writer
# --------------------------------------------------------------------------

def write_fem(model: Model, output: Path) -> None:
    lines = [
        "$ Adhesive Connector combined validation deck",
        "$ Parallel shell plates with separate glue PATCH location components",
        "$ Generated by examples/AdhesiveConnector_Validation/generate_fem.py",
        "$ Units: mm, N, MPa. Test geometry only - not a production solve model.",
        "BEGIN BULK",
        '$HMNAME MAT 1 "ADH_STEEL"',
        "MAT1,1,210000.0,,0.3,7.85E-9",
        "$ PROPERTIES",
    ]
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        prop = component.component_id
        lines.append('$HMNAME PROP {} "{}"'.format(prop, component.name + "_PSHELL"))
        lines.append("PSHELL,{},1,1.0".format(prop))
    lines.append("$ COMPONENT NAMES")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend((
            '$HMNAME COMP {} "{}"'.format(component.component_id, component.name),
            "$HWCOLOR COMP {} {}".format(component.component_id, component.color),
        ))
    lines.append("$ NODES")
    for node_id, point in sorted(model.nodes.items()):
        lines.append("GRID,{},,{:.9g},{:.9g},{:.9g}".format(node_id, *point))
    lines.append("$ ELEMENTS GROUPED BY HYPERMESH COMPONENT")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.append("$HMCOMP ID {}".format(component.component_id))
        lines.append("$ " + component.name)
        for element_id in component.element_ids:
            element = model.elements[element_id]
            lines.append("CQUAD4,{},{},{}".format(element.element_id, element.property_id, ",".join(str(n) for n in element.node_ids)))
    lines.extend(("ENDDATA", ""))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def validate_written_fem(output: Path, stats: Dict[str, int]) -> None:
    lines = output.read_text(encoding="utf-8").splitlines()
    if "BEGIN BULK" not in lines or not lines or lines[-1] != "ENDDATA":
        raise ValueError("FEM is missing BEGIN BULK or terminal ENDDATA")
    actual_quads = sum(1 for line in lines if line.startswith("CQUAD4,"))
    if actual_quads != stats["quads"]:
        raise ValueError("written CQUAD4 count {} != {}".format(actual_quads, stats["quads"]))
    actual_grid = sum(1 for line in lines if line.startswith("GRID,"))
    if actual_grid != stats["nodes"]:
        raise ValueError("written GRID count {} != {}".format(actual_grid, stats["nodes"]))
    oversized = [(i, line) for i, line in enumerate(lines, 1) if line and not line.startswith("$") and len(line.split(",")) > 9]
    if oversized:
        raise ValueError("free-format card exceeds nine fields at line {}".format(oversized[0][0]))


def manifest(model: Model, stats: Dict[str, int]) -> Dict[str, object]:
    components = []
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        components.append({
            "component_id": component.component_id,
            "name": component.name,
            "element_count": len(component.element_ids),
        })
    return {
        "schema_version": "1.0",
        "purpose": "Adhesive Connector（打胶）模块验证：area/adhesives 连接的 location 单元投影清洗、realize 成功与失败行为",
        "generator": "examples/AdhesiveConnector_Validation/generate_fem.py",
        "fem": "AdhesiveConnector_Combined_Validation.fem",
        "parameters": {
            "mesh_size_mm": CELL,
            "case_pitch_mm": 300,
            "tolerance": TOLERANCE,
            "coats": COATS,
            "thickness_type": "CONST_THICKNESS",
            "const_thickness": THICKNESS,
            "units": "mm,N,Mpa",
            "module_version": "1.2",
        },
        "statistics": stats,
        "components": components,
        "cases": model.cases,
        "warning": "几何验证模型，仅供识别/流程验证，非生产求解模型；连接器 realize 需在 HyperMesh 2019 OptiStruct profile 中实机验证。",
    }


def parse_args() -> argparse.Namespace:
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=directory / "AdhesiveConnector_Combined_Validation.fem")
    parser.add_argument("--manifest", type=Path, default=directory / "AdhesiveConnector_Combined_Validation_manifest.json")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    model = Model()
    build_cases(model)
    stats = validate(model)
    write_fem(model, args.output.resolve())
    validate_written_fem(args.output.resolve(), stats)
    args.manifest.resolve().write_text(json.dumps(manifest(model, stats), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"fem": str(args.output.resolve()), "manifest": str(args.manifest.resolve()), **stats}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
