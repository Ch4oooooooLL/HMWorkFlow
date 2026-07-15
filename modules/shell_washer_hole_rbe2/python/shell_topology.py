"""Build shell edge and element adjacency indexes."""
from __future__ import annotations

from collections import defaultdict
from topology import edge_incidence, shell_corner_nodes


def build(elements):
    elements = list(elements)
    incidence = edge_incidence(elements)
    neighbors = defaultdict(set)
    for attached in incidence.values():
        if len(attached) == 2:
            a, b = attached; neighbors[a].add(b); neighbors[b].add(a)
    nodes = {element.element_id: tuple(shell_corner_nodes(element)) for element in elements}
    return incidence, {key: sorted(value) for key, value in neighbors.items()}, nodes


def expand_layers(seeds, neighbors, layer_count):
    selected = set(seeds); frontier = set(seeds)
    for _ in range(1, max(1, layer_count)):
        following = {neighbor for element in frontier for neighbor in neighbors.get(element, [])} - selected
        selected.update(following); frontier = following
        if not frontier: break
    return sorted(selected)
