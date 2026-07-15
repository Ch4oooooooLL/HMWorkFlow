from __future__ import annotations

import math
from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Any, DefaultDict, Dict, Iterable, List, Sequence, Set, Tuple

Point = Tuple[float, float, float]
Edge = Tuple[int, int]


def distance(a: Point, b: Point) -> float:
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def midpoint(a: Point, b: Point) -> Point:
    return tuple((a[i] + b[i]) * 0.5 for i in range(3))  # type: ignore[return-value]


@dataclass
class ComponentTopology:
    component_id: int
    name: str
    node_ids: Set[int]
    element_ids: Set[int]
    free_edges: List[Tuple[int, int, int]]
    node_elements: Dict[int, Set[int]]
    bounds: Tuple[float, float, float, float, float, float]


class SpatialHash:
    def __init__(self, nodes: Dict[int, Point], node_ids: Iterable[int], cell_size: float):
        self.nodes = nodes
        self.cell_size = max(float(cell_size), 1.0e-12)
        self.cells: DefaultDict[Tuple[int, int, int], List[int]] = defaultdict(list)
        for node_id in node_ids:
            self.cells[self.key(nodes[node_id])].append(node_id)

    def key(self, point: Point) -> Tuple[int, int, int]:
        return tuple(int(math.floor(value / self.cell_size)) for value in point)  # type: ignore[return-value]

    def nearest(self, point: Point, maximum: float) -> Tuple[float, int]:
        base = self.key(point)
        best, best_id = float("inf"), 0
        radius = max(1, int(math.ceil(maximum / self.cell_size)))
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                for dz in range(-radius, radius + 1):
                    for node_id in self.cells.get((base[0] + dx, base[1] + dy, base[2] + dz), ()):
                        value = distance(point, self.nodes[node_id])
                        if value < best:
                            best, best_id = value, node_id
        return best, best_id


def _element_edges(node_ids: Sequence[int]) -> Iterable[Edge]:
    for index, first in enumerate(node_ids):
        second = node_ids[(index + 1) % len(node_ids)]
        yield (first, second) if first < second else (second, first)


def build_component_topology(components: Sequence[Dict[str, Any]], nodes: Dict[int, Point], elements: Sequence[Dict[str, Any]]) -> Dict[int, ComponentTopology]:
    by_component: DefaultDict[int, List[Dict[str, Any]]] = defaultdict(list)
    for element in elements:
        if len(element["node_ids"]) in (3, 4):
            by_component[element["component_id"]].append(element)
    result: Dict[int, ComponentTopology] = {}
    for component in components:
        component_id = int(component.get("id", component.get("component_id")))
        component_elements = by_component.get(component_id, [])
        node_ids = {node_id for element in component_elements for node_id in element["node_ids"] if node_id in nodes}
        if not node_ids:
            continue
        incidence: DefaultDict[Edge, List[int]] = defaultdict(list)
        node_elements: DefaultDict[int, Set[int]] = defaultdict(set)
        for element in component_elements:
            for node_id in element["node_ids"]:
                node_elements[node_id].add(element["element_id"])
            for edge in _element_edges(element["node_ids"]):
                incidence[edge].append(element["element_id"])
        xyz = [nodes[node_id] for node_id in node_ids]
        result[component_id] = ComponentTopology(
            component_id=component_id,
            name=str(component.get("name", component.get("component_name", "COMP_{}".format(component_id)))),
            node_ids=node_ids,
            element_ids={element["element_id"] for element in component_elements},
            free_edges=[(edge[0], edge[1], owners[0]) for edge, owners in incidence.items() if len(owners) == 1],
            node_elements=dict(node_elements),
            bounds=(min(p[0] for p in xyz), max(p[0] for p in xyz), min(p[1] for p in xyz), max(p[1] for p in xyz), min(p[2] for p in xyz), max(p[2] for p in xyz)),
        )
    return result


def build_component_bounds(topologies: Dict[int, ComponentTopology]) -> Dict[int, Tuple[float, float, float, float, float, float]]:
    return {component_id: topology.bounds for component_id, topology in topologies.items()}


def find_candidate_component_pairs(topologies: Dict[int, ComponentTopology], maximum: float) -> List[Tuple[int, int]]:
    ordered = sorted(topologies.values(), key=lambda item: item.bounds[0])
    pairs: List[Tuple[int, int]] = []
    for index, first in enumerate(ordered):
        for second in ordered[index + 1 :]:
            if second.bounds[0] > first.bounds[1] + maximum:
                break
            a, b = first.bounds, second.bounds
            if all((a[axis * 2] - maximum <= b[axis * 2 + 1] and b[axis * 2] - maximum <= a[axis * 2 + 1]) for axis in range(3)):
                pairs.append(tuple(sorted((first.component_id, second.component_id))))
    return pairs


def _connected_regions(qualified: List[Dict[str, Any]], nodes: Dict[int, Point], settings: Dict[str, Any], source_id: int, target_id: int) -> List[Dict[str, Any]]:
    by_node: DefaultDict[int, List[int]] = defaultdict(list)
    for index, row in enumerate(qualified):
        by_node[row["n1"]].append(index)
        by_node[row["n2"]].append(index)
    remaining = set(range(len(qualified)))
    regions: List[Dict[str, Any]] = []
    while remaining:
        seed = remaining.pop()
        group, queue = [seed], deque([seed])
        while queue:
            current = qualified[queue.popleft()]
            for node_id in (current["n1"], current["n2"]):
                for neighbor in by_node[node_id]:
                    if neighbor in remaining:
                        remaining.remove(neighbor); group.append(neighbor); queue.append(neighbor)
        rows = [qualified[index] for index in group]
        source_nodes = sorted({node_id for row in rows for node_id in (row["n1"], row["n2"])})
        length = sum(distance(nodes[row["n1"]], nodes[row["n2"]]) for row in rows)
        if len(source_nodes) < int(settings["min_continuous_nodes"]) or length < float(settings["min_contact_length"]):
            continue
        distances = [value for row in rows for value in (row["d1"], row["d2"])]
        centers = [nodes[node_id] for node_id in source_nodes]
        regions.append({
            "source_component_id": source_id, "target_component_id": target_id,
            "source_node_ids": source_nodes,
            "source_edge_pairs": [[row["n1"], row["n2"]] for row in rows],
            "source_element_ids": sorted({row["owner"] for row in rows}),
            "target_near_node_ids": sorted({node_id for row in rows for node_id in (row["t1"], row["t2"]) if node_id}),
            "target_near_element_ids": [],
            "region_length": round(length, 9), "minimum_distance": round(min(distances), 9),
            "average_distance": round(sum(distances) / len(distances), 9), "maximum_distance": round(max(distances), 9),
            "region_center": [round(sum(point[axis] for point in centers) / len(centers), 9) for axis in range(3)],
        })
    return regions


def extract_candidate_regions(source: ComponentTopology, target: ComponentTopology, nodes: Dict[int, Point], settings: Dict[str, Any]) -> List[Dict[str, Any]]:
    maximum = float(settings["max_search_distance"])
    index = SpatialHash(nodes, target.node_ids, maximum)
    nearest: Dict[int, Tuple[float, int]] = {}
    qualified: List[Dict[str, Any]] = []
    for n1, n2, owner in source.free_edges:
        if n1 not in nearest: nearest[n1] = index.nearest(nodes[n1], maximum)
        if n2 not in nearest: nearest[n2] = index.nearest(nodes[n2], maximum)
        d1, t1 = nearest[n1]; d2, t2 = nearest[n2]
        if d1 <= maximum and d2 <= maximum:
            qualified.append({"n1": n1, "n2": n2, "owner": owner, "d1": d1, "d2": d2, "t1": t1, "t2": t2})
    regions = _connected_regions(qualified, nodes, settings, source.component_id, target.component_id)
    for region in regions:
        region["target_near_element_ids"] = sorted({
            element_id
            for node_id in region["target_near_node_ids"]
            for element_id in target.node_elements.get(node_id, set())
        })
    return regions


def merge_duplicate_pairs(regions: List[Dict[str, Any]], maximum: float) -> List[Dict[str, Any]]:
    # Opposite-direction free edges often describe the same physical gap. Keep
    # the longer representation when their centers occupy the same local area.
    merged: List[Dict[str, Any]] = []
    for region in sorted(regions, key=lambda row: row["region_length"], reverse=True):
        center = tuple(region["region_center"])
        if any(distance(center, tuple(existing["region_center"])) <= maximum for existing in merged):
            continue
        merged.append(region)
    return merged


def analyze_component_pair(first: ComponentTopology, second: ComponentTopology, nodes: Dict[int, Point], settings: Dict[str, Any]) -> List[Dict[str, Any]]:
    if settings.get("ignore_shared_nodes", True):
        shared = first.node_ids & second.node_ids
        if len(shared) >= int(settings["min_continuous_nodes"]):
            return []
    regions = extract_candidate_regions(first, second, nodes, settings)
    regions.extend(extract_candidate_regions(second, first, nodes, settings))
    return merge_duplicate_pairs(regions, float(settings["max_search_distance"]))


def calculate_pair_metrics(regions: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    distances = [(region["average_distance"], max(region["region_length"], 1.0e-12)) for region in regions]
    total_length = sum(region["region_length"] for region in regions)
    return {
        "candidate_region_count": len(regions), "total_candidate_length": round(total_length, 9),
        "minimum_distance": min(region["minimum_distance"] for region in regions),
        "average_distance": round(sum(value * weight for value, weight in distances) / sum(weight for _, weight in distances), 9),
        "maximum_distance": max(region["maximum_distance"] for region in regions),
    }


def detect(components: Sequence[Dict[str, Any]], nodes: Dict[int, Point], elements: Sequence[Dict[str, Any]], settings: Dict[str, Any]) -> Dict[str, Any]:
    topologies = build_component_topology(components, nodes, elements)
    pairs: List[Dict[str, Any]] = []
    for first_id, second_id in find_candidate_component_pairs(topologies, float(settings["max_search_distance"])):
        first, second = topologies[first_id], topologies[second_id]
        regions = analyze_component_pair(first, second, nodes, settings)
        if not regions:
            continue
        for region in regions:
            region["region_id"] = "REGION_{:06d}".format(sum(len(pair["regions"]) for pair in pairs) + regions.index(region) + 1)
        row = {
            "pair_id": "PAIR_{:06d}".format(len(pairs) + 1),
            "component_a": {"id": first_id, "name": first.name},
            "component_b": {"id": second_id, "name": second.name},
            "status": "pending", "recommended_weld_type": "shell_shell_candidate", "regions": regions,
        }
        row.update(calculate_pair_metrics(regions)); pairs.append(row)
    pairs.sort(key=lambda row: (-row["total_candidate_length"], -row["candidate_region_count"], row["minimum_distance"], row["component_a"]["id"], row["component_b"]["id"]))
    for index, pair in enumerate(pairs, 1): pair["pair_id"] = "PAIR_{:06d}".format(index)
    return {"success": True, "message": "", "summary": {"selected_component_count": len(topologies), "candidate_pair_count": len(pairs), "candidate_region_count": sum(len(pair["regions"]) for pair in pairs)}, "pairs": pairs}
