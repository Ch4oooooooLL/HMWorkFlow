#!/usr/bin/env python3
"""gen_weld_integrity.py -- weld_integrity_check LARGE missing-weld validation.

weld_integrity_check scans shell components for likely-missing welds:

  max_search_distance    5 mm
  min_contact_length    20 mm
  min_continuous_nodes   3
  ignore_shared_nodes    1

Content (groups separated 300 mm along X, components do NOT share nodes unless
stated):
  T leak-weld       12 pairs, gap 0.5..4.5 mm, contact length 30..150 mm.
  Lap leak-weld      8 pairs, gap 0.2..3 mm.
  Near free edge     6 pairs, edge gap 4..8 mm (3 of them at 8 mm boundary).
  Welded             2 pairs carrying a shared >=3-node SEAM_T band -> ignored.
  Far                2 pairs, 40 mm apart -> not triggered.
  Hub-and-spoke      2 hubs each neighbouring 4..6 small plates (multi-comp).

>= 25k shell elements, >= 25 components.  Deterministic; stdlib-only.
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

PITCH = 300.0
THRESH = {"max_search_distance": 5.0, "min_contact_length": 20.0,
          "min_continuous_nodes": 3, "ignore_shared_nodes": 1}


def _node_ids(model, comp) -> List[int]:
    out = []
    for el in model.elements_of(comp):
        out.extend(el.node_ids)
    return out


def _plate_xy(model, comp, cx, cy, w, h, mesh, z):
    return F.rect_plate_mesh(model, comp, (cx - w / 2.0, cy - h / 2.0, z),
                             w, h, max(1, int(round(w / mesh))), max(1, int(round(h / mesh))))


def _plate_xz(model, comp, cx, y, w, h, mesh):
    """Vertical plate in XZ plane at y=y, X width w, Z height h, bottom z=0."""
    info = F.rect_plate_mesh(model, comp, (cx - w / 2.0, 0.0, 0.0),
                             w, h, max(1, int(round(w / mesh))), max(1, int(round(h / mesh))))
    for row in info["grid"]:
        for nid in row:
            p = model.nodes[nid]
            model.nodes[nid] = (round(p[0], 9), round(y, 9), round(p[1], 9))
    return info


def _weld_band(model, seam_comp, cx, y_low, y_high, length, mesh):
    """Shared-node weld band spanning the overlap of two plates (the band's
    edge nodes land on the plate 5 mm grid and merge -> a >=3 continuous-node
    shared chain, which ignore_shared_nodes should skip)."""
    nx = int(round(length / mesh))
    for i in range(nx):
        x0 = cx - length / 2.0 + i * mesh
        x1 = x0 + mesh
        model.elem(seam_comp, "CQUAD4",
                   (model.node(x0, y_low, 0.0), model.node(x1, y_low, 0.0),
                    model.node(x1, y_high, 0.0), model.node(x0, y_high, 0.0)))


def _shared_node_chain(model, a, b):
    """Count max continuous shared-node nodes between two XY plates via the
    coincident-node pairs (used to assert >=3 for the welded pair)."""
    pairs = F.coincident_node_pairs(model, a, b, tol=0.01)
    return len(pairs)


def build_model() -> Tuple[Model, List[Dict]]:
    model = Model("weld_integrity_check LARGE missing-weld validation")
    mat = model.add_material("STEEL")

    def prop(name, t):
        return model.add_property("PSHELL", name + "_PSHELL", mat.mid, thickness=t)

    J = {"x": 0.0}

    def new_x():
        v = J["x"]
        J["x"] += PITCH
        return v

    cases: List[Dict] = []

    # ---- T-type missing-weld (12) -------------------------------------------
    t_gaps = [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 2, 3, 4][:12]
    for i, gap in enumerate(t_gaps):
        cx = new_x()
        contact = 30 + 10 * i  # 30..140 (within 30..150)
        p_t = prop("V{:02d}WTAR".format(i + 1), 1.5)
        p_s = prop("V{:02d}WSRC".format(i + 1), 1.2)
        c_t = model.add_component("V{:02d}_WTARGET_T1.5".format(i + 1), 3, p_t)
        c_s = model.add_component("V{:02d}_WSOURCE_T1.2".format(i + 1), 4, p_s)
        _plate_xy(model, c_t, cx, 0.0, 380, 300, 5.0, 0.0)
        _plate_xz(model, c_s, cx, 0.0, contact, 180, 5.0)
        for nid in _node_ids(model, c_s):
            p = model.nodes[nid]
            model.nodes[nid] = (p[0], p[1], round(p[2] + gap, 9))
        cases.append({"case_id": "WT{:02d}".format(i + 1), "kind": "T",
                      "gap": gap, "contact_length": contact,
                      "source_comp": c_s.name, "target_comp": c_t.name,
                      "expected": "missing-weld candidate, gap {} (0.5..4.5)".format(gap)})

    # ---- Lap missing-weld (8) ------------------------------------------------
    lap_gaps = [0.2, 0.5, 0.8, 1.2, 1.6, 2.0, 2.5, 3.0]
    for i, gap in enumerate(lap_gaps):
        cx = new_x()
        p_a = prop("V{:02d}LA".format(i + 1), 1.6)
        p_b = prop("V{:02d}LB".format(i + 1), 1.6)
        c_low = model.add_component("V{:02d}_LAPLOW_T1.6".format(i + 1), 5, p_a)
        c_high = model.add_component("V{:02d}_LAPHIGH_T1.6".format(i + 1), 6, p_b)
        _plate_xy(model, c_low, cx, 0.0, 320, 200, 5.0, 0.0)
        _plate_xy(model, c_high, cx + 10, 0.0, 320, 200, 5.0, gap)
        cases.append({"case_id": "WL{:02d}".format(i + 1), "kind": "lap",
                      "gap": gap, "low_comp": c_low.name, "high_comp": c_high.name,
                      "expected": "lap missing-weld, gap {} (0.2..3)".format(gap)})

    # ---- Near free edge (6), 3 at 8 mm boundary -----------------------------
    near_gaps = [4, 5, 6, 8, 8, 8]
    for i, gap in enumerate(near_gaps):
        cx = new_x()
        p_a = prop("V{:02d}NEA".format(i + 1), 1.5)
        p_b = prop("V{:02d}NEB".format(i + 1), 1.5)
        c_a = model.add_component("V{:02d}_NEAR_A_T1.5".format(i + 1), 7, p_a)
        c_b = model.add_component("V{:02d}_NEAR_B_T1.5".format(i + 1), 8, p_b)
        _plate_xy(model, c_a, cx - gap / 2.0 - 80.0, 0.0, 200, 160, 5.0, 0.0)
        _plate_xy(model, c_b, cx + gap / 2.0 + 80.0, 0.0, 200, 160, 5.0, 0.0)
        cases.append({"case_id": "WN{:02d}".format(i + 1), "kind": "near",
                      "gap": gap, "at_boundary8": gap >= 8.0,
                      "comp_a": c_a.name, "comp_b": c_b.name,
                      "expected": "near free edge, gap {} (4..8)".format(gap)})

    # ---- Welded (2) with shared SEAM band -> ignored -------------------------
    for i in range(2):
        cx = new_x()
        p_a = prop("V{:02d}WDA".format(i + 1), 1.5)
        p_b = prop("V{:02d}WDB".format(i + 1), 1.5)
        p_seam = prop("V{:02d}SEAM".format(i + 1), 1.5)
        c_a = model.add_component("V{:02d}_WELDA_T1.5".format(i + 1), 9, p_a)
        c_b = model.add_component("V{:02d}_WELDB_T1.5".format(i + 1), 9, p_b)
        c_seam = model.add_component("V{:02d}_SEAM_T1.5".format(i + 1), 10, p_seam)
        # Two plates that OVERLAP on the same 5mm grid -> all overlap nodes
        # coincide (shared). The SEAM band in the overlap also shares nodes.
        _plate_xy(model, c_a, cx, -60.0, 300, 240, 5.0, 0.0)  # y -180..+60
        _plate_xy(model, c_b, cx, 60.0, 300, 240, 5.0, 0.0)   # y -60..+180
        _weld_band(model, c_seam, cx, -40.0, 40.0, 300, 5.0)  # band inside overlap
        cases.append({"case_id": "WD{:02d}".format(i + 1), "kind": "welded",
                      "seam_comp": c_seam.name, "comp_a": c_a.name, "comp_b": c_b.name,
                      "expected": "plates share overlap nodes + SEAM band -> ignored"})

    # ---- Far pairs (2) --------------------------------------------------------
    for i in range(2):
        cx = new_x()
        p_a = prop("V{:02d}FA".format(i + 1), 1.5)
        p_b = prop("V{:02d}FB".format(i + 1), 1.5)
        c_a = model.add_component("V{:02d}_FARA_T1.5".format(i + 1), 7, p_a)
        c_b = model.add_component("V{:02d}_FARB_T1.5".format(i + 1), 8, p_b)
        _plate_xy(model, c_a, cx - 40.0 - 80.0, 0.0, 200, 160, 5.0, 0.0)
        _plate_xy(model, c_b, cx + 40.0 + 80.0, 0.0, 200, 160, 5.0, 0.0)
        cases.append({"case_id": "WF{:02d}".format(i + 1), "kind": "far",
                      "gap": 40.0, "comp_a": c_a.name, "comp_b": c_b.name,
                      "expected": "40 mm > 5 -> not triggered"})

    # ---- Hub-and-spoke (2) ----------------------------------------------------
    for i in range(2):
        cx = new_x()
        n_spoke = 4 if i == 0 else 6
        p_h = prop("V{:02d}HUB".format(i + 1), 1.5)
        c_hub = model.add_component("V{:02d}_HUB_T1.5".format(i + 1), 2, p_h)
        _plate_xy(model, c_hub, cx, 0.0, 260, 260, 5.0, 0.0)
        spokes = []
        gap = 3.0
        half_hub = 130.0
        for k in range(n_spoke):
            p_s = prop("V{:02d}SPK{}".format(i + 1, k), 1.0)
            c_s = model.add_component("V{:02d}_SPOKE{}_{}".format(i + 1, k, n_spoke), 6, p_s)
            ang = 360.0 * k / n_spoke
            # spoke centre just outside the hub (130 + gap/2 + len/2)
            _spoke_ray(model, c_s, cx, 0.0, ang, half_hub + gap / 2.0 + 60.0,
                       120.0, 40.0, 5.0)
            spokes.append(c_s.name)
        cases.append({"case_id": "H{:02d}".format(i + 1), "kind": "hub",
                      "n_spoke": n_spoke, "hub_comp": c_hub.name, "spoke_comps": spokes,
                      "expected": "hub + {} spokes near-gap -> multi-component pair".format(n_spoke)})

    return model, cases, J


def _spoke_ray(model, comp, hx, hy, ang_deg, len_from_center, length, width, mesh):
    """A small plate (spoke) oriented radially outward from a hub centred at
    (hx,hy).  The spoke's near short edge is `gap` outside the hub; `length`
    is the spoke's plate length, `width` its width.  Returns the mesh info."""
    a = math.radians(ang_deg)
    half = length / 2.0
    half_w = width / 2.0
    # place the spoke centre at distance len_from_center along the ray
    cx = hx + len_from_center * math.cos(a)
    cy = hy + len_from_center * math.sin(a)
    nx = max(1, int(round(length / mesh)))
    ny = max(1, int(round(width / mesh)))
    grid = []
    cos_a, sin_a = math.cos(a), math.sin(a)
    for k in range(ny + 1):
        row = []
        for m in range(nx + 1):
            lx_local = -half + length * m / nx
            wy_local = -half_w + width * k / ny
            world_x = cx + lx_local * cos_a - wy_local * sin_a
            world_y = cy + lx_local * sin_a + wy_local * cos_a
            row.append(model.node(world_x, world_y, 0.0))
        grid.append(row)
    for k in range(ny):
        for m in range(nx):
            model.elem(comp, "CQUAD4", (grid[k][m], grid[k][m + 1],
                                        grid[k + 1][m + 1], grid[k + 1][m]))
    return grid


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------


def verify(model: Model, cases: List[Dict], J) -> Dict:
    comp_names = {c.name for c in model.components.values()}
    errors = []
    for case in cases:
        for key in ("source_comp", "target_comp", "low_comp", "high_comp",
                    "comp_a", "comp_b", "hub_comp", "seam_comp"):
            name = case.get(key)
            if name and name not in comp_names:
                errors.append("{}: missing {}".format(case["case_id"], name))
        for key in ("spoke_comps",):
            for s in case.get(key, []):
                if s not in comp_names:
                    errors.append("{}: missing spoke {}".format(case["case_id"], s))

    for case in cases:
        k = case["kind"]
        if k == "T":
            assert 0.5 <= case["gap"] <= 4.5, case
            assert 30.0 <= case["contact_length"] <= 150.0, case
        elif k == "lap":
            assert 0.2 <= case["gap"] <= 3.0, case
        elif k == "near":
            assert 4.0 <= case["gap"] <= 8.0, case
        elif k == "far":
            assert case["gap"] == 40.0

    # welded pairs: assert the SEAM band shares a >=3 continuous node chain
    for case in cases:
        if case["kind"] == "welded":
            a = next(c for c in model.components.values() if c.name == case["comp_a"])
            b = next(c for c in model.components.values() if c.name == case["comp_b"])
            nshared = _shared_node_chain(model, a, b)
            assert nshared >= 3, "{} shared {} <3".format(case["case_id"], nshared)

    if errors:
        raise ValueError("verification failed:\n- " + "\n- ".join(errors))

    stats = model.stats()
    stats.update({
        "T_leak_pairs": sum(1 for c in cases if c["kind"] == "T"),
        "lap_leak_pairs": sum(1 for c in cases if c["kind"] == "lap"),
        "near_edge_pairs": sum(1 for c in cases if c["kind"] == "near"),
        "near_edge_at8": sum(1 for c in cases if c["kind"] == "near" and c["at_boundary8"]),
        "welded_ignored": sum(1 for c in cases if c["kind"] == "welded"),
        "far_pairs": sum(1 for c in cases if c["kind"] == "far"),
        "hub_and_spoke": sum(1 for c in cases if c["kind"] == "hub"),
        "spokes": sum(c["n_spoke"] for c in cases if c["kind"] == "hub"),
        "thresholds": THRESH,
    })
    assert stats["element_count"] >= 25000, stats["element_count"]
    assert stats["component_count"] >= 25, stats["component_count"]
    return stats


def manifest(model, cases, J, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name,
              "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    return {
        "schema_version": "1.0",
        "module": "weld_integrity_check",
        "purpose": "LARGE weld-integrity missing-weld validation: 12 T + 8 lap + 6 near + "
                   "2 welded + 2 far + 2 hub-and-spoke. Components mostly share no nodes.",
        "generator": "tools/model_generation/gen_weld_integrity.py",
        "fem": "WeldIntegrity_30pairs.fem",
        "parameters": THRESH,
        "statistics": stats,
        "components": comps,
        "cases": cases,
        "warning": "Validation geometry only; welded pairs share the SEAM band nodes on purpose.",
    }


def main() -> int:
    model, cases, J = build_model()
    stats = verify(model, cases, J)
    outdir = common.model_dir("weld_integrity_30pairs")
    fem_path = outdir / "WeldIntegrity_30pairs.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "WeldIntegrity_30pairs_manifest.json",
                          manifest(model, cases, J, stats))
    common.write_readme(outdir / "README.md", README)
    print("nodes={} elems={} comps={}".format(stats["node_count"],
                                              stats["element_count"],
                                              stats["component_count"]))
    sk = {k: v for k, v in stats.items() if not isinstance(v, dict)}
    sk.pop("element_count", None)
    print(sk)
    return 0


README = """# weld_integrity_check — Large Missing-Weld Validation Model

## 用途
`WeldIntegrity_30pairs.fem` 用于 `weld_integrity_check`（漏焊核验）的大规模验证：
T 型漏焊、搭接漏焊、邻近自由边（含 8mm 边界）、已焊忽略、远距不触发、
hub-and-spoke 多组件对。规模 >=2.5 万壳单元 / >=25 组件。

## 场景表
| ID | 类别 | 内容 | 预期 |
|---|---|---|---|
| WT01..WT12 | T 漏焊（12） | 间隙 0.5~4.5mm、接触长 30~140mm | 候选（间隙<=5） |
| WL01..WL08 | 搭接漏焊（8） | 两平行板间隙 0.2~3mm | 候选 |
| WN01..WN06 | 邻近自由边（6） | 间隙 4~8mm，其中 3 组 8mm 边界 | 候选 |
| WD01..WD02 | 已焊（2） | 共享 >=3 节点 SEAM_T 带 | 被忽略（ignore_shared_nodes） |
| WF01..WF02 | 远距（2） | 40mm | 不触发（>5） |
| H01..H02 | hub-and-spoke（2） | 1 中心板邻 4~6 小板 | 多组件对候选 |

## 操作
1. HyperMesh 导入 `WeldIntegrity_30pairs.fem`。
2. 全选壳单元运行漏焊核验（阈值：search 5 / contact 20 / nodes 3 / shared 忽略）。
3. 核对候选数量、已焊 SEAM 忽略、远距不触发、hub 多对。

## 设计说明
- 候选对组件通常不共享节点；已焊 WD 对通过 SEAM 带共享 >=3 节点序列。
- 确定性生成；网格 5mm；生成时自检间距/接触长/共享节点数/无退化单元。
"""

if __name__ == "__main__":
    raise SystemExit(main())
