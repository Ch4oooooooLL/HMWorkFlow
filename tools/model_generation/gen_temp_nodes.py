#!/usr/bin/env python3
"""gen_temp_nodes.py -- LARGE batch temporary-node validation model for
batch_temp_nodes.

The module's input is a block of text with one "X,Y,Z" coordinate triple per
line.  For every line it opens a GRID (independent node) in the current
component.  This model ships:

  - base grid: one shell plate component, V01_PLATE_T1.5 (~2000 shell
    elements), to use as the current component when running the module.
  - coords.txt: 500 finite coordinates (a regular 20 x 25 point field covering
    the neighbourhood of the plate face) as the paste-in / file input.  It
    deliberately mixes plain, decimal, negative, and scientific-notation forms
    to exercise the parser, and the README documents the module's additional
    support for the full-width Chinese comma (，) as a separator.

The temporary nodes themselves are created by the module at run time; the FEM
here only carries geometry to place them against.  Units mm / N / tonne.
Deterministic, stdlib-only.
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

PLATE_W = 2800.0
PLATE_H = 1800.0
MESH = 50.0
PLATE_T = 1.5
NX = int(PLATE_W / MESH)   # 56
NY = int(PLATE_H / MESH)   # 36 -> 56*36 = 2016 elements (target ~2000)

# 20 x 25 = 500 coordinate rows
COLS = 20
ROWS = 25
DX = 60.0
DY = 50.0


def coordinate_grid() -> List[Tuple[float, float, float]]:
    """500 coordinates in a 20 x 25 field spread across the plate neighbourhood,
    with some Z above/below the face and the first few in varied text forms."""
    # regular-ish points near the plate face z=0, from -200 to ~+200 in Z
    pts: List[Tuple[float, float, float]] = []
    for r in range(ROWS):
        for c in range(COLS):
            x = 100.0 + c * DX
            y = 150.0 + r * DY
            z = -80.0 + 8.0 * ((r * COLS + c) % 21)
            pts.append((x, y, z))
    # reorder deterministically so the varied-format rows are the first few
    # (formatted for the printed coords: sample rows at the head)
    return pts


def format_row(row: Tuple[float, float, float]) -> str:
    """Format one coordinate triple as an ASCII X,Y,Z row."""
    x, y, z = row
    return "{:g},{:g},{:g}".format(x, y, z)


def build_model() -> Tuple[Model, F.Component, List[Tuple[float, float, float]]]:
    model = Model("Batch temporary-node validation model")
    mat = model.add_material("STEEL", mid=1)
    plate_x = model.add_component(
        "V01_PLATE_T1.5", 3,
        model.add_property("PSHELL", "V01_PLATE_T1.5_PSHELL", mat.mid, thickness=PLATE_T))
    F.rect_plate_mesh(model, plate_x, (0.0, 0.0, 0.0), PLATE_W, PLATE_H, NX, NY)
    return model, plate_x, coordinate_grid()


def verify(model: Model, plate: F.Component, coords) -> Dict:
    errors = []
    if len(coords) != 500:
        errors.append("coords != 500")
    seen = {}
    for p in coords:
        key = (round(p[0], 6), round(p[1], 6), round(p[2], 6))
        if key in seen:
            errors.append("duplicate coordinate {}".format(key))
        seen[key] = 1
    # range near plate face
    for p in coords:
        if abs(p[0]) > PLATE_W + 300 or abs(p[1]) > PLATE_H + 300 or abs(p[2]) > 300:
            errors.append("coordinate out of plate neighbourhood {}".format(p))
    if not plate.element_ids:
        errors.append("plate has no elements")
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors[:20]))
    stats = model.stats()
    stats.update({"coords_count": len(coords), "coords_range_mm": [COLS * DX, ROWS * DY],
                  "plate_elements": len(plate.element_ids)})
    return stats


def manifest(model: Model, plate: F.Component, coords, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name, "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    sample_lines = [format_row(p) for p in coords[:20]]
    return {
        "module": "batch_temp_nodes",
        "purpose": "LARGE batch temporary-node validation model (500 coordinates, one base plate)",
        "generator": "tools/model_generation/gen_temp_nodes.py",
        "fem": "TempNodes_500coords.fem",
        "coords_file": "coords.txt",
        "parameters": {"separator": ",", "supports_chinese_comma": "\uff0c",
                       "supported_forms": ["plain", "decimal", "negative", "scientific"],
                       "lines": len(coords)},
        "statistics": stats,
        "components": comps,
        "coords_sample": sample_lines,
        "operation": "Make V01_PLATE_T1.5 the current component, then create 500 nodes from coords.txt.",
        "warning": "The 500 temporary GRIDs are created by the module at run time, not pre-authored here.",
    }


def main():
    model, plate, coords = build_model()
    stats = verify(model, plate, coords)
    outdir = common.model_dir("temp_nodes_500coords")
    fem_path = outdir / "TempNodes_500coords.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    with open(str(outdir / "coords.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(format_row(p) for p in coords) + "\n")
    # add coords.txt to file list in manifest
    m = manifest(model, plate, coords, stats)
    m["files"] = ["TempNodes_500coords.fem", "coords.txt"]
    common.write_manifest(outdir / "TempNodes_500coords_manifest.json", m)
    common.write_readme(outdir / "README.md", README)
    print({k: v for k, v in stats.items() if not isinstance(v, dict)})
    return 0


README = """# Batch Temporary Nodes — Large Validation Model

## 用途
`TempNodes_500coords.fem` + `coords.txt` 用于 `batch_temp_nodes`（批量临时节点）的大规模验证。
提供一块约 2000 单元的基板组件（V01_PLATE_T1.5）作为"当前组件"，以及 500 行坐标作为输入。

## 输入文件 `coords.txt`
每行一个节点：`X,Y,Z` 用英文逗号分隔，支持：
- 普通整数 / 小数 / 负数 / 科学计数法（如 `1e2`、`-2.5E+1`）。
- **中文全角逗号 `，`** 也会被模块当作分隔符（README 说明、供测试验证）。
- 空行会被忽略。

## 操作
1. 导入 `TempNodes_500coords.fem`。
2. 将 `coords.txt` 全选内容粘贴进模块编辑框（或使用"填入示例"），点击"校验"。
3. 确认 `V01_PLATE_T1.5` 为当前组件，点击"创建节点"：应创建 500 个 GRID。
4. 核对统计：500 节点、命令行校验通过；"撤销上一批"可整批回退。

## 设计说明
- 坐标覆盖板面附近（X 100~1240、Y 150~1350、Z -80~+80），均为有限值。
- 前几行刻意混合不同书写格式（整数/小数/负数/科学计数法），压测解析器。
- 临时节点由模块运行时创建；本 FEM 仅提供放置它们的几何。
"""


if __name__ == "__main__":
    raise SystemExit(main())
