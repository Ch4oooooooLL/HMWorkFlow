#!/usr/bin/env python3
"""gen_seam_surface.py -- LARGE open-shell-surface STEP suite for seam_surface
(几何焊缝, 12 operations).

Each region below exercises one or more of the 12 seam operations.  Every
face is a separate STEP file (product name = component name on import);
the manifest groups the files per region.  All plates are OPEN shell faces
(surface geometry only), with 0.5-8 mm gaps between parts to be welded.

Regions (along X):
  R01 T_PATH          base 400x250 + 3 standing ribs (1mm gap)
  R02 T_LIST          base + 2 ribs with zigzag bottom-edge paths (T list)
  R03 L_SURF          2 lap pairs (parallel plates, 70mm overlap, 5mm gap)
  R04 L_LIST          2 lap pairs with edge path (60mm offset, 6mm gap)
  R05 CONNECT         2 dog-leg pairs (edge-to-edge, 5mm gap, offset)
  R06 PROJECT         large face + secondary face (project/split target)
  R07 EXTEND          2 pairs of parallel faces, 8mm gap (extend)
  R08 COMBINE         2 coplanar face pairs sharing full edges (merge)
  R09 SPLIT           large face 400x300 (user picks a line)
  R10 REPLACE_POINT   face with holes/points (replace point target)
  R11 DISTRIBUTE      long face 800x150 (long edge, point_spacing 7)
  R12 ANGLED_T        rib at 70 deg (T path, angle boundary)
  R13 CLOSED          zero-gap pair (known failure, negative control)

Units mm.  Built with cadquery (OCCT).  Deterministic.
"""

from __future__ import annotations

import os
import sys
from typing import Dict, List, Tuple

import cadquery as cq

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import steplib as S


def rot_x(face: cq.Workplane, angle_deg: float) -> cq.Workplane:
    """Rotate a face around the X axis (stand a plate up)."""
    return cq.Workplane(obj=face.val().rotate((0, 0, 0), (1, 0, 0), angle_deg))


def build_regions() -> List[Dict]:
    regions: List[Dict] = []

    # ---- R01: T_PATH (3 standing ribs on one base) ------------------------
    faces = [("R01_BASE", S.shell_rect(400, 250))]
    for i, x in enumerate((-100.0, 0.0, 100.0)):
        rib = rot_x(S.shell_rect(150, 80), 90.0).translate((x, 0.0, 1.0))
        faces.append(("R01_RIB_{}".format(i + 1), rib))
    regions.append({"region": "R01", "op": "T_PATH",
                    "title": "T 曲面：3 条立筋垂直投影到底板（间隙 1mm）",
                    "files": faces, "expected": "T 曲面延伸 + 缝合成功（角度 90°>15°，间隙 1mm）"})

    # ---- R02: T_LIST (zigzag bottom-edge paths) ---------------------------
    faces = [("R02_BASE", S.shell_rect(500, 260))]
    zigzag = [(0, 0), (50, 0), (50, 8), (100, 8), (100, 0), (150, 0), (150, 8),
              (200, 8), (200, 0), (250, 0), (250, 60), (0, 60)]
    rib1 = rot_x(S.shell_poly(zigzag), 90.0).translate((-100.0, 0.0, 1.0))
    zigzag2 = [(0, 0), (40, 0), (40, 10), (90, 10), (90, 0), (140, 0), (140, 10),
               (190, 10), (190, 0), (230, 0), (230, 55), (0, 55)]
    rib2 = rot_x(S.shell_poly(zigzag2), 90.0).translate((80.0, 0.0, 1.0))
    faces += [("R02_RIB_1", rib1), ("R02_RIB_2", rib2)]
    regions.append({"region": "R02", "op": "T_LIST",
                    "title": "T 列表：锯齿底边路径投影切分到目标面",
                    "files": faces, "expected": "投影路径识别 + ruled 焊缝面创建"})

    # ---- R03: L_SURF (2 lap pairs) ----------------------------------------
    faces = []
    for i in range(2):
        x0 = i * 350.0
        faces.append(("R03_A_{}".format(i + 1), S.shell_rect(300, 200).translate((x0, 0.0, 0.0))))
        faces.append(("R03_B_{}".format(i + 1), S.shell_rect(300, 200).translate((x0 + 70.0, 0.0, 5.0))))
    regions.append({"region": "R03", "op": "L_SURF",
                    "title": "搭接曲面：平行重叠板 2 对（重叠 70mm，间隙 5mm）",
                    "files": faces, "expected": "偏移 + 布尔并集 + 修剪创建搭接焊缝面"})

    # ---- R04: L_LIST -------------------------------------------------------
    faces = []
    for i in range(2):
        x0 = i * 350.0
        faces.append(("R04_A_{}".format(i + 1), S.shell_rect(250, 150).translate((x0, 0.0, 0.0))))
        faces.append(("R04_B_{}".format(i + 1), S.shell_rect(250, 150).translate((x0 + 60.0, 0.0, 6.0))))
    regions.append({"region": "R04", "op": "L_LIST",
                    "title": "搭接边线：平行板边线路径 2 对（偏移 60mm，间隙 6mm）",
                    "files": faces, "expected": "边线路径 -> 目标面搭接创建"})

    # ---- R05: CONNECT (dog-leg pairs) --------------------------------------
    faces = []
    for i in range(2):
        y0 = i * 220.0
        faces.append(("R05_A_{}".format(i + 1), S.shell_rect(250, 120).translate((0.0, y0, 0.0))))
        faces.append(("R05_B_{}".format(i + 1),
                      S.shell_rect(250, 120).translate((255.0, y0 + 30.0, 0.0))))
    regions.append({"region": "R05", "op": "CONNECT",
                    "title": "连接边线：狗腿对边 2 对（5mm 间隙，30mm 错位）",
                    "files": faces, "expected": "直纹连接面 + 缝合"})

    # ---- R06: PROJECT (target face for projection/split) -------------------
    faces = [("R06_TARGET", S.shell_rect(400, 300, holes=[(-120, 0, 30), (120, 0, 30)])),
             ("R06_AUX", S.shell_rect(150, 80).translate((0.0, 220.0, 0.0)))]
    regions.append({"region": "R06", "op": "PROJECT",
                    "title": "投影切分：带 2 孔大面 + 辅助面（供投影线切分）",
                    "files": faces, "expected": "用户选择投影线切分目标面"})

    # ---- R07: EXTEND (2 pairs across an 8mm gap) ---------------------------
    faces = []
    for i in range(2):
        y0 = i * 200.0
        faces.append(("R07_A_{}".format(i + 1), S.shell_rect(200, 120).translate((0.0, y0, 0.0))))
        faces.append(("R07_B_{}".format(i + 1), S.shell_rect(200, 120).translate((208.0, y0, 0.0))))
    regions.append({"region": "R07", "op": "EXTEND",
                    "title": "延伸：跨 8mm 间隙的平行边 2 对",
                    "files": faces, "expected": "延伸边到目标面 + 连接"})

    # ---- R08: COMBINE (coplanar adjacent faces) ----------------------------
    faces = []
    for i in range(2):
        y0 = i * 200.0
        faces.append(("R08_A_{}".format(i + 1), S.shell_rect(200, 150).translate((0.0, y0, 0.0))))
        faces.append(("R08_B_{}".format(i + 1), S.shell_rect(200, 150).translate((200.0, y0, 0.0))))
    regions.append({"region": "R08", "op": "COMBINE",
                    "title": "合并：共面相邻面对 2 对（共享完整边）",
                    "files": faces, "expected": "multi-surfs-lines merge 合并"})

    # ---- R09: SPLIT ---------------------------------------------------------
    faces = [("R09_TARGET", S.shell_rect(400, 300))]
    regions.append({"region": "R09", "op": "SPLIT",
                    "title": "拆分：400x300 大面（用户选择分割线）",
                    "files": faces, "expected": "按用户线拆分"})

    # ---- R10: REPLACE_POINT -------------------------------------------------
    faces = [("R10_TARGET", S.shell_rect(300, 200, holes=[(-60, 0, 16), (60, 0, 16)]))]
    regions.append({"region": "R10", "op": "REPLACE_POINT",
                    "title": "替换点：带孔面（孔边界点可被投影替换）",
                    "files": faces, "expected": "点投影到边 + 顶点合并"})

    # ---- R11: DISTRIBUTE_POINTS (long edge) --------------------------------
    faces = [("R11_LONG", S.shell_rect(800, 150, holes=[(x, 0, 20) for x in (-300, 0, 300)]))]
    regions.append({"region": "R11", "op": "DISTRIBUTE_POINTS",
                    "title": "分布点：800mm 长边（point_spacing=7 -> 约 114 点）",
                    "files": faces, "expected": "沿长边分布点"})

    # ---- R12: ANGLED_T (70 deg, angle boundary) ----------------------------
    faces = [("R12_BASE", S.shell_rect(300, 200)),
             ("R12_RIB", rot_x(S.shell_rect(140, 70), 70.0).translate((0.0, 0.0, 1.0)))]
    regions.append({"region": "R12", "op": "T_PATH",
                    "title": "斜 T：70° 立筋（角度边界，>15° 应成功）",
                    "files": faces, "expected": "T 曲面创建成功（70°>15°）"})

    # ---- R13: CLOSED (zero gap, known failure) -----------------------------
    faces = [("R13_A", S.shell_rect(200, 150)),
             ("R13_B", S.shell_rect(200, 150).translate((200.0, 0.0, 0.0)))]
    regions.append({"region": "R13", "op": "CONNECT",
                    "title": "负向：零间隙闭合对（已知失败场景）",
                    "files": faces, "expected": "全闭合间隙 0 -> 创建失败/回滚（观察）"})

    return regions


def main():
    outdir = common.model_dir("seam_surface_13regions")
    regions = build_regions()
    all_files = []
    all_faces = 0
    for region in regions:
        for name, face in region["files"]:
            path = outdir / (name + ".step")
            S.export_step(face, str(path), name)
            info = S.verify_step(str(path))
            if info["solids"] != 0 or info["faces"] != 1:
                raise ValueError("{}: expected a single shell face, got {}".format(name, info))
            region.setdefault("bboxes", {})[name] = info["bbox"]
            all_files.append(name + ".step")
            all_faces += 1
            print(name, info["bbox"])
    stats = {"region_count": len(regions), "face_count": all_faces,
             "file_count": len(all_files),
             "total_edge_length_mm": sum(b[3] - b[0] for r in regions for b in r.get("bboxes", {}).values())}
    manifest_regions = []
    for region in regions:
        manifest_regions.append({
            "region": region["region"], "op": region["op"], "title": region["title"],
            "expected": region["expected"],
            "files": [n for n, _f in region["files"]],
            "bboxes": region.get("bboxes", {}),
        })
    common.write_manifest(outdir / "seam_surface_13regions_manifest.json", {
        "module": "seam_surface",
        "purpose": "LARGE open-shell-surface suite for the 12 seam-surface operations",
        "generator": "tools/model_generation/gen_seam_surface.py",
        "files": all_files,
        "statistics": stats,
        "regions": manifest_regions,
        "warning": "R13 is a zero-gap negative control; PROJECT/SPLIT/REPLACE_POINT need user-picked lines/points.",
    })
    common.write_readme(outdir / "README.md", README)
    print(stats)
    return 0


README = """# Geometry Seam（几何焊缝）— Large Validation Model（13 区域 / 12 操作）

## 用途
开放壳体曲面 STEP 套件（每面一个 .step，导入后组件名 = 文件名），覆盖
`seam_surface` 全部 12 种操作，间隙 0.5~8mm。

## 区域与操作（见 manifest）
| 区域 | 操作 | 构型 |
|---|---|---|
| R01 | T 曲面 | 底板 400x250 + 3 立筋（1mm 间隙） |
| R02 | T 列表 | 2 条锯齿底边路径 → 投影切分 |
| R03 | 搭接曲面 | 2 对平行重叠板（70mm 重叠 / 5mm） |
| R04 | 搭接边线 | 2 对平行板边（60mm 偏移 / 6mm） |
| R05 | 连接边线 | 2 对狗腿对边（5mm 间隙 / 30mm 错位） |
| R06 | 投影切分 | 带 2 孔大面 + 辅助面 |
| R07 | 延伸 | 2 对跨 8mm 间隙平行边 |
| R08 | 合并 | 2 对共面相邻面 |
| R09 | 拆分 | 400x300 大面 |
| R10 | 替换点 | 带孔面（孔边界点） |
| R11 | 分布点 | 800mm 长边（约 114 点 @7mm） |
| R12 | T 曲面（斜） | 70° 立筋（角度边界） |
| R13 | 连接（负向） | 零间隙闭合对（预期失败） |

## 操作
1. 按区域导入对应 .step（同一区域的多个面导入到一个模型）。
2. 面板中按区域执行对应操作；创建类操作后核对 SEAM_Tx_Surf 输出与拓扑缝合。
3. R13 用于确认失败回滚路径。

## 设计说明
- 全部为 OPEN 面（无厚度）；面间 0.5~8mm 间隙、不共享拓扑（符合模块输入要求）。
- 最小焊缝长度门限 5mm：所有边路径 >= 40mm。
- 角度门限 connect_min_angle_to_target=15°：R01/R12 均满足。
"""


if __name__ == "__main__":
    raise SystemExit(main())
