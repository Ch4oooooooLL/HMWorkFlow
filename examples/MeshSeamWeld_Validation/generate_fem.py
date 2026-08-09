#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate the Mesh Seam Weld validation FEM deck.

Eight scenarios laid out along the global X axis (pitch 400 mm).  Each
scenario contains shell components with NO shared nodes between components.
Deterministic (fixed random seed); requires only the Python standard library
(Python 3.8+).

Run from the repository root:
    runtime/python/windows-x64/python.exe examples/MeshSeamWeld_Validation/generate_fem.py

Scenario matrix (see README.md for the full description):
    C01  source plate with 7 circular holes + complete target  (manual closed loops)
    C02  source straight free edge + target plate              (manual open path)
    C03  source 45-degree polyline free edge + target plate     (manual open polyline)
    C04  vertical rib on base plate (90 deg)                    (FAST_AUTO T_PATH)
    C05  overlapping parallel plates (lap, normals parallel)    (FAST_AUTO L_SURF)
    C06  source/target gap 30 mm > search_distance 12           (FAST_AUTO no candidate)
    C07  short flange edge (qualified length < min_seam_length) (FAST_AUTO rejected)
    C08  pre-existing SEAM_T1 strip 3 mm from source edge       (FAST_AUTO dedup)

The generator writes the .fem deck and the *_manifest.json, and runs an
embedded module-like analysis (free-edge qualified regions, joint type and
confidence) that must match the expected results before anything is written.
"""

from __future__ import annotations

import argparse
import json
import math
import random
from collections import Counter, defaultdict, deque
from pathlib import Path
from typing import DefaultDict, Dict, List, Sequence, Set, Tuple

Point = Tuple[float, float, float]

# ---------------------------------------------------------------------------
# Module parameters mirrored from config/mesh_seam_auto_rules.txt
# ---------------------------------------------------------------------------
MODULE_SETTINGS = {
    "search_distance": 12.0,
    "min_seam_length": 20.0,
    "min_path_nodes": 3,
    "parallel_angle_max": 15.0,
    "perpendicular_angle_min": 70.0,
    "max_distance_variation_ratio": 0.35,
    "existing_path_search_width": 20.0,
    "max_target_path_offset": 8.0,
    "existing_weld_search_distance": 4.0,
    "exclude_existing_welds": 1,
    "auto_accept_confidence": 0.88,
    "review_confidence": 0.60,
}


class Element:
    __slots__ = ("elem_id", "prop_id", "nodes")

    def __init__(self, elem_id: int, prop_id: int, nodes: Tuple[int, int, int, int]):
        self.elem_id = elem_id
        self.prop_id = prop_id
        self.nodes = nodes


class Component:
    __slots__ = ("comp_id", "name", "prop_id", "thickness", "color", "elements")

    def __init__(self, comp_id: int, name: str, prop_id: int, thickness: float,
                 color: int, elements: List[Element]):
        self.comp_id = comp_id
        self.name = name
        self.prop_id = prop_id
        self.thickness = thickness
        self.color = color
        self.elements = elements


class Model:
    def __init__(self) -> None:
        self.nodes: Dict[int, Point] = {}
        self.components: Dict[int, Component] = {}
        self.next_node = 1
        self.next_elem = 1

    def add_node(self, x: float, y: float, z: float) -> int:
        node_id = self.next_node
        self.next_node += 1
        self.nodes[node_id] = (float(x), float(y), float(z))
        return node_id

    def new_component(self, name: str, thickness: float, color: int) -> Component:
        comp_id = len(self.components) + 1
        comp = Component(comp_id, name, comp_id, thickness, color, [])
        self.components[comp_id] = comp
        return comp

    def add_elem(self, comp: Component, node_tuple: Tuple[int, int, int, int]) -> Element:
        element = Element(self.next_elem, comp.prop_id, tuple(node_tuple))
        self.next_elem += 1
        comp.elements.append(element)
        return element


def dist3(a: Point, b: Point) -> float:
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


# ---------------------------------------------------------------------------
# Structured mesh builders (all quads, deterministic by construction)
# ---------------------------------------------------------------------------

def build_rect(model: Model, comp: Component, x0: float, y0: float, z: float,
               width: float, height: float, mesh: float) -> None:
    """Rectangle in the XY plane at constant z."""
    nx = int(round(width / mesh))
    ny = int(round(height / mesh))
    if abs(width - nx * mesh) > 1.0e-6 or abs(height - ny * mesh) > 1.0e-6:
        raise ValueError("rect width/height must be integer multiples of mesh")
    alloc: Dict[Tuple[int, int], int] = {}

    def node(i: int, j: int) -> int:
        key = (i, j)
        nid = alloc.get(key)
        if nid is None:
            nid = model.add_node(x0 + i * mesh, y0 + j * mesh, z)
            alloc[key] = nid
        return nid

    for j in range(ny):
        for i in range(nx):
            model.add_elem(comp, (node(i, j), node(i + 1, j),
                                  node(i + 1, j + 1), node(i, j + 1)))


def build_vertical_rect(model: Model, comp: Component, x0: float, y_fixed: float,
                        z0: float, width_x: float, height_z: float, mesh: float) -> None:
    """Rectangle in the XZ plane at fixed y (vertical rib plate)."""
    nx = int(round(width_x / mesh))
    nz = int(round(height_z / mesh))
    if abs(width_x - nx * mesh) > 1.0e-6 or abs(height_z - nz * mesh) > 1.0e-6:
        raise ValueError("vertical rect dimensions must be integer multiples of mesh")
    alloc: Dict[Tuple[int, int], int] = {}

    def node(i: int, j: int) -> int:
        key = (i, j)
        nid = alloc.get(key)
        if nid is None:
            nid = model.add_node(x0 + i * mesh, y_fixed, z0 + j * mesh)
            alloc[key] = nid
        return nid

    for j in range(nz):
        for i in range(nx):
            model.add_elem(comp, (node(i, j), node(i + 1, j),
                                  node(i + 1, j + 1), node(i, j + 1)))


def build_chamfer_pentagon(model: Model, comp: Component, x0: float, y0: float,
                           z: float, width: float, height: float, chamfer: float,
                           mesh: float) -> None:
    """Pentagon plate with a single 45-degree chamfer at the top-right corner.

    Vertices (local, CCW): (0,0), (W,0), (W,H-C), (W-C,H), (0,H).
    The free-edge polyline along the right side then the chamfer has one
    45-degree bend and is the manual open-polyline scenario (C03).
    """
    nx = int(round(width / mesh))
    ny_rect = int(round((height - chamfer) / mesh))
    ny_top = int(round(chamfer / mesh))
    if ny_rect < 1 or ny_top < 1:
        raise ValueError("chamfer and body must each hold at least one cell")
    alloc: Dict[Tuple[float, float], int] = {}

    def node(x: float, y: float) -> int:
        key = (round(x, 6), round(y, 6))
        nid = alloc.get(key)
        if nid is None:
            nid = model.add_node(x0 + x, y0 + y, z)
            alloc[key] = nid
        return nid

    # Bottom rectangle [0,W] x [0, H-C]
    for j in range(ny_rect):
        for i in range(nx):
            model.add_elem(comp, (
                node(i * mesh, j * mesh), node((i + 1) * mesh, j * mesh),
                node((i + 1) * mesh, (j + 1) * mesh), node(i * mesh, (j + 1) * mesh)))

    # Top trapezoid: bottom y = H-C (x 0..W), top y = H (x 0..W-C).
    # The right boundary of the trapezoid lies exactly on the 45-degree chamfer.
    y_b = height - chamfer
    for k in range(ny_top):
        y0r = y_b + (k + 0) * chamfer / ny_top
        y1r = y_b + (k + 1) * chamfer / ny_top
        x_w0 = width - (y0r - y_b)  # right boundary x at row k (on chamfer)
        x_w1 = width - (y1r - y_b)
        for i in range(nx):
            x00 = x_w0 * i / nx
            x01 = x_w0 * (i + 1) / nx
            x10 = x_w1 * i / nx
            x11 = x_w1 * (i + 1) / nx
            model.add_elem(comp, (
                node(x00, y0r), node(x01, y0r), node(x11, y1r), node(x10, y1r)))


def build_perforated_plate(model: Model, comp: Component, x0: float, y0: float,
                           z: float, width: float, height: float, mesh: float,
                           holes: Sequence[Tuple[int, int, float]],
                           circle_segments: int = 24, radial_layers: int = 2) -> None:
    """Regular background quad plate with conformal circular-hole patches.

    holes: list of (grid_i, grid_j, radius).  Each removed hole becomes a
    closed free-edge loop in the mesh (manual closed-loop weld scenario C01).
    """
    nx = int(round(width / mesh))
    ny = int(round(height / mesh))
    half = circle_segments // 8
    if circle_segments < 16 or circle_segments % 8:
        raise ValueError("circle_segments must be >= 16 and divisible by 8")
    if radial_layers < 1:
        raise ValueError("radial_layers must be positive")
    patch_cells: Set[Tuple[int, int]] = set()
    for gx, gy, radius in holes:
        if radius >= half * mesh - 0.25 * mesh:
            raise ValueError("hole radius too large for the transition patch")
        left, right = gx - half, gx + half
        bottom, top = gy - half, gy + half
        if left < 0 or right > nx or bottom < 0 or top > ny:
            raise ValueError("hole patch reaches the plate edge")
        for j in range(bottom, top):
            for i in range(left, right):
                cell = (i, j)
                if cell in patch_cells:
                    raise ValueError("hole transition patches overlap; reduce hole count")
                patch_cells.add(cell)

    alloc: Dict[Tuple[float, float], int] = {}

    def node(x: float, y: float) -> int:
        key = (round(x, 6), round(y, 6))
        nid = alloc.get(key)
        if nid is None:
            nid = model.add_node(x, y, z)
            alloc[key] = nid
        return nid

    # Background grid, skipping patch cells.
    for j in range(ny):
        for i in range(nx):
            if (i, j) in patch_cells:
                continue
            model.add_elem(comp, (
                node(x0 + i * mesh, y0 + j * mesh),
                node(x0 + (i + 1) * mesh, y0 + j * mesh),
                node(x0 + (i + 1) * mesh, y0 + (j + 1) * mesh),
                node(x0 + i * mesh, y0 + (j + 1) * mesh)))

    # Conformal circular patches.
    for gx, gy, radius in holes:
        cx = x0 + gx * mesh
        cy = y0 + gy * mesh
        left, right = gx - half, gx + half
        bottom, top = gy - half, gy + half
        square = [(i, bottom) for i in range(left, right)]
        square += [(right, j) for j in range(bottom, top)]
        square += [(i, top) for i in range(right, left, -1)]
        square += [(left, j) for j in range(top, bottom, -1)]
        if len(square) != circle_segments:
            raise ValueError("internal error: square boundary length mismatch")
        outer = [(x0 + i * mesh, y0 + j * mesh) for i, j in square]
        inner: List[Point] = []
        for px, py in outer:
            dx, dy = px - cx, py - cy
            length = math.hypot(dx, dy)
            if length < 1.0e-9:
                raise ValueError("hole center coincides with patch boundary")
            inner.append((cx + radius * dx / length, cy + radius * dy / length))

        rings: List[List[int]] = [
            [node(inner[k][0], inner[k][1]) for k in range(circle_segments)]]
        for layer in range(1, radial_layers):
            fraction = layer / float(radial_layers)
            rings.append([node(
                inner[k][0] + fraction * (outer[k][0] - inner[k][0]),
                inner[k][1] + fraction * (outer[k][1] - inner[k][1]))
                for k in range(circle_segments)])
        rings.append([node(outer[k][0], outer[k][1]) for k in range(circle_segments)])

        for layer in range(len(rings) - 1):
            inner_ring, outer_ring = rings[layer], rings[layer + 1]
            for k in range(circle_segments):
                following = (k + 1) % circle_segments
                model.add_elem(comp, (
                    outer_ring[k], outer_ring[following],
                    inner_ring[following], inner_ring[k]))


def build_bent_plate_with_flange(model: Model, comp: Component, x0: float, y0: float,
                                 z_plate: float, width: float, depth: float, mesh: float,
                                 flange_x0: float, flange_x1: float,
                                 flange_z_bottom: float) -> None:
    """Bent plate: horizontal main plate at z_plate plus a short vertical flange
    hanging below its front edge (y = depth) from z_plate down to flange_z_bottom.

    The flange's free edges total far less than min_seam_length, which exercises
    the FAST_AUTO rejection path (scenario C07).
    """
    nx = int(round(width / mesh))
    ny = int(round(depth / mesh))
    nz = int(round((z_plate - flange_z_bottom) / mesh))
    if nx < 1 or ny < 1 or nz < 1:
        raise ValueError("plate/flange must hold at least one cell")
    alloc: Dict[Tuple[float, float, float], int] = {}

    def node(x: float, y: float, z: float) -> int:
        key = (round(x, 6), round(y, 6), round(z, 6))
        nid = alloc.get(key)
        if nid is None:
            nid = model.add_node(x0 + x, y0 + y, z)
            alloc[key] = nid
        return nid

    for j in range(ny):
        for i in range(nx):
            model.add_elem(comp, (
                node(i * mesh, j * mesh, z_plate), node((i + 1) * mesh, j * mesh, z_plate),
                node((i + 1) * mesh, (j + 1) * mesh, z_plate),
                node(i * mesh, (j + 1) * mesh, z_plate)))

    # Flange in the XZ plane at y = depth, sharing the plate front-edge nodes.
    fxs = (flange_x0, flange_x1)
    for k in range(nz):
        z_lo = z_plate - (k + 1) * mesh
        z_hi = z_plate - k * mesh
        model.add_elem(comp, (
            node(fxs[0], depth, z_hi), node(fxs[1], depth, z_hi),
            node(fxs[1], depth, z_lo), node(fxs[0], depth, z_lo)))


# ---------------------------------------------------------------------------
# Topology analysis (mirrors shell_weld_detection.py / auto_detector.py)
# ---------------------------------------------------------------------------

def free_edge_loops(nodes: Dict[int, Point], elements: Sequence[Element]) -> List[List[int]]:
    """Return closed manifold free-edge loops; raise if the boundary is not closed."""
    owners: Counter[Tuple[int, int]] = Counter()
    for element in elements:
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
            "free-edge topology is not closed/manifold at {} nodes; first node {} "
            "has degree {}".format(len(invalid), invalid[0], len(adjacency[invalid[0]])))
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


def loop_length(loop: Sequence[int], nodes: Dict[int, Point]) -> float:
    return sum(dist3(nodes[loop[i]], nodes[loop[(i + 1) % len(loop)]])
               for i in range(len(loop)))


def tri_normal(p0: Point, p1: Point, p2: Point) -> Point:
    a = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
    b = (p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2])
    cross = (a[1] * b[2] - a[2] * b[1],
             a[2] * b[0] - a[0] * b[2],
             a[0] * b[1] - a[1] * b[0])
    length = math.sqrt(sum(v * v for v in cross))
    if length <= 1.0e-12:
        raise ValueError("degenerate triangle normal")
    return tuple(v / length for v in cross)


def representative_normal(element_ids: Sequence[int], elements_by_id: Dict[int, Element],
                          nodes: Dict[int, Point]):
    values = []
    for element_id in sorted(element_ids):
        element = elements_by_id[element_id]
        n = element.nodes
        if len(n) < 3:
            continue
        try:
            values.append(tri_normal(nodes[n[0]], nodes[n[1]], nodes[n[2]]))
        except ValueError:
            continue
    if not values:
        return None
    reference = values[0]
    aligned = [tuple(-v for v in value) if sum(value[i] * reference[i]
                                               for i in range(3)) < 0 else value
               for value in values]
    average = tuple(sum(value[i] for value in aligned) / len(aligned) for i in range(3))
    length = math.sqrt(sum(v * v for v in average))
    return tuple(v / length for v in average) if length > 1.0e-12 else None


def angle_degrees(a: Point, b: Point) -> float:
    dot = sum(a[i] * b[i] for i in range(3))
    dot = max(-1.0, min(1.0, dot))
    return math.degrees(math.acos(dot))


def component_node_set(comp: Component) -> Set[int]:
    return {node_id for element in comp.elements for node_id in element.nodes}


def extract_qualified_regions(source_elems: Sequence[Element],
                              source_nodes: Dict[int, Point],
                              target_nodes: Dict[int, Point],
                              settings: Dict[str, float]) -> List[Dict]:
    """Replicate module region extraction: connected source free edges whose two
    endpoints are each within search_distance of any target node; regions shorter
    than min_seam_length or with fewer than min_path_nodes nodes are dropped."""
    owners: Counter[Tuple[int, int]] = Counter()
    elem_for_edge: Dict[Tuple[int, int], int] = {}
    for element in source_elems:
        n = element.nodes
        for a, b in ((n[0], n[1]), (n[1], n[2]), (n[2], n[3]), (n[3], n[0])):
            key = tuple(sorted((a, b)))
            owners[key] += 1
            elem_for_edge[key] = element.elem_id
    free_edges = [(a, b) for (a, b), count in owners.items() if count == 1]
    maximum = float(settings["search_distance"])
    target_coords = list(target_nodes.values())
    nearest_cache: Dict[int, float] = {}

    def nearest(node_id: int) -> float:
        value = nearest_cache.get(node_id)
        if value is None:
            value = min(dist3(source_nodes[node_id], t) for t in target_coords)
            nearest_cache[node_id] = value
        return value

    qualified: List[Tuple[int, int, float, float]] = []
    for a, b in free_edges:
        d1, d2 = nearest(a), nearest(b)
        if d1 <= maximum and d2 <= maximum:
            qualified.append((a, b, d1, d2))

    by_node: DefaultDict[int, List[int]] = defaultdict(list)
    for index, (a, b, _, _) in enumerate(qualified):
        by_node[a].append(index)
        by_node[b].append(index)
    remaining = set(range(len(qualified)))
    regions: List[Dict] = []
    while remaining:
        seed = min(remaining)
        remaining.remove(seed)
        group = [seed]
        queue = deque([seed])
        while queue:
            a, b, _, _ = qualified[queue.popleft()]
            for node_id in (a, b):
                for neighbor in by_node[node_id]:
                    if neighbor in remaining:
                        remaining.remove(neighbor)
                        group.append(neighbor)
                        queue.append(neighbor)
        rows = [qualified[i] for i in group]
        source_node_ids = sorted({n for a, b, _, _ in rows for n in (a, b)})
        length = sum(dist3(source_nodes[a], source_nodes[b]) for a, b, _, _ in rows)
        if (len(source_node_ids) < int(settings["min_path_nodes"])
                or length < float(settings["min_seam_length"])):
            continue
        distances = [value for _, _, d1, d2 in rows for value in (d1, d2)]
        source_element_ids = sorted(
            {elem_for_edge[tuple(sorted((a, b)))] for a, b, _, _ in rows})
        centers = [source_nodes[node_id] for node_id in source_node_ids]
        regions.append({
            "source_node_ids": source_node_ids,
            "source_element_ids": source_element_ids,
            "region_length": round(length, 9),
            "minimum_distance": round(min(distances), 9),
            "average_distance": round(sum(distances) / len(distances), 9),
            "maximum_distance": round(max(distances), 9),
            "region_center": [round(sum(p[axis] for p in centers) / len(centers), 9)
                              for axis in range(3)],
        })
    return regions


def compute_pair_analysis(source_comp: Component, target_comp: Component,
                          nodes: Dict[int, Point],
                          settings: Dict[str, float]) -> List[Dict]:
    """Full mini-analysis per directed pair: regions + joint classification.

    Mirrors auto_detector.detect_candidates for a single (source -> target) pair.
    """
    source_elems_by_id = {e.elem_id: e for e in source_comp.elements}
    target_elems_by_id = {e.elem_id: e for e in target_comp.elements}

    # Target free-edge node set (for CONNECT vs T_PATH boundary detection).
    target_owners: Counter[Tuple[int, int]] = Counter()
    for element in target_comp.elements:
        n = element.nodes
        for a, b in ((n[0], n[1]), (n[1], n[2]), (n[2], n[3]), (n[3], n[0])):
            target_owners[tuple(sorted((a, b)))] += 1
    target_free_node_ids = {node for (a, b), count in target_owners.items()
                            if count == 1 for node in (a, b)}

    # Target node -> adjacent elements (for target_near_element_ids).
    target_node_to_elems: DefaultDict[int, Set[int]] = defaultdict(set)
    for element in target_comp.elements:
        for node_id in element.nodes:
            target_node_to_elems[node_id].add(element.elem_id)

    target_node_ids = component_node_set(target_comp)
    target_coords = {node_id: nodes[node_id] for node_id in target_node_ids}

    regions = extract_qualified_regions(source_comp.elements, nodes,
                                        target_coords, settings)

    results = []
    for region in regions:
        source_normal = representative_normal(region["source_element_ids"],
                                              source_elems_by_id, nodes)
        # Nearest target node per region source node, then adjacent target elements
        # (mirrors region target_near_node_ids / target_near_element_ids).
        target_near_nodes: Set[int] = set()
        for node_id in region["source_node_ids"]:
            nearest_target = min(target_node_ids,
                                 key=lambda n: dist3(nodes[node_id], nodes[n]))
            target_near_nodes.add(nearest_target)
        region["target_near_node_ids"] = sorted(target_near_nodes)
        target_near_elements = sorted(
            {element_id for node_id in target_near_nodes
             for element_id in target_node_to_elems[node_id]})
        region["target_near_element_ids"] = target_near_elements
        target_normal = representative_normal(target_near_elements,
                                              target_elems_by_id, nodes)

        distances = (region["minimum_distance"], region["average_distance"],
                     region["maximum_distance"])
        variation = ((distances[2] - distances[0]) / max(distances[1], 1.0e-9))

        if source_normal is None or target_normal is None:
            results.append({"joint_type": "REVIEW", "confidence": 0.0,
                            "reasons": ["unstable or degenerate local normal"],
                            "normal_angle_degrees": None,
                            "warnings": [], "region": region,
                            "variation_ratio": round(variation, 6)})
            continue

        angle = angle_degrees(source_normal, target_normal)
        parallel = float(settings["parallel_angle_max"])
        perpendicular = float(settings["perpendicular_angle_min"])
        boundary_hits = sum(1 for node_id in region["target_near_node_ids"]
                            if node_id in target_free_node_ids)
        near_boundary = (bool(region["target_near_node_ids"])
                         and boundary_hits / float(len(region["target_near_node_ids"])) >= 0.8)
        warnings = []
        if variation > float(settings["max_distance_variation_ratio"]):
            warnings.append("distance variation exceeds configured ratio")

        if angle <= parallel:
            joint_type = "L_SURF"
            reasons = ["local shell normals are parallel"]
        elif angle >= perpendicular:
            joint_type = "CONNECT" if near_boundary else "T_PATH"
            reasons = ["both paths are free edges" if near_boundary
                       else "source free edge projects to target shell interior"]
        else:
            results.append({"joint_type": "REVIEW",
                            "confidence": 0.45,
                            "reasons": ["normal angle is ambiguous ({:.3f} deg)".format(angle)],
                            "normal_angle_degrees": round(angle, 4),
                            "warnings": warnings, "region": region,
                            "variation_ratio": round(variation, 6)})
            continue

        distance_score = max(0.0, 1.0 - region["average_distance"]
                             / max(float(settings["search_distance"]), 1.0e-9))
        confidence = 0.55 + 0.25 * distance_score + (
            0.15 if variation <= float(settings["max_distance_variation_ratio"]) else 0.0)
        results.append({"joint_type": joint_type,
                        "confidence": round(min(confidence, 0.99), 6),
                        "reasons": reasons,
                        "normal_angle_degrees": round(angle, 4),
                        "warnings": warnings, "region": region,
                        "variation_ratio": round(variation, 6)})
    return results


def duplicate_status(candidate_center: Point, existing_seams: Sequence[Dict],
                     maximum: float) -> str:
    """Replicate duplicate_detector.classify_duplicate (element centers only)."""
    if not existing_seams:
        return "NEW"
    for seam in existing_seams:
        center = tuple(float(v) for v in seam["center"])
        if dist3(candidate_center, center) <= maximum:
            overlap = float(seam.get("overlap_ratio", 1.0))
            return "DUPLICATE" if overlap >= 0.9 else "PARTIAL_OVERLAP"
    return "NEW"


# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

def validate_quad_areas(model: Model) -> None:
    for comp_id, comp in model.components.items():
        for element in comp.elements:
            n = element.nodes
            points = [model.nodes[node_id] for node_id in n]
            # 3D area via two triangles (handles vertical plates).
            area = 0.5 * math.sqrt(sum(v * v for v in _cross(
                tuple(points[1][i] - points[0][i] for i in range(3)),
                tuple(points[2][i] - points[0][i] for i in range(3)))))
            area += 0.5 * math.sqrt(sum(v * v for v in _cross(
                tuple(points[0][i] - points[2][i] for i in range(3)),
                tuple(points[3][i] - points[2][i] for i in range(3)))))
            if area <= 1.0e-10:
                raise ValueError(
                    "component {} element {} is degenerate or inverted (area {})".format(
                        comp.name, element.elem_id, area))


def _cross(a: Tuple[float, float, float], b: Tuple[float, float, float]) -> Tuple[float, float, float]:
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


# ---------------------------------------------------------------------------
# Scenario definitions
# ---------------------------------------------------------------------------

COLOR_PALETTE = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]


def build_scenario_01(model: Model, origin: Point, rng: random.Random,
                      color_seed: int) -> Dict:
    """C01: source plate with 7 circular holes + complete target plate."""
    x0, y0, _ = origin
    source = model.new_component("V01_PlateHoles_T1.5", 1.5, COLOR_PALETTE[color_seed])
    target = model.new_component("V01_PlateSolid_T2.0", 2.0, COLOR_PALETTE[color_seed + 1])
    mesh = 4.0
    # Plate 120 x 100, holes on a 3x3-ish grid (7 holes), patch = 24-segment circles.
    hole_slots = [(4, 5), (15, 5), (26, 5), (4, 12), (15, 12), (26, 12), (15, 19)]
    radii = []
    for _ in hole_slots:
        radii.append(round(rng.uniform(4.0, 9.5), 1))
    holes = [(gx, gy, radius) for (gx, gy), radius in zip(hole_slots, radii)]
    build_perforated_plate(model, source, x0, y0, 5.0, 120.0, 100.0, mesh,
                           holes, circle_segments=24, radial_layers=2)
    build_rect(model, target, x0 - 20.0, y0 - 10.0, 0.0, 160.0, 120.0, mesh)
    return {
        "case_id": "C01",
        "title": "源板多圆孔闭合环 + 完整目标板（手动闭合环焊缝）",
        "source": source,
        "target": target,
        "mode": "manual",
        "holes": [{"grid": [gx, gy], "center": [x0 + gx * mesh, y0 + gy * mesh, 5.0],
                   "radius": radius} for (gx, gy, radius) in holes],
        "expected_loops": {"V01_PlateHoles_T1.5": len(holes) + 1,  # holes + perimeter
                           "V01_PlateSolid_T2.0": 1},
        "expected": "手动路径：每个孔自由边闭合环生成一条闭环焊缝；预期 7 条。",
        "expected_results": {
            "closed_loop_count": len(holes),
            "fast_auto_candidate_count": len(holes) + 1,
        },
        "settings": dict(MODULE_SETTINGS),
        "notes": "逐孔创建选择对：选一个孔环上种子节点 → 选目标组件，重复 7 次。"
                 "若走 FAST_AUTO，孔环与板外轮廓各为一个 L_SURF 候选，共 8 个。",
    }


def build_scenario_02(model: Model, origin: Point, rng: random.Random, color_seed: int) -> Dict:
    """C02: source straight free edge + target plate (manual open path)."""
    x0, y0, _ = origin
    source = model.new_component("V02_OpenEdge_T1.5", 1.5, COLOR_PALETTE[color_seed])
    target = model.new_component("V02_PlateSolid_T2.0", 2.0, COLOR_PALETTE[color_seed + 1])
    mesh = 4.0
    build_rect(model, source, x0, y0, 5.0, 100.0, 60.0, mesh)
    build_rect(model, target, x0 - 20.0, y0 - 15.0, 0.0, 140.0, 88.0, mesh)
    return {
        "case_id": "C02",
        "title": "源板直边开放路径 + 目标板（手动投影 + imprint/ruled）",
        "source": source,
        "target": target,
        "mode": "manual",
        "path_endpoints": {"a": [x0, y0, 5.0], "b": [x0 + 100.0, y0, 5.0]},
        "path_length": 100.0,
        "path_nodes": int(100.0 / mesh) + 1,
        "expected_loops": {"V02_OpenEdge_T1.5": 1, "V02_PlateSolid_T2.0": 1},
        "expected": "沿源板底边连续选择 26 个节点 → 投影 imprint → Ruled 连接带，预期 1 条开放焊缝。",
        "expected_results": {"fast_auto_candidate_count": 1},
        "settings": dict(MODULE_SETTINGS),
        "notes": "开放路径要求所选节点在原网格中沿元素边连续。",
    }


def build_scenario_03(model: Model, origin: Point, rng: random.Random, color_seed: int) -> Dict:
    """C03: source plate with a 45-degree polyline free edge (manual open path)."""
    x0, y0, _ = origin
    source = model.new_component("V03_Chamfer_T1.5", 1.5, COLOR_PALETTE[color_seed])
    target = model.new_component("V03_PlateSolid_T2.0", 2.0, COLOR_PALETTE[color_seed + 1])
    mesh = 4.0
    build_chamfer_pentagon(model, source, x0, y0, 5.0, 100.0, 80.0, 40.0, mesh)
    build_rect(model, target, x0 - 20.0, y0 - 10.0, 0.0, 140.0, 100.0, mesh)
    # Polyline: right edge (x=W, y=0..H-C) + chamfer ((W,H-C)->(W-C,H)).
    bend = [x0 + 100.0, y0 + 40.0, 5.0]
    return {
        "case_id": "C03",
        "title": "源板 45 度折线开放路径 + 目标板（手动投影分割）",
        "source": source,
        "target": target,
        "mode": "manual",
        "path_endpoints": {"a": [x0 + 100.0, y0, 5.0], "bend": bend,
                           "b": [x0 + 60.0, y0 + 80.0, 5.0]},
        "path_length": 40.0 + round(40.0 * math.sqrt(2.0), 3),
        "expected_loops": {"V03_Chamfer_T1.5": 1, "V03_PlateSolid_T2.0": 1},
        "expected": "沿右边缘 + 45 度斜边连续选择节点（1 处折弯）→ 投影 imprint，预期 1 条折线焊缝。",
        "expected_results": {"fast_auto_candidate_count": 1},
        "settings": dict(MODULE_SETTINGS),
        "notes": "折线路径终点为斜边端点，网格沿 45 度斜边对齐。",
    }


def build_scenario_04(model: Model, origin: Point, rng: random.Random, color_seed: int) -> Dict:
    """C04: vertical rib on a base plate (T joint, 90 deg) -> FAST_AUTO T_PATH."""
    x0, y0, _ = origin
    rib = model.new_component("V04_Rib_T1.5", 1.5, COLOR_PALETTE[color_seed])
    base = model.new_component("V04_Base_T2.0", 2.0, COLOR_PALETTE[color_seed + 1])
    mesh = 5.0
    build_rect(model, base, x0, y0, 0.0, 200.0, 140.0, mesh)
    build_vertical_rect(model, rib, x0 + 30.0, y0 + 70.0, 5.0, 140.0, 40.0, mesh)
    return {
        "case_id": "C04",
        "title": "垂直筋板壳 + 底板壳（T 型，法向 90 度）→ FAST_AUTO T 候选",
        "source": rib,
        "target": base,
        "mode": "fast_auto",
        "seam_endpoints": {"a": [x0 + 30.0, y0 + 70.0, 5.0], "b": [x0 + 170.0, y0 + 70.0, 5.0]},
        "seam_length": 140.0,
        "expected_loops": {"V04_Rib_T1.5": 1, "V04_Base_T2.0": 1},
        "expected": "筋板底边自由边投影到底板内部，法向夹角 90 度 → T_PATH 候选（1 个）。",
        "expected_results": {"candidate_count": 1, "joint_type": "T_PATH"},
        "settings": dict(MODULE_SETTINGS),
        "notes": "筋板底边距底板 5mm < search_distance 12；侧边底部短段也在搜索距离内，"
                 "区域长度 > min_seam_length，故生成候选。",
    }


def build_scenario_05(model: Model, origin: Point, rng: random.Random, color_seed: int) -> Dict:
    """C05: overlapping parallel plates (lap) -> FAST_AUTO L_SURF."""
    x0, y0, _ = origin
    top = model.new_component("V05_LapTop_T1.5", 1.5, COLOR_PALETTE[color_seed])
    bottom = model.new_component("V05_LapBottom_T2.0", 2.0, COLOR_PALETTE[color_seed + 1])
    mesh = 5.0
    # Bottom 160x100 at z=0; top 120x80 at z=2, centered and grid-aligned so the
    # projected perimeter coincides with existing bottom-plate grid lines.
    build_rect(model, bottom, x0, y0, 0.0, 160.0, 100.0, mesh)
    build_rect(model, top, x0 + 20.0, y0 + 10.0, 2.0, 120.0, 80.0, mesh)
    return {
        "case_id": "C05",
        "title": "平行重叠壳板（法向夹角 0 度，重叠区宽）→ FAST_AUTO 搭接候选",
        "source": top,
        "target": bottom,
        "mode": "fast_auto",
        "overlap_corners": {
            "a": [x0 + 20.0, y0 + 10.0, 2.0], "b": [x0 + 140.0, y0 + 10.0, 2.0],
            "c": [x0 + 140.0, y0 + 90.0, 2.0], "d": [x0 + 20.0, y0 + 90.0, 2.0],
        },
        "overlap_width": 120.0,
        "overlap_depth": 80.0,
        "expected_loops": {"V05_LapTop_T1.5": 1, "V05_LapBottom_T2.0": 1},
        "expected": "上下板法向平行（<15 度）→ L_SURF 搭接候选（1 个），confidence 高。",
        "expected_results": {"candidate_count": 1, "joint_type": "L_SURF"},
        "settings": dict(MODULE_SETTINGS),
        "notes": "上板周界投影与下板网格线对齐，规划阶段可用已有目标边直接创建。",
    }


def build_scenario_06(model: Model, origin: Point, rng: random.Random, color_seed: int) -> Dict:
    """C06: source/target gap 30 mm > search_distance 12 -> no candidate."""
    x0, y0, _ = origin
    source = model.new_component("V06_SourceFar_T1.5", 1.5, COLOR_PALETTE[color_seed])
    target = model.new_component("V06_TargetFar_T2.0", 2.0, COLOR_PALETTE[color_seed + 1])
    mesh = 4.0
    build_rect(model, source, x0, y0, 0.0, 80.0, 60.0, mesh)
    build_rect(model, target, x0, y0, 30.0, 100.0, 80.0, mesh)
    return {
        "case_id": "C06",
        "title": "失败：源边与目标间距 30mm > search_distance 12mm → 无候选",
        "source": source,
        "target": target,
        "mode": "fast_auto",
        "gap": 30.0,
        "expected_loops": {"V06_SourceFar_T1.5": 1, "V06_TargetFar_T2.0": 1},
        "expected": "源/目标任何自由边对间距均 > 12mm，宽相与逐边筛选均不通过 → 无候选。",
        "expected_results": {"candidate_count": 0},
        "settings": dict(MODULE_SETTINGS),
        "notes": "模块应提示“未识别到候选焊缝”，不修改模型。",
    }


def build_scenario_07(model: Model, origin: Point, rng: random.Random, color_seed: int) -> Dict:
    """C07: short flange free edge (qualified length 12 mm < 20 mm) -> rejected."""
    x0, y0, _ = origin
    source = model.new_component("V07_ShortFlange_T1.5", 1.5, COLOR_PALETTE[color_seed])
    target = model.new_component("V07_Target_T2.0", 2.0, COLOR_PALETTE[color_seed + 1])
    mesh = 4.0
    build_rect(model, target, x0, y0, 0.0, 100.0, 80.0, mesh)
    build_bent_plate_with_flange(model, source, x0, y0, 20.0, 100.0, 60.0, mesh,
                                 48.0, 52.0, 8.0)
    return {
        "case_id": "C07",
        "title": "失败：源边长度（合格区 12mm）< min_seam_length 20mm → 拒绝",
        "source": source,
        "target": target,
        "mode": "fast_auto",
        "flange_tip": {"a": [x0 + 48.0, y0 + 60.0, 8.0], "b": [x0 + 52.0, y0 + 60.0, 8.0]},
        "qualified_length": 12.0,
        "expected_loops": {"V07_ShortFlange_T1.5": 1, "V07_Target_T2.0": 1},
        "expected": "翻边自由边合格区域总长 12mm < min_seam_length 20mm → 候选被丢弃。",
        "expected_results": {"candidate_count": 0},
        "settings": dict(MODULE_SETTINGS),
        "notes": "主体板位于 z=20，距目标 20mm > search_distance，不参与候选。",
    }


def build_scenario_08(model: Model, origin: Point, rng: random.Random, color_seed: int) -> Dict:
    """C08: pre-existing SEAM_T1 strip 3 mm from source edge -> dedup."""
    x0, y0, _ = origin
    rib = model.new_component("V08_Rib_T1.5", 1.5, COLOR_PALETTE[color_seed])
    base = model.new_component("V08_Base_T2.0", 2.0, COLOR_PALETTE[color_seed + 1])
    seam = model.new_component("SEAM_T1", 1.0, COLOR_PALETTE[color_seed + 2])
    mesh = 4.0
    build_rect(model, base, x0, y0, 0.0, 160.0, 108.0, mesh)
    build_vertical_rect(model, rib, x0 + 30.0, y0 + 55.0, 5.0, 100.0, 48.0, mesh)
    # SEAM_T1 strip: 100 x 8 mm in XY at z=2, its centroid ~3 mm below the rib seam.
    build_rect(model, seam, x0 + 30.0, y0 + 51.0, 2.0, 100.0, 8.0, mesh)
    seam_center = [x0 + 80.0, y0 + 55.0, 2.0]
    return {
        "case_id": "C08",
        "title": "边界：预置 SEAM_T1 壳带距源边 3mm（<4.0 去重距离）→ 去重",
        "source": rib,
        "target": base,
        "mode": "fast_auto",
        "seam_endpoints": {"a": [x0 + 30.0, y0 + 55.0, 5.0], "b": [x0 + 130.0, y0 + 55.0, 5.0]},
        "existing_seam_center": seam_center,
        "existing_seam_distance": 3.0,
        "expected_loops": {"V08_Rib_T1.5": 1, "V08_Base_T2.0": 1, "SEAM_T1": 1},
        "expected": "候选被识别后，与 SEAM_T1 距离 3mm <= 4.0 → duplicate_status=DUPLICATE，"
                     "转为 REVIEW，不能批量接受，不会重复创建。",
        "expected_results": {"candidate_count": 1, "duplicate_status": "DUPLICATE"},
        "settings": dict(MODULE_SETTINGS),
        "notes": "SEAM_T1 组件不被选入分析，但会被写入 existing_seams.json 参与去重。",
    }


# ---------------------------------------------------------------------------
# FEM writer
# ---------------------------------------------------------------------------

def fmt(value: float) -> str:
    return "{:.9g}".format(value)


def write_fem(path: Path, model: Model, purpose: str) -> None:
    lines = [
        "$ Mesh Seam Weld validation deck",
        "$ " + purpose,
        "$ Generated by examples/MeshSeamWeld_Validation/generate_fem.py",
        "BEGIN BULK",
        '$HMNAME MAT 1 "BENCHMARK_STEEL"',
        "MAT1,1,210000.0,,0.3,7.85E-9",
    ]
    for comp_id, comp in sorted(model.components.items()):
        lines.extend((
            '$HMNAME PROP {} "{}_PSHELL"'.format(comp.prop_id, comp.name),
            "PSHELL,{},1,{}".format(comp.prop_id, fmt(comp.thickness)),
            '$HMNAME COMP {} "{}"'.format(comp.comp_id, comp.name),
            "$HWCOLOR COMP {} {}".format(comp.comp_id, comp.color),
        ))
    for comp_id, comp in sorted(model.components.items()):
        elem_nodes = {node_id for element in comp.elements for node_id in element.nodes}
        lines.append("$ NODES: {}".format(comp.name))
        for node_id in sorted(elem_nodes):
            x, y, z = model.nodes[node_id]
            lines.append("GRID,{},,{},{},{}".format(node_id, fmt(x), fmt(y), fmt(z)))
        lines.extend(("$HMCOMP ID {}".format(comp.comp_id),
                      "$ ELEMENTS: " + comp.name))
        for element in comp.elements:
            lines.append("CQUAD4,{},{},{},{},{},{}".format(
                element.elem_id, element.prop_id, *element.nodes))
    lines.extend(("ENDDATA", ""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


# ---------------------------------------------------------------------------
# Self checks
# ---------------------------------------------------------------------------

def run_self_checks(model: Model, scenarios: Sequence[Dict]) -> None:
    # 1. Every component's free edges are closed manifold loops with expected count.
    for scenario in scenarios:
        for role in ("source", "target", "seam_comp"):
            comp = scenario.get(role)
            if comp is None:
                continue
            loops = free_edge_loops(model.nodes, comp.elements)
            expected = scenario.get("expected_loops", {}).get(comp.name)
            if expected is None:
                raise ValueError(
                    "{}: no expected loop count registered for {}".format(
                        scenario["case_id"], comp.name))
            if len(loops) != expected:
                raise ValueError(
                    "{} {}: expected {} free-edge loops, found {}".format(
                        scenario["case_id"], comp.name, expected, len(loops)))
    # 2. Non-degenerate elements.
    validate_quad_areas(model)

    # 3. No duplicate element IDs / node IDs (by construction, but assert).
    all_elems = [e.elem_id for comp in model.components.values() for e in comp.elements]
    if len(all_elems) != len(set(all_elems)):
        raise ValueError("duplicate element ids")
    if len(model.nodes) != model.next_node - 1:
        raise ValueError("duplicate node ids")

    # 4. Scenario isolation: source/target components share no node coordinates.
    all_coords: Set[Tuple[float, float, float]] = set()
    for scenario in scenarios:
        source = scenario.get("source")
        target = scenario.get("target")
        if source is None or target is None:
            continue
        source_coords = {model.nodes[node_id] for node_id in component_node_set(source)}
        target_coords = {model.nodes[node_id] for node_id in component_node_set(target)}
        shared = source_coords & target_coords
        if shared:
            raise ValueError(
                "{}: source and target share node coordinates ({}): {}".format(
                    scenario["case_id"], len(shared), next(iter(shared))))
        for coord in source_coords | target_coords:
            if coord in all_coords:
                raise ValueError(
                    "{}: coordinate {} already used by another scenario/component".format(
                        scenario["case_id"], coord))
            all_coords.add(coord)

    # 5. Module-like behavior checks per scenario.
    checks = {
        "C01": {"candidate_count": None, "min_regions": 8, "dup": None, "loops": None},
        "C02": {"candidate_count": None, "min_regions": 1, "dup": None, "loops": None},
        "C03": {"candidate_count": None, "min_regions": 1, "dup": None, "loops": None},
        "C04": {"candidate_count": 1, "min_regions": 1, "dup": None, "joint": "T_PATH"},
        "C05": {"candidate_count": 1, "min_regions": 1, "dup": None, "joint": "L_SURF"},
        "C06": {"candidate_count": 0, "min_regions": None, "dup": None, "loops": None},
        "C07": {"candidate_count": 0, "min_regions": None, "dup": None, "loops": None},
        "C08": {"candidate_count": 1, "min_regions": 1, "dup": "DUPLICATE",
                "joint": None},
    }
    existing_seams = []
    for scenario in scenarios:
        if scenario.get("case_id") == "C08":
            seam_comp = scenario["seam_comp"]
            for element in seam_comp.elements:
                cx = sum(model.nodes[n][0] for n in element.nodes) / 4.0
                cy = sum(model.nodes[n][1] for n in element.nodes) / 4.0
                cz = sum(model.nodes[n][2] for n in element.nodes) / 4.0
                existing_seams.append({"center": [cx, cy, cz]})
    for scenario in scenarios:
        case_id = scenario["case_id"]
        source = scenario.get("source")
        target = scenario.get("target")
        if source is None or target is None:
            continue
        check = checks[case_id]
        results = compute_pair_analysis(source, target, model.nodes,
                                        dict(MODULE_SETTINGS))
        scenario["analysis"] = {
            "region_count": len(results),
            "regions": [{
                "joint_type": r["joint_type"],
                "confidence": r["confidence"],
                "length": r["region"]["region_length"],
                "min_distance": r["region"]["minimum_distance"],
                "avg_distance": r["region"]["average_distance"],
                "max_distance": r["region"]["maximum_distance"],
                "warnings": r["warnings"],
                "normal_angle_degrees": r["normal_angle_degrees"],
                "center": r["region"]["region_center"],
            } for r in results],
        }
        if check.get("candidate_count") is not None:
            if len(results) != check["candidate_count"]:
                raise ValueError(
                    "{}: expected {} candidate regions, found {}".format(
                        case_id, check["candidate_count"], len(results)))
        if check.get("min_regions") is not None and len(results) < check["min_regions"]:
            raise ValueError(
                "{}: expected at least {} candidate regions, found {}".format(
                    case_id, check["min_regions"], len(results)))
        if check.get("joint"):
            for r in results:
                if r["joint_type"] != check["joint"] and r["joint_type"] != "REVIEW":
                    raise ValueError(
                        "{}: unexpected joint type {} (expected {})".format(
                            case_id, r["joint_type"], check["joint"]))
        if check.get("dup") is not None:
            if not results:
                raise ValueError("C08: expected a candidate for duplicate check")
            center = tuple(results[0]["region"]["region_center"])
            status = duplicate_status(center, existing_seams,
                                      float(MODULE_SETTINGS["existing_weld_search_distance"]))
            if status != check["dup"]:
                raise ValueError(
                    "C08: expected duplicate_status {}, got {}".format(check["dup"], status))
            scenario["analysis"]["duplicate_status"] = status

    # 6. Node budget.
    total_nodes = len(model.nodes)
    if not (5000 <= total_nodes <= 15000):
        raise ValueError("total node count {} outside [5000, 15000]".format(total_nodes))
    for scenario in scenarios:
        nodes_in_scene = set()
        for role in ("source", "target", "seam_comp"):
            comp = scenario.get(role)
            if comp is not None:
                nodes_in_scene.update(component_node_set(comp))
        count = len(nodes_in_scene)
        if not (500 <= count <= 3000):
            raise ValueError(
                "{}: scenario node count {} outside [500, 3000]".format(
                    scenario["case_id"], count))


def build_manifest(args: argparse.Namespace, model: Model,
                   scenarios: Sequence[Dict]) -> Dict:
    components = {str(comp_id): comp.name for comp_id, comp in model.components.items()}
    statistics = {
        "total_nodes": len(model.nodes),
        "total_elements": sum(len(comp.elements) for comp in model.components.values()),
        "component_count": len(model.components),
    }
    for scenario in scenarios:
        scene_nodes = 0
        scene_elems = 0
        for role in ("source", "target"):
            comp = scenario.get(role)
            if comp is not None:
                scene_nodes += len(component_node_set(comp))
                scene_elems += len(comp.elements)
        if scenario.get("seam_comp") is not None:
            scene_nodes += len(component_node_set(scenario["seam_comp"]))
            scene_elems += len(scenario["seam_comp"].elements)
        statistics[scenario["case_id"] + "_nodes"] = scene_nodes
        statistics[scenario["case_id"] + "_elements"] = scene_elems

    cases = []
    for scenario in scenarios:
        comp_ids = []
        comp_names = []
        for role in ("source", "target", "seam_comp"):
            comp = scenario.get(role)
            if comp is not None:
                comp_ids.append(comp.comp_id)
                comp_names.append(comp.name)
        case = {
            "case_id": scenario["case_id"],
            "title": scenario["title"],
            "component_ids": comp_ids,
            "component_names": comp_names,
            "expected": scenario["expected"],
            "expected_results": scenario["expected_results"],
            "settings": scenario["settings"],
            "notes": scenario["notes"],
        }
        for key in ("path_endpoints", "overlap_corners", "seam_endpoints",
                    "flange_tip", "holes", "gap", "path_length", "path_nodes",
                    "seam_length", "qualified_length", "overlap_width",
                    "overlap_depth", "existing_seam_center", "existing_seam_distance",
                    "loop_count_expected"):
            if key in scenario:
                case[key] = scenario[key]
        if "analysis" in scenario:
            case["analysis"] = scenario["analysis"]
        cases.append(case)

    manifest = {
        "schema_version": "1.0",
        "purpose": "Mesh Seam Weld 模块验证模型：8 个场景覆盖手动闭合环/开放路径、"
                   "FAST_AUTO T 型与搭接候选、失败（超距/短边）与已有焊缝去重",
        "generator": "examples/MeshSeamWeld_Validation/generate_fem.py",
        "fem": str(args.output),
        "parameters": {
            "pitch": 400.0,
            "element_size_range_mm": [4.0, 5.0],
            "module_rules_source": "config/mesh_seam_auto_rules.txt",
            **{k: MODULE_SETTINGS[k] for k in (
                "search_distance", "min_seam_length", "min_path_nodes",
                "parallel_angle_max", "perpendicular_angle_min",
                "max_distance_variation_ratio", "existing_path_search_width",
                "max_target_path_offset", "existing_weld_search_distance",
                "exclude_existing_welds", "auto_accept_confidence",
                "review_confidence")},
        },
        "statistics": statistics,
        "components": components,
        "cases": cases,
    }
    return manifest


def parse_args() -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=here / "MeshSeamWeld_Validation.fem")
    parser.add_argument("--manifest", type=Path,
                        default=here / "MeshSeamWeld_Validation_manifest.json")
    parser.add_argument("--seed", type=int, default=20260809)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    rng = random.Random(args.seed)
    model = Model()
    pitch = 400.0
    builders = [
        build_scenario_01, build_scenario_02, build_scenario_03, build_scenario_04,
        build_scenario_05, build_scenario_06, build_scenario_07, build_scenario_08,
    ]
    scenarios = []
    for index, builder in enumerate(builders):
        origin = (pitch * index, 0.0, 0.0)
        scenario = builder(model, origin, rng, color_seed=2 * index)
        scenarios.append(scenario)

    # Wire the SEAM_T1 component into scenario C08 for the duplicate check.
    for comp in model.components.values():
        if comp.name == "SEAM_T1":
            scenarios[7]["seam_comp"] = comp
            break
    else:
        raise ValueError("SEAM_T1 component was not created")

    run_self_checks(model, scenarios)

    output = args.output.resolve()
    manifest_path = args.manifest.resolve()
    write_fem(output, model,
              "Eight independent Mesh Seam Weld scenarios (C01..C08).")
    manifest = build_manifest(args, model, scenarios)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                             encoding="utf-8")
    print(json.dumps({
        "fem": str(output),
        "manifest": str(manifest_path),
        "total_nodes": len(model.nodes),
        "total_elements": sum(len(c.elements) for c in model.components.values()),
        "per_scenario": {s["case_id"]: s["analysis"]["region_count"]
                         for s in scenarios if "analysis" in s},
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
