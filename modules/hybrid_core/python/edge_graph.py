"""Deterministic undirected edge graph traversal."""
from __future__ import annotations

from collections import defaultdict, deque
from typing import Dict, Iterable, List, Set, Tuple

try:
    from .topology import edge_key
except ImportError:  # Standalone HM2019 entry compatibility.
    from topology import edge_key


class EdgeGraph:
    def __init__(self, edges: Iterable[Tuple[int, int]]) -> None:
        self.adjacency = defaultdict(set)  # type: Dict[int, Set[int]]
        self.edges = set()
        for a, b in edges:
            if a == b:
                continue
            key = edge_key(int(a), int(b))
            self.edges.add(key)
            self.adjacency[key[0]].add(key[1])
            self.adjacency[key[1]].add(key[0])

    def components(self) -> List[List[int]]:
        pending = set(self.adjacency)
        result = []
        for start in sorted(self.adjacency):
            if start not in pending:
                continue
            queue = deque([start])
            seen = {start}
            while queue:
                node = queue.popleft()
                for neighbor in sorted(self.adjacency[node]):
                    if neighbor not in seen:
                        seen.add(neighbor)
                        queue.append(neighbor)
            pending -= seen
            result.append(sorted(seen))
        return result

    def ordered_paths(self) -> List[Dict[str, object]]:
        paths = []
        for component in self.components():
            degrees = {node: len(self.adjacency[node]) for node in component}
            branched = any(value > 2 for value in degrees.values())
            endpoints = sorted(node for node, value in degrees.items() if value == 1)
            closed = bool(component) and not endpoints and all(value == 2 for value in degrees.values())
            if branched or (not closed and len(endpoints) != 2):
                paths.append({"nodes": component, "closed": False, "branched": True})
                continue
            start = min(component) if closed else endpoints[0]
            ordered = [start]
            previous = None
            current = start
            ordered_set = {start}
            while True:
                choices = sorted(node for node in self.adjacency[current] if node != previous)
                if not choices:
                    break
                following = choices[0]
                if closed and following == start:
                    break
                if following in ordered_set:
                    break
                ordered.append(following)
                ordered_set.add(following)
                previous, current = current, following
            paths.append({"nodes": ordered, "closed": closed, "branched": False})
        return paths
