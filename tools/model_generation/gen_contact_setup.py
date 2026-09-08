#!/usr/bin/env python3
"""gen_contact_setup.py -- LARGE two-face contact setup validation model for
contact_setup.

The module takes two separate Face selections and, from the common / opposing
region, builds two opposite-facing SURF contact surfaces plus a CONTACT group.
Its adaptive search tolerance is:

    searchTol = max(bboxAtoB gap + 2.5 * medianSpan, 2.5 * medianSpan)

with contact types SLIDE / STICK / FREEZE and main sides AUTO / FIRST / SECOND.

This generator authors 10 pairs of facing shell plates (each pair is two
components, ~300 mm apart between pairs):

   1-4   parallel plates, 300x200 .. 1000x800, gap 2..10 mm, mesh 8..15 mm
   5-6   partially overlapping pairs (30% / 50% plan offset)
   7-8   tilted pairs (20 deg / 35 deg, still facing)
   9     different mesh density (10 mm vs 20 mm)
   10    over-distance pair, 100 mm gap (negative / stress case)

Total >= 50k shell elements.  Contact surfaces / groups are created by the
module at run time.  Units mm / N / tonne.  Deterministic, stdlib-only.
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

PAIR_PITCH = 300.0


def make_plate(model: Model, comp: F.Component, origin: Tuple[float, float, float],
               w: float, h: float, mesh: float) -> F.Component:
    nx = max(2, int(round(w / mesh)))
    ny = max(2, int(round(h / mesh)))
    F.rect_plate_mesh(model, comp, origin, w, h, nx, ny)
    return comp


def flip_shells(model: Model, comp: F.Component) -> None:
    """Reverse the corner order of every 2D element of a component so its
    face normal flips.  Makes the two plates of a facing pair point their
    normals toward one another (z 法向相反)."""
    for eid in comp.element_ids:
        el = model.elements[eid]
        model.elements[eid].node_ids = tuple(reversed(el.node_ids))


def rotate_xy_plate_about_center(model: Model, comp: F.Component, center: Tuple[float, float, float],
                                 angle_deg: float, axis: str = "Y") -> None:
    """Rotate every node of a component about its centre on the given global
    axis (X or Y).  Used to tilt a facing plate pair while keeping them
    mutually parallel (still相向)."""
    c = math.cos(math.radians(angle_deg))
    s = math.sin(math.radians(angle_deg))
    cx, cy, cz = center
    touched = set()
    for el in model.elements_of(comp):
        for n in el.node_ids:
            if n in touched:
                continue
            touched.add(n)
            x, y, z = model.nodes[n]
            dx, dy, dz = x - cx, y - cy, z - cz
            if axis == "Y":
                nx, ny, nz = cx + dx * c + dz * s, cy + dy, cz - dx * s + dz * c
            else:  # X
                nx, ny, nz = cx + dx, cy + dy * c - dz * s, cz + dy * s + dz * c
            model.nodes[n] = (round(nx, 9), round(ny, 9), round(nz, 9))


def face_normal(model: Model, el) -> Tuple[float, float, float]:
    p = [model.nodes[n] for n in el.node_ids]
    u = (p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2])
    v = (p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2])
    nx = u[1] * v[2] - u[2] * v[1]
    ny = u[2] * v[0] - u[0] * v[2]
    nz = u[0] * v[1] - u[1] * v[0]
    ln = math.sqrt(nx * nx + ny * ny + nz * nz)
    if ln < 1e-12:
        return (0.0, 0.0, 0.0)
    return (nx / ln, ny / ln, nz / ln)


def comp_normal(model: Model, comp: F.Component) -> Tuple[float, float, float]:
    el = model.elements_of(comp)[0]
    return face_normal(model, el)


def build_model() -> Tuple[Model, List[Dict]]:
    model = Model("Two-face contact setup validation model (10 pairs)")
    mat = model.add_material("STEEL", mid=1)
    pairs = []

    def new_pair(idx: int, name_a: str, name_b: str) -> Tuple[F.Component, F.Component]:
        a = model.add_component(name_a, 1 + (idx % 6),
                                model.add_property("PSHELL", name_a + "_PSHELL", mat.mid, thickness=1.5))
        b = model.add_component(name_b, 8 + (idx % 6),
                                model.add_property("PSHELL", name_b + "_PSHELL", mat.mid, thickness=1.5))
        return a, b

    pair_index = 0
    px_cursor = 0.0

    def slot():
        nonlocal px_cursor
        return px_cursor

    # ---- 1..4 parallel pairs (gap 2..10 mm, mesh 8..15 mm) ----------------
    specs = [
        ("P1_PAR_300x200",  300.0, 200.0, 2.0,  8.0,   None),
        ("P2_PAR_400x300",  400.0, 300.0, 4.0,  10.0,  None),
        ("P3_PAR_600x450",  600.0, 450.0, 6.0,  10.0,  None),
        ("P4_PAR_1000x800", 1000.0, 800.0, 10.0, 12.0,  None),
    ]
    for name, w, h, gap, mesh, _ in specs:
        pair_index += 1
        cnameA = "V{0:02d}_A".format(pair_index)
        cnameB = "V{0:02d}_B".format(pair_index)
        a, b = new_pair(pair_index, cnameA, cnameB)
        base_x = slot()
        make_plate(model, a, (base_x, 0.0, 0.0), w, h, mesh)
        make_plate(model, b, (base_x, 0.0, gap), w, h, mesh)
        flip_shells(model, b)
        pairs.append({"id": pair_index, "label": name, "kind": "parallel", "gap_mm": gap,
                      "mesh_a": mesh, "mesh_b": mesh, "angle_deg": 0.0,
                      "a": a, "b": b, "dimensions": (w, h)})
        px_cursor = base_x + w + PAIR_PITCH

    # ---- 5..6 partially overlapping pairs (30% / 50% plan offset) ----------
    pair_index += 1
    a, b = new_pair(pair_index, "V{0:02d}_A".format(pair_index), "V{0:02d}_B".format(pair_index))
    base_x = slot(); w, h, gap, mesh = 600.0, 500.0, 4.0, 10.0
    overlap = 0.30
    make_plate(model, a, (base_x, 0.0, 0.0), w, h, mesh)
    make_plate(model, b, (base_x + w * (1.0 - overlap), 0.0, gap), w, h, mesh)
    flip_shells(model, b)
    pairs.append({"id": pair_index, "label": "P5_OVERLAP30%", "kind": "overlap",
                  "gap_mm": gap, "mesh_a": mesh, "mesh_b": mesh, "angle_deg": 0.0,
                  "a": a, "b": b, "dimensions": (w, h), "plan_offset_frac": overlap})
    px_cursor = base_x + w * 2 + PAIR_PITCH

    pair_index += 1
    a, b = new_pair(pair_index, "V{0:02d}_A".format(pair_index), "V{0:02d}_B".format(pair_index))
    base_x = slot(); w, h, gap, mesh = 800.0, 400.0, 6.0, 12.0
    overlap = 0.50
    make_plate(model, a, (base_x, 0.0, 0.0), w, h, mesh)
    make_plate(model, b, (base_x + w * (1.0 - overlap), 0.0, gap), w, h, mesh)
    flip_shells(model, b)
    pairs.append({"id": pair_index, "label": "P6_OVERLAP50%", "kind": "overlap",
                  "gap_mm": gap, "mesh_a": mesh, "mesh_b": mesh, "angle_deg": 0.0,
                  "a": a, "b": b, "dimensions": (w, h), "plan_offset_frac": overlap})
    px_cursor = base_x + w * 2 + PAIR_PITCH

    # ---- 7..8 tilted pairs (20 deg / 35 deg, parallel + facing) ------------
    for idx, (label, w, h, gap, mesh, ang) in enumerate([
            ("P7_TILT20", 700.0, 500.0, 5.0, 10.0, 20.0),
            ("P8_TILT35", 600.0, 300.0, 8.0, 10.0, 35.0)]):
        pair_index += 1
        a, b = new_pair(pair_index, "V{0:02d}_A".format(pair_index), "V{0:02d}_B".format(pair_index))
        base_x = slot()
        make_plate(model, a, (base_x, 0.0, -gap / 2.0), w, h, mesh)
        make_plate(model, b, (base_x, 0.0, gap / 2.0), w, h, mesh)
        flip_shells(model, b)
        ca = (base_x + w / 2.0, h / 2.0, 0.0)
        rotate_xy_plate_about_center(model, a, ca, ang, "Y")
        rotate_xy_plate_about_center(model, b, ca, ang, "Y")
        pairs.append({"id": pair_index, "label": label, "kind": "tilted", "gap_mm": gap,
                      "mesh_a": mesh, "mesh_b": mesh, "angle_deg": ang, "a": a, "b": b,
                      "dimensions": (w, h)})
        px_cursor = base_x + w + PAIR_PITCH

    # ---- 9 different mesh densities ----------------------------------------
    pair_index += 1
    a, b = new_pair(pair_index, "V{0:02d}_A".format(pair_index), "V{0:02d}_B".format(pair_index))
    base_x = slot(); w, h, gap = 800.0, 800.0, 4.0
    make_plate(model, a, (base_x, 0.0, 0.0), w, h, 10.0)
    make_plate(model, b, (base_x, 0.0, gap), w, h, 20.0)
    flip_shells(model, b)
    pairs.append({"id": pair_index, "label": "P9_DENSMIX", "kind": "density",
                  "gap_mm": gap, "mesh_a": 10.0, "mesh_b": 20.0, "angle_deg": 0.0,
                  "a": a, "b": b, "dimensions": (w, h)})
    px_cursor = base_x + w + PAIR_PITCH

    # ---- 10 over-distance pair (100 mm gap, negative / stress) --------------
    pair_index += 1
    a, b = new_pair(pair_index, "V{0:02d}_A".format(pair_index), "V{0:02d}_B".format(pair_index))
    base_x = slot(); w, h, gap, mesh = 500.0, 400.0, 100.0, 10.0
    make_plate(model, a, (base_x, 0.0, 0.0), w, h, mesh)
    make_plate(model, b, (base_x, 0.0, gap), w, h, mesh)
    flip_shells(model, b)
    pairs.append({"id": pair_index, "label": "P10_OVERDIST", "kind": "overdistance",
                  "gap_mm": gap, "mesh_a": mesh, "mesh_b": mesh, "angle_deg": 0.0,
                  "a": a, "b": b, "dimensions": (w, h)})
    return model, pairs


def verify(model: Model, pairs) -> Dict:
    errors = []
    if len(pairs) != 10:
        errors.append("pairs != 10")
    for pr in pairs:
        a, b = pr["a"], pr["b"]
        if not a.element_ids or not b.element_ids:
            errors.append("{} missing elements".format(pr["label"]))
        na = comp_normal(model, a)
        nb = comp_normal(model, b)
        dot = na[0] * nb[0] + na[1] * nb[1] + na[2] * nb[2]
        if dot > -0.5:
            errors.append("{} normals not opposite (dot={:.3f})".format(pr["label"], dot))
        # gap sanity: for axis-aligned pairs (parallel / density / overlap) the
        # plate gap equals the Z separation of matching element centroids.
        if pr["kind"] in ("parallel", "density", "overlap"):
            got_gap = _facing_gap(model, a, b)
            if got_gap is not None and abs(got_gap - pr["gap_mm"]) > max(pr["gap_mm"] * 0.3, 2.0):
                errors.append("{} facing gap {} != {}".format(
                    pr["label"], round(got_gap, 2), pr["gap_mm"]))
    total_elems = sum(len(c.element_ids) for c in model.components.values())
    if total_elems < 50000:
        errors.append("total shell elements {} < 50000".format(total_elems))
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors[:30]))
    stats = model.stats()
    shell_per_pair = [len(pr["a"].element_ids) + len(pr["b"].element_ids) for pr in pairs]
    stats.update({"pair_count": len(pairs), "shell_elements_per_pair": shell_per_pair,
                  "typical_searchTol_rule": "max(bboxGap + 2.5*medianSpan, 2.5*medianSpan)",
                  "contact_types": ["SLIDE", "STICK", "FREEZE"],
                  "main_sides": ["AUTO", "FIRST", "SECOND"]})
    return stats


def _facing_gap(model: Model, a: F.Component, b: F.Component):
    """Z separation between an A-element centre and the nearest opposite
    element centre (valid only for axis-aligned facing pairs)."""
    ea = model.elements_of(a)[0]
    eb = model.elements_of(b)[0]
    pa = _centroid(model, ea)
    pb = _centroid(model, eb)
    return abs(pa[2] - pb[2])


def _centroid(model: Model, el):
    ps = [model.nodes[n] for n in el.node_ids]
    n = len(ps)
    return (sum(p[0] for p in ps) / n, sum(p[1] for p in ps) / n, sum(p[2] for p in ps) / n)


def manifest(model: Model, pairs, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name, "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    pair_list = []
    for pr in pairs:
        d = {"id": pr["id"], "label": pr["label"], "kind": pr["kind"],
             "components": [pr["a"].name, pr["b"].name],
             "gap_mm": pr["gap_mm"], "mesh_a": pr["mesh_a"], "mesh_b": pr["mesh_b"],
             "angle_deg": pr["angle_deg"], "dimensions": list(pr["dimensions"])}
        if pr["kind"] == "overlap":
            d["plan_offset_frac"] = pr.get("plan_offset_frac")
        pair_list.append(d)
    return {
        "module": "contact_setup",
        "purpose": "LARGE two-face contact setup validation model (10 opposing plate pairs, >=50k shell)",
        "generator": "tools/model_generation/gen_contact_setup.py",
        "fem": "ContactSetup_10pairs.fem",
        "parameters": {"searchTol": "max(bboxGap + 2.5*medianSpan, 2.5*medianSpan)",
                       "contact_types": ["SLIDE", "STICK", "FREEZE"],
                       "main_sides": ["AUTO", "FIRST", "SECOND"]},
        "statistics": stats,
        "components": comps,
        "pairs": pair_list,
        "expected_module_result": "For each of pairs 1..9 the module builds two opposite SURF contact surfaces + "
                                  "a CONTACT group on the opposing common region; pair 10 (100 mm gap) is the "
                                  "over-distance negative/stress case.",
        "warning": "Contact surfaces and CONTACT groups are created by the module at run time, not pre-authored. "
                   "The adaptive searchTol grows with the inter-plate bbox gap, so the 100 mm pair may still couple "
                   "a thin edge region; treat it as the parametrisation stress/negative case.",
    }


def main():
    model, pairs = build_model()
    stats = verify(model, pairs)
    outdir = common.model_dir("contact_setup_10pairs")
    fem_path = outdir / "ContactSetup_10pairs.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "ContactSetup_10pairs_manifest.json",
                          manifest(model, pairs, stats))
    common.write_readme(outdir / "README.md", README)
    print({k: v for k, v in stats.items() if not isinstance(v, dict) and k != "shell_elements_per_pair"})
    return 0


README = """# Contact Setup — Large Validation Model

## 用途
`ContactSetup_10pairs.fem` 用于 `contact_setup`（两次 Face 选择创建相向接触）的大规模验证：
10 对相向壳板（每对 2 个组件），网格共 5 万余壳单元。接触面/接触 group 由模块运行时创建。

## 场景（按对）
| id | 类型 | 尺寸(mm) | 间隙 | 网格(mm) | 预期 |
|---|---|---|---|---|---|
| P1-P4 | 平行板 | 300x200~1000x800 | 2~10 | 8~12 | 创建若干 SURF + CONTACT group |
| P5 | 部分重叠 | 600x500 | 4 | 10 | 30% 面内错位，公共区相向 |
| P6 | 部分重叠 | 800x400 | 6 | 12 | 50% 面内错位 |
| P7 | 斜置 | 700x500 | 5 | 10 | 20° 倾斜仍相向 |
| P8 | 斜置 | 600x300 | 8 | 10 | 35° 倾斜仍相向 |
| P9 | 密度不同 | 800x800 | 4 | 10 vs 20 | 非对称网格接触 |
| P10 | 超距 | 500x400 | **100** | 10 | 负向/压测：间隙远超常规 |

## 操作
1. 导入 `ContactSetup_10pairs.fem`。
2. 对每对板两张面分别执行"分两次选择 Face"→"创建接触"；可切换接触类型
   SLIDE / STICK / FREEZE 与主面 AUTO / FIRST / SECOND 复跑。
3. 核对：P1-P9 生成相向 SURF 接触面；P10（100mm 超距）作为间隙参数化压测/负向。

## 设计说明
- 搜索距离自适应 `searchTol = max(bboxGap + 2.5*medianSpan, 2.5*medianSpan)`。
- 每对相向板的法向相反（自检断言）；斜置对保持两板彼此平行仍相向。
- 因公式随 bboxGap 增大，P10 的 100mm 对可能仍耦合极薄边缘区——README 标注为压测/负向语义。
"""


if __name__ == "__main__":
    raise SystemExit(main())
