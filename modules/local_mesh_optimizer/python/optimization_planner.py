"""Geometry-driven local topology actions for failed shell elements.

The planner never decides whether an element passes quality. It only proposes
bounded repair actions from HyperMesh-exported connectivity and coordinates;
HyperMesh performs every modification and all acceptance checks.
"""

from __future__ import annotations

import math
from typing import Dict, List, Mapping, Optional, Sequence, Set, Tuple

from adjacency import Edge, ShellElement, build_adjacency

Point = Tuple[float, float, float]


def _distance(first: Point, second: Point) -> float:
    return math.sqrt(sum((first[index] - second[index]) ** 2 for index in range(3)))


def _cross_length(first: Point, second: Point, third: Point) -> float:
    ab = tuple(second[index] - first[index] for index in range(3))
    ac = tuple(third[index] - first[index] for index in range(3))
    cross = (
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    )
    return math.sqrt(sum(value * value for value in cross))


def _triangle_score(nodes: Sequence[int], coordinates: Mapping[int, Point]) -> float:
    first, second, third = (coordinates[node] for node in nodes)
    lengths = (
        _distance(first, second),
        _distance(second, third),
        _distance(third, first),
    )
    denominator = sum(value * value for value in lengths)
    if denominator <= 0.0:
        return 0.0
    # 1.0 for an equilateral triangle; approaches zero for a collapsed tria.
    return 2.0 * math.sqrt(3.0) * _cross_length(first, second, third) / denominator


def _edge_lengths(element: ShellElement, coordinates: Mapping[int, Point]) -> List[float]:
    return [
        _distance(
            coordinates[element.nodes[index]],
            coordinates[element.nodes[(index + 1) % len(element.nodes)]],
        )
        for index in range(len(element.nodes))
    ]


def _edge(element: ShellElement, index: int) -> Edge:
    first = element.nodes[index]
    second = element.nodes[(index + 1) % len(element.nodes)]
    return (first, second) if first < second else (second, first)


def _action(region_id: str, action_id: int, action_type: str, element_id: int, reason: str, **values: object) -> dict:
    result = {
        "region_id": region_id,
        "action_id": "{}_{:04d}".format(region_id, action_id),
        "action_type": action_type,
        "element_id": element_id,
        "edge_index": 0,
        "node_a": 0,
        "node_b": 0,
        "reference_a": 0,
        "reference_b": 0,
        "target_distance": 0.0,
        "split_method": 0,
        "reason": reason,
    }
    result.update(values)
    return result


def _quad_action(
    region_id: str,
    action_id: int,
    element: ShellElement,
    coordinates: Mapping[int, Point],
    edge_owners: Mapping[Edge, List[int]],
    protected_nodes: Set[int],
    mandatory_nodes: Set[int],
    allow_free_edge_move: bool,
    narrow_ratio: float,
    target_aspect: float,
) -> dict:
    lengths = _edge_lengths(element, coordinates)
    pair_02 = (lengths[0] + lengths[2]) / 2.0
    pair_13 = (lengths[1] + lengths[3]) / 2.0
    short_indices = (0, 2) if pair_02 <= pair_13 else (1, 3)
    long_indices = (1, 3) if short_indices == (0, 2) else (0, 2)
    short_average = min(pair_02, pair_13)
    long_average = max(pair_02, pair_13)

    if short_average > 0.0 and long_average / short_average >= narrow_ratio:
        free_long = [index for index in long_indices if len(edge_owners.get(_edge(element, index), [])) == 1]
        if free_long:
            edge_index = min(free_long, key=lambda index: lengths[index])
            node_a = element.nodes[edge_index]
            node_b = element.nodes[(edge_index + 1) % 4]
            reference_a = element.nodes[(edge_index - 1) % 4]
            reference_b = element.nodes[(edge_index + 2) % 4]
            moving = {node_a, node_b}
            if allow_free_edge_move and not moving.intersection(mandatory_nodes):
                return _action(
                    region_id,
                    action_id,
                    "expand_free_edge",
                    element.element_id,
                    "narrow_quad_free_edge",
                    edge_index=edge_index + 1,
                    node_a=node_a,
                    node_b=node_b,
                    reference_a=reference_a,
                    reference_b=reference_b,
                    target_distance=long_average / max(target_aspect, 1.0),
                )
            return _action(region_id, action_id, "manual_review", element.element_id, "free_edge_move_protected_or_disabled")

        internal_short = [
            index for index in short_indices if len(edge_owners.get(_edge(element, index), [])) == 2
        ]
        if not internal_short:
            return _action(region_id, action_id, "manual_review", element.element_id, "narrow_quad_has_no_internal_short_edge")
        collapse_index = min(internal_short, key=lambda index: lengths[index])
        collapse_nodes = set(_edge(element, collapse_index))
        if not collapse_nodes.intersection(protected_nodes):
            return _action(
                region_id,
                action_id,
                "collapse_short_edge",
                element.element_id,
                "narrow_internal_quad",
                edge_index=collapse_index + 1,
                node_a=element.nodes[collapse_index],
                node_b=element.nodes[(collapse_index + 1) % 4],
            )
        return _action(region_id, action_id, "manual_review", element.element_id, "narrow_quad_short_edge_protected")

    nodes = element.nodes
    score_02 = min(
        _triangle_score((nodes[0], nodes[1], nodes[2]), coordinates),
        _triangle_score((nodes[0], nodes[2], nodes[3]), coordinates),
    )
    score_13 = min(
        _triangle_score((nodes[0], nodes[1], nodes[3]), coordinates),
        _triangle_score((nodes[1], nodes[2], nodes[3]), coordinates),
    )
    selected_02 = score_02 >= score_13
    diagonal_02 = _distance(coordinates[nodes[0]], coordinates[nodes[2]])
    diagonal_13 = _distance(coordinates[nodes[1]], coordinates[nodes[3]])
    selected_is_shortest = (diagonal_02 <= diagonal_13) == selected_02
    return _action(
        region_id,
        action_id,
        "split_quad",
        element.element_id,
        "best_worst_triangle_score",
        split_method=2 if selected_is_shortest else 102,
    )


def plan_optimization_actions(
    elements: Mapping[int, ShellElement],
    failed_ids: Sequence[int],
    coordinates: Mapping[int, Point],
    regions: Sequence[dict],
    blocked_edges: Optional[Set[Edge]] = None,
    user_anchor_nodes: Optional[Set[int]] = None,
    allow_free_edge_move: bool = True,
    skinny_triangle_ratio: float = 2.5,
    narrow_quad_ratio: float = 2.5,
    narrow_target_aspect: float = 1.5,
) -> List[dict]:
    """Return deterministic, one-per-failed-element repair proposals."""
    blocked_edges = set(blocked_edges or set())
    user_anchor_nodes = set(user_anchor_nodes or set())
    _, edge_owners = build_adjacency(elements)
    region_by_element: Dict[int, dict] = {}
    for region in regions:
        for element_id in region["failed_elements"]:
            region_by_element[element_id] = region

    actions: List[dict] = []
    for action_index, element_id in enumerate(sorted(set(failed_ids)), 1):
        element = elements.get(element_id)
        region = region_by_element.get(element_id)
        if element is None or region is None:
            continue
        region_id = str(region["region_id"])
        if any(node not in coordinates for node in element.nodes):
            actions.append(_action(region_id, action_index, "manual_review", element_id, "missing_coordinates"))
            continue
        protected_nodes = set(region.get("anchor_nodes", [])).union(user_anchor_nodes)
        mandatory_nodes = set(user_anchor_nodes)
        for edge in blocked_edges:
            mandatory_nodes.update(edge)

        if len(element.nodes) == 4:
            actions.append(
                _quad_action(
                    region_id,
                    action_index,
                    element,
                    coordinates,
                    edge_owners,
                    protected_nodes,
                    mandatory_nodes,
                    allow_free_edge_move,
                    narrow_quad_ratio,
                    narrow_target_aspect,
                )
            )
            continue

        lengths = _edge_lengths(element, coordinates)
        ordered = sorted(range(3), key=lambda index: lengths[index])
        shortest, middle, longest = ordered
        if lengths[shortest] > 0.0 and lengths[middle] / lengths[shortest] >= skinny_triangle_ratio and lengths[longest] / lengths[shortest] >= skinny_triangle_ratio:
            collapse_nodes = set(_edge(element, shortest))
            if not collapse_nodes.intersection(protected_nodes):
                actions.append(
                    _action(
                        region_id,
                        action_index,
                        "collapse_short_edge",
                        element_id,
                        "skinny_triangle_two_long_edges",
                        edge_index=shortest + 1,
                        node_a=element.nodes[shortest],
                        node_b=element.nodes[(shortest + 1) % 3],
                    )
                )
            else:
                actions.append(_action(region_id, action_index, "manual_review", element_id, "skinny_triangle_short_edge_protected"))
        else:
            actions.append(_action(region_id, action_index, "manual_review", element_id, "tria_not_matching_safe_collapse_rule"))
    claimed_nodes: Set[int] = set()
    for action in actions:
        if action["action_type"] != "collapse_short_edge":
            continue
        nodes = {int(action["node_a"]), int(action["node_b"])}
        if nodes.intersection(claimed_nodes):
            action["action_type"] = "manual_review"
            action["reason"] = "topology_action_conflict"
        else:
            claimed_nodes.update(nodes)
    for action in actions:
        if action["action_type"] in ("collapse_short_edge", "manual_review"):
            continue
        element = elements[int(action["element_id"])]
        if set(element.nodes).intersection(claimed_nodes):
            action["action_type"] = "manual_review"
            action["reason"] = "adjacent_to_planned_edge_collapse"
    priority = {"collapse_short_edge": 0, "expand_free_edge": 1, "split_quad": 2, "manual_review": 3}
    actions.sort(key=lambda action: (str(action["region_id"]), priority[action["action_type"]], int(action["element_id"])))
    return actions
