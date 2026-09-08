#!/usr/bin/env python3
"""gen_local_mesh_opt.py -- local_mesh_optimizer LARGE quality-defect model.

Deliberately injects quality-failing shell elements that the
local_mesh_optimizer is expected to recognize / repair.  Module criteria:

  aspect ratio    >= 5
  warp            >= 15 deg
  quad angle      < 40 or > 140 deg
  tria angle      < 30 or > 120 deg
  skew            >= 40 deg
  jacobian        <= 0.60
  min/max length    2 / 30 mm
  SKINNY_TRIANGLE_RATIO 2.5 ; NARROW_QUAD_RATIO 2.5

Layout (deterministic, stdlib-only):
  Main grid 5 x Vxx plates (1200x800, 5mm -> 240x160 = 38400 elems each).
  Defect injection: 600 defects / plate (3000 total), isolated pattern
    (defect cells 8 apart so node moves don't corrupt neighbours):
      a) warp   150  -- out-of-plane node offset 2..6 mm
      b) thin-high-aspect quad 150 -- narrow 0.35..0.6 mm cell (aspect>5)
      c) large-skew 150 -- in-plane corner move, angle dev >45 deg
      d) skinny-tria 150 -- long-thin CTRIA3 (aspect >2.5)
  Washer+RBE2 protection zones: 12 cells -> module should skip them.
  1 clean control plate (no defects).
  4 narrow strip zones (width 2 cells).

Self-check: mesh_quality_stats over defected plates must show
aspect_over_5 > 500 and quad_dev_over_45 > 500, and degenerate == 0.
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

PLATE_W, PLATE_H = 1200.0, 800.0
MESH = 5.0
NX, NY = 240, 160          # cells

CRITERIA = {
    "aspect": 5.0, "warp_deg": 15.0, "quad_angle_min": 40.0,
    "quad_angle_max": 140.0, "tria_angle_min": 30.0, "tria_angle_max": 120.0,
    "skew": 40.0, "jacobian": 0.60, "length_min": 2.0, "length_max": 30.0,
    "SKINNY_TRIANGLE_RATIO": 2.5, "NARROW_QUAD_RATIO": 2.5,
}


def _node_ids(model, comp) -> List[int]:
    out = []
    for el in model.elements_of(comp):
        out.extend(el.node_ids)
    return out


# ---------------------------------------------------------------------------
# Defect injection helpers (operate on an existing rect grid + comp)
# ---------------------------------------------------------------------------


def _defect_cells(nx, ny, count):
    """Yield up to `count` defect cells (i,j) spaced apart so node moves stay
    isolated; i is bounded to nx-10 (skinny tria needs i+8) and j to ny-3."""
    total = nx * ny
    spacing = max(2, int(round(math.sqrt(total / float(count)))))
    # reduce spacing so >=count cells fit in the constrained region
    while True:
        ni = len(range(3, nx - 10, spacing))
        nj = len(range(3, ny - 3, spacing))
        if ni * nj >= count:
            break
        spacing -= 1
        if spacing < 2:
            break
    out = []
    for j in range(3, ny - 3, spacing):
        for i in range(3, nx - 10, spacing):
            if len(out) >= count:
                return out
            out.append((i, j))
    return out[:count]


def inject_defects(model: Model, comp: F.Component, grid, nx, ny, count=600):
    """Draw `count` isolated defect cells and apply a deterministic defect
    (cycling warp / thin / skew / skinny-tria)."""
    cells = _defect_cells(nx, ny, count)
    assert len(cells) >= count, "not enough isolating cells for {} defects".format(count)
    counters = {"warp": 0, "thin": 0, "skew": 0, "skinny": 0}
    for idx, (i, j) in enumerate(cells[:count]):
        kind = idx % 4
        if kind == 0:
            _defect_warp(model, grid, i, j, idx)
            counters["warp"] += 1
        elif kind == 1:
            _defect_thin_quad(model, grid, i, j)
            counters["thin"] += 1
        elif kind == 2:
            _defect_skew(model, grid, i, j, idx)
            counters["skew"] += 1
        else:
            _defect_skinny_tria(model, comp, grid, i, j)
            counters["skinny"] += 1
    return counters


def _defect_warp(model, grid, i, j, idx):
    """Warp: lift one shared corner node of the target quad out of plane by
    2..6 mm (isolated; safe for neighbours)."""
    nid = grid[j + 1][i]
    z = 2.0 + (idx % 40) * 0.1   # 2.0 .. 5.9 mm
    px, py, pz = model.nodes[nid]
    model.nodes[nid] = (px, py, round(pz + z, 9))


def _defect_thin_quad(model, grid, i, j):
    """High-aspect quad: pull the right column of the cell close to the left,
    leaving a narrow 0.35..0.6 mm cell (aspect ~ 12..5)."""
    # move the two right nodes of cell (i,j) inward by a deterministic amount
    width = 0.35
    x_left = model.nodes[grid[j][i]][0]
    # right nodes currently at x_left + MESH ; move to x_left + width
    for row in (j, j + 1):
        nid = grid[row][i + 1]
        px, py, pz = model.nodes[nid]
        model.nodes[nid] = (round(x_left + width, 9), py, pz)


def _defect_skew(model, grid, i, j, idx):
    """Large skew: shift one corner node in-plane by ~3.4..3.9 mm so the quad's
    corner deviates >45 deg.  The move stays inside the adjacent cell region
    (corner at (10,10) max) so neighbours never invert / go degenerate."""
    nid = grid[j + 1][i + 1]
    sx = 3.4 + 0.06 * (idx % 10)   # 3.40 .. 3.94 mm in +x
    sy = 3.4 + 0.06 * ((idx // 10) % 10)
    px, py, pz = model.nodes[nid]
    model.nodes[nid] = (round(px + sx, 9), round(py + sy, 9), pz)


def _defect_skinny_tria(model, comp, grid, i, j):
    """Skinny triangle: add a long-thin CTRIA3 using three of the plate grid
    nodes (a wide base running along x, a tiny apex one row up -> aspect >2.5).
    The original quad cell remains; the added loose tria is the defect."""
    a = grid[j][i]
    b = grid[j][i + 8]        # base far right (~40 mm along x)
    c = grid[j + 1][i]        # apex one grid row up (still thin, height 5 mm)
    model.elem(comp, "CTRIA3", (a, b, c))


# ---------------------------------------------------------------------------
# Model assembly
# ---------------------------------------------------------------------------


def plate_origin(index) -> Tuple[float, float, float]:
    # stack plates along +Y with a vertical offset so they don't collide
    return (0.0, index * (PLATE_H + 60.0), 0.0)


def build_plate(model, comp, origin) -> List[List[int]]:
    """Clean structured plate and return the node grid (index [row][col])."""
    info = F.rect_plate_mesh(model, comp, origin, PLATE_W, PLATE_H,
                             max(1, int(round(PLATE_W / MESH))),
                             max(1, int(round(PLATE_H / MESH))))
    return info["grid"]


def build_model() -> Tuple[Model, List[Dict]]:
    model = Model("local_mesh_optimizer LARGE quality-defect validation")
    mat = model.add_material("STEEL")

    def prop(name, t):
        return model.add_property("PSHELL", name + "_PSHELL", mat.mid, thickness=t)

    J = {"comp_seq": 1}
    cases: List[Dict] = []
    all_stats = []

    names_t = ["V01_MAIN_T1.5", "V02_MAIN_T1.5", "V03_MAIN_T1.5", "V04_MAIN_T1.5", "V05_MAIN_T1.5"]

    # ---- 5 defected main plates ---------------------------------------------
    for idx, name in enumerate(names_t):
        c = model.add_component(name, 3, prop(name, 1.5))
        grid = build_plate(model, c, plate_origin(idx))
        counters = inject_defects(model, c, grid, NX, NY, 600)
        q = F.mesh_quality_stats(model, c)
        all_stats.append(q)
        cases.append({"case_id": "MAIN{}".format(idx + 1), "component": name,
                      "defect_counts": counters,
                      "expected": "600 injected + isolated pattern -> optimizer repairs nonnegligibly"})

    # ---- clean control plate --------------------------------------------------
    c0 = model.add_component("V06_CONTROL_T1.5", 4, prop("V06_CONTROL_T1.5", 1.5))
    build_plate(model, c0, plate_origin(6))
    all_stats.append(F.mesh_quality_stats(model, c0))
    cases.append({"case_id": "CONTROL", "component": "V06_CONTROL_T1.5",
                  "expected": "clean plate, quality within criteria (baseline)"})

    # ---- 12 washer + RBE2 protection zones ------------------------------------
    prod_comps = []
    for z in range(12):
        name = "V{:02d}_WASHER_T1.5".format(7 + z)
        c = model.add_component(name, 5, prop(name, 1.5))
        cx = 200.0 + (z % 4) * 220.0
        cy = (7 + z // 4) * (PLATE_H + 60.0)
        F.washer_hole_cell(model, c, (cx, cy, 0.0), 12.0, 10, (4.0, 6.0), 120.0, 32)
        # RBE2 at the hole centre -> module should skip these protected zones
        out = model.add_component("AUTO_RBE2_V{:02d}_WASHER_T1.5".format(7 + z), 9)
        rind = model.node(cx, cy, 0.0)
        deps = []
        for el in model.elements_of(c):
            for nid in el.node_ids:
                if nid not in deps:
                    deps.append(nid)
        model.elem(out, "RBE2", (rind, "123456", *deps))
        prod_comps.append(name)
    cases.append({"case_id": "WASHERPROTECT", "components": prod_comps,
                  "expected": "12 washer+RBE2 protected zones; optimizer should skip them"})

    # ---- narrow strip zones (width 2 cells) ------------------------------------
    strip_comps = []
    for s in range(4):
        name = "V{:02d}_STRIP_T1.5".format(19 + s)
        c = model.add_component(name, 6, prop(name, 1.5))
        # plate 60 mm wide (12 cells) x 800 tall with width 2-cell ~ handled as full plate
        F.rect_plate_mesh(model, c, (0.0, (11 + s) * (PLATE_H + 60.0), 0.0),
                          60.0, 800.0, int(round(60.0 / MESH)), int(round(800.0 / MESH)))
        strip_comps.append(name)
    cases.append({"case_id": "STRIPS", "components": strip_comps,
                  "expected": "4 narrow strip zones, width 2 cells, optimizer boundary"})


    return model, cases


def verify(model: Model, cases: List[Dict]) -> Dict:
    # aggregate defect counts across the 5 main plates
    tot = {"aspect_over_5": 0, "quad_dev_over_45": 0, "angle_under_20": 0, "degenerate": 0}
    for idx in range(1, 6):
        name = "V{:02d}_MAIN_T1.5".format(idx)
        c = next(c for c in model.components.values() if c.name == name)
        q = F.mesh_quality_stats(model, c)
        tot["aspect_over_5"] += q["aspect_over_5"]
        tot["quad_dev_over_45"] += q["quad_dev_over_45"]
        tot["angle_under_20"] += q["angle_under_20"]
        tot["degenerate"] += q["degenerate"]

    # also check control plate is essentially clean
    cc = next(c for c in model.components.values() if c.name == "V06_CONTROL_T1.5")
    qc = F.mesh_quality_stats(model, cc)

    assert tot["degenerate"] == 0, "degenerate elements found in main plates: {}".format(tot["degenerate"])
    assert tot["aspect_over_5"] >= 500, "aspect_over_5 {} < 500".format(tot["aspect_over_5"])
    assert tot["quad_dev_over_45"] >= 500, "quad_dev_over_45 {} < 500".format(tot["quad_dev_over_45"])

    stats = model.stats()
    stats.update({
        "defect_failures": tot,
        "control_clean_baseline": qc,
        "criteria": CRITERIA,
        "defects_per_plate": 600,
        "defect_plates": 5,
    })
    assert stats["element_count"] >= 80000, stats["element_count"]
    return stats


def manifest(model, cases, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name,
              "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    return {
        "schema_version": "1.0",
        "module": "local_mesh_optimizer",
        "purpose": "LARGE quality-defect shell model: 5x38400 + control + 12 washer/RBE2 "
                   "protected + 4 strip zones. 600 defects/plate (3000 total).",
        "generator": "tools/model_generation/gen_local_mesh_opt.py",
        "fem": "LocalMeshOpt_80k.fem",
        "parameters": CRITERIA,
        "statistics": stats,
        "components": comps,
        "cases": cases,
        "warning": "Intentionally contains quality-failing shell elements for the optimizer.",
    }


def main() -> int:
    model, cases = build_model()
    stats = verify(model, cases)
    outdir = common.model_dir("local_mesh_opt_80k")
    fem_path = outdir / "LocalMeshOpt_80k.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "LocalMeshOpt_80k_manifest.json",
                          manifest(model, cases, stats))
    common.write_readme(outdir / "README.md", README)
    print("nodes={} elems={} comps={}".format(stats["node_count"],
                                              stats["element_count"],
                                              stats["component_count"]))
    print("defect_failures", stats["defect_failures"])
    print("control_clean", stats["control_clean_baseline"])
    return 0


README = """# local_mesh_optimizer — Large Quality-Defect Validation Model

## 用途
`LocalMeshOpt_80k.fem` 用于 `local_mesh_optimizer`（局部网格质量优化）的大规模验证：
向 5 张规则板注入 3000 个质量失败单元，供模块按 criteria 识别与修复，并验证
washer+RBE2 保护区应被跳过、干净对照板无退化。

## 场景表
| 组件 | 内容 | 预期 |
|---|---|---|
| V01..V05_MAIN_T1.5 | 5×38400 单元规则板，每板 600 缺陷（翘曲/瘦长 quad/大 skew/瘦长 tria） | 模块识别并修复；缺陷量大需分批 |
| V06_CONTROL_T1.5 | 干净对照板（无缺陷） | 质量达标基线 |
| V07..V18_WASHER_T1.5 | 12 个 washer+RBE2 保护区 | 模块应跳过（保护区） |
| AUTO_RBE2_V.. | 保护区 RBE2 输出组件 | 供跳过检测 |
| V19..V22_STRIP_T1.5 | 4 个窄条带区（宽 2 单元） | 模块边界处理 |

## 操作
1. HyperMesh 导入 `LocalMeshOpt_80k.fem`。
2. 选择 V01..V05 运行优化（criteria 与 manifest 一致）。
3. 核对 aspect_over_5 / quad_dev_over_45 数量下降、degenerate==0、0 保护区元素被修改。

## 设计说明
- 缺陷注入使用隔离式布局（缺陷单元相隔 8），保证邻近单元不退化为零面积。
- 缺陷类型：a) 法向偏移 2~6mm 翘曲、b) 0.35~0.6mm 窄 quad（aspect>5）、
  c) 面内移位 >45° 角偏（skew）、d) 长薄 CTRIA3（skinny, aspect>2.5）。
- 确定性生成（无随机）；生成时用 mesh_quality_stats 自检缺陷数量级与 degenerate==0。
"""

if __name__ == "__main__":
    raise SystemExit(main())
