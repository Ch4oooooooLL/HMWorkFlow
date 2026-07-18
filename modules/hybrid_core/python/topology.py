"""Element face and edge topology helpers."""
from __future__ import annotations

from collections import defaultdict
from typing import Dict, Iterable, List, Sequence, Tuple

try:
    from .mesh_model import Element
except ImportError:  # Standalone HM2019 entry compatibility.
    from mesh_model import Element

Edge = Tuple[int, int]


def edge_key(a: int, b: int) -> Edge:
    return (a, b) if a < b else (b, a)


def polygon_edges(nodes: Sequence[int], corner_count: int = 0) -> List[Edge]:
    corners = list(nodes[:corner_count] if corner_count else nodes)
    if len(corners) < 2:
        return []
    return [edge_key(corners[index], corners[(index + 1) % len(corners)]) for index in range(len(corners))]


def shell_corner_nodes(element: Element) -> Tuple[int, ...]:
    count = {"CTRIA3": 3, "CTRIA6": 3, "CQUAD4": 4, "CQUAD8": 4}.get(element.element_type)
    if count is None:
        raise ValueError("unsupported shell element type {}".format(element.element_type))
    return element.node_ids[:count]


def solid_faces(element: Element) -> List[Tuple[int, ...]]:
    nodes = element.node_ids
    indices = {
        "CTETRA": ((0, 2, 1), (0, 1, 3), (1, 2, 3), (2, 0, 3)),
        "CPYRA": ((0, 3, 2, 1), (0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)),
        "CPENTA": ((0, 2, 1), (3, 4, 5), (0, 1, 4, 3), (1, 2, 5, 4), (2, 0, 3, 5)),
        "CHEXA": ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)),
    }.get(element.element_type)
    if indices is None:
        raise ValueError("unsupported solid element type {}".format(element.element_type))
    required = max(index for face in indices for index in face) + 1
    if len(nodes) < required:
        raise ValueError("element {} has incomplete connectivity".format(element.element_id))
    return [tuple(nodes[index] for index in face) for face in indices]


def exterior_faces(elements: Iterable[Element]) -> List[Tuple[int, Tuple[int, ...]]]:
    occurrences = defaultdict(list)
    for element in elements:
        for face in solid_faces(element):
            occurrences[tuple(sorted(face))].append((element.element_id, face))
    return [rows[0] for rows in occurrences.values() if len(rows) == 1]


def edge_incidence(elements: Iterable[Element]) -> Dict[Edge, List[int]]:
    result = defaultdict(list)
    for element in elements:
        for edge in polygon_edges(shell_corner_nodes(element)):
            result[edge].append(element.element_id)
    return dict(result)
