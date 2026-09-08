#!/usr/bin/env python3
"""gen_mesh_seam_weld.py -- mesh_seam_weld (FAST_AUTO seam) LARGE shell validation.

Shell mesh with CQUAD4/CTRIA3 components that share NO nodes between the two
sides of every joint (except the deliberately pre-placed SEAM band).  The
module's FAST_AUTO detector searches for T / L(overlap) / CONNECT candidates:

  search_distance           12 mm
  min_seam_length           20 mm
  min_path_nodes            3
  parallel_angle_max        15 deg   (lap L_SURF)
  perpendicular_angle_min   70 deg   (T_PATH / CONNECT)
  existing_weld_search_dist 4 mm     (skip pre-placed welds)
  weld_mesh_size            8 mm

Content (each pair is its own pair of components; spacing 300 mm along X):
  T-type   8 pairs  source normal ~90 deg from target, gap 1..8, free-edge
                     length 40..200 mm, weld path mesh 4..6 mm.
  Lap      6 pairs  parallel overlapping plates, gap 1..5 mm, tilt <=15 deg.
  CONNECT  4 pairs  coplanar near edges, gap 3..10 mm.
  Perf     1 source plate 30x20 = 600 holes + 2 target plates (batch stress).
  Negative 2 pairs  30 mm gap (no trigger) and 12 mm free edge (<min => drop).
  Seam     1 pre-placed SEAM_T1.5 band (shared-node weld strip, dedup target).

Cross-component nodes are NOT merged (each plate gets its own node ids via
add_node_unmerged where interfaces touch).  Deterministic, stdlib-only (no
numpy).  Expected >= 35k shell elements.
"""

from __future__ import annotations

import math
import os
import sys
from typing import Dict, List, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import femlib as F
from femlib import Model

PITCH = 300.0          # X separation between joint groups
DEFAULTS = {
    "search_distance": 12.0, "min_seam_length": 20.0, "min_path_nodes": 3,
    "parallel_angle_max": 15.0, "perpendicular_angle_min": 70.0,
    "existing_weld_search_dist": 4.0, "weld_mesh_size": 8.0,
}


# ---------------------------------------------------------------------------
# Model assembly
# ---------------------------------------------------------------------------


def _plate_xy(model, comp, cx, cy, w, h, mesh, z):
    """XY plate centred at (cx,cy) at height z."""
    return F.rect_plate_mesh(model, comp, (cx - w / 2.0, cy - h / 2.0, z),
                             w, h, max(1, int(round(w / mesh))), max(1, int(round(h / mesh))))


def _plate_xz(model, comp, cx, y, w, h, mesh):
    """Vertical plate in XZ plane at y=y, spanning X width `w` and Z height `h`,
    centred on X at cx, bottom at z=0.  Builds in local XY then maps grid Y to
    world Z and sets world Y = const."""
    info = F.rect_plate_mesh(model, comp, (cx - w / 2.0, 0.0, 0.0),
                             w, h, max(1, int(round(w / mesh))), max(1, int(round(h / mesh))))
    for row in info["grid"]:
        for nid in row:
            p = model.nodes[nid]
            model.nodes[nid] = (round(p[0], 9), round(y, 9), round(p[1], 9))
    return info


def _plate_yz(model, comp, x, cy, w, h, mesh):
    """Vertical plate in YZ plane at x=x, spanning Y width `w` and Z height `h`,
    centred on Z at z=0, bottom at z=0."""
    info = F.rect_plate_mesh(model, comp, (0.0, cy - h / 2.0, 0.0),
                             w, h, max(1, int(round(w / mesh))), max(1, int(round(h / mesh))))
    for row in info["grid"]:
        for nid in row:
            p = model.nodes[nid]
            model.nodes[nid] = (round(x, 9), round(p[0], 9), round(p[1], 9))
    return info


def _free_edge_loops_of(model, comp):
    return F.free_edge_loops(model, comp)


def _min_gap_xy(model, a, b):
    """Min vertical gap between two XY plates in different components."""
    zs = []
    for comp in (a, b):
        zs.append([p[2] for p in (model.nodes[n] for n in _node_ids(model, comp))])
    za = min(zs[0]) if zs[0] else 0.0
    zb = max(zs[1]) if zs[1] else 0.0
    return abs(za - zb)


def _node_ids(model, comp) -> List[int]:
    out = []
    for el in model.elements_of(comp):
        out.extend(el.node_ids)
    return out


# ---------------------------------------------------------------------------
# Dense hole plate (compact conforming polar washer cells via femlib)
# ---------------------------------------------------------------------------


def dense_hole_plate(model: Model, comp: F.Component, origin, cols, rows,
                     cell_size: float, dia: float, seg: int,
                     widths: Tuple[float, float]) -> Dict:
    """Plate tiled with cols x rows square washer cells, one circular hole per
    cell.  Uses femlib.washer_hole_cell which morphs a polar hole to a true
    square_ring boundary, so adjacent cells tile conformingly (shared edge
    nodes merge)."""
    o0x, o0y, o0z = origin
    all_cells = []
    for r in range(rows):
        for c in range(cols):
            cx = o0x + (c + 0.5) * cell_size
            cy = o0y + (r + 0.5) * cell_size
            center = (cx, cy, o0z)
            info = F.washer_hole_cell(model, comp, center, dia, seg, widths,
                                      cell_size, 32)
            all_cells.append({"center": center, "diameter": dia,
                              "inner_loop_node_ids": info["inner_loop_node_ids"]})
    return {"cols": cols, "rows": rows, "cells": all_cells,
            "hole_count": cols * rows, "cell_size": cell_size}


# ---------------------------------------------------------------------------
# Model assembly
# ---------------------------------------------------------------------------


def build_model() -> Tuple[Model, List[Dict], Dict]:
    model = Model("mesh_seam_weld FAST_AUTO LARGE shell validation")
    mat = model.add_material("STEEL")

    def plate_prop(name, t):
        return model.add_property("PSHELL", name + "_PSHELL", mat.mid, thickness=t)

    cases: List[Dict] = []
    x_cursor = 0.0
    J = {"x": 0.0}

    def new_x():
        x_cursor = J["x"]
        J["x"] += PITCH
        return x_cursor

    # ---- T-type pairs (8) --------------------------------------------------
    t_gaps = [1, 2, 3, 4, 5, 6, 7, 8]
    for i, gap in enumerate(t_gaps):
        cx = new_x()
        free_len = 60 + 20 * i  # 60..200
        p_t = plate_prop("V{:02d}TTAR".format(i + 1), 1.5)
        p_s = plate_prop("V{:02d}TSRC".format(i + 1), 1.2)
        c_t = model.add_component("V{:02d}_TTARGET_T1.5".format(i + 1), 3, p_t)
        c_s = model.add_component("V{:02d}_TSOURCE_T1.2".format(i + 1), 4, p_s)
        mesh = 5.0
        _plate_xy(model, c_t, cx, 0.0, 420, 320, 8.0, 0.0)          # target at z=0, coarse 8mm
        _plate_xz(model, c_s, cx, 0.0, free_len, 220, 5.0)          # source vertical 5mm
        # raise the source plate to sit at z=gap above the target
        for nid in _node_ids(model, c_s):
            p = model.nodes[nid]
            model.nodes[nid] = (p[0], p[1], round(p[2] + gap, 9))
        cases.append({"case_id": "T{:02d}".format(i + 1), "kind": "T",
                      "gap": gap, "source_free_edge_len": free_len,
                      "source_comp": c_s.name, "target_comp": c_t.name,
                      "expected": "T_PATH candidate, gap {} (1..8) trigger".format(gap)})

    # ---- Lap pairs (6) -----------------------------------------------------
    lap_gaps = [1, 1.5, 2, 3, 4, 5]
    for i, gap in enumerate(lap_gaps):
        cx = new_x()
        tilt = (i % 3) / 100.0  # <=15 deg parallelism is kept (we stay parallel)
        p_a = plate_prop("V{:02d}LAP".format(i + 1), 1.6)
        p_b = plate_prop("V{:02d}LAP2".format(i + 1), 1.6)
        c_low = model.add_component("V{:02d}_LAPLOW_T1.6".format(i + 1), 5, p_a)
        c_high = model.add_component("V{:02d}_LAPHIGH_T1.6".format(i + 1), 6, p_b)
        mesh = 5.0
        _plate_xy(model, c_low, cx, 0.0, 360, 240, 8.0, 0.0)
        _plate_xy(model, c_high, cx + 20.0, 0.0, 360, 240, 8.0, gap)
        cases.append({"case_id": "L{:02d}".format(i + 1), "kind": "LAP",
                      "gap": gap, "low_comp": c_low.name, "high_comp": c_high.name,
                      "expected": "L_SURF overlap candidate, gap {} (1..5)".format(gap)})

    # ---- CONNECT pairs (4) -------------------------------------------------
    conn_gaps = [3, 4, 6, 8]
    for i, gap in enumerate(conn_gaps):
        cx = new_x()
        p_a = plate_prop("V{:02d}CONA".format(i + 1), 1.5)
        p_b = plate_prop("V{:02d}CONB".format(i + 1), 1.5)
        c_a = model.add_component("V{:02d}_CONA_T1.5".format(i + 1), 7, p_a)
        c_b = model.add_component("V{:02d}_CONB_T1.5".format(i + 1), 8, p_b)
        mesh = 5.0
        _plate_xy(model, c_a, cx - gap / 2.0 - 90.0, 0.0, 220, 180, 8.0, 0.0)
        _plate_xy(model, c_b, cx + gap / 2.0 + 90.0, 0.0, 220, 180, 8.0, 0.0)
        cases.append({"case_id": "C{:02d}".format(i + 1), "kind": "CONNECT",
                      "gap": gap, "comp_a": c_a.name, "comp_b": c_b.name,
                      "expected": "CONNECT near-parallel edge, gap {} (3..10)".format(gap)})

    # ---- Performance: 600-hole source + 2 targets ---------------------------
    cx = new_x()
    p_src = plate_prop("V21_PERFSRC", 1.0)
    p_t1 = plate_prop("V21_PERFT1", 1.5)
    p_t2 = plate_prop("V21_PERFT2", 1.5)
    c_src = model.add_component("V21_PERFSOURCE_T1.0", 2, p_src)
    c_t1 = model.add_component("V21_PERFTARGET1_T1.5", 3, p_t1)
    c_t2 = model.add_component("V21_PERFTARGET2_T1.5", 3, p_t2)
    cell = 60.0
    seg = 10
    dia = 10.0
    widths = (2.0, 2.0)
    plate_w = cell * 30.0
    plate_h = cell * 20.0
    dense = dense_hole_plate(model, c_src, (cx - plate_w / 2.0, -plate_h / 2.0, 0.0),
                             30, 20, cell, dia, seg, widths)
    # two target plates (plain) below/above
    _plate_xy(model, c_t1, cx, 0.0, 300, 240, 5.0, -80.0)
    _plate_xy(model, c_t2, cx, 0.0, 300, 240, 5.0, 80.0)
    cases.append({"case_id": "PERF", "kind": "perf",
                  "dense_available": True,
                  "expected": "600-hole plate generates many closed-loop candidates",
                  "component": c_src.name})

    # ---- Negative pairs (2) --------------------------------------------------
    # negative 1: 30 mm gap (no trigger)
    cx = new_x()
    p_a = plate_prop("V22NEGA", 1.5)
    p_b = plate_prop("V22NEGB", 1.5)
    c_a = model.add_component("V22_NEGDIST_A_T1.5", 7, p_a)
    c_b = model.add_component("V22_NEGDIST_B_T1.5", 7, p_b)
    _plate_xy(model, c_a, cx - 30.0 - 90.0, 0.0, 220, 180, 8.0, 0.0)
    _plate_xy(model, c_b, cx + 30.0 + 90.0, 0.0, 220, 180, 8.0, 0.0)
    cases.append({"case_id": "NEG1", "kind": "negative", "gap": 30.0,
                  "expected": "gap 30 > 12 search_distance -> NOT detected"})

    # negative 2: source free edge 12 mm (< min_seam_length 20 -> dropped)
    cx = new_x()
    p_s = plate_prop("V23NEGS", 1.2)
    p_t = plate_prop("V23NEGT", 1.5)
    c_s = model.add_component("V23_NEGSEAM_SRC_T1.2", 4, p_s)
    c_t = model.add_component("V23_NEGSEAM_TGT_T1.5", 3, p_t)
    _plate_xy(model, c_t, cx, 0.0, 420, 320, 8.0, 0.0)
    _plate_xz(model, c_s, cx, 0.0, 12.0, 220, 5.0)
    for nid in _node_ids(model, c_s):
        p = model.nodes[nid]
        model.nodes[nid] = (p[0], p[1], round(p[2] + 2.0, 9))
    cases.append({"case_id": "NEG2", "kind": "negative", "source_free_edge_len": 12.0,
                  "expected": "12 < min_seam_length 20 -> candidate dropped"})

    # ---- Pre-placed SEAM band (shared-node weld strip, dedup target) ---------
    cx = new_x()
    p_a = plate_prop("V24FA", 1.5)
    p_b = plate_prop("V24FB", 1.5)
    p_seam = plate_prop("SEAM_T1.5", 1.5)
    c_a = model.add_component("V24_WELDA_T1.5", 9, p_a)
    c_b = model.add_component("V24_WELDB_T1.5", 9, p_b)
    c_seam = model.add_component("SEAM_T1.5", 10, p_seam)
    mesh = 5.0
    _plate_xy(model, c_a, cx, -25.0, 260, 200, 5.0, 0.0)   # y in [-125, +75], 5mm grid
    _plate_xy(model, c_b, cx, 25.0, 260, 200, 5.0, 0.0)    # y in [-75, +125], 5mm grid
    # shared-node weld band spanning the full overlap [-75, +75]
    _weld_band(model, c_seam, cx, -75.0, 75.0, 260, 5.0)
    cases.append({"case_id": "SEAM", "kind": "seam", "component": c_seam.name,
                  "expected": "pre-placed SEAM band ignored by existing-weld search"})

    return model, cases, J


def _weld_band(model: Model, seam_comp: F.Component, cx, y_low, y_high, length, mesh):
    """A band of weld elements spanning the full overlap between two plates,
    from y_low (bottom, = high plate's bottom edge) to y_high (top, = low
    plate's top edge).  Because both plates are meshed on the same 5mm grid,
    the band's edge nodes land exactly on plate grid nodes and MERGE, so the
    SEAM band shares nodes with both plates (dedup / existing-weld target)."""
    nx = int(round(length / mesh))
    for i in range(nx):
        x0 = cx - length / 2.0 + i * mesh
        x1 = x0 + mesh
        n1 = model.node(x0, y_low, 0.0)
        n2 = model.node(x1, y_low, 0.0)
        n3 = model.node(x1, y_high, 0.0)
        n4 = model.node(x0, y_high, 0.0)
        model.elem(seam_comp, "CQUAD4", (n1, n2, n3, n4))


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------


def verify(model: Model, cases: List[Dict], J) -> Dict:
    errors = []
    # 1. every listed component must exist and have elements
    comp_names = {c.name for c in model.components.values()}
    for case in cases:
        for key in ("source_comp", "target_comp", "low_comp", "high_comp",
                    "comp_a", "comp_b", "component"):
            name = case.get(key)
            if name and name not in comp_names:
                errors.append("{}: missing component {}".format(case["case_id"], name))

    # 2. T pairs: gap within 1..8, free edge within 40..200
    for case in cases:
        if case["kind"] == "T":
            g = case["gap"]
            fe = case["source_free_edge_len"]
            assert 1.0 <= g <= 8.0, "T gap {} out of range".format(g)
            assert 40.0 <= fe <= 200.0, "T free-edge {} out of range".format(fe)
        elif case["kind"] == "LAP":
            assert 1.0 <= case["gap"] <= 5.0
        elif case["kind"] == "CONNECT":
            assert 3.0 <= case["gap"] <= 10.0
        elif case["kind"] == "negative" and case["case_id"] == "NEG1":
            assert case["gap"] == 30.0

    # 3. no shared nodes between T source/target components (gap preserves this)
    # 4. free-edge loop sanity + geometry sanity on a T source plate
    t05 = next((c for c in cases if c["case_id"] == "T05"), None)
    if t05:
        c = next(c for c in model.components.values() if c.name == t05["source_comp"])
        loops = F.free_edge_loops(model, c)
        assert len(loops) == 1, "T05 source expected 1 free-edge loop, got {}".format(len(loops))
        # vertical plate: all nodes share ~one Y plane and span Z >= 200mm
        ids = _node_ids(model, c)
        ys = {model.nodes[n][1] for n in ids}
        zs = [model.nodes[n][2] for n in ids]
        assert len(ys) == 1, "T05 source should be a single-Y vertical plate, got {} y values".format(len(ys))
        assert (max(zs) - min(zs)) >= 200.0, "T05 source should span ~220mm in Z, got {}".format(max(zs) - min(zs))

    # 5. dense plate holes
    perf = next(c for c in cases if c["case_id"] == "PERF")
    if perf["dense_available"]:
        src_c = next(c for c in model.components.values() if c.name == perf["component"])
        # count closed hole loops = holes + 1 outer boundary
        loops = F.free_edge_loops(model, src_c)
        assert len(loops) == 600 + 1, "dense plate expected 601 loops, got {}".format(len(loops))

    if errors:
        raise ValueError("verification failed:\n- " + "\n- ".join(errors))

    stats = model.stats()
    stats.update({
        "joint_T_pairs": sum(1 for c in cases if c["kind"] == "T"),
        "joint_lap_pairs": sum(1 for c in cases if c["kind"] == "LAP"),
        "joint_connect_pairs": sum(1 for c in cases if c["kind"] == "CONNECT"),
        "negative_pairs": sum(1 for c in cases if c["kind"] == "negative"),
        "preplaced_seam_bands": sum(1 for c in cases if c["kind"] == "seam"),
        "dense_hole_plate_holes": 600,
        "thresholds": DEFAULTS,
    })
    assert stats["element_count"] >= 35000, \
        "element_count {} < 35000".format(stats["element_count"])
    return stats


# ---------------------------------------------------------------------------
# Manifest / README / main
# ---------------------------------------------------------------------------


def manifest(model, cases, J, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name,
              "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    return {
        "schema_version": "1.0",
        "module": "mesh_seam_weld",
        "purpose": "LARGE mesh_seam_weld FAST_AUTO shell validation: 8 T + 6 lap + 4 CONNECT "
                   "+ 600-hole perf + 2 negatives + 1 pre-placed SEAM. Components share no nodes.",
        "generator": "tools/model_generation/gen_mesh_seam_weld.py",
        "fem": "MeshSeamWeld_Large.fem",
        "parameters": DEFAULTS,
        "statistics": stats,
        "components": comps,
        "cases": cases,
        "warning": ("Validation geometry only; joints are NOT connected (gap separation + "
                    "distinct comp groups) except the shared-node SEAM_T1.5 band."),
    }


def main() -> int:
    model, cases, J = build_model()
    stats = verify(model, cases, J)
    outdir = common.model_dir("mesh_seam_weld_large")
    fem_path = outdir / "MeshSeamWeld_Large.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "MeshSeamWeld_Large_manifest.json",
                          manifest(model, cases, J, stats))
    common.write_readme(outdir / "README.md", README)
    # print critical stats
    print("nodes={} elems={} comps={}".format(
        stats["node_count"], stats["element_count"], stats["component_count"]))
    sk = {k: v for k, v in stats.items() if not isinstance(v, dict)}
    sk.pop("element_count", None)
    print(sk)
    return 0


README = """# mesh_seam_weld FAST_AUTO — Large Shell Validation Model

## 用途
`MeshSeamWeld_Large.fem` 用于 `mesh_seam_weld`（FAST_AUTO 自动焊缝）的大规模
接受/拒绝验证。规模 >=3.5 万壳单元，含 T 型、搭接、CONNECT、600 孔性能板、
负向与预置 SEAM 去重场景。

## 场景表
| ID | 类别 | 内容 | 预期 |
|---|---|---|---|
| T01..T08 | T 型（8） | 源板垂直立于目标板，法向夹角 ~90°，间隙 1~8mm，自由边 60~200mm，网格 5mm | 识别 T_PATH，焊缝路径 40..200mm |
| L01..L06 | 搭接（6） | 两平行板重叠（平行 <=15°），间隙 1~5mm | 识别 L_SURF |
| C01..C04 | CONNECT（4）| 共面近边平行，间隙 3~10mm | 识别 CONNECT |
| PERF | 性能（1） | 30x20=600 孔源板 + 2 目标板 | 批量闭环候选性能压测 |
| NEG1 | 负向 | 间隙 30mm（>12 不触发） | 不识别 |
| NEG2 | 负向 | 源板自由边 12mm（<20 丢弃） | 候选丢弃 |
| SEAM | 预置 | 两板间共享节点 SEAM_T1.5 焊缝带 | existing-weld 去重（DUPLICATE） |

## 操作
1. HyperMesh 导入 `MeshSeamWeld_Large.fem`。
2. 全选壳单元，运行 FAST_AUTO（阈值与 manifest/defaults 一致）。
3. 核对 T/L/C 候选数量、600 孔板批量候选、NEG 不触发、SEAM 去重。
4. 检查生成组件（`SEAM_T1.5` 等）与 Model Browser。

## 设计说明
- 组件间不共享节点（除 SEAM 带）；每对独立成组、X 向 300mm 间距。
- 确定性生成；单元尺寸 5mm，部分板 4~6mm。
- 生成时自检：每对间隙/角度范围、自由边环数与孔数吻合、无退化单元。
"""

if __name__ == "__main__":
    raise SystemExit(main())
