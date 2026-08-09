#!/usr/bin/env python3
"""RIGIDS Bolt Connector validation model generator (examples/BoltConnector_Validation).

Run from the repository root:

    runtime\\python\\windows-x64\\python.exe examples\\BoltConnector_Validation\\generate_fem.py

Deterministic, stdlib-only (Python 3.8+).  Produces an OptiStruct bulk deck of
GRID + RBE2 cards covering the acceptance / rejection matrix of the
rbe2_bolt_connector module (planar/spatial RIGIDS grouping -> CBEAM bolts):

  C01  normal   coaxial planar RBE2 chain, 4 rings z=0/20/40/60 (D16) -> 3 bolts
  C02  normal   multi-diameter stacks: D12 (z 0/20/40) and D20 (z 0/20/40)
                -> 4 bolts, BOLT_D12_CBEAM + BOLT_D20_CBEAM
  C03  reject   spatial (3-D spread) coaxial RBE2 pair -> group formed but
                plan rejects SPATIAL_ONLY (no planar record)
  C04  reject   two planar RBE2 with 10 mm transverse offset (> offsetTol 5)
                -> no group
  C05  reject   single isolated planar RBE2 -> below minGroupSize 2 -> no group
  C06  boundary two stacks: offset exactly 5.0 mm (match, 1 bolt) and
                5.1 mm (no match, no bolt)

Planar rings lie in XY planes (normal_axis Z).  Module defaults used:
axisMode AUTO, gapTol 100, offsetTol 5, minGroupSize 2, minBeamLength 0.001,
planeAbsTol 0.5, planeFlatRatio 0.12, radialAbsTol 0.5, radialRelTol 0.08,
elemType CBEAM, compPrefix BOLT.  Units: mm.  This is a validation deck
(RBE2 + GRID only; the bolt module reads exactly those cards).

The generator self-checks the geometry.  With --verify-module it additionally
loads the repository's rbe2_bolt_connector python pipeline and asserts the
analyze -> group -> plan results match the manifest expectations.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

Point = Tuple[float, float, float]

# Module default settings (rbe2_bolt_connector/python/schema.py DEFAULTS).
SETTINGS = {
    "axisMode": "AUTO", "gapTol": 100.0, "offsetTol": 5.0, "minGroupSize": 2,
    "minBeamLength": 0.001, "planeAbsTol": 0.5, "planeFlatRatio": 0.12,
    "radialAbsTol": 0.5, "radialRelTol": 0.08, "elemType": "CBEAM",
    "compPrefix": "BOLT", "propName": "", "dryRun": False,
}

RING_DEPENDENTS = 8  # dependents per planar ring (>=3 required)


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
    property_id: int
    color: int
    element_ids: List[int] = field(default_factory=list)


@dataclass
class Rbe2Record:
    element_id: int
    center_node_id: int
    center: Point
    dependent_node_ids: List[int]
    ring_radius: float
    planar: bool
    normal_axis: str
    scenario: str


class Model:
    def __init__(self) -> None:
        self.nodes: Dict[int, Point] = {}
        self.elements: Dict[int, Element] = {}
        self.components: Dict[int, Component] = {}
        self.next_node_id = 1
        self.next_element_id = 1
        self.rbe2: List[Rbe2Record] = []

    def add_component(self, component_id: int, name: str, color: int) -> Component:
        component = Component(component_id, name, component_id, color)
        self.components[component_id] = component
        return component

    def add_node(self, point: Point) -> int:
        node_id = self.next_node_id
        self.next_node_id += 1
        self.nodes[node_id] = tuple(round(float(v), 10) for v in point)
        return node_id

    def add_rbe2(self, component_id: int, center: Point, dependents: Sequence[Point]) -> Rbe2Record:
        center_node_id = self.add_node(center)
        dependent_ids = [self.add_node(p) for p in dependents]
        element_id = self.next_element_id
        self.next_element_id += 1
        node_ids = tuple([center_node_id] + dependent_ids)
        self.elements[element_id] = Element("RBE2", element_id, 1, node_ids)
        self.components[component_id].element_ids.append(element_id)
        radius = max(math.hypot(p[0] - center[0], p[1] - center[1], p[2] - center[2]) for p in dependents)
        record = Rbe2Record(
            element_id=element_id, center_node_id=center_node_id, center=tuple(center),
            dependent_node_ids=dependent_ids, ring_radius=radius,
            planar=True, normal_axis="", scenario="",
        )
        self.rbe2.append(record)
        return record


def ring_points(center: Point, radius: float, z: float, count: int = RING_DEPENDENTS) -> List[Point]:
    """Planar ring of dependents in the XY plane at height z (normal_axis Z)."""
    return [(center[0] + radius * math.cos(2.0 * math.pi * i / count),
             center[1] + radius * math.sin(2.0 * math.pi * i / count),
             z) for i in range(count)]


def cube_points(center: Point, half: float) -> List[Point]:
    """Eight cube-corner dependents -> ranges (2h, 2h, 2h) -> non-planar."""
    cx, cy, cz = center
    return [(cx + sx * half, cy + sy * half, cz + sz * half)
            for sx in (-1.0, 1.0) for sy in (-1.0, 1.0) for sz in (-1.0, 1.0)]


def planar_axis(points: Sequence[Point]) -> Optional[str]:
    """Replicate planar_detector.detect: min range <= 0.5 or <= 0.12 of max."""
    ranges = [max(p[i] for p in points) - min(p[i] for p in points) for i in range(3)]
    minimum, maximum = min(ranges), max(ranges)
    if maximum <= 0 or (minimum > SETTINGS["planeAbsTol"] and minimum / maximum > SETTINGS["planeFlatRatio"]):
        return None
    return "XYZ"[ranges.index(minimum)]


def add_planar_ring(model, component_id, scenario, center_xy, z, radius) -> Rbe2Record:
    center = (center_xy[0], center_xy[1], z)
    dependents = ring_points(center, radius, z)
    record = model.add_rbe2(component_id, center, dependents)
    axis = planar_axis(dependents)
    assert axis == "Z", "planar ring should be an XY-plane loop (normal_axis Z)"
    record.planar = True
    record.normal_axis = axis
    record.ring_radius = radius
    record.scenario = scenario
    return record


def add_spatial(model, component_id, scenario, center_xy, z, half) -> Rbe2Record:
    center = (center_xy[0], center_xy[1], z)
    dependents = cube_points(center, half)
    record = model.add_rbe2(component_id, center, dependents)
    assert planar_axis(dependents) is None, "cube spread must be non-planar"
    record.planar = False
    record.normal_axis = ""
    record.scenario = scenario
    return record


def build_model():
    model = Model()
    scenarios = []
    rbe2_by_scenario: Dict[str, List[Rbe2Record]] = {}

    # ---- C01 coaxial planar chain (D16, 20 mm spacing) ----------------------
    c01 = model.add_component(101, "B1_COAXIAL_CHAIN", 3)
    records = [add_planar_ring(model, 101, "C01", (0.0, 0.0), z, 8.0) for z in (0.0, 20.0, 40.0, 60.0)]
    rbe2_by_scenario["C01"] = records
    scenarios.append({
        "case_id": "C01", "component_id": 101, "name": "B1_COAXIAL_CHAIN",
        "rbe2_ids": [r.element_id for r in records],
        "ring_z": [0.0, 20.0, 40.0, 60.0], "ring_radius": 8.0,
        "center_xy": [0.0, 0.0],
    })

    # ---- C02 multi-diameter stacks (D12 + D20) ------------------------------
    c02 = model.add_component(102, "B2_MULTI_DIAMETER", 4)
    d12 = [add_planar_ring(model, 102, "C02", (2000.0, 0.0), z, 6.0) for z in (0.0, 20.0, 40.0)]
    d20 = [add_planar_ring(model, 102, "C02", (2400.0, 0.0), z, 10.0) for z in (0.0, 20.0, 40.0)]
    rbe2_by_scenario["C02"] = d12 + d20
    scenarios.append({
        "case_id": "C02", "component_id": 102, "name": "B2_MULTI_DIAMETER",
        "rbe2_ids": [r.element_id for r in d12 + d20],
        "stacks": [
            {"diameter": 12.0, "ring_radius": 6.0, "center_xy": [2000.0, 0.0], "ring_z": [0.0, 20.0, 40.0]},
            {"diameter": 20.0, "ring_radius": 10.0, "center_xy": [2400.0, 0.0], "ring_z": [0.0, 20.0, 40.0]},
        ],
    })

    # ---- C03 spatial (non-planar) coaxial pair ------------------------------
    c03 = model.add_component(103, "B3_SPATIAL_RIGIDS", 5)
    spatial = [add_spatial(model, 103, "C03", (3000.0, 0.0), z, 6.0) for z in (0.0, 40.0)]
    rbe2_by_scenario["C03"] = spatial
    scenarios.append({
        "case_id": "C03", "component_id": 103, "name": "B3_SPATIAL_RIGIDS",
        "rbe2_ids": [r.element_id for r in spatial],
        "center_xy": [3000.0, 0.0], "ring_z": [0.0, 40.0], "spread_half": 6.0,
    })

    # ---- C04 10 mm transverse offset (> offsetTol 5) ------------------------
    c04 = model.add_component(104, "B4_OFFSET_10MM", 6)
    a = add_planar_ring(model, 104, "C04", (3500.0, 0.0), 0.0, 8.0)
    b = add_planar_ring(model, 104, "C04", (3510.0, 0.0), 20.0, 8.0)
    rbe2_by_scenario["C04"] = [a, b]
    scenarios.append({
        "case_id": "C04", "component_id": 104, "name": "B4_OFFSET_10MM",
        "rbe2_ids": [a.element_id, b.element_id],
        "center_xy": [[3500.0, 0.0], [3510.0, 0.0]], "ring_z": [0.0, 20.0],
        "transverse_offset": 10.0, "ring_radius": 8.0,
    })

    # ---- C05 single isolated planar RBE2 ------------------------------------
    c05 = model.add_component(105, "B5_SINGLE_RBE2", 7)
    solo = add_planar_ring(model, 105, "C05", (4000.0, 0.0), 0.0, 8.0)
    rbe2_by_scenario["C05"] = [solo]
    scenarios.append({
        "case_id": "C05", "component_id": 105, "name": "B5_SINGLE_RBE2",
        "rbe2_ids": [solo.element_id], "center_xy": [4000.0, 0.0],
        "ring_z": [0.0], "ring_radius": 8.0,
    })

    # ---- C06 offsetTol boundary: 5.0 (match) vs 5.1 (no match) --------------
    c06 = model.add_component(106, "B6_OFFSET_TOL_EDGE", 8)
    ok_a = add_planar_ring(model, 106, "C06", (4500.0, 0.0), 0.0, 8.0)
    ok_b = add_planar_ring(model, 106, "C06", (4505.0, 0.0), 20.0, 8.0)
    no_a = add_planar_ring(model, 106, "C06", (4800.0, 0.0), 0.0, 8.0)
    no_b = add_planar_ring(model, 106, "C06", (4805.1, 0.0), 20.0, 8.0)
    rbe2_by_scenario["C06"] = [ok_a, ok_b, no_a, no_b]
    scenarios.append({
        "case_id": "C06", "component_id": 106, "name": "B6_OFFSET_TOL_EDGE",
        "rbe2_ids": [r.element_id for r in (ok_a, ok_b, no_a, no_b)],
        "match_stack": {"center_xy": [[4500.0, 0.0], [4505.0, 0.0]], "ring_z": [0.0, 20.0],
                        "transverse_offset": 5.0, "ring_radius": 8.0},
        "reject_stack": {"center_xy": [[4800.0, 0.0], [4805.1, 0.0]], "ring_z": [0.0, 20.0],
                         "transverse_offset": 5.1, "ring_radius": 8.0},
    })

    model.scenarios = scenarios
    return model, scenarios, rbe2_by_scenario


def validate(model, scenarios) -> Dict[str, object]:
    errors: List[str] = []
    for element in model.elements.values():
        if element.card != "RBE2" or len(element.node_ids) < 3:
            errors.append("malformed {} {}".format(element.card, element.element_id))
        if len(set(element.node_ids)) != len(element.node_ids):
            errors.append("duplicate node on {} {}".format(element.card, element.element_id))
        for node_id in element.node_ids:
            if node_id not in model.nodes:
                errors.append("{} references missing node {}".format(element.element_id, node_id))

    # Cross-scenario isolation: no pair of RBE2 from different scenarios may
    # group (offset > gapTol in the transverse plane or axial gap outside range).
    records = model.rbe2
    for i, r in enumerate(records):
        for j in range(i + 1, len(records)):
            s, t = records[i], records[j]
            if s.scenario == t.scenario:
                continue
            for axis in "XYZ":
                a = AXIS[axis]
                cross = [k for k in range(3) if k != a]
                gap = abs(s.center[a] - t.center[a])
                offset = max(abs(s.center[k] - t.center[k]) for k in cross)
                if SETTINGS["minBeamLength"] < gap <= SETTINGS["gapTol"] and offset <= SETTINGS["offsetTol"]:
                    errors.append(
                        "cross-scenario group risk {} ({} axis): gap={} offset={}".format(
                            s.scenario, t.scenario, axis, round(gap, 3), round(offset, 3)))

    for scenario in scenarios:
        ids = scenario["rbe2_ids"]
        if len(ids) != len(set(ids)):
            errors.append("scenario {} duplicate rbe2 ids".format(scenario["case_id"]))
        for element_id in ids:
            if element_id not in model.elements:
                errors.append("scenario {} missing rbe2 {}".format(scenario["case_id"], element_id))
        # every scenario owns at least one RBE2 (so component blocks are non-empty)
        component = model.components[scenario["component_id"]]
        if not component.element_ids:
            errors.append("component {} has no elements".format(scenario["component_id"]))

    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors))
    return {
        "component_count": len(model.components),
        "node_count": len(model.nodes),
        "element_count": len(model.elements),
        "rbe2_count": len(model.rbe2),
    }


AXIS = {"X": 0, "Y": 1, "Z": 2}


def write_fem(model, output) -> None:
    lines = [
        "$ RIGIDS bolt-connector validation model (BoltConnector_Validation)",
        "$ GRID + RBE2 only; rbe2_bolt_connector reads exactly these cards.",
        "$ Units: mm. Not a production solve deck.",
        "$ Generated by examples/BoltConnector_Validation/generate_fem.py",
        "BEGIN BULK",
        "$ COMPONENTS",
    ]
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend((
            '$HMNAME COMP {} "{}"'.format(component.component_id, component.name),
            "$HWCOLOR COMP {} {}".format(component.component_id, component.color),
        ))
    lines.append("$ NODES")
    for node_id, point in sorted(model.nodes.items()):
        lines.append("GRID,{},,{:.9g},{:.9g},{:.9g}".format(node_id, *point))
    lines.append("$ RBE2 GROUPED BY HYPERMESH COMPONENT")
    for component in sorted(model.components.values(), key=lambda item: item.component_id):
        lines.extend(("$HMCOMP ID {}".format(component.component_id), "$ " + component.name))
        for element_id in component.element_ids:
            element = model.elements[element_id]
            fields = [element.card, str(element.element_id), str(element.node_ids[0]), "123456"] + \
                [str(n) for n in element.node_ids[1:]]
            lines.append(",".join(fields))
    lines.extend(("ENDDATA", ""))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def validate_written_fem(output, stats) -> None:
    lines = output.read_text(encoding="utf-8").splitlines()
    if "BEGIN BULK" not in lines or lines[-1] != "ENDDATA":
        raise ValueError("FEM is missing BEGIN BULK or terminal ENDDATA")
    if sum(line.startswith("GRID,") for line in lines) != stats["node_count"]:
        raise ValueError("written GRID count mismatch")
    if sum(line.startswith("RBE2,") for line in lines) != stats["rbe2_count"]:
        raise ValueError("written RBE2 count mismatch")


def manifest(model, scenarios, stats) -> Dict[str, object]:
    components = [
        {
            "component_id": component.component_id,
            "name": component.name,
            "element_count": len(component.element_ids),
        }
        for component in sorted(model.components.values(), key=lambda item: item.component_id)
    ]
    cases = []
    for scenario in scenarios:
        cases.append({
            "case_id": scenario["case_id"],
            "title": SCENARIO_TITLES[scenario["case_id"]],
            "component_ids": [scenario["component_id"]],
            "component_names": [scenario["name"]],
            "rbe2_ids": scenario["rbe2_ids"],
            "expected": SCENARIO_EXPECTED[scenario["case_id"]],
            "expected_results": SCENARIO_EXPECTED_RESULTS[scenario["case_id"]],
            "settings": SCENARIO_SETTINGS[scenario["case_id"]],
            "notes": SCENARIO_NOTES[scenario["case_id"]],
        })
    return {
        "schema_version": "1.0",
        "purpose": "RIGIDS bolt-connector acceptance/rejection matrix for rbe2_bolt_connector",
        "generator": "examples/BoltConnector_Validation/generate_fem.py",
        "fem": "BoltConnector_Validation.fem",
        "parameters": {
            "ring_dependents": RING_DEPENDENTS,
            "module_defaults": dict(SETTINGS),
            "note": "spacing 20 mm between adjacent planar rings within a stack",
        },
        "statistics": stats,
        "components": components,
        "cases": cases,
        "rbe2_records": [
            {
                "element_id": r.element_id,
                "scenario": r.scenario,
                "center_node_id": r.center_node_id,
                "center": list(r.center),
                "ring_radius": round(r.ring_radius, 6),
                "planar": r.planar,
                "normal_axis": r.normal_axis,
                "dependent_count": len(r.dependent_node_ids),
            }
            for r in sorted(model.rbe2, key=lambda item: item.element_id)
        ],
        "warning": "Validation deck only (GRID + RBE2); no loads/constraints. "
                   "The bolt module reads only RBE2 and GRID cards.",
    }


SCENARIO_TITLES = {
    "C01": "正常：同轴平面 RBE2 链（4 环 z=0/20/40/60，D16）→ 3 段 CBEAM 螺栓",
    "C02": "正常：多孔径同轴组（D12 组 + D20 组）→ BOLT_D12_CBEAM / BOLT_D20_CBEAM",
    "C03": "失败：空间型（非平面）同轴 RBE2 对 → 分组成功但 plan 拒绝 SPATIAL_ONLY",
    "C04": "失败：横向偏移 10mm（> offsetTol 5）的两平面 RBE2 → 不分组",
    "C05": "失败：孤立单一平面 RBE2 → 低于 minGroupSize 2 → 不分组",
    "C06": "边界：偏移恰为 5.0mm（匹配 → 1 段螺栓）与 5.1mm（不匹配 → 0 段）",
}

SCENARIO_EXPECTED = {
    "C01": "4 个同轴平面 RBE2（D16，Z 向 0/20/40/60）构成 1 个同轴组，组内相邻环各生成 1 段 CBEAM，共 3 段，轴向距离 20mm，组件 BOLT_D16_CBEAM",
    "C02": "两组同轴组：D12 组（3 环）与 D20 组（3 环），各生成 2 段 CBEAM 共 4 段；直径选取为组内平面环众数 12/20，组件 BOLT_D12_CBEAM 与 BOLT_D20_CBEAM",
    "C03": "2 个空间型 RBE2 可配对成组（非平面允许配对），但组内无平面环 → plan 拒绝 SPATIAL_ONLY，生成 0 段螺栓",
    "C04": "两平面 RBE2 横向偏移 10mm 超过 offsetTol 5 → Z 向与 X 向都不匹配 → 0 组 0 螺栓",
    "C05": "单平面 RBE2 与任何 RBE2 不构成满足 minGroupSize=2 的组 → 0 组 0 螺栓",
    "C06": "偏移 5.0mm 恰在容差内（<= 5.0）→ 匹配生成 1 段螺栓；偏移 5.1mm 超容差 → 不匹配，0 段",
}

SCENARIO_EXPECTED_RESULTS = {
    "C01": {"group_count": 1, "bolt_count": 3, "axial_distance": 20.0, "transverse_offset": 0.0,
            "diameter": 16, "component_name": "BOLT_D16_CBEAM", "rejected_plan_count": 0},
    "C02": {"group_count": 2, "bolt_count": 4, "axial_distance": 20.0,
            "diameters": [12, 20], "component_names": ["BOLT_D12_CBEAM", "BOLT_D20_CBEAM"],
            "rejected_plan_count": 0},
    "C03": {"group_count": 1, "bolt_count": 0, "rejected_plan_count": 1,
            "rejected_reason": "SPATIAL_ONLY"},
    "C04": {"group_count": 0, "bolt_count": 0, "rejected_plan_count": 0},
    "C05": {"group_count": 0, "bolt_count": 0, "rejected_plan_count": 0},
    "C06": {"group_count": 1, "bolt_count": 1, "transverse_offset_ok": 5.0,
            "transverse_offset_reject": 5.1, "rejected_plan_count": 0},
}

SCENARIO_SETTINGS = {
    "C01": {"axisMode": "AUTO", "gapTol": 100.0, "offsetTol": 5.0, "minGroupSize": 2,
            "minBeamLength": 0.001, "elemType": "CBEAM", "compPrefix": "BOLT"},
    "C02": {"axisMode": "AUTO", "gapTol": 100.0, "offsetTol": 5.0, "minGroupSize": 2,
            "minBeamLength": 0.001, "elemType": "CBEAM", "compPrefix": "BOLT"},
    "C03": {"axisMode": "AUTO", "gapTol": 100.0, "offsetTol": 5.0, "minGroupSize": 2,
            "minBeamLength": 0.001, "planeAbsTol": 0.5, "planeFlatRatio": 0.12,
            "note": "cube spread 12mm per axis: min range 12 > 0.5 and 12/12 > 0.12 -> non-planar"},
    "C04": {"axisMode": "AUTO", "gapTol": 100.0, "offsetTol": 5.0, "minGroupSize": 2,
            "note": "transverse offset 10 > offsetTol 5"},
    "C05": {"axisMode": "AUTO", "gapTol": 100.0, "offsetTol": 5.0, "minGroupSize": 2,
            "note": "single ring below minGroupSize 2"},
    "C06": {"axisMode": "AUTO", "gapTol": 100.0, "offsetTol": 5.0, "minGroupSize": 2,
            "note": "5.0 <= offsetTol accepted; 5.1 > offsetTol rejected"},
}

SCENARIO_NOTES = {
    "C01": "4 个平面环（XY 平面，法线 Z），中心 (0,0)，z=0/20/40/60，半径 8mm → D16。Z 向 gap 20mm 在 (0.001, 100] 内，横向偏移 0 ≤ 5。直径取平面环众数 16 → BOLT_D16_CBEAM。",
    "C02": "两组相互隔离（X 向 400mm > gapTol 100）：D12 组中心 (2000,0) 半径 6mm，D20 组中心 (2400,0) 半径 10mm，各 3 环 z=0/20/40。每组内部 Z 向匹配。直径 2*median(环半径)=D12/D20。",
    "C03": "两个 RBE2 依赖节点为 6mm 立方体 8 角点（范围 12mm/轴）。min 范围 12 > planeAbsTol 0.5 且 12/12=1.0 > planeFlatRatio 0.12 → 非平面。非平面配对在 allowed() 中放行（轴向 gap 40），组内无平面环 → plan 拒绝 SPATIAL_ONLY。",
    "C04": "两平面环中心 (3500,0,0) 与 (3510,0,20)：Z 向 gap 20 但在 X 向偏移 10 > 5 → 不匹配；X 向 gap 10 但在 Z 向偏移 20 > 5 → 不匹配。0 组 0 螺栓。",
    "C05": "单平面环中心 (4000,0,0)。与任何 RBE2 的轴向 gap（相对各轴）要么为 0（同轴）要么横向偏移超容差 → 无满足条件的配对，且组尺寸 < minGroupSize 2。",
    "C06": "匹配组：中心 (4500,0,0)/(4505,0,20)，X 向偏移恰为 5.0 ≤ offsetTol → 1 段螺栓，transverse_offset=5.0。拒绝组：中心 (4800,0,0)/(4805.1,0,20)，偏移 5.1 > 5.0 → 不匹配。两组 X 向间距 295/300mm > gapTol，互不干扰。",
}


def parse_args():
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=directory / "BoltConnector_Validation.fem")
    parser.add_argument("--manifest", type=Path, default=directory / "BoltConnector_Validation_manifest.json")
    parser.add_argument("--verify-module", action="store_true",
                        help="run the repository's rbe2_bolt_connector pipeline against the FEM "
                             "and assert the expected analyze/group/plan results")
    return parser.parse_args()


def verify_module(fem_path) -> Dict[str, object]:
    """Cross-check the generated deck against the real module pipeline."""
    here = Path(__file__).resolve().parent
    root = here.parents[1]
    common = root / "modules" / "hybrid_core" / "python"
    bolt = root / "modules" / "rbe2_bolt_connector" / "python"
    for directory in (str(common), str(bolt)):
        if directory not in sys.path:
            sys.path.insert(0, directory)
    from fem_io import read_fem  # noqa: E402
    from grouping import build as build_groups  # noqa: E402
    from pair_planner import plan as plan_bolts  # noqa: E402
    from rbe2_analyzer import analyze as analyze_rbe2  # noqa: E402
    from schema import DEFAULTS  # noqa: E402

    settings = dict(DEFAULTS)
    snapshot = read_fem(Path(fem_path))
    records, rejected_rbe2 = analyze_rbe2(snapshot.model, settings)
    groups = build_groups(records, settings)
    bolts, rejected_plans = plan_bolts(groups, settings)
    diameters = sorted({b["diameter"] for b in bolts})
    component_names = sorted({b["component_name"] for b in bolts})
    result = {
        "analyzed_rbe2": len(records),
        "rejected_rbe2": len(rejected_rbe2),
        "coaxial_groups": len(groups),
        "planned_bolts": len(bolts),
        "rejected_plans": len(rejected_plans),
        "rejected_plan_reasons": sorted({r["reason"] for r in rejected_plans}),
        "bolt_lengths": sorted({round(b["axial_distance"], 6) for b in bolts}),
        "diameters": diameters,
        "component_names": component_names,
        "per_scenario_bolts": {},
    }
    for b in bolts:
        result["per_scenario_bolts"].setdefault(b["candidate_id"], b["component_name"])
    expected = {
        "analyzed_rbe2": 19, "rejected_rbe2": 0, "coaxial_groups": 5,
        "planned_bolts": 8, "rejected_plans": 1,
        "rejected_plan_reasons": ["SPATIAL_ONLY"],
        "bolt_lengths": [20.0], "diameters": [12, 16, 20],
        "component_names": ["BOLT_D12_CBEAM", "BOLT_D16_CBEAM", "BOLT_D20_CBEAM"],
    }
    for key, value in expected.items():
        if result[key] != value:
            raise ValueError("module cross-check mismatch for {}: {} != {}".format(key, result[key], value))
    result["cross_check_passed"] = True
    return result


def main():
    args = parse_args()
    model, scenarios, _ = build_model()
    stats = validate(model, scenarios)
    write_fem(model, args.output.resolve())
    validate_written_fem(args.output.resolve(), stats)
    args.manifest.resolve().write_text(
        json.dumps(manifest(model, scenarios, stats), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    report = {"fem": str(args.output.resolve()), "manifest": str(args.manifest.resolve()), **stats}
    if args.verify_module:
        report["module_cross_check"] = verify_module(args.output.resolve())
    print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
