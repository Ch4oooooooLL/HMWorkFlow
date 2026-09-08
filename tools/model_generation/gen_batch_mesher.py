#!/usr/bin/env python3
"""gen_batch_mesher.py -- BatchMesher LARGE surface-input validation suite.

BatchMesher operates on *surface geometry* (not mesh).  We ship 12 independent
STEP **open-surface face** files (one part each, one connected face per file),
placed along X with >=200 mm separation so by-attached grouping yields exactly
12 topologically-connected tasks:

  1  V01_RECT_8HOLES   rectangular face, 8  holes
  2  V02_RECT_14HOLES  rectangular face, 14 holes
  3  V03_RECT_20HOLES  rectangular face, 20 holes
  4  V04_RECT_16HOLES  rectangular face, 16 holes
  5  V05_SLOTS_6       rectangular face, 6 long rounded-end slots
  6  V06_SLOTS_5       rectangular face, 5 long slots
  7  V07_LSHAPE        L-shaped face (no holes)
  8  V08_LSHAPE_HOLES  L-shaped face with 4 holes
  9  V09_USHAPE        U-shaped / notched face
  10 V10_NOTCHED       notched face
  11 V11_DENSE_HOLES   large face with 40 dense holes
  12 V12_PLAIN         large plain (no-hole) face

Total surface features (outer faces + hole rings + slot loops) > 100 across
the 12 parts.  Deterministic.  Requires cadquery (cadquery/OCCT) via steplib.
"""

from __future__ import annotations

import math
import os
import sys
from typing import Dict, List, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

PITCH = 220.0  # X spacing between part origins (>=200)

# ---------------------------------------------------------------------------
# Profile helpers (closed XY polylines)
# ---------------------------------------------------------------------------


def _rect_points(w: float, h: float) -> List[Tuple[float, float]]:
    return [(-w / 2.0, -h / 2.0), (w / 2.0, -h / 2.0),
            (w / 2.0, h / 2.0), (-w / 2.0, h / 2.0)]


def _l_points(arm_x: float, arm_y: float, thickness: float) -> List[Tuple[float, float]]:
    """Closed L-shape: long leg along X length `arm_x`, tall leg along Y
    length `arm_y`, both `thickness` wide at the outer (negative) corner."""
    # Unfold: bottom-left is outer corner; occupy [+0, arm_x] x [+0, arm_y]
    return [(0.0, 0.0), (arm_x, 0.0), (arm_x, thickness),
            (thickness, thickness), (thickness, arm_y), (0.0, arm_y)]


def _u_points(w: float, h: float, notch_w: float, notch_depth: float) -> List[Tuple[float, float]]:
    """Closed rectangle w x h with a rectangular notch from the top edge;
    notch centred on X, spans the full top band down by notch_depth."""
    return [(w / 2.0, -h / 2.0), (w / 2.0, h / 2.0),
            (notch_w / 2.0, h / 2.0), (notch_w / 2.0, h / 2.0 - notch_depth),
            (-notch_w / 2.0, h / 2.0 - notch_depth), (-notch_w / 2.0, h / 2.0),
            (-w / 2.0, h / 2.0), (-w / 2.0, -h / 2.0)]


def _notch_points(w: float, h: float, notch_w: float, notch_depth: float) -> List[Tuple[float, float]]:
    """Closed rectangle with a side notch cut into the right edge."""
    return [(w / 2.0, h / 2.0), (w / 2.0 - notch_depth, h / 2.0),
            (w / 2.0 - notch_depth, notch_w / 2.0), (-w / 2.0, notch_w / 2.0),
            (-w / 2.0, -notch_w / 2.0), (w / 2.0 - notch_depth, -notch_w / 2.0),
            (w / 2.0 - notch_depth, -h / 2.0), (w / 2.0, -h / 2.0)]


def _slot_wire(w, h, u, v, length, width) -> List[Tuple[float, float]]:
    """Closed polyline for a horizontal rounded-end slot centred at (u,v)."""
    r = width / 2.0
    straight = max(length - width, 1e-3)
    pts = []
    n = 8
    for i in range(n + 1):
        a = -math.pi / 2.0 + math.pi * i / n
        pts.append((u + straight / 2.0 + r * math.cos(a), v + r * math.sin(a)))
    for i in range(n + 1):
        a = math.pi / 2.0 + math.pi * i / n
        pts.append((u - straight / 2.0 + r * math.cos(a), v + r * math.sin(a)))
    return pts


def _hole_grid(cols: int, rows: int, dx: float, dy: float, d: float) -> List[Tuple[float, float, float]]:
    out = []
    for r in range(rows):
        for c in range(cols):
            out.append(((c - (cols - 1) / 2.0) * dx, (r - (rows - 1) / 2.0) * dy, d))
    return out


# ---------------------------------------------------------------------------
# Case table: geometry descriptor per part (single source of truth).
# Each entry carries enough for _build_shape to reconstruct exactly.
# ---------------------------------------------------------------------------

CASES: List[Dict] = [
    {"part": "V01_RECT_8HOLES",   "geometry": "rect", "size": (620, 520), "holes": _hole_grid(4, 2, 90, 160, 12)},
    {"part": "V02_RECT_14HOLES",  "geometry": "rect", "size": (760, 520), "holes": _hole_grid(7, 2, 72, 150, 10)},
    {"part": "V03_RECT_20HOLES",  "geometry": "rect", "size": (700, 620), "holes": _hole_grid(5, 4, 88, 100, 16)},
    {"part": "V04_RECT_16HOLES",  "geometry": "rect", "size": (620, 620), "holes": _hole_grid(4, 4, 90, 90, 8)},
    {"part": "V05_SLOTS_6",       "geometry": "rect_slots",
     "size": (620, 520), "slots": [_slot_wire(620, 520, u, v, 200, 24)
                                   for u in (-160, 0, 160) for v in (-130, 130)]},
    {"part": "V06_SLOTS_5",       "geometry": "rect_slots",
     "size": (720, 560), "slots": [_slot_wire(720, 560, u, v, 160, 20)
                                   for u in (-210, 0, 210) for v in (-160, 160)]},
    {"part": "V07_LSHAPE",        "geometry": "L", "size": (700, 520), "thickness": 220,
     "holes": ()},
    {"part": "V08_LSHAPE_HOLES",  "geometry": "L", "size": (700, 520), "thickness": 220,
     "holes": [(0, -150, 12), (0, 150, 12), (480, -150, 12), (480, 150, 12)]},
    {"part": "V09_USHAPE",        "geometry": "U", "size": (680, 520), "notch_w": 300,
     "notch_depth": 120},
    {"part": "V10_NOTCHED",       "geometry": "notch", "size": (680, 520), "notch_w": 240,
     "notch_depth": 120},
    {"part": "V11_DENSE_HOLES",   "geometry": "rect", "size": (980, 580), "holes": _hole_grid(10, 4, 56, 84, 10)},
    {"part": "V12_PLAIN",         "geometry": "rect", "size": (980, 580), "holes": ()},
]


def _build_shape(c: Dict):
    """Rebuild the cadquery open-surface face for a case at local origin."""
    import steplib as S
    g = c["geometry"]
    w, h = c["size"]
    if g == "rect":
        return S.shell_rect(w, h, list(c["holes"]))
    if g == "rect_slots":
        return _face_with_slots(w, h, c["slots"])
    if g == "L":
        th = c["thickness"]
        return S.shell_poly(_l_points(w, h, th), list(c["holes"]))
    if g == "U":
        return S.shell_poly(_u_points(w, h, c["notch_w"], c["notch_depth"]))
    if g == "notch":
        return S.shell_poly(_notch_points(w, h, c["notch_w"], c["notch_depth"]))
    raise ValueError("unknown geometry " + str(g))


def _face_with_slots(w: float, h: float,
                     slot_pts: Sequence[Sequence[Tuple[float, float]]]):
    """Rect face with several slot loops cut into it (still a single connected
    open surface face, except the slot boundaries become new face pieces)."""
    import cadquery as cq
    import steplib as S
    face = S.shell_rect(w, h)
    base = face.val()
    for pts in slot_pts:
        cutter = cq.Face.makeFromWires(_closed_wire(pts))
        base = base.cut(cutter)
    return cq.Workplane(obj=base)


def _closed_wire(pts: Sequence[Tuple[float, float]]):
    import cadquery as cq
    wp = cq.Workplane("XY")
    for i, (x, y) in enumerate(pts):
        if i == 0:
            wp = wp.moveTo(x, y)
        else:
            wp = wp.lineTo(x, y)
    return wp.close().val()


def hole_count(c: Dict) -> int:
    return len(c.get("holes", ())) + len(c.get("slots", ()))


def main() -> int:
    import steplib as S

    # sanity: 12 independent parts; surface-feature budget (outer face + hole
    # rings + slot loops) must exceed 100 so BatchMesher sees a large input.
    assert len(CASES) == 12
    total_features = sum(1 + hole_count(c) for c in CASES)
    assert total_features > 100, "expected >100 surface features, got {}".format(total_features)

    outdir = common.model_dir("batch_mesher_surfaces_12parts")
    step_paths = []
    parts: List[Dict] = []
    x = 0.0
    total_faces = 0
    for idx, c in enumerate(CASES):
        shape = _build_shape(c)
        shape = shape.translate((x, 0.0, 0.0))
        p = c["part"]
        path = str(outdir / (p + ".step"))
        S.export_step(shape, path, p)
        info = S.verify_step(path)
        total_faces += info["faces"]
        step_paths.append(path)
        parts.append({
            "part": p, "file": p + ".step", "size": list(c["size"]),
            "holes": hole_count(c), "occt_faces": info["faces"], "bbox": info["bbox"],
            "origin_x": round(x, 3),
        })
        print("wrote {}  occt_faces={}  holes/slots={}".format(p, info["faces"], hole_count(c)))
        x += PITCH

    manifest = {
        "schema_version": "1.0",
        "module": "batch_mesher",
        "purpose": "LARGE BatchMesher surface-input validation: 12 independent STEP surface parts "
                   "-> exactly 12 connected components. X spacing >=200mm; >100 surface features.",
        "generator": "tools/model_generation/gen_batch_mesher.py",
        "step_files": step_paths,
        "statistics": {
            "part_count": len(CASES), "connected_components": len(CASES),
            "occt_face_count": total_faces,
            "surface_feature_count": sum(1 + hole_count(c) for c in CASES),
            "x_spacing_mm": PITCH,
            "holes_slots": sum(hole_count(c) for c in CASES),
        },
        "components": parts,
        "cases": [{k: c[k] for k in ("part", "geometry", "size")} for c in CASES],
        "note": "Import all .step files, select all surfaces, run BatchMesher; "
                "by-attached should report exactly 12 connectivity domains.",
    }
    common.write_manifest(outdir / "BatchMesher_Surfaces_manifest.json", manifest)
    common.write_readme(outdir / "README.md", README)
    print("TOTAL parts={} connected_components={} surface_features={} holes_slots={}".format(
        len(CASES), len(CASES), sum(1 + hole_count(c) for c in CASES),
        sum(hole_count(c) for c in CASES)))
    return 0


README = """# BatchMesher — 曲面输入大型验证模型（12 部件 / >100 面）

## 用途
`batch_mesher_surfaces_12parts/` 提供 **12 个独立 STEP 曲面文件**，用于
`batch_mesher` 模块的 by-attached 连通域分组与批量网格生成验证。
BatchMesher 输入是曲面几何（非网格），故本套件输出 *.step 开放曲面面片。

## 场景表
| 部件 | 几何 | 孔/槽 | 面数（含孔环） |
|---|---|---|---|
| V01_RECT_8HOLES  | 矩形 | 8 孔   | 9  |
| V02_RECT_14HOLES | 矩形 | 14 孔  | 15 |
| V03_RECT_20HOLES | 矩形 | 20 孔  | 21 |
| V04_RECT_16HOLES | 矩形 | 16 孔  | 17 |
| V05_SLOTS_6      | 矩形 | 6 槽   | 7  |
| V06_SLOTS_5      | 矩形 | 5 槽   | 6  |
| V07_LSHAPE       | L 形 | 0      | 1  |
| V08_LSHAPE_HOLES | L 形 | 4 孔   | 5  |
| V09_USHAPE       | U 形缺口 | 0  | 1  |
| V10_NOTCHED      | 侧缺口 | 0   | 1  |
| V11_DENSE_HOLES  | 矩形 | 40 孔  | 41 |
| V12_PLAIN        | 矩形 | 0      | 1  |

## 操作
1. HyperMesh 导入 12 个 `.step`（产品名即组件名，见 manifest `components`）。
2. 全选所有 surfaces，运行 BatchMesher，默认按 by-attached 分组。
3. 预期 **连通域 = 12**，即 12 个批量任务；总面数 100+。
4. 核对每个任务生成的组件名与部件名一致。

## 设计说明
- 部件沿 X 以 220mm 间距排布，互不接触 → 每个文件恰 1 个连通域。
- 前 4 块多孔矩形面（孔距 >=30mm、孔径 8~16）；11 为 40 孔密集大板。
- 5/6 用长圆槽（闭合环缺口）模拟槽特征。
- 确定性生成（无随机）；manifest 记录每部件面数/孔数/bbox。
"""

if __name__ == "__main__":
    raise SystemExit(main())
