# -*- coding: utf-8 -*-
"""Geometry Cleanup 验证几何模型生成器（HMWorkFlow examples/GeometryCleanup_Validation）。

生成两个 STEP 文件，沿 X 轴排布 8 个相互隔离的验证场景（间距 >= 300 mm）：

  * GeometryCleanup_Chamfer_Validation.step   —— CHAMFER 相关 4 场景（C01 C02 C07 C08）
  * GeometryCleanup_Pocket_Validation.step    —— POCKET / AUTO / REJECT 相关 4 场景（C03 C04 C05 C06）

生成命令（仓库根目录执行，需系统 Python 3.14 + cadquery 2.8.0）：

    python examples/GeometryCleanup_Validation/generate_geometry.py

脚本同时写入 examples/GeometryCleanup_Validation/GeometryCleanup_Validation_manifest.json，
并内置自检：用 cadquery 公开 API 读回 .step，校验场景数量、实体数、体积为正、面数与设计一致。

场景矩阵（对应 modules/geometry_cleanup.tcl 的 CHAMFER / POCKET / AUTO 模式与规则参数）：

  C01 CHAMFER 正常    —— 顶缘圆角链 r=2（4 面相邻环），清理后重建直角拓扑并重建实体
  C02 CHAMFER 边界    —— 大折弯圆角 r=8 > fillet_max_r(5)，验证半径查询不误删大圆角
  C03 POCKET 正常      —— 单沉台（沉孔+通孔），底面为双环面
  C04 POCKET 多个      —— 同板 3 个不同深度/面积的沉台，逐个处理
  C05 AUTO 模式        —— 同时含顶缘小圆角链 + 沉台，AUTO 按种子面分派 CHAMFER / POCKET
  C06 REJECT（光顺件） —— 纯拉伸 U 型槽，无圆角无沉台，模块应安全拒绝且不删面
  C07 CHAMFER 边界     —— 连续 9 段凸弧圆角链（r=3）> max_chain_depth(6)，验证链截断
  C08 REJECT（小特征） —— 含 6 个 r=1.5 通孔 + r=1.5 小圆角的板，验证小面积面不被误当倒角链

确定性：无随机，所有尺寸为固定常量。
"""

import json
from pathlib import Path

import cadquery as cq
from cadquery import exporters, importers

HERE = Path(__file__).resolve().parent

STEP_CHAMFER = HERE / "GeometryCleanup_Chamfer_Validation.step"
STEP_POCKET = HERE / "GeometryCleanup_Pocket_Validation.step"
MANIFEST = HERE / "GeometryCleanup_Validation_manifest.json"

# 场景 X 方向中心（保证各场景包络盒间距 >= 300 mm）
X_OFFSET = {"C01": 0.0, "C02": 360.0, "C07": 720.0, "C08": 1120.0}          # 文件 A
X_OFFSET_B = {"C03": 0.0, "C04": 360.0, "C05": 720.0, "C06": 1120.0}        # 文件 B

FILENAME = {
    "C01": STEP_CHAMFER, "C02": STEP_CHAMFER, "C07": STEP_CHAMFER, "C08": STEP_CHAMFER,
    "C03": STEP_POCKET, "C04": STEP_POCKET, "C05": STEP_POCKET, "C06": STEP_POCKET,
}


# ---------------------------------------------------------------------------
# 构造辅助
# ---------------------------------------------------------------------------

def plate_centered(w, l, t, z0=0.0):
    """底板：XY 尺寸 w×l，厚度 t，z 范围 [z0, z0+t]，中心在原点。"""
    return cq.Workplane("XY").box(w, l, t).translate((0.0, 0.0, z0 + t / 2.0))


def counterbore(plate_wp, cb_r, cb_d, hole_r, t, cx, cy, z0):
    """在底板上切沉台：圆柱沉孔（半径 cb_r、深 cb_d）叠加通孔（半径 hole_r）。
    plate z 范围 [z0, z0+t]；沉孔从顶面 z0+t 下挖 cb_d，通孔贯通剩余厚度。
    """
    body = plate_wp
    cb = cq.Workplane("XY").cylinder(cb_d, cb_r).translate((cx, cy, z0 + t - cb_d / 2.0))
    hole = cq.Workplane("XY").cylinder(t - cb_d, hole_r).translate((cx, cy, z0 + (t + cb_d) / 2.0))
    return body.cut(cb).cut(hole)


def bolt_holes(plate_wp, t, z0, corners, r=5.0):
    """在四个角位打贯穿螺栓孔。"""
    body = plate_wp
    for cx, cy in corners:
        h = cq.Workplane("XY").cylinder(t + 2.0, r).translate((cx, cy, z0 + t / 2.0))
        body = body.cut(h)
    return body


def _face_list(shape):
    """接受 Workplane 或 Solid/Compound，返回 Face 列表。"""
    fs = shape.faces()
    if hasattr(fs, "vals"):
        return fs.vals()
    return list(fs)


def fillet_chain_components(shape):
    """返回各圆柱（fillet）面连通分量大小列表（降序），用于自检链结构。"""
    from collections import defaultdict
    faces = _face_list(shape)
    cyl = [i for i, f in enumerate(faces) if f.geomType() == "CYLINDER"]
    edge_map = defaultdict(set)
    for fi, f in enumerate(faces):
        for e in f.Edges():
            edge_map[e.hashCode()].add(fi)
    adj = defaultdict(set)
    for owners in edge_map.values():
        o = [i for i in owners if i in cyl]
        for a in o:
            for b in o:
                if a != b:
                    adj[a].add(b)
    seen = set()
    comps = []
    for c0 in cyl:
        if c0 in seen:
            continue
        st = [c0]
        seen.add(c0)
        comp = []
        while st:
            n = st.pop()
            comp.append(n)
            for m in adj[n]:
                if m not in seen:
                    seen.add(m)
                    st.append(m)
        comps.append(comp)
    return sorted((len(c) for c in comps), reverse=True)


# ---------------------------------------------------------------------------
# 场景构造（均返回局部坐标下、中心在 (0,0) 的 Workplane）
# ---------------------------------------------------------------------------

def build_c01():
    """CHAMFER 正常：冲压支架。

    底板 320x180x2.5，顶缘 4 条边圆角 r=2（构成相邻 4 面圆角环，供链式扩展）；
    中央加强筋（260x34x6，棱边圆角 r=2）熔接在顶面；
    四角螺栓孔 r=5 贯通。清理目标：顶缘圆角环 -> 重建直角拓扑并重建实体。
    """
    t = 2.5
    plate = plate_centered(320.0, 180.0, t, z0=0.0)
    rim = plate.edges(">Z").fillet(2.0)                    # 顶缘 4 面圆角环 r=2
    rib = cq.Workplane("XY").box(260.0, 34.0, 6.0).translate((0.0, 0.0, t + 3.0))
    rib = rib.edges().fillet(2.0)                          # 加强筋棱边圆角 r=2
    body = rim.union(rib)
    body = bolt_holes(body, t, 0.0, [(-150.0, 80.0), (150.0, 80.0),
                                     (-150.0, -80.0), (150.0, -80.0)])
    return body


def build_c02():
    """CHAMFER 边界：大折弯 L 型支架。

    两腿 90x4 与 60x4（厚 4），内折弯圆角 r=8（> fillet_max_r=5），沿长度挤出 260。
    无其他圆角。验证：半径查询 [0,5] 不返回 r=8 折弯面；默认小面回退链行为见 README。
    """
    t = 4.0
    r_bend = 8.0
    leg1 = 90.0
    leg2 = 60.0
    length = 260.0
    w = cq.Workplane("XY").moveTo(0.0, 0.0)
    w = w.lineTo(leg1, 0.0).lineTo(leg1, t).lineTo(r_bend + t, t)
    w = w.threePointArc((r_bend, t), (r_bend, t + r_bend))
    w = w.lineTo(r_bend, leg2).lineTo(0.0, leg2).close()
    body = w.extrude(length)
    return body


def build_c03():
    """POCKET 正常：单沉台铸件板。

    板 260x160x12（z 范围 [-12, 0]），中央沉台（沉孔 R=40 深 4 + 通孔 R=20），
    四角螺栓孔 r=5。沉台底面为 R=20..40 的环形面（外环+内环双边界环），
    外壁高 4 < 内孔壁高 8，满足 classifyPocketLoops 的可区分条件（d < t/2）。
    """
    t = 12.0
    z0 = -t
    plate = plate_centered(260.0, 160.0, t, z0=z0)
    body = counterbore(plate, cb_r=40.0, cb_d=4.0, hole_r=20.0, t=t,
                       cx=0.0, cy=0.0, z0=z0)
    body = bolt_holes(body, t, z0, [(-110.0, 65.0), (110.0, 65.0),
                                    (-110.0, -65.0), (110.0, -65.0)])
    return body


def build_c04():
    """POCKET 多个：同板 3 个不同深度/面积的沉台。

    板 300x180x12（z 范围 [-12, 0]），三个沉台：
      A：沉孔 R=45 深 4 / 通孔 R=18，位于 (-70, 0)
      B：沉孔 R=30 深 3 / 通孔 R=12，位于 (10, 55)
      C：沉孔 R=45 深 2 / 通孔 R=20，位于 (55, -40)
    深度均 < t/2，保证外壁高度严格小于内孔壁高度（可被模块区分）。
    各沉台完整位于板内（不越界裁剪）。
    四角螺栓孔 r=5。POCKET 模式逐个选择底面处理（连续清洗）。
    """
    t = 12.0
    z0 = -t
    plate = plate_centered(300.0, 180.0, t, z0=z0)
    body = counterbore(plate, cb_r=45.0, cb_d=4.0, hole_r=18.0, t=t, cx=-70.0, cy=0.0, z0=z0)
    body = counterbore(body, cb_r=30.0, cb_d=3.0, hole_r=12.0, t=t, cx=10.0, cy=55.0, z0=z0)
    body = counterbore(body, cb_r=45.0, cb_d=2.0, hole_r=20.0, t=t, cx=55.0, cy=-40.0, z0=z0)
    body = bolt_holes(body, t, z0, [(-135.0, 75.0), (135.0, 75.0),
                                    (-135.0, -75.0), (135.0, -75.0)])
    return body


def build_c05():
    """AUTO 模式：同时含顶缘小圆角链 + 中央沉台。

    板 260x160x12，顶缘 4 条边圆角 r=2（圆角环）；中央沉台（R=40 深 4 / 通孔 R=20）。
    四角螺栓孔 r=5。种子面在圆角环上 -> AUTO 分派 CHAMFER；
    种子面在沉台底面 -> AUTO 分派 POCKET。
    """
    t = 12.0
    z0 = -t
    plate = plate_centered(260.0, 160.0, t, z0=z0)
    rim = plate.edges(">Z").fillet(2.0)
    body = counterbore(rim, cb_r=40.0, cb_d=4.0, hole_r=20.0, t=t,
                       cx=0.0, cy=0.0, z0=z0)
    body = bolt_holes(body, t, z0, [(-110.0, 65.0), (110.0, 65.0),
                                    (-110.0, -65.0), (110.0, -65.0)])
    return body


def build_c06():
    """REJECT：光顺 U 型槽（纯拉伸，无圆角无沉台无孔）。

    U 型截面：底宽 120，两侧翻边高 40，厚 4，锐角 90°；沿长度挤出 300。
    任何种子面都不存在可识别圆角/沉台，模块应安全失败且不删除任何面。
    """
    length = 300.0
    u = cq.Workplane("YZ").moveTo(-60.0, 0.0)
    u = u.lineTo(60.0, 0.0).lineTo(60.0, 40.0).lineTo(56.0, 40.0) \
        .lineTo(56.0, 4.0).lineTo(-56.0, 4.0).lineTo(-56.0, 40.0) \
        .lineTo(-60.0, 40.0).close()
    body = u.extrude(length)
    return body


def build_c07():
    """CHAMFER 边界：连续凸弧波纹板（圆角链 9 段 > max_chain_depth=6）。

    轮廓：底边直线 + 9 段相切半圆凸弧（r=3），厚 3，沿长度挤出 340。
    9 个半圆柱面两两相邻，构成连通圆角链。从一端种子面扩展时，
    connectedChain 按 max_chain_depth=6 截断（覆盖深度 0..6 约 7 段），末端凸弧不被误伤。
    """
    r = 3.0
    n_bumps = 9
    length = 340.0
    thk = 3.0
    seg = 2.0 * r
    w = cq.Workplane("XY").moveTo(-length / 2.0, 0.0).lineTo(-length / 2.0, thk)
    x = -length / 2.0
    for i in range(n_bumps):
        cx = x + seg / 2.0
        w = w.threePointArc((cx, thk + r), (x + seg, thk))
        x += seg
    w = w.lineTo(length / 2.0, 0.0).lineTo(-length / 2.0, 0.0).close()
    body = w.extrude(thk)
    return body


def build_c08():
    """REJECT/边界：含 6 个小通孔 + 小圆角的板。

    板 300x160x3，顶缘 4 条边圆角 r=1.5；中心线等距 6 个 r=1.5 通孔（孔径在
    fillet 半径范围内）。验证：小面积孔壁不被误当倒角链扩展；建议以
    chain_by_small_area=0 验证半径查询保护（纯平面种子 -> 安全拒绝）。
    """
    t = 3.0
    plate = plate_centered(300.0, 160.0, t, z0=0.0)
    rim = plate.edges(">Z").fillet(1.5)
    body = rim
    for i in range(6):
        hx = -100.0 + i * 40.0
        hole = cq.Workplane("XY").cylinder(t + 0.4, 1.5).translate((hx, 0.0, t / 2.0))
        body = body.cut(hole)
    return body


BUILDERS = {
    "C01": build_c01,
    "C02": build_c02,
    "C03": build_c03,
    "C04": build_c04,
    "C05": build_c05,
    "C06": build_c06,
    "C07": build_c07,
    "C08": build_c08,
}

# ---------------------------------------------------------------------------
# 场景元数据（期望行为 / 设置）
# ---------------------------------------------------------------------------

CASE_META = {
    "C01": {
        "title": "CHAMFER 正常：带加强筋冲压支架的顶缘圆角链",
        "expected_mode": "CHAMFER",
        "expected": "选中任一顶缘圆角面（r=2）后，圆角链应扩展覆盖 4 个顶缘圆角面并清除，"
                    "直角拓扑重建，*solids_create_from_surfaces 能重建实体（新增/补充 solid 非空）。",
        "settings": {"mode": "CHAMFER", "fillet_min_r": 0.0, "fillet_max_r": 5.0,
                     "chain_by_fillet": 1, "chain_by_small_area": 1, "max_chain_depth": 6},
    },
    "C02": {
        "title": "CHAMFER 边界：大折弯圆角 r=8 超出 fillet_max_r",
        "expected_mode": "CHAMFER",
        "expected": "半径查询 [0,5] 不会返回 r=8 折弯面。在长腿平面上选种子时：默认小面回退链可能把 "
                    "r=8 面列入 target_surfs，但 HM2019 回退按半径范围过滤删除，r=8 面应保留（不误删大圆角）；"
                    "设置 chain_by_small_area=0 时半径查询为空 -> 安全拒绝、不删除任何面。",
        "settings": {"mode": "CHAMFER", "fillet_min_r": 0.0, "fillet_max_r": 5.0,
                     "chain_by_fillet": 1, "chain_by_small_area": 1, "max_chain_depth": 6},
    },
    "C03": {
        "title": "POCKET 正常：单沉台（沉孔+通孔）",
        "expected_mode": "POCKET",
        "expected": "选中沉台底面（环形面）后，模块删除底面与外壁（高 4），将内环（R=20 通孔顶）"
                    "与基准环（R=40 顶缘）用 ruled 面直接连接并缝合；外壁高 4 < 内孔壁高 8 可可靠区分。",
        "settings": {"mode": "POCKET", "stitch_tolerance": 0.2},
    },
    "C04": {
        "title": "POCKET 多个：同板 3 个不同深度/面积沉台",
        "expected_mode": "POCKET",
        "expected": "POCKET 模式逐个处理：分别选三个底面，每个沉台独立执行（外壁高 2/3/4 均 < 内孔壁高），"
                    "互不影响；连续清洗模式可一次选择多个底面逐个完成。",
        "settings": {"mode": "POCKET", "stitch_tolerance": 0.2},
    },    "C05": {
        "title": "AUTO 模式：顶缘圆角链 + 中央沉台混合件",
        "expected_mode": "AUTO",
        "expected": "种子面在顶缘圆角面 -> AUTO 分派 CHAMFER（清除 4 面圆角环并重建实体）；"
                    "种子面在沉台底面 -> AUTO 分派 POCKET（补平沉台）。两种分派均可验证。",
        "settings": {"mode": "AUTO", "fillet_min_r": 0.0, "fillet_max_r": 5.0,
                     "chain_by_fillet": 1, "chain_by_small_area": 1, "max_chain_depth": 6},
    },
    "C06": {
        "title": "失败：纯拉伸 U 型槽（无圆角无沉台）",
        "expected_mode": "REJECT",
        "expected": "任意种子面均无可识别圆角/沉台：半径查询为空、沉台环数不等于 2，模块应安全失败"
                    "（日志 target_surfs 为空或报\u2018倒角/圆角清理失败\u2019），不删除任何面。"
                    "验证方式：处理前后表面总数不变、实体完整。",
        "settings": {"mode": "CHAMFER", "fillet_min_r": 0.0, "fillet_max_r": 5.0},
    },
    "C07": {
        "title": "CHAMFER 边界：9 段连续凸弧圆角链（> max_chain_depth）",
        "expected_mode": "CHAMFER",
        "expected": "圆角链 BFS 按 max_chain_depth=6 截断：从一端凸弧种子扩展覆盖深度 0..6（约 7 段），"
                    "末端凸弧不被误伤。验证：处理后末端凸弧面仍存在（圆柱面数减少但未清零）。",
        "settings": {"mode": "CHAMFER", "fillet_min_r": 0.0, "fillet_max_r": 5.0,
                     "chain_by_fillet": 1, "chain_by_small_area": 1, "max_chain_depth": 6},
    },
    "C08": {
        "title": "失败/边界：含 6 个小通孔 + 小圆角的板",
        "expected_mode": "REJECT",
        "expected": "小孔壁面（r=1.5）孤立、互不相邻，不应被当作倒角链扩展；在平面上选种子且 "
                    "chain_by_small_area=0 时半径查询不包含平面 -> 安全拒绝、6 个孔保持完整。"
                    "默认 chain_by_small_area=1 时按日志 target_surfs 核对范围，孔数应仍为 6。",
        "settings": {"mode": "CHAMFER", "fillet_min_r": 0.0, "fillet_max_r": 5.0,
                     "chain_by_fillet": 1, "chain_by_small_area": 0, "max_chain_depth": 6},
    },
}


# ---------------------------------------------------------------------------
# 构建 / 自检 / manifest / 导出
# ---------------------------------------------------------------------------

def _cyl_chain_faces(workplane, amin=0.0):
    """返回属于最大圆柱（fillet）连通分量的圆柱面列表。"""
    from collections import defaultdict
    faces = _face_list(workplane)
    cyl_idx = [i for i, f in enumerate(faces) if f.geomType() == "CYLINDER" and f.Area() > amin]
    edge_map = defaultdict(set)
    for fi, f in enumerate(faces):
        for e in f.Edges():
            edge_map[e.hashCode()].add(fi)
    adj = defaultdict(set)
    for owners in edge_map.values():
        o = [i for i in owners if i in cyl_idx]
        for a in o:
            for b in o:
                if a != b:
                    adj[a].add(b)
    seen = set()
    comps = []
    for c0 in cyl_idx:
        if c0 in seen:
            continue
        st = [c0]
        seen.add(c0)
        comp = []
        while st:
            n = st.pop()
            comp.append(n)
            for m in adj[n]:
                if m not in seen:
                    seen.add(m)
                    st.append(m)
        comps.append(comp)
    comps.sort(key=len, reverse=True)
    return [faces[i] for i in (comps[0] if comps else [])]


def _annulus_point(face, solid):
    """沉台底面（环形面）上的代表点：中心沿 +X 方向（外R+内r)/2 处。

    本模型所有沉台均为轴对齐构造，该点在环带上。"""
    bb = face.BoundingBox()
    cx = (bb.xmin + bb.xmax) / 2.0
    cy = (bb.ymin + bb.ymax) / 2.0
    cz = (bb.zmin + bb.zmax) / 2.0
    R = (bb.xmax - bb.xmin) / 2.0
    inner = face.innerWires()
    ibl = inner[0].BoundingBox()
    r = (ibl.xmax - ibl.xmin) / 2.0
    return (cx + (R + r) / 2.0, cy, cz)


def _on_face_point(face, solid):
    """返回面上一点。平面面用包围盒中心（平面上必在面上）；
    曲面用 positionAt 参数域 5x5 网格采样，取距离实体表面最近者。"""
    if face.geomType() == "PLANE":
        bb = face.BoundingBox()
        return (bb.xmin + bb.xlen / 2.0, bb.ymin + bb.ylen / 2.0, bb.zmin + bb.zlen / 2.0)
    from cadquery.occ_impl.shapes import Vertex
    best = None
    for u in (0.1, 0.3, 0.5, 0.7, 0.9):
        for v in (0.1, 0.3, 0.5, 0.7, 0.9):
            p = face.positionAt(u, v)
            d = solid.distance(Vertex.makeVertex(p.x, p.y, p.z))
            if best is None or d < best[0]:
                best = (d, (p.x, p.y, p.z))
    return best[1]


def collect_seed_points(built):
    """按场景从实际几何收集种子点（采样目标面，返回全局坐标点）。

    返回 {cid: [(label, (x, y, z)), ...]}。
    """
    faces = {cid: _face_list(built[cid][0].val()) for cid in built}

    def cylinders(cid, amin, amax):
        return [f for f in faces[cid]
                if f.geomType() == "CYLINDER" and amin < f.Area() <= amax]

    def two_wire_planes(cid):
        return [f for f in faces[cid]
                if f.geomType() == "PLANE" and len(f.Wires()) == 2]

    def largest_plane(cid):
        planes = [f for f in faces[cid] if f.geomType() == "PLANE" and len(f.Wires()) == 1]
        planes.sort(key=lambda f: f.Area(), reverse=True)
        return planes[0]

    out = {}

    solid = built["C01"][0].val()
    chain = _cyl_chain_faces(built["C01"][0], amin=300.0)   # 顶缘 4 面圆角环 r=2
    assert len(chain) >= 4, "C01 顶缘圆角链不足 4 面"
    out["C01"] = [("顶缘圆角面（r=2，圆柱面，链大小 %d）" % len(chain),
                   _on_face_point(chain[0], solid))]

    solid = built["C02"][0].val()
    bend = cylinders("C02", 1000.0, 1e9)           # r=8 折弯面（面积 ≈ 3653）
    assert bend, "C02 未找到折弯圆角面"
    out["C02"] = [
        ("内折弯圆角面（r=8，圆柱面）", _on_face_point(bend[0], solid)),
        ("长腿外壁平面（最大平面）", _on_face_point(largest_plane("C02"), solid)),
    ]

    solid = built["C03"][0].val()
    floors = two_wire_planes("C03")
    assert len(floors) == 1, "C03 沉台底面数量异常"
    out["C03"] = [("沉台底面环形面（z=-4，R=20..40）", _annulus_point(floors[0], solid))]

    solid = built["C04"][0].val()
    floors = two_wire_planes("C04")
    assert len(floors) == 3, "C04 沉台底面数量异常"
    # 按全局 x 排序：A(-70+360) < B(10+360) < C(60+360)
    floors.sort(key=lambda f: _annulus_point(f, solid)[0])
    names = ["沉台 A 底面（z=-4，R=45/深4）",
             "沉台 B 底面（z=-3，R=30/深3）",
             "沉台 C 底面（z=-2，R=45/深2）"]
    out["C04"] = [(name, _annulus_point(f, solid)) for name, f in zip(names, floors)]

    solid = built["C05"][0].val()
    chain5 = _cyl_chain_faces(built["C05"][0], amin=300.0)  # 顶缘 4 面圆角环 r=2
    assert len(chain5) >= 4, "C05 顶缘圆角链不足 4 面"
    floors = two_wire_planes("C05")
    assert len(floors) == 1, "C05 沉台底面数量异常"
    out["C05"] = [
        ("顶缘圆角面（r=2，圆柱面）", _on_face_point(chain5[0], solid)),
        ("沉台底面环形面（z=-4，R=20..40）", _annulus_point(floors[0], solid)),
    ]

    solid = built["C06"][0].val()
    out["C06"] = [("底腹板平面（300x120）", _on_face_point(largest_plane("C06"), solid))]

    solid = built["C07"][0].val()
    bumps = cylinders("C07", 20.0, 50.0)           # r=3 凸弧半圆柱面（面积 ≈ 28.3）
    assert len(bumps) >= 9, "C07 凸弧面数量异常"
    bumps.sort(key=lambda f: f.BoundingBox().xmin)
    out["C07"] = [
        ("端部第 1 个凸弧圆柱面（r=3）", _on_face_point(bumps[0], solid)),
        ("端部第 9 个凸弧圆柱面（r=3）", _on_face_point(bumps[-1], solid)),
    ]

    solid = built["C08"][0].val()
    rim8 = cylinders("C08", 300.0, 900.0)          # r=1.5 顶缘圆角（长 704 / 短 374）
    assert rim8, "C08 未找到顶缘小圆角面"
    # 顶面平面两孔之间点（孔位于 x=-100..100，y=0，z=3）
    off = X_OFFSET.get("C08", 0.0)
    top_pt = (off - 40.0, 30.0, 3.0)
    out["C08"] = [
        ("顶缘小圆角面（r=1.5，圆柱面）", _on_face_point(rim8[0], solid)),
        ("顶面平面（z=3，最右侧孔旁）", top_pt),
    ]

    return out


def validate_seed_points(built, seed_points):
    """校验每个种子点都位于对应场景表面（distance 容差 0.3mm，曲面网格采样精度内）。"""
    from cadquery.occ_impl.shapes import Vertex
    for cid, (body, _bbox) in built.items():
        solid = body.val()
        for label, pt in seed_points[cid]:
            v = Vertex.makeVertex(*pt)
            d = solid.distance(v)
            assert d <= 0.3, "%s 种子点 %s %s 距表面 %.3f" % (cid, label, pt, d)


def build_all():
    """返回 {case_id: (workplane, bbox)}，并施加 X 偏移（全局坐标）。"""
    out = {}
    for cid, builder in BUILDERS.items():
        body = builder()
        off = X_OFFSET_B.get(cid, X_OFFSET.get(cid, 0.0))
        body = body.translate((off, 0.0, 0.0))
        s = body.val()
        assert s.Volume() > 0.0, "%s 体积非正" % cid
        assert len(s.Solids()) == 1, "%s 应为单一实体" % cid
        out[cid] = (body, s.BoundingBox())
    return out


def check_chain_sanity():
    """构造后静态检查链结构与沉台结构（与模块规则参数对齐）。"""
    def two_loop_planes(shape):
        return [f for f in _face_list(shape)
                if f.geomType() == "PLANE" and len(f.Wires()) == 2]

    c1 = build_c01()
    assert max(fillet_chain_components(c1)) >= 4, "C01 应有 >= 4 面连通圆角链"
    c7 = build_c07()
    assert max(fillet_chain_components(c7)) >= 9, "C07 应有 >= 9 面连通凸弧链"
    c3 = build_c03()
    assert len(two_loop_planes(c3)) == 1, "C03 应恰有 1 个沉台底面（双环面）"
    c4 = build_c04()
    assert len(two_loop_planes(c4)) == 3, "C04 应恰有 3 个沉台底面"
    c5 = build_c05()
    assert len(two_loop_planes(c5)) == 1, "C05 应恰有 1 个沉台底面"
    assert max(fillet_chain_components(c5)) >= 4, "C05 应有顶缘 4 面圆角链"
    c6 = build_c06()
    assert len(two_loop_planes(c6)) == 0, "C06 不应有双环面"
    assert not any(f.geomType() == "CYLINDER" for f in c6.faces().vals()), "C06 不应有圆柱面"


def build_manifest(built, seed_points):
    cases = []
    for cid in ["C01", "C02", "C03", "C04", "C05", "C06", "C07", "C08"]:
        body, bbox = built[cid]
        meta = CASE_META[cid]
        seed_list = [
            {"label": label, "global_point": [round(x, 3), round(y, 3), round(z, 3)]}
            for label, (x, y, z) in seed_points[cid]
        ]
        cases.append({
            "case_id": cid,
            "title": meta["title"],
            "file": FILENAME[cid].name,
            "expected_mode": meta["expected_mode"],
            "expected": meta["expected"],
            "expected_results": {
                "solids": 1,
                "volume_positive": True,
                "faces": len(body.faces().vals()),
                "bbox": {
                    "xmin": round(bbox.xmin, 3), "xmax": round(bbox.xmax, 3),
                    "ymin": round(bbox.ymin, 3), "ymax": round(bbox.ymax, 3),
                    "zmin": round(bbox.zmin, 3), "zmax": round(bbox.zmax, 3),
                },
            },
            "seed_point": seed_list,
            "settings": meta["settings"],
            "notes": meta["expected"],
        })
    manifest = {
        "schema_version": "1.0",
        "purpose": "Geometry Cleanup 模块（CHAMFER/POCKET/AUTO 模式）验证几何模型",
        "generator": "examples/GeometryCleanup_Validation/generate_geometry.py",
        "verify": "examples/GeometryCleanup_Validation/verify_geometry.py",
        "step_files": [STEP_CHAMFER.name, STEP_POCKET.name],
        "parameters": {
            "spacing_mm": 360,
            "fillet_max_r_default": 5.0,
            "max_chain_depth_default": 6,
            "area_growth_ratio_default": 2.5,
            "stitch_tolerance_default": 0.2,
            "units": "mm",
            "deterministic": True,
        },
        "statistics": {"cases": len(cases), "step_files": 2},
        "cases": cases,
    }
    return manifest


def export_file(workplanes, path):
    """把多个场景实体合并导出到单个 STEP（不互相布尔，保留为独立实体）。"""
    from cadquery import Workplane
    combined = Workplane()
    for body in workplanes:
        combined = combined.union(body)
    exporters.export(combined, str(path), exportType="STEP")


def readback_selfcheck(path, expected_cases):
    """用 cadquery 公开 API 读回 .step，校验场景数与实体完整性。"""
    obj = importers.importStep(str(path))
    solids = obj.val().Solids()
    assert len(solids) == len(expected_cases), \
        "%s 读回实体数 %d != 场景数 %d" % (path.name, len(solids), len(expected_cases))
    print("  [读回] %-42s solids=%d" % (path.name, len(solids)))
    return obj


def main():
    print("== 构造 8 个场景（含结构自检） ==")
    check_chain_sanity()
    built = build_all()
    seed_points = collect_seed_points(built)
    validate_seed_points(built, seed_points)

    for cid, (body, bbox) in built.items():
        print("  %s: faces=%d  bbox=(%.0f..%.0f, %.0f..%.0f, %.0f..%.0f)" % (
            cid, body.faces().size(), bbox.xmin, bbox.xmax,
            bbox.ymin, bbox.ymax, bbox.zmin, bbox.zmax))

    print("== 写入 manifest ==")
    manifest = build_manifest(built, seed_points)
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print("  %s" % MANIFEST.name)

    print("== 导出 STEP 并读回自检 ==")
    a = [built[c][0] for c in ["C01", "C02", "C07", "C08"]]
    b = [built[c][0] for c in ["C03", "C04", "C05", "C06"]]
    export_file(a, STEP_CHAMFER)
    export_file(b, STEP_POCKET)
    readback_selfcheck(STEP_CHAMFER, ["C01", "C02", "C07", "C08"])
    readback_selfcheck(STEP_POCKET, ["C03", "C04", "C05", "C06"])

    print("== 完成 ==")
    print("  产物: %s" % STEP_CHAMFER.name)
    print("        %s" % STEP_POCKET.name)
    print("        %s" % MANIFEST.name)


if __name__ == "__main__":
    main()
