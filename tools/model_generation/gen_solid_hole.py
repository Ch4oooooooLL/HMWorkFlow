#!/usr/bin/env python3
"""gen_solid_hole.py -- LARGE solid through-hole -> RIGIDS validation model.

Hexa meshed blocks with regular cylindrical through-holes for the
auto_hole_rbe2 module (wall nodes lie exactly on the cylinder; both end rings
are complete):

  A  V06_BLOCK_A_T40  1560x360x40, 12x3 = 36 holes (D10/D14/D18/D22/D26 mix)
  B  V07_BLOCK_B_T40  1080x120x40, 8 holes D16, one with a pre-placed RBE2
  C  V08_ANGLE_T40    480x120x40, 3 holes rotated 40 deg around X -> reject

Units mm / N / tonne.  Deterministic, stdlib-only.
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

CELL = 120.0
OUTER_SEG = 32

BANDS = [
    (10.0, 12), (14.0, 14), (18.0, 16), (22.0, 16), (26.0, 16),
]


def build_block_a(model: Model, comp: F.Component, origin, cols: int, rows: int) -> List[Dict]:
    holes: List[Tuple[float, float, float, float]] = []
    specs: List[Dict] = []
    for r in range(rows):
        for c in range(cols):
            d, segs = BANDS[(r * cols + c) % len(BANDS)]
            holes.append((origin[0] + (c + 0.5) * CELL, origin[1] + (r + 0.5) * CELL, d / 2.0, segs))
            specs.append({"center": (origin[0] + (c + 0.5) * CELL, origin[1] + (r + 0.5) * CELL),
                          "diameter": d, "segments": segs})
    info = F.hex_block_with_holes(model, comp, origin, cols * CELL, rows * CELL, 40.0,
                                  holes, nz=10, cell_size=CELL, outer_segments=OUTER_SEG)
    for s, rings in zip(specs, info["hole_rings_3d"]):
        s["wall_rings_3d"] = rings
    return specs


def build_block_b(model: Model, comp: F.Component, origin) -> List[Dict]:
    holes: List[Tuple[float, float, float, float]] = []
    specs: List[Dict] = []
    for c in range(8):
        d, segs = 16.0, 16
        holes.append((origin[0] + (c + 0.5) * CELL, origin[1] + 0.5 * CELL, d / 2.0, segs))
        specs.append({"center": (origin[0] + (c + 0.5) * CELL, origin[1] + 0.5 * CELL),
                      "diameter": d, "segments": segs})
    info = F.hex_block_with_holes(model, comp, origin, 8 * CELL, CELL, 40.0,
                                  holes, nz=10, cell_size=CELL, outer_segments=OUTER_SEG)
    for s, rings in zip(specs, info["hole_rings_3d"]):
        s["wall_rings_3d"] = rings
    return specs


def rotate_comp_about_x(model: Model, comp: F.Component, angle_deg: float) -> None:
    """Rotate every node of a component around the global X axis (used to tilt
    a hole axis beyond the module's 35 deg loop-normal limit)."""
    c, s = math.cos(math.radians(angle_deg)), math.sin(math.radians(angle_deg))
    touched = set()
    for el in model.elements_of(comp):
        for n in el.node_ids:
            if n in touched:
                continue
            touched.add(n)
            x, y, z = model.nodes[n]
            model.nodes[n] = (round(x, 9), round(y * c - z * s, 9), round(y * s + z * c, 9))


def place_rbe2(model: Model, out_comp: F.Component, spec: Dict) -> Dict:
    """Pre-place an RBE2 on a hole: independent = axis node at mid height,
    dependents = hole wall nodes (all layers)."""
    cx, cy = spec["center"]
    z_mid = 20.0
    cnode = model.node(cx, cy, z_mid)
    deps = sorted({n for ring in spec["wall_rings_3d"].values() for n in ring})
    eid = model.elem(out_comp, "RBE2", (cnode, "123456", *deps))
    return {"element_id": eid, "independent_node_id": cnode, "dependent_node_ids": deps}


def build_model() -> Tuple[Model, List[Dict], List[Dict]]:
    model = Model("Solid through-hole -> RIGIDS LARGE validation model")
    mat = model.add_material("STEEL")
    cases = []
    existing_rbe2 = []

    # ---- A: 12x3 = 36 mixed-diameter holes --------------------------------
    comp_a = model.add_component("V06_BLOCK_A_T40", 3,
                                 model.add_property("PSOLID", "V06_BLOCK_A_T40_PSOLID", mat.mid))
    specs_a = build_block_a(model, comp_a, (0.0, 0.0, 0.0), 12, 3)
    cases.append({"case_id": "A", "component": comp_a.name, "expected_holes": 36,
                  "title": "正常：36 个规则圆柱贯通孔（D10~D26 混合）",
                  "expected": "识别并创建 36 个 RBE2（壁面节点精确落圆柱面，两端端环完整）"})

    # ---- B: 8 holes D16 + pre-placed RBE2 ---------------------------------
    comp_b = model.add_component("V07_BLOCK_B_T40", 4,
                                 model.add_property("PSOLID", "V07_BLOCK_B_T40_PSOLID", mat.mid))
    specs_b = build_block_b(model, comp_b, (2000.0, 0.0, 0.0))
    out_b = model.add_component("RBE2_HOLE_AUTO", 9)
    existing_rbe2.append(place_rbe2(model, out_b, specs_b[3]))
    cases.append({"case_id": "B", "component": comp_b.name, "expected_holes": 8,
                  "title": "正常 + 跳过：8 孔 D16，其中 1 孔已有预置 RBE2",
                  "expected": "7 个新 RBE2 创建 + 1 个 SKIP_EXISTING"})

    # ---- C: tilted axis (reject) ------------------------------------------
    comp_c = model.add_component("V08_ANGLE_T40", 5,
                                 model.add_property("PSOLID", "V08_ANGLE_T40_PSOLID", mat.mid))
    build_block_b(model, comp_c, (4000.0, 0.0, 0.0))
    rotate_comp_about_x(model, comp_c, 40.0)
    cases.append({"case_id": "C", "component": comp_c.name, "expected_holes": 8,
                  "title": "拒绝：孔轴与端环法向夹角 40°（>35° 门限）",
                  "expected": "全部 8 孔因 loop-normal 夹角超限被拒绝，无 RBE2 创建"})

    all_specs = specs_a + specs_b
    return model, cases, all_specs, existing_rbe2


def verify(model: Model, cases, all_specs, existing_rbe2) -> Dict:
    errors = []
    for spec in all_specs:
        cx, cy = spec["center"]
        r = spec["diameter"] / 2.0
        for layer, ring in spec["wall_rings_3d"].items():
            for nid in ring:
                p = model.nodes[nid]
                radial = math.hypot(p[0] - cx, p[1] - cy)
                if abs(radial - r) > 1e-6:
                    errors.append("hole wall node {} off cylinder (r {} vs {})".format(nid, radial, r))
    for case in cases:
        comp = next(c for c in model.components.values() if c.name == case["component"])
        q = model.stats()
        if not comp.element_ids:
            errors.append("{}: component has no elements".format(case["case_id"]))
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors[:20]))
    stats = model.stats()
    stats.update({"hole_count": len(all_specs) + 8,  # + block C
                  "preplaced_rbe2_count": len(existing_rbe2),
                  "cell_size": CELL, "block_thickness": 40.0})
    return stats


def manifest(model, cases, all_specs, existing_rbe2, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name, "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    return {
        "module": "auto_hole_rbe2",
        "purpose": "LARGE solid through-hole -> RIGIDS validation matrix (36+8+8 holes)",
        "generator": "tools/model_generation/gen_solid_hole.py",
        "fem": "SolidHole_Large.fem",
        "parameters": {"feature_angle_deg": 78.0, "loop_normal_tol_deg": 35.0,
                       "cyl_fit_tol": 0.25, "cell_size": CELL},
        "statistics": stats,
        "components": comps,
        "cases": cases,
        "holes": [{"center": [round(v, 6) for v in s["center"]],
                   "diameter": s["diameter"], "segments": s["segments"]} for s in all_specs],
        "existing_rbe2": existing_rbe2,
        "warning": "Block C (V08_ANGLE_T40) intentionally tilts the hole axis 40 deg for rejection.",
    }


def main():
    model, cases, all_specs, existing_rbe2 = build_model()
    stats = verify(model, cases, all_specs, existing_rbe2)
    outdir = common.model_dir("solid_hole_large")
    fem_path = outdir / "SolidHole_Large.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "SolidHole_Large_manifest.json",
                          manifest(model, cases, all_specs, existing_rbe2, stats))
    common.write_readme(outdir / "README.md", README)
    print({k: v for k, v in stats.items() if not isinstance(v, dict)})
    return 0


README = """# Solid Through-Hole RIGIDS — Large Validation Model

## 用途
`SolidHole_Large.fem` 用于 `auto_hole_rbe2`（实体孔 RIGIDS）的大规模验证：
单块 36 孔六面体网格（壁面节点精确落圆柱面、两端端环完整）。

## 场景（按组件）
| 组件 | 内容 | 预期 |
|---|---|---|
| V06_BLOCK_A_T40 | 12x3=36 孔，D10/D14/D18/D22/D26 混合 | 创建 36 个 RBE2 |
| V07_BLOCK_B_T40 | 8 孔 D16，其中 1 孔预置 RBE2 | 7 创建 + 1 SKIP_EXISTING |
| V08_ANGLE_T40 | 8 孔，孔轴绕 X 转 40° | 全部拒绝（环法向夹角 >35°） |
| RBE2_HOLE_AUTO | 预置 RBE2 输出组件 | 供跳过检测 |

## 操作
1. HyperMesh 导入 `SolidHole_Large.fem`。
2. 选择实体组件运行模块（默认参数：特征角 78°、环法向容差 35°、圆柱拟合容差 0.25）。
3. 核对 A/B 块创建数量、C 块全部拒绝、^faces 临时组件自动清理。

## 设计说明
- 每个孔周围为极坐标网格（孔壁 12~16 段），外圈 morph 到方形格边界，格间为
  笛卡尔条带，全部共形（同一单元尺寸 15mm 节距）。
- 孔壁节点按构造精确落在圆柱面上（生成时自检径向偏差 <1e-6）。
- C 块通过整体绕 X 轴旋转 40° 使孔轴倾斜，触发模块法向门限拒绝。
"""


if __name__ == "__main__":
    raise SystemExit(main())
