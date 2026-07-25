"""Pure-Python quality simulation and conservative candidate line search."""

from __future__ import annotations

import math
from collections import Counter
from typing import Dict, Iterable, List, Mapping, Sequence, Set, Tuple

from adjacency import ShellElement
from mesh_state import MeshState, Point
from operation_model import Operation


def _distance(first: Point, second: Point) -> float:
    return math.sqrt(sum((first[index] - second[index]) ** 2 for index in range(3)))


def _vector(first: Point, second: Point) -> Point:
    return tuple(second[index] - first[index] for index in range(3))


def _cross(first: Point, second: Point) -> Point:
    return (
        first[1] * second[2] - first[2] * second[1],
        first[2] * second[0] - first[0] * second[2],
        first[0] * second[1] - first[1] * second[0],
    )


def _norm(vector: Point) -> float:
    return math.sqrt(sum(value * value for value in vector))


def _angle(previous: Point, center: Point, following: Point) -> float:
    first = _vector(center, previous)
    second = _vector(center, following)
    denominator = _norm(first) * _norm(second)
    if denominator <= 1.0e-14:
        return 0.0
    cosine = max(-1.0, min(1.0, sum(first[i] * second[i] for i in range(3)) / denominator))
    return math.degrees(math.acos(cosine))


def _normal(first: Point, second: Point, third: Point) -> Point:
    return _cross(_vector(first, second), _vector(first, third))


def _element_metrics(element: ShellElement, nodes: Mapping[int, Point]) -> Dict[str, float]:
    points = [nodes[node] for node in element.nodes]
    lengths = [
        _distance(points[index], points[(index + 1) % len(points)])
        for index in range(len(points))
    ]
    angles = [
        _angle(points[index - 1], points[index], points[(index + 1) % len(points)])
        for index in range(len(points))
    ]
    minimum = min(lengths)
    metrics = {
        "minimum_length": minimum,
        "maximum_length": max(lengths),
        "maximum_aspect_ratio": max(lengths) / minimum if minimum > 1.0e-14 else float("inf"),
    }
    if len(points) == 3:
        metrics.update({
            "minimum_angle_tria": min(angles),
            "maximum_angle_tria": max(angles),
            "maximum_skew": max(abs(angle - 60.0) for angle in angles),
        })
        ideal = math.sin(math.radians(60.0))
    else:
        metrics.update({
            "minimum_angle_quad": min(angles),
            "maximum_angle_quad": max(angles),
            "maximum_skew": max(abs(angle - 90.0) for angle in angles),
        })
        first_normal = _normal(points[0], points[1], points[2])
        second_normal = _normal(points[0], points[2], points[3])
        denominator = _norm(first_normal) * _norm(second_normal)
        if denominator <= 1.0e-14:
            metrics["maximum_warpage"] = 180.0
        else:
            cosine = max(-1.0, min(1.0, sum(first_normal[i] * second_normal[i] for i in range(3)) / denominator))
            metrics["maximum_warpage"] = math.degrees(math.acos(cosine))
        ideal = 1.0
    corner_jacobians = []
    for index in range(len(points)):
        first = _vector(points[index], points[index - 1])
        second = _vector(points[index], points[(index + 1) % len(points)])
        denominator = _norm(first) * _norm(second)
        corner_jacobians.append(_norm(_cross(first, second)) / denominator if denominator > 1.0e-14 else 0.0)
    metrics["minimum_jacobian"] = min(corner_jacobians) / ideal
    return metrics


def _is_minimum_metric(name: str) -> bool:
    return name.startswith("minimum_")


def _quality_summary(
    state: MeshState,
    element_ids: Iterable[int],
    limits: Mapping[str, float],
) -> Dict[str, object]:
    failures: Set[Tuple[int, str]] = set()
    counts: Counter = Counter()
    penalty_sum = 0.0
    worst_penalty = 0.0
    for element_id in sorted(set(element_ids)):
        element = state.elements.get(element_id)
        if element is None or any(node not in state.nodes for node in element.nodes):
            continue
        metrics = _element_metrics(element, state.nodes)
        for name, raw_limit in limits.items():
            if name not in metrics:
                continue
            limit = float(raw_limit)
            if limit <= 0.0:
                continue
            value = metrics[name]
            if _is_minimum_metric(name):
                penalty = max(0.0, (limit - value) / limit)
            else:
                penalty = max(0.0, (value - limit) / limit)
            if penalty > 1.0e-10:
                failures.add((element_id, name))
                counts[name] += 1
                penalty_sum += penalty
                worst_penalty = max(worst_penalty, penalty)
    return {
        "failures": failures,
        "counts": counts,
        "failure_count": len(failures),
        "penalty_sum": penalty_sum,
        "worst_penalty": worst_penalty,
    }


def _symmetric_pair(first: Point, second: Point, final_distance: float) -> Tuple[Point, Point]:
    direction = tuple(first[index] - second[index] for index in range(3))
    current = _norm(direction)
    if current <= 1.0e-14 or final_distance < current - 1.0e-12:
        raise ValueError("invalid_symmetric_distance")
    displacement = max(0.0, final_distance - current) / 2.0
    unit = tuple(value / current for value in direction)
    return (
        tuple(first[index] + unit[index] * displacement for index in range(3)),
        tuple(second[index] - unit[index] * displacement for index in range(3)),
    )


def _scaled_distance(current: float, requested: float, scale: float) -> float:
    return current + max(0.0, requested - current) * scale


def _copy_local_state(state: MeshState, element_ids: Iterable[int]) -> MeshState:
    local_elements = {
        element_id: state.elements[element_id]
        for element_id in set(element_ids)
        if element_id in state.elements
    }
    local_node_ids = {
        node
        for element in local_elements.values()
        for node in element.nodes
    }
    local_nodes = {
        node: state.nodes[node]
        for node in local_node_ids
        if node in state.nodes
    }
    return MeshState(local_nodes, local_elements)


def _one_sided_target(node: Point, reference: Point, target: float) -> Point:
    current = _distance(node, reference)
    if current <= 1.0e-14:
        raise ValueError("coincident_move_reference")
    if current >= target:
        return node
    direction = tuple(node[index] - reference[index] for index in range(3))
    return tuple(reference[index] + direction[index] * target / current for index in range(3))


def _movement_updates(
    operation: Operation, state: MeshState, scale: float
) -> Tuple[Dict[int, Point], Dict[str, float]]:
    action = operation.legacy_action
    updates: Dict[int, Point] = {}
    action_updates: Dict[str, float] = {}
    if operation.operation_type == "expand_triangle_short_edge":
        first, second = int(action["node_a"]), int(action["node_b"])
        current = _distance(state.nodes[first], state.nodes[second])
        target = _scaled_distance(current, float(action["target_distance"]), scale)
        updates[first], updates[second] = _symmetric_pair(state.nodes[first], state.nodes[second], target)
        action_updates["target_distance"] = target
    elif operation.operation_type == "expand_internal_quad":
        first, second = int(action["node_a"]), int(action["node_b"])
        reference_first = int(action["reference_a"])
        reference_second = int(action["reference_b"])
        current_first = _distance(state.nodes[first], state.nodes[reference_first])
        current_second = _distance(state.nodes[second], state.nodes[reference_second])
        target_first = _scaled_distance(current_first, float(action["target_distance"]), scale)
        target_second = _scaled_distance(current_second, float(action["target_distance_b"]), scale)
        move_mode = int(action.get("move_mode", 0))
        if move_mode == 1:
            updates[first] = _one_sided_target(state.nodes[first], state.nodes[reference_first], target_first)
            updates[second] = _one_sided_target(state.nodes[second], state.nodes[reference_second], target_second)
        elif move_mode == 2:
            updates[reference_first] = _one_sided_target(state.nodes[reference_first], state.nodes[first], target_first)
            updates[reference_second] = _one_sided_target(state.nodes[reference_second], state.nodes[second], target_second)
        elif move_mode == 0:
            updates[first], updates[reference_first] = _symmetric_pair(state.nodes[first], state.nodes[reference_first], target_first)
            updates[second], updates[reference_second] = _symmetric_pair(state.nodes[second], state.nodes[reference_second], target_second)
        else:
            raise ValueError("invalid_internal_quad_move_mode")
        action_updates.update(target_distance=target_first, target_distance_b=target_second)
    elif operation.operation_type == "expand_free_edge":
        pairs = (
            (int(action["node_a"]), int(action["reference_a"])),
            (int(action["node_b"]), int(action["reference_b"])),
        )
        current_minimum = min(_distance(state.nodes[node], state.nodes[reference]) for node, reference in pairs)
        target = _scaled_distance(current_minimum, float(action["target_distance"]), scale)
        for node, reference in pairs:
            updates[node] = _one_sided_target(state.nodes[node], state.nodes[reference], target)
        action_updates["target_distance"] = target
    else:
        raise ValueError("not_a_movement_operation")
    return updates, action_updates


def _movement_candidate(operation: Operation, state: MeshState, scale: float) -> Tuple[MeshState, Dict[str, float]]:
    candidate = _copy_local_state(state, operation.affected_elements)
    updates, action_updates = _movement_updates(operation, state, scale)
    candidate.nodes.update(updates)
    return candidate, action_updates


def _topology_candidate(operation: Operation, state: MeshState, method: int = 0) -> MeshState:
    action = operation.legacy_action
    candidate = _copy_local_state(state, operation.affected_elements)
    source_id = operation.source_elements[0]
    element = candidate.elements[source_id]
    if operation.operation_type == "split_quad":
        nodes = element.nodes
        selected = method or int(action["split_method"])
        triangles = (
            ((nodes[0], nodes[1], nodes[2]), (nodes[0], nodes[2], nodes[3]))
            if selected == 2 else
            ((nodes[0], nodes[1], nodes[3]), (nodes[1], nodes[2], nodes[3]))
        )
        candidate.remove_element(source_id)
        candidate.add_element(ShellElement(-source_id * 2, element.component_id, triangles[0]))
        candidate.add_element(ShellElement(-source_id * 2 - 1, element.component_id, triangles[1]))
    elif operation.operation_type == "collapse_short_edge":
        first, second = int(action["node_a"]), int(action["node_b"])
        midpoint = tuple((state.nodes[first][index] + state.nodes[second][index]) / 2.0 for index in range(3))
        candidate.nodes[second] = midpoint
        candidate.replace_node(first, second)
    else:
        raise ValueError("not_a_topology_operation")
    return candidate


def _candidate_is_safe(before: Mapping[str, object], after: Mapping[str, object]) -> Tuple[bool, str]:
    before_failures = before["failures"]
    after_failures = after["failures"]
    new_preserved = {
        item for item in after_failures
        if item[0] > 0 and item not in before_failures
    }
    if new_preserved:
        return False, "quality_simulation_would_add_failure"
    before_counts = before["counts"]
    after_counts = after["counts"]
    if any(after_counts[name] > before_counts[name] for name in after_counts):
        return False, "quality_simulation_would_add_failure"
    before_rank = (before["failure_count"], before["worst_penalty"], before["penalty_sum"])
    after_rank = (after["failure_count"], after["worst_penalty"], after["penalty_sum"])
    if after_rank > before_rank:
        return False, "quality_simulation_worsened"
    return True, "quality_simulation_safe"


def optimize_operation_candidate(
    operation: Operation,
    state: MeshState,
    limits: Mapping[str, float],
) -> Tuple[bool, str, Dict[str, object]]:
    """Find the largest simulated candidate that adds no quality failure."""
    if not limits:
        return True, "quality_limits_unavailable", {"accepted_scale": 1.0}
    affected = set(operation.affected_elements)
    before = _quality_summary(state, affected, limits)
    attempts: List[Dict[str, object]] = []
    movement_types = {
        "expand_free_edge", "expand_triangle_short_edge", "expand_internal_quad"
    }
    if operation.operation_type in movement_types:
        candidates = [(scale, None) for scale in (1.0, 0.75, 0.5, 0.25)]
    elif operation.operation_type == "split_quad":
        selected = int(operation.legacy_action.get("split_method", 2))
        candidates = [(1.0, selected), (1.0, 102 if selected == 2 else 2)]
    else:
        candidates = [(1.0, None)]
    last_reason = "quality_simulation_worsened"
    for scale, method in candidates:
        try:
            if operation.operation_type in movement_types:
                candidate, action_updates = _movement_candidate(operation, state, scale)
            else:
                candidate = _topology_candidate(operation, state, method or 0)
                action_updates = {"split_method": method} if method is not None else {}
        except (KeyError, TypeError, ValueError):
            attempts.append({"scale": scale, "method": method, "reason": "simulation_failed"})
            continue
        candidate_ids = set(affected).intersection(candidate.elements)
        candidate_ids.update(element_id for element_id in candidate.elements if element_id < 0)
        after = _quality_summary(candidate, candidate_ids, limits)
        safe, reason = _candidate_is_safe(before, after)
        attempts.append({"scale": scale, "method": method, "reason": reason})
        last_reason = reason
        if not safe:
            continue
        original_method = int(operation.legacy_action.get("split_method", 0))
        operation.legacy_action.update(action_updates)
        accepted_reason = (
            "quality_simulation_safe_step" if scale < 1.0 else
            "quality_simulation_alternate" if method is not None and method != original_method else
            "quality_simulation_safe"
        )
        return True, accepted_reason, {
            "accepted_scale": scale,
            "accepted_method": method,
            "before": {key: value for key, value in before.items() if key != "failures"},
            "after": {key: value for key, value in after.items() if key != "failures"},
            "attempts": attempts,
        }
    return False, last_reason, {"accepted_scale": 0.0, "attempts": attempts}


def optimize_operation_group(
    operations: Sequence[Operation],
    state: MeshState,
    limits: Mapping[str, float],
) -> Tuple[bool, str, Dict[str, object]]:
    """Simulate a coordinated movement chain exactly as Tcl averages it."""
    group = list(operations)
    if not group:
        return True, "quality_simulation_empty_group", {"accepted_scale": 1.0}
    if len(group) == 1:
        return optimize_operation_candidate(group[0], state, limits)
    movement_types = {"expand_free_edge", "expand_internal_quad"}
    if any(operation.operation_type not in movement_types for operation in group):
        return False, "quality_simulation_invalid_group", {"accepted_scale": 0.0}
    if not limits:
        return True, "quality_limits_unavailable", {"accepted_scale": 1.0}
    affected = {
        element_id
        for operation in group
        for element_id in operation.affected_elements
    }
    before = _quality_summary(state, affected, limits)
    attempts: List[Dict[str, object]] = []
    last_reason = "quality_simulation_worsened"
    for scale in (1.0, 0.75, 0.5, 0.25):
        proposals: Dict[int, List[Point]] = {}
        per_operation_updates: List[Dict[str, float]] = []
        try:
            for operation in group:
                node_updates, action_updates = _movement_updates(operation, state, scale)
                per_operation_updates.append(action_updates)
                for node, point in node_updates.items():
                    proposals.setdefault(node, []).append(point)
            candidate = _copy_local_state(state, affected)
            candidate.nodes.update({
                node: tuple(
                    sum(point[index] for point in points) / len(points)
                    for index in range(3)
                )
                for node, points in proposals.items()
            })
        except (KeyError, TypeError, ValueError):
            attempts.append({"scale": scale, "reason": "simulation_failed"})
            continue
        after = _quality_summary(candidate, affected, limits)
        safe, reason = _candidate_is_safe(before, after)
        attempts.append({"scale": scale, "reason": reason})
        last_reason = reason
        if not safe:
            continue
        for operation, action_updates in zip(group, per_operation_updates):
            operation.legacy_action.update(action_updates)
        return True, (
            "quality_simulation_safe_step" if scale < 1.0
            else "quality_simulation_safe_group"
        ), {
            "accepted_scale": scale,
            "operation_count": len(group),
            "before": {key: value for key, value in before.items() if key != "failures"},
            "after": {key: value for key, value in after.items() if key != "failures"},
            "attempts": attempts,
        }
    return False, last_reason, {
        "accepted_scale": 0.0,
        "operation_count": len(group),
        "attempts": attempts,
    }
