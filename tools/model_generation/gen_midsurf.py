#!/usr/bin/env python3
"""gen_midsurf.py -- LARGE sheet-metal solid STEP suite for midsurf (抽中面).

24 thin-wall solid parts (Vxx naming, thickness tokens, one STEP file per
part with the product name = component name).  Covers the module's input
matrix at scale:

  - flat plates / panels with dense hole patterns and slots
  - L / Z / U / hat / multi-step / flanged / ribbed / arc brackets
  - variable-thickness wedge (boundary) and a thick block (reject)
  - material suffixes (AL6061 / Q355) on some names

Units mm.  Built with cadquery (OCCT).  Deterministic.
"""

from __future__ import annotations

import os
import sys
from typing import Dict, List, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import steplib as S

PARTS: List[Dict] = []  # filled after the helper definitions below


def _panel_v11():
    """Big panel: dense hole pattern + elongated slots."""
    part = S.flat_plate(500, 300, 1.5)
    part = S.drill(part, [(x, y, 10) for x in (-200, -100, 0, 100, 200) for y in (-100, 100)])
    for i, x in enumerate((-150, 0, 150)):
        part = S.cut_slot(part, x, 0, 60 + 10 * i, 12)
    return part


def _panel_v21():
    """Channel with holes on the base and on both legs."""
    part = S.channel(180, 60, 280, 1.5, bend_r=2.0,
                     holes=[(-80, 0, 10), (0, 0, 10), (80, 0, 10)])
    # side holes on the legs: leg faces at x = 1.5 (inner) - drill through
    part = S.drill_on_face(part, (1.5, 30, 140), [(-120, 0, 6), (0, 0, 6), (120, 0, 6)])
    part = S.drill_on_face(part, (180 - 1.5, 30, 140), [(-120, 0, 6), (0, 0, 6), (120, 0, 6)])
    return part


def _wedge():
    """Variable-thickness wedge: thickness tapers 1.0 -> 2.5 along the length."""
    return S.solid_from_profile([(0.0, 0.0), (220.0, 0.0), (220.0, 2.5), (0.0, 1.0)], 1.0, 140.0)


def _thick_block():
    """Thick solid block -- the module should skip it (not thin-walled)."""
    return S.chamfer_block(100, 80, 50, fillets=[("|Z", 5.0)])


PARTS[:] = [
    # (name, thickness token used in name, builder callable, case note)
    dict(name="V01_PLATE_T1.5", case="normal",
         build=lambda: S.flat_plate(300, 200, 1.5,
                                    holes=[(-100, -60, 10), (-50, -60, 10), (0, -60, 10), (50, -60, 10),
                                           (100, -60, 10), (-100, 0, 12), (0, 0, 12), (100, 0, 12),
                                           (-100, 60, 10), (-50, 60, 10), (0, 60, 10), (50, 60, 10),
                                           (100, 60, 10)])),
    dict(name="V02_LBRACKET_T2.0", case="normal",
         build=lambda: S.l_bracket(180, 120, 100, 2.0, bend_r=3.0,
                                   holes=[(-60, -30, 8), (0, -30, 8), (60, -30, 8),
                                          (-60, 30, 8), (0, 30, 8), (60, 30, 8)])),
    dict(name="V03_CHANNEL_T1.0_AL6061", case="normal",
         build=lambda: S.channel(160, 70, 240, 1.0, bend_r=2.0,
                                 holes=[(-40, -80, 10), (40, -80, 10), (-40, 0, 10),
                                        (40, 0, 10), (-40, 80, 10), (40, 80, 10)])),
    dict(name="V04_HATRIB_T1.2", case="normal",
         build=lambda: S.hat_rib(320, 50, 100, 30, 1.2, bend_r=2.0,
                                 holes=[(-120, 0, 8), (-60, 0, 8), (0, 0, 8),
                                        (60, 0, 8), (120, 0, 8)])),
    dict(name="V05_ARC_T1.0", case="normal",
         build=lambda: S.arc_bracket(120, 140, 80, 1.0)),
    dict(name="V06_RIBPLATE_T1.5", case="normal",
         build=lambda: S.panel_with_ribs(400, 260, 1.5, 14, 6, 7,
                                         holes=[(-150, -80, 10), (-50, -80, 10), (50, -80, 10), (150, -80, 10),
                                                (-150, 0, 12), (-50, 0, 12), (50, 0, 12), (150, 0, 12),
                                                (-150, 80, 10), (-50, 80, 10), (50, 80, 10), (150, 80, 10)])),
    dict(name="V07_STEP_T1.0", case="normal",
         build=lambda: S.stepped_bracket([(100, 35, 3), (70, 15, 3), (50, 10, 2)], 80, 1.0)),
    dict(name="V08_FLANGE_T2.0", case="normal",
         build=lambda: S.plate_with_flanges(220, 160, 2.0, 40, bend_r=2.5,
                                            holes=[(40, 80, 10), (110, 80, 10), (180, 80, 10)],
                                            flange_holes=[(60, 20, 6), (160, 20, 6)])),
    dict(name="V09_ZBRACKET_T1.5", case="normal",
         build=lambda: S.stepped_bracket([(150, 30, 3), (150, 30, 3)], 90, 1.5,
                                         holes=[(-90, 15, 8), (0, 15, 8), (90, 15, 8)])),
    dict(name="V10_UPANEL_T1.0", case="normal",
         build=lambda: S.channel(200, 50, 300, 1.0, bend_r=2.0,
                                 holes=[(-60, -100, 8), (-60, 0, 8), (-60, 100, 8),
                                        (60, -100, 8), (60, 0, 8), (60, 100, 8)])),
    dict(name="V11_PANEL_T1.5", case="normal", build=_panel_v11),
    dict(name="V12_COVER_T0.8", case="normal",
         build=lambda: S.flat_plate(240, 160, 0.8,
                                    holes=[(x, y, 8) for x in (-80, 0, 80) for y in (-50, 0, 50)])),
    dict(name="V13_BRACKET_T1.2_Q355", case="normal",
         build=lambda: S.l_bracket(140, 90, 70, 1.2, bend_r=2.0,
                                   holes=[(-40, -15, 6), (0, -15, 6), (40, -15, 6)])),
    dict(name="V14_STEP2_T1.5", case="normal",
         build=lambda: S.stepped_bracket([(80, 25, 2), (60, 15, 2), (60, 15, 2), (50, 10, 2)], 70, 1.5)),
    dict(name="V15_DEEPCHANNEL_T1.0", case="normal",
         build=lambda: S.channel(140, 90, 260, 1.0, bend_r=2.0,
                                 holes=[(-45, -90, 8), (-45, 0, 8), (-45, 90, 8),
                                        (45, -90, 8), (45, 0, 8), (45, 90, 8)])),
    dict(name="V16_HATRIB_T2.0", case="normal",
         build=lambda: S.hat_rib(280, 60, 120, 35, 2.0, bend_r=3.0,
                                 holes=[(-100, 0, 10), (-50, 0, 10), (0, 0, 10),
                                        (50, 0, 10), (100, 0, 10)])),
    dict(name="V17_PANEL_T2.5", case="normal",
         build=lambda: S.flat_plate(400, 250, 2.5,
                                    holes=[(x, y, 12) for x in (-120, 0, 120) for y in (-60, 0, 60)])),
    dict(name="V18_STEP3_T1.2", case="normal",
         build=lambda: S.stepped_bracket([(120, 20, 2), (80, 25, 3), (60, 15, 2)], 100, 1.2)),
    dict(name="V19_ARC2_T1.5", case="normal",
         build=lambda: S.arc_bracket(150, 90, 100, 1.5)),
    dict(name="V20_LBRACKET_T1.0", case="normal",
         build=lambda: S.l_bracket(100, 70, 60, 1.0, bend_r=1.5,
                                   holes=[(-30, -12, 6), (0, -12, 6), (30, -12, 6)])),
    dict(name="V21_UPANEL_T1.5", case="normal", build=_panel_v21),
    dict(name="V22_WEDGE_T1_2.5", case="variable_thickness", build=_wedge),
    dict(name="V23_BLOCK_T50", case="reject_thick", build=_thick_block),
    dict(name="V24_HALFPIPE_T3.0", case="normal",
         build=lambda: S.arc_bracket(90, 180, 200, 3.0)),
]


def main():
    outdir = common.model_dir("midsurf_sheetmetal_24parts")
    parts_info = []
    x_cursor = 0.0
    row_y = 0.0
    row = 0
    for spec in PARTS:
        part = spec["build"]()
        info = S.shape_info(part)
        if info["solids"] != 1:
            raise ValueError("{}: expected 1 solid, got {}".format(spec["name"], info["solids"]))
        w = info["bbox"][3] - info["bbox"][0]
        # place parts in rows of 8 with 120 mm gaps
        if row == 8:
            row = 0
            x_cursor = 0.0
            row_y += 320.0
        dx = x_cursor
        dy = row_y
        part = part.translate((dx, dy, 0.0))
        fname = spec["name"] + ".step"
        path = outdir / fname
        S.export_step(part, str(path), spec["name"])
        info = S.verify_step(str(path))
        parts_info.append({"name": spec["name"], "file": fname,
                           "case": spec["case"], "solids": info["solids"],
                           "faces": info["faces"], "bbox": info["bbox"]})
        x_cursor += w + 120.0
        row += 1
        print(spec["name"], info["faces"], "faces", info["bbox"])
    stats = {"part_count": len(PARTS),
             "normal_parts": sum(1 for p in PARTS if p["case"] == "normal"),
             "variable_thickness_parts": sum(1 for p in PARTS if p["case"] == "variable_thickness"),
             "reject_parts": sum(1 for p in PARTS if p["case"] == "reject_thick"),
             "total_faces": sum(p["faces"] for p in parts_info)}
    common.write_manifest(outdir / "midsurf_sheetmetal_24parts_manifest.json", {
        "module": "midsurf",
        "purpose": "LARGE sheet-metal solid suite for midsurface extraction (24 parts)",
        "generator": "tools/model_generation/gen_midsurf.py",
        "files": [p["file"] for p in parts_info],
        "statistics": stats,
        "parts": parts_info,
        "warning": "V23_BLOCK_T50 is intentionally too thick (reject); V22_WEDGE_T1_2.5 is variable thickness.",
    })
    common.write_readme(outdir / "README.md", README)
    print(stats)
    return 0


README = """# Midsurface Extraction — Large Validation Model（24 件钣金）

## 用途
24 个钣金实体（每个独立 .step，导入后组件名 = 文件名 = Vxx 命名），用于
`midsurf`（抽中面）的大规模验证：多级折弯、台阶、翻边、密集孔、筋板、
变厚边界与厚块拒绝。

## 场景
| 组件 | 特征 | 预期 |
|---|---|---|
| V01~V21, V24（21 件） | 平板/L/Z/U/帽形/阶梯/翻边/圆弧/筋板，孔 0~13 个 | 正常抽中面，命名 Vxx_件号_Tx |
| V03 / V13 | 名称带材料后缀（AL6061 / Q355） | 厚度取 _T 标记，材料后缀保留 |
| V22_WEDGE_T1_2.5 | 变厚（1.0→2.5 楔形） | 厚度测量走中位数/体积法，或提示变厚 |
| V23_BLOCK_T50 | 厚实块 100x80x50 | 非薄壁，跳过 |

## 操作
1. HyperMesh 导入 `*.step`（单位 mm；组件名由 STEP 产品名自动生成）。
2. 主面板运行 Midsurface Extraction，选择全部 24 个组件。
3. 核对输出组件进入 MIDSURFED assembly、命名/厚度 token、源几何隐藏。

## 设计说明
- 每个 .step 恰好包含 1 个实体（生成时自检 solids==1）。
- 折弯处带圆角（半径按板厚自动钳制，OCCT 稳健）。
- 布局：8 件/行 × 3 行，间距 ≥120mm，互不接触。
"""


if __name__ == "__main__":
    raise SystemExit(main())
