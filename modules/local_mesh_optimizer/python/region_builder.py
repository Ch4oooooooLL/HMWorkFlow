"""Build Local Mesh Optimizer regions from HyperMesh-exported data."""

from __future__ import annotations

import csv
import math
from pathlib import Path
from typing import Dict, List, Mapping, Optional, Sequence, Set, Tuple

from adjacency import Edge, ShellElement, build_adjacency, connected_components, expand_region


def read_blocked_edges(path: Optional[Path]) -> Set[Edge]:
    edges: Set[Edge] = set()
    if path is None or not path.exists():
        return edges
    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames is None or not {"n1", "n2"}.issubset(reader.fieldnames):
            raise ValueError("Protected edge CSV requires n1,n2 columns")
        for row in reader:
            first, second = int(row["n1"]), int(row["n2"])
            edges.add((first, second) if first < second else (second, first))
    return edges


def read_node_coordinates(path: Optional[Path]) -> Dict[int, Tuple[float, float, float]]:
    coordinates: Dict[int, Tuple[float, float, float]] = {}
    if path is None or not path.exists():
        return coordinates
    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames is None or not {"node_id", "x", "y", "z"}.issubset(reader.fieldnames):
            raise ValueError("Node coordinate CSV requires node_id,x,y,z columns")
        for row in reader:
            coordinates[int(row["node_id"])] = (
                float(row["x"]), float(row["y"]), float(row["z"])
            )
    return coordinates


def _geometry(
    element_ids: Sequence[int],
    elements: Mapping[int, ShellElement],
    coordinates: Mapping[int, Tuple[float, float, float]],
) -> Tuple[Dict[str, List[float]], Dict[str, float]]:
    node_ids = {node for element_id in element_ids for node in elements[element_id].nodes}
    points = [coordinates[node_id] for node_id in node_ids if node_id in coordinates]
    if not points:
        return {}, {}
    bbox = {
        "min": [min(point[index] for point in points) for index in range(3)],
        "max": [max(point[index] for point in points) for index in range(3)],
    }
    count = float(len(points))
    centroid = {
        "x": sum(point[0] for point in points) / count,
        "y": sum(point[1] for point in points) / count,
        "z": sum(point[2] for point in points) / count,
    }
    return bbox, centroid


def _normal(element: ShellElement, coordinates: Mapping[int, Tuple[float, float, float]]) -> Optional[Tuple[float, float, float]]:
    if any(node not in coordinates for node in element.nodes[:3]):
        return None
    first, second, third = (coordinates[node] for node in element.nodes[:3])
    ab = tuple(second[index] - first[index] for index in range(3))
    ac = tuple(third[index] - first[index] for index in range(3))
    cross = (
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    )
    length = math.sqrt(sum(value * value for value in cross))
    return None if length == 0.0 else tuple(value / length for value in cross)


def feature_edges(
    elements: Mapping[int, ShellElement],
    coordinates: Mapping[int, Tuple[float, float, float]],
    angle_degrees: float,
) -> Set[Edge]:
    _, edge_owners = build_adjacency(elements)
    normals = {element_id: _normal(element, coordinates) for element_id, element in elements.items()}
    result: Set[Edge] = set()
    cosine_limit = math.cos(math.radians(angle_degrees))
    for edge, owners in edge_owners.items():
        if len(owners) != 2:
            continue
        first, second = (normals[element_id] for element_id in owners)
        if first is None or second is None:
            continue
        cosine = max(-1.0, min(1.0, sum(first[index] * second[index] for index in range(3))))
        if cosine < cosine_limit:
            result.add(edge)
    return result


def build_regions(
    elements: Mapping[int, ShellElement],
    failed_ids: Sequence[int],
    layers: int,
    max_region_elements: int,
    blocked_edges: Optional[Set[Edge]] = None,
    cross_components: bool = False,
    coordinates: Optional[Mapping[int, Tuple[float, float, float]]] = None,
    user_anchor_nodes: Optional[Set[int]] = None,
    protect_feature_edges: bool = False,
    feature_angle: float = 30.0,
) -> List[dict]:
    if max_region_elements < 1:
        raise ValueError("max_region_elements must be positive")
    coordinates = coordinates or {}
    blocked_edges = set(blocked_edges or set())
    if protect_feature_edges:
        blocked_edges.update(feature_edges(elements, coordinates, feature_angle))
    if not cross_components:
        _, raw_edge_owners = build_adjacency(elements)
        for edge, owners in raw_edge_owners.items():
            if len(owners) == 2 and elements[owners[0]].component_id != elements[owners[1]].component_id:
                blocked_edges.add(edge)
    adjacency, edge_owners = build_adjacency(elements, blocked_edges, cross_components)
    failed_groups = connected_components(failed_ids, adjacency)
    result: List[dict] = []
    user_anchor_nodes = user_anchor_nodes or set()
    for index, failed in enumerate(failed_groups, 1):
        expanded, completed_layers, truncated = expand_region(
            failed, adjacency, layers, max_region_elements
        )
        bbox, centroid = _geometry(expanded, elements, coordinates)
        component_ids = sorted({elements[element_id].component_id for element_id in expanded})
        expanded_set = set(expanded)
        anchor_nodes = set(user_anchor_nodes)
        for element_id in expanded:
            for edge in elements[element_id].edges():
                owners = edge_owners.get(edge, [])
                if edge in blocked_edges or len(owners) != 2 or any(owner not in expanded_set for owner in owners):
                    anchor_nodes.update(edge)
        result.append(
            {
                "region_id": "Region_{:04d}".format(index),
                "failed_elements": failed,
                "expanded_elements": expanded,
                "components": component_ids,
                "failed_count": len(failed),
                "expanded_count": len(expanded),
                "requested_layers": layers,
                "completed_layers": completed_layers,
                "expansion_truncated": truncated,
                "bbox": bbox,
                "centroid": centroid,
                "anchor_nodes": sorted(anchor_nodes),
                "current_failed_count": len(failed),
                "rounds": 0,
                "optimization_methods": [],
                "rollback_count": 0,
                "elapsed_seconds": 0.0,
                "status": "pending",
                "message": "",
            }
        )
    return result


def merge_independent_regions(
    regions: Sequence[dict],
    elements: Mapping[int, ShellElement],
    coordinates: Optional[Mapping[int, Tuple[float, float, float]]] = None,
    max_source_regions: int = 200,
    max_failed_elements: int = 500,
    max_expanded_elements: int = 10000,
) -> List[dict]:
    """Pack node-disjoint small regions into macro regions.

    The Tcl executor already applies actions and performs native quality checks
    per region.  Thousands of isolated failures therefore caused thousands of
    UI updates, batch files and quality calls.  Packing only regions whose
    expanded node sets are disjoint preserves the original local protection
    boundaries while allowing one execution/recheck pass for many islands.
    """
    if min(max_source_regions, max_failed_elements, max_expanded_elements) < 1:
        raise ValueError("macro region limits must be positive")
    coordinates = coordinates or {}
    buckets: List[dict] = []
    ordered = sorted(regions, key=lambda region: str(region["region_id"]))
    for region in ordered:
        expanded = set(int(value) for value in region["expanded_elements"])
        nodes = {
            node
            for element_id in expanded
            if element_id in elements
            for node in elements[element_id].nodes
        }
        failed_count = len(region["failed_elements"])
        placed = False
        for bucket in buckets:
            if len(bucket["regions"]) >= max_source_regions:
                continue
            if bucket["failed_count"] + failed_count > max_failed_elements:
                continue
            combined_expanded = bucket["expanded"].union(expanded)
            if len(combined_expanded) > max_expanded_elements:
                continue
            if bucket["nodes"].intersection(nodes):
                continue
            bucket["regions"].append(region)
            bucket["nodes"].update(nodes)
            bucket["expanded"] = combined_expanded
            bucket["failed_count"] += failed_count
            placed = True
            break
        if not placed:
            buckets.append(
                {
                    "regions": [region],
                    "nodes": set(nodes),
                    "expanded": set(expanded),
                    "failed_count": failed_count,
                }
            )

    result: List[dict] = []
    for index, bucket in enumerate(buckets, 1):
        sources = bucket["regions"]
        failed = sorted(
            {int(value) for region in sources for value in region["failed_elements"]}
        )
        expanded = sorted(bucket["expanded"])
        bbox, centroid = _geometry(expanded, elements, coordinates)
        result.append(
            {
                "region_id": "Region_{:04d}".format(index),
                "source_region_ids": [str(region["region_id"]) for region in sources],
                "failed_elements": failed,
                "expanded_elements": expanded,
                "components": sorted(
                    {int(value) for region in sources for value in region["components"]}
                ),
                "failed_count": len(failed),
                "expanded_count": len(expanded),
                "requested_layers": max(int(region["requested_layers"]) for region in sources),
                "completed_layers": min(int(region["completed_layers"]) for region in sources),
                "expansion_truncated": any(bool(region["expansion_truncated"]) for region in sources),
                "bbox": bbox,
                "centroid": centroid,
                "anchor_nodes": sorted(
                    {int(value) for region in sources for value in region["anchor_nodes"]}
                ),
                "current_failed_count": len(failed),
                "rounds": 0,
                "optimization_methods": [],
                "rollback_count": 0,
                "elapsed_seconds": 0.0,
                "status": "pending",
                "message": "",
            }
        )
    return result
