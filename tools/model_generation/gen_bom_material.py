#!/usr/bin/env python3
"""gen_bom_material.py -- bom_material_assignment LARGE FEM model + setup.tcl.

40 shell components (each plate meshed 8x10=80 elements on a 10mm grid):

  - 30 thickness components  Vxx_Part_T<1.0..3.0> gradient; 10 of them already
                             carry a material suffix (_STEEL, _Q235, _AL6061)
                             that the module must REPLACE with _Q355
  - 5  no-thickness          V21_PART ... V25_PART -> flagged for review but
                             still assigned Q355
  - 5  weld (SEAM)           SEAM_T1.5 ... OUTSIDE the MIDSURFED assembly ->
                             NOT processed

bom_material_assignment operates on the MIDSURFED assembly only.  Assemblies
are HM-only entities and are NOT persisted in the .fem, so this suite ships a
setup.tcl that best-effort creates MIDSURFED and adds the 35 target comps.

Target material: Q355  MAT1 E=206000 NU=0.30 RHO=7.85e-9.  Units mm/N/tonne.
"""
from __future__ import annotations

import os
import re
import sys
from typing import Dict, List, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import femlib as F
from femlib import Model

NX, NY = 8, 10
CELL = 10.0
PLATE_W, PLATE_H = NX * CELL, NY * CELL

Q355 = {"E": 206000.0, "nu": 0.30, "rho": 7.85e-9}
MATERIALS = ["STEEL", "Q235", "AL6061", "STEEL", "Q235", "AL6061", "STEEL", "Q235", "AL6061", "STEEL"]

PIECE = ["PANEL", "BRACKET", "COVER", "FLOOR", "RIB", "SIDE", "ROOF", "GUSSET", "BASE", "STRUT",
         "DOOR", "HOOD", "SPAR", "BULKHEAD", "SHELL", "BRKT", "SKIN", "FRAME", "BAFFLE", "DECK",
         "CLAMP", "SUPPORT", "WALL", "LID", "PLATE", "GIRDER", "RAIL", "TRAY", "GUARD", "WEB"]


def thickness_for(idx: int) -> float:
    """1.0 .. 3.0 gradient across idx 1..30."""
    return round(1.0 + 2.0 * (idx - 1) / 29.0, 2)


def build_comp_name(idx: int, mats: Dict[int, str]) -> str:
    t = thickness_for(idx)
    base = "V{:02d}_{}_T{}".format(idx, PIECE[idx - 1], format(t, "g"))
    return base + ("_" + mats[idx] if idx in mats else "")


def build_model() -> Tuple[Model, Dict, List[Dict]]:
    model = Model("bom_material_assignment LARGE FEM model (MIDSURFED -> Q355)")
    mat_steel = model.add_material("STEEL")  # default pre-assignment material
    # Q355 is the target the module assigns; included so the deck is self-contained
    mat_q355 = model.add_material("Q355", **Q355)

    def new_comp(name: str, color: int) -> F.Component:
        # one PSHELL per component: HyperMesh links a property to the
        # component of the same id on .fem import (shared props land in misc)
        return model.add_component(
            name, color,
            model.add_property("PSHELL", name + "_PSHELL", mat_steel.mid, thickness=1.5))

    # 10 of the 30 thickness comps carry a material suffix (non-Q355)
    mat_suffix_idx = [1, 2, 4, 8, 12, 16, 20, 23, 27, 30]
    mat_for_idx = {i: MATERIALS[k] for k, i in enumerate(mat_suffix_idx)}

    target = []      # 30 thickness + 5 no-thickness = 35 -> join MIDSURFED
    non_target = []  # 5 SEAM weld -> outside

    cursor_y = 0.0

    # ---- 30 thickness components (Vxx_Part_T<1.0..3.0>) -------------------
    for idx in range(1, 31):
        name = build_comp_name(idx, mat_for_idx)
        comp = new_comp(name, 1)
        F.rect_plate_mesh(model, comp, (0.0, cursor_y, 0.0), PLATE_W, PLATE_H, NX, NY)
        had_suffix = idx in mat_for_idx
        target.append({"component_id": comp.cid, "name": name,
                       "thickness": thickness_for(idx),
                       "existing_material_suffix": mat_for_idx.get(idx),
                       "has_material_suffix": had_suffix,
                       "expected_name": re.sub(r"(_(STEEL|Q235|AL6061|Q355))?$", "", name)
                                        + "_Q355"
                          if not had_suffix else
                          re.sub(r"_(STEEL|Q235|AL6061|Q355)$", "", name) + "_Q355"})
        cursor_y += PLATE_H + 20.0

    # ---- 5 no-thickness components (V21_PART ... V25_PART) ----------------
    for k in range(1, 6):
        name = "V2{}_PART".format(k)
        comp = new_comp(name, 6)
        F.rect_plate_mesh(model, comp, (PLATE_W + 120.0, cursor_y, 0.0), PLATE_W, PLATE_H, NX, NY)
        target.append({"component_id": comp.cid, "name": name, "thickness": None,
                       "existing_material_suffix": None, "has_material_suffix": False,
                       "expected_name": name + "_Q355", "no_thickness": True})
        cursor_y += PLATE_H + 20.0

    # ---- 5 SEAM weld components (OUTSIDE MIDSURFED) -----------------------
    for k, t in enumerate(("1.0", "1.5", "2.0", "2.5", "3.0")):
        name = "SEAM_T{}".format(t)
        comp = new_comp(name, 3)
        F.rect_plate_mesh(model, comp, (2 * PLATE_W + 240.0, cursor_y, 0.0), PLATE_W, PLATE_H, NX, NY)
        non_target.append({"component_id": comp.cid, "name": name,
                           "reason": "outside_midsurfed"})
        cursor_y += PLATE_H + 20.0

    layout = {"target": target, "non_target": non_target, "mat_q355_mid": mat_q355.mid}
    return model, layout


def verify(model: Model, layout: Dict) -> Dict:
    errors = []
    comps = model.components
    if len(comps) != 40:
        errors.append("expected 40 components, got {}".format(len(comps)))
    if len(layout["target"]) != 35:
        errors.append("expected 35 target components, got {}".format(len(layout["target"])))
    if len(layout["non_target"]) != 5:
        errors.append("expected 5 non-target components, got {}".format(len(layout["non_target"])))
    if len(comps[layout["target"][0]["component_id"]].element_ids) != 80:
        errors.append("expected 80 elements per plate")
    total = sum(len(comps[cid].element_ids) for cid in comps)
    if total != 40 * 80:
        errors.append("expected 3200 elements, got {}".format(total))
    # expected_name sanity
    for t in layout["target"]:
        if not t["expected_name"].endswith("_Q355"):
            errors.append("expected name lacks _Q355: " + t["expected_name"])
        if t["existing_material_suffix"] and t["existing_material_suffix"] == "Q355":
            errors.append("suffix should not already be Q355: {}".format(t["name"]))
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors[:40]))
    stats = model.stats()
    stats.update({"target_components": 35, "non_target_components": 5,
                  "material_target": "Q355", "q355_mid": layout["mat_q355_mid"]})
    return stats


def setup_tcl(layout: Dict) -> str:
    ids = " ".join(str(t["component_id"]) for t in layout["target"])
    return """# setup.tcl -- prepare the MIDSURFED assembly for bom_material_assignment.
# Assemblies are HyperMesh-only entities and are NOT persisted in the .fem, so
# they must be (re)built at import time.  Best effort: if the command names
# differ on your HM build, create a MIDSURFED assembly manually and add the
# 35 target components below (use Model Browser -> right click -> Add to
# existing assembly, or drag components onto the assembly node).
# Execution: File -> Run -> Tcl script (or paste your whole import block).

# 1) create the MIDSURFED assembly if it does not already exist
if {![hm_entityexists assemblies MIDSURFED]} {
    *createentity assemblies name=MIDSURFED
}

# 2) add the 35 target components (the whole MIDSURFED scan set)
eval *assemblyaddmembers MIDSURFED comps """ + ids + """

puts "MIDSURFED assembly populated with 35 target components."
puts "Run bom_material_assignment to assign Q355 (E=206000 Nu=0.30 Rho=7.85e-9)."
"""


def manifest(layout: Dict, stats: Dict) -> Dict:
    return {
        "module": "bom_material_assignment",
        "purpose": "LARGE FEM for MIDSURFED-wide Q355 material assignment (40 comps)",
        "generator": "tools/model_generation/gen_bom_material.py",
        "fem": "BomMaterial_40comp.fem",
        "setup_tcl": "setup.tcl",
        "parameters": {"material": "Q355", "mat1": Q355,
                       "grid": [NX, NY], "cell_mm": CELL},
        "statistics": stats,
        "target_components": layout["target"],
        "non_target_components": layout["non_target"],
        "note": "35 target comps join MIDSURFED via setup.tcl; 5 weld (SEAM) comps stay outside and are NOT processed.",
    }


def main() -> int:
    model, layout = build_model()
    stats = verify(model, layout)
    outdir = common.model_dir("bom_material_40comp")
    fem_path = outdir / "BomMaterial_40comp.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "bom_material_40comp_manifest.json", manifest(layout, stats))
    common.write_setup_tcl(outdir / "setup.tcl", setup_tcl(layout))
    common.write_readme(outdir / "README.md", README)
    print({"component_count": stats["component_count"],
           "element_count": stats["element_count"],
           "target": 35, "non_target": 5,
           "with_material_suffix": sum(1 for t in layout["target"] if t["has_material_suffix"])})
    return 0


README = """# bom_material_assignment — 大模型验证（40 组件 / 统一赋 Q355）

## 用途
`BomMaterial_40comp.fem` + `setup.tcl` 用于 `bom_material_assignment` 的规模验证：
扫描 **MIDSURFED** assembly 内的组件 → 统一赋材料 Q355（`MAT1 E=206000 NU=0.30 RHO=7.85e-9`）、
组件名追加/替换为 `_Q355` 后缀。

## 场景（40 组件 / 每板 8×10=80 单元）
| 类别 | 数量 | 命名 | 模块预期 |
|---|---|---|---|
| 厚度件（目标，入 MIDSURFED） | 30 | `Vxx_Part_T1.0~T3.0`，其中 10 个已带材料后缀（_STEEL/_Q235/_AL6061） | 已带后缀 → 替换为 `_Q355`；无后缀 → 追加 `_Q355` |
| 无厚度件（目标） | 5 | `V21_PART`~`V25_PART`（不含 _T） | 列入复核清单但照常赋 Q355 → `_Q355` |
| 焊缝件（非目标） | 5 | `SEAM_T1.0`~`SEAM_T3.0`（在 MIDSURFED 外） | **不处理** |

## 操作
1. HyperMesh 导入 `BomMaterial_40comp.fem`，然后运行 `setup.tcl` 重建 **MIDSURFED**
   assembly 并把 35 个目标组件加入（`*createentity assemblies name=MIDSURFED` +
   `*assemblyaddmembers MIDSURFED comps <ids>`）。
   > 若你的 HM 版本命令名不符，请手工在 Model Browser 建 MIDSURFED assembly 并把
   > 35 个目标组件拖入（见 manifest target_components）。
2. 运行 bom_material_assignment（目标：MIDSURFED assembly）。
3. 核对 35 个目标组件统一赋 Q355 且名字尾随 `_Q355`；5 个 SEAM 组件保持不动。

## 设计说明
- assembly 是 HM 专属实体，.fem 不持久化 → 必须用 setup.tcl 在每次导入后重建。
- 10 个已带非 Q355 材料后缀的组件用于验证"材料后缀替换"逻辑。
- 5 个无厚度件验证复核路径；5 个 SEAM 件验证 assembly 外组件不处理。
- 规模自检：40 组件、3200 单元、目标/非目标清单与 `_Q355` 期望写入 manifest。
"""


if __name__ == "__main__":
    raise SystemExit(main())

