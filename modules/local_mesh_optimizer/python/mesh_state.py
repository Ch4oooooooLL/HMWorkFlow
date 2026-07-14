"""Incrementally maintained shell-mesh topology cache.

The cache is deliberately independent of HyperMesh APIs. HyperMesh remains the
authoritative database; this object supports planning, conservative simulation,
and local updates returned by the Tcl executor.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Iterable, Mapping, Optional, Sequence, Set, Tuple

from adjacency import Edge, ShellElement

Point = Tuple[float, float, float]


def edge_key(first: int, second: int) -> Edge:
    return (first, second) if first < second else (second, first)


@dataclass(frozen=True)
class DirtyRegion:
    nodes: Set[int]
    elements: Set[int]
    edges: Set[Edge]


class MeshState:
    """Shell topology plus reverse indices with local mutation operations."""

    def __init__(
        self,
        nodes: Mapping[int, Point],
        elements: Mapping[int, ShellElement],
    ) -> None:
        self.nodes: Dict[int, Point] = dict(nodes)
        self.elements: Dict[int, ShellElement] = dict(elements)
        self.node_to_elements: Dict[int, Set[int]] = {}
        self.edge_to_elements: Dict[Edge, Set[int]] = {}
        self.element_neighbors: Dict[int, Set[int]] = {}
        self.component_elements: Dict[int, Set[int]] = {}
        self.deleted_nodes: Set[int] = set()
        self.deleted_elements: Set[int] = set()
        self._build_indices()

    def _element_edges(self, element: ShellElement) -> Tuple[Edge, ...]:
        return tuple(
            edge_key(element.nodes[index], element.nodes[(index + 1) % len(element.nodes)])
            for index in range(len(element.nodes))
        )

    def _build_indices(self) -> None:
        self.node_to_elements.clear()
        self.edge_to_elements.clear()
        self.component_elements.clear()
        for element in self.elements.values():
            self.component_elements.setdefault(element.component_id, set()).add(element.element_id)
            for node in element.nodes:
                self.node_to_elements.setdefault(node, set()).add(element.element_id)
            for edge in self._element_edges(element):
                self.edge_to_elements.setdefault(edge, set()).add(element.element_id)
        self._rebuild_neighbors(set(self.elements))

    def _rebuild_neighbors(self, element_ids: Set[int]) -> None:
        expanded = set(element_ids)
        for element_id in tuple(element_ids):
            element = self.elements.get(element_id)
            if element is None:
                continue
            for edge in self._element_edges(element):
                expanded.update(self.edge_to_elements.get(edge, set()))
        for element_id in expanded:
            element = self.elements.get(element_id)
            if element is None:
                self.element_neighbors.pop(element_id, None)
                continue
            neighbors: Set[int] = set()
            for edge in self._element_edges(element):
                neighbors.update(self.edge_to_elements.get(edge, set()))
            neighbors.discard(element_id)
            self.element_neighbors[element_id] = neighbors

    def add_node(self, node_id: int, point: Point) -> None:
        self.nodes[node_id] = point
        self.deleted_nodes.discard(node_id)

    def remove_node(self, node_id: int) -> None:
        if self.node_to_elements.get(node_id):
            raise ValueError("cannot delete node {} while elements still reference it".format(node_id))
        self.nodes.pop(node_id, None)
        self.node_to_elements.pop(node_id, None)
        self.deleted_nodes.add(node_id)

    def add_element(self, element: ShellElement) -> None:
        if element.element_id in self.elements:
            raise ValueError("element {} already exists".format(element.element_id))
        missing = [node for node in element.nodes if node not in self.nodes]
        if missing:
            raise ValueError("element {} references missing nodes {}".format(element.element_id, missing))
        self.elements[element.element_id] = element
        self.deleted_elements.discard(element.element_id)
        self.component_elements.setdefault(element.component_id, set()).add(element.element_id)
        for node in element.nodes:
            self.node_to_elements.setdefault(node, set()).add(element.element_id)
        for edge in self._element_edges(element):
            self.edge_to_elements.setdefault(edge, set()).add(element.element_id)
        self._rebuild_neighbors({element.element_id})

    def remove_element(self, element_id: int) -> Optional[ShellElement]:
        element = self.elements.pop(element_id, None)
        if element is None:
            return None
        previous_neighbors = set(self.element_neighbors.get(element_id, set()))
        for node in element.nodes:
            owners = self.node_to_elements.get(node)
            if owners is not None:
                owners.discard(element_id)
                if not owners:
                    self.node_to_elements.pop(node, None)
        for edge in self._element_edges(element):
            owners = self.edge_to_elements.get(edge)
            if owners is not None:
                owners.discard(element_id)
                if not owners:
                    self.edge_to_elements.pop(edge, None)
        owners = self.component_elements.get(element.component_id)
        if owners is not None:
            owners.discard(element_id)
            if not owners:
                self.component_elements.pop(element.component_id, None)
        self.element_neighbors.pop(element_id, None)
        self.deleted_elements.add(element_id)
        self._rebuild_neighbors(previous_neighbors)
        return element

    def update_element(self, element: ShellElement) -> None:
        self.remove_element(element.element_id)
        self.add_element(element)

    def replace_node(self, old_node: int, new_node: int) -> Set[int]:
        if new_node not in self.nodes:
            raise ValueError("replacement node {} does not exist".format(new_node))
        affected = set(self.node_to_elements.get(old_node, set()))
        for element_id in sorted(affected):
            element = self.elements[element_id]
            nodes = tuple(new_node if node == old_node else node for node in element.nodes)
            if len(set(nodes)) < 3:
                self.remove_element(element_id)
            else:
                self.update_element(ShellElement(element_id, element.component_id, nodes))
        if not self.node_to_elements.get(old_node):
            self.remove_node(old_node)
        return affected

    def affected_elements(
        self,
        nodes: Iterable[int] = (),
        elements: Iterable[int] = (),
        rings: int = 1,
    ) -> Set[int]:
        affected = {element for element in elements if element in self.elements}
        for node in nodes:
            affected.update(self.node_to_elements.get(node, set()))
        frontier = set(affected)
        for _ in range(max(0, rings)):
            following: Set[int] = set()
            for element_id in frontier:
                following.update(self.element_neighbors.get(element_id, set()))
            following.difference_update(affected)
            if not following:
                break
            affected.update(following)
            frontier = following
        return affected

    def dirty_region(
        self,
        nodes: Iterable[int],
        elements: Iterable[int],
        rings: int = 1,
    ) -> DirtyRegion:
        dirty_nodes = set(nodes)
        dirty_elements = self.affected_elements(dirty_nodes, elements, rings)
        dirty_edges: Set[Edge] = set()
        for element_id in dirty_elements:
            element = self.elements.get(element_id)
            if element is not None:
                dirty_nodes.update(element.nodes)
                dirty_edges.update(self._element_edges(element))
        return DirtyRegion(dirty_nodes, dirty_elements, dirty_edges)
