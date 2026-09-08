#!/usr/bin/env python3
"""gen_preprocess.py -- geometry_preprocess LARGE component-management FEM model.

40 shell components (each plate meshed 5x8=40 elements on a 10mm grid):

  - 20 normal components      V01_PANEL_T1.5 ... (Vxx proper naming)
  - 12 same-name family       V10_PANEL family x3, each base + .1 + .2 + .3
                              (4 pieces/family) -> preprocess archives the
                              duplicates into a USELESS assembly
  - 8  SKELL skeleton         names containing "SKELL" (case-insensitive) ->
                              archived as skeleton (SKELL) components

geometry_preprocess operates purely on component management (display-coordinate
rotation + same-name/SKELL archiving), so a single .fem input is sufficient.
The two-step rotation (X+90° then Z-90° on the "current display" selection) is
applied interactively by the user; its exact angles are documented in README.

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

NX, NY = 5, 8          # grid -> 40 elements per plate
CELL = 10.0
PLATE_W = NX * CELL    # 50
PLATE_H = NY * CELL    # 80

SKELL_TAGS = [
    "SKELL_FRAME_1", "REAR_SKELL_2", "Skell_Main_3", "skell_bracket_4",
    "SKELL_RIB_5", "BODY_SKELL_6", "skell_firewall_7", "SKELL_Dash_8",
]
FAMILY_BASES = ["V10_PANEL", "V11_PANEL", "V12_PANEL"]

# normal components: 20 proper Vxx names
NORMAL_NAMES = [
    "V01_PANEL_T1.5", "V02_BRACKET_T2.0", "V03_COVER_T1.0", "V04_FLOOR_T2.5",
    "V05_RIB_T1.2", "V06_SIDE_T3.0", "V07_ROOF_T1.0", "V08_GUSSET_T1.5",
    "V09_BASE_T2.0", "V10_STRUT_T1.5", "V11_DOOR_T1.0", "V12_HOOD_T2.0",
    "V13_SPAR_T1.5", "V14_BULKHEAD_T3.0", "V15_PANEL_T1.0", "V16_BRKT_T1.2",
    "V17_SKIN_T1.5", "V18_FRAME_T2.0", "V19_BAFFLE_T1.0", "V20_DECK_T2.5",
]


def add_plate(model: Model, comp: F.Component, origin: Tuple[float, float, float],
              z: float = 0.0) -> Dict[str, object]:
    return F.rect_plate_mesh(model, comp, origin, PLATE_W, PLATE_H, NX, NY, z=z)


def build_model() -> Tuple[Model, Dict]:
    model = Model("geometry_preprocess LARGE component-management FEM model")
    mat = model.add_material("STEEL")

    def new_comp(name: str, color: int) -> F.Component:
        # one PSHELL per component: HyperMesh links a property to the
        # component of the same id on .fem import (shared props land in misc)
        return model.add_component(
            name, color,
            model.add_property("PSHELL", name + "_PSHELL", mat.mid, thickness=1.5))

    cursor_y = 0.0  # lay plates in a vertical stack, 110 mm pitch
    normal = []
    skell = []
    families = []

    # ---- 20 normal components ---------------------------------------------
    for name in NORMAL_NAMES:
        comp = new_comp(name, 1)
        add_plate(model, comp, (0.0, cursor_y, 0.0))
        normal.append({"name": name, "component_id": comp.cid,
                       "element_count": len(comp.element_ids)})
        cursor_y += PLATE_H + 30.0

    # ---- 12 same-name family components (base + .1 + .2 + .3) -------------
    for base in FAMILY_BASES:
        members = []
        for suffix in ("", ".1", ".2", ".3"):
            name = base + suffix
            comp = new_comp(name, 2)
            add_plate(model, comp, (PLATE_W + 60.0, cursor_y, 0.0))
            members.append({"suffix": suffix, "name": name, "component_id": comp.cid,
                            "element_count": len(comp.element_ids)})
            cursor_y += PLATE_H + 10.0
        families.append({"base": base, "member_count": len(members),
                         "members": members})
        cursor_y += 30.0

    # ---- 8 SKELL skeleton components --------------------------------------
    for name in SKELL_TAGS:
        comp = new_comp(name, 5)
        add_plate(model, comp, (2 * PLATE_W + 120.0, cursor_y, 0.0))
        skell.append({"name": name, "component_id": comp.cid,
                      "element_count": len(comp.element_ids)})
        cursor_y += PLATE_H + 30.0

    layout = {"normal": normal, "skell": skell, "families": families}
    return model, layout


def verify(model: Model, layout: Dict) -> Dict:
    errors = []
    comps = model.components
    total = len(comps)
    if total != 40:
        errors.append("expected 40 components, got {}".format(total))

    # normal: 20, proper Vxx naming
    normal = layout["normal"]
    if len(normal) != 20:
        errors.append("expected 20 normal components, got {}".format(len(normal)))
    for n in normal:
        if not re.match(r"^V\d{2}_.+", n["name"]):
            errors.append("normal component name not proper Vxx: " + n["name"])
        if len(comps[n["component_id"]].element_ids) != 40:
            errors.append("normal comp {} element count != 40".format(n["name"]))

    # same-name family: 12 comps, each family base + .1+.2+.3
    total_fam = 0
    fam_names = set()
    for fam in layout["families"]:
        base = fam["base"]
        for m in fam["members"]:
            total_fam += 1
            fam_names.add(m["name"])
            if len(comps[m["component_id"]].element_ids) != 40:
                errors.append("family comp {} element count != 40".format(m["name"]))
        # members must include base + .1+.2+.3
        expected = {base, base + ".1", base + ".2", base + ".3"}
        got = {m["name"] for m in fam["members"]}
        if got != expected:
            errors.append("family {} members mismatch: {}".format(base, got))
    if total_fam != 12:
        errors.append("expected 12 same-name family components, got {}".format(total_fam))
    if len(fam_names) != 12:
        errors.append("same-name family names are not unique across families")

    # SKELL: 8, names contain "skell" case-insensitive
    skell = layout["skell"]
    if len(skell) != 8:
        errors.append("expected 8 SKELL components, got {}".format(len(skell)))
    for s in skell:
        if "skell" not in s["name"].lower():
            errors.append("SKELL component name lacks 'skell': " + s["name"])
        if len(comps[s["component_id"]].element_ids) != 40:
            errors.append("SKELL comp {} element count != 40".format(s["name"]))

    total_elems = sum(1 for c in comps.values() for _ in c.element_ids)
    if total_elems != 40 * 40:
        errors.append("expected 1600 elements, got {}".format(total_elems))

    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors[:40]))

    return model.stats()


def manifest(model: Model, layout: Dict, stats: Dict, outdir) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name, "element_count": len(c.element_ids),
              "kind": _kind(c.name)}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    return {
        "module": "geometry_preprocess",
        "purpose": "LARGE FEM for component management: 40 comps, rotation + same-name/SKELL archiving",
        "generator": "tools/model_generation/gen_preprocess.py",
        "fem": "Preprocess_40comp.fem",
        "parameters": {
            "grid": [NX, NY], "cell_mm": CELL,
            "rotation_note": "user applies to current display: X+90 then Z-90",
            "useless_assembly": "USELESS",
            "skell_assembly": "SKELL",
        },
        "statistics": stats,
        "components": comps,
        "same_name_families": [{"base": f["base"], "member_count": f["member_count"]}
                               for f in layout["families"]],
        "normal_component_count": len(layout["normal"]),
        "skell_component_count": len(layout["skell"]),
        "manifest_path": str(outdir / "preprocess_40comp_manifest.json"),
    }


def _kind(name: str) -> str:
    if "skell" in name.lower():
        return "SKELL"
    if re.match(r"^V10_PANEL(\.\d)?$|^V11_PANEL(\.\d)?$|^V12_PANEL(\.\d)?$", name):
        return "same_name_family"
    return "normal"


def main() -> int:
    model, layout = build_model()
    stats = verify(model, layout)
    outdir = common.model_dir("preprocess_40comp")
    fem_path = outdir / "Preprocess_40comp.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "preprocess_40comp_manifest.json",
                          manifest(model, layout, stats, outdir))
    common.write_readme(outdir / "README.md", README)
    print({"component_count": stats["component_count"],
           "element_count": stats["element_count"],
           "normal": len(layout["normal"]),
           "same_name_family": 12,
           "skell": len(layout["skell"])})
    return 0


README = """# geometry_preprocess — 大模型验证（组件管理 / 40 个壳组件）

## 用途
`Preprocess_40comp.fem`（40 个壳组件，每板 5×8=40 个 CQUAD4，10mm 网格）
用于 `geometry_preprocess` 的组件管理验证：

| 类别 | 数量 | 组件命名 | 预期模块动作 |
|---|---|---|---|
| 正常组件 | 20 | V01~V20（Vxx_Part_Tx，命名规范） | 保留 |
| 同名族 | 12 | 3 族 × 4 件（基名 + .1 + .2 + .3） | 同名组件归档进 **USELESS** assembly |
| SKELL 骨架 | 8 | 名称含 "SKELL"（不区分大小写） | 归档为 SKELL 骨架组件 |

## 坐标旋转（两步，作用于"当前显示"）
geometry_preprocess 只对**当前显示的组件**做显示坐标系旋转。导入本模型后，
在模块中选择要旋转的组件集（"当前显示"）：
1. 绕 X 轴 +90°；
2. 再绕 Z 轴 −90°（合计使原 Y 朝上转为 Z 朝上，视原始摆放可二选一/按需交换顺序）。
> 说明：旋转是显示坐标变换，不改变网格节点全局坐标；README 仅记录您应执行的两步角度。

## 操作
1. HyperMesh 导入 `Preprocess_40comp.fem`。
2. geometry_preprocess：核对组件列表、对当前显示组件做两步旋转（X+90°→Z−90°）。
3. 运行同名族归档（V10_PANEL 族系引入 USELESS assembly）与 SKELL 骨架归档。

## 设计说明
- 三族同名组件（V10/V11/V12_PANEL）各含基名 + .1 + .2 + .3，共 12 件；模块应把它们
  识别为同名重复并归入 USELESS，避免命名冲突。
- 8 个 SKELL 组件大小写混合（Skell/skell/SKELL），验证不区分大小写的匹配。
- 规模：40 组件 × 40 单元 = 1600 单元（自检组件数、名称族匹配、单元总数）。
"""


if __name__ == "__main__":
    raise SystemExit(main())
