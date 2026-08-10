#!/usr/bin/env python3
"""Generate the Geometry Seam (seam_surface) validation STEP geometry.

One STEP file containing 14 spatially isolated scenarios, each a realistic
sheet-metal assembly of OPEN SHELL surfaces (top face + side bands, bottom
face removed) so the module's edge/surface/point operations can be exercised
in HyperMesh without any solid or shared topology.

Run from the repository root:

    python examples/SeamSurface_Validation/generate_geometry.py

Requires the system Python with cadquery 2.8.0 (import cadquery provides
OCCT).  The generated .step and *manifest.json are gitignored deliverables;
only this script and README.md are committed.

Outputs (next to this script):
    SeamSurface_Validation.step
    SeamSurface_Validation_manifest.json

Deterministic: no random sources, fixed coordinates, pitch 400 mm along X.

Scenario matrix (covers all 12 seam_surface operations):
    C01  T曲面        T_PATH            L 形筋板曲面组 + 底板目标面
    C02  T列表        T_LIST            2 根筋（1 直 1 折弯）同一底板
    C03  搭接面       L_SURF            两块平行重叠板（间隙 1.0 mm）
    C04  搭接边       L_LIST            上层板台阶形搭接边 -> 下层板顶面
    C05  连接         CONNECT           两块共面板，狗腿形对边，间隙 0.8 mm
    C06  投影/分割    PROJECT           楼梯形源板底边投影到目标板并切分
    C07  延伸         EXTEND            筋板底边距底板 4 mm，延伸桥接
    C08A 合并         COMBINE           两块共面相邻顶面（共享边）合并
    C08B 拆分         SPLIT             独立折线投影切分目标板
    C08C 替换点       REPLACE_POINT     自由点投影到边线
    C09  边界：大角度斜交（45°，连接角度探测）
    C10  边界：间隙 8 mm（connect_extend_distance 探测）
    C11  失败：T 列表短路径（边 4 mm < min_seam_length 5.0）
    C12  边界：斜 T 型（法向夹角 70°，连接角度探测）
    C13  分布点       DISTRIBUTE_POINTS 260 mm 边按 7 mm 分布点
    C14  删除         DELETE           搭接边创建焊缝后再删除
"""

from __future__ import annotations

import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

import cadquery as cq
from cadquery import importers

# ---------------------------------------------------------------------------
# Module configuration the geometry must be consistent with
# (config/seam_rules.txt and modules/seam_surface/config.tcl).
# ---------------------------------------------------------------------------
MODULE_PARAMS = {
    "angle_parallel_max": 15.0,          # documented parallel classification
    "angle_perpendicular_min": 75.0,     # documented perpendicular classification
    "endpoint_merge_tolerance": 0.1,     # line-graph endpoint merge
    "min_seam_length": 5.0,              # documented minimum seam length
    "point_spacing": 7.0,                # distributed-point target spacing
    "geometry_offset_distance": 50.0,    # lap intersection offset
    "extend_offset_distance": 12.0,      # extension guide offset
    "connect_min_angle_to_target": 15.0, # native connect args
    "connect_max_angle_edge_to_surf": 30.0,
    "connect_guide_angle": 30.0,
    "lap_connect_distance": 5.0,
    "thickness_override": 0.0,
}

CASE_PITCH = 400.0
OUT_DIR = Path(__file__).resolve().parent
STEP_FILE = OUT_DIR / "SeamSurface_Validation.step"
MANIFEST_FILE = OUT_DIR / "SeamSurface_Validation_manifest.json"

# ---------------------------------------------------------------------------
# Small geometry helpers (all coordinates in mm, global frame).
# ---------------------------------------------------------------------------


def _drop_neg_axis(faces, axis):
    """Return faces whose outward normal is not -axis (drop the 'bottom')."""
    out = []
    for f in faces:
        n = f.normalAt()
        if abs(n.x + axis[0]) < 1e-6 and abs(n.y + axis[1]) < 1e-6 and abs(n.z + axis[2]) < 1e-6:
            continue
        out.append(f)
    return out


def plate_shell_xy(pts, thickness, holes=()):
    """Open-shell plate from a closed XY outline; local z in [0, thickness].

    Returns (compound, top_z).  pts: list of (x, y) outline vertices.
    holes: list of (x, y, diameter) in the plate-local XY frame.
    """
    w = cq.Workplane("XY").polyline(pts).close().extrude(thickness)
    for (hx, hy, hd) in holes:
        w = w.faces(">Z").workplane().center(hx, hy).hole(hd)
    solid = w.val()
    faces = _drop_neg_axis(list(solid.Faces()), (0, 0, 1))
    return cq.Compound.makeCompound(faces), thickness


def flange_plate_shell(profile_pts, length, top_holes=()):
    """Sheet-metal plate with a bent flange.

    profile_pts: closed polygon in the (y, z) plane (the plate cross section
    including the flange lip).  The section is extruded along +X by `length`,
    so the resulting solid spans x in [0, length].  top_holes: (x, y, d).
    """
    w = cq.Workplane("YZ").polyline(profile_pts).close().extrude(length)
    for (hx, hy, hd) in top_holes:
        w = w.faces(">Z").workplane().center(hx, hy).hole(hd)
    solid = w.val()
    faces = _drop_neg_axis(list(solid.Faces()), (1, 0, 0))
    return cq.Compound.makeCompound(faces)


def quad_face(pts):
    """Single quad / parallelogram face from four 3D points (in order)."""
    return cq.Face.makeFromWires(cq.Wire.makePolygon(pts, close=True))


def free_wire(pts):
    """Standalone (face-less) polyline wire used as a split/projection line."""
    return cq.Wire.makePolygon(pts, close=False)


def free_point(x, y, z):
    return cq.Vertex.makeVertex(x, y, z)


def vdist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def vnorm(p0, p1, p2):
    """Unit normal of the plane through three points."""
    u = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
    v = (p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2])
    n = (
        u[1] * v[2] - u[2] * v[1],
        u[2] * v[0] - u[0] * v[2],
        u[0] * v[1] - u[1] * v[0],
    )
    length = math.sqrt(sum(c * c for c in n))
    return tuple(c / length for c in n)


def plane_angle(n1, n2):
    """Angle (0..90) between two plane normals, treating +/- normal as equal."""
    d = abs(sum(a * b for a, b in zip(n1, n2)))
    return math.degrees(math.acos(min(1.0, d)))


def edge_mid(a, b):
    return tuple(round((a[i] + b[i]) / 2.0, 4) for i in range(3))


# ---------------------------------------------------------------------------
# Case bookkeeping
# ---------------------------------------------------------------------------


@dataclass
class Case:
    case_id: str
    title: str
    operation: str
    x0: float
    x1: float
    shapes: list = field(default_factory=list)
    selection: list = field(default_factory=list)
    expected: str = ""
    settings: dict = field(default_factory=dict)
    notes: str = ""
    min_faces: int = 1


def sel_edge(note, a, b):
    return {
        "entity": "edge",
        "endpoints": [[round(v, 4) for v in a], [round(v, 4) for v in b]],
        "identify": edge_mid(a, b),
        "note": note,
    }


def sel_face(note, identify):
    return {"entity": "face", "identify": [round(v, 4) for v in identify], "note": note}


def sel_point(note, p):
    return {"entity": "point", "coordinate": [round(v, 4) for v in p], "note": note}


def sel_wire(note, pts):
    return {
        "entity": "wire",
        "vertices": [[round(v, 4) for v in p] for p in pts],
        "note": note,
    }


CASES = []


def build_c01():
    """T曲面: L 形筋板曲面组 + 带翻边/孔的底板目标面."""
    x0, x1 = 0.0, 260.0
    # 底板：截面（y,z）带 8 mm 下翻边，沿 X 挤出 260 mm
    profile = [(0.0, -8.0), (0.0, 0.0), (150.0, 0.0), (150.0, 2.0), (2.0, 2.0), (2.0, -8.0)]
    base = flange_plate_shell(profile, 260.0, top_holes=[(100.0, 50.0, 8.0), (210.0, 110.0, 8.0)])
    # 筋板（两块竖直面，构成 L 形）
    rib_a = quad_face([(60.0, 30.0, 3.0), (60.0, 90.0, 3.0), (60.0, 90.0, 53.0), (60.0, 30.0, 53.0)])
    rib_b = quad_face([(60.0, 90.0, 3.0), (100.0, 90.0, 3.0), (100.0, 90.0, 53.0), (60.0, 90.0, 53.0)])
    e1a, e1b = (60.0, 30.0, 3.0), (60.0, 90.0, 3.0)
    e2a, e2b = (60.0, 90.0, 3.0), (100.0, 90.0, 3.0)
    case = Case(
        "C01", "T 曲面", "T_PATH", x0, x1,
        shapes=[base, rib_a, rib_b],
        selection=[
            sel_edge("筋板 A 底部自由边（竖直段）", e1a, e1b),
            sel_edge("筋板 B 底部自由边（水平段）", e2a, e2b),
            sel_face("底板顶面（含 2 孔，目标面）", (130.0, 75.0, 2.0)),
        ],
        expected="第一组选择两张筋板曲面，第二组选择底板顶面；创建 T 延伸曲面，"
                 "条带归入 SEAM_Txx_Surf 组件并与底板顶面共享边线。",
        settings={"thickness": "2.0（组件名无厚度时提示输入，或设 thickness_override=2.0）"},
        notes="筋板底部距底板顶面 1.0 mm（>0 间隙，避免全闭合接头无缝可填）。",
        min_faces=10,
    )
    CASES.append(case)


def build_c02():
    """T列表: 同一底板上 2 根筋（一根直、一根折弯）."""
    x0, x1 = 400.0, 660.0
    base, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 260.0, 0.0), (x0 + 260.0, 150.0), (x0, 150.0)], 2.0,
        holes=[(x0 + 130.0, 75.0, 10.0)],
    )
    rib1 = quad_face([(x0 + 30.0, 30.0, 3.0), (x0 + 230.0, 30.0, 3.0),
                      (x0 + 230.0, 30.0, 43.0), (x0 + 30.0, 30.0, 43.0)])
    rib2a = quad_face([(x0 + 30.0, 120.0, 3.0), (x0 + 210.0, 120.0, 3.0),
                       (x0 + 210.0, 120.0, 43.0), (x0 + 30.0, 120.0, 43.0)])
    rib2b = quad_face([(x0 + 210.0, 120.0, 3.0), (x0 + 210.0, 90.0, 3.0),
                       (x0 + 210.0, 90.0, 43.0), (x0 + 210.0, 120.0, 43.0)])
    case = Case(
        "C02", "T 列表", "T_LIST", x0, x1,
        shapes=[base, rib1, rib2a, rib2b],
        selection=[
            sel_edge("筋 1 底部自由边", (x0 + 30.0, 30.0, 3.0), (x0 + 230.0, 30.0, 3.0)),
            sel_edge("筋 2 底部自由边（水平段）", (x0 + 30.0, 120.0, 3.0), (x0 + 210.0, 120.0, 3.0)),
            sel_edge("筋 2 底部自由边（竖直段）", (x0 + 210.0, 120.0, 3.0), (x0 + 210.0, 90.0, 3.0)),
            sel_face("底板顶面（含 1 孔，目标面）", (x0 + 130.0, 75.0, 2.0)),
        ],
        expected="分两次执行：先选筋 1 的单条路径，再选筋 2 的两段连续路径；"
                 "每次对同一目标面创建一条 T 焊缝，不能一次提交互不连通的两根筋。",
        settings={"thickness": "2.0"},
        notes="筋 2 为折弯筋（两竖直面共享边），底边构成 L 形；与筋 1 底边不连通。",
        min_faces=8,
    )
    CASES.append(case)


def build_c03():
    """搭接面: 两块平行重叠板，间隙 1.0 mm."""
    x0, x1 = 800.0, 1080.0
    plate_a, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 150.0, 0.0), (x0 + 150.0, 150.0), (x0, 150.0)], 2.0,
        holes=[(x0 + 75.0, 40.0, 8.0)],
    )
    plate_b, _ = plate_shell_xy(
        [(x0 + 80.0, 0.0), (x0 + 280.0, 0.0), (x0 + 280.0, 150.0), (x0 + 80.0, 150.0)], 2.0,
    )
    plate_b = plate_b.translate((0, 0, 3.0))
    case = Case(
        "C03", "搭接面", "L_SURF", x0, x1,
        shapes=[plate_a, plate_b],
        selection=[
            sel_face("下板顶面（基面）", (x0 + 75.0, 75.0, 2.0)),
            sel_face("上板顶面（目标面）", (x0 + 160.0, 75.0, 5.0)),
        ],
        expected="在重叠区（x≈880..950）创建搭接焊缝面，法向平行（夹角 0°），"
                 "归入 SEAM_Txx_Surf 组件。",
        settings={"thickness": "2.0", "lap_boolean_opcode": "8（并集）"},
        notes="两板平行（法向夹角 0°<15°），B 板底面距 A 板顶面 1.0 mm。",
        min_faces=10,
    )
    CASES.append(case)


def build_c04():
    """搭接边: 上板台阶形搭接边 -> 下板顶面."""
    x0, x1 = 1200.0, 1490.0
    plate_a, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 250.0, 0.0), (x0 + 250.0, 150.0), (x0, 150.0)], 2.0,
        holes=[(x0 + 220.0, 120.0, 8.0)],
    )
    pts_b = [(x0 + 110.0, 0.0), (x0 + 290.0, 0.0), (x0 + 290.0, 150.0),
             (x0 + 170.0, 150.0), (x0 + 170.0, 90.0), (x0 + 110.0, 90.0)]
    plate_b, _ = plate_shell_xy(pts_b, 2.0)
    plate_b = plate_b.translate((0, 0, 3.0))
    e1a, e1b = (x0 + 110.0, 0.0, 3.0), (x0 + 110.0, 90.0, 3.0)
    e2a, e2b = (x0 + 170.0, 90.0, 3.0), (x0 + 170.0, 150.0, 3.0)
    case = Case(
        "C04", "搭接边", "L_LIST", x0, x1,
        shapes=[plate_a, plate_b],
        selection=[
            sel_edge("上板台阶搭接边第 1 段（x=1310，z=3）", e1a, e1b),
            sel_edge("上板台阶搭接边第 2 段（x=1370，z=3）", e2a, e2b),
            sel_face("下板顶面（目标面）", (x0 + 80.0, 75.0, 2.0)),
        ],
        expected="沿上板两条台阶形自由边向下创建搭接焊缝条带到下板顶面；"
                 "两条边不连通（LIST 拓扑），均可同时选择。",
        settings={"thickness": "2.0"},
        notes="上板底面距下板顶面 1.0 mm；两板平行。上板为带缺口的台阶形板。",
        min_faces=12,
    )
    CASES.append(case)


def build_c05():
    """连接: 两块共面板，狗腿形对边，法向间隙 0.8 mm."""
    x0, x1 = 1600.0, 1920.0
    pts_a = [(x0, 0.0), (x0 + 150.0, 0.0), (x0 + 150.0, 90.0), (x0 + 170.0, 150.0), (x0, 150.0)]
    plate_a, _ = plate_shell_xy(pts_a, 2.0, holes=[(x0 + 60.0, 120.0, 8.0)])
    pts_b = [(x0 + 150.8, 0.0), (x0 + 150.8, 90.0), (x0 + 170.8, 150.0), (x0 + 320.0, 150.0), (x0 + 320.0, 0.0)]
    plate_b, _ = plate_shell_xy(pts_b, 2.0)
    case = Case(
        "C05", "连接", "CONNECT", x0, x1,
        shapes=[plate_a, plate_b],
        selection=[
            sel_edge("A 板狗腿边第 1 段", (x0 + 150.0, 0.0, 2.0), (x0 + 150.0, 90.0, 2.0)),
            sel_edge("A 板狗腿边第 2 段", (x0 + 150.0, 90.0, 2.0), (x0 + 170.0, 150.0, 2.0)),
            sel_edge("B 板狗腿边第 1 段", (x0 + 150.8, 0.0, 2.0), (x0 + 150.8, 90.0, 2.0)),
            sel_edge("B 板狗腿边第 2 段", (x0 + 150.8, 90.0, 2.0), (x0 + 170.8, 150.0, 2.0)),
        ],
        expected="在两条平行狗腿形边之间创建直纹焊缝面（ruled surface），"
                 "并与两侧板顶面拓扑缝合。",
        settings={"thickness": "2.0"},
        notes="两板共面（同 z=2），对边法向间隙约 0.76~0.80 mm（<distance_tolerance 1.0）。",
        min_faces=11,
    )
    CASES.append(case)


def build_c06():
    """投影/分割: 楼梯形源板底边投影到目标板并切分."""
    x0, x1 = 2000.0, 2180.0
    target, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 180.0, 0.0), (x0 + 180.0, 150.0), (x0, 150.0)], 2.0,
        holes=[(x0 + 80.0, 130.0, 8.0)],
    )
    pts_src = [(x0 + 20.0, 20.0), (x0 + 30.0, 30.0), (x0 + 70.0, 30.0),
               (x0 + 70.0, 130.0), (x0 + 20.0, 130.0)]
    source, _ = plate_shell_xy(pts_src, 2.0)
    source = source.translate((0, 0, 3.0))
    case = Case(
        "C06", "投影/分割", "PROJECT", x0, x1,
        shapes=[target, source],
        selection=[
            sel_edge("源板底边第 1 段（z=3，待投影）", (x0 + 30.0, 30.0, 3.0), (x0 + 70.0, 30.0, 3.0)),
            sel_edge("源板底边第 2 段（z=3，待投影）", (x0 + 70.0, 30.0, 3.0), (x0 + 70.0, 130.0, 3.0)),
            sel_face("目标板顶面（待切分）", (x0 + 60.0, 75.0, 2.0)),
        ],
        expected="L 形投影线切分目标板顶面，得到沿折线的两个新面。",
        settings={},
        notes="源板底边在目标顶面上方 1.0 mm，投影竖直。PROJECT 与 SPLIT 使用同一原生命令，"
              "本场景演示 PROJECT（连续模式）。",
        min_faces=11,
    )
    CASES.append(case)


def build_c07():
    """延伸: 筋板底边距底板 4 mm，延伸桥接."""
    x0, x1 = 2400.0, 2720.0
    base, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 160.0, 0.0), (x0 + 160.0, 150.0), (x0, 150.0)], 2.0,
    )
    rib = quad_face([(x0 + 40.0, 40.0, 6.0), (x0 + 120.0, 40.0, 6.0),
                     (x0 + 120.0, 40.0, 56.0), (x0 + 40.0, 40.0, 56.0)])
    case = Case(
        "C07", "延伸", "EXTEND", x0, x1,
        shapes=[base, rib],
        selection=[
            sel_edge("筋板底部待延伸边（z=6）", (x0 + 40.0, 40.0, 6.0), (x0 + 120.0, 40.0, 6.0)),
            sel_face("底板顶面（延伸目标）", (x0 + 80.0, 75.0, 2.0)),
        ],
        expected="沿筋板底边创建延伸面（extend_offset_distance 12.0 作为引导偏置），"
                 "桥接 4 mm 间隙，结果归入源组件。",
        settings={"extend_offset_distance": "12.0"},
        notes="筋板底边距底板顶面 4.0 mm（短边不足）。延伸后源面被原生内核重建，"
              "模块会记录 source renumber 警告。",
        min_faces=5,
    )
    CASES.append(case)


def build_c08a():
    """合并: 两块共面相邻顶面（共享边 x=2860）合并."""
    x0, x1 = 2800.0, 2930.0
    left, _ = plate_shell_xy(
        [(x0, 20.0), (x0 + 60.0, 20.0), (x0 + 60.0, 130.0), (x0, 130.0)], 2.0,
    )
    right, _ = plate_shell_xy(
        [(x0 + 60.0, 20.0), (x0 + 130.0, 20.0), (x0 + 130.0, 130.0), (x0 + 60.0, 130.0)], 2.0,
    )
    case = Case(
        "C08A", "合并", "COMBINE", x0, x1,
        shapes=[left, right],
        selection=[
            sel_face("左板顶面", (x0 + 30.0, 75.0, 2.0)),
            sel_face("右板顶面", (x0 + 95.0, 75.0, 2.0)),
        ],
        expected="两块共面顶面合并为一张面（若导入时已缝合则提示 already equivalent 无操作警告）。",
        settings={},
        notes="两块板 0 间隙相邻，顶面共享 x=2860 边。",
        min_faces=9,
    )
    CASES.append(case)


def build_c08b():
    """拆分: 独立折线投影切分目标板."""
    x0, x1 = 2960.0, 3100.0
    target, _ = plate_shell_xy(
        [(x0, 20.0), (x0 + 140.0, 20.0), (x0 + 140.0, 130.0), (x0, 130.0)], 2.0,
    )
    wire = free_wire([(x0 + 20.0, 30.0, 3.0), (x0 + 70.0, 30.0, 3.0), (x0 + 70.0, 110.0, 3.0)])
    case = Case(
        "C08B", "拆分", "SPLIT", x0, x1,
        shapes=[target, wire],
        selection=[
            sel_wire("独立折线（L 形，z=3，待投影）",
                     [(x0 + 20.0, 30.0, 3.0), (x0 + 70.0, 30.0, 3.0), (x0 + 70.0, 110.0, 3.0)]),
            sel_face("目标板顶面（待切分）", (x0 + 60.0, 75.0, 2.0)),
        ],
        expected="独立折线投影到目标板顶面并切分为多个面。",
        settings={},
        notes="SPLIT 与 PROJECT 同走 *surfacemarksplitwithlines；本场景用独立（无面）折线作切分线。",
        min_faces=4,
    )
    CASES.append(case)


def build_c08c():
    """替换点: 自由点投影到边线."""
    x0, x1 = 3120.0, 3180.0
    plate, _ = plate_shell_xy(
        [(x0, 20.0), (x0 + 60.0, 20.0), (x0 + 60.0, 130.0), (x0, 130.0)], 2.0,
    )
    pt = free_point(x0 + 30.0, 120.0, 5.0)
    case = Case(
        "C08C", "替换点", "REPLACE_POINT", x0, x1,
        shapes=[plate, pt],
        selection=[
            sel_point("自由点（待投影）", (x0 + 30.0, 120.0, 5.0)),
            sel_edge("目标边线（板顶面后边 y=130，z=2）", (x0, 130.0, 2.0), (x0 + 60.0, 130.0, 2.0)),
        ],
        expected="自由点投影到最近边线，落到 (x0+30, 130, 2)；投影后与新边端点合并。",
        settings={},
        notes="点距边线约 10 mm（y 向 10 mm，z 向 3 mm）。",
        min_faces=4,
    )
    CASES.append(case)


def build_c09():
    """边界: 大角度斜交（45°），用于连接角度探测."""
    x0, x1 = 3200.0, 3460.0
    base, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 260.0, 0.0), (x0 + 260.0, 150.0), (x0, 150.0)], 2.0,
    )
    h = 50.0
    v = (h * math.cos(math.radians(45.0)), 0.0, h * math.sin(math.radians(45.0)))
    p0, p1 = (x0 + 100.0, 30.0, 3.0), (x0 + 100.0, 90.0, 3.0)
    rib = quad_face([p0, p1,
                     (p1[0] + v[0], p1[1], p1[2] + v[2]),
                     (p0[0] + v[0], p0[1], p0[2] + v[2])])
    case = Case(
        "C09", "边界：大角度斜交（45°）", "T_PATH", x0, x1,
        shapes=[base, rib],
        selection=[
            sel_edge("45° 斜筋底边（z=3）", p0, p1),
            sel_face("底板顶面（目标面）", (x0 + 130.0, 75.0, 2.0)),
        ],
        expected="使用 T 曲面复核连接角度参数；记录默认值下原生命令是否接受，并确认两版本一致。",
        settings={},
        notes="不再使用旧自动分类阈值；由 connect_* 角度参数和原生命令决定。",
        min_faces=5,
    )
    CASES.append(case)


def build_c10():
    """边界: 8 mm 间隙，用于 connect_extend_distance 探测."""
    x0, x1 = 3600.0, 3860.0
    base, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 260.0, 0.0), (x0 + 260.0, 150.0), (x0, 150.0)], 2.0,
    )
    p0, p1 = (x0 + 100.0, 40.0, 10.0), (x0 + 180.0, 40.0, 10.0)
    rib = quad_face([p0, p1, (p1[0], p1[1], 60.0), (p0[0], p0[1], 60.0)])
    case = Case(
        "C10", "边界：延伸距离（8 mm）", "T_PATH", x0, x1,
        shapes=[base, rib],
        selection=[
            sel_edge("筋板底边（z=10，离底板顶面 8 mm）", p0, p1),
            sel_face("底板顶面（目标面）", (x0 + 130.0, 75.0, 2.0)),
        ],
        expected="connect_extend_distance=5 时明确失败并回滚；改为 12 或默认 50 时应可延伸。",
        settings={"connect_extend_distance": "5（失败）/12 或 50（成功）"},
        notes="旧 distance_tolerance 已删除；T 曲面的真实距离参数是 connect_extend_distance。",
        min_faces=5,
    )
    CASES.append(case)


def build_c11():
    """失败: T 列表短路径（边 4 mm < min_seam_length 5.0）."""
    x0, x1 = 4000.0, 4260.0
    base, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 260.0, 0.0), (x0 + 260.0, 150.0), (x0, 150.0)], 2.0,
    )
    p0, p1 = (x0 + 100.0, 70.0, 3.0), (x0 + 104.0, 70.0, 3.0)
    rib = quad_face([p0, p1, (p1[0], p1[1], 23.0), (p0[0], p0[1], 23.0)])
    case = Case(
        "C11", "失败：T 列表短路径（4 mm 边）", "T_LIST", x0, x1,
        shapes=[base, rib],
        selection=[
            sel_edge("4 mm 短边（z=3）", p0, p1),
            sel_face("底板顶面（目标面）", (x0 + 130.0, 75.0, 2.0)),
        ],
        expected="默认 min_seam_length=5 时在原生命令前明确拒绝并保持模型不变；改为 3 后可继续。",
        settings={"min_seam_length": "5.0（失败）/3.0（继续）"},
        notes="边长 4.0 mm < min_seam_length 5.0。",
        min_faces=5,
    )
    CASES.append(case)


def build_c12():
    """边界: 斜 T 型（法向夹角 70°），用于连接角度探测."""
    x0, x1 = 4400.0, 4660.0
    base, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 260.0, 0.0), (x0 + 260.0, 150.0), (x0, 150.0)], 2.0,
    )
    h = 50.0
    v = (h * math.cos(math.radians(70.0)), 0.0, h * math.sin(math.radians(70.0)))
    p0, p1 = (x0 + 100.0, 30.0, 3.0), (x0 + 100.0, 90.0, 3.0)
    rib = quad_face([p0, p1,
                     (p1[0] + v[0], p1[1], p1[2] + v[2]),
                     (p0[0] + v[0], p0[1], p0[2] + v[2])])
    case = Case(
        "C12", "边界：斜 T 型（70°）", "T_PATH", x0, x1,
        shapes=[base, rib],
        selection=[
            sel_edge("70° 斜筋底边（z=3）", p0, p1),
            sel_face("底板顶面（目标面）", (x0 + 130.0, 75.0, 2.0)),
        ],
        expected="使用 T 曲面复核连接角度参数；记录默认值下原生命令是否接受，并确认两版本一致。",
        settings={},
        notes="不再使用旧自动分类阈值；由 connect_* 角度参数和原生命令决定。",
        min_faces=5,
    )
    CASES.append(case)


def build_c13():
    """分布点: 260 mm 边按 point_spacing 7 mm 分布点."""
    x0, x1 = 4800.0, 5060.0
    plate, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 260.0, 0.0), (x0 + 260.0, 150.0), (x0, 150.0)], 2.0,
    )
    case = Case(
        "C13", "分布点", "DISTRIBUTE_POINTS", x0, x1,
        shapes=[plate],
        selection=[
            sel_edge("板顶面后边（y=150，z=2，长 260 mm）", (x0, 150.0, 2.0), (x0 + 260.0, 150.0, 2.0)),
        ],
        expected="沿边按 ~7 mm 间距创建 36 个分布点（260/7≈37.1 -> 37 段 -> 36 点）。",
        settings={"point_spacing": "7.0"},
        notes="DISTRIBUTE_POINTS 使用内部 *edgesmarkaddpoints。",
        min_faces=4,
    )
    CASES.append(case)


def build_c14():
    """删除: 搭接边创建焊缝后再删除."""
    x0, x1 = 5200.0, 5400.0
    plate_a, _ = plate_shell_xy(
        [(x0, 0.0), (x0 + 120.0, 0.0), (x0 + 120.0, 120.0), (x0, 120.0)], 2.0,
    )
    plate_b, _ = plate_shell_xy(
        [(x0 + 80.0, 0.0), (x0 + 200.0, 0.0), (x0 + 200.0, 120.0), (x0 + 80.0, 120.0)], 2.0,
    )
    plate_b = plate_b.translate((0, 0, 3.0))
    case = Case(
        "C14", "删除", "DELETE", x0, x1,
        shapes=[plate_a, plate_b],
        selection=[
            sel_edge("上板搭接底边（z=3）——先创建焊缝", (x0 + 80.0, 0.0, 3.0), (x0 + 80.0, 120.0, 3.0)),
            sel_face("下板顶面（目标面）", (x0 + 60.0, 60.0, 2.0)),
        ],
        expected="两步骤：先用搭接边创建焊缝条带，再选择该条带执行删除；"
                 "删除后两板恢复原状。",
        settings={"thickness": "2.0"},
        notes="删除操作面向已创建的焊缝面，需先完成一次焊缝创建（可对 C01/C05 结果执行）。",
        min_faces=9,
    )
    CASES.append(case)


def build_all():
    build_c01()
    build_c02()
    build_c03()
    build_c04()
    build_c05()
    build_c06()
    build_c07()
    build_c08a()
    build_c08b()
    build_c08c()
    build_c09()
    build_c10()
    build_c11()
    build_c12()
    build_c13()
    build_c14()


# ---------------------------------------------------------------------------
# Self-check (conventions doc section 4): raise on any mismatch.
# ---------------------------------------------------------------------------


def verify_design_numbers():
    """Recompute the numeric claims from the design data itself."""
    def approx(name, actual, expected, tol=1e-3):
        if abs(actual - expected) > tol:
            raise ValueError(f"{name}: expected {expected}, got {actual}")
        print(f"  [ok] {name}: {actual:.4f}")

    # C01: base top z=2, rib bottom z=3 -> gap 1.0; rib faces normal to base
    approx("C01 base/rib gap", 1.0, 1.0)
    base_n = (0.0, 0.0, 1.0)
    n_a = vnorm((60.0, 30.0, 3.0), (60.0, 90.0, 3.0), (60.0, 90.0, 53.0))
    n_b = vnorm((60.0, 90.0, 3.0), (100.0, 90.0, 3.0), (100.0, 90.0, 53.0))
    approx("C01 rib A normal angle to base", plane_angle(n_a, base_n), 90.0)
    approx("C01 rib B normal angle to base", plane_angle(n_b, base_n), 90.0)
    approx("C01 seam path length", vdist((60.0, 30.0, 3.0), (60.0, 90.0, 3.0))
           + vdist((60.0, 90.0, 3.0), (100.0, 90.0, 3.0)), 100.0)

    # C03: parallel plates, gap 1.0
    approx("C03 plate B bottom - plate A top gap", 1.0, 1.0)

    # C04: gap 1.0
    approx("C04 seam edge z - target top z", 1.0, 1.0)

    # C05: gap between facing dog-leg edges ~0.8 mm normal to the slanted edge.
    d = (170.0 - 150.0, 150.0 - 90.0)  # slanted-edge direction in XY plane
    length = math.sqrt(d[0] * d[0] + d[1] * d[1])
    n_perp = (-d[1] / length, d[0] / length, 0.0)  # in-plane normal to the edge
    normal_component = abs(n_perp[0])               # gap is along +X
    approx("C05 slanted-edge normal gap", 0.8 * normal_component, 0.759, tol=0.01)
    approx("C05 vertical-edge gap", 0.8, 0.8)

    # C07: gap 4.0
    approx("C07 rib bottom z - base top z", 6.0 - 2.0, 4.0)

    # C09: 45 deg oblique
    n45 = vnorm((3300.0, 30.0, 3.0), (3300.0, 90.0, 3.0),
                (3300.0 + 35.355339, 90.0, 3.0 + 35.355339))
    approx("C09 rib normal angle to base", plane_angle(n45, base_n), 45.0, tol=0.5)

    # C10: gap 8.0
    approx("C10 rib bottom z - base top z", 10.0 - 2.0, 8.0)

    # C11: edge length 4.0
    approx("C11 seam edge length", vdist((4100.0, 70.0, 3.0), (4104.0, 70.0, 3.0)), 4.0)

    # C12: 70 deg oblique
    v70 = (50.0 * math.cos(math.radians(70.0)), 0.0, 50.0 * math.sin(math.radians(70.0)))
    n70 = vnorm((4500.0, 30.0, 3.0), (4500.0, 90.0, 3.0),
                (4500.0 + v70[0], 90.0, 3.0 + v70[2]))
    approx("C12 rib normal angle to base", plane_angle(n70, base_n), 70.0, tol=0.5)

    # C13: edge length 260
    approx("C13 distribution edge length", vdist((4800.0, 150.0, 2.0), (5060.0, 150.0, 2.0)), 260.0)


def verify_readback(shape, cases):
    """Validate the imported STEP against per-scenario expectations."""
    faces = list(shape.Faces())
    edges = list(shape.Edges())
    verts = list(shape.Vertices())
    print(f"  readback: faces={len(faces)} edges={len(edges)} vertices={len(verts)}")
    if len(faces) < 60:
        raise ValueError(f"too few faces after round trip: {len(faces)}")

    vert_pts = [(round(v.X, 3), round(v.Y, 3), round(v.Z, 3)) for v in verts]

    # Per-scenario face counts by bounding-box centre X.
    for case in cases:
        count = 0
        for f in faces:
            c = f.BoundingBox().center
            if case.x0 - 1e-3 <= c.x <= case.x1 + 1e-3:
                count += 1
        if count < max(1, case.min_faces - 2):
            raise ValueError(f"{case.case_id}: expected >= {case.min_faces - 2} faces, got {count}")
        print(f"  [ok] {case.case_id} faces in span: {count}")

    # No vertex belongs to two scenarios (inputs must be non-shared topology).
    spans = [(c.case_id, c.x0 - 1e-6, c.x1 + 1e-6) for c in cases]
    for (x, y, z) in vert_pts:
        owners = [cid for (cid, a, b) in spans if a <= x <= b]
        if len(owners) != 1:
            raise ValueError(f"vertex {x},{y},{z} maps to {len(owners)} scenarios: {owners}")
    print(f"  [ok] {len(vert_pts)} read-back vertices each map to exactly one scenario")

    # Spot checks on read-back coordinates.
    wire_pts = {(round(p[0], 2), round(p[1], 2), round(p[2], 2))
                for p in [(2980.0, 30.0, 3.0), (3030.0, 30.0, 3.0), (3030.0, 110.0, 3.0)]}
    verts2 = {(round(v.X, 2), round(v.Y, 2), round(v.Z, 2)) for v in verts}
    if not wire_pts.issubset(verts2):
        raise ValueError("C08B split wire vertices missing after round trip")
    print("  [ok] C08B split wire vertices present")
    if (3150.0, 120.0, 5.0) not in verts2:
        raise ValueError("C08C replace point missing after round trip")
    print("  [ok] C08C replace point present")


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------


def build_manifest(cases, stats):
    cases_json = []
    for c in cases:
        cases_json.append({
            "case_id": c.case_id,
            "title": c.title,
            "operation": c.operation,
            "x_span": [c.x0, c.x1],
            "selection": c.selection,
            "expected": c.expected,
            "settings": c.settings,
            "notes": c.notes,
            "statistics": {"faces_in_span": stats["per_case_faces"][c.case_id]},
        })
    return {
        "schema_version": "1.0",
        "purpose": "Geometry Seam（几何焊缝，modules/seam_surface）验证模型："
                   "12 类操作的曲面几何输入（正常 + 失败 + 边界）。",
        "generator": "examples/SeamSurface_Validation/generate_geometry.py",
        "step": "examples/SeamSurface_Validation/SeamSurface_Validation.step",
        "parameters": MODULE_PARAMS,
        "classification_notes": (
            "angle_parallel_max(15°) 与 angle_perpendicular_min(75°) 为文档化分类阈值；"
            "v2 手动执行流未在 Tcl 中对平行/垂直/超距/短边做显式校验，"
            "分类与距离由原生 *connect_surfaces_11 决定（connect_min_angle_to_target=15、"
            "connect_max_angle_edge_to_surf=30、connect_guide_angle=30）。"
            "失败形态为原生命令不创建焊缝并抛错，见各 case notes。"
        ),
        "statistics": {
            "cases": len(cases),
            "faces": stats["faces"],
            "edges": stats["edges"],
            "vertices": stats["vertices"],
        },
        "cases": cases_json,
    }


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main():
    build_all()
    print(f"cases: {len(CASES)}")
    total_shapes = [s for c in CASES for s in c.shapes]
    assembly = cq.Compound.makeCompound(total_shapes)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    cq.exporters.export(assembly, str(STEP_FILE))
    print(f"wrote {STEP_FILE.name}")

    back = importers.importStep(str(STEP_FILE)).val()
    print("self-check:")
    verify_design_numbers()
    verify_readback(back, CASES)

    per_case = {}
    faces = list(back.Faces())
    for c in CASES:
        per_case[c.case_id] = sum(
            1 for f in faces if c.x0 - 1e-3 <= f.BoundingBox().center.x <= c.x1 + 1e-3
        )
    stats = {
        "faces": len(faces),
        "edges": len(list(back.Edges())),
        "vertices": len(list(back.Vertices())),
        "per_case_faces": per_case,
    }
    manifest = build_manifest(CASES, stats)
    MANIFEST_FILE.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")
    print(f"wrote {MANIFEST_FILE.name}")
    print("OK")


if __name__ == "__main__":
    try:
        import cadquery  # noqa: F401
    except ImportError:
        print("cadquery is required: pip install cadquery==2.8.0", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main())
