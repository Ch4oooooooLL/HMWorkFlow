#!/usr/bin/env python3
"""Generate a large OptiStruct shell FEM for Local Mesh Optimizer testing.

The model deliberately contains valid bulk mesh, washer rings, defects that
match the existing automatic planner, and failures that must remain manual.
Only the Python standard library is required.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Sequence, Tuple

Point = Tuple[float, float, float]


@dataclass(frozen=True)
class Element:
    card: str
    element_id: int
    property_id: int
    nodes: Tuple[int, ...]


@dataclass(frozen=True)
class Rigid:
    element_id: int
    independent: int
    dependent: Tuple[int, ...]
    components: str = "123456"


@dataclass
class Model:
    nodes: Dict[int, Point] = field(default_factory=dict)
    elements: Dict[int, Element] = field(default_factory=dict)
    rigids: Dict[int, Rigid] = field(default_factory=dict)
    groups: Dict[str, List[int]] = field(default_factory=dict)
    notes: Dict[str, str] = field(default_factory=dict)
    next_node_id: int = 1
    next_element_id: int = 1
    next_rigid_id: int = 900001

    def add_node(self, point: Point) -> int:
        node_id = self.next_node_id
        self.next_node_id += 1
        self.nodes[node_id] = point
        return node_id

    def add_element(self, card: str, property_id: int, nodes: Sequence[int], group: str = "") -> int:
        element_id = self.next_element_id
        self.next_element_id += 1
        element = Element(card, element_id, property_id, tuple(nodes))
        self.elements[element_id] = element
        if group:
            self.groups.setdefault(group, []).append(element_id)
        return element_id

    def add_rigid(self, independent: int, dependent: Sequence[int], group: str = "RBE2") -> int:
        element_id = self.next_rigid_id
        self.next_rigid_id += 1
        self.rigids[element_id] = Rigid(element_id, independent, tuple(dependent))
        self.groups.setdefault(group, []).append(element_id)
        return element_id


def _grid_node(nx: int, i: int, j: int) -> int:
    return j * (nx + 1) + i + 1


def _defect_cells(nx: int, ny: int, count: int, zone_index: int) -> List[Tuple[int, int]]:
    """Return separated cells from one of three horizontal defect zones."""
    cells: List[Tuple[int, int]] = []
    margin = 5
    usable_height = ny - 2 * margin
    zone_start = margin + zone_index * usable_height // 3
    zone_end = margin + (zone_index + 1) * usable_height // 3
    for j in range(zone_start + 2, zone_end - 2, 3):
        for i in range(margin + 1, nx - margin - 1, 3):
            cells.append((i, j))
            if len(cells) >= count:
                return cells
    return cells


def build_plate(
    model: Model,
    nx: int,
    ny: int,
    spacing: float,
    split_defects: int = 1200,
    narrow_defects: int = 1200,
    skinny_defects: int = 1200,
) -> None:
    for j in range(ny + 1):
        for i in range(nx + 1):
            model.add_node((i * spacing, j * spacing, 0.0))

    split_cells = set(_defect_cells(nx, ny, split_defects, 0))
    narrow_cells = set(_defect_cells(nx, ny, narrow_defects, 1))
    skinny_cells = set(_defect_cells(nx, ny, skinny_defects, 2))
    overlap = split_cells.intersection(narrow_cells.union(skinny_cells)).union(narrow_cells.intersection(skinny_cells))
    if overlap:
        raise ValueError("defect-cell layout overlaps: {}".format(sorted(overlap)))

    # Move shared grid nodes before element creation. Defects remain connected
    # to a normal multi-layer neighborhood, so collapse endpoints are not all
    # classified as region-boundary anchors.
    for i, j in split_cells:
        node = _grid_node(nx, i + 1, j + 1)
        x, y, _ = model.nodes[node]
        model.nodes[node] = (x - 2.0 * spacing / 5.0, y - 0.8 * spacing / 5.0, 0.65 * spacing)
    for i, j in narrow_cells:
        for node in (_grid_node(nx, i, j + 1), _grid_node(nx, i + 1, j + 1)):
            x, _, z = model.nodes[node]
            model.nodes[node] = (x, j * spacing + 0.08 * spacing, z)
    for i, j in skinny_cells:
        node = _grid_node(nx, i + 1, j + 1)
        x, _, z = model.nodes[node]
        model.nodes[node] = (x, j * spacing + 0.04 * spacing, z)

    for j in range(ny):
        for i in range(nx):
            n00 = _grid_node(nx, i, j)
            n10 = _grid_node(nx, i + 1, j)
            n11 = _grid_node(nx, i + 1, j + 1)
            n01 = _grid_node(nx, i, j + 1)
            cell = (i, j)
            if cell in skinny_cells:
                model.add_element("CTRIA3", 1, (n00, n10, n11), "PROCESSABLE_SKINNY_TRIA")
                model.add_element("CTRIA3", 1, (n00, n11, n01), "SKINNY_TRIA_COMPANION")
            elif cell in split_cells:
                model.add_element("CQUAD4", 1, (n00, n10, n11, n01), "PROCESSABLE_SPLIT_QUAD")
            elif cell in narrow_cells:
                model.add_element("CQUAD4", 1, (n00, n10, n11, n01), "PROCESSABLE_NARROW_QUAD")
            else:
                model.add_element("CQUAD4", 1, (n00, n10, n11, n01), "BASE_SHELL")

    model.notes["plate"] = (
        "{} x {} cells at spacing {}; generated defect cells: split={}, narrow={}, skinny={}; "
        "three-cell pitch prevents direct endpoint sharing"
    ).format(nx, ny, spacing, len(split_cells), len(narrow_cells), len(skinny_cells))


def add_washers(model: Model, count: int, nx: int, ny: int, spacing: float) -> None:
    segments = 16
    inner_radius = 4.0
    radii = (inner_radius, 8.0, 12.0)
    origin_y = (ny + 8) * spacing
    columns = 6
    for washer_index in range(count):
        center_x = 18.0 + (washer_index % columns) * 34.0
        center_y = origin_y + (washer_index // columns) * 34.0
        rings: List[List[int]] = []
        for radius in radii:
            ring = []
            for segment in range(segments):
                angle = 2.0 * math.pi * segment / segments
                ring.append(
                    model.add_node((center_x + radius * math.cos(angle), center_y + radius * math.sin(angle), 0.0))
                )
            rings.append(ring)
        for ring_index in range(len(rings) - 1):
            inner = rings[ring_index]
            outer = rings[ring_index + 1]
            for segment in range(segments):
                following = (segment + 1) % segments
                model.add_element(
                    "CQUAD4",
                    2,
                    (inner[segment], inner[following], outer[following], outer[segment]),
                    "WASHER_ELEMENTS",
                )
        center_node = model.add_node((center_x, center_y, 0.0))
        model.add_rigid(center_node, rings[0], "WASHER_RBE2")
        model.groups.setdefault("WASHER_CENTER_NODES", []).append(center_node)
        model.groups.setdefault("WASHER_INNER_NODES", []).extend(rings[0])
    model.notes["washers"] = "{} detached two-ring washers, 16 sectors each, with center RBE2".format(count)


def add_manual_failures(model: Model, nx: int, ny: int, spacing: float, count: int = 120) -> None:
    base_x = (nx + 8) * spacing

    def nodes(points: Sequence[Point]) -> List[int]:
        return [model.add_node(point) for point in points]

    for cluster_index in range(count):
        cluster_x = base_x + (cluster_index % 10) * 28.0
        base_y = 10.0 + (cluster_index // 10) * 125.0

        # Minimum angle around 26.6 degrees: commonly fails angle criteria but
        # remains below the planner's 2.5 two-long-edge collapse ratio.
        n = nodes(((cluster_x, base_y, 0.0), (cluster_x + 5.0, base_y, 0.0), (cluster_x, base_y + 10.0, 0.0)))
        model.add_element("CTRIA3", 3, n, "MANUAL_MODERATE_TRIA")

        n = nodes(((cluster_x, base_y + 20.0, 0.0), (cluster_x + 3.0, base_y + 20.0, 0.0), (cluster_x + 7.0, base_y + 20.0, 0.0)))
        model.add_element("CTRIA3", 3, n, "MANUAL_ZERO_AREA_TRIA")

        n = nodes(
            (
                (cluster_x, base_y + 35.0, 0.0),
                (cluster_x + 5.0, base_y + 35.0, 0.0),
                (cluster_x + 10.0, base_y + 35.0, 0.0),
                (cluster_x + 15.0, base_y + 35.0, 0.0),
            )
        )
        model.add_element("CQUAD4", 3, n, "MANUAL_ZERO_AREA_QUAD")

        n = nodes(
            (
                (cluster_x, base_y + 50.0, 0.0),
                (cluster_x + 10.0, base_y + 60.0, 0.0),
                (cluster_x, base_y + 60.0, 0.0),
                (cluster_x + 10.0, base_y + 50.0, 0.0),
            )
        )
        model.add_element("CQUAD4", 3, n, "MANUAL_BOWTIE_QUAD")

        n = nodes(
            (
                (cluster_x, base_y + 75.0, 0.0),
                (cluster_x + 8.0, base_y + 75.0, 0.0),
                (cluster_x + 8.0, base_y + 83.0, 0.0),
                (cluster_x, base_y + 83.0, 0.0),
            )
        )
        model.add_element("CQUAD4", 3, n, "MANUAL_DUPLICATE_QUADS")
        model.add_element("CQUAD4", 3, n, "MANUAL_DUPLICATE_QUADS")

        # Skinny tria whose short-edge endpoints are RBE2 dependent nodes.
        n = nodes(
            (
                (cluster_x, base_y + 100.0, 0.0),
                (cluster_x + 0.15, base_y + 100.0, 0.0),
                (cluster_x, base_y + 110.0, 0.0),
            )
        )
        protected_element = model.add_element("CTRIA3", 3, n, "MANUAL_RBE2_PROTECTED_TRIA")
        center = model.add_node((cluster_x - 3.0, base_y + 105.0, 0.0))
        model.add_rigid(center, n[:2], "MANUAL_RBE2")
        model.groups.setdefault("RECOMMENDED_USER_ANCHORS", []).extend(n[:2])
    model.notes["manual_rbe2"] = (
        "{} protected skinny trias: select {} listed anchor nodes because automatic rigid-node protection is unverified"
    ).format(count, len(model.groups.get("RECOMMENDED_USER_ANCHORS", [])))


def _write_set(lines: List[str], set_id: int, set_type: str, values: Iterable[int], name: str) -> None:
    unique = sorted(set(int(value) for value in values))
    if not unique:
        return
    lines.append("$ SET_NAME: {}".format(name))
    first, rest = unique[:6], unique[6:]
    lines.append(",".join(["SET3", str(set_id), set_type] + [str(value) for value in first]))
    for start in range(0, len(rest), 8):
        lines.append(",".join(["+"] + [str(value) for value in rest[start : start + 8]]))


def validate(model: Model, minimum_shells: int) -> Dict[str, object]:
    errors: List[str] = []
    for element in model.elements.values():
        expected = 3 if element.card == "CTRIA3" else 4
        if len(element.nodes) != expected:
            errors.append("{} {} has {} nodes".format(element.card, element.element_id, len(element.nodes)))
        missing = [node for node in element.nodes if node not in model.nodes]
        if missing:
            errors.append("element {} references missing nodes {}".format(element.element_id, missing))
    for rigid in model.rigids.values():
        referenced = (rigid.independent,) + rigid.dependent
        missing = [node for node in referenced if node not in model.nodes]
        if missing:
            errors.append("RBE2 {} references missing nodes {}".format(rigid.element_id, missing))
        if rigid.independent in rigid.dependent:
            errors.append("RBE2 {} repeats its independent node".format(rigid.element_id))
    for name, values in model.groups.items():
        if name.endswith("NODES") or name == "RECOMMENDED_USER_ANCHORS":
            missing = [value for value in values if value not in model.nodes]
        else:
            missing = [value for value in values if value not in model.elements and value not in model.rigids]
        if missing:
            errors.append("group {} references missing IDs {}".format(name, missing[:10]))
    if len(model.elements) < minimum_shells:
        errors.append("model has only {} shell elements; expected at least {}".format(len(model.elements), minimum_shells))
    required = (
        "PROCESSABLE_SPLIT_QUAD",
        "PROCESSABLE_SKINNY_TRIA",
        "PROCESSABLE_NARROW_QUAD",
        "WASHER_ELEMENTS",
        "MANUAL_ZERO_AREA_TRIA",
        "MANUAL_ZERO_AREA_QUAD",
        "MANUAL_BOWTIE_QUAD",
        "MANUAL_DUPLICATE_QUADS",
        "MANUAL_RBE2_PROTECTED_TRIA",
    )
    for name in required:
        if not model.groups.get(name):
            errors.append("required group {} is empty".format(name))
    duplicate_keys: Dict[Tuple[int, ...], List[int]] = {}
    for element in model.elements.values():
        duplicate_keys.setdefault(tuple(sorted(element.nodes)), []).append(element.element_id)
    duplicate_groups = [ids for ids in duplicate_keys.values() if len(ids) > 1]
    if not duplicate_groups:
        errors.append("no intentional duplicate shell pair found")
    if errors:
        raise ValueError("model validation failed:\n- " + "\n- ".join(errors))
    return {
        "nodes": len(model.nodes),
        "shell_elements": len(model.elements),
        "quad_elements": sum(element.card == "CQUAD4" for element in model.elements.values()),
        "tria_elements": sum(element.card == "CTRIA3" for element in model.elements.values()),
        "rbe2_elements": len(model.rigids),
        "intentional_duplicate_groups": duplicate_groups,
    }


def write_fem(model: Model, output: Path) -> None:
    lines = [
        "$ Generated by generate_fem.py for HMWorkFlow Local Mesh Optimizer",
        "$ Deliberately contains invalid/poor-quality elements; use for testing only.",
        "BEGIN BULK",
        "$HMNAME MAT 1 \"STEEL_TEST\"",
        "MAT1,1,210000.0,,0.3,7.85E-9",
        "$HMNAME PROP 1 \"BASE_AND_AUTOMATIC_DEFECTS\"",
        "PSHELL,1,1,1.0",
        "$HMNAME PROP 2 \"WASHER_RINGS\"",
        "PSHELL,2,1,1.2",
        "$HMNAME PROP 3 \"MANUAL_FAILURES\"",
        "PSHELL,3,1,1.0",
        "$ NODES",
    ]
    for node_id, (x, y, z) in sorted(model.nodes.items()):
        lines.append("GRID,{},{},{:.9g},{:.9g},{:.9g}".format(node_id, "", x, y, z))
    lines.append("$ SHELL ELEMENTS")
    for element in sorted(model.elements.values(), key=lambda value: value.element_id):
        lines.append(
            ",".join(
                [element.card, str(element.element_id), str(element.property_id)]
                + [str(node) for node in element.nodes]
            )
        )
    lines.append("$ RIGID ELEMENTS")
    for rigid in sorted(model.rigids.values(), key=lambda value: value.element_id):
        dependent = [str(node) for node in rigid.dependent]
        lines.append(
            ",".join(
                ["RBE2", str(rigid.element_id), str(rigid.independent), rigid.components]
                + dependent[:5]
            )
        )
        for start in range(5, len(dependent), 8):
            lines.append(",".join(["+"] + dependent[start : start + 8]))
    lines.append("$ NAMED TEST SETS")
    set_specs = (
        (1001, "ELEM", "PROCESSABLE_SPLIT_QUAD"),
        (1002, "ELEM", "PROCESSABLE_SKINNY_TRIA"),
        (1003, "ELEM", "PROCESSABLE_NARROW_QUAD"),
        (1101, "ELEM", "WASHER_ELEMENTS"),
        (1102, "ELEM", "WASHER_RBE2"),
        (1201, "ELEM", "MANUAL_MODERATE_TRIA"),
        (1202, "ELEM", "MANUAL_ZERO_AREA_TRIA"),
        (1203, "ELEM", "MANUAL_ZERO_AREA_QUAD"),
        (1204, "ELEM", "MANUAL_BOWTIE_QUAD"),
        (1205, "ELEM", "MANUAL_DUPLICATE_QUADS"),
        (1206, "ELEM", "MANUAL_RBE2_PROTECTED_TRIA"),
        (1207, "GRID", "RECOMMENDED_USER_ANCHORS"),
    )
    for set_id, set_type, name in set_specs:
        _write_set(lines, set_id, set_type, model.groups.get(name, []), name)
    lines.extend(("ENDDATA", ""))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")


def validate_written_fem(output: Path, stats: Mapping[str, object]) -> None:
    text = output.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or "BEGIN BULK" not in lines or not lines[-1] == "ENDDATA":
        raise ValueError("written FEM is missing BEGIN BULK or terminal ENDDATA")
    counts = {
        "nodes": sum(line.startswith("GRID,") for line in lines),
        "quad_elements": sum(line.startswith("CQUAD4,") for line in lines),
        "tria_elements": sum(line.startswith("CTRIA3,") for line in lines),
        "rbe2_elements": sum(line.startswith("RBE2,") for line in lines),
    }
    for key, actual in counts.items():
        expected = int(stats[key])
        if actual != expected:
            raise ValueError("written FEM {} count {} does not match {}".format(key, actual, expected))
    oversized = [
        (index, line)
        for index, line in enumerate(lines, 1)
        if line and not line.startswith("$") and len(line.split(",")) > 9
    ]
    if oversized:
        raise ValueError("free-format card exceeds nine fields at line {}: {}".format(*oversized[0]))


def build_manifest(model: Model, stats: Mapping[str, object], arguments: argparse.Namespace) -> Dict[str, object]:
    processable_names = ("PROCESSABLE_SPLIT_QUAD", "PROCESSABLE_SKINNY_TRIA", "PROCESSABLE_NARROW_QUAD")
    manual_names = (
        "MANUAL_MODERATE_TRIA",
        "MANUAL_ZERO_AREA_TRIA",
        "MANUAL_ZERO_AREA_QUAD",
        "MANUAL_BOWTIE_QUAD",
        "MANUAL_DUPLICATE_QUADS",
        "MANUAL_RBE2_PROTECTED_TRIA",
    )
    return {
        "generator": "generate_fem.py",
        "parameters": {
            "nx": arguments.nx,
            "ny": arguments.ny,
            "spacing": arguments.spacing,
            "washers": arguments.washers,
            "split_defects": arguments.split_defects,
            "narrow_defects": arguments.narrow_defects,
            "skinny_defects": arguments.skinny_defects,
            "manual_clusters": arguments.manual_clusters,
        },
        "statistics": dict(stats),
        "groups": {name: {"count": len(values), "ids": sorted(set(values))} for name, values in sorted(model.groups.items())},
        "expected_behavior": {
            "automatic_candidates": {name: len(model.groups.get(name, [])) for name in processable_names},
            "washer_default": "WASHER_ELEMENTS should be excluded for manual handling when EXCLUDE_WASHER_ELEMENTS=1",
            "manual_failures": {name: len(model.groups.get(name, [])) for name in manual_names},
            "rbe2_protection": "Select RECOMMENDED_USER_ANCHORS before optimization; automatic rigid-node detection is not verified.",
        },
        "recommended_test_settings": {
            "scope": "all or displayed",
            "execution_mode": "batch",
            "exclude_washer_elements": True,
            "adjacency_layers": 2,
            "max_rounds": 3,
            "preserve_geometry_association": True,
            "note": "The selected criteria determines which deliberately distorted entities enter the failed mark.",
        },
        "notes": model.notes,
        "warning": "This model intentionally contains degenerate and duplicate topology. Never use it for production solving.",
    }


def parse_arguments() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nx", type=int, default=300, help="plate cells in X (minimum 80)")
    parser.add_argument("--ny", type=int, default=200, help="plate cells in Y (minimum 72)")
    parser.add_argument("--spacing", type=float, default=5.0)
    parser.add_argument("--washers", type=int, default=12)
    parser.add_argument("--split-defects", type=int, default=1200)
    parser.add_argument("--narrow-defects", type=int, default=1200)
    parser.add_argument("--skinny-defects", type=int, default=1200)
    parser.add_argument("--manual-clusters", type=int, default=120)
    parser.add_argument("--output", type=Path, default=script_dir / "LocalMeshOptimizer_Large_Mixed.fem")
    parser.add_argument("--manifest", type=Path, default=script_dir / "LocalMeshOptimizer_Large_Mixed_manifest.json")
    arguments = parser.parse_args()
    if arguments.nx < 80 or arguments.ny < 72:
        parser.error("nx must be >=80 and ny must be >=72 so all defect neighborhoods fit")
    if arguments.spacing <= 0.0 or arguments.washers < 1:
        parser.error("spacing and washers must be positive")
    if min(arguments.split_defects, arguments.narrow_defects, arguments.skinny_defects, arguments.manual_clusters) < 1:
        parser.error("all defect counts must be positive")
    return arguments


def main() -> int:
    arguments = parse_arguments()
    model = Model()
    build_plate(
        model,
        arguments.nx,
        arguments.ny,
        arguments.spacing,
        arguments.split_defects,
        arguments.narrow_defects,
        arguments.skinny_defects,
    )
    add_washers(model, arguments.washers, arguments.nx, arguments.ny, arguments.spacing)
    add_manual_failures(model, arguments.nx, arguments.ny, arguments.spacing, arguments.manual_clusters)
    stats = validate(model, minimum_shells=10000)
    write_fem(model, arguments.output.resolve())
    validate_written_fem(arguments.output.resolve(), stats)
    manifest = build_manifest(model, stats, arguments)
    arguments.manifest.resolve().write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps({"fem": str(arguments.output.resolve()), "manifest": str(arguments.manifest.resolve()), **stats}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
