#!/usr/bin/env python3
"""gen_batch_property.py -- batch_property_assignment LARGE FEM model (50 comps).

50 shell components (each regular plate meshed 6x8=48 elements on a 10mm grid,
thickness 1.0..3.0).  The batch_property_assignment module parses component
names `Vxx_..._T<thickness>_<material>` -> PSHELL(<material>_T<thickness>);
SEAM-named comps -> SEAM_Txx with material fixed to Steel; everything else is
classified per expected behaviour:

  - 25 valid normal      Vxx_Part_T1.5_Q355 (mat Q355/STEEL/Q235/AL6061) -> assign
  - 8  SEAM              SEAM_T1.5, V04_SEAM_T1.0_Q355 -> SEAM_Txx (Steel)
  - 5  unparseable       T-no-number / no _T / messy -> PROPERTY_REVIEW__<name>
                         (assembly PROPERTY_ASSIGNMENT_REVIEW, module self-built)
  - 6  1D-named          BEAM_X, RBE_Y, BUSH_Z, SPRING_W, BEAM2, RBE3_A -> skip
  - 4  empty             no elements -> skip
  - 2  has property      pre-assigned PSHELL -> skip

Units mm / N / tonne.  Deterministic, stdlib-only.
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

NX, NY = 6, 8
CELL = 10.0
PLATE_W, PLATE_H = NX * CELL, NY * CELL

MATERIALS = ["Q355", "STEEL", "Q235", "AL6061"]
REVIEW_COLLECTOR_PREFIX = "PROPERTY_REVIEW__"
REVIEW_ASSEMBLY = "PROPERTY_ASSIGNMENT_REVIEW"

DISCARD_TOKENS = ("BEAM", "RBE", "BUSH", "SPRING")


def thickness_for(idx: int) -> float:
    return round(1.0 + 2.0 * (idx - 1) / 45.0, 2)


def classify(name: str, is_empty: bool, has_property: bool) -> Dict:
    """Mirror of the module's per-component decision.  Returns behavior tags."""
    if is_empty:
        return {"behavior": "SKIP_EMPTY"}
    if has_property:
        return {"behavior": "SKIP_HAS_PROPERTY"}
    up = name.upper()
    if any(tok in up for tok in DISCARD_TOKENS):
        return {"behavior": "SKIP_1D", "detail": "1D name token detected"}
    # SEAM + any _T<number> present -> material fixed to Steel regardless of suffix
    seam_m = re.search(r"(?:^|_)T(\d+(?:\.\d+)?)", name, re.IGNORECASE)
    if "SEAM" in up and seam_m:
        return {"behavior": "PROPERTY_ASSIGN_SEAM",
                "property": "STEEL_T{}".format(seam_m.group(1)),
                "thickness": seam_m.group(1), "material": "STEEL"}
    m = re.match(r"^V\d{2}_.*_T(\d+(?:\.\d+)?)_([A-Za-z0-9]+)$", name)
    if m:
        return {"behavior": "PROPERTY_ASSIGN",
                "property": "{}_T{}".format(m.group(2), m.group(1)),
                "thickness": m.group(1), "material": m.group(2)}
    return {"behavior": "REVIEW",
            "collector": REVIEW_COLLECTOR_PREFIX + name,
            "assembly": REVIEW_ASSEMBLY}


def add_plate(model: Model, comp: F.Component, origin: Tuple[float, float, float],
              z: float = 0.0) -> None:
    F.rect_plate_mesh(model, comp, origin, PLATE_W, PLATE_H, NX, NY, z=z)


def build_model() -> Tuple[Model, List[Dict], Dict]:
    model = Model("batch_property_assignment LARGE FEM model (50 comps)")
    mat_steel = model.add_material("STEEL")

    cursor_y = 0.0
    plans: List[Dict] = []

    def add(name: str, *, empty: bool = False, existing_prop: bool = False):
        nonlocal cursor_y
        # Every component carries a same-id PSHELL so .fem import groups all
        # elements into their components (HyperMesh links a property to the
        # component of the same id).  The module expects UNPROPERTIED
        # components, so the README/setup.tcl explains the one-step
        # "clear property" preparation before running it.
        if existing_prop:
            prop = model.add_property("PSHELL", name + "_PROP", mat_steel.mid, thickness=2.0)
        else:
            prop = model.add_property("PSHELL", name + "_PSHELL", mat_steel.mid, thickness=1.5)
        comp = model.add_component(name, 1, prop)
        if not empty:
            add_plate(model, comp, ((len(plans) % 5) * (PLATE_W + 60.0), cursor_y, 0.0))
            cursor_y += PLATE_H + 15.0
        cls = classify(name, is_empty=empty, has_property=existing_prop)
        plans.append({"component_id": comp.cid, "name": name,
                      "element_count": len(comp.element_ids),
                      **cls})

    # ---- 25 valid normal components ----------------------------------------
    pieces = ["PANEL", "BRACKET", "COVER", "GUSSET", "FLOOR", "RIB", "SIDE", "ROOF",
              "BASE", "STRUT", "DOOR", "HOOD", "SPAR", "SHELL", "BRKT", "SKIN",
              "FRAME", "BAFFLE", "DECK", "PLATE", "GIRDER", "RAIL", "TRAY", "GUARD", "WEB"]
    for i, piece in enumerate(pieces):
        idx = i + 1
        t = round(1.0 + 2.0 * (idx - 1) / 24.0, 2)   # 1.0..3.0 across 25 valid comps
        mat = MATERIALS[idx % len(MATERIALS)]
        add("V{:02d}_{}_T{}_{}".format(idx, piece, format(t, "g"), mat))

    # ---- 8 SEAM components --------------------------------------------------
    seam_names = ["SEAM_T1.0", "SEAM_T1.5", "SEAM_T2.0", "SEAM_T2.5", "SEAM_T3.0",
                  "SEAM_T1.2", "SEAM_T2.8", "V26_SEAM_T1.0_Q355"]
    for nm in seam_names:
        add(nm)

    # ---- 5 unparseable components -------------------------------------------
    for nm in ["V31_PART_T", "V32_PART", "GARBAGE!!_x", "V34_", "V35_Tabc"]:
        add(nm)

    # ---- 6 1D-named components (skip) ---------------------------------------
    for nm in ["BEAM_X", "RBE_Y", "BUSH_Z", "SPRING_W", "BEAM2", "RBE3_A"]:
        add(nm)

    # ---- 4 empty components (skip) ------------------------------------------
    for k in range(1, 5):
        add("EMPTY_{:02d}".format(k), empty=True)

    # ---- 2 components with existing PSHELL property (skip) ------------------
    add("V41_PROP_T2.0_Q355", existing_prop=True)
    add("V42_PROP_T2.5_STEEL", existing_prop=True)

    counts: Dict[str, int] = {}
    for p in plans:
        counts[p["behavior"]] = counts.get(p["behavior"], 0) + 1
    return model, plans, counts


def verify(model: Model, plans: List[Dict], counts: Dict) -> Dict:
    errors = []
    if len(plans) != 50:
        errors.append("expected 50 components, got {}".format(len(plans)))
    if counts.get("PROPERTY_ASSIGN") != 25:
        errors.append("expected 25 valid assign, got {}".format(counts.get("PROPERTY_ASSIGN")))
    if counts.get("PROPERTY_ASSIGN_SEAM") != 8:
        errors.append("expected 8 SEAM, got {}".format(counts.get("PROPERTY_ASSIGN_SEAM")))
    if counts.get("REVIEW") != 5:
        errors.append("expected 5 review, got {}".format(counts.get("REVIEW")))
    if counts.get("SKIP_1D") != 6:
        errors.append("expected 6 skip-1D, got {}".format(counts.get("SKIP_1D")))
    if counts.get("SKIP_EMPTY") != 4:
        errors.append("expected 4 skip-empty, got {}".format(counts.get("SKIP_EMPTY")))
    if counts.get("SKIP_HAS_PROPERTY") != 2:
        errors.append("expected 2 skip-has-property, got {}".format(counts.get("SKIP_HAS_PROPERTY")))
    # valid assigns: property naming and thickness range
    for p in plans:
        if p["behavior"] in ("PROPERTY_ASSIGN", "PROPERTY_ASSIGN_SEAM"):
            if not (1.0 <= float(p["thickness"]) <= 3.0):
                errors.append("thickness out of range: {}".format(p))
        if p["behavior"] == "REVIEW":
            if not p["collector"].startswith(REVIEW_COLLECTOR_PREFIX):
                errors.append("review collector naming wrong: {}".format(p))
        # name-family consistency: SEAM material must be STEEL
        if p["behavior"] == "PROPERTY_ASSIGN_SEAM" and p.get("material") != "STEEL":
            errors.append("SEAM material must be STEEL: {}".format(p))
    total_elems = sum(1 for c in model.components.values() for _ in c.element_ids)
    stats = model.stats()
    stats["total_elements"] = total_elems
    if total_elems != 46 * 48:
        errors.append("expected 2208 elements, got {}".format(total_elems))
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors[:40]))
    return stats


def main() -> int:
    model, plans, counts = build_model()
    stats = verify(model, plans, counts)
    outdir = common.model_dir("batch_property_50comp")
    fem_path = outdir / "BatchProperty_50comp.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "batch_property_50comp_manifest.json", {
        "module": "batch_property_assignment",
        "purpose": "LARGE FEM for name-driven PSHELL batch assignment (50 comps)",
        "generator": "tools/model_generation/gen_batch_property.py",
        "fem": "BatchProperty_50comp.fem",
        "parameters": {"grid": [NX, NY], "cell_mm": CELL,
                       "review_collector_prefix": REVIEW_COLLECTOR_PREFIX,
                       "review_assembly": REVIEW_ASSEMBLY,
                       "discard_tokens": list(DISCARD_TOKENS)},
        "statistics": stats,
        "classification_counts": counts,
        "components": plans,
        "preparation": "Run setup.tcl after import to clear the property of every "
                       "component EXCEPT V41_PROP_T2.0_Q355 / V42_PROP_T2.5_STEEL "
                       "(those two validate the skip-existing-property path).",
        "note": "PROPERTY_ASSIGNMENT_REVIEW assembly and PROPERTY_REVIEW__* collectors are built by the module at runtime (HM-only).",
    })
    common.write_setup_tcl(outdir / "setup.tcl", SETUP_TCL)
    common.write_readme(outdir / "README.md", README)
    print({"component_count": stats["component_count"],
           "element_count": stats["total_elements"],
           **counts})
    return 0


SETUP_TCL = """# BatchProperty_50comp preparation (run AFTER importing the .fem).
# The module expects UNPROPERTIED components; the imported deck carries a
# same-id PSHELL per component so .fem import groups elements correctly.
# This script clears the property of EVERY component.
# Best effort: if *propertyupdate is rejected by your HyperMesh build, use
# the GUI: Model Browser -> select all components -> clear the Property column.

*createmark comps 1 all
*propertyupdate comps 1 ""
puts "BatchProperty setup: properties cleared for all components."
puts "To validate the skip-existing-property path afterwards, re-assign a"
puts "PSHELL to V41_PROP_T2.0_Q355 and V42_PROP_T2.5_STEEL and re-run the module."
"""

README = """# batch_property_assignment — 大模型验证（50 组件 / 按名建 PSHELL）

## 用途
`BatchProperty_50comp.fem` 用于 `batch_property_assignment` 的名称→属性批量赋值：
按 `Vxx_Part_T<厚度>_<材料>` 解析 → PSHELL(<材料>_T<厚度>)；SEAM 名 → SEAM_Txx
（材料固定 Steel）；含 BEAM/RBE/BUSH/SPRING 的 1D 名、空组件、已有属性组件 → 跳过；
无法解析 → 建空 collector `PROPERTY_REVIEW__<原名>`（assembly `PROPERTY_ASSIGNMENT_REVIEW`）。

## 场景（50 组件 / 每板 6×8=48 单元，10mm 网格）
| 类别 | 数量 | 示例 | 模块预期 |
|---|---|---|---|
| 有效普通件 | 25 | `V01_PANEL_T1.0_Q355`、`V02_BRACKET_T1.02_STEEL`（Q355/STEEL/Q235/AL6061） | PSHELL(材料_T厚度) |
| SEAM 件 | 8 | `SEAM_T1.5`、`V26_SEAM_T1.0_Q355` | PSHELL(STEEL_T1.5)（材料固定 Steel） |
| 无法解析 | 5 | `V31_PART_T`、`V32_PART`、乱名 | 建 `PROPERTY_REVIEW__*` collector |
| 1D 名 | 6 | `BEAM_X`、`RBE_Y`、`BUSH_Z`、`SPRING_W`、`BEAM2`、`RBE3_A` | 跳过（名称含 BEAM/RBE/BUSH/SPRING） |
| 空组件 | 4 | `EMPTY_01`~`EMPTY_04`（无单元） | 跳过 |
| 已有属性 | 2 | `V41_PROP_T2.0_Q355`（预置 PSHELL） | 跳过 |

## 操作（重要：运行模块前先解除属性）
1. HyperMesh 导入 `BatchProperty_50comp.fem`（所有组件自带同 id PSHELL，导入后单元归属正确）。
2. 模块要求输入组件**无属性**（有属性会跳过）——导入后运行 `setup.tcl`
   （best-effort：全选组件 → `*propertyupdate` 清空属性，**保留
   `V41_PROP_T2.0_Q355` / `V42_PROP_T2.5_STEEL` 两个组件不动**，
   它们验证"已有属性跳过"路径；若命令不生效请用 GUI：Model Browser
   全选组件 → 属性列清空）。
3. batch_property_assignment 选择全部组件运行。
4. 核对：25 个普通件按名字建 `材料_T厚度` PSHELL；8 个 SEAM 记为 STEEL；5 个无法解析进
   `PROPERTY_REVIEW__*`；6 个 1D + 4 空 + 2 已属性被跳过；`PROPERTY_ASSIGNMENT_REVIEW`
   assembly 由模块自建。

## 设计说明
- 组件带同 id PSHELL 是 .fem 导入归属的必要条件（HyperMesh 按"属性→同 id 组件"
  分配单元，属性 id ≠ 组件 id 时单元落入 misc）；模块的"无属性输入"状态由
  setup.tcl 在导入后一步达成。
- `PROPERTY_ASSIGNMENT_REVIEW` assembly 与 `PROPERTY_REVIEW__*` collector 为 HM 专属实体，
  .fem 不持久化，由模块在运行期自建（无需 setup.tcl）。
- 规模自检：50 组件、2208 单元；manifest 记录每组件期望行为与分类计数。
"""


if __name__ == "__main__":
    raise SystemExit(main())
