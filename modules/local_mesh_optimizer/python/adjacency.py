"""Edge-based shell element adjacency."""

from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, Iterator, List, Mapping, MutableMapping, Optional, Sequence, Set, Tuple

Edge = Tuple[int, int]


@dataclass(frozen=True)
class ShellElement:
    element_id: int
    component_id: int
    nodes: Tuple[int, ...]

    def edges(self) -> Iterator[Edge]:
        count = len(self.nodes)
        for index in range(count):
            first = self.nodes[index]
            second = self.nodes[(index + 1) % count]
            yield (first, second) if first < second else (second, first)


def _parse_nodes(row: Mapping[str, str]) -> Tuple[int, ...]:
    if row.get("node_ids", "").strip():
        text = row["node_ids"].replace(";", " ").replace(",", " ")
        values = [int(value) for value in text.split() if value]
    else:
        values = []
        for key in ("n1", "n2", "n3", "n4"):
            value = row.get(key, "").strip()
            if value and int(value) > 0:
                values.append(int(value))
    if len(values) not in (3, 4) or len(set(values)) != len(values):
        raise ValueError("Only valid 3-node and 4-node shell elements are supported: {}".format(row))
    return tuple(values)


def read_connectivity(path: Path) -> Dict[int, ShellElement]:
    elements: Dict[int, ShellElement] = {}
    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        required = {"element_id", "component_id"}
        if reader.fieldnames is None or not required.issubset(reader.fieldnames):
            raise ValueError("Connectivity table requires element_id and component_id columns")
        for row in reader:
            element_id = int(row["element_id"])
            if element_id in elements:
                raise ValueError("Duplicate element id {}".format(element_id))
            elements[element_id] = ShellElement(
                element_id=element_id,
                component_id=int(row["component_id"]),
                nodes=_parse_nodes(row),
            )
    return elements


def build_adjacency(
    elements: Mapping[int, ShellElement],
    blocked_edges: Optional[Set[Edge]] = None,
    cross_components: bool = True,
) -> Tuple[Dict[int, Set[int]], Dict[Edge, List[int]]]:
    blocked_edges = blocked_edges or set()
    edge_owners: Dict[Edge, List[int]] = {}
    adjacency: Dict[int, Set[int]] = {element_id: set() for element_id in elements}
    for element in elements.values():
        for edge in element.edges():
            edge_owners.setdefault(edge, []).append(element.element_id)

    for edge, owners in edge_owners.items():
        if edge in blocked_edges or len(owners) != 2:
            continue
        first, second = owners
        if not cross_components and elements[first].component_id != elements[second].component_id:
            continue
        adjacency[first].add(second)
        adjacency[second].add(first)
    return adjacency, edge_owners


def connected_components(seed_ids: Iterable[int], adjacency: Mapping[int, Set[int]]) -> List[List[int]]:
    remaining = set(seed_ids)
    unknown = remaining.difference(adjacency)
    if unknown:
        raise ValueError("Failed element ids are absent from connectivity: {}".format(sorted(unknown)[:20]))
    result: List[List[int]] = []
    while remaining:
        start = min(remaining)
        remaining.remove(start)
        component = [start]
        stack = [start]
        while stack:
            current = stack.pop()
            neighbors = adjacency[current].intersection(remaining)
            for neighbor in sorted(neighbors, reverse=True):
                remaining.remove(neighbor)
                stack.append(neighbor)
                component.append(neighbor)
        result.append(sorted(component))
    result.sort(key=lambda values: values[0])
    return result


def expand_region(
    seeds: Iterable[int], adjacency: Mapping[int, Set[int]], layers: int, limit: int
) -> Tuple[List[int], int, bool]:
    if layers < 0:
        raise ValueError("Adjacency layers cannot be negative")
    selected = set(seeds)
    frontier = set(selected)
    completed_layers = 0
    truncated = False
    for layer in range(1, layers + 1):
        candidates: Set[int] = set()
        for element_id in frontier:
            candidates.update(adjacency[element_id])
        candidates.difference_update(selected)
        if not candidates:
            completed_layers = layer
            break
        available = limit - len(selected)
        if available <= 0 or len(candidates) > available:
            truncated = True
            break
        selected.update(candidates)
        frontier = candidates
        completed_layers = layer
    return sorted(selected), completed_layers, truncated
