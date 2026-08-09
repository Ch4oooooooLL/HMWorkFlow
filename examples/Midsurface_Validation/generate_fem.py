#!/usr/bin/env python3
"""Generate the BOM Material Assignment validation FEM deck.

Output: examples/Midsurface_Validation/Midsurface_Imported_State.fem

Run from the repository root with the portable runtime (pure stdlib, no third
party dependencies; works on Python 3.8):

    runtime/python/windows-x64/python.exe examples/Midsurface_Validation/generate_fem.py

The deck simulates the post-midsurface-extraction state: shell components that
already live in the MIDSURFED assembly.  It intentionally contains NO Q355
material, so the first run of the BOM module must create it (creation path)
and a second run must reuse it (reuse/idempotent path).

Component naming follows the workflow convention Vxx_<part>_T<thickness>[_material]:
  - V01_PANEL_T1.5            no material suffix      -> gets _Q355
  - V02_BRACKET_T2.0_Q355     already ends in _Q355   -> name unchanged (skip)
  - V03_REINF_T1.0            no material suffix      -> gets _Q355
  - V04_NO_THICKNESS          no _T token             -> _Q355 appended, thickness unparseable -> review list
  - V05_ARC_T1.5_STEEL        other material suffix   -> STEEL replaced by _Q355
  - V08_PLATE_HOLES_T1.0      no material suffix      -> gets _Q355

HyperMesh assemblies are not persisted in bulk decks; after import create the
"MIDSURFED" assembly and add these components (or import the STEP model first
so the mid-surface module creates MIDSURFED, then add the shells).
"""

from __future__ import annotations

import argparse
import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

Point = Tuple[float, float, float]

OUT_DIR = Path(__file__).resolve().parent
FEM_NAME = "Midsurface_Imported_State.fem"
MANIFEST_NAME = "Midsurface_Validation_manifest.json"

STEEL_MATERIAL_ID = 1
Q355 = "Q355"


@dataclass(frozen=True)
class Element:
    card: str
    element_id: int
    property_id: int
    node_ids: Tuple[int, ...]


@dataclass
class Component:
    component_id: int
    name: str
    color: int
    element_ids: List[int] = field(default_factory=list)


@dataclass
class Model:
    nodes: Dict[int, Point] = field(default_factory=dict)
    elements: Dict[int, Element] = field(default_factory=dict)
    components: Dict[int, Component] = field(default_factory=dict)
    properties: Dict[int, Tuple[str, str, float]] = field(default_factory=dict)
    cases: List[Dict[str, object]] = field(default_factory=list)
    next_node_id: int = 1
    next_element_id: int = 1

    def component(self, component_id: int, name: str, color: int = 11) -> Component:
        if component_id in self.components:
            raise ValueError("duplicate component ID {}".format(component_id))
        item = Component(component_id, name, color)
        self.components[component_id] = item
        return item

    def property(self, property_id: int, name: str, thickness: float) -> None:
        self.properties[property_id] = ("PSHELL", name, thickness)

    def node(self, point: Point) -> int:
        node_id = self.next_node_id
        self.next_node_id += 1
        self.nodes[node_id] = tuple(float(value) for value in point)
        return node_id

    def element(self, component_id: int, card: str, node_ids: Sequence[int], property_id: int = 0) -> int:
        element_id = self.next_element_id
        self.next_element_id += 1
        item = Element(card, element_id, property_id or component_id, tuple(node_ids))
        self.elements[element_id] = item
        self.components[component_id].element_ids.append(element_id)
        return element_id


def add(a: Point, b: Point) -> Point:
    return a[0] + b[0], a[1] + b[1], a[2] + b[2]


def scale(a: Point, value: float) -> Point:
    return a[0] * value, a[1] * value, a[2] * value


def grid_nodes(model: Model, origin: Point, u: Point, v: Point, nu: int, nv: int) -> Dict[Tuple[int, int], int]:
    """Regular grid of nodes over origin + [0..u] x [0..v]."""
    grid: Dict[Tuple[int, int], int] = {}
    for j in range(nv + 1):
        for i in range(nu + 1):
            grid[(i, j)] = model.node(add(origin, add(scale(u, i / float(nu)), scale(v, j / float(nv)))))
    return grid


def add_quads(model: Model, component_id: int, grid: Dict[Tuple[int, int], int], nu: int, nv: int) -> None:
    for j in range(nv):
        for i in range(nu):
            model.element(component_id, "CQUAD4",
                          (grid[(i, j)], grid[(i + 1, j)], grid[(i + 1, j + 1)], grid[(i, j + 1)]))


# --------------------------------------------------------------------------
# Components
# --------------------------------------------------------------------------


def add_flat_shell(model: Model, component_id: int, name: str, origin: Point, size: Point,
                   nu: int, nv: int, thickness: float) -> None:
    model.component(component_id, name)
    model.property(component_id, name, thickness)
    grid = grid_nodes(model, origin, (size[0], 0, 0), (0, size[1], 0), nu, nv)
    add_quads(model, component_id, grid, nu, nv)


def add_l_bracket_shell(model: Model, component_id: int, name: str, bx: float,
                        thickness: float = 2.0) -> None:
    """L-shaped shell: 150x100 base at z=0 plus a 100-high flange folded at y=50."""
    model.component(component_id, name)
    model.property(component_id, name, thickness)
    nu, nv = 15, 10
    g_base = grid_nodes(model, (bx, -50, 0), (150, 0, 0), (0, 100, 0), nu, nv)
    # flange shares the fold-line nodes (y=50, z=0)
    g_flange: Dict[Tuple[int, int], int] = {}
    for j in range(nv + 1):
        for i in range(nu + 1):
            if j == 0:
                g_flange[(i, j)] = g_base[(i, nv)]
            else:
                g_flange[(i, j)] = model.node((bx + i * (150.0 / nu), 50.0, j * (100.0 / nv)))
    add_quads(model, component_id, g_base, nu, nv)
    add_quads(model, component_id, g_flange, nu, nv)


def add_arc_shell(model: Model, component_id: int, name: str, origin: Point,
                  radius: float = 80.0, width: float = 120.0,
                  nth: int = 12, nw: int = 10, thickness: float = 1.5) -> None:
    """Quarter-arc shell: mid-radius arc of the V05 bent plate."""
    model.component(component_id, name)
    model.property(component_id, name, thickness)
    grid: Dict[Tuple[int, int], int] = {}
    for j in range(nw + 1):
        z = origin[2] + width * j / float(nw)
        for i in range(nth + 1):
            theta = (math.pi / 2.0) * i / float(nth)
            grid[(i, j)] = model.node((origin[0] + radius * math.cos(theta),
                                       origin[1] + radius * math.sin(theta), z))
    add_quads(model, component_id, grid, nth, nw)


def build_model() -> Model:
    model = Model()
    # Isolated shell components spaced along X.  All currently reference the
    # pre-existing STEEL material through their PSHELL; the BOM module will
    # reassign Q355 at the component level.
    add_flat_shell(model, 1001, "V01_PANEL_T1.5", (0, -60, 0), (200, 120), 20, 12, 1.5)
    add_l_bracket_shell(model, 1002, "V02_BRACKET_T2.0_Q355", 500.0)
    add_flat_shell(model, 1003, "V03_REINF_T1.0", (950, -60, 0), (180, 120), 18, 12, 1.0)
    add_flat_shell(model, 1004, "V04_NO_THICKNESS", (1430, -50, 0), (140, 100), 14, 10, 1.5)
    add_arc_shell(model, 1005, "V05_ARC_T1.5_STEEL", (2010, 0, 0))
    add_flat_shell(model, 1006, "V08_PLATE_HOLES_T1.0", (2390, -80, 0), (240, 160), 24, 16, 1.0)

    model.cases = build_bom_cases()
    return model


# --------------------------------------------------------------------------
# Cases
# --------------------------------------------------------------------------


def build_bom_cases() -> List[Dict[str, object]]:
    return [
        {
            "case_id": "B01",
            "title": "无材料后缀组件，创建并赋予 Q355",
            "component_ids": [1001],
            "component_names": ["V01_PANEL_T1.5"],
            "expected_mode": "normal",
            "expected_results": {"final_name": "V01_PANEL_T1.5_Q355", "material": Q355,
                                 "name_change": "created"},
            "notes": "模块将组件名规范为 *_Q355 并赋予 Q355 材料。",
        },
        {
            "case_id": "B02",
            "title": "已带 _Q355 后缀，名称跳过",
            "component_ids": [1002],
            "component_names": ["V02_BRACKET_T2.0_Q355"],
            "expected_mode": "normal",
            "expected_results": {"final_name": "V02_BRACKET_T2.0_Q355", "material": Q355,
                                 "name_change": "unchanged"},
            "notes": "名称已符合 *_Q355，rename 被跳过（unchanged 计数），材料仍被赋予。"
                     "重复运行模块应幂等（B02 仍 unchanged）。",
        },
        {
            "case_id": "B03",
            "title": "无材料后缀组件，创建并赋予 Q355（厚度 token 规范化）",
            "component_ids": [1003],
            "component_names": ["V03_REINF_T1.0"],
            "expected_mode": "normal",
            "expected_results": {"final_name": "V03_REINF_T1_Q355", "material": Q355,
                                 "name_change": "created"},
            "notes": "厚度 1.0 经 formatThicknessToken 规范化为 T1（1.0 -> '1'）。",
        },
        {
            "case_id": "B04",
            "title": "名称无法解析厚度，列入复核",
            "component_ids": [1004],
            "component_names": ["V04_NO_THICKNESS"],
            "expected_mode": "review",
            "expected_results": {"final_name": "V04_NO_THICKNESS_Q355", "material": Q355,
                                 "name_change": "created"},
            "notes": "组件名不含 _T token，componentNameInfo 无法解析厚度；BOM 模块 v0.1"
                     "仍会追加 _Q355 并赋予材料，不拒绝。厚度缺失应转入下游属性赋予模块的"
                     "复核清单（本验证仅确认模块不崩溃、日志可核对）。",
        },
        {
            "case_id": "B05",
            "title": "带其他材料后缀，替换为 Q355",
            "component_ids": [1005],
            "component_names": ["V05_ARC_T1.5_STEEL"],
            "expected_mode": "normal",
            "expected_results": {"final_name": "V05_ARC_T1.5_Q355", "material": Q355,
                                 "name_change": "created"},
            "notes": "尾部材料字段 STEEL 被 Q355 替换，避免累积 _STEEL_Q355。",
        },
        {
            "case_id": "B06",
            "title": "无材料后缀组件，创建并赋予 Q355（带孔板）",
            "component_ids": [1006],
            "component_names": ["V08_PLATE_HOLES_T1.0"],
            "expected_mode": "normal",
            "expected_results": {"final_name": "V08_PLATE_HOLES_T1_Q355", "material": Q355,
                                 "name_change": "created"},
            "notes": "厚度 1.0 规范化为 T1。",
        },
    ]


# --------------------------------------------------------------------------
# Validation / writing
# --------------------------------------------------------------------------


def validate(model: Model) -> Dict[str, int]:
    errors: List[str] = []
    expected_node_count = {"CQUAD4": 4}
    for element in model.elements.values():
        if element.card not in expected_node_count or len(element.node_ids) != expected_node_count[element.card]:
            errors.append("malformed {} {}".format(element.card, element.element_id))
        if element.property_id not in model.properties:
            errors.append("element {} missing property {}".format(element.element_id, element.property_id))
        if any(node not in model.nodes for node in element.node_ids):
            errors.append("element {} references missing nodes".format(element.element_id))
        # non-degenerate quad in any orientation: area = |d1 x d2| / 2 > 0
        n0, n1, n2, n3 = (model.nodes[nid] for nid in element.node_ids)
        d1 = (n2[0] - n0[0], n2[1] - n0[1], n2[2] - n0[2])
        d2 = (n3[0] - n1[0], n3[1] - n1[1], n3[2] - n1[2])
        cross = ((d1[1] * d2[2] - d1[2] * d2[1]),
                 (d1[2] * d2[0] - d1[0] * d2[2]),
                 (d1[0] * d2[1] - d1[1] * d2[0]))
        area = 0.5 * math.sqrt(cross[0] ** 2 + cross[1] ** 2 + cross[2] ** 2)
        if area < 1e-9:
            errors.append("degenerate CQUAD4 {}".format(element.element_id))
    for component in model.components.values():
        if not component.element_ids:
            errors.append("empty component {}".format(component.component_id))
        if len(component.element_ids) < 4:
            errors.append("shell component {} under-meshed".format(component.component_id))
    if len(model.cases) != 6:
        errors.append("expected 6 BOM cases")
    # name-token spot checks mirroring ::HWFlow::thicknessFromComponentName
    for name in ("V01_PANEL_T1.5", "V02_BRACKET_T2.0_Q355", "V05_ARC_T1.5_STEEL"):
        if "_T" not in name:
            errors.append("expected a _T token in {}".format(name))
    thickness_token = re.compile(r"(?:^|_)T[0-9]")
    if thickness_token.search("V04_NO_THICKNESS"):
        errors.append("V04 name must not parse a thickness token")
    if not errors:
        return {
            "nodes": len(model.nodes),
            "elements": len(model.elements),
            "components": len(model.components),
            "quad4": sum(1 for item in model.elements.values() if item.card == "CQUAD4"),
            "cases": len(model.cases),
        }
    raise ValueError("validation failed:\n- " + "\n- ".join(errors))


def write_fem(model: Model, output: Path) -> None:
    lines = [
        "$ Midsurface validation - imported post-extraction state",
        "$ Shell components as delivered by the mid-surface module; no Q355 material",
        "$ is pre-defined so the BOM module exercises the create path on first run",
        "$ Generated by examples/Midsurface_Validation/generate_fem.py",
        "$ Units: mm, N, MPa. Test geometry only.",
        "BEGIN BULK",
        '$HMNAME MAT {} "STEEL"'.format(STEEL_MATERIAL_ID),
        "MAT1,{},210000.0,,0.3,7.85E-9".format(STEEL_MATERIAL_ID),
        "$ PROPERTIES",
    ]
    for property_id, (card, name, thickness) in sorted(model.properties.items()):
        lines.append('$HMNAME PROP {} "{}"'.format(property_id, name))
        lines.append("PSHELL,{},{},{:.9g}".format(property_id, STEEL_MATERIAL_ID, thickness))
    lines.append("$ COMPONENT NAMES")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend(('$HMNAME COMP {} "{}"'.format(component.component_id, component.name),
                      "$HWCOLOR COMP {} {}".format(component.component_id, component.color)))
    lines.append("$ NODES")
    for node_id, point in sorted(model.nodes.items()):
        lines.append("GRID,{},,{:.9g},{:.9g},{:.9g}".format(node_id, *point))
    lines.append("$ ELEMENTS GROUPED BY HYPERMESH COMPONENT")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend(("$HMCOMP ID {}".format(component.component_id), "$ " + component.name))
        for element_id in component.element_ids:
            element = model.elements[element_id]
            lines.append("CQUAD4,{},{},{},{},{},{}".format(
                element.element_id, element.property_id, *element.node_ids))
    lines.extend(("ENDDATA", ""))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def validate_written_fem(output: Path, stats: Dict[str, int]) -> None:
    lines = output.read_text(encoding="utf-8").splitlines()
    if "BEGIN BULK" not in lines or lines[-1] != "ENDDATA":
        raise ValueError("FEM is missing BEGIN BULK or terminal ENDDATA")
    actual = sum(line.startswith("CQUAD4,") for line in lines)
    if actual != stats["quad4"]:
        raise ValueError("written CQUAD4 count {} != {}".format(actual, stats["quad4"]))
    if any('$HMNAME MAT' in line and 'Q355' in line for line in lines):
        raise ValueError("deck must not pre-define a Q355 material (create path must be exercised)")
    oversized = [(index, line) for index, line in enumerate(lines, 1)
                 if line and not line.startswith("$") and len(line.split(",")) > 9]
    if oversized:
        raise ValueError("free-format card exceeds nine fields at line {}".format(oversized[0][0]))


def merge_manifest(stats: Dict[str, int]) -> None:
    manifest_path = OUT_DIR / MANIFEST_NAME
    manifest = {}
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            manifest = {}
    fem_statistics = {
        "fem_nodes": stats["nodes"],
        "fem_elements": stats["elements"],
        "fem_components": stats["components"],
        "fem_quad4": stats["quad4"],
    }
    if not manifest:
        manifest = {
            "schema_version": "1.0",
            "purpose": "Midsurface Extraction（抽中面）模块验证：8 件钣金/非钣金实体沿 X 排布，"
                       "覆盖正常抽中面、变厚件、非钣金块、带孔板等场景；FEM 部分覆盖 BOM 材料赋予。",
            "generator": "examples/Midsurface_Validation/generate_geometry.py + generate_fem.py",
            "geometry": "examples/Midsurface_Validation/Midsurface_SheetMetal_8Parts.step",
            "fem": "examples/Midsurface_Validation/" + FEM_NAME,
            "parameters": {},
            "statistics": {},
            "components": {},
            "cases": [],
        }
    manifest["fem"] = "examples/Midsurface_Validation/" + FEM_NAME
    manifest["parameters"]["x_gap_min_mm"] = 300.0
    if not isinstance(manifest["statistics"], dict):
        manifest["statistics"] = {}
    manifest["statistics"].update(fem_statistics)
    manifest["statistics"]["midsurf_cases"] = "G01..G08 (see geometry generator)"
    manifest["statistics"]["bom_cases"] = 6
    existing_ids = {case.get("case_id") for case in manifest.get("cases", [])}
    new_cases = [case for case in build_bom_cases() if case["case_id"] not in existing_ids]
    merged: List[Dict[str, object]] = []
    seen = set()
    for case in manifest.get("cases", []) + new_cases:
        case_id = case.get("case_id")
        if case_id in seen:
            continue
        seen.add(case_id)
        merged.append(case)
    manifest["cases"] = merged
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUT_DIR / FEM_NAME)
    parser.add_argument("--manifest", type=Path, default=OUT_DIR / MANIFEST_NAME)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    model = build_model()
    stats = validate(model)
    write_fem(model, args.output.resolve())
    validate_written_fem(args.output.resolve(), stats)
    merge_manifest(stats)
    print("wrote {}".format(args.output.resolve()))
    print("statistics: {}".format(json.dumps(stats)))
    print("all FEM self-checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
