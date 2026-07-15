#!/usr/bin/env python3
"""Generate two shell-mesh planes for closed-boundary weld benchmarks.

The upper plane is a regular CQUAD4 mesh with many isolated, differently
sized regions removed.  Every removed region is therefore a closed free-edge
loop in the existing mesh.  The lower plane is complete and is intended to be
the common imprint/target component for Mesh Seam Weld.

Only the Python standard library is required (Python 3.8+).
"""

from __future__ import annotations

import argparse
import json
import math
import random
from collections import Counter, defaultdict, deque
from dataclasses import dataclass
from pathlib import Path
from typing import DefaultDict, Dict, Iterable, List, Sequence, Set, Tuple

Point = Tuple[float, float, float]
Cell = Tuple[int, int]
Edge = Tuple[int, int]


@dataclass(frozen=True)
class Hole:
    hole_id: int
    x: float
    y: float
    radius: float
    grid_i: int
    grid_j: int


@dataclass(frozen=True)
class Element:
    element_id: int
    property_id: int
    nodes: Tuple[int, int, int, int]


@dataclass
class PlaneMesh:
    name: str
    component_id: int
    property_id: int
    z: float
    nodes: Dict[int, Point]
    elements: List[Element]


def positive_float(value: str) -> float:
    result = float(value)
    if result <= 0.0:
        raise argparse.ArgumentTypeError("value must be positive")
    return result


def positive_int(value: str) -> int:
    result = int(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("value must be a positive integer")
    return result


def build_holes(args: argparse.Namespace) -> List[Hole]:
    nx = int(round(args.width / args.mesh_size))
    ny = int(round(args.height / args.mesh_size))
    half_cells = args.circle_segments // 8
    patch_half_width = half_cells * args.mesh_size
    clearance = max(args.clearance, args.mesh_size)
    if args.circle_segments < 16 or args.circle_segments % 8:
        raise ValueError("circle-segments must be at least 16 and divisible by 8")
    if args.radial_layers < 1:
        raise ValueError("radial-layers must be positive")
    if args.max_radius >= patch_half_width - 0.25 * args.mesh_size:
        raise ValueError(
            "max-radius {:.3g} is too large for the circular transition patch; "
            "use max-radius < {:.3g} or increase circle-segments".format(
                args.max_radius, patch_half_width - 0.25 * args.mesh_size
            )
        )
    if args.min_radius > args.max_radius:
        raise ValueError("min-radius must not exceed max-radius")
    if args.min_radius < 0.70 * args.mesh_size:
        raise ValueError("min-radius must be at least 0.70 * mesh-size")

    rng = random.Random(args.seed)
    holes: List[Hole] = []
    hole_id = 0
    for row in range(args.holes_y):
        for column in range(args.holes_x):
            hole_id += 1
            # A deterministic shuffle gives each neighborhood a mixture of
            # small and large holes while retaining generous separation.
            fraction = rng.random()
            radius = args.min_radius + (args.max_radius - args.min_radius) * fraction
            grid_i = int(round((column + 0.5) * nx / args.holes_x))
            grid_j = int(round((row + 0.5) * ny / args.holes_y))
            holes.append(Hole(hole_id, grid_i * args.mesh_size, grid_j * args.mesh_size, radius, grid_i, grid_j))

    centers_i = sorted({hole.grid_i for hole in holes})
    centers_j = sorted({hole.grid_j for hole in holes})
    if centers_i[0] < half_cells or nx - centers_i[-1] < half_cells:
        raise ValueError("circular transition patch reaches the left or right plate edge")
    if centers_j[0] < half_cells or ny - centers_j[-1] < half_cells:
        raise ValueError("circular transition patch reaches the top or bottom plate edge")
    min_dx = min((b - a) * args.mesh_size for a, b in zip(centers_i, centers_i[1:])) if len(centers_i) > 1 else args.width
    min_dy = min((b - a) * args.mesh_size for a, b in zip(centers_j, centers_j[1:])) if len(centers_j) > 1 else args.height
    required_pitch = 2.0 * patch_half_width + clearance
    if min(min_dx, min_dy) + 1.0e-9 < required_pitch:
        raise ValueError(
            "circular transition patches overlap: minimum center pitch {:.3g}, required {:.3g}; "
            "reduce hole count/clearance or circle-segments".format(min(min_dx, min_dy), required_pitch)
        )
    return holes


def square_boundary(center_i: int, center_j: int, half_cells: int) -> List[Tuple[int, int]]:
    """Return grid points around a square in counter-clockwise order."""
    left, right = center_i - half_cells, center_i + half_cells
    bottom, top = center_j - half_cells, center_j + half_cells
    points = [(i, bottom) for i in range(left, right)]
    points += [(right, j) for j in range(bottom, top)]
    points += [(i, top) for i in range(right, left, -1)]
    points += [(left, j) for j in range(top, bottom, -1)]
    return points


def build_plane(
    name: str,
    component_id: int,
    property_id: int,
    z: float,
    width: float,
    height: float,
    mesh_size: float,
    skipped_cells: Set[Cell],
    first_node_id: int,
    first_element_id: int,
) -> PlaneMesh:
    nx = int(round(width / mesh_size))
    ny = int(round(height / mesh_size))
    node_ids: Dict[Tuple[int, int], int] = {}
    used_grid_points: Set[Tuple[int, int]] = set()
    kept_cells = [
        (i, j)
        for j in range(ny)
        for i in range(nx)
        if (i, j) not in skipped_cells
    ]
    for i, j in kept_cells:
        used_grid_points.update(((i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)))

    nodes: Dict[int, Point] = {}
    next_node_id = first_node_id
    for i, j in sorted(used_grid_points, key=lambda item: (item[1], item[0])):
        node_ids[(i, j)] = next_node_id
        nodes[next_node_id] = (i * mesh_size, j * mesh_size, z)
        next_node_id += 1

    elements: List[Element] = []
    next_element_id = first_element_id
    for i, j in kept_cells:
        elements.append(
            Element(
                next_element_id,
                property_id,
                (
                    node_ids[(i, j)],
                    node_ids[(i + 1, j)],
                    node_ids[(i + 1, j + 1)],
                    node_ids[(i, j + 1)],
                ),
            )
        )
        next_element_id += 1
    return PlaneMesh(name, component_id, property_id, z, nodes, elements)


def build_perforated_plane(
    holes: Sequence[Hole], args: argparse.Namespace, first_node_id: int = 1,
    first_element_id: int = 1,
) -> Tuple[PlaneMesh, int]:
    """Build regular background quads plus conformal circular-hole patches."""
    nx = int(round(args.width / args.mesh_size))
    ny = int(round(args.height / args.mesh_size))
    half_cells = args.circle_segments // 8
    patch_cells: Set[Cell] = set()
    for hole in holes:
        for j in range(hole.grid_j - half_cells, hole.grid_j + half_cells):
            for i in range(hole.grid_i - half_cells, hole.grid_i + half_cells):
                patch_cells.add((i, j))

    nodes: Dict[int, Point] = {}
    grid_nodes: Dict[Tuple[int, int], int] = {}
    elements: List[Element] = []
    next_node_id = first_node_id
    next_element_id = first_element_id

    def grid_node(i: int, j: int) -> int:
        nonlocal next_node_id
        key = (i, j)
        if key not in grid_nodes:
            grid_nodes[key] = next_node_id
            nodes[next_node_id] = (i * args.mesh_size, j * args.mesh_size, args.gap)
            next_node_id += 1
        return grid_nodes[key]

    for j in range(ny):
        for i in range(nx):
            if (i, j) in patch_cells:
                continue
            elements.append(Element(next_element_id, 1, (
                grid_node(i, j), grid_node(i + 1, j),
                grid_node(i + 1, j + 1), grid_node(i, j + 1),
            )))
            next_element_id += 1

    for hole in holes:
        outer_grid = square_boundary(hole.grid_i, hole.grid_j, half_cells)
        if len(outer_grid) != args.circle_segments:
            raise ValueError("internal error: square boundary does not match circle-segments")
        outer_points = [(i * args.mesh_size, j * args.mesh_size, args.gap) for i, j in outer_grid]
        inner_points: List[Point] = []
        for x, y, z in outer_points:
            dx, dy = x - hole.x, y - hole.y
            length = math.hypot(dx, dy)
            inner_points.append((hole.x + hole.radius * dx / length, hole.y + hole.radius * dy / length, z))

        rings: List[List[int]] = []
        inner_ids: List[int] = []
        for point in inner_points:
            inner_ids.append(next_node_id)
            nodes[next_node_id] = point
            next_node_id += 1
        rings.append(inner_ids)
        for layer in range(1, args.radial_layers):
            fraction = layer / float(args.radial_layers)
            ring: List[int] = []
            for inner, outer in zip(inner_points, outer_points):
                ring.append(next_node_id)
                nodes[next_node_id] = tuple(inner[k] + fraction * (outer[k] - inner[k]) for k in range(3))
                next_node_id += 1
            rings.append(ring)
        rings.append([grid_node(i, j) for i, j in outer_grid])

        for layer in range(len(rings) - 1):
            inner_ring, outer_ring = rings[layer], rings[layer + 1]
            for index in range(args.circle_segments):
                following = (index + 1) % args.circle_segments
                elements.append(Element(next_element_id, 1, (
                    outer_ring[index], outer_ring[following],
                    inner_ring[following], inner_ring[index],
                )))
                next_element_id += 1
    return PlaneMesh("PERFORATED_SOURCE_SHELL", 1, 1, args.gap, nodes, elements), len(patch_cells)


def free_edge_loops(mesh: PlaneMesh) -> List[List[int]]:
    owners: Counter[Edge] = Counter()
    for element in mesh.elements:
        n = element.nodes
        for a, b in ((n[0], n[1]), (n[1], n[2]), (n[2], n[3]), (n[3], n[0])):
            owners[tuple(sorted((a, b)))] += 1
    adjacency: DefaultDict[int, Set[int]] = defaultdict(set)
    for (a, b), count in owners.items():
        if count == 1:
            adjacency[a].add(b)
            adjacency[b].add(a)
    invalid = [node for node, neighbors in adjacency.items() if len(neighbors) != 2]
    if invalid:
        raise ValueError(
            "free-edge topology is not closed/manifold at {} nodes; first node {} has degree {}".format(
                len(invalid), invalid[0], len(adjacency[invalid[0]])
            )
        )

    loops: List[List[int]] = []
    unseen = set(adjacency)
    while unseen:
        start = min(unseen)
        loop: List[int] = []
        queue = deque([start])
        unseen.remove(start)
        while queue:
            node = queue.popleft()
            loop.append(node)
            for neighbor in adjacency[node]:
                if neighbor in unseen:
                    unseen.remove(neighbor)
                    queue.append(neighbor)
        loops.append(loop)
    return loops


def validate_quad_areas(mesh: PlaneMesh) -> None:
    for element in mesh.elements:
        points = [mesh.nodes[node_id] for node_id in element.nodes]
        signed_area = 0.5 * sum(
            points[index][0] * points[(index + 1) % 4][1]
            - points[(index + 1) % 4][0] * points[index][1]
            for index in range(4)
        )
        if signed_area <= 1.0e-10:
            raise ValueError(
                "element {} is degenerate or reversed (signed XY area {})".format(
                    element.element_id, signed_area
                )
            )


def fmt(value: float) -> str:
    return "{:.9g}".format(value)


def write_fem(path: Path, planes: Iterable[PlaneMesh], args: argparse.Namespace) -> None:
    planes = list(planes)
    lines = [
        "$ Mesh Seam Weld many-closed-boundaries performance deck",
        "$ Upper component: perforated source shell; lower component: complete target shell",
        "$ Generated by examples/MeshSeamWeld_ManyHoles/generate_fem.py",
        "BEGIN BULK",
        '$HMNAME MAT 1 "BENCHMARK_STEEL"',
        "MAT1,1,210000.0,,0.3,7.85E-9",
    ]
    for plane in planes:
        lines.extend(
            (
                '$HMNAME PROP {} "{}_PSHELL"'.format(plane.property_id, plane.name),
                "PSHELL,{},1,{}".format(plane.property_id, fmt(args.shell_thickness)),
                '$HMNAME COMP {} "{}"'.format(plane.component_id, plane.name),
                "$HWCOLOR COMP {} {}".format(
                    plane.component_id, 3 if plane.component_id == 1 else 6
                ),
            )
        )
    for plane in planes:
        lines.append("$ NODES: {}".format(plane.name))
        for node_id, (x, y, z) in sorted(plane.nodes.items()):
            lines.append("GRID,{},,{},{},{}".format(node_id, fmt(x), fmt(y), fmt(z)))
        lines.extend(("$HMCOMP ID {}".format(plane.component_id), "$ ELEMENTS: " + plane.name))
        for element in plane.elements:
            lines.append(
                "CQUAD4,{},{},{},{},{},{}".format(
                    element.element_id, element.property_id, *element.nodes
                )
            )
    lines.extend(("ENDDATA", ""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=here / "MeshSeamWeld_ManyHoles.fem")
    parser.add_argument("--manifest", type=Path, default=here / "MeshSeamWeld_ManyHoles_manifest.json")
    parser.add_argument("--width", type=positive_float, default=1800.0)
    parser.add_argument("--height", type=positive_float, default=1200.0)
    parser.add_argument("--mesh-size", type=positive_float, default=5.0)
    parser.add_argument("--gap", type=positive_float, default=8.0)
    parser.add_argument("--shell-thickness", type=positive_float, default=1.0)
    parser.add_argument("--holes-x", type=positive_int, default=30)
    parser.add_argument("--holes-y", type=positive_int, default=20)
    parser.add_argument("--min-radius", type=positive_float, default=5.0)
    parser.add_argument("--max-radius", type=positive_float, default=18.0)
    parser.add_argument("--clearance", type=positive_float, default=10.0)
    parser.add_argument("--circle-segments", type=positive_int, default=40)
    parser.add_argument("--radial-layers", type=positive_int, default=2)
    parser.add_argument("--seed", type=int, default=20260715)
    args = parser.parse_args()
    for dimension in ("width", "height"):
        value = getattr(args, dimension)
        cells = value / args.mesh_size
        if abs(cells - round(cells)) > 1.0e-9:
            parser.error("{} must be an integer multiple of mesh-size".format(dimension))
    return args


def main() -> int:
    args = parse_args()
    holes = build_holes(args)
    upper, replaced_background_cells = build_perforated_plane(holes, args)
    lower = build_plane(
        "COMPLETE_TARGET_SHELL", 2, 2, 0.0, args.width, args.height,
        args.mesh_size, set(), max(upper.nodes) + 1,
        max(element.element_id for element in upper.elements) + 1,
    )
    upper_loops = free_edge_loops(upper)
    lower_loops = free_edge_loops(lower)
    validate_quad_areas(upper)
    validate_quad_areas(lower)
    expected_upper_loops = len(holes) + 1  # holes plus the plate perimeter
    if len(upper_loops) != expected_upper_loops:
        raise ValueError(
            "expected {} upper free-edge loops, found {}; reduce max-radius or increase clearance".format(
                expected_upper_loops, len(upper_loops)
            )
        )
    if len(lower_loops) != 1:
        raise ValueError("complete target plane must have exactly one perimeter loop")

    output = args.output.resolve()
    manifest_path = args.manifest.resolve()
    write_fem(output, (upper, lower), args)
    manifest = {
        "schema_version": "1.0",
        "purpose": "Mesh Seam Weld closed-boundary performance benchmark",
        "fem": str(output),
        "parameters": {
            key: getattr(args, key)
            for key in (
                "width", "height", "mesh_size", "gap", "shell_thickness",
                "holes_x", "holes_y", "min_radius", "max_radius", "clearance",
                "circle_segments", "radial_layers", "seed"
            )
        },
        "statistics": {
            "requested_holes": len(holes),
            "verified_hole_loops": len(upper_loops) - 1,
            "upper_free_edge_loops_including_perimeter": len(upper_loops),
            "lower_free_edge_loops_including_perimeter": len(lower_loops),
            "replaced_background_cells": replaced_background_cells,
            "circle_segments_per_hole": args.circle_segments,
            "radial_transition_layers": args.radial_layers,
            "upper_nodes": len(upper.nodes),
            "upper_elements": len(upper.elements),
            "lower_nodes": len(lower.nodes),
            "lower_elements": len(lower.elements),
            "total_nodes": len(upper.nodes) + len(lower.nodes),
            "total_elements": len(upper.elements) + len(lower.elements),
        },
        "components": {
            "1": "PERFORATED_SOURCE_SHELL",
            "2": "COMPLETE_TARGET_SHELL",
        },
        "holes": [
            {
                "id": hole.hole_id,
                "center": [hole.x, hole.y, args.gap],
                "nominal_radius": hole.radius,
                "circle_segments": args.circle_segments,
                "radial_transition_layers": args.radial_layers,
            }
            for hole in holes
        ],
    }
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"fem": str(output), "manifest": str(manifest_path), **manifest["statistics"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
