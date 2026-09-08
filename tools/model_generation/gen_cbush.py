#!/usr/bin/env python3
"""gen_cbush.py -- LARGE CBUSH source-node validation model for cbush_creator.

The module's input is a set of source GRIDs.  For each source node it creates a
temporary node at (x, y, z+5), connects both with a CBUSH (Spring config 21 /
solver type 6, CID=0) and places every element for one source component into a
single output component named `CBUSH_<sourceComponentName>`.

This generator authors:
  - 4 source shell components (Vxx naming), each carrying 50 source nodes
    selected on a regular 10 x 5 grid across its mesh.  Every node belongs to
    exactly one component (plates are placed apart, no shared nodes), which is
    the module's required precondition for the unambiguous CBUSH naming.
  - 1 empty output component (no elements, no nodes) as a negative case: it
    must contribute nothing and should be skipped / warned on.

The module performs the actual Z+5 node + CBUSH creation at run time; none are
pre-authored here.  Units mm / N / tonne.  Deterministic, stdlib-only.
"""

from __future__ import annotations

import os
import sys
from typing import Dict, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import femlib as F
from femlib import Model

PLATE = 300.0          # plate side length
PLATE_T = 1.5
NX = 30                # mesh subdivisions -> 31x31 nodes per plate
NX_STRIDE = 30         # source-point stride along each axis (multiple of mesh)
SRC_COLS = 10
SRC_ROWS = 5           # 10 x 5 = 50 source nodes per plate

PLATES = [
    ("V01_PLATE_T1.5",  3, (0.0, 0.0, 0.0)),
    ("V02_PLATE_T1.5",  4, (400.0, 0.0, 0.0)),
    ("V03_PLATE_T1.5",  5, (0.0, 400.0, 0.0)),
    ("V04_PLATE_T1.5",  6, (400.0, 400.0, 0.0)),
]


def build_plate(model: Model, name: str, color: int, origin) -> F.Component:
    comp = model.add_component(name, color, model.add_property("PSHELL", name + "_PSHELL", 1, thickness=PLATE_T))
    F.rect_plate_mesh(model, comp, origin, PLATE, PLATE, NX, NX)
    return comp


def collect_source_nodes(model: Model, comp: F.Component, origin) -> List[int]:
    """50 source nodes on a regular 10 x 5 grid (30 mm pitch, aligned with the
    10 mm mesh so every coordinate hits a mesh node)."""
    src = []
    for m in range(SRC_ROWS):
        for k in range(SRC_COLS):
            x = origin[0] + k * NX_STRIDE
            y = origin[1] + m * NX_STRIDE
            src.append(model.node(x, y, origin[2]))
    return src


def build_model() -> Dict:
    model = Model("CBUSH creator source-node validation model")
    model.add_material("STEEL", mid=1)
    plates = []
    for name, color, origin in PLATES:
        comp = build_plate(model, name, color, origin)
        src = collect_source_nodes(model, comp, origin)
        plates.append({"component": comp, "origin": origin, "source_nodes": src})
    # empty negative-case component (no nodes / no elements)
    empty = model.add_component("V05_EMPTY", 7)
    return {"model": model, "plates": plates, "empty": empty}


def verify(model: Model, plates, empty) -> Dict:
    errors = []
    if len(plates) != 4:
        errors.append("expected 4 source plates")
    for p in plates:
        if len(p["source_nodes"]) != 50:
            errors.append("{} has {} source nodes != 50".format(p["component"].name, len(p["source_nodes"])))
        if not p["component"].element_ids:
            errors.append("{} has no mesh".format(p["component"].name))
        # every source node belongs to exactly this component
        for nid in p["source_nodes"]:
            owners = [c for c in model.components.values()
                      if any(nid in model.elements[e].node_ids for e in c.element_ids)]
            if len(owners) != 1 or owners[0].cid != p["component"].cid:
                errors.append("source node {} not uniquely owned by {}".format(nid, p["component"].name))
    if empty.element_ids:
        errors.append("empty component should have no elements")
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors[:30]))
    stats = model.stats()
    stats.update({"source_nodes": sum(len(p["source_nodes"]) for p in plates),
                  "source_components": len(plates), "empty_component": empty.name,
                  "nodes_per_plate": 50, "expected_cbush": 200})
    return stats


def manifest(model: Model, plates, empty, stats) -> Dict:
    comps = [{"component_id": c.cid, "name": c.name, "element_count": len(c.element_ids),
              "property": c.property.name if c.property else None}
             for c in sorted(model.components.values(), key=lambda x: x.cid)]
    return {
        "module": "cbush_creator",
        "purpose": "LARGE CBUSH source-node validation model (200 source nodes across 4 components)",
        "generator": "tools/model_generation/gen_cbush.py",
        "fem": "Cbush_200nodes.fem",
        "parameters": {"z_offset_mm": 5.0, "spring_config": 21, "solver_type": 6, "cid": 0,
                       "output_component_prefix": "CBUSH_"},
        "statistics": stats,
        "components": comps,
        "source_plates": [{
            "component": p["component"].name,
            "expected_output_component": "CBUSH_" + p["component"].name,
            "source_nodes": p["source_nodes"],
        } for p in plates],
        "negative_case": {"component": empty.name, "note": "empty component (no nodes) -> no CBUSH; module should skip/warn"},
        "expected_module_result": "200 CBUSH elements into CBUSH_V0x_PLATE_T1.5 output components; empty component contributes nothing",
        "warning": "Z+5 temporary nodes and CBUSH elements are created by the module at run time, not pre-authored here.",
    }


def main():
    ctx = build_model()
    model, plates, empty = ctx["model"], ctx["plates"], ctx["empty"]
    stats = verify(model, plates, empty)
    outdir = common.model_dir("cbush_200nodes")
    fem_path = outdir / "Cbush_200nodes.fem"
    model.write_fem(str(fem_path))
    F.verify_fem_file(str(fem_path))
    common.write_manifest(outdir / "Cbush_200nodes_manifest.json", manifest(model, plates, empty, stats))
    common.write_readme(outdir / "README.md", README)
    print({k: v for k, v in stats.items() if not isinstance(v, dict)})
    return 0


README = """# CBUSH Creator — Large Validation Model

## 用途
`Cbush_200nodes.fem` 用于 `cbush_creator`（单个/批量 CBUSH 创建）的大规模验证：
4 个源组件各 50 个源节点，模块应逐节点在 (x, y, z+5) 创建临时节点并连 CBUSH，
输出到 `CBUSH_<源组件>` 组件。

## 场景
| 组件 | 内容 | 预期 |
|---|---|---|
| V01..V04_PLATE_T1.5 | 每块 31x31=961 网格节点，其中 50 个规则源节点 | 各创建 50 个 CBUSH 到 `CBUSH_V0x_PLATE_T1.5` |
| V05_EMPTY | 空组件（无节点无单元） | 无 CBUSH，模块应跳过/提示 |

## 操作
1. 导入 `Cbush_200nodes.fem`，框选（或按组件选）4 块板上的源节点。
2. 运行模块；核对共 200 个 CBUSH、4 个 `CBUSH_*` 输出组件。
3. 单独选中空组件 V05_EMPTY 运行，确认无输出且不报错。

## 设计说明
- 每个源节点唯一归属一个组件（板彼此分离、节点不共用），满足模块"节点归属唯一"要求。
- 源节点按 30mm 节距 10x5 规则取点，铺满板面中部，与 10mm 网格对齐。
- 临时节点与 CBUSH 由模块在运行时生成；本模型不预置任何 CBUSH。
"""


if __name__ == "__main__":
    raise SystemExit(main())
