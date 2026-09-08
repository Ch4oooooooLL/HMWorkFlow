#!/usr/bin/env python3
"""gen_shell_washer.py -- LARGE shell washer-hole -> RIGIDS validation model.

Four large plates (Vxx naming) with a dense washer-hole matrix covering the
shell_washer_hole_rbe2 acceptance matrix at scale:

  P1  V01_WASHER_ARRAY_T1.5  12x10 = 120 holes  (D8/D12/D18/D26 cycle)
  P2  V02_OVAL_RBE3_T1.5     8x6  = 48 holes   (oval 2:1 rows + circular)
  P3  V03_SPECIAL_T1.5       8x5  = 40 cells   (D4 reject / D40 reject /
                              edge-flush / rectangular / pre-placed RBE2)
  P4  V04_PERF_T1.5          16x12 = 192 holes (D12, batch-performance)

Washer ring densities follow config/washer_rules.txt:
  6<D<=9 -> 8 nodes, widths 4,6 ; 9<D<=13 -> 10, 4,6 ;
  13<D<=20 -> 12, 6,8 ; 20<D<=30 -> 16, 8,8.
Units mm / N / tonne.  Deterministic, stdlib-only.
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

CELL = 120.0
OUTER_SEG = 32
PLATE_T = 1.5

WASHER_BANDS = {
    "D8":  {"diameter": 8.0,  "segments": 8,  "widths": (4.0, 6.0)},
    "D12": {"diameter": 12.0, "segments": 10, "widths": (4.0, 6.0)},
    "D18": {"diameter": 18.0, "segments": 12, "widths": (6.0, 8.0)},
    "D26": {"diameter": 26.0, "segments": 16, "widths": (8.0, 8.0)},
}


def cell_center(origin: Tuple[float, float, float], col: int, row: int) -> Tuple[float, float, float]:
    return (origin[0] + (col + 0.5) * CELL, origin[1] + (row + 0.5) * CELL, origin[2])


def build_plate_array(model: Model, comp: F.Component, origin, cols, rows, cycle) -> List[Dict]:
    holes = []
    for row in range(rows):
        for col in range(cols):
            spec = WASHER_BANDS[cycle[(row * cols + col) % len(cycle)]]
            center = cell_center(origin, col, row)
            info = F.washer_hole_cell(model, comp, center, spec["diameter"], spec["segments"],
                                      spec["widths"], CELL, OUTER_SEG)
            info.update({"center": center, "shape": "circular",
                         "diameter": spec["diameter"], "segments": spec["segments"],
                         "widths": list(spec["widths"])})
            holes.append(info)
    return holes


def _radius(model: Model, nid: int, center: Tuple[float, float, float]) -> float:
    p = model.nodes[nid]
    return math.hypot(p[0] - center[0], p[1] - center[1])


def build_oval_cells(model: Model, comp: F.Component, origin, cols, rows,
                     a: float, b: float, segments: int = 20, widths=(6.0, 8.0)) -> List[Dict]:
    """Oval (2:1) washer holes on a sub-grid."""
    holes = []
    for row in range(rows):
        for col in range(cols):
            center = cell_center(origin, col, row)
            r0 = 1.0
            inner = F.ring_nodes(model, comp, center, r0, segments, ellipse=(a, b))
            w1 = F.ring_nodes(model, comp, center, r0, segments, ellipse=(a + widths[0], b + widths[0]))
            w2 = F.ring_nodes(model, comp, center, r0, segments, ellipse=(a + widths[0] + widths[1],
                                                                          b + widths[0] + widths[1]))
            elems = F.connect_rings(model, comp, inner, w1)
            elems += F.connect_rings(model, comp, w1, w2)
            outer_r = max(_radius(model, n, center) for n in w2)
            s16 = F.ring_nodes(model, comp, center, outer_r + 8.0, 16)
            elems += F.transition_rings(model, comp, w2, s16)
            s32 = F.ring_nodes(model, comp, center, outer_r + 16.0, OUTER_SEG)
            elems += F.transition_rings(model, comp, s16, s32)
            half = CELL / 2.0
            r32 = outer_r + 16.0
            layers = max(2, int(math.ceil((half - r32) / 10.0)))
            prev = s32
            for layer in range(1, layers):
                fraction = layer / float(layers)
                ring = []
                for i in range(OUTER_SEG):
                    angle = 2.0 * math.pi * i / OUTER_SEG
                    c, s = math.cos(angle), math.sin(angle)
                    square_r = half / max(abs(c), abs(s))
                    r = r32 + fraction * (square_r - r32)
                    ring.append(model.node(center[0] + r * c, center[1] + r * s, center[2]))
                elems += F.connect_rings(model, comp, prev, ring)
                prev = ring
            boundary = F.square_ring_nodes(model, comp, center, half, OUTER_SEG)
            elems += F.connect_rings(model, comp, prev, boundary)
            holes.append({"center": center, "shape": "oval", "a": a, "b": b,
                          "segments": segments, "widths": list(widths),
                          "inner_loop_node_ids": inner,
                          "washer_loop_1_node_ids": w1, "washer_loop_2_node_ids": w2})
    return holes


def build_rect_cell(model: Model, comp: F.Component, center, wx: float, wy: float) -> Dict:
    """Rectangular hole (corners + edge midpoints) with scaled washer rings."""
    pts = [(wx / 2.0, wy / 2.0), (0.0, wy / 2.0), (-wx / 2.0, wy / 2.0), (-wx / 2.0, 0.0),
           (-wx / 2.0, -wy / 2.0), (0.0, -wy / 2.0), (wx / 2.0, -wy / 2.0), (wx / 2.0, 0.0)]

    def ring_scale(factor):
        return [model.node(center[0] + p[0] * factor, center[1] + p[1] * factor, center[2]) for p in pts]

    inner = ring_scale(1.0)
    w1 = ring_scale(1.3)
    w2 = ring_scale(1.6)
    elems = F.connect_rings(model, comp, inner, w1)
    elems += F.connect_rings(model, comp, w1, w2)
    outer_r = max(math.hypot(p[0] * 1.6, p[1] * 1.6) for p in pts)
    s16 = F.ring_nodes(model, comp, center, outer_r + 8.0, 16)
    elems += F.transition_rings(model, comp, w2, s16)
    s32 = F.ring_nodes(model, comp, center, outer_r + 16.0, OUTER_SEG)
    elems += F.transition_rings(model, comp, s16, s32)
    half = CELL / 2.0
    r32 = outer_r + 16.0
    layers = max(2, int(math.ceil((half - r32) / 10.0)))
    prev = s32
    for layer in range(1, layers):
        fraction = layer / float(layers)
        ring = []
        for i in range(OUTER_SEG):
            angle = 2.0 * math.pi * i / OUTER_SEG
            c, s = math.cos(angle), math.sin(angle)
            square_r = half / max(abs(c), abs(s))
            r = r32 + fraction * (square_r - r32)
            ring.append(model.node(center[0] + r * c, center[1] + r * s, center[2]))
        elems += F.connect_rings(model, comp, prev, ring)
        prev = ring
    boundary = F.square_ring_nodes(model, comp, center, half, OUTER_SEG)
    elems += F.connect_rings(model, comp, prev, boundary)
    return {"center": center, "shape": "rectangular", "wx": wx, "wy": wy,
            "inner_loop_node_ids": inner,
            "washer_loop_1_node_ids": w1, "washer_loop_2_node_ids": w2}


def build_edge_flush_cell(model: Model, comp: F.Component, cell_center,
                          hole_center, diameter: float, segments: int,
                          widths, plate_xmax: float) -> Dict:
    """Standalone cell plate whose hole sits close to the plate right edge:
    washer rings are truncated by the boundary (the module must reject the
    truncated washer).  The outer ring is the ray-intersection of the cell
    square with the plate edge, all clipped by in_bounds."""
    cx, cy, _ = cell_center
    hx, hy, _ = hole_center
    half = CELL / 2.0
    r0 = diameter / 2.0
    inner = F.ring_nodes(model, comp, hole_center, r0, segments)
    w1 = F.ring_nodes(model, comp, hole_center, r0 + widths[0], segments)
    w2 = F.ring_nodes(model, comp, hole_center, r0 + widths[0] + widths[1], segments)
    outer_r = r0 + widths[0] + widths[1]
    s16 = F.ring_nodes(model, comp, hole_center, outer_r + 8.0, 16)
    s32 = F.ring_nodes(model, comp, hole_center, outer_r + 16.0, OUTER_SEG)
    r32 = outer_r + 16.0
    layers = max(2, int(math.ceil((half - r32) / 10.0)))

    def in_bounds(nid):
        p = model.nodes[nid]
        return (p[0] <= plate_xmax + 1e-9 and p[1] >= cy - half - 1e-9
                and p[1] <= cy + half + 1e-9 and p[0] >= cx - half - 1e-9)

    def clipped_ring(a, b):
        if len(a) != len(b):
            raise ValueError("clipped ring requires equal node counts")
        for i in range(len(a)):
            j = (i + 1) % len(a)
            quad = (a[i], b[i], b[j], a[j])
            if not all(in_bounds(n) for n in quad):
                continue
            if len({model.nodes[n] for n in quad}) < 4:
                continue
            model.elem(comp, "CQUAD4", quad)

    def clipped_transition(a, b):
        istep = ostep = 0
        ic, oc = len(a), len(b)
        while istep < ic or ostep < oc:
            ni = (istep + 1.0) / ic if istep < ic else float("inf")
            no = (ostep + 1.0) / oc if ostep < oc else float("inf")
            i0 = a[istep % ic]
            o0 = b[ostep % oc]
            if abs(ni - no) <= 1e-12:
                i1 = a[(istep + 1) % ic]
                o1 = b[(ostep + 1) % oc]
                for tri in ((i0, o0, i1), (i1, o0, o1)):
                    if all(in_bounds(n) for n in tri) and len({model.nodes[n] for n in tri}) == 3:
                        model.elem(comp, "CTRIA3", tri)
                istep += 1
                ostep += 1
            elif ni < no:
                tri = (i0, o0, a[(istep + 1) % ic])
                if all(in_bounds(n) for n in tri):
                    model.elem(comp, "CTRIA3", tri)
                istep += 1
            else:
                tri = (i0, o0, b[(ostep + 1) % oc])
                if all(in_bounds(n) for n in tri):
                    model.elem(comp, "CTRIA3", tri)
                ostep += 1

    clipped_ring(inner, w1)
    clipped_ring(w1, w2)
    clipped_transition(w2, s16)
    clipped_transition(s16, s32)

    def ray_square(angle: float) -> float:
        c, s = math.cos(angle), math.sin(angle)
        t = float("inf")
        if abs(c) > 1e-12:
            tx = ((cx + half if c > 0 else cx - half) - hx) / c
            t = min(t, tx)
        if abs(s) > 1e-12:
            ty = ((cy + half if s > 0 else cy - half) - hy) / s
            t = min(t, ty)
        if c > 1e-12:
            t = min(t, (plate_xmax - hx) / c)
        return t

    target_r = [max(ray_square(2.0 * math.pi * i / OUTER_SEG), r32) for i in range(OUTER_SEG)]
    prev = s32
    for layer in range(1, layers):
        fraction = layer / float(layers)
        ring = []
        for i in range(OUTER_SEG):
            angle = 2.0 * math.pi * i / OUTER_SEG
            rr = r32 + fraction * (target_r[i] - r32)
            ring.append(model.node(hx + rr * math.cos(angle), hy + rr * math.sin(angle), hole_center[2]))
        clipped_transition(prev, ring)
        prev = ring
    boundary = []
    for i, rr in enumerate(target_r):
        angle = 2.0 * math.pi * i / OUTER_SEG
        boundary.append(model.node(hx + rr * math.cos(angle), hy + rr * math.sin(angle), hole_center[2]))
    clipped_transition(prev, boundary)
    return {"center": list(hole_center), "diameter": diameter, "shape": "circular_edge",
            "segments": segments, "widths": list(widths),
            "inner_loop_node_ids": inner,
            "washer_loop_1_node_ids": w1, "washer_loop_2_node_ids": w2}


def place_rbe2(model: Model, out_comp: F.Component, hole: Dict) -> Dict:
    """Pre-place an RBE2 on a hole (independent = hole centre node,
    dependents = hole ring + washer ring 1)."""
    center = hole["center"]
    cnode = model.node(center[0], center[1], center[2])
    deps = sorted(set(hole["inner_loop_node_ids"]) | set(hole["washer_loop_1_node_ids"]))
    eid = model.elem(out_comp, "RBE2", (cnode, "123456", *deps))
    return {"element_id": eid, "independent_node_id": cnode, "dependent_node_ids": deps}


def build_model() -> Tuple[Model, List[Dict]]:
    model = Model("Shell washer-hole -> RIGIDS LARGE validation model")
    mat = model.add_material("STEEL")
    cases = []
    existing_rbe2 = []

    # ---- P1: 12x10 mixed-diameter array ----------------------------------
    p1 = model.add_component("V01_WASHER_ARRAY_T1.5", 3,
                             model.add_property("PSHELL", "V01_WASHER_ARRAY_T1.5_PSHELL", mat.mid, thickness=PLATE_T))
    h1 = build_plate_array(model, p1, (0.0, 0.0, 0.0), 12, 10, ("D8", "D12", "D18", "D26"))
    cases.append({"case_id": "P1", "component": p1.name, "expected_holes": 120,
                  "title": "正常：120 孔混合直径阵列（D8/D12/D18/D26 各 30）",
                  "expected": "识别并创建 120 个 RBE2，washer 密度按 washer_rules.txt"})

    # ---- P2: oval + circular mix (RBE3-friendly) --------------------------
    p2 = model.add_component("V02_OVAL_RBE3_T1.5", 4,
                             model.add_property("PSHELL", "V02_OVAL_RBE3_T1.5_PSHELL", mat.mid, thickness=PLATE_T))
    origin2 = (2400.0, 0.0, 0.0)
    h2 = build_plate_array(model, p2, origin2, 4, 6, ("D12", "D18"))
    ovals = build_oval_cells(model, p2, (origin2[0] + 4 * CELL, 0.0, 0.0), 4, 6, 12.0, 6.0)
    h2 += ovals
    cases.append({"case_id": "P2", "component": p2.name, "expected_holes": 48,
                  "title": "正常：24 圆孔 + 24 椭圆长孔（2:1），可切 RBE3 运行",
                  "expected": "识别 48 个候选：24 circular + 24 oval，创建 48 个 RIGID"})

    # ---- P3: specials (reject / skip) -------------------------------------
    p3 = model.add_component("V03_SPECIAL_T1.5", 5,
                             model.add_property("PSHELL", "V03_SPECIAL_T1.5_PSHELL", mat.mid, thickness=PLATE_T))
    origin3 = (4800.0, 0.0, 0.0)
    h3_normal: List[Dict] = []
    holes3: List[Dict] = []
    for row in range(5):
        for col in range(8):
            center = cell_center(origin3, col, row)
            if row == 0 and col == 0:
                info = F.washer_hole_cell(model, p3, center, 4.0, 8, (2.0, 3.0), CELL, OUTER_SEG)
                holes3.append(dict(info, center=center, shape="circular_small",
                                   diameter=4.0, segments=8, widths=[2.0, 3.0]))
            elif row == 0 and col == 1:
                info = F.washer_hole_cell(model, p3, center, 40.0, 16, (8.0, 8.0), CELL, OUTER_SEG)
                holes3.append(dict(info, center=center, shape="circular_large",
                                   diameter=40.0, segments=16, widths=[8.0, 8.0]))
            elif row == 0 and col == 2:
                info = build_rect_cell(model, p3, center, 30.0, 6.0)
                holes3.append(dict(info, center=center, shape="rectangular",
                                   diameter=None, segments=8, widths=[]))
            else:
                spec = WASHER_BANDS[("D8", "D12", "D18")[(row * 8 + col) % 3]]
                info = F.washer_hole_cell(model, p3, center, spec["diameter"], spec["segments"],
                                          spec["widths"], CELL, OUTER_SEG)
                h3_normal.append(dict(info, center=center, shape="circular",
                                      diameter=spec["diameter"], segments=spec["segments"],
                                      widths=list(spec["widths"])))
    # pre-placed RBE2 holes: 3 among the normal array
    out3 = model.add_component("AUTO_RBE2_V03_SPECIAL_T1.5", 9)
    for idx in (1, 8, 17):
        existing_rbe2.append(place_rbe2(model, out3, h3_normal[idx]))
    cases.append({"case_id": "P3", "component": p3.name, "expected_holes": 37,
                  "title": "特殊：D4 小孔 / D40 大孔 / 矩形孔拒绝，3 个预置 RBE2 孔跳过",
                  "expected": "候选 37 个：34 正常创建 + 3 SKIP_EXISTING + 3 拒绝（DIAMETER_RANGE x2, NOT_CIRCULAR_OR_OVAL）"})

    # ---- P5: single-cell plate with an edge-flush hole ---------------------
    p5 = model.add_component("V05_EDGE_T1.5", 7,
                             model.add_property("PSHELL", "V05_EDGE_T1.5_PSHELL", mat.mid, thickness=PLATE_T))
    origin5 = (9600.0, 0.0, 0.0)
    cell5 = (origin5[0] + CELL / 2.0, origin5[1] + CELL / 2.0, 0.0)
    hole5 = (origin5[0] + CELL - 8.0, origin5[1] + CELL / 2.0, 0.0)  # 8 mm from the right edge
    edge_hole = build_edge_flush_cell(model, p5, cell5, hole5, 12.0, 10, (4.0, 6.0),
                                      origin5[0] + CELL)
    holes3.append(dict(edge_hole, center=hole5, shape="circular_edge",
                       diameter=12.0, segments=10, widths=[4.0, 6.0]))
    cases.append({"case_id": "P5", "component": p5.name, "expected_holes": 1,
                  "title": "边界：孔贴板右边缘（距边 8mm，washer 环被截断）",
                  "expected": "孔环可识别，但外 washer 环不完整 -> 拒绝（OUTER_RING_IRREGULAR）"})

    # ---- P4: 16x12 uniform D12 performance plate --------------------------
    p4 = model.add_component("V04_PERF_T1.5", 6,
                             model.add_property("PSHELL", "V04_PERF_T1.5_PSHELL", mat.mid, thickness=PLATE_T))
    h4 = build_plate_array(model, p4, (7200.0, 0.0, 0.0), 16, 12, ("D12",))
    cases.append({"case_id": "P4", "component": p4.name, "expected_holes": 192,
                  "title": "性能：192 孔均匀阵列（D12）压测批量创建与 BATCH_ORGANIZE",
                  "expected": "识别并创建 192 个 RBE2"})

    all_holes = h1 + h2 + h3_normal + holes3 + h4
    return model, cases, all_holes, existing_rbe2


def verify(model: Model, cases, all_holes, existing_rbe2) -> Dict:
    errors = []
    for case in cases:
        comp = next(c for c in model.components.values() if c.name == case["component"])
        loops = F.free_edge_loops(model, comp)
        holes_in = [h for h in all_holes if _comp_of(model, h) == comp.name]
        if case["case_id"] == "P5":
            # ragged plate edge: only require the intact hole loop
            if len(loops) < 1:
                errors.append("P5: no closed hole loop found")
        else:
            expected_loops = len(holes_in) + 1  # outer boundary + holes
            if len(loops) != expected_loops:
                errors.append("{}: free-edge loops {} != {}".format(case["case_id"], len(loops), expected_loops))
        q = F.mesh_quality_stats(model, comp)
        if q["degenerate"]:
            errors.append("{}: degenerate elements".format(case["case_id"]))
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors))
    stats = model.stats()
    stats.update({
        "washer_hole_count": len(all_holes),
        "preplaced_rbe2_count": len(existing_rbe2),
        "diameter_bands": ["D8", "D12", "D18", "D26"],
        "cell_size": CELL,
        "plate_thickness": PLATE_T,
    })
    return stats


def _comp_of(model: Model, hole: Dict) -> str:
    # find the component owning the hole's inner loop nodes
    nid = hole["inner_loop_node_ids"][0]
    for comp in model.components.values():
        for eid in comp.element_ids:
            if nid in model.elements[eid].node_ids:
                return comp.name
    return "?"


def manifest(model, cases, all_holes, existing_rbe2, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name, "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    return {
        "module": "shell_washer_hole_rbe2",
        "purpose": "LARGE shell washer-hole -> RIGIDS validation matrix (120+48+40+192 holes)",
        "generator": "tools/model_generation/gen_shell_washer.py",
        "fem": "ShellWasher_Large.fem",
        "parameters": {"min_hole_diameter": 6.0, "max_hole_diameter": 30.0,
                       "washer_rule_source": "config/washer_rules.txt",
                       "cell_size": CELL, "outer_cell_segments": OUTER_SEG},
        "statistics": stats,
        "components": comps,
        "cases": cases,
        "holes": [{"center": [round(v, 6) for v in h["center"]],
                   "shape": h["shape"], "diameter": h.get("diameter"),
                   "segments": h.get("segments", h.get("a"))} for h in all_holes],
        "existing_rbe2": existing_rbe2,
        "warning": "Validation geometry only; no loads/constraints. Pre-placed RBE2s exist only in AUTO_RBE2_V03_SPECIAL_T1.5.",
    }


def main():
    model, cases, all_holes, existing_rbe2 = build_model()
    stats = verify(model, cases, all_holes, existing_rbe2)
    outdir = common.model_dir("shell_washer_large")
    fem_path = outdir / "ShellWasher_Large.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "ShellWasher_Large_manifest.json",
                          manifest(model, cases, all_holes, existing_rbe2, stats))
    common.write_readme(outdir / "README.md", README)
    print({k: v for k, v in stats.items() if not isinstance(v, dict)})
    return 0


README = """# Shell Washer-Hole RIGIDS — Large Validation Model

## 用途
`ShellWasher_Large.fem` 用于 `shell_washer_hole_rbe2`（壳孔 RIGIDS）的大规模
验收/拒绝矩阵验证，规模约 **8 万单元 / 400 孔**，远超原 36 孔样例。

## 场景（按组件）
| 组件 | 内容 | 预期 |
|---|---|---|
| V01_WASHER_ARRAY_T1.5 | 12x10=120 孔，D8/D12/D18/D26 循环（各 30） | 创建 120 个 RBE2 |
| V02_OVAL_RBE3_T1.5 | 24 圆孔 + 24 椭圆长孔（2:1） | 创建 48 个 RIGID（RBE2 或切 RBE3） |
| V03_SPECIAL_T1.5 | 4 特殊孔（D4/D40/矩形/贴边）+ 3 预置 RBE2 + 24 正常 | 24 创建 + 3 跳过 + 4 拒绝 |
| V04_PERF_T1.5 | 16x12=192 孔 D12 | 创建 192 个 RBE2（性能压测） |
| AUTO_RBE2_V03_SPECIAL_T1.5 | 预置 RBE2 输出组件 | 供 SKIP_EXISTING 检测 |

## 操作
1. HyperMesh 导入 `ShellWasher_Large.fem`。
2. 选择组件（可全选 4 块板），模块默认参数（孔径 6~30、RBE2、DOF 123456）。
3. 执行创建；核对各组件输出 `AUTO_RBE2_<组件>` 的 RBE2 数量与拒绝日志。
4. 对 V02 可切 rigidType=RBE3 再跑一次。

## 设计说明
- washer 环密度严格按 `config/washer_rules.txt`（8/10/12/16 节点，层宽 4,6 / 4,6 / 6,8 / 8,8）。
- 贴边孔（V03 第 8 列）washer 环被板边截断 → 应被外环校验拒绝。
- 预置 RBE2 依赖节点 = 孔环 + 第一层 washer 环，模块应识别为 SKIP_EXISTING。
- 单元尺寸 3.75~10mm 渐变，无零面积/退化单元（生成时自检）。
"""


if __name__ == "__main__":
    raise SystemExit(main())
