#!/usr/bin/env python3
"""Generate one shell-mesh OptiStruct FEM for Contact Setup validation.

All scenarios are placed in one deck and separated along global X (pitch
>= 300 mm).  Each scenario is one or more pairs of parallel/offset/tilted
shell plates.  The module under test (`modules/contact_setup.tcl`) works as
follows (confirmed against the source and its unit tests):

  * the user picks two face regions (side A, side B) with the native face
    selector; the two selections must not share an element
    (validateSelectedFaces rejects shared elements);
  * `selectNearestContactFaces` keeps an element only if another element on
    the opposite side has its centroid within
        searchTol = max(bboxGap + 2.5 * medianElemSpan, 2.5 * medianElemSpan)
    where bboxGap is the 3-D bounding-box gap between the two selections
    (bidirectional nearest-neighbour filter).  If either side ends up empty the
    module errors "No common contact region was found between the two
    selections.";
  * two SURF contact surfaces are created (`*contactsurfcreatewithshells`) with
    reverse_normals flags that point both surfaces toward each other, then one
    OptiStruct CONTACT group references them (SLIDE/STICK/FREEZE).

Important verified behaviours that the scenario matrix encodes:

  * the filter is purely centroid-distance based: it never checks face normals,
    so back-to-back plates (normals pointing away) still produce a contact
    (B05 documents this);
  * the search tolerance auto-scales with the bbox gap, so two parallel plates
    100 mm apart still produce a contact (B06 documents this - a fixed
    "no-contact beyond N mm" threshold does not exist);
  * the only hard rejections are shared elements (B07) and (unreachable for two
    non-empty plate sets) an empty common region.

This script re-implements the nearest-neighbour filter in pure Python and
records the predicted kept element counts, search tolerance, main side
(AUTO: the larger kept side becomes the main surface) and CONTACT type for
every case before any HyperMesh run.

Run from the repository root:

    runtime\\python\\windows-x64\\python.exe examples\\ContactSetup_Validation\\generate_fem.py

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

CELL = 10.0  # mm mesh size
GAP = 5.0  # default contact gap in mm
CONTACT_TYPE = "STICK"  # default per config/contact_rules.txt
MAIN_SIDE = "AUTO"
RESULT_PREFIX = "AUTO_CONTACT"
TYPE_VALUE = {"SLIDE": 0, "STICK": 1, "FREEZE": 2}


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

def add_shell_grid(
    model: Model,
    component_id: int,
    origin: Point,
    ncx: int,
    ncy: int,
    reverse: bool = False,
) -> Dict[Tuple[int, int], int]:
    """Regular CQUAD4 grid in the z=const plane at `origin`.  `reverse` flips
    the winding so the face normal points -Z."""
    grid: Dict[Tuple[int, int], int] = {}
    for j in range(ncy + 1):
        for i in range(ncx + 1):
            grid[(i, j)] = model.node((origin[0] + i * CELL, origin[1] + j * CELL, origin[2]))
    for j in range(ncy):
        for i in range(ncx):
            if reverse:
                nodes = (grid[(i, j)], grid[(i, j + 1)], grid[(i + 1, j + 1)], grid[(i + 1, j)])
            else:
                nodes = (grid[(i, j)], grid[(i + 1, j)], grid[(i + 1, j + 1)], grid[(i, j + 1)])
            model.element(component_id, "CQUAD4", nodes)
    return grid


def add_tilted_grid(
    model: Model,
    component_id: int,
    center: Point,
    ncx: int,
    ncy: int,
    theta_deg: float,
) -> Dict[Tuple[int, int], int]:
    """A 400-style plate centred at `center`, rotated by `theta_deg` about the
    Y axis through the centre (left edge dips below the plane, right edge
    rises).  Node ordering stays a regular grid so each face normal is the
    rotated +Z."""
    theta = math.radians(theta_deg)
    s, c = math.sin(theta), math.cos(theta)
    x0 = center[0] - (ncx * CELL) / 2.0
    y0 = center[1] - (ncy * CELL) / 2.0
    grid: Dict[Tuple[int, int], int] = {}
    for j in range(ncy + 1):
        for i in range(ncx + 1):
            lx = x0 + i * CELL
            world = (center[0] + (lx - center[0]) * c, y0 + j * CELL, center[2] + (lx - center[0]) * s)
            grid[(i, j)] = model.node(world)
    for j in range(ncy):
        for i in range(ncx):
            nodes = (grid[(i, j)], grid[(i + 1, j)], grid[(i + 1, j + 1)], grid[(i, j + 1)])
            model.element(component_id, "CQUAD4", nodes)
    return grid


# --------------------------------------------------------------------------
# Exact re-implementation of ::ContactSetup::selectNearestContactFaces
# --------------------------------------------------------------------------

def vsub(a: Point, b: Point) -> Point:
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def vnorm(a: Point) -> float:
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def vcross(a: Point, b: Point) -> Point:
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def vnormalize(a: Point) -> Point:
    n = vnorm(a)
    if n <= 1.0e-12:
        return (0.0, 0.0, 0.0)
    return (a[0] / n, a[1] / n, a[2] / n)


def vdot(a: Point, b: Point) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def face_normal(pts: List[Point]) -> Point:
    p0 = pts[0]
    for index in range(1, len(pts) - 1):
        cr = vcross(vsub(pts[index], p0), vsub(pts[index + 1], p0))
        if vnorm(cr) > 1.0e-12:
            return vnormalize(cr)
    return (0.0, 0.0, 0.0)


def uniq(values: Sequence[int]) -> List[int]:
    seen = set()
    out = []
    for value in values:
        if value not in seen:
            seen.add(value)
            out.append(value)
    return out


def elem_geometry(nodes: Sequence[int], xyz: Dict[int, Point]) -> Tuple[Point, float, Point, List[Point]]:
    """Return (center, span, normal, node_points) mirroring faceGeometryData."""
    nodes = uniq(nodes)
    pts = [xyz[n] for n in nodes]
    count = len(pts)
    center = tuple(sum(p[axis] for p in pts) / count for axis in range(3))
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    zs = [p[2] for p in pts]
    span = math.sqrt((max(xs) - min(xs)) ** 2 + (max(ys) - min(ys)) ** 2 + (max(zs) - min(zs)) ** 2)
    normal = face_normal(pts)
    return center, span, normal, pts


def median(values: List[float]) -> float:
    vals = sorted(v for v in values if v > 0.0)
    if not vals:
        return 0.0
    mid = len(vals) // 2
    if len(vals) % 2 == 1:
        return vals[mid]
    return (vals[mid - 1] + vals[mid]) / 2.0


def bbox_gap(bbox_a, bbox_b) -> float:
    """Mirror ::ContactSetup::bboxGap over (min, max) node bounding boxes."""
    total = 0.0
    for axis in range(3):
        gap = 0.0
        if bbox_a["max"][axis] < bbox_b["min"][axis]:
            gap = bbox_b["min"][axis] - bbox_a["max"][axis]
        elif bbox_b["max"][axis] < bbox_a["min"][axis]:
            gap = bbox_a["min"][axis] - bbox_b["max"][axis]
        total += gap * gap
    return math.sqrt(total)


def side_bbox(elems, xyz):
    mins = [float("inf")] * 3
    maxs = [float("-inf")] * 3
    for nodes in elems:
        for n in uniq(nodes):
            p = xyz[n]
            for axis in range(3):
                mins[axis] = min(mins[axis], p[axis])
                maxs[axis] = max(maxs[axis], p[axis])
    return {"min": tuple(mins), "max": tuple(maxs)}


def grid_key(p: Point, cell: float) -> Tuple[int, int, int]:
    return (
        int(math.floor(p[0] / cell)),
        int(math.floor(p[1] / cell)),
        int(math.floor(p[2] / cell)),
    )


def distance2(a: Point, b: Point) -> float:
    dx = a[0] - b[0]
    dy = a[1] - b[1]
    dz = a[2] - b[2]
    return dx * dx + dy * dy + dz * dz


def simulate_contact(
    elems_a: List[Tuple[int, Sequence[int]]],
    elems_b: List[Tuple[int, Sequence[int]]],
    xyz: Dict[int, Point],
) -> Dict[str, object]:
    """Mirror ::ContactSetup::selectNearestContactFaces.  Returns dict with
    kept element ids, search tolerance and bbox gap."""
    recs_a = []
    recs_b = []
    spans_a = []
    spans_b = []
    for eid, nodes in elems_a:
        center, span, normal, _ = elem_geometry(nodes, xyz)
        recs_a.append({"elem": eid, "center": center, "normal": normal, "span": span})
        spans_a.append(span)
    for eid, nodes in elems_b:
        center, span, normal, _ = elem_geometry(nodes, xyz)
        recs_b.append({"elem": eid, "center": center, "normal": normal, "span": span})
        spans_b.append(span)

    bbox_a = side_bbox([nodes for _, nodes in elems_a], xyz)
    bbox_b = side_bbox([nodes for _, nodes in elems_b], xyz)

    elem_scale = max(median(spans_a), median(spans_b), 1.0e-6)
    gap = bbox_gap(bbox_a, bbox_b)
    search_tol = max(gap + 2.5 * elem_scale, 2.5 * elem_scale)
    max_d2 = search_tol * search_tol
    cell = search_tol

    grid_b: Dict[Tuple[int, int, int], List[int]] = {}
    for idx, rec in enumerate(recs_b):
        grid_b.setdefault(grid_key(rec["center"], cell), []).append(idx)
    grid_a: Dict[Tuple[int, int, int], List[int]] = {}
    for idx, rec in enumerate(recs_a):
        grid_a.setdefault(grid_key(rec["center"], cell), []).append(idx)

    def has_nearby(query_center, grid, records):
        kx, ky, kz = grid_key(query_center, cell)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for idx in grid.get((kx + dx, ky + dy, kz + dz), ()):
                        if distance2(query_center, records[idx]["center"]) <= max_d2:
                            return True
        return False

    keep_a = []
    keep_b = []
    for rec in recs_a:
        if has_nearby(rec["center"], grid_b, recs_b):
            keep_a.append(rec["elem"])
    for rec in recs_b:
        if has_nearby(rec["center"], grid_a, recs_a):
            keep_b.append(rec["elem"])

    return {
        "kept_a": sorted(keep_a),
        "kept_b": sorted(keep_b),
        "search_tolerance_mm": search_tol,
        "bbox_gap_mm": gap,
        "selected_a": len(recs_a),
        "selected_b": len(recs_b),
    }


# --------------------------------------------------------------------------
# Scenario builders
# --------------------------------------------------------------------------

def build_cases(model: Model) -> None:
    xyz = model.nodes  # filled during grid creation

    # ------------------------------------------------------------------
    # B01 正常：大面积平行对 (500x300, gap 5 mm, fully aligned)
    # ------------------------------------------------------------------
    model.component(101, "B01_PLATE_A", 3)
    model.component(102, "B01_PLATE_B", 6)
    add_shell_grid(model, 101, (0.0, 0.0, 0.0), 50, 30)
    add_shell_grid(model, 102, (0.0, 0.0, GAP), 50, 30, reverse=True)  # normal -Z, toward A
    nrm_a = face_normal([model.nodes[n] for n in model.elements[model.components[101].element_ids[0]].node_ids])
    nrm_b = face_normal([model.nodes[n] for n in model.elements[model.components[102].element_ids[0]].node_ids])
    assert nrm_a[2] > 0.99 and nrm_b[2] < -0.99, (nrm_a, nrm_b)
    sim = simulate_contact(
        [(eid, model.elements[eid].node_ids) for eid in model.components[101].element_ids],
        [(eid, model.elements[eid].node_ids) for eid in model.components[102].element_ids],
        xyz,
    )
    assert len(sim["kept_a"]) == 1500 and len(sim["kept_b"]) == 1500
    assert sim["bbox_gap_mm"] == GAP
    model.cases.append(
        {
            "case_id": "B01",
            "title": "正常：大面积平行对（500x300 完全对位，间距 5 mm）",
            "component_ids": [101, 102],
            "component_names": ["B01_PLATE_A", "B01_PLATE_B"],
            "expected": "双向邻近覆盖完整：两板全部 1500 单元进入公共区域，创建 1 个 STICK CONTACT group",
            "expected_results": {
                "selected_A": sim["selected_a"], "kept_A": len(sim["kept_a"]),
                "selected_B": sim["selected_b"], "kept_B": len(sim["kept_b"]),
                "bbox_gap_mm": round(sim["bbox_gap_mm"], 3),
                "search_tolerance_mm": round(sim["search_tolerance_mm"], 3),
                "expected_group_count": 1, "expected_type": "STICK",
                "main_side": "FIRST" if len(sim["kept_b"]) <= len(sim["kept_a"]) else "SECOND",
                "group_name": "AUTO_CONTACT_STICK_B01_PLATE_A_TO_B01_PLATE_B_GROUP",
            },
            "settings": {"contact_type": "STICK", "main_side": "AUTO", "result_prefix": "AUTO_CONTACT", "try_group": 1, "gap_mm": GAP},
            "notes": "法向相向（A 朝 +Z，B 朝 -Z）。searchTol = gap + 2.5*medianSpan = 5 + 35.36 mm。",
        }
    )

    # ------------------------------------------------------------------
    # B02 正常：部分重叠对 (40% in-plane overlap)
    # ------------------------------------------------------------------
    model.component(201, "B02_PLATE_A", 3)
    model.component(202, "B02_PLATE_B_OFFSET", 6)
    add_shell_grid(model, 201, (600.0, 0.0, 0.0), 50, 30)
    add_shell_grid(model, 202, (900.0, 0.0, GAP), 50, 30, reverse=True)  # x in [900,1400]
    sim = simulate_contact(
        [(eid, model.elements[eid].node_ids) for eid in model.components[201].element_ids],
        [(eid, model.elements[eid].node_ids) for eid in model.components[202].element_ids],
        xyz,
    )
    assert len(sim["kept_a"]) > 0 and len(sim["kept_b"]) > 0
    overlap_frac = 200.0 / 500.0
    model.cases.append(
        {
            "case_id": "B02",
            "title": "正常：部分重叠对（两板面内重叠 40%，公共覆盖区正确）",
            "component_ids": [201, 202],
            "component_names": ["B02_PLATE_A", "B02_PLATE_B_OFFSET"],
            "expected": "公共区域 = 面内重叠区 + 每侧约 2.5*medianSpan 的邻近余量；创建 1 个 STICK CONTACT group",
            "expected_results": {
                "selected_A": sim["selected_a"], "kept_A": len(sim["kept_a"]),
                "selected_B": sim["selected_b"], "kept_B": len(sim["kept_b"]),
                "inplane_overlap_fraction": overlap_frac,
                "bbox_gap_mm": round(sim["bbox_gap_mm"], 3),
                "search_tolerance_mm": round(sim["search_tolerance_mm"], 3),
                "expected_group_count": 1, "expected_type": "STICK",
                "main_side": "FIRST" if len(sim["kept_b"]) <= len(sim["kept_a"]) else "SECOND",
                "group_name": "AUTO_CONTACT_STICK_B02_PLATE_A_TO_B02_PLATE_B_OFFSET_GROUP",
            },
            "settings": {"contact_type": "STICK", "main_side": "AUTO", "result_prefix": "AUTO_CONTACT", "try_group": 1, "gap_mm": GAP},
            "notes": "A x[600,1100]，B x[900,1400]，重叠 [900,1100]=200 mm（40%）。kept 边界由 searchTol 决定，manifest 记录精确预测值。",
        }
    )

    # ------------------------------------------------------------------
    # B03 正常：STICK / SLIDE / FREEZE 三类型（三个隔离场景各一）
    # ------------------------------------------------------------------
    comps_03 = []
    for index, (x, ctype, color) in enumerate(
        ((1500, "STICK", 3), (1900, "SLIDE", 4), (2300, "FREEZE", 5)), start=0
    ):
        cid_a = 301 + index * 2
        cid_b = 302 + index * 2
        model.component(cid_a, "B03_PAIR{}_A_{}".format(index + 1, ctype), color)
        model.component(cid_b, "B03_PAIR{}_B_{}".format(index + 1, ctype), color + 3)
        add_shell_grid(model, cid_a, (x, 0.0, 0.0), 30, 20)
        add_shell_grid(model, cid_b, (x, 0.0, GAP), 30, 20, reverse=True)
        sim = simulate_contact(
            [(eid, model.elements[eid].node_ids) for eid in model.components[cid_a].element_ids],
            [(eid, model.elements[eid].node_ids) for eid in model.components[cid_b].element_ids],
            xyz,
        )
        assert len(sim["kept_a"]) == 600 and len(sim["kept_b"]) == 600
        comps_03.append((cid_a, cid_b, ctype))
    model.cases.append(
        {
            "case_id": "B03",
            "title": "正常：STICK / SLIDE / FREEZE 三类型（三个隔离场景各一类型）",
            "component_ids": [301, 302, 303, 304, 305, 306],
            "component_names": [
                "B03_PAIR1_A_STICK", "B03_PAIR1_B_STICK",
                "B03_PAIR2_A_SLIDE", "B03_PAIR2_B_SLIDE",
                "B03_PAIR3_A_FREEZE", "B03_PAIR3_B_FREEZE",
            ],
            "expected": "对每对分别运行模块并选择相应 contact_type：创建 3 个 CONTACT group（STICK/SLIDE/FREEZE），CONTACT_PROP_TYPE 分别写入对应值（1/0/2）",
            "expected_results": {
                "pairs": [
                    {"components": [301, 302], "kept_A": 600, "kept_B": 600, "expected_type": "STICK"},
                    {"components": [303, 304], "kept_A": 600, "kept_B": 600, "expected_type": "SLIDE"},
                    {"components": [305, 306], "kept_A": 600, "kept_B": 600, "expected_type": "FREEZE"},
                ],
                "expected_group_count": 3,
            },
            "settings": {"contact_type": "STICK/SLIDE/FREEZE（每对一次）", "main_side": "AUTO", "result_prefix": "AUTO_CONTACT", "try_group": 1, "gap_mm": GAP},
            "notes": "三对沿 X 隔离（pitch 400 mm > 2*searchTol），互相不串扰。也可三对 A/B 一次性全选 -> 1 个 group，但 type 只能取一个。",
        }
    )

    # ------------------------------------------------------------------
    # B04 正常：多对同时（一个模型内 4 对相向面）
    # ------------------------------------------------------------------
    comps_04 = []
    for index, x in enumerate((2800, 3200, 3600, 4000)):
        cid_a = 401 + index * 2
        cid_b = cid_a + 1
        model.component(cid_a, "B04_PAIR{}_A".format(index + 1), 3 + index)
        model.component(cid_b, "B04_PAIR{}_B".format(index + 1), 8 + index)
        add_shell_grid(model, cid_a, (x, 0.0, 0.0), 30, 20)
        add_shell_grid(model, cid_b, (x, 0.0, GAP), 30, 20, reverse=True)
        comps_04.append((cid_a, cid_b))
    all_a = [eid for cid_a, _ in comps_04 for eid in model.components[cid_a].element_ids]
    all_b = [eid for _, cid_b in comps_04 for eid in model.components[cid_b].element_ids]
    sim = simulate_contact(
        [(eid, model.elements[eid].node_ids) for eid in all_a],
        [(eid, model.elements[eid].node_ids) for eid in all_b],
        xyz,
    )
    assert len(sim["kept_a"]) == 2400 and len(sim["kept_b"]) == 2400
    model.cases.append(
        {
            "case_id": "B04",
            "title": "正常：多对同时（4 对相向面，一次性全选 A/B）",
            "component_ids": [401, 402, 403, 404, 405, 406, 407, 408],
            "component_names": [
                "B04_PAIR1_A", "B04_PAIR1_B", "B04_PAIR2_A", "B04_PAIR2_B",
                "B04_PAIR3_A", "B04_PAIR3_B", "B04_PAIR4_A", "B04_PAIR4_B",
            ],
            "expected": "一次运行选择全部 4 个 A 面 + 全部 4 个 B 面：公共区域覆盖全部 2400 单元，创建 1 个 CONTACT group（主/从 SURF 各含 4 块板）",
            "expected_results": {
                "selected_A": sim["selected_a"], "kept_A": len(sim["kept_a"]),
                "selected_B": sim["selected_b"], "kept_B": len(sim["kept_b"]),
                "bbox_gap_mm": round(sim["bbox_gap_mm"], 3),
                "search_tolerance_mm": round(sim["search_tolerance_mm"], 3),
                "expected_group_count": 1, "expected_type": "STICK",
                "main_side": "FIRST" if len(sim["kept_b"]) <= len(sim["kept_a"]) else "SECOND",
            },
            "settings": {"contact_type": "STICK", "main_side": "AUTO", "result_prefix": "AUTO_CONTACT", "try_group": 1, "gap_mm": GAP},
            "notes": "4 对 pitch 400 mm，跨对最近质心距离 >= 100 mm > searchTol=40.4 mm，不会跨对匹配。逐对运行 4 次则得到 4 个 group。",
        }
    )

    # ------------------------------------------------------------------
    # B05 观察：背向面（两块板法向同向，背面相对；两法向均朝 +Z）
    # ------------------------------------------------------------------
    model.component(501, "B05_PLATE_A_BACK", 3)
    model.component(502, "B05_PLATE_B_BACK", 6)
    add_shell_grid(model, 501, (4400.0, 0.0, 0.0), 30, 20)   # normal +Z
    add_shell_grid(model, 502, (4400.0, 0.0, GAP), 30, 20)   # normal +Z (same direction)
    sim = simulate_contact(
        [(eid, model.elements[eid].node_ids) for eid in model.components[501].element_ids],
        [(eid, model.elements[eid].node_ids) for eid in model.components[502].element_ids],
        xyz,
    )
    assert len(sim["kept_a"]) == 600 and len(sim["kept_b"]) == 600
    # Verify both face normals point the same way (+Z).
    nodes_a = model.elements[model.components[501].element_ids[0]].node_ids
    nodes_b = model.elements[model.components[502].element_ids[0]].node_ids
    nrm_a = face_normal([model.nodes[n] for n in nodes_a])
    nrm_b = face_normal([model.nodes[n] for n in nodes_b])
    assert nrm_a[2] > 0.99 and nrm_b[2] > 0.99, (nrm_a, nrm_b)
    model.cases.append(
        {
            "case_id": "B05",
            "title": "观察：背向面（两块板背面相对，法向均背离间隙）",
            "component_ids": [501, 502],
            "component_names": ["B05_PLATE_A_BACK", "B05_PLATE_B_BACK"],
            "expected": "模块仍会创建 CONTACT group：邻近筛选仅按质心距离，不校验法向；创建接触面时以 reverse_normals 将两侧表面翻向相向",
            "expected_results": {
                "selected_A": sim["selected_a"], "kept_A": len(sim["kept_a"]),
                "selected_B": sim["selected_b"], "kept_B": len(sim["kept_b"]),
                "bbox_gap_mm": round(sim["bbox_gap_mm"], 3),
                "search_tolerance_mm": round(sim["search_tolerance_mm"], 3),
                "expected_group_count": 1, "expected_type": "STICK",
                "normal_A": tuple(round(v, 3) for v in nrm_a),
                "normal_B": tuple(round(v, 3) for v in nrm_b),
                "expected_reverse_flags": {"A": 0, "B": 1},
            },
            "settings": {"contact_type": "STICK", "main_side": "AUTO", "result_prefix": "AUTO_CONTACT", "try_group": 1, "gap_mm": GAP},
            "notes": "验证模块对'法向不相向'的容错行为：referenceOrientations 按中心连线点积决定 reverse_normals，此处 A 法向 +Z（不翻转），B 法向 +Z 指向 A 需翻转（reverseB=1），接触面仍被导向相向而非拒绝。若需要拒绝背向输入，模块需增加法向相向预检。",
        }
    )

    # ------------------------------------------------------------------
    # B06 观察：超距（间距 100 mm；模块搜索容差随间距自适应）
    # ------------------------------------------------------------------
    model.component(601, "B06_PLATE_A", 3)
    model.component(602, "B06_PLATE_B_FAR", 6)
    add_shell_grid(model, 601, (4800.0, 0.0, 0.0), 30, 20)
    add_shell_grid(model, 602, (4800.0, 0.0, 100.0), 30, 20, reverse=True)
    sim = simulate_contact(
        [(eid, model.elements[eid].node_ids) for eid in model.components[601].element_ids],
        [(eid, model.elements[eid].node_ids) for eid in model.components[602].element_ids],
        xyz,
    )
    assert sim["bbox_gap_mm"] == 100.0
    assert len(sim["kept_a"]) == 600 and len(sim["kept_b"]) == 600
    model.cases.append(
        {
            "case_id": "B06",
            "title": "观察：超距（间距 100 mm；无固定截断距离，搜索容差随间距自适应）",
            "component_ids": [601, 602],
            "component_names": ["B06_PLATE_A", "B06_PLATE_B_FAR"],
            "expected": "模块仍创建 CONTACT group：searchTol = bboxGap + 2.5*medianSpan = 100 + 35.36 = 135.36 mm，100 mm 间距仍在范围内",
            "expected_results": {
                "selected_A": sim["selected_a"], "kept_A": len(sim["kept_a"]),
                "selected_B": sim["selected_b"], "kept_B": len(sim["kept_b"]),
                "bbox_gap_mm": round(sim["bbox_gap_mm"], 3),
                "search_tolerance_mm": round(sim["search_tolerance_mm"], 3),
                "expected_group_count": 1, "expected_type": "STICK",
            },
            "settings": {"contact_type": "STICK", "main_side": "AUTO", "result_prefix": "AUTO_CONTACT", "try_group": 1, "gap_mm": 100.0},
            "notes": "注意与场景设计假设的差异：模块的搜索容差 max(gap+2.5*medianSpan, 2.5*medianSpan) 随 bbox 间距自适应增长，因此'间距 100 mm -> 无邻近关系'并不成立；本场景如实记录该行为。若要制造'无公共区域'错误需 bbox 重叠但单元彼此远离（如多板嵌套选择），几何上很不自然。",
        }
    )

    # ------------------------------------------------------------------
    # B07 失败：两遍相同单元（A/B 选同一组件 -> 拒绝）
    # ------------------------------------------------------------------
    model.component(701, "B07_PLATE_A", 3)
    model.component(702, "B07_PLATE_B", 6)
    add_shell_grid(model, 701, (5200.0, 0.0, 0.0), 30, 20)
    add_shell_grid(model, 702, (5200.0, 0.0, GAP), 30, 20, reverse=True)
    model.cases.append(
        {
            "case_id": "B07",
            "title": "失败：两遍相同单元（A/B 选同一组件 -> 模块拒绝）",
            "component_ids": [701, 702],
            "component_names": ["B07_PLATE_A", "B07_PLATE_B"],
            "expected": "validateSelectedFaces 拒绝：'两次选择包含相同单元 <id>；请分别选择相向的两侧。'，不创建任何 SURF/group",
            "expected_results": {
                "expected_group_count": 0,
                "expected_behavior": "hard rejection at validateSelectedFaces（共享单元）",
            },
            "settings": {"contact_type": "STICK", "main_side": "AUTO", "result_prefix": "AUTO_CONTACT", "try_group": 1, "gap_mm": GAP},
            "notes": "操作：A 侧与 B 侧均选择同一组件（如 701 或其部分单元）。两遍选择只要包含任一相同单元 id 即被拒绝。",
        }
    )

    # ------------------------------------------------------------------
    # B08 边界：斜对置（两块板 20° 倾斜对置）
    # ------------------------------------------------------------------
    model.component(801, "B08_PLATE_A", 3)
    model.component(802, "B08_PLATE_B_TILTED", 6)
    add_shell_grid(model, 801, (5600.0, 0.0, 0.0), 40, 30)
    add_tilted_grid(model, 802, (5800.0, 150.0, 50.0), 40, 30, 20.0)
    sim = simulate_contact(
        [(eid, model.elements[eid].node_ids) for eid in model.components[801].element_ids],
        [(eid, model.elements[eid].node_ids) for eid in model.components[802].element_ids],
        xyz,
    )
    assert len(sim["kept_a"]) > 0 and len(sim["kept_b"]) > 0
    nrm_a = face_normal([model.nodes[n] for n in model.elements[model.components[801].element_ids[0]].node_ids])
    nrm_b = face_normal([model.nodes[n] for n in model.elements[model.components[802].element_ids[0]].node_ids])
    angle_deg = math.degrees(math.acos(max(-1.0, min(1.0, vdot(nrm_a, nrm_b)))))
    assert abs(angle_deg - 20.0) < 0.5, angle_deg
    model.cases.append(
        {
            "case_id": "B08",
            "title": "边界：斜对置（两块板 20° 倾斜对置，观察法向夹角边界判定）",
            "component_ids": [801, 802],
            "component_names": ["B08_PLATE_A", "B08_PLATE_B_TILTED"],
            "expected": "创建 1 个 CONTACT group：邻近筛选按质心距离（bboxGap=0 -> searchTol=35.36 mm），公共区域为 B 板下倾侧（左端 z<=35 mm 的部分）+ A 板对应足印；reverse_normals 使两表面相向",
            "expected_results": {
                "selected_A": sim["selected_a"], "kept_A": len(sim["kept_a"]),
                "selected_B": sim["selected_b"], "kept_B": len(sim["kept_b"]),
                "normal_angle_deg": round(angle_deg, 2),
                "bbox_gap_mm": round(sim["bbox_gap_mm"], 3),
                "search_tolerance_mm": round(sim["search_tolerance_mm"], 3),
                "expected_group_count": 1, "expected_type": "STICK",
                "main_side": "FIRST" if len(sim["kept_b"]) <= len(sim["kept_a"]) else "SECOND",
            },
            "settings": {"contact_type": "STICK", "main_side": "AUTO", "result_prefix": "AUTO_CONTACT", "try_group": 1, "gap_mm": 50.0, "tilt_deg": 20.0},
            "notes": "B 板左端下倾到 z=-18.4 mm、右端升到 z=118.4 mm；bboxGap=0（bbox 在 Z 向交叠），searchTol=2.5*medianSpan。kept 区域由质心距离决定（约 B 板左半）。",
        }
    )


# --------------------------------------------------------------------------
# Validation / self checks
# --------------------------------------------------------------------------

def edge_usage(model: Model) -> Tuple[int, Dict[int, int]]:
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

    if set(model.nodes) != set(range(1, len(model.nodes) + 1)):
        errors.append("node ids are not a dense 1..N sequence")

    for element in model.elements.values():
        if element.card != "CQUAD4" or len(element.node_ids) != 4:
            errors.append("malformed element {}".format(element.element_id))
        if any(node not in model.nodes for node in element.node_ids):
            errors.append("element {} references missing node".format(element.element_id))
        pts = [model.nodes[n] for n in element.node_ids]
        area = vnorm(vcross(vsub(pts[1], pts[0]), vsub(pts[3], pts[0])))
        if area <= 0.0:
            errors.append("degenerate quad {}".format(element.element_id))

    if len({tuple(e.node_ids) for e in model.elements.values()}) != len(model.elements):
        errors.append("duplicate element connectivity found")

    if len(model.cases) != 8:
        errors.append("expected exactly 8 cases, got {}".format(len(model.cases)))

    _, per_comp = edge_usage(model)
    expected_boundary = {
        # rect plates: 2*ncx + 2*ncy
        101: 2 * 50 + 2 * 30, 102: 2 * 50 + 2 * 30,
        201: 2 * 50 + 2 * 30, 202: 2 * 50 + 2 * 30,
        301: 2 * 30 + 2 * 20, 302: 2 * 30 + 2 * 20,
        303: 2 * 30 + 2 * 20, 304: 2 * 30 + 2 * 20,
        305: 2 * 30 + 2 * 20, 306: 2 * 30 + 2 * 20,
        401: 2 * 30 + 2 * 20, 402: 2 * 30 + 2 * 20,
        403: 2 * 30 + 2 * 20, 404: 2 * 30 + 2 * 20,
        405: 2 * 30 + 2 * 20, 406: 2 * 30 + 2 * 20,
        407: 2 * 30 + 2 * 20, 408: 2 * 30 + 2 * 20,
        501: 2 * 30 + 2 * 20, 502: 2 * 30 + 2 * 20,
        601: 2 * 30 + 2 * 20, 602: 2 * 30 + 2 * 20,
        701: 2 * 30 + 2 * 20, 702: 2 * 30 + 2 * 20,
        801: 2 * 40 + 2 * 30, 802: 2 * 40 + 2 * 30,
    }
    for comp_id, expected in expected_boundary.items():
        actual = per_comp.get(comp_id)
        if actual != expected:
            errors.append("component {} boundary edges {} != expected {}".format(comp_id, actual, expected))

    # A/B selections must be disjoint in the running model (only B07 relies on
    # shared elements, and there the operator selects the same component twice).
    all_elems = []
    for case in model.cases:
        if case["case_id"] == "B07":
            continue
        ids = case["component_ids"]
        for cid in ids:
            all_elems.extend(model.components[cid].element_ids)
    if len(set(all_elems)) != len(all_elems):
        errors.append("some shell elements are shared between B-side components (must be disjoint)")

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
        "$ Contact Setup combined validation deck",
        "$ Parallel / offset / tilted shell plate pairs",
        "$ Generated by examples/ContactSetup_Validation/generate_fem.py",
        "$ Units: mm, N, MPa. Test geometry only - not a production solve model.",
        "BEGIN BULK",
        '$HMNAME MAT 1 "CT_STEEL"',
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
        "purpose": "Contact Setup（接触创建）模块验证：双向邻近筛选公共覆盖区、SURF + CONTACT group 创建与失败/边界行为",
        "generator": "examples/ContactSetup_Validation/generate_fem.py",
        "fem": "ContactSetup_Combined_Validation.fem",
        "parameters": {
            "mesh_size_mm": CELL,
            "case_pitch_mm": 400,
            "contact_type": CONTACT_TYPE,
            "main_side": MAIN_SIDE,
            "result_prefix": RESULT_PREFIX,
            "try_group": 1,
            "units": "mm,N,Mpa",
            "module_version": "0.3",
        },
        "statistics": stats,
        "components": components,
        "cases": model.cases,
        "warning": "几何验证模型，仅供识别/流程验证，非生产求解模型；SURF/CONTACT 创建需在 HyperMesh 2019 OptiStruct profile 中实机验证。",
    }


def parse_args() -> argparse.Namespace:
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=directory / "ContactSetup_Combined_Validation.fem")
    parser.add_argument("--manifest", type=Path, default=directory / "ContactSetup_Combined_Validation_manifest.json")
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
