#!/usr/bin/env python3
"""Generate a deterministic shell FEM for the FEM Automatic Seam module.

Ten isolated scenarios (separated along global X) cover every candidate
classification of the FEM-level automatic seam detector:

  F01 straight T seam      F06 patch with a small internal hole (review)
  F02 angled T seam (45d)  F07 nearby free edges (review)
  F03 curved T seam        F08 multi-target web (3 targets)
  F04 partial-overlap T    F09 negative control: far apart
  F05 parallel patch seam  F10 negative control: shared-node single mesh

Inside a scenario the source and target components never share nodes
(assembled-part semantics); F10 is the shared-node negative control. Only
the Python standard library is required (Python 3.8+).
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

Point = Tuple[float, float, float]
CASE_PITCH = 300.0
GAP = 3.0
SEARCH_DISTANCE = 12.0
MIN_SEAM_LENGTH = 20.0

EXPECTED_RESULTS = {
    "F01": {"candidate_count": 1, "auto_eligible": 1, "review": 0},
    "F02": {"candidate_count": 1, "auto_eligible": 1, "review": 0},
    "F03": {"candidate_count": 1, "auto_eligible": 1, "review": 0},
    "F04": {"candidate_count": 1, "auto_eligible": 0, "review": 1},
    "F05": {"candidate_count": 1, "auto_eligible": 1, "review": 0},
    "F06": {"candidate_count": 1, "auto_eligible": 0, "review": 1},
    "F07": {"candidate_count": 1, "auto_eligible": 0, "review": 1},
    "F08": {"candidate_count": 3, "auto_eligible": 3, "review": 0},
    "F09": {"candidate_count": 0, "auto_eligible": 0, "review": 0},
    "F10": {"candidate_count": 0, "auto_eligible": 0, "review": 0},
}


@dataclass
class Builder:
    nodes: Dict[int, Point] = field(default_factory=dict)
    elements: Dict[int, Tuple[int, str, Tuple[int, ...]]] = field(default_factory=dict)
    element_props: Dict[int, int] = field(default_factory=dict)
    components: Dict[int, Tuple[str, float]] = field(default_factory=dict)
    pshell: Dict[int, float] = field(default_factory=dict)
    next_node: int = 1
    next_element: int = 1
    next_component: int = 1
    next_property: int = 1

    def component(self, name: str, thickness: float = 1.0) -> Tuple[int, int]:
        component_id = self.next_component
        self.next_component += 1
        property_id = self.next_property
        self.next_property += 1
        self.components[component_id] = (name, thickness)
        self.pshell[property_id] = thickness
        return component_id, property_id

    def node(self, point: Point) -> int:
        node_id = self.next_node
        self.next_node += 1
        self.nodes[node_id] = tuple(float(value) for value in point)
        return node_id

    def quad(self, component_id: int, property_id: int, node_ids: Sequence[int]) -> int:
        element_id = self.next_element
        self.next_element += 1
        self.elements[element_id] = (component_id, "CQUAD4", tuple(node_ids))
        self.element_props[element_id] = property_id
        return element_id

    def grid(self, name: str, origin: Point, u: Point, v: Point, nu: int, nv: int, thickness: float = 1.0, omit: Sequence[Tuple[int, int]] = ()) -> int:
        """Regular CQUAD4 grid spanning origin + [0,u] + [0,v]."""
        component_id, property_id = self.component(name, thickness)
        grid: Dict[Tuple[int, int], int] = {}
        for j in range(nv + 1):
            for i in range(nu + 1):
                grid[(i, j)] = self.node((
                    origin[0] + u[0] * i / nu + v[0] * j / nv,
                    origin[1] + u[1] * i / nu + v[1] * j / nv,
                    origin[2] + u[2] * i / nu + v[2] * j / nv,
                ))
        omitted = set(omit)
        for j in range(nv):
            for i in range(nu):
                if (i, j) in omitted:
                    continue
                self.quad(component_id, property_id, (
                    grid[(i, j)], grid[(i + 1, j)], grid[(i + 1, j + 1)], grid[(i, j + 1)],
                ))
        return component_id

    def ruled(self, name: str, bottom: Sequence[Point], top: Sequence[Point], thickness: float = 1.0) -> int:
        """Ruled surface between two polylines with the same vertex count."""
        if len(bottom) != len(top):
            raise ValueError("ruled: bottom and top must have the same vertex count")
        component_id, property_id = self.component(name, thickness)
        bottom_ids = [self.node(point) for point in bottom]
        top_ids = [self.node(point) for point in top]
        for index in range(len(bottom) - 1):
            self.quad(component_id, property_id, (
                bottom_ids[index], bottom_ids[index + 1],
                top_ids[index + 1], top_ids[index],
            ))
        return component_id

    def line_points(self, start: float, stop: float, step: float, y: float, z: float) -> List[Point]:
        count = int(round((stop - start) / step))
        return [(start + index * step, y, z) for index in range(count + 1)]


def straight_t(b: Builder, x: float) -> None:
    b.grid("F01_BASE_T2", (x - 15, -30, 0), (90, 0, 0), (0, 60, 0), 30, 20, 2.0)
    b.ruled("F01_WEB_T1", b.line_points(x, x + 60, 2.5, 0, GAP), b.line_points(x, x + 60, 2.5, 0, GAP + 20.0), 1.0)


def angled_t(b: Builder, x: float) -> None:
    b.grid("F02_BASE_T2", (x - 15, -30, 0), (90, 0, 0), (0, 60, 0), 30, 20, 2.0)
    slant = 20.0  # 45 deg lean in +y
    bottom = b.line_points(x, x + 60, 2.5, 0, GAP)
    b.ruled("F02_ANGLED_WEB_T1", bottom, [(px, py + slant, GAP + 20.0) for px, py, pz in bottom], 1.0)


def curved_t(b: Builder, x: float) -> None:
    b.grid("F03_BASE_T2", (x - 55, -30, 0), (110, 0, 0), (0, 60, 0), 36, 20, 2.0)
    bottom = []
    for index in range(25):
        px = x - 30.0 + index * 2.5
        py = 8.0 * math.sin(math.pi * index / 24.0)
        bottom.append((px, py, GAP))
    b.ruled("F03_CURVED_WEB_T1", bottom, [(px, py, GAP + 20.0) for px, py, pz in bottom], 1.0)


def partial_overlap_t(b: Builder, x: float) -> None:
    # The 100 mm web only overlaps the 34 mm base interval [x+23, x+57].
    b.grid("F04_BASE_T2", (x + 23, -20, 0), (34, 0, 0), (0, 40, 0), 11, 13, 2.0)
    b.ruled("F04_LONG_WEB_T1", b.line_points(x, x + 100, 2.5, 0, GAP), b.line_points(x, x + 100, 2.5, 0, GAP + 20.0), 1.0)


def patch(b: Builder, x: float) -> None:
    b.grid("F05_PATCH_TARGET_T2", (x, 0, 0), (80, 0, 0), (0, 60, 0), 26, 20, 2.0)
    b.grid("F05_SMALL_PATCH_T1", (x + 15, 15, GAP), (50, 0, 0), (0, 30, 0), 16, 10, 1.0)


def patch_small_hole(b: Builder, x: float) -> None:
    # 60 x 40 patch with a ~20 mm internal hole (2x2 omitted cells at 5 mm).
    # The hole is below the 30 mm review threshold, so the patch is review-only.
    b.grid("F06_PATCH_TARGET_T2", (x, 0, 0), (80, 0, 0), (0, 60, 0), 26, 20, 2.0)
    b.grid("F06_PATCH_HOLE_T1", (x + 10, 10, GAP), (60, 0, 0), (0, 40, 0), 20, 13, 1.0,
           omit={(8, 4), (9, 4), (10, 4), (11, 4), (8, 5), (9, 5), (10, 5), (11, 5),
                 (8, 6), (9, 6), (10, 6), (11, 6), (8, 7), (9, 7), (10, 7), (11, 7)})


def near_free_edges(b: Builder, x: float) -> None:
    # Two plates separated by a 2 mm gap but offset in y so the tangent
    # projection coverage stays below the acceptance threshold.
    b.grid("F07_EDGE_PLATE_A_T1", (x, 0, 0), (40, 0, 0), (0, 30, 0), 13, 10, 1.0)
    b.grid("F07_EDGE_PLATE_B_T1", (x + 42, 12, 0), (40, 0, 0), (0, 30, 0), 13, 10, 1.0)


def multi_target(b: Builder, x: float) -> None:
    # One 140 mm web crossing three 40 mm base plates with 10 mm gaps.
    for index in range(3):
        x0 = x + index * 50.0
        b.grid("F08_BASE{}_T2".format(index + 1), (x0, -20, 0), (40, 0, 0), (0, 40, 0), 13, 13, 2.0)
    b.ruled("F08_CENTER_WEB_T1", b.line_points(x, x + 140, 2.5, 0, GAP), b.line_points(x, x + 140, 2.5, 0, GAP + 20.0), 1.0)


def negative_far_apart(b: Builder, x: float) -> None:
    b.grid("F09_PLATE_A_T1", (x, 0, 0), (40, 0, 0), (0, 30, 0), 13, 10, 1.0)
    b.grid("F09_PLATE_B_T1", (x + 100, 0, 0), (40, 0, 0), (0, 30, 0), 13, 10, 1.0)


def negative_shared_nodes(b: Builder, x: float) -> None:
    # One continuous T mesh: the web shares its bottom row of nodes with the
    # base plate, so no independent source free edge exists and no candidate
    # can be detected (the joint is already welded by shared nodes).
    base_cid, base_pid = b.component("F10_CONTINUOUS_T_T2", 2.0)
    base_grid: Dict[Tuple[int, int], int] = {}
    for j in range(7):
        for i in range(7):
            base_grid[(i, j)] = b.node((x + i * 10.0, -30 + j * 10.0, 0.0))
    for j in range(6):
        for i in range(6):
            b.quad(base_cid, base_pid, (base_grid[(i, j)], base_grid[(i + 1, j)], base_grid[(i + 1, j + 1)], base_grid[(i, j + 1)]))
    web_cid, web_pid = b.component("F10_CONTINUOUS_T_T1", 1.0)
    web_grid: Dict[Tuple[int, int], int] = {}
    for k in range(3):
        for i in range(7):
            web_grid[(i, k)] = base_grid[(i, 3)] if k == 0 else b.node((x + i * 10.0, 0.0, k * 10.0))
    for k in range(2):
        for i in range(6):
            b.quad(web_cid, web_pid, (web_grid[(i, k)], web_grid[(i + 1, k)], web_grid[(i + 1, k + 1)], web_grid[(i, k + 1)]))


def build_scenarios() -> Builder:
    b = Builder()
    scenarios = [
        ("F01", straight_t), ("F02", angled_t), ("F03", curved_t),
        ("F04", partial_overlap_t), ("F05", patch), ("F06", patch_small_hole),
        ("F07", near_free_edges), ("F08", multi_target),
        ("F09", negative_far_apart), ("F10", negative_shared_nodes),
    ]
    for index, (case_id, factory) in enumerate(scenarios):
        factory(b, index * CASE_PITCH)
    return b


def free_edge_lengths(b: Builder) -> Dict[int, float]:
    """Total free-edge length per component (perimeter minus shared edges)."""
    from collections import Counter, defaultdict
    owners: Counter[Tuple[int, int]] = Counter()
    for (component_id, card, node_ids) in b.elements.values():
        for a, bnode in ((node_ids[0], node_ids[1]), (node_ids[1], node_ids[2]), (node_ids[2], node_ids[3]), (node_ids[3], node_ids[0])):
            owners[tuple(sorted((a, bnode)))] += 1
    length_by_component: Dict[int, float] = defaultdict(float)
    for (a, bnode), count in owners.items():
        if count == 1:
            ax, ay, az = b.nodes[a]
            bx, by, bz = b.nodes[bnode]
            length = math.hypot(ax - bx, ay - by, az - bz)
            for (component_id, card, node_ids) in b.elements.values():
                pass  # resolved below per component
    # Resolve free edges per component (an edge is free in a component when
    # it belongs to exactly one element of that component).
    comp_edge_owner: Dict[int, Counter[Tuple[int, int]]] = defaultdict(Counter)
    for element_id, (component_id, card, node_ids) in b.elements.items():
        for a, bnode in ((node_ids[0], node_ids[1]), (node_ids[1], node_ids[2]), (node_ids[2], node_ids[3]), (node_ids[3], node_ids[0])):
            comp_edge_owner[component_id][tuple(sorted((a, bnode)))] += 1
    for component_id, edge_owner in comp_edge_owner.items():
        for (a, bnode), count in edge_owner.items():
            if count == 1:
                ax, ay, az = b.nodes[a]
                bx, by, bz = b.nodes[bnode]
                length_by_component[component_id] += math.hypot(ax - bx, ay - by, az - bz)
    return dict(length_by_component)


def validate(b: Builder) -> Dict[str, int]:
    errors = []
    for element_id, (component_id, card, node_ids) in b.elements.items():
        if card != "CQUAD4" or len(node_ids) != 4:
            errors.append("malformed element {}".format(element_id))
        if component_id not in b.components:
            errors.append("element {} references missing component".format(element_id))
        if any(node not in b.nodes for node in node_ids):
            errors.append("element {} references missing nodes".format(element_id))
    for component_id, (name, thickness) in b.components.items():
        count = sum(1 for (cid, card, node_ids) in b.elements.values() if cid == component_id)
        if count < 4:
            errors.append("component {} {} has too few elements".format(component_id, name))
        if thickness <= 0.0:
            errors.append("component {} has non-positive thickness".format(component_id))
    if errors:
        raise ValueError("validation failed:\n- " + "\n- ".join(errors))
    counts = {card: sum(1 for (cid, card_type, n) in b.elements.values() if card_type == card) for card in ("CQUAD4",)}
    return {"nodes": len(b.nodes), "elements": len(b.elements), "components": len(b.components), "quads": counts["CQUAD4"]}


def write_fem(b: Builder, output: Path) -> None:
    lines = [
        "$ FEM Automatic Seam validation deck",
        "$ Ten isolated scenarios: straight/angled/curved/partial T, patch, patch hole,",
        "$ near free edges, multi-target, far apart, shared-node negative controls.",
        "$ Generated by examples/FemAutoSeam_Validation/generate_fem.py",
        "$ Units: mm, N, MPa. Test geometry only.",
        "BEGIN BULK",
        '$HMNAME MAT 1 "FAS_STEEL"',
        "MAT1,1,210000.0,,0.3,7.85E-9",
        "$ PROPERTIES",
    ]
    for property_id, thickness in sorted(b.pshell.items()):
        lines.append('$HMNAME PROP {} "FAS_T{:.3g}"'.format(property_id, thickness))
        lines.append("PSHELL,{},1,{:.9g}".format(property_id, thickness))
    lines.append("$ COMPONENT NAMES")
    for component_id, (name, thickness) in sorted(b.components.items()):
        lines.extend((
            '$HMNAME COMP {} "{}"'.format(component_id, name),
            "$HWCOLOR COMP {} {}".format(component_id, 3 if "_WEB" in name or "_PATCH" in name or "_PLATE" in name else 6),
        ))
    lines.append("$ NODES")
    for node_id, point in sorted(b.nodes.items()):
        lines.append("GRID,{},,{:.9g},{:.9g},{:.9g}".format(node_id, *point))
    lines.append("$ ELEMENTS GROUPED BY HYPERMESH COMPONENT")
    grouped: Dict[int, List[int]] = {}
    for element_id, (component_id, card, node_ids) in b.elements.items():
        grouped.setdefault(component_id, []).append(element_id)
    for component_id in sorted(b.components):
        lines.extend(("$HMCOMP ID {}".format(component_id), "$ " + b.components[component_id][0]))
        for element_id in sorted(grouped.get(component_id, [])):
            cid, card, node_ids = b.elements[element_id]
            fields = [card, str(element_id), str(b.element_props[element_id])] + [str(node) for node in node_ids]
            lines.append(",".join(fields))
    lines.extend(("ENDDATA", ""))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def validate_written_fem(output: Path, stats: Dict[str, int]) -> None:
    lines = output.read_text(encoding="utf-8").splitlines()
    if "BEGIN BULK" not in lines or not lines or lines[-1] != "ENDDATA":
        raise ValueError("FEM is missing BEGIN BULK or terminal ENDDATA")
    actual = sum(line.startswith("CQUAD4,") for line in lines)
    if actual != stats["quads"]:
        raise ValueError("written CQUAD4 count {} != {}".format(actual, stats["quads"]))
    oversized = [(index, line) for index, line in enumerate(lines, 1) if line and not line.startswith("$") and len(line.split(",")) > 9]
    if oversized:
        raise ValueError("free-format card exceeds nine fields at line {}".format(oversized[0][0]))


def manifest(b: Builder, stats: Dict[str, int]) -> Dict[str, object]:
    components = []
    for component_id in sorted(b.components):
        name, thickness = b.components[component_id]
        element_ids = [eid for eid, (cid, card, n) in b.elements.items() if cid == component_id]
        components.append({"component_id": component_id, "name": name, "thickness": thickness, "element_count": len(element_ids), "element_ids": element_ids})
    return {
        "schema_version": "1.0",
        "purpose": "FEM Automatic Seam candidate classification validation",
        "generator": "examples/FemAutoSeam_Validation/generate_fem.py",
        "fem": "FemAutoSeam_Combined_Validation.fem",
        "parameters": {"case_pitch": CASE_PITCH, "gap": GAP, "search_distance": SEARCH_DISTANCE, "min_seam_length": MIN_SEAM_LENGTH},
        "statistics": stats,
        "cases": [
            {"case_id": case_id, "title": title, "expected": expected, "expected_results": EXPECTED_RESULTS[case_id]}
            for case_id, title, expected in (
                ("F01", "straight T seam (base 90x60, web 60x20, gap 3)", "one high-confidence T candidate, auto"),
                ("F02", "angled T seam (web leaned 45 deg in +y)", "one T candidate, auto"),
                ("F03", "curved T seam (sinusoidal web)", "one T candidate, auto"),
                ("F04", "partial-overlap T (100 mm web, 34 mm base interval)", "only the 34 mm common interval creates a weld; review"),
                ("F05", "parallel patch (50x30 patch fully inside 80x60 target)", "one patch candidate, auto"),
                ("F06", "patch with ~20 mm internal hole (< 30 mm threshold)", "patch review only"),
                ("F07", "nearby free edges (2 mm gap, y-offset 12 mm)", "near-edge candidate, review only"),
                ("F08", "one 140 mm web across three 40 mm bases", "three T candidates (one per target), auto"),
                ("F09", "negative control: plates 100 mm apart", "no candidate"),
                ("F10", "negative control: continuous shared-node L mesh", "no candidate"),
            )
        ],
        "components": components,
        "warning": "Geometry-only validation deck. Candidate confidence is a topological prediction; the live workflow verdict is decided by the HyperMesh 2019/2022 quality criteria.",
    }


def parse_args() -> argparse.Namespace:
    directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=directory / "FemAutoSeam_Combined_Validation.fem")
    parser.add_argument("--manifest", type=Path, default=directory / "FemAutoSeam_Combined_Validation_manifest.json")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    b = build_scenarios()
    stats = validate(b)
    write_fem(b, args.output.resolve())
    validate_written_fem(args.output.resolve(), stats)
    args.manifest.resolve().write_text(json.dumps(manifest(b, stats), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"fem": str(args.output.resolve()), "manifest": str(args.manifest.resolve()), **stats}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
