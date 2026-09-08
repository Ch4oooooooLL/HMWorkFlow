#!/usr/bin/env python3
"""gen_bolt_chain.py -- LARGE pre-placed RBE2 -> coaxial CBEAM bolt-chain
validation model for the rbe2_bolt_connector module.

A 4-storey stack of shell plates, each carrying a 12x12 washer-hole matrix.
Every hole carries ONE pre-placed planar RBE2 (independent = hole centre node,
dependents = hole ring + washer ring 1).  The four storeys are coaxially stacked
at 120 mm layer pitch, so the 4 x 144 = 576 RBE2s collapse into 144 coaxial
groups of 4; the module must emit 144 x 3 = 432 CBEAM segments (one between
consecutive members of each group) into per-diameter output components.

Storey arrangement (each column is ONE diameter across ALL four storeys, which
is what lets the module's diameter vote produce clean per-diameter components):

    Layers 0..3 : column diameter grid on the 12x12 hole matrix
                  col 0,6 -> D10 ; col 1,7 -> D16 ; col 2,8 -> D22 ;
                  remaining cols (3,4,5,9,10,11) -> D12.
    => 24 D10 groups, 24 D16 groups, 24 D22 groups, 72 D12 groups = 144 groups.

Negative cases (in a separate plate region, pre-placed RBE2s only, no beams):
  3 transverse-offset RBE2 pairs   (10 mm cross-axis > offsetTol 5 -> reject)
  2 isolated RBE2s                 (single member -> below minGroupSize 2)

Only planar RBE2 groups may produce beam segments; a purely spatial group is
rejected (SPATIAL_ONLY).  Units mm / N / tonne.  Deterministic, stdlib-only.
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

CELL = 120.0          # washer cell size (matches the plate being 12 x CELL wide)
OUTER_SEG = 32
PLATE_T = 1.5
LAYER_PITCH = 120.0   # Z spacing between the four storeys

DIAMETERS = {"D10": 10.0, "D12": 12.0, "D16": 16.0, "D22": 22.0}


def column_diameter(col: int) -> str:
    """Per-column diameter across all four storeys (so each coaxial group is a
    clean single-diameter vote)."""
    if col in (0, 6):
        return "D10"
    if col in (1, 7):
        return "D16"
    if col in (2, 8):
        return "D22"
    return "D12"


def washer_spec(band: str) -> Tuple[float, int, Tuple[float, float]]:
    # density follows config/washer_rules.txt for 6<D<=13 / 13<D<=20 bands
    if band == "D10":
        return (10.0, 10, (4.0, 6.0))
    if band == "D12":
        return (12.0, 10, (4.0, 6.0))
    if band == "D16":
        return (16.0, 12, (6.0, 8.0))
    return (22.0, 12, (6.0, 8.0))  # D22 -> 12 segments for 13<D<=20


def cell_center(origin: Tuple[float, float, float], col: int, row: int) -> Tuple[float, float, float]:
    return (origin[0] + (col + 0.5) * CELL, origin[1] + (row + 0.5) * CELL, origin[2])


def build_layer_plate(model: Model, comp: F.Component, origin: Tuple[float, float, float]) -> List[Dict]:
    """12x12 washer holes on a shell plate; returns per-hole dicts with the
    pre-placed RBE2 already created inside `comp`."""
    holes = []
    for row in range(12):
        for col in range(12):
            band = column_diameter(col)
            dia, segs, widths = washer_spec(band)
            center = cell_center(origin, col, row)
            info = F.washer_hole_cell(model, comp, center, dia, segs, widths, CELL, OUTER_SEG)
            # pre-placed planar RBE2
            cnode = model.node(center[0], center[1], center[2])
            deps = sorted(set(info["inner_loop_node_ids"]) | set(info["washer_loop_1_node_ids"]))
            eid = model.elem(comp, "RBE2", (cnode, "123456", *deps))
            holes.append({
                "center": center, "band": band, "diameter": dia,
                "col": col, "row": row, "element_id": eid,
                "independent_node_id": cnode, "dependent_count": len(deps),
            })
    return holes


def build_negative_plate(model: Model, comp: F.Component, origin: Tuple[float, float, float]) -> Tuple[List[Dict], List[Dict]]:
    """Standalone washer holes for the negative cases.  Returns (offset_pairs,
    isolated).  `origin` is the bottom-left of this small plate region.  Each
    cell (120x120) holds one washer; the whole region is meshed on one plate."""
    offset_pairs: List[Dict] = []
    isolated: List[Dict] = []
    # cell coordinates (col,row) in this region
    cells = {}

    def place(band: str, cx: float, cy: float, z: float) -> Dict:
        dia, segs, widths = washer_spec(band)
        center = (cx, cy, z)
        info = F.washer_hole_cell(model, comp, center, dia, segs, widths, CELL, OUTER_SEG)
        cnode = model.node(center[0], center[1], center[2])
        deps = sorted(set(info["inner_loop_node_ids"]) | set(info["washer_loop_1_node_ids"]))
        eid = model.elem(comp, "RBE2", (cnode, "123456", *deps))
        return {"center": center, "band": band, "element_id": eid,
                "independent_node_id": cnode, "dependent_count": len(deps)}

    # --- 3 offset pairs: two RBE2s with 10 mm cross-axis offset (> offsetTol 5)
    oy = origin[1] + 0.5 * CELL
    for p in range(3):
        bx = origin[0] + (p + 0.5) * CELL
        # member A at nominal column (z=0), member B displaced +10 mm in X at z=pitch
        a = place("D12", bx, oy, 0.0)
        b = place("D12", bx + 10.0, oy + 10.0, LAYER_PITCH)
        offset_pairs.append({"members": [a, b], "cross_offset_mm": 10.0})

    # --- 2 isolated RBE2s: single member, no partner along Z
    iso_y = origin[1] + 1.5 * CELL
    iso_x = origin[0] + 0.5 * CELL
    isolated.append(place("D12", iso_x, iso_y, 0.0))
    isolated.append(place("D12", iso_x + CELL, iso_y, 0.0))
    return offset_pairs, isolated


def build_model() -> Tuple[Model, List[Dict], List[Dict], List[Dict], List[Dict]]:
    model = Model("Coaxial RBE2 bolt-chain LARGE validation model")
    mat = model.add_material("STEEL")
    layers = []

    for layer in range(4):
        z0 = layer * LAYER_PITCH
        cname = "V{0:02d}_BOLT_L{1}_T{2}".format(layer + 1, layer, "1.5")
        comp = model.add_component(cname, 3 + layer,
                                   model.add_property("PSHELL", cname + "_PSHELL", mat.mid, thickness=PLATE_T))
        holes = build_layer_plate(model, comp, (0.0, 0.0, z0))
        layers.append({"layer": layer, "component": comp, "origin": (0.0, 0.0, z0), "holes": holes})

    # negative region plate
    neg_comp = model.add_component("V05_BOLT_NEG_T1.5", 8,
                                   model.add_property("PSHELL", "V05_BOLT_NEG_T1.5_PSHELL", mat.mid,
                                                      thickness=PLATE_T))
    offset_pairs, isolated = build_negative_plate(model, neg_comp, (2000.0, 0.0, 0.0))
    return model, layers, offset_pairs, isolated


def verify(model: Model, layers, offset_pairs, isolated) -> Dict:
    errors = []

    # 1) RBE2 totals
    rbe2s = [el for el in model.elements.values() if el.card == "RBE2"]
    if len(rbe2s) != 576 + len(offset_pairs) * 2 + len(isolated):
        errors.append("RBE2 total {} != 576 + 6 + 2".format(len(rbe2s)))

    # 2) per-main-layer hole & RBE2 counts and coaxial assertion
    layer_hole_count = None
    for lay in layers:
        hs = lay["holes"]
        if layer_hole_count is None:
            layer_hole_count = len(hs)
        if len(hs) != 144:
            errors.append("layer {} has {} holes != 144".format(lay["layer"], len(hs)))
        # same storey -> distinct z's already guaranteed by construction; check x,y
        # coalesce down to 144 column positions across the 4 layers
    # coaxial assertion: every main-layer hole shares (x,y) with the same hole
    # on every other layer (columns agree column-wise).
    cols = {}
    for lay in layers:
        for h in lay["holes"]:
            cols.setdefault((h["col"], h["row"]), []).append(lay["layer"])
    for (col, row), ls in cols.items():
        passes = 0
        for lay in layers:
            h = next(x for x in layers[lay["layer"]]["holes"] if x["col"] == col and x["row"] == row)
            p = model.nodes[h["independent_node_id"]]
            q = model.nodes[next(x for x in layers[0]["holes"] if x["col"] == col and x["row"] == row)["independent_node_id"]]
            if abs(p[0] - q[0]) < 1e-9 and abs(p[1] - q[1]) < 1e-9:
                passes += 1
        if passes != len(ls):
            errors.append("column ({},{}) not coaxial across storeys".format(col, row))

    # 3) negative cases sanity
    if len(offset_pairs) != 3:
        errors.append("offset pairs != 3")
    for pr in offset_pairs:
        pa, pb = pr["members"]
        a = model.nodes[pa["independent_node_id"]]
        b = model.nodes[pb["independent_node_id"]]
        if math.hypot(a[0] - b[0], a[1] - b[1]) <= 5.0:
            errors.append("offset pair cross offset not > offsetTol(5)")
    if len(isolated) != 2:
        errors.append("isolated != 2")

    # degenerate-shell sanity on the main plates
    for lay in layers:
        q = F.mesh_quality_stats(model, lay["component"])
        if q["degenerate"]:
            errors.append("layer {} degenerate elements".format(lay["layer"]))

    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors[:30]))
    stats = model.stats()
    stats.update({
        "rbe2_count": len([e for e in model.elements.values() if e.card == "RBE2"]),
        "preplaced_rbe2_count": 576,
        "coaxial_groups": 144,          # 12x12 columns
        "expected_segments": 144 * 3,   # 432 CBEAM from module
        "offset_pair_count": len(offset_pairs),
        "isolated_count": len(isolated),
        "layer_pitch_mm": LAYER_PITCH,
        "plate_x_y_mm": [1440.0, 1440.0],
        "cell_size": CELL,
    })
    return stats


def manifest(model: Model, layers, offset_pairs, isolated, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name, "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    # diameter -> group/segment expectations
    per_dia = {}
    for band in ("D10", "D16", "D22", "D12"):
        ncols = sum(1 for c in range(12) if column_diameter(c) == band)
        per_dia[band] = {"groups": ncols * 12, "expected_segments": ncols * 12 * 3,
                         "output_component": "BOLT_{}_CBEAM".format(band)}
    return {
        "module": "rbe2_bolt_connector",
        "purpose": "LARGE pre-placed RBE2 coaxial bolt-chain validation matrix (576 RBE2 -> 432 CBEAM)",
        "generator": "tools/model_generation/gen_bolt_chain.py",
        "fem": "BoltChain_576rbe2.fem",
        "parameters": {"gapTol": 100.0, "offsetTol": 5.0, "minGroupSize": 2,
                       "radialAbsTol": 0.5, "radialRelTol": 0.08,
                       "minBeamLength": 0.001, "axisMode": "AUTO", "elemType": "CBEAM",
                       "compPrefix": "BOLT"},
        "statistics": stats,
        "components": comps,
        "layers": [{"layer": l["layer"], "component": l["component"].name,
                    "holes": len(l["holes"]), "origin": [round(v, 3) for v in l["origin"]]}
                   for l in layers],
        "diameter_output": per_dia,
        "negative_cases": {
            "offset_pairs": [{"cross_offset_mm": p["cross_offset_mm"],
                              "members": len(p["members"])} for p in offset_pairs],
            "isolated_rbe2": len(isolated),
        },
        "expected_module_result": "144 coaxial groups -> 432 CBEAM segments into BOLT_D10/D12/D16/D22_CBEAM; "
                                  "3 offset pairs + 2 isolated RBE2s rejected (no segments); "
                                  "spatial-only groups rejected as SPATIAL_ONLY.",
        "warning": "Pre-placed RBE2s are inputs, not outputs.  Output CBEAM components (BOLT_Dxx_CBEAM) and "
                   "properties (BOLT_Dxx_PBEAM) are created by the module at run time, not authored here.",
    }


def main():
    model, layers, offset_pairs, isolated = build_model()
    stats = verify(model, layers, offset_pairs, isolated)
    outdir = common.model_dir("bolt_chain_576rbe2")
    fem_path = outdir / "BoltChain_576rbe2.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "BoltChain_576rbe2_manifest.json",
                          manifest(model, layers, offset_pairs, isolated, stats))
    common.write_readme(outdir / "README.md", README)
    print({k: v for k, v in stats.items() if not isinstance(v, dict)})
    return 0


README = """# Coaxial RBE2 Bolt-Chain — Large Validation Model

## 用途
`BoltChain_576rbe2.fem` 用于 `rbe2_bolt_connector`（RBE2 共轴分组建段）的大规模验证。
四层壳板各带 12x12 预置 RBE2（孔环+第一层 washer 环为依赖、孔中心节点为独立），隔层
120mm 共轴堆叠，576 个 RBE2 折叠成 144 个共轴组，每组 4 个 RBE2 -> 模块应创建 D 段 CBEAM。

## 场景
| 区域 / 组件 | 内容 | 机器预期 |
|---|---|---|
| V01..V04_BOLT_L0..L3_T1.5 | 4 层 x 12x12 孔，孔内预置平面 RBE2 | 144 共轴组 -> 432 段 CBEAM |
| V05_BOLT_NEG_T1.5 | 3 组横向偏移 10mm 的 RBE2 对 + 2 个孤立 RBE2 | 全部拒绝，不建段 |

柱径分配（每个柱四层同径，保证直径投票输出干净的多组件）：
- col 0,6 - D10；col 1,7 - D16；col 2,8 - D22；其余 col 3,4,5,9,10,11 - D12。
- 各产出 `BOLT_D10_CBEAM` / `BOLT_D16_CBEAM` / `BOLT_D22_CBEAM` / `BOLT_D12_CBEAM`。

## 操作
1. HyperMesh 导入 `BoltChain_576rbe2.fem`。
2. 选择 RBE2 或含 RBE2 的组件（默认参数：gapTol=100、offsetTol=5、minGroupSize=2、
   radialAbsTol=0.5/radialRelTol=0.08、elemType=CBEAM、axisMode=AUTO）。
3. 核对：144 组 -> 432 段；按直径分入 4 个输出组件；3 个偏移对与 2 个孤立 RBE2 被拒绝。

## 设计说明
- 预置 RBE2 是**输入**；输出 CBEAM/PBEAM/BOLT_Dxx 组件由模块运行时创建，不在本文件预置。
- 依赖节点 = 孔环 + 第一层 washer 环；独立节点 = 孔中心（浮动 GRID）。
- 只有平面 RBE2 组参与建段；纯空间组被拒绝（SPATIAL_ONLY）。
- washer 密度按 `config/washer_rules.txt`（D10/D12=10 段，D16/D22=12 段）。
"""


if __name__ == "__main__":
    raise SystemExit(main())
