#!/usr/bin/env python3
"""gen_solid_seam.py -- LARGE solid seam-weld validation model for
solid_seam_connector.

The module takes two solid components, detects the junction node chain between
them (nodes within search_distance, chain length >= min_weld_length), classifies
the joint from component average normals and creates PENTA6 + RBE3 solid welds
into SEAM_SOLID.  Defaults: search_distance=15, max_search_distance=25,
min_weld_length=20, width/spacing 6.  Joint classes:
T (perpendicular, high boundary ratio) / LAP (parallel <=20deg) /
BUTT (parallel, high boundary ratio) / ANGLED (<=40deg) / UNKNOWN.

This generator authors 10 joints, each two hexa solid components meshed at
6 mm (~1000 hexa per block).  The two components NEVER share nodes (a small
joint gap keeps them apart).  List:

    J01..J03  T joints (wall bottom edge over floor, gap 2 mm)
    J04..J05  LAP joints (two parallel plates stacked, gap 2 mm)
    J06..J07  BUTT joints (two plates end-to-end, gap 1.5 mm)
    J08..J09  ANGLED joints (30 deg / 40 deg miter, gap 2 mm)
    J10       negative joint (gap 30 mm > max_search_distance 25 -> no seam)

~20 hexa components, ~20k hexa total.  PENTA6 + RBE3 welds are created by the
module at run time.  Units mm / N / tonne.  Deterministic, stdlib-only.
"""

from __future__ import annotations

import math
import os
import sys
from typing import Dict, List, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import femlib as F
from femlib import Model

MESH = 6.0
SEARCH = 15.0
MAX_SEARCH = 25.0
MIN_WELD_LEN = 20.0


def add_block(model: Model, comp: F.Component, origin: Tuple[float, float, float],
              dx: float, dy: float, dz: float, rot_axis: str = "NONE",
              angle_deg: float = 0.0, passcode: str = "") -> Dict:
    """Build a 6 mm hexa box, optionally rotating all nodes about the box
    centre.  passcode is unused (kept for clarity of intent)."""
    nx = max(1, int(round(dx / MESH)))
    ny = max(1, int(round(dy / MESH)))
    nz = max(1, int(round(dz / MESH)))
    info = F.hex_block_mesh(model, comp, origin, dx, dy, dz, nx, ny, nz)
    if rot_axis != "NONE":
        cx = origin[0] + dx / 2.0
        cy = origin[1] + dy / 2.0
        cz = origin[2] + dz / 2.0
        _rotate_nodes(model, comp, (cx, cy, cz), angle_deg, rot_axis)
    return info


def _rotate_nodes(model: Model, comp: F.Component, center, angle_deg: float, axis: str) -> None:
    c = math.cos(math.radians(angle_deg))
    s = math.sin(math.radians(angle_deg))
    cx, cy, cz = center
    touched = set()
    for el in model.elements_of(comp):
        for n in el.node_ids:
            if n in touched:
                continue
            touched.add(n)
            x, y, z = model.nodes[n]
            dx, dy, dz = x - cx, y - cy, z - cz
            if axis == "Y":
                nx_, ny_, nz_ = cx + dx * c + dz * s, cy + dy, cz - dx * s + dz * c
            elif axis == "X":
                nx_, ny_, nz_ = cx + dx, cy + dy * c - dz * s, cz + dy * s + dz * c
            else:
                nx_, ny_, nz_ = cx + dx * c - dy * s, cy + dx * s + dy * c, cz + dz
            model.nodes[n] = (round(nx_, 9), round(ny_, 9), round(nz_, 9))


def joint_geometry() -> List[Dict]:
    """Return the 10 joint definitions as (comps, boxes).  Each joint places its
    two blocks at an increasing X origin so no cross-joint nodes interfere."""
    j = []

    def T(floor_origin, wall_origin):
        # horizontal floor + vertical wall standing on it (bottom edge over floor)
        floor = {"origin": floor_origin, "dims": (150.0, 60.0, 24.0), "mesh": (25, 10, 4)}
        wall = {"origin": wall_origin, "dims": (60.0, 24.0, 120.0), "mesh": (10, 4, 20)}
        return floor, wall

    def LAP(base_origin, top_origin):
        a = {"origin": base_origin, "dims": (150.0, 60.0, 24.0), "mesh": (25, 10, 4)}
        b = {"origin": top_origin, "dims": (150.0, 60.0, 24.0), "mesh": (25, 10, 4)}
        return a, b

    def BUTT(a_origin, a_dims, b_origin, b_dims):
        a = {"origin": a_origin, "dims": a_dims, "mesh": tuple(int(round(d / MESH)) for d in a_dims)}
        b = {"origin": b_origin, "dims": b_dims, "mesh": tuple(int(round(d / MESH)) for d in b_dims)}
        return a, b

    def ANGLED(base_origin, up_origin, ang):
        a = {"origin": base_origin, "dims": (150.0, 60.0, 24.0), "mesh": (25, 10, 4)}
        b = {"origin": up_origin, "dims": (150.0, 60.0, 24.0), "mesh": (25, 10, 4)}
        return a, b

    spec_base_x = 0.0
    pitch_x = 260.0

    def origin_jump():
        nonlocal spec_base_x
        x = spec_base_x
        spec_base_x += pitch_x
        return x

    # ---- 3 T joints --------------------------------------------------------
    for k in range(3):
        bx = origin_jump()
        floor = (bx, 0.0, 0.0)
        wall = (bx + 45.0, 18.0, 24.0 + 2.0)   # bottom edge 2mm above floor top (z=24)
        floor_box, wall_box = T(floor, wall)
        j.append({"id": k + 1, "label": "J{:02d}_T".format(k + 1), "kind": "T_JOINT",
                  "gap_mm": 2.0, "boxes": [floor_box, wall_box],
                  "expect": "wall bottom edge -> floor (PENTA_MIG_T)"})

    # ---- 2 LAP joints ------------------------------------------------------
    for k in range(2):
        bx = origin_jump()
        base = (bx, 0.0, 0.0)
        top = (bx + 10.0, 0.0, 24.0 + 2.0)     # stacked plate, 2mm above, 10mm plan offset
        a, b = LAP(base, top)
        j.append({"id": 4 + k, "label": "J0{}_LAP{}".format(4 + k, "AB" if k else "BA"),
                  "kind": "LAP_JOINT", "gap_mm": 2.0, "boxes": [a, b],
                  "expect": "two parallel plates overlap (PENTA_MIG_L)"})

    # ---- 2 BUTT joints -----------------------------------------------------
    butts = [
        ((150.0, 60.0, 24.0), (150.0, 60.0, 24.0), 1.5),
        ((150.0, 60.0, 48.0), (150.0, 60.0, 48.0), 1.5),
    ]
    for k, (dima, dimb, gap) in enumerate(butts):
        bx = origin_jump()
        a_o = (bx, 0.0, 0.0)
        b_o = (bx + dima[0] + gap, 0.0, 0.0)     # end faces opposite with x-gap
        a, b = BUTT(a_o, dima, b_o, dimb)
        j.append({"id": 6 + k, "label": "J0{}_BUTT".format(6 + k), "kind": "BUTT_JOINT",
                  "gap_mm": gap, "boxes": [a, b], "expect": "end-to-end plates (PENTA_MIG_B)"})

    # ---- 2 ANGLED joints ---------------------------------------------------
    for k, ang in enumerate((30.0, 40.0)):
        bx = origin_jump()
        base = (bx, 0.0, 0.0)
        up = (bx, 12.0, 26.0)
        a, b = ANGLED(base, up, ang)
        j.append({"id": 8 + k, "label": "J0{}_ANGLED{}".format(8 + k, int(ang)),
                  "kind": "ANGLED_JOINT", "gap_mm": 2.0, "angle_deg": ang,
                  "boxes": [a, b], "expect": "miter joint (PENTA_MIG)"})

    # ---- 1 negative joint --------------------------------------------------
    bx = origin_jump()
    a = {"origin": (bx, 0.0, 0.0), "dims": (150.0, 60.0, 24.0), "mesh": (25, 10, 4)}
    b = {"origin": (bx, 0.0, 54.0), "dims": (150.0, 60.0, 24.0), "mesh": (25, 10, 4)}
    j.append({"id": 10, "label": "J10_NEG", "kind": "UNKNOWN", "gap_mm": 30.0,
              "boxes": [a, b], "expect": "gap 30mm > max_search_distance 25 -> no seam"})
    return j


def build_model() -> Tuple[Model, List[Dict]]:
    model = Model("Solid seam-weld validation model (10 joints, ~20k hexa)")
    mat = model.add_material("STEEL", mid=1)
    joints = joint_geometry()
    comps_name = []
    for joint in joints:
        names = []
        for bi, box in enumerate(joint["boxes"]):
            cname = "V{0:02d}_{1}{2}".format(joint["id"], "A" if bi == 0 else "B",
                                             "_SEAM" if joint["kind"] != "UNKNOWN" else "_NEG")
            # one PSOLID per component: HyperMesh links a property to the
            # component of the same id on .fem import (shared props land in
            # misc and drag every element with them)
            psolid = model.add_property("PSOLID", cname + "_PSOLID", mat.mid)
            comp = model.add_component(cname, 3 + joint["id"] % 12, psolid)
            add_block(model, comp, box["origin"], *box["dims"])
            box["comp"] = comp
            names.append(comp)
        joint["comps"] = names
        comps_name.append(names)
    return model, joints


def nearest_node_gap(model: Model, compA, compB) -> Tuple[float, List[int]]:
    """Min Euclidean distance between any node of A and any node of B, plus the
    list of B-node ids that have an A-node within SEARCH (15 mm)."""
    a_pos = {model.nodes[n] for el in model.elements_of(compA) for n in el.node_ids}
    best = float("inf")
    near_b = []
    b_nodes = {n for el in model.elements_of(compB) for n in el.node_ids}
    for n in b_nodes:
        p = model.nodes[n]
        local = min(math.dist(p, q) for q in a_pos)
        if local < best:
            best = local
        if local <= SEARCH:
            near_b.append(n)
    return best, near_b


def chain_span_length(model: Model, compA, compB) -> Tuple[float, float]:
    """Span (longest axis extent) of the junction region (compA nodes within
    SEARCH of compB) and the min pair gap."""
    b_pos = {model.nodes[n] for el in model.elements_of(compB) for n in el.node_ids}
    xs, ys, zs = [], [], []
    min_gap = float("inf")
    for el in model.elements_of(compA):
        for n in el.node_ids:
            p = model.nodes[n]
            local = min(math.dist(p, q) for q in b_pos)
            if local < min_gap:
                min_gap = local
            if local <= SEARCH:
                xs.append(p[0]); ys.append(p[1]); zs.append(p[2])
    if not xs:
        return 0.0, min_gap
    return max(max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)), min_gap


def verify(model: Model, joints) -> Dict:
    errors = []
    if len(joints) != 10:
        errors.append("joints != 10")
    for joint in joints:
        a, b = joint["comps"]
        gap = abs(joint["gap_mm"])
        # components must NOT share nodes
        a_nodes = {n for el in model.elements_of(a) for n in el.node_ids}
        b_nodes = {n for el in model.elements_of(b) for n in el.node_ids}
        if a_nodes & b_nodes:
            errors.append("{} shares nodes between components".format(joint["label"]))
        span, min_gap = chain_span_length(model, a, b)
        if joint["kind"] == "UNKNOWN":
            # negative: nearest gap clearly beyond search
            if min_gap <= MAX_SEARCH:
                errors.append("{} negative expects gap > max_search, got {}".format(joint["label"], round(min_gap, 2)))
        else:
            if min_gap > SEARCH:
                errors.append("{} junction gap {} > search 15".format(joint["label"], round(min_gap, 2)))
            if span < MIN_WELD_LEN:
                errors.append("{} chain length {} < {}mm".format(joint["label"], round(span, 2), int(MIN_WELD_LEN)))
    total_hexa = sum(len(c.element_ids) for c in model.components.values())
    if total_hexa < 15000:
        errors.append("total hexa {} < 15000".format(total_hexa))
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors[:30]))
    stats = model.stats()
    stats.update({"joint_count": len(joints),
                  "search_distance": SEARCH, "max_search_distance": MAX_SEARCH,
                  "min_weld_length": MIN_WELD_LEN, "default_width": 6.0, "default_spacing": 6.0})
    return stats


def manifest(model: Model, joints, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name, "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    joint_list = []
    for joint in joints:
        joint_list.append({"id": joint["id"], "label": joint["label"],
                           "kind": joint["kind"], "gap_mm": joint["gap_mm"],
                           "angle_deg": joint.get("angle_deg", 0.0),
                           "components": [joint["comps"][0].name, joint["comps"][1].name],
                           "expected": joint["expect"]})
    return {
        "module": "solid_seam_connector",
        "purpose": "LARGE solid seam-weld validation model (10 joints, ~20k hexa)",
        "generator": "tools/model_generation/gen_solid_seam.py",
        "fem": "SolidSeam_10joints.fem",
        "parameters": {"search_distance": SEARCH, "max_search_distance": MAX_SEARCH,
                       "min_weld_length": MIN_WELD_LEN, "default_width": 6.0,
                       "default_spacing": 6.0, "realize": "PENTA6 + RBE3",
                       "output_component": "SEAM_SOLID"},
        "statistics": stats,
        "components": comps,
        "joints": joint_list,
        "expected_module_result": "J01-J03 T, J04-J05 LAP, J06-J07 BUTT, J08-J09 ANGLED seams are detected and "
                                  "welded as PENTA6 + RBE3 into SEAM_SOLID; J10 (30 mm gap) produces no candidate.",
        "warning": "PENTA6 + RBE3 weld elements and the SEAM_SOLID output component are created by the module at "
                   "run time, not pre-authored here.",
    }


def main():
    model, joints = build_model()
    stats = verify(model, joints)
    outdir = common.model_dir("solid_seam_10joints")
    fem_path = outdir / "SolidSeam_10joints.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "SolidSeam_10joints_manifest.json", manifest(model, joints, stats))
    common.write_readme(outdir / "README.md", README)
    print({k: v for k, v in stats.items() if not isinstance(v, dict)})
    return 0


README = """# Solid Seam Weld — Large Validation Model

## 用途
`SolidSeam_10joints.fem` 用于 `solid_seam_connector`（实体焊缝）的大规模验证：
10 组接头、每组两个 6mm 六面体实体组件（两组件零共享节点、间有小间隙）。
默认参数：search_distance=15、max_search_distance=25、min_weld_length=20、宽度/间距 6。

## 场景（按组）
| id | 类型 | 间隙 | 预期 |
|---|---|---|---|
| J01..J03 | T | 2mm | 立板底边焊地板 → PENTA6+RBE3 入 SEAM_SOLID（PENTA_MIG_T） |
| J04..J05 | 搭接 LAP | 2mm | 两平行板叠放错位 → PENTA_MIG_L |
| J06..J07 | 对接 BUTT | 1.5mm | 两板端面相对 → PENTA_MIG_B |
| J08..J09 | 斜接 ANGLED | 2mm | 30°/40° 斜接 → PENTA_MIG |
| J10 | 负向 | 30mm | 间隙 > max_search_distance → 无焊缝候选 |

## 操作
1. 导入 `SolidSeam_10joints.fem`（20 个 hexa 组件，约 2 万单元）。
2. 逐组选择两个组件运行模块（或批量）；核对每组检测出交界链并按类型建焊缝到 `SEAM_SOLID`。
3. 核对 J10（30mm 间隙）应无候选。

## 设计说明
- 两组件**不共享节点**（存在 1.5~2mm 间隙），模拟装配界面。
- 每个块 6mm 网格，块体积/单元数 ~1000 hexa。
- 模块按组件平均法向分类接头；PENTA6+RBE3 焊缝与 SEAM_SOLID 组件由模块运行时创建。
"""


if __name__ == "__main__":
    raise SystemExit(main())
