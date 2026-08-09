#!/usr/bin/env python3
"""Generate the Mesh Weld Integrity Check validation OptiStruct shell FEM.

Command (run from the repository root, portable Python 3.8):

    runtime/python/windows-x64/python.exe examples/WeldIntegrityCheck_Validation/generate_fem.py

Only the Python standard library is required.  The generator is deterministic
(regular grids, no randomness) and runs a full self-check before writing
anything: it re-implements the module's candidate detection (free edges ->
nearest-node spatial hash within max_search_distance -> continuous-region
extraction -> pair dedup) and asserts that exactly the designed pair set is
produced under the recommended settings.  With --verify-detector it also loads
the repository's own hybrid_core/shell_weld_detection.py and cross-checks the
pair set against it.

Model layout (mm, mesh 5.0):

    C01  T-junction gap    101 horizontal base + 102 vertical flange, flange
         free bottom edge 0.5 mm above the base top -> 1 candidate pair
    C02  lap-joint gap     103 bottom + 104 top overlapping 0.2 mm apart ->
         1 candidate pair
    C03  near free edges   105 + 106 edge-to-edge, 4.5 mm gap -> 1 pair
    C03b near free edges 8mm 107 + 108 edge-to-edge, 8.0 mm gap -> 1 pair when
         max_search_distance >= 8.0 (module default is 5.0)
    C04  already welded    109 base + SEAM_T1 strip 110 + 111 flange; strip
         shares node lines with both plates -> no candidate
    C05  far apart         112 + 113, 40 mm gap -> no candidate
    C06  shared one-piece  114 + 115 continuous grid sharing the junction
         node line -> no candidate
    C07  pair matrix       116 hub near 117/118/119 (left/right/top) -> 3 pairs

This model is a mesh-integrity review input only: no loads/boundary conditions,
not for production solving.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import defaultdict, deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

Point = Tuple[float, float, float]

# ---------------------------------------------------------------------------
# Stdlib-only detection mirror used for the generator self-check.
# ---------------------------------------------------------------------------


def _distance(a: Point, b: Point) -> float:
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def _canonical(first: int, second: int) -> Tuple[int, int]:
    return (first, second) if first < second else (second, first)


class _SpatialHash:
    def __init__(self, nodes: Dict[int, Point], node_ids: Iterable[int], cell: float):
        self.nodes = nodes
        self.cell = max(float(cell), 1.0e-12)
        self.cells: Dict[Tuple[int, int, int], List[int]] = defaultdict(list)
        for node_id in sorted(node_ids):
            self.cells[self._key(nodes[node_id])].append(node_id)

    def _key(self, point: Point) -> Tuple[int, int, int]:
        return tuple(int(math.floor(value / self.cell)) for value in point)

    def nearest(self, point: Point, maximum: float) -> Tuple[float, int]:
        base = self._key(point)
        radius = max(1, int(math.ceil(maximum / self.cell)))
        best, best_id = float("inf"), 0
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                for dz in range(-radius, radius + 1):
                    for node_id in self.cells.get((base[0] + dx, base[1] + dy, base[2] + dz), ()):
                        value = _distance(point, self.nodes[node_id])
                        if value < best or (value == best and node_id < best_id):
                            best, best_id = value, node_id
        return best, best_id


def _simulate_detection(
    components: Sequence[Dict[str, object]],
    nodes: Dict[int, Point],
    elements: Sequence[Dict[str, object]],
    max_search_distance: float,
    min_contact_length: float,
    min_continuous_nodes: int,
    ignore_shared_nodes: bool = True,
) -> Dict[str, object]:
    """Mirror of hybrid_core/shell_weld_detection.detect (authoritative pair set)."""
    by_component: Dict[int, List[dict]] = defaultdict(list)
    for element in elements:
        if len(element["node_ids"]) in (3, 4):
            by_component[element["component_id"]].append(element)

    topologies: Dict[int, Dict[str, object]] = {}
    for component in components:
        component_id = int(component["id"])
        incidence: Dict[Tuple[int, int], int] = defaultdict(int)
        node_ids: Set[int] = set()
        node_elements: Dict[int, Set[int]] = defaultdict(set)
        for element in by_component[component_id]:
            element_id = int(element["element_id"])
            element_nodes = element["node_ids"]
            node_ids.update(element_nodes)
            for node_id in element_nodes:
                node_elements[node_id].add(element_id)
            for index, first in enumerate(element_nodes):
                incidence[_canonical(first, element_nodes[(index + 1) % len(element_nodes)])] += 1
        free_edges = [edge for edge, count in incidence.items() if count == 1]
        topologies[component_id] = {"node_ids": node_ids, "free_edges": free_edges, "node_elements": node_elements}

    def pair_regions(first_id: int, second_id: int) -> List[dict]:
        first, second = topologies[first_id], topologies[second_id]
        if ignore_shared_nodes and len(first["node_ids"] & second["node_ids"]) >= min_continuous_nodes:
            return []
        regions: List[dict] = []
        for source, target in ((first, second), (second, first)):
            index = _SpatialHash(nodes, target["node_ids"], max_search_distance)
            nearest: Dict[int, Tuple[float, int]] = {}
            qualified: List[Tuple[int, int]] = []
            for n1, n2 in source["free_edges"]:
                if n1 not in nearest:
                    nearest[n1] = index.nearest(nodes[n1], max_search_distance)
                if n2 not in nearest:
                    nearest[n2] = index.nearest(nodes[n2], max_search_distance)
                if nearest[n1][0] <= max_search_distance and nearest[n2][0] <= max_search_distance:
                    qualified.append((n1, n2))
            by_node: Dict[int, List[int]] = defaultdict(list)
            for row_index, (n1, n2) in enumerate(qualified):
                by_node[n1].append(row_index)
                by_node[n2].append(row_index)
            remaining = set(range(len(qualified)))
            while remaining:
                seed = min(remaining)
                remaining.remove(seed)
                group = [seed]
                queue = deque([seed])
                while queue:
                    current = qualified[queue.popleft()]
                    for node_id in (current[0], current[1]):
                        for neighbor in by_node[node_id]:
                            if neighbor in remaining:
                                remaining.remove(neighbor)
                                group.append(neighbor)
                                queue.append(neighbor)
                rows = [qualified[index] for index in group]
                source_nodes = {node for row in rows for node in row}
                length = sum(_distance(nodes[row[0]], nodes[row[1]]) for row in rows)
                if len(source_nodes) < min_continuous_nodes or length < min_contact_length:
                    continue
                regions.append({"source_nodes": source_nodes, "length": length})
        # Merge regions seen from both directions (by signature) and any regions
        # whose centres are within max_search_distance of each other.
        merged: List[dict] = []
        for region in sorted(regions, key=lambda row: (-row["length"], min(row["source_nodes"]))):
            centre = tuple(sum(nodes[node][axis] for node in region["source_nodes"]) / len(region["source_nodes"])
                           for axis in range(3))
            if any(_distance(centre, existing) <= max_search_distance for existing in merged):
                continue
            merged.append(centre)
        return merged

    pairs: List[Dict[str, object]] = []
    ordered = sorted(components, key=lambda row: int(row["id"]))
    for index, first in enumerate(ordered):
        for second in ordered[index + 1:]:
            first_id, second_id = int(first["id"]), int(second["id"])
            regions = pair_regions(first_id, second_id)
            if regions:
                pairs.append({
                    "pair_id": "PAIR_{:06d}".format(len(pairs) + 1),
                    "component_a": {"id": first_id},
                    "component_b": {"id": second_id},
                    "candidate_region_count": len(regions),
                })
    return {"candidate_pair_count": len(pairs), "pairs": pairs}


# ---------------------------------------------------------------------------
# Model container (tracks element -> component ownership).
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Element:
    card: str
    element_id: int
    property_id: int
    component_id: int
    nodes: Tuple[int, ...]


@dataclass
class Model:
    nodes: Dict[int, Point] = field(default_factory=dict)
    elements: Dict[int, Element] = field(default_factory=dict)
    components: Dict[int, Dict[str, object]] = field(default_factory=dict)
    next_node_id: int = 1
    next_element_id: int = 1

    def add_node(self, point: Point) -> int:
        node_id = self.next_node_id
        self.next_node_id += 1
        self.nodes[node_id] = point
        return node_id

    def add_component(self, component_id: int, name: str) -> None:
        if component_id in self.components:
            raise ValueError("duplicate component {}".format(component_id))
        self.components[component_id] = {"id": component_id, "name": name}

    def add_element(self, card: str, property_id: int, component_id: int, nodes: Sequence[int]) -> int:
        element_id = self.next_element_id
        self.next_element_id += 1
        self.elements[element_id] = Element(card, element_id, property_id, component_id, tuple(nodes))
        return element_id


# ---------------------------------------------------------------------------
# Plate builders.
# ---------------------------------------------------------------------------


def _add_flat_plate(
    model: Model,
    component_id: int,
    property_id: int,
    x0: float,
    y0: float,
    z0: float,
    nx: int,
    ny: int,
    spacing: float,
    name: str,
) -> List[List[int]]:
    """Flat nx x ny CQUAD4 grid; returns the 2-D node grid [j][i]."""
    model.add_component(component_id, name)
    grid: List[List[int]] = []
    for j in range(ny + 1):
        row = [model.add_node((x0 + i * spacing, y0 + j * spacing, z0)) for i in range(nx + 1)]
        grid.append(row)
    for j in range(ny):
        for i in range(nx):
            model.add_element(
                "CQUAD4", property_id, component_id,
                (grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]),
            )
    return grid


def _add_vertical_xz_plate(
    model: Model,
    component_id: int,
    property_id: int,
    x0: float,
    y_plane: float,
    z0: float,
    nx: int,
    nz: int,
    spacing: float,
    name: str,
) -> None:
    """Plate standing in the x-z plane at a fixed y; free bottom edge at z0."""
    model.add_component(component_id, name)
    grid: List[List[int]] = []
    for k in range(nz + 1):
        row = [model.add_node((x0 + i * spacing, y_plane, z0 + k * spacing)) for i in range(nx + 1)]
        grid.append(row)
    for k in range(nz):
        for i in range(nx):
            model.add_element(
                "CQUAD4", property_id, component_id,
                (grid[k][i], grid[k][i + 1], grid[k + 1][i + 1], grid[k + 1][i]),
            )


# ---------------------------------------------------------------------------
# Scenario builders.
# ---------------------------------------------------------------------------

SPACING = 5.0


def build_t_junction_gap(model: Model) -> None:
    """C01: horizontal base 101 + vertical flange 102 whose free bottom edge sits
    0.5 mm above the base top -> one candidate pair (101,102)."""
    _add_flat_plate(model, 101, 1, 0.0, 0.0, 0.0, 60, 30, SPACING, "C01_TJ_BASE")
    _add_vertical_xz_plate(model, 102, 1, 0.0, 30 * SPACING, 0.5, 60, 8, SPACING, "C01_TJ_FLANGE")


def build_lap_gap(model: Model) -> None:
    """C02: bottom 103 + top 104 at z=0.2, top fully inside the bottom footprint
    (>=25 mm margins) -> top perimeter is the candidate region for pair (103,104)."""
    _add_flat_plate(model, 103, 1, 350.0, 0.0, 0.0, 60, 30, SPACING, "C02_LAP_BOTTOM")
    _add_flat_plate(model, 104, 1, 425.0, 25.0, 0.2, 30, 20, SPACING, "C02_LAP_TOP")


def build_near_edges(model: Model) -> None:
    """C03: edge-to-edge gap 4.5 mm -> candidate pair (105,106)."""
    _add_flat_plate(model, 105, 1, 700.0, 0.0, 0.0, 30, 20, SPACING, "C03_NEAR_LEFT")
    _add_flat_plate(model, 106, 1, 854.5, 0.0, 0.0, 30, 20, SPACING, "C03_NEAR_RIGHT")


def build_near_edges_8mm(model: Model) -> None:
    """C03b: edge-to-edge gap 8.0 mm.  Detected only when max_search_distance >= 8."""
    _add_flat_plate(model, 107, 1, 1060.0, 0.0, 0.0, 30, 20, SPACING, "C03B_NEAR8_LEFT")
    _add_flat_plate(model, 108, 1, 1218.0, 0.0, 0.0, 30, 20, SPACING, "C03B_NEAR8_RIGHT")


def _add_vertical_yz_wall(
    model: Model,
    component_id: int,
    property_id: int,
    x_plane: float,
    y0: float,
    z0: float,
    ny: int,
    nz: int,
    spacing: float,
    name: str,
    bottom_shared_row: Optional[List[int]] = None,
) -> Tuple[List[List[int]], List[int]]:
    """Wall standing in the y-z plane at fixed x.  When ``bottom_shared_row`` is
    given, the lowest z-row reuses those node IDs (a welded node line)."""
    model.add_component(component_id, name)
    grid: List[List[int]] = []
    for k in range(nz + 1):
        row: List[int] = []
        for j in range(ny + 1):
            if k == 0 and bottom_shared_row is not None:
                row.append(bottom_shared_row[j])
            else:
                row.append(model.add_node((x_plane, y0 + j * spacing, z0 + k * spacing)))
        grid.append(row)
    for k in range(nz):
        for j in range(ny):
            model.add_element(
                "CQUAD4", property_id, component_id,
                (grid[k][j], grid[k][j + 1], grid[k + 1][j + 1], grid[k + 1][j]),
            )
    return grid, grid[-1]  # top row (shared with the next part when welding)


def build_welded_t(model: Model) -> None:
    """C04: base 109 + SEAM_T1 strip 110 + flange 111.

    The strip is a vertical wall at x=750 whose bottom row is the base's x=750
    node line (shared), and the flange is a vertical wall at x=750 whose bottom
    row is the strip's top row (shared).  Every component pair touching the seam
    shares >=3 nodes and is skipped by ignore_shared_nodes; the two plates' free
    edges are >=20 mm apart -> no candidate pair for this already-welded joint."""
    base = _add_flat_plate(model, 109, 1, 1430.0, 0.0, 0.0, 30, 20, SPACING, "C04_SEAM_BASE")
    base_top_row = [base[j][9] for j in range(20 + 1)]  # x=1475 node line
    _, strip_top = _add_vertical_yz_wall(
        model, 110, 2, 1475.0, 0.0, 0.0, 20, 4, SPACING, "C04_SEAM_T1",
        bottom_shared_row=base_top_row,
    )
    _add_vertical_yz_wall(
        model, 111, 1, 1475.0, 0.0, 20.0, 20, 4, SPACING, "C04_SEAM_FLANGE",
        bottom_shared_row=strip_top,
    )


def build_far(model: Model) -> None:
    """C05: 40 mm gap -> no candidate pair (112,113)."""
    _add_flat_plate(model, 112, 1, 1640.0, 0.0, 0.0, 30, 20, SPACING, "C05_FAR_LEFT")
    _add_flat_plate(model, 113, 1, 1830.0, 0.0, 0.0, 30, 20, SPACING, "C05_FAR_RIGHT")


def build_shared_one_piece(model: Model) -> None:
    """C06: two components meshed as one continuous grid sharing the junction
    node line -> ignore_shared_nodes skips the pair (114,115)."""
    left = _add_flat_plate(model, 114, 1, 2040.0, 0.0, 0.0, 40, 20, SPACING, "C06_ONEPIECE_A")
    right_shared = [left[j][40] for j in range(20 + 1)]  # x=2240 shared line
    model.add_component(115, "C06_ONEPIECE_B")
    grid: List[List[int]] = []
    for j in range(20 + 1):
        row = [right_shared[j]]  # x=2240 shared with A
        for i in range(1, 41):
            row.append(model.add_node((2240.0 + i * SPACING, j * SPACING, 0.0)))
        grid.append(row)
    for j in range(20):
        for i in range(40):
            model.add_element(
                "CQUAD4", 1, 115,
                (grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]),
            )


def build_pair_matrix(model: Model) -> None:
    """C07: hub 116 near left 117, right 118 and top 119 neighbours -> 3 pairs."""
    _add_flat_plate(model, 116, 1, 2500.0, 0.0, 0.0, 30, 20, SPACING, "C07_HUB")
    _add_flat_plate(model, 117, 1, 2456.0, 0.0, 0.0, 8, 16, SPACING, "C07_NEIGHBOR_LEFT")
    _add_flat_plate(model, 118, 1, 2654.0, 0.0, 0.0, 8, 16, SPACING, "C07_NEIGHBOR_RIGHT")
    _add_flat_plate(model, 119, 1, 2500.0, 112.0, 0.0, 30, 16, SPACING, "C07_NEIGHBOR_TOP")


# ---------------------------------------------------------------------------
# Writers.
# ---------------------------------------------------------------------------


def write_fem(model: Model, output: Path) -> None:
    lines = [
        "$ Generated by examples/WeldIntegrityCheck_Validation/generate_fem.py",
        "$ Mesh-integrity review input only; not for production solving.",
        "BEGIN BULK",
        '$HMNAME MAT 1 "STEEL_TEST"',
        "MAT1,1,210000.0,,0.3,7.85E-9",
        '$HMNAME PROP 1 "REVIEW_PLATES"',
        "PSHELL,1,1,1.0",
        '$HMNAME PROP 2 "SEAM_T1_STRIP"',
        "PSHELL,2,1,1.2",
    ]
    for component_id, component in sorted(model.components.items()):
        lines.append('$HMNAME COMP {} "{}"'.format(component_id, component["name"]))
        lines.append("$HWCOLOR COMP {} {}".format(component_id, (component_id * 3) % 15 + 1))
    lines.append("$ NODES")
    for node_id, (x, y, z) in sorted(model.nodes.items()):
        lines.append("GRID,{},{},{:.9g},{:.9g},{:.9g}".format(node_id, "", x, y, z))
    lines.append("$ SHELL ELEMENTS (grouped by component)")
    current_component = -1
    for element in sorted(model.elements.values(), key=lambda value: (value.component_id, value.element_id)):
        if element.component_id != current_component:
            current_component = element.component_id
            lines.append("$HMCOMP ID {}".format(current_component))
        lines.append(",".join(
            [element.card, str(element.element_id), str(element.property_id)]
            + [str(node) for node in element.nodes]
        ))
    lines.extend(("ENDDATA", ""))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


# ---------------------------------------------------------------------------
# Cases and manifest.
# ---------------------------------------------------------------------------

_CASES: Dict[str, Dict[str, object]] = {
    "C01": {
        "title": "正常：T 型漏焊区（垂直法兰自由底边距水平底板顶面 0.5 mm）",
        "components": [101, 102],
        "expected_pairs": [(101, 102)],
        "notes": "法兰底边整条自由边贴近底板顶面，整条为候选区；提示此处可能漏焊。",
    },
    "C02": {
        "title": "正常：搭接漏焊区（上层板完全叠在下层板上方 0.2 mm）",
        "components": [103, 104],
        "expected_pairs": [(103, 104)],
        "notes": "上层板周界整圈为候选区，下层板四周边缘离上层板 >=15 mm 不产生额外候选。",
    },
    "C03": {
        "title": "正常：邻近自由边（间距 4.5 mm）",
        "components": [105, 106],
        "expected_pairs": [(105, 106)],
        "notes": "默认 max_search_distance=5.0 即可检出。",
    },
    "C03b": {
        "title": "正常：邻近自由边（间距 8 mm，需 max_search_distance>=8）",
        "components": [107, 108],
        "expected_pairs": [(107, 108)],
        "notes": "默认 5.0 检不出；把最大搜索距离调到 8 以上后检出，用于演示距离阈值。",
    },
    "C04": {
        "title": "失败/应排除：已焊接区（SEAM_T1 壳带共节点覆盖）",
        "components": [109, 110, 111],
        "expected_pairs": [],
        "notes": "SEAM 带与两板各共享整条节点线（>=3 节点），ignore_shared_nodes 跳过；两板自由边相距 >=20 mm 无候选。",
    },
    "C05": {
        "title": "失败/应排除：远距（自由边间距 40 mm）",
        "components": [112, 113],
        "expected_pairs": [],
        "notes": "40 mm > max_search_distance，AABB 粗筛即排除，不产生候选。",
    },
    "C06": {
        "title": "边界：共节点一体区（两组件网格连续共享交界节点线）",
        "components": [114, 115],
        "expected_pairs": [],
        "notes": "两组件共享 >=3 个节点，ignore_shared_nodes 跳过；无自由边交邻。",
    },
    "C07": {
        "title": "正常：多组件对矩阵（一个 hub 同时邻近 3 个组件）",
        "components": [116, 117, 118, 119],
        "expected_pairs": [(116, 117), (116, 118), (116, 119)],
        "notes": "3 个 Pair 各自独立汇总候选区与长度；邻居之间相距 >=16 mm 不互相产生候选。",
    },
}


def build_manifest(model: Model, stats: Dict[str, object], recommended: Dict[str, object],
                   simulated: Dict[str, object]) -> Dict[str, object]:
    return {
        "schema_version": "1.0",
        "purpose": "网格焊缝完整性检查（Weld Integrity Check）验证模型：模拟主要网格已完成但可能漏焊的装配壳模型，覆盖 T 型/搭接/邻近自由边漏焊候选、已焊接排除、远距排除、共节点排除与多组件对矩阵",
        "generator": "examples/WeldIntegrityCheck_Validation/generate_fem.py",
        "fem": "examples/WeldIntegrityCheck_Validation/WeldIntegrityCheck_Validation.fem",
        "parameters": {"spacing": SPACING},
        "statistics": stats,
        "components": {str(component_id): component["name"] for component_id, component in sorted(model.components.items())},
        "recommended_settings": recommended,
        "cases": [
            {
                "case_id": case_id,
                "title": case["title"],
                "component_ids": list(case["components"]),
                "component_names": [model.components[component_id]["name"] for component_id in case["components"]],
                "expected": "候选 Pair {} 个：{}".format(
                    len(case["expected_pairs"]),
                    "、".join(str(item) for item in case["expected_pairs"]) if case["expected_pairs"] else "无",
                ),
                "expected_results": {
                    "candidate_pair_count": len(case["expected_pairs"]),
                    "candidate_pairs": [list(item) for item in case["expected_pairs"]],
                },
                "settings": dict(recommended),
                "notes": case["notes"],
            }
            for case_id, case in sorted(_CASES.items())
        ],
        "simulation": simulated,
        "warning": "该模型仅用于识别/流程验证，不含求解边界条件，不用于生产求解。",
    }


# ---------------------------------------------------------------------------
# Self-check and main.
# ---------------------------------------------------------------------------


def _run_self_check(model: Model, recommended: Dict[str, object]) -> Dict[str, object]:
    components = [
        {"id": component_id, "name": component["name"]}
        for component_id, component in sorted(model.components.items())
    ]
    elements = [
        {
            "element_id": element.element_id,
            "component_id": element.component_id,
            "element_type": element.card,
            "node_ids": list(element.nodes),
        }
        for element in model.elements.values()
    ]
    result = _simulate_detection(
        components, model.nodes, elements,
        recommended["max_search_distance"],
        recommended["min_contact_length"],
        recommended["min_continuous_nodes"],
        recommended["ignore_shared_nodes"],
    )
    pair_keys = {
        tuple(sorted((pair["component_a"]["id"], pair["component_b"]["id"])))
        for pair in result["pairs"]
    }
    expected: Set[Tuple[int, int]] = set()
    for case in _CASES.values():
        expected.update(tuple(sorted(item)) for item in case["expected_pairs"])
    unexpected = pair_keys - expected
    if unexpected:
        raise ValueError("self-check found unexpected candidate pairs: {}".format(sorted(unexpected)))
    missing = expected - pair_keys
    if missing:
        raise ValueError("self-check missed expected candidate pairs: {}".format(sorted(missing)))
    return result


def _verify_repository_detector(model: Model, recommended: Dict[str, object]) -> Dict[str, object]:
    """Cross-check the pair set with the repository's own shell_weld_detection."""
    root = Path(__file__).resolve().parents[2]
    common = root / "modules" / "hybrid_core" / "python"
    if not common.is_dir():
        raise FileNotFoundError("hybrid_core python dir not found: {}".format(common))
    if str(common) not in sys.path:
        sys.path.insert(0, str(common))
    from shell_weld_detection import detect  # noqa: E402

    components = [
        {"id": component_id, "name": component["name"]}
        for component_id, component in sorted(model.components.items())
    ]
    elements = [
        {
            "element_id": element.element_id,
            "component_id": element.component_id,
            "element_type": element.card,
            "node_ids": list(element.nodes),
        }
        for element in model.elements.values()
    ]
    result = detect(components, model.nodes, elements, dict(recommended))
    pairs = {
        tuple(sorted((pair["component_a"]["id"], pair["component_b"]["id"])))
        for pair in result["pairs"]
    }
    expected = set()
    for case in _CASES.values():
        expected.update(tuple(sorted(item)) for item in case["expected_pairs"])
    return {
        "candidate_pair_count": result["summary"]["candidate_pair_count"],
        "candidate_region_count": result["summary"]["candidate_region_count"],
        "pairs": sorted(list(pairs)),
        "expected_pairs": sorted(list(expected)),
        "verified": pairs == expected,
    }


def validate_written_fem(output: Path, stats: Dict[str, object]) -> None:
    text = output.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or "BEGIN BULK" not in lines or lines[-1] != "ENDDATA":
        raise ValueError("written FEM is missing BEGIN BULK or terminal ENDDATA")
    counts = {
        "nodes": sum(line.startswith("GRID,") for line in lines),
        "quad_elements": sum(line.startswith("CQUAD4,") for line in lines),
    }
    for key, actual in counts.items():
        if actual != int(stats[key]):
            raise ValueError("written FEM {} count {} does not match {}".format(key, actual, stats[key]))
    oversized = [
        (index, line) for index, line in enumerate(lines, 1)
        if line and not line.startswith("$") and len(line.split(",")) > 9
    ]
    if oversized:
        raise ValueError("free-format card exceeds nine fields at line {}: {}".format(*oversized[0]))


def parse_arguments() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=script_dir / "WeldIntegrityCheck_Validation.fem")
    parser.add_argument("--manifest", type=Path, default=script_dir / "WeldIntegrityCheck_Validation_manifest.json")
    parser.add_argument("--verify-detector", action="store_true",
                        help="also run the repository hybrid_core shell_weld_detection against the model")
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    model = Model()
    build_t_junction_gap(model)
    build_lap_gap(model)
    build_near_edges(model)
    build_near_edges_8mm(model)
    build_welded_t(model)
    build_far(model)
    build_shared_one_piece(model)
    build_pair_matrix(model)

    recommended = {
        "max_search_distance": 12.0,
        "min_contact_length": 20.0,
        "min_continuous_nodes": 3,
        "prefer_free_edges": True,
        "ignore_shared_nodes": True,
        "note": "C03b（8 mm 间距）需要 max_search_distance>=8；模块默认 5.0 时该对不出现。",
    }

    stats = {
        "nodes": len(model.nodes),
        "elements": len(model.elements),
        "quad_elements": sum(element.card == "CQUAD4" for element in model.elements.values()),
        "components": len(model.components),
    }
    simulated = _run_self_check(model, recommended)
    if args.verify_detector:
        simulated["repository_detector"] = _verify_repository_detector(model, recommended)

    write_fem(model, args.output.resolve())
    validate_written_fem(args.output.resolve(), stats)
    manifest = build_manifest(model, stats, recommended, simulated)
    args.manifest.resolve().write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "fem": str(args.output.resolve()),
        "manifest": str(args.manifest.resolve()),
        **stats,
        "simulated_pairs": simulated["candidate_pair_count"],
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
