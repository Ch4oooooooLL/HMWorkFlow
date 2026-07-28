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


def _element_unit_normal(element: ShellElement, coordinates: Mapping[int, Point]) -> Optional[Point]:
    points = [coordinates[node] for node in element.nodes]
    vector = [0.0, 0.0, 0.0]
    for index, point in enumerate(points):
        following = points[(index + 1) % len(points)]
        vector[0] += (point[1] - following[1]) * (point[2] + following[2])
        vector[1] += (point[2] - following[2]) * (point[0] + following[0])
        vector[2] += (point[0] - following[0]) * (point[1] + following[1])
    length = math.sqrt(sum(value * value for value in vector))
    if length <= 1.0e-14:
        return None
    return tuple(value / length for value in vector)


def _weld_strip_move_mode(
    element: ShellElement,
    long_indices: Sequence[int],
    elements: Mapping[int, ShellElement],
    coordinates: Mapping[int, Point],
    edge_owners: Mapping[Edge, List[int]],
    minimum_perpendicular_angle: float = 60.0,
) -> Optional[int]:
    """Return 0=both sides, 1=first edge, 2=opposite edge."""
    source_normal = _element_unit_normal(element, coordinates)
    if source_normal is None:
        return None
    perpendicular = []
    has_other_component = []
    threshold = math.cos(math.radians(minimum_perpendicular_angle))
    for edge_index in long_indices:
        neighbors = [
            elements[owner]
            for owner in edge_owners.get(_edge(element, edge_index), [])
            if owner != element.element_id and owner in elements
        ]
        cross_component = [
            neighbor for neighbor in neighbors
            if neighbor.component_id != element.component_id
        ]
        has_other_component.append(bool(cross_component))
        side_is_perpendicular = False
        for neighbor in cross_component:
            neighbor_normal = _element_unit_normal(neighbor, coordinates)
            if neighbor_normal is None:
                continue
            cosine = abs(sum(source_normal[index] * neighbor_normal[index] for index in range(3)))
            if cosine <= threshold + 1.0e-12:
                side_is_perpendicular = True
                break
        perpendicular.append(side_is_perpendicular)
    if not all(has_other_component) or not any(perpendicular):
        return None
    if all(perpendicular):
        return 0
    # Translate the junction chain attached to the perpendicular shell along
    # the weld strip's short-edge axis. The attached shell row follows as a
    # planar tilt/translation instead of being compressed by the opposite side.
    return 1 if perpendicular[0] else 2


def _minimum_passing_short_length(
    long_length: float,
    minimum_length: float,
    maximum_aspect_ratio: Optional[float],
    fallback_target_aspect: Optional[float] = None,
) -> float:
    targets = [max(0.0, minimum_length)]
    if maximum_aspect_ratio is not None and maximum_aspect_ratio > 0.0:
        targets.append(long_length / maximum_aspect_ratio)
    elif fallback_target_aspect is not None and fallback_target_aspect > 0.0:
        targets.append(long_length / fallback_target_aspect)
    return max(targets)


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
        "target_distance_b": 0.0,
        "move_mode": 0,
        "split_method": 0,
        "reason": reason,
    }
    result.update(values)
    return result


def _assign_expansion_chain_ids(actions: List[dict]) -> None:
    """Label connected free-edge action chains using the compatibility field.

    ``split_method`` is unused by expansion actions and already travels through
    the CSV/Tcl protocol, so it safely carries a deterministic chain ID without
    widening the legacy file schema.
    """
    by_region: Dict[str, List[int]] = {}
    for index, action in enumerate(actions):
        if action["action_type"] in ("expand_free_edge", "expand_internal_quad"):
            by_region.setdefault(str(action["region_id"]), []).append(index)
    chain_id = 0
    for region_id in sorted(by_region):
        indices = by_region[region_id]
        node_to_indices: Dict[int, List[int]] = {}
        for index in indices:
            action = actions[index]
            nodes = (int(action["node_a"]), int(action["node_b"]))
            if action["action_type"] == "expand_internal_quad":
                nodes += (int(action["reference_a"]), int(action["reference_b"]))
            for node in nodes:
                node_to_indices.setdefault(node, []).append(index)
        pending = set(indices)
        while pending:
            chain_id += 1
            seed = min(pending, key=lambda index: int(actions[index]["element_id"]))
            pending.remove(seed)
            stack = [seed]
            component = []
            while stack:
                current = stack.pop()
                component.append(current)
                action = actions[current]
                nodes = (int(action["node_a"]), int(action["node_b"]))
                if action["action_type"] == "expand_internal_quad":
                    nodes += (int(action["reference_a"]), int(action["reference_b"]))
                for node in nodes:
                    for neighbor in node_to_indices.get(node, []):
                        if neighbor in pending:
                            pending.remove(neighbor)
                            stack.append(neighbor)
            for index in component:
                actions[index]["split_method"] = chain_id


def _quad_actions(
    region_id: str,
    action_id: int,
    element: ShellElement,
    elements: Mapping[int, ShellElement],
    coordinates: Mapping[int, Point],
    edge_owners: Mapping[Edge, List[int]],
    protected_nodes: Set[int],
    mandatory_nodes: Set[int],
    allow_free_edge_move: bool,
    allow_internal_quad_expansion: bool,
    narrow_ratio: float,
    target_aspect: float,
    minimum_length: float,
    maximum_aspect_ratio: Optional[float],
    user_anchor_nodes: Set[int],
    support_action: bool = False,
) -> List[dict]:
    lengths = _edge_lengths(element, coordinates)
    pair_02 = (lengths[0] + lengths[2]) / 2.0
    pair_13 = (lengths[1] + lengths[3]) / 2.0
    short_indices = (0, 2) if pair_02 <= pair_13 else (1, 3)
    long_indices = (1, 3) if short_indices == (0, 2) else (0, 2)
    short_average = min(pair_02, pair_13)
    long_average = max(pair_02, pair_13)

    if short_average > 0.0 and long_average / short_average >= narrow_ratio:
        passing_short = _minimum_passing_short_length(
            long_average,
            minimum_length,
            maximum_aspect_ratio,
            target_aspect,
        )
        free_long = [index for index in long_indices if len(edge_owners.get(_edge(element, index), [])) == 1]
        if free_long:
            edge_index = min(free_long, key=lambda index: lengths[index])
            node_a = element.nodes[edge_index]
            node_b = element.nodes[(edge_index + 1) % 4]
            reference_a = element.nodes[(edge_index - 1) % 4]
            reference_b = element.nodes[(edge_index + 2) % 4]
            moving = {node_a, node_b}
            if allow_free_edge_move and not moving.intersection(mandatory_nodes):
                return [_action(
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
                    target_distance=max(short_average, passing_short),
                )]
            return [_action(region_id, action_id, "manual_review", element.element_id, "free_edge_move_protected_or_disabled")]

        if any(len(edge_owners.get(_edge(element, index), [])) != 2 for index in range(4)):
            return [_action(
                region_id,
                action_id,
                "manual_review",
                element.element_id,
                "narrow_quad_not_fully_internal",
            )]
        if not allow_internal_quad_expansion:
            return [_action(region_id, action_id, "manual_review", element.element_id, "internal_quad_expansion_disabled")]
        weld_move_mode = _weld_strip_move_mode(
            element, long_indices, elements, coordinates, edge_owners
        )
        protected_for_move = user_anchor_nodes if weld_move_mode is not None else mandatory_nodes
        if set(element.nodes).intersection(protected_for_move):
            return [_action(region_id, action_id, "manual_review", element.element_id, "internal_quad_expansion_protected")]
        edge_index = long_indices[0]
        current_a = lengths[(edge_index - 1) % 4]
        current_b = lengths[(edge_index + 1) % 4]
        target_a = max(current_a, passing_short)
        target_b = max(current_b, passing_short)
        if (target_a <= current_a + 1.0e-12 and target_b <= current_b + 1.0e-12
                and not support_action):
            return [_action(region_id, action_id, "manual_review", element.element_id, "internal_quad_has_no_criteria_expansion_target")]
        reason = "narrow_internal_quad_symmetric_expansion"
        if weld_move_mode == 0:
            reason = "weld_strip_two_side_chain_expansion"
        elif weld_move_mode in (1, 2):
            reason = "weld_strip_single_side_chain_translation"
        return [_action(
            region_id,
            action_id,
            "expand_internal_quad",
            element.element_id,
            reason,
            edge_index=edge_index + 1,
            node_a=element.nodes[edge_index],
            node_b=element.nodes[(edge_index + 1) % 4],
            reference_a=element.nodes[(edge_index - 1) % 4],
            reference_b=element.nodes[(edge_index + 2) % 4],
            target_distance=target_a,
            target_distance_b=target_b,
            move_mode=weld_move_mode or 0,
        )]

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
    return [_action(
        region_id,
        action_id,
        "split_quad",
        element.element_id,
        "best_worst_triangle_score",
        split_method=2 if selected_is_shortest else 102,
    )]


def _extend_narrow_quad_chains(
    actions: List[dict],
    failed_ids: Set[int],
    regions: Sequence[dict],
    elements: Mapping[int, ShellElement],
    coordinates: Mapping[int, Point],
    edge_owners: Mapping[Edge, List[int]],
    blocked_edges: Set[Edge],
    user_anchor_nodes: Set[int],
    allow_free_edge_move: bool,
    allow_internal_quad_expansion: bool,
    narrow_quad_ratio: float,
    narrow_target_aspect: float,
    minimum_length: float,
    maximum_aspect_ratio: Optional[float],
) -> None:
    """Grow failed narrow-quad seeds through the complete contiguous strip.

    HyperMesh commonly reports only alternating cells of an otherwise uniform
    narrow strip. Moving only those failed cells creates a saw-tooth boundary
    and is correctly rejected by the quality simulator. Support actions make
    every narrow quad between/around the failed seeds participate in the same
    coordinated node-chain move.
    """
    region_map = {str(region["region_id"]): region for region in regions}
    mandatory_nodes = set(user_anchor_nodes)
    for edge in blocked_edges:
        mandatory_nodes.update(edge)
    expansion_types = {"expand_free_edge", "expand_internal_quad"}
    existing = {
        (str(action["region_id"]), str(action["action_type"]), int(action["element_id"]))
        for action in actions
        if action["action_type"] in expansion_types
    }
    queue = [action for action in actions if action["action_type"] in expansion_types]
    queue_index = 0
    while queue_index < len(queue):
        seed = queue[queue_index]
        queue_index += 1
        seed_element = elements.get(int(seed["element_id"]))
        if seed_element is None or len(seed_element.nodes) != 4:
            continue
        edge_index = int(seed["edge_index"]) - 1
        if edge_index not in range(4):
            continue
        short_edges = ((edge_index - 1) % 4, (edge_index + 1) % 4)
        for short_edge_index in short_edges:
            for neighbor_id in edge_owners.get(_edge(seed_element, short_edge_index), []):
                if neighbor_id == seed_element.element_id:
                    continue
                neighbor = elements.get(neighbor_id)
                if (neighbor is None or len(neighbor.nodes) != 4 or
                        neighbor.component_id != seed_element.component_id or
                        any(node not in coordinates for node in neighbor.nodes)):
                    continue
                key = (str(seed["region_id"]), str(seed["action_type"]), neighbor_id)
                if key in existing:
                    continue
                region = region_map.get(str(seed["region_id"]), {})
                candidate = _quad_actions(
                    str(seed["region_id"]),
                    0,
                    neighbor,
                    elements,
                    coordinates,
                    edge_owners,
                    set(region.get("anchor_nodes", [])).union(user_anchor_nodes),
                    mandatory_nodes,
                    allow_free_edge_move,
                    allow_internal_quad_expansion,
                    max(1.5, narrow_quad_ratio * 0.6),
                    narrow_target_aspect,
                    minimum_length,
                    maximum_aspect_ratio,
                    user_anchor_nodes,
                    support_action=True,
                )[0]
                if candidate["action_type"] != seed["action_type"]:
                    continue
                # A weld strip must keep the selected moving side consistent
                # along the whole chain. Local missing/mismatched neighbour
                # ownership must not flip one cell to symmetric movement.
                if str(seed.get("reason", "")).startswith("weld_strip_"):
                    candidate["move_mode"] = int(seed.get("move_mode", 0))
                if neighbor_id not in failed_ids:
                    candidate["reason"] = "narrow_quad_chain_support"
                actions.append(candidate)
                queue.append(candidate)
                existing.add(key)


def plan_optimization_actions(
    elements: Mapping[int, ShellElement],
    failed_ids: Sequence[int],
    coordinates: Mapping[int, Point],
    regions: Sequence[dict],
    blocked_edges: Optional[Set[Edge]] = None,
    user_anchor_nodes: Optional[Set[int]] = None,
    allow_free_edge_move: bool = True,
    allow_internal_quad_expansion: bool = False,
    skinny_triangle_ratio: float = 2.5,
    narrow_quad_ratio: float = 2.5,
    narrow_target_aspect: float = 1.5,
    minimum_length: float = 0.0,
    maximum_aspect_ratio: Optional[float] = None,
) -> List[dict]:
    """Return deterministic repair proposals for failed shell elements.

    A skinny triangle contributes one short-edge collapse. A fully internal
    narrow quad contributes the two opposite short-edge collapses needed to
    remove the complete thin strip.
    """
    blocked_edges = set(blocked_edges or set())
    user_anchor_nodes = set(user_anchor_nodes or set())
    _, edge_owners = build_adjacency(elements)
    region_by_element: Dict[int, dict] = {}
    for region in regions:
        for element_id in region["failed_elements"]:
            region_by_element[element_id] = region

    failed_set = set(failed_ids)
    actions: List[dict] = []
    for action_index, element_id in enumerate(sorted(failed_set), 1):
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
            actions.extend(
                _quad_actions(
                    region_id,
                    action_index,
                    element,
                    elements,
                    coordinates,
                    edge_owners,
                    protected_nodes,
                    mandatory_nodes,
                    allow_free_edge_move,
                    allow_internal_quad_expansion,
                    narrow_quad_ratio,
                    narrow_target_aspect,
                    minimum_length,
                    maximum_aspect_ratio,
                    user_anchor_nodes,
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
            passing_short = _minimum_passing_short_length(
                lengths[longest], minimum_length, maximum_aspect_ratio
            )
            moderate_ratio = lengths[longest] / lengths[shortest] < skinny_triangle_ratio
            if moderate_ratio and passing_short > lengths[shortest] + 1.0e-12:
                moving = set(_edge(element, shortest))
                if moving.intersection(mandatory_nodes):
                    actions.append(_action(region_id, action_index, "manual_review", element_id, "triangle_short_edge_expansion_protected"))
                else:
                    actions.append(_action(
                        region_id,
                        action_index,
                        "expand_triangle_short_edge",
                        element_id,
                        "moderate_triangle_short_edge_below_criteria",
                        edge_index=shortest + 1,
                        node_a=element.nodes[shortest],
                        node_b=element.nodes[(shortest + 1) % 3],
                        target_distance=passing_short,
                    ))
            else:
                actions.append(_action(region_id, action_index, "manual_review", element_id, "tria_not_matching_safe_collapse_rule"))
    _extend_narrow_quad_chains(
        actions,
        failed_set,
        regions,
        elements,
        coordinates,
        edge_owners,
        blocked_edges,
        user_anchor_nodes,
        allow_free_edge_move,
        allow_internal_quad_expansion,
        narrow_quad_ratio,
        narrow_target_aspect,
        minimum_length,
        maximum_aspect_ratio,
    )
    # A skinny triangle can share its short edge with another failed shell. A
    # midpoint node replacement intentionally removes that sliver and updates
    # the neighbour, so shared failure ownership alone is not a conflict.
    # Exact duplicate edge proposals are retained for provenance and are
    # deduplicated by the operation adapter below the planner. Different
    # collapse directions that merely meet at one node remain conflicts.
    claimed_nodes: Set[int] = set()
    claimed_edges: Set[Edge] = set()
    for action in actions:
        if action["action_type"] != "collapse_short_edge":
            continue
        nodes = {int(action["node_a"]), int(action["node_b"])}
        edge = tuple(sorted(nodes))
        if edge in claimed_edges:
            # Keep exact duplicates until operation adaptation so provenance is
            # retained in deduplication_events.json.
            continue
        if nodes.intersection(claimed_nodes):
            action["action_type"] = "manual_review"
            action["reason"] = "topology_action_conflict"
        else:
            claimed_nodes.update(nodes)
            claimed_edges.add(edge)
    for action in actions:
        if action["action_type"] in ("collapse_short_edge", "manual_review"):
            continue
        element = elements[int(action["element_id"])]
        if set(element.nodes).intersection(claimed_nodes):
            action["action_type"] = "manual_review"
            action["reason"] = "adjacent_to_planned_edge_collapse"
    _assign_expansion_chain_ids(actions)
    priority = {
        "collapse_short_edge": 0,
        "expand_free_edge": 1,
        "expand_internal_quad": 1,
        "expand_triangle_short_edge": 1,
        "split_quad": 2,
        "manual_review": 3,
    }
    actions.sort(key=lambda action: (
        str(action["region_id"]),
        priority[action["action_type"]],
        int(action["element_id"]),
        min(int(action.get("node_a", 0)), int(action.get("node_b", 0))),
        max(int(action.get("node_a", 0)), int(action.get("node_b", 0))),
    ))
    for index, action in enumerate(actions, 1):
        action["action_id"] = "{}_A{:06d}".format(action["region_id"], index)
    return actions
