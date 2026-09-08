#!/usr/bin/env python3
"""gen_adhesive.py -- LARGE area-adhesive validation model for adhesive_connector.

The module takes a set of `location` shell elements plus >= 2 link components.
Every location element's face samples must project (along the plate normal,
within tolerance) onto EVERY link component's shell footprint, otherwise the
whole element is removed ("projection cleaning", tolerance = 50).  The realised
connector creates RBE3 + HEXA8 elements.

This generator authors 4 large shell plates (2000x1200 mm, 10 mm mesh = 24k
elements each => ~96k total):

    A   V01_PLATE_A_T1.5   base plate at z=0 (location elems live here)
    B   V02_PLATE_B_T1.5   link plate over A (z=1), origin (400,150)
    C   V03_PLATE_C_T1.5   link plate over A (z=2), origin (450,160), slightly offset
    D   V04_PLATE_D_T1.5   extra large plate (scale), not a link target

10 adhesive strips are identified on plate A (each 11 elements wide, spanning
the mutual valid length):

    8  in-bound strips inside the common footprint of B AND C -> all elements
       project onto both links and survive.
    2  over-bound strips at plate A's right edge, protruding beyond BOTH B and C
       by ~60..100 mm -> their out-of-footprint elements are cleaned away.

The RBE3 + HEXA8 realise elements are created by the module at run time.
Units mm / N / tonne.  Deterministic, stdlib-only.
"""

from __future__ import annotations

import os
import sys
from typing import Dict, List, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import femlib as F
from femlib import Model

AW, AH = 2000.0, 1200.0          # plate A outer size
MESH = 10.0
PLATE_T = 1.5
NX, NY = int(AW / MESH), int(AH / MESH)      # 200 x 120
TOL = 50.0                                    # module projection tolerance


def plate_bounds(origin, w, h) -> Tuple[float, float, float, float]:
    x0, y0, _ = origin
    return (x0, y0, x0 + w, y0 + h)


def point_inside(px, py, bounds) -> bool:
    bx0, by0, bx1, by1 = bounds
    return bx0 <= px <= bx1 and by0 <= py <= by1


def quads_in(model: Model, grid, x0, x1, y0, y1, all_corners_inside=None):
    """A-grid elements whose first corner lies inside [x0,x1]x[y0,y1]; when
    all_corners_inside is a callable, only elements fully accepted by it are
    returned (used to keep good patches strictly inside every link footprint)."""
    out = []
    for j in range(NY):
        for i in range(NX):
            c = (grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i])
            px = model.nodes[c[0]][0]
            py = model.nodes[c[0]][1]
            if x0 <= px <= x1 and y0 <= py <= y1:
                if all_corners_inside is None or all_corners_inside(c):
                    out.append(c)
    return out


def build_model() -> Dict:
    model = Model("Area-adhesive validation model (10 strips on plate A)")
    mat = model.add_material("STEEL", mid=1)
    comps = {}
    comps["A"] = model.add_component("V01_PLATE_A_T1.5", 3, model.add_property(
        "PSHELL", "V01_PLATE_A_T1.5_PSHELL", mat.mid, thickness=PLATE_T))
    meshA = F.rect_plate_mesh(model, comps["A"], (0.0, 0.0, 0.0), AW, AH, NX, NY)
    comps["B"] = model.add_component("V02_PLATE_B_T1.5", 4, model.add_property(
        "PSHELL", "V02_PLATE_B_T1.5_PSHELL", mat.mid, thickness=PLATE_T))
    F.rect_plate_mesh(model, comps["B"], (0.0, 100.0, 1.0), 1800.0, 1100.0, 180, 110)
    comps["C"] = model.add_component("V03_PLATE_C_T1.5", 5, model.add_property(
        "PSHELL", "V03_PLATE_C_T1.5_PSHELL", mat.mid, thickness=PLATE_T))
    F.rect_plate_mesh(model, comps["C"], (10.0, 110.0, 2.0), 1800.0, 1100.0, 180, 110)
    comps["D"] = model.add_component("V04_PLATE_D_T1.5", 6, model.add_property(
        "PSHELL", "V04_PLATE_D_T1.5_PSHELL", mat.mid, thickness=PLATE_T))
    F.rect_plate_mesh(model, comps["D"], (3000.0, 0.0, -5.0), AW, AH, NX, NY)

    link_bounds = [plate_bounds((0.0, 100.0, 1.0), 1800.0, 1100.0),
                   plate_bounds((10.0, 110.0, 2.0), 1800.0, 1100.0)]
    # mutual valid region = intersection of B and C footprints
    xv0 = max(link_bounds[0][0], link_bounds[1][0])   # 10
    xv1 = min(link_bounds[0][2], link_bounds[1][2])   # 1800
    yv0 = max(link_bounds[0][1], link_bounds[1][1])   # 110
    yv1 = min(link_bounds[0][3], link_bounds[1][3])   # 1200

    def inside_every(corners):
        return _samples_inside(model, corners, link_bounds)

    patches = []
    w_elems = 11
    band = yv1 - yv0
    step = band / 8.0
    for k in range(8):
        y0 = yv0 + k * step + 20.0
        y1 = y0 + w_elems * MESH
        quads = quads_in(model, meshA["grid"], xv0, xv1, y0, y1, inside_every)
        patches.append({"kind": "good", "label": "PATCH{:02d}".format(k + 1),
                        "x": [xv0, xv1], "y": [y0, y1],
                        "elements": quads, "mesh_cells": len(quads)})

    # 2 over-bound strips: start inside the valid x, extend ~100 mm past xv1=1800
    ob_y = [yv0 + 2 * step + 20.0, yv0 + 6 * step + 20.0]
    for k in range(2):
        x0 = xv1 - 30.0
        x1 = x0 + 160.0
        y0 = ob_y[k]
        y1 = y0 + w_elems * MESH
        quads = quads_in(model, meshA["grid"], x0, x1, y0, y1)
        patches.append({"kind": "overbound", "label": "OB{:02d}".format(k + 1),
                        "x": [x0, x1], "y": [y0, y1],
                        "elements": quads, "mesh_cells": len(quads)})

    return {"model": model, "comps": comps, "patches": patches,
            "link_bounds": link_bounds, "x_valid": [xv0, xv1], "y_valid": [yv0, yv1]}


def verify(model: Model, patches, link_bounds) -> Dict:
    errors = []
    good = [p for p in patches if p["kind"] == "good"]
    over = [p for p in patches if p["kind"] == "overbound"]
    if len(good) != 8 or len(over) != 2:
        errors.append("patch split wrong: good={} over={}".format(len(good), len(over)))
    for p in good:
        if not p["elements"]:
            errors.append("{} has no elements".format(p["label"]))
        for corners in p["elements"]:
            if not _samples_inside(model, corners, link_bounds):
                errors.append("{} has an out-of-projection element".format(p["label"]))
                break
    for p in over:
        in_proj = sum(1 for c in p["elements"] if _samples_inside(model, c, link_bounds))
        if in_proj == len(p["elements"]):
            errors.append("{} expected some out-of-projection elements".format(p["label"]))
    total = sum(len(c.element_ids) for c in model.components.values())
    if total < 80000:
        errors.append("total elements {} < 80000".format(total))
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors[:30]))
    stats = model.stats()
    stats.update({"patch_count": len(good), "overbound_strips": len(over),
                  "tolerance": TOL, "links": ["V02_PLATE_B_T1.5", "V03_PLATE_C_T1.5"],
                  "realize": "RBE3 + HEXA8",
                  "good_good_cells": sum(len(p["elements"]) for p in good)})
    return stats


def _samples_inside(model: Model, corners, link_bounds) -> bool:
    """Strict in-plane containment of all 5 face samples inside every link."""
    ps = [model.nodes[n] for n in corners]
    cx = sum(p[0] for p in ps) / 4.0
    cy = sum(p[1] for p in ps) / 4.0
    samples = [(model.nodes[n][0], model.nodes[n][1]) for n in corners] + [(cx, cy)]
    for (sx, sy) in samples:
        for bounds in link_bounds:
            if not point_inside(sx, sy, bounds):
                return False
    return True


def manifest(model: Model, patches, ctx, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name, "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    link_bounds = ctx["link_bounds"]
    patch_list = []
    for p in patches:
        in_proj = sum(1 for c in p["elements"] if _samples_inside(model, c, link_bounds))
        patch_list.append({"label": p["label"], "kind": p["kind"], "x_mm": p["x"], "y_mm": p["y"],
                           "elements": len(p["elements"]), "surviving_after_clean": in_proj})
    return {
        "module": "adhesive_connector",
        "purpose": "LARGE area-adhesive validation model (4 big plates, 10 strips, ~96k shell)",
        "generator": "tools/model_generation/gen_adhesive.py",
        "fem": "Adhesive_8patches.fem",
        "parameters": {"tolerance": TOL, "coats": "default", "realize": "RBE3 + HEXA8",
                       "location_source": "V01_PLATE_A_T1.5", "links": ["V02_PLATE_B_T1.5", "V03_PLATE_C_T1.5"]},
        "statistics": stats,
        "components": comps,
        "patches": patch_list,
        "expected_module_result": "8 in-bound strips survive projection cleaning and are realised into RBE3+HEXA8; "
                                  "2 over-bound strips lose their protruding elements during cleaning.",
        "warning": "RBE3 + HEXA8 realisations are created by the module at run time, not pre-authored here.",
    }


def main():
    ctx = build_model()
    model, patches, link_bounds = ctx["model"], ctx["patches"], ctx["link_bounds"]
    stats = verify(model, patches, link_bounds)
    outdir = common.model_dir("adhesive_8patches")
    fem_path = outdir / "Adhesive_8patches.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "Adhesive_8patches_manifest.json",
                          manifest(model, patches, ctx, stats))
    common.write_readme(outdir / "README.md", README)
    print({k: v for k, v in stats.items() if not isinstance(v, dict)})
    return 0


README = """# Area Adhesive — Large Validation Model

## 用途
`Adhesive_8patches.fem` 用于 `adhesive_connector`（面/胶粘 1D 连接）的大规模验证：
4 块大板（2000x1200、10mm 网格，共约 9.6 万壳单元），板 A 顶面 10 条胶带。

## 场景（板 A 为 location，链路 = 板 B、C）
| 条目 | 内容 | 预期 |
|---|---|---|
| V01_PLATE_A_T1.5 | location 所在基板（z=0） | — |
| V02_PLATE_B_T1.5 / V03_PLATE_C_T1.5 | link 目标板（z=1/2，与 A 间隙 1~2mm，落于 A 投影内） | B、C 为 2 个 link |
| 8 条 `PATCH01..08` | 板 A 中共 B∩C 投影内的胶带 | 全部保留并 realize 成 RBE3+HEXA8 |
| 2 条 `OB01..02` | 板 A 右缘、部分伸出 B/C 投影的胶带 | 越界单元被投影清洗剔除 |

## 操作
1. 导入 `Adhesive_8patches.fem`。
2. "选择 location 单元"：框选板 A 上某条胶带所在壳单元；"选择目标组件"：选 B、C。
3. 执行创建：默认 tolerance=50；核对 8 条带内单元保留、realize 出 RBE3+HEXA8；
   对越界条带核对清洗日志（剔除伸出投影的单元）。

## 设计说明
- location 单元的面采样（4 角 + 形心）须逐点投影到**每个** link 组件的壳内
  （面内严格包含 + 沿法向距离 <= tolerance），否则整单元剔除。
- 板 B、C 相对于板 A 向内侧收拢，使板 A 右缘存在落在两者投影之外的条带。
"""


if __name__ == "__main__":
    raise SystemExit(main())
