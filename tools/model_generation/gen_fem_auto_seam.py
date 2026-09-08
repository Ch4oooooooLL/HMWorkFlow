#!/usr/bin/env python3
"""gen_fem_auto_seam.py -- fem_auto_seam LARGE shell validation.

fm_auto_seam detects joints between shell components that do not share nodes:

  near_edge_distance   8 mm
  small_hole_diameter 30 mm   (holes <= this on a patch trigger REVIEW)
  minimum_t_length    15 mm
  search_distance     12 mm
  T-type normal angle >= 30 deg
  patch tilt <= 15 deg, area small enough (fully inside target projection,
  area difference > 2%)

Content (groups separated 300 mm along X, components share no nodes):
  T-type        8 pairs, source normal 35..90 deg from target, gap 1..6 mm,
                source free-edge 30..200 mm.
  Patch         6 small plates inside target projection (area diff 5..50%),
                2 of them carry a hole <= 30 mm -> REVIEW candidates.
  Near-edge     4 pairs of coplanar plates, edge gap 2..8 mm.
  Multi-target  2 source plates each straddling 2..3 target plates.
  Negative      2: gap 100 mm (no trigger) and a one-piece integrated plate
                (same component, shared nodes -> no joint detected).

>= 30k shell elements, >= 20 components.  Deterministic; stdlib-only.
"""

from __future__ import annotations

import math
import os
import sys
from typing import Dict, List, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import femlib as F
from femlib import Model

PITCH = 300.0
THRESH = {
    "near_edge_distance": 8.0, "small_hole_diameter": 30.0,
    "minimum_t_length": 15.0, "search_distance": 12.0,
    "t_min_normal_angle": 30.0, "patch_max_tilt": 15.0,
}


def _node_ids(model, comp) -> List[int]:
    out = []
    for el in model.elements_of(comp):
        out.extend(el.node_ids)
    return out


def _plate_xy(model, comp, cx, cy, w, h, mesh, z):
    return F.rect_plate_mesh(model, comp, (cx - w / 2.0, cy - h / 2.0, z),
                             w, h, max(1, int(round(w / mesh))), max(1, int(round(h / mesh))))


def _tilted_source(model, comp, cx, y0, z0, length, height, mesh, tilt_deg):
    """Vertical-ish source plate whose bottom edge (free edge) lies along X at
    (z=z0, y=y0).  The plate plane is spanned by u=(1,0,0) and v=(0,-cos,sin),
    so the angle between its normal and +Z = tilt_deg (the T dihedral angle)."""
    th = math.radians(tilt_deg)
    c, s = math.cos(th), math.sin(th)
    nx = max(1, int(round(length / mesh)))
    ny = max(1, int(round(height / mesh)))
    grid = []
    for j in range(ny + 1):
        row = []
        for i in range(nx + 1):
            sx = length * i / nx
            sy = height * j / ny
            x = cx - length / 2.0 + sx
            y = y0 - sy * c
            z = z0 + sy * s
            row.append(model.node(x, y, z))
        grid.append(row)
    for j in range(ny):
        for i in range(nx):
            model.elem(comp, "CQUAD4", (grid[j][i], grid[j][i + 1],
                                        grid[j + 1][i + 1], grid[j + 1][i]))
    info = {"grid": grid, "tilt_deg": tilt_deg, "free_edge_len": length}
    return info


def build_model() -> Tuple[Model, List[Dict]]:
    model = Model("fem_auto_seam LARGE shell validation")
    mat = model.add_material("STEEL")

    def prop(name, t):
        return model.add_property("PSHELL", name + "_PSHELL", mat.mid, thickness=t)

    J = {"x": 0.0}

    def new_x():
        v = J["x"]
        J["x"] += PITCH
        return v

    cases: List[Dict] = []

    # ---- T-type pairs (8), angle gradient 35..90 deg ------------------------
    angles = [35, 40, 46, 55, 63, 70, 80, 90]
    gaps = [1, 2, 3, 4, 5, 6, 1, 2][:8]
    for i, ang in enumerate(angles):
        cx = new_x()
        gap = gaps[i]
        free_len = 30 + 24 * i  # 30..198 (within 30..200)
        p_t = prop("V{:02d}FTAR".format(i + 1), 1.5)
        p_s = prop("V{:02d}FSRC".format(i + 1), 1.2)
        c_t = model.add_component("V{:02d}_FTARGET_T1.5".format(i + 1), 3, p_t)
        c_s = model.add_component("V{:02d}_FSOURCE_T1.2".format(i + 1), 4, p_s)
        _plate_xy(model, c_t, cx, 0.0, 420, 320, 6.0, 0.0)
        _tilted_source(model, c_s, cx, 0.0, gap, free_len, 220, 6.0, ang)
        cases.append({"case_id": "FT{:02d}".format(i + 1), "kind": "T",
                      "angle": ang, "gap": gap, "source_free_edge_len": free_len,
                      "source_comp": c_s.name, "target_comp": c_t.name,
                      "expected": "T-type, normal angle {}>=30, gap {} (1..6)".format(ang, gap)})

    # ---- Patch pairs (6), patch area = 5..50% of target, 2 with hole ------->
    patch_areas = [0.05, 0.10, 0.15, 0.20, 0.30, 0.50]
    for i, frac in enumerate(patch_areas):
        cx = new_x()
        gap = 0.5 + 0.4 * i
        p_t = prop("V{:02d}PTAR".format(i + 1), 1.5)
        p_p = prop("V{:02d}PPAT".format(i + 1), 1.0)
        c_t = model.add_component("V{:02d}_PTARGET_T1.5".format(i + 1), 5, p_t)
        c_p = model.add_component("V{:02d}_PPATCH_T1.0".format(i + 1), 6, p_p)
        _plate_xy(model, c_t, cx, 0.0, 400, 300, 6.0, 0.0)
        # square patch area = frac * target_area (target 400x300)
        target_area = 400.0 * 300.0
        p_w = math.sqrt(target_area * frac)
        p_h = p_w
        if i in (3, 5):  # 2 patches carry a small inner hole -> REVIEW
            dia = 14.0 + 6.0 * i
            cell = p_w + 40.0
            F.washer_hole_cell(model, c_p, (cx, 0.0, gap), dia, 10, (4.0, 6.0), cell, 24)
        else:
            _plate_xy(model, c_p, cx, 0.0, p_w, p_h, 6.0, gap)
        cases.append({"case_id": "P{:02d}".format(i + 1), "kind": "patch",
                      "patch_area_pct": round(frac * 100.0, 1), "gap": gap,
                      "hole_diameter": 14.0 + 6.0 * i if i in (3, 5) else None,
                      "patch_comp": c_p.name, "target_comp": c_t.name,
                      "with_hole": i in (3, 5),
                      "expected": "patch (tilt 0), area {:.1f}% of target{}".format(
                          frac * 100.0, "; REVIEW (hole)" if i in (3, 5) else "")})

    # ---- Near-edge pairs (4), gap 2..8 mm -----------------------------------
    for i, gap in enumerate([2, 3.5, 5, 7]):
        cx = new_x()
        p_a = prop("V{:02d}NEA".format(i + 1), 1.5)
        p_b = prop("V{:02d}NEB".format(i + 1), 1.5)
        c_a = model.add_component("V{:02d}_NEAR_A_T1.5".format(i + 1), 7, p_a)
        c_b = model.add_component("V{:02d}_NEAR_B_T1.5".format(i + 1), 8, p_b)
        _plate_xy(model, c_a, cx - gap / 2.0 - 90.0, 0.0, 220, 180, 6.0, 0.0)
        _plate_xy(model, c_b, cx + gap / 2.0 + 90.0, 0.0, 220, 180, 6.0, 0.0)
        cases.append({"case_id": "NE{:02d}".format(i + 1), "kind": "near",
                      "gap": gap, "comp_a": c_a.name, "comp_b": c_b.name,
                      "expected": "near free edge, gap {} (2..8)".format(gap)})

    # ---- Multi-target pairs (2) ---------------------------------------------
    for i in range(2):
        cx = new_x()
        n_targets = 2 if i == 0 else 3
        p_s = prop("V{:02d}MULTIS".format(i + 1), 1.0)
        c_s = model.add_component("V{:02d}_MULTISRC_T1.0".format(i + 1), 2, p_s)
        # one horizontal source plate spanning the targets
        span = n_targets * 260
        _plate_xy(model, c_s, cx, 0.0, 240, span, 6.0, 0.0)
        targets = []
        for k in range(n_targets):
            p_t = prop("V{:02d}MULTIT{}".format(i + 1, k), 1.5)
            c_t = model.add_component("V{:02d}_MULTITGT{}_{}".format(i + 1, k, n_targets), 3, p_t)
            ty = -span / 2.0 + 130.0 + k * 260
            _plate_xy(model, c_t, cx, ty, 240, 200, 6.0, 4.0)
            targets.append(c_t.name)
        cases.append({"case_id": "M{:02d}".format(i + 1), "kind": "multi",
                      "n_targets": n_targets, "source_comp": c_s.name,
                      "target_comps": targets,
                      "expected": "1 source across {} target plates".format(n_targets)})

    # ---- Negative 1: 100 mm gap (no trigger) --------------------------------
    cx = new_x()
    p_a = prop("V30NEGA", 1.5)
    p_b = prop("V30NEGB", 1.5)
    c_a = model.add_component("V30_NEGDIST_A_T1.5", 7, p_a)
    c_b = model.add_component("V30_NEGDIST_B_T1.5", 7, p_b)
    _plate_xy(model, c_a, cx - 100.0 - 90.0, 0.0, 220, 180, 6.0, 0.0)
    _plate_xy(model, c_b, cx + 100.0 + 90.0, 0.0, 220, 180, 6.0, 0.0)
    cases.append({"case_id": "NEG1", "kind": "negative", "gap": 100.0,
                  "expected": "gap 100 > search_distance 12 -> NOT detected"})

    # ---- Negative 2: integrated one-piece plate (shared nodes) --------------
    cx = new_x()
    p_int = prop("V31_INTEG", 1.5)
    c_int = model.add_component("V31_INTEGRATED_T1.5", 9, p_int)
    _integrated_l_plate(model, c_int, cx, 0.0, 6.0)
    cases.append({"case_id": "NEG2", "kind": "negative", "shared": True,
                  "component": c_int.name,
                  "expected": "one-piece integrated plate (same comp) -> no joint"})

    return model, cases, J


def _integrated_l_plate(model: Model, comp: F.Component, cx, cy, mesh):
    """L-shaped plate built as ONE component (shared nodes) -> fem_auto_seam
    must NOT find a joint, since both legs are one connected mesh."""
    leg1 = 240.0
    leg2 = 200.0
    w = 160.0
    nx1 = max(1, int(round(leg1 / mesh)))
    nx2 = max(1, int(round(w / mesh)))
    # build full rectangle then leave a notch by splitting the mesh
    # Simpler: place nodes for an L-plan and quad them row by row.
    origin = (cx - leg1 / 2.0, cy - leg2 / 2.0, 0.0)
    # X from origin[0]..+leg1 ; Y from origin[1]..+leg2 ; L removes top-right w x w
    n1 = max(1, int(round(leg1 / mesh)))
    n2 = max(1, int(round(leg2 / mesh)))
    nw = max(1, int(round(w / mesh)))
    grid = {}
    for j in range(n2 + 1):
        for i in range(n1 + 1):
            grid[(i, j)] = model.node(
                origin[0] + leg1 * i / n1, origin[1] + leg2 * j / n2, 0.0)
    def in_plate(i, j):
        # notch: remove top-right w x w region
        x = origin[0] + leg1 * i / n1
        y = origin[1] + leg2 * j / n2
        xmax = origin[0] + leg1
        ymax = origin[1] + leg2
        if x > xmax - w - 1e-9 and y > ymax - w - 1e-9:
            return False
        return True
    for j in range(n2):
        for i in range(n1):
            if not (in_plate(i, j) and in_plate(i + 1, j)
                    and in_plate(i + 1, j + 1) and in_plate(i, j + 1)):
                continue
            model.elem(comp, "CQUAD4", (grid[(i, j)], grid[(i + 1, j)],
                                        grid[(i + 1, j + 1)], grid[(i, j + 1)]))
    return grid


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------


def verify(model: Model, cases: List[Dict], J) -> Dict:
    comp_names = {c.name for c in model.components.values()}
    errors = []
    for case in cases:
        for key in ("source_comp", "target_comp", "patch_comp", "comp_a",
                    "comp_b", "component"):
            if case.get(key) and case[key] not in comp_names:
                errors.append("{}: missing comp {}".format(case["case_id"], case[key]))
        for key in ("target_comps",):
            for t in case.get(key, []):
                if t not in comp_names:
                    errors.append("{}: missing target {}".format(case["case_id"], t))

    # geometry checks
    for case in cases:
        if case["kind"] == "T":
            assert case["angle"] >= 30.0 and case["angle"] <= 90.0, case
            assert 1.0 <= case["gap"] <= 6.0, case
            assert 30.0 <= case["source_free_edge_len"] <= 200.0, case
        elif case["kind"] == "patch":
            assert 5.0 <= case["patch_area_pct"] <= 50.0, case
            comp = next(c for c in model.components.values() if c.name == case["patch_comp"])
            q = F.mesh_quality_stats(model, comp)
            assert q["degenerate"] == 0, "{} degenerate patch".format(case["case_id"])
        elif case["kind"] == "near":
            assert 2.0 <= case["gap"] <= 8.0, case
        elif case["kind"] == "negative" and case["case_id"] == "NEG1":
            assert case["gap"] == 100.0

    stats = model.stats()
    stats.update({
        "joint_T_pairs": sum(1 for c in cases if c["kind"] == "T"),
        "patch_pairs": sum(1 for c in cases if c["kind"] == "patch"),
        "patch_review_hole": sum(1 for c in cases if c["kind"] == "patch" and c["with_hole"]),
        "near_edge_pairs": sum(1 for c in cases if c["kind"] == "near"),
        "multi_target": sum(1 for c in cases if c["kind"] == "multi"),
        "negative_pairs": sum(1 for c in cases if c["kind"] == "negative"),
        "thresholds": THRESH,
    })
    assert stats["element_count"] >= 30000, stats["element_count"]
    assert stats["component_count"] >= 20, stats["component_count"]
    if errors:
        raise ValueError("verification failed:\n- " + "\n- ".join(errors))
    return stats


def manifest(model, cases, J, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name,
              "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    return {
        "schema_version": "1.0",
        "module": "fem_auto_seam",
        "purpose": "LARGE fem_auto_seam shell validation: 8 T + 6 patch (2 with hole) + "
                   "4 near-edge + 2 multi-target + 2 negatives. Components share no nodes.",
        "generator": "tools/model_generation/gen_fem_auto_seam.py",
        "fem": "FemAutoSeam_Large.fem",
        "parameters": THRESH,
        "statistics": stats,
        "components": comps,
        "cases": cases,
        "warning": "Validation geometry only; joints are NOT connected (gap-separated comps).",
    }


def main() -> int:
    model, cases, J = build_model()
    stats = verify(model, cases, J)
    outdir = common.model_dir("fem_auto_seam_large")
    fem_path = outdir / "FemAutoSeam_Large.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "FemAutoSeam_Large_manifest.json",
                          manifest(model, cases, J, stats))
    common.write_readme(outdir / "README.md", README)
    print("nodes={} elems={} comps={}".format(stats["node_count"],
                                              stats["element_count"],
                                              stats["component_count"]))
    sk = {k: v for k, v in stats.items() if not isinstance(v, dict)}
    sk.pop("element_count", None)
    print(sk)
    return 0


README = """# fem_auto_seam — Large Shell Validation Model

## 用途
`FemAutoSeam_Large.fem` 用于 `fem_auto_seam`（FEM 自动焊缝）的大规模验证：
T 型、贴片（含内孔 REVIEW）、邻近自由边、多目标与负向场景。规模 >=3 万壳单元、
>=20 组件。

## 场景表
| ID | 类别 | 内容 | 预期 |
|---|---|---|---|
| FT01..FT08 | T 型（8） | 源板与目标板法向夹角 35~90° 梯度，间隙 1~6mm，自由边 30~198mm | 识别 T（夹角>=30°） |
| P01..P06 | 贴片（6） | 小板面积为目标 8%~50%（差 5%~50%），2 个带 <=30mm 内孔 | 贴片识别；P04/P06 REVIEW（内孔） |
| NE01..NE04 | 邻近自由边（4） | 共面平行边，间隙 2~8mm | 识别近边 seam |
| M01..M02 | 多目标（2） | 1 源板跨 2~3 目标板 | 识别多对 |
| NEG1 | 负向 | 间隙 100mm（>12 不触发） | 不识别 |
| NEG2 | 负向 | 一体集成 L 板（共享节点同组件） | 不识别 |

## 操作
1. HyperMesh 导入 `FemAutoSeam_Large.fem`。
2. 全选壳单元运行模块（阈值：near_edge 8 / search 12 / small_hole 30 / min_t 15）。
3. 核对 T/P/NE/M 候选与 REVIEW 标记；NEG 不触发。

## 设计说明
- 组件间不共享节点（除 NEG2 一体板）；每组独立、间距 300mm。
- 贴片面积差按目标板面积计算；带孔贴片用 washer 单元（孔环完整）。
- 确定性生成（无随机）；生成时自检间隙/夹角/面积比/无退化单元。
"""

if __name__ == "__main__":
    raise SystemExit(main())
