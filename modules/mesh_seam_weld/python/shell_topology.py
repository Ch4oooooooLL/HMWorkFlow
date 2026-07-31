"""Automatic seam topology model built on HybridCore's shared detector."""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

COMMON_DIR = Path(__file__).resolve().parents[2] / "hybrid_core" / "python"
if str(COMMON_DIR) not in sys.path: sys.path.insert(0, str(COMMON_DIR))
from shell_weld_detection import build_component_topology, connected_edge_paths, element_edges  # noqa: E402


@dataclass(frozen=True)
class ShellElement:
    element_id: int
    component_id: int
    property_id: int
    element_type: str
    node_ids: Tuple[int, ...]


@dataclass
class FreeEdgePath:
    path_id: str
    component_id: int
    node_ids: List[int]
    edge_pairs: List[List[int]]
    closed: bool
    length: float
    adjacent_element_ids: List[int]
    branched: bool = False


def model_records(model):
    components = [{"component_id": item.component_id, "component_name": item.component_name} for item in model.components.values()]
    elements = [{"element_id": item.element_id, "component_id": item.component_id, "element_type": item.element_type, "node_ids": list(item.node_ids)} for item in model.elements.values()]
    return components, elements


def build(model):
    components, elements = model_records(model)
    return build_component_topology(components, model.nodes, elements)


def free_edge_paths(model):
    result: Dict[int, List[FreeEdgePath]] = {}
    for component_id, topology in sorted(build(model).items()):
        rows = connected_edge_paths(topology.free_edges, model.nodes)
        result[component_id] = [FreeEdgePath("C{}_P{:04d}".format(component_id, index), component_id, row["node_ids"], row["edge_pairs"], row["closed"], row["length"], row["adjacent_element_ids"], row["branched"]) for index, row in enumerate(rows, 1)]
    return result


def edge_graph(model, component_id, free_only=False):
    incidence = {}
    for element in model.elements_for_components([component_id]):
        for edge in element_edges(element.node_ids): incidence.setdefault(edge, []).append(element.element_id)
    graph = {}
    for edge, owners in incidence.items():
        if free_only and len(owners) != 1: continue
        graph.setdefault(edge[0], set()).add(edge[1]); graph.setdefault(edge[1], set()).add(edge[0])
    return graph, incidence
