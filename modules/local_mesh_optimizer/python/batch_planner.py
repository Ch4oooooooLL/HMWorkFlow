"""Conservative simulation, conflict analysis and deterministic batching."""

from __future__ import annotations

import csv
import io
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

from adjacency import ShellElement
from io_utils import atomic_write_json, atomic_write_text
from mesh_state import MeshState, Point, edge_key
from operation_model import Operation


def _triangle_area(first: Point, second: Point, third: Point) -> float:
    ab = tuple(second[index] - first[index] for index in range(3))
    ac = tuple(third[index] - first[index] for index in range(3))
    cross = (
        ab[1] * ac[2] - ab[2] * ac[1],
        ab[2] * ac[0] - ab[0] * ac[2],
        ab[0] * ac[1] - ab[1] * ac[0],
    )
    return 0.5 * math.sqrt(sum(value * value for value in cross))


def _symmetric_targets(first: Point, second: Point, final_distance: float) -> Tuple[Point, Point]:
    vector = tuple(first[index] - second[index] for index in range(3))
    current = math.sqrt(sum(value * value for value in vector))
    if current <= 1.0e-14 or not math.isfinite(final_distance) or final_distance < current - 1.0e-12:
        raise ValueError("invalid_symmetric_expansion_distance")
    if final_distance <= current + 1.0e-12:
        return first, second
    displacement = (final_distance - current) / 2.0
    unit = tuple(value / current for value in vector)
    return (
        tuple(first[index] + unit[index] * displacement for index in range(3)),
        tuple(second[index] - unit[index] * displacement for index in range(3)),
    )


def _one_sided_target(node: Point, reference: Point, final_distance: float) -> Point:
    vector = tuple(node[index] - reference[index] for index in range(3))
    current = math.sqrt(sum(value * value for value in vector))
    if current <= 1.0e-14 or not math.isfinite(final_distance) or final_distance < current - 1.0e-12:
        raise ValueError("invalid_one_sided_expansion_distance")
    if final_distance <= current + 1.0e-12:
        return node
    return tuple(reference[index] + vector[index] * final_distance / current for index in range(3))


def _area_vector(points: Sequence[Point]) -> Point:
    vector = [0.0, 0.0, 0.0]
    for index, point in enumerate(points):
        following = points[(index + 1) % len(points)]
        vector[0] += (point[1] - following[1]) * (point[2] + following[2])
        vector[1] += (point[2] - following[2]) * (point[0] + following[0])
        vector[2] += (point[0] - following[0]) * (point[1] + following[1])
    return tuple(vector)


def _movement_preserves_shells(state: MeshState, targets: Mapping[int, Point]) -> bool:
    affected = state.affected_elements(targets, rings=0)
    for element_id in affected:
        element = state.elements[element_id]
        original = _area_vector([state.nodes[node] for node in element.nodes])
        moved = _area_vector([targets.get(node, state.nodes[node]) for node in element.nodes])
        original_norm = math.sqrt(sum(value * value for value in original))
        moved_norm = math.sqrt(sum(value * value for value in moved))
        if original_norm <= 1.0e-14 or moved_norm <= max(1.0e-14, original_norm * 1.0e-8):
            return False
        if sum(original[index] * moved[index] for index in range(3)) <= 0.0:
            return False
    return True


def prevalidate_operation(
    operation: Operation,
    state: MeshState,
    protected_nodes: Optional[Set[int]] = None,
    validate_movement_geometry: bool = True,
) -> Tuple[bool, str]:
    protected_nodes = set(protected_nodes or set())
    if operation.operation_type == "manual_review":
        return False, "manual_review"
    if not operation.source_elements or operation.source_elements[0] not in state.elements:
        return False, "source_element_missing"
    if any(node not in state.nodes for node in operation.source_nodes):
        return False, "source_node_missing"
    action = operation.legacy_action
    if operation.operation_type == "split_quad":
        element = state.elements[operation.source_elements[0]]
        if len(element.nodes) != 4:
            return False, "split_requires_quad"
        nodes = element.nodes
        method = int(action.get("split_method", 0))
        triangles = (
            ((nodes[0], nodes[1], nodes[2]), (nodes[0], nodes[2], nodes[3]))
            if method == 2
            else ((nodes[0], nodes[1], nodes[3]), (nodes[1], nodes[2], nodes[3]))
        )
        if method not in (2, 102):
            return False, "unsupported_split_method"
        if any(_triangle_area(*(state.nodes[node] for node in triangle)) <= 1.0e-14 for triangle in triangles):
            return False, "split_would_create_zero_area_triangle"
        if any(state.node_signature_to_elements.get(tuple(sorted(triangle))) for triangle in triangles):
            return False, "split_would_create_duplicate_triangle"
    elif operation.operation_type == "collapse_short_edge":
        first = int(action.get("node_a", 0))
        second = int(action.get("node_b", 0))
        if first == second or first not in state.nodes or second not in state.nodes:
            return False, "invalid_collapse_edge"
        if {first, second}.intersection(protected_nodes):
            return False, "collapse_touches_protected_node"
        owners = state.edge_to_elements.get(edge_key(first, second), set())
        if not owners:
            return False, "collapse_edge_no_longer_exists"
    elif operation.operation_type == "expand_free_edge":
        first = int(action.get("node_a", 0))
        second = int(action.get("node_b", 0))
        references = {int(action.get("reference_a", 0)), int(action.get("reference_b", 0))}
        if {first, second}.intersection(protected_nodes):
            return False, "move_touches_protected_node"
        if any(node not in state.nodes for node in {first, second}.union(references)):
            return False, "move_node_or_reference_missing"
        if len(state.edge_to_elements.get(edge_key(first, second), set())) != 1:
            return False, "edge_no_longer_free"
    elif operation.operation_type == "expand_triangle_short_edge":
        first = int(action.get("node_a", 0))
        second = int(action.get("node_b", 0))
        if {first, second}.intersection(protected_nodes):
            return False, "move_touches_protected_node"
        if first not in state.nodes or second not in state.nodes:
            return False, "move_node_missing"
        if not state.edge_to_elements.get(edge_key(first, second)):
            return False, "triangle_short_edge_no_longer_exists"
        try:
            target_first, target_second = _symmetric_targets(
                state.nodes[first], state.nodes[second], float(action.get("target_distance", 0.0))
            )
        except (TypeError, ValueError):
            return False, "invalid_triangle_expansion_distance"
        if not _movement_preserves_shells(
            state, {first: target_first, second: target_second}
        ):
            return False, "triangle_expansion_would_invert_or_collapse_shell"
    elif operation.operation_type == "expand_internal_quad":
        element = state.elements[operation.source_elements[0]]
        if len(element.nodes) != 4:
            return False, "internal_expansion_requires_quad"
        first = int(action.get("node_a", 0))
        second = int(action.get("node_b", 0))
        reference_first = int(action.get("reference_a", 0))
        reference_second = int(action.get("reference_b", 0))
        all_nodes = {first, second, reference_first, reference_second}
        if all_nodes != set(element.nodes):
            return False, "internal_expansion_nodes_do_not_match_quad"
        move_mode = int(action.get("move_mode", 0))
        moving = set()
        if move_mode in (0, 1):
            moving.update((first, second))
        if move_mode in (0, 2):
            moving.update((reference_first, reference_second))
        if move_mode not in (0, 1, 2):
            return False, "invalid_internal_quad_move_mode"
        if moving.intersection(protected_nodes):
            return False, "move_touches_protected_node"
        try:
            target_first, target_reference_first = _symmetric_targets(
                state.nodes[first], state.nodes[reference_first],
                float(action.get("target_distance", 0.0)),
            )
            target_second, target_reference_second = _symmetric_targets(
                state.nodes[second], state.nodes[reference_second],
                float(action.get("target_distance_b", action.get("target_distance", 0.0))),
            )
        except (KeyError, TypeError, ValueError):
            return False, "invalid_internal_quad_expansion_distance"
        targets = {}
        try:
            if move_mode == 0:
                targets.update({first: target_first, second: target_second, reference_first: target_reference_first, reference_second: target_reference_second})
            elif move_mode == 1:
                targets.update({
                    first: _one_sided_target(state.nodes[first], state.nodes[reference_first], float(action.get("target_distance", 0.0))),
                    second: _one_sided_target(state.nodes[second], state.nodes[reference_second], float(action.get("target_distance_b", action.get("target_distance", 0.0)))),
                })
            else:
                targets.update({
                    reference_first: _one_sided_target(state.nodes[reference_first], state.nodes[first], float(action.get("target_distance", 0.0))),
                    reference_second: _one_sided_target(state.nodes[reference_second], state.nodes[second], float(action.get("target_distance_b", action.get("target_distance", 0.0)))),
                })
        except (KeyError, TypeError, ValueError):
            return False, "invalid_internal_quad_expansion_distance"
        if validate_movement_geometry and not _movement_preserves_shells(state, targets):
            return False, "internal_quad_expansion_would_invert_or_collapse_shell"
    else:
        return False, "unknown_operation_type"
    return True, "ok"


def _sets_conflict(first: Operation, second: Operation) -> Optional[str]:
    if first.operation_type == "expand_free_edge" and second.operation_type == "expand_free_edge":
        # Free-boundary actions are intentionally coordinated in one batch.
        # The Tcl executor accumulates both endpoint proposals, averages shared
        # nodes, and then moves each direction block only once.
        return None
    if first.operation_type == "expand_internal_quad" and second.operation_type == "expand_internal_quad":
        first_chain = int(first.legacy_action.get("split_method", 0))
        second_chain = int(second.legacy_action.get("split_method", 0))
        if first_chain > 0 and first_chain == second_chain:
            return None
    a, b = first.access, second.access
    if a.write_nodes.intersection(b.write_nodes):
        return "shared_write_node"
    if a.delete_nodes.intersection(b.read_nodes.union(b.write_nodes)) or b.delete_nodes.intersection(a.read_nodes.union(a.write_nodes)):
        return "delete_read_node"
    if a.delete_elements.intersection(b.read_elements.union(b.write_elements)) or b.delete_elements.intersection(a.read_elements.union(a.write_elements)):
        return "delete_read_element"
    if a.write_elements.intersection(b.write_elements):
        return "shared_write_element"
    if set(first.affected_elements).intersection(second.affected_elements):
        return "overlapping_one_ring"
    first_replacements = {
        int(first.legacy_action.get("node_a", 0)), int(first.legacy_action.get("node_b", 0))
    } if first.operation_type == "collapse_short_edge" else set()
    second_replacements = {
        int(second.legacy_action.get("node_a", 0)), int(second.legacy_action.get("node_b", 0))
    } if second.operation_type == "collapse_short_edge" else set()
    if first_replacements.intersection(second.access.read_nodes) or second_replacements.intersection(first.access.read_nodes):
        return "collapse_replacement_dependency"
    return None


def conflict_graph(operations: Sequence[Operation]) -> Tuple[Dict[str, Set[str]], List[Dict[str, str]]]:
    graph = {operation.operation_id: set() for operation in operations}
    edges: List[Dict[str, str]] = []
    # Build sparse candidate pairs from shared resources instead of comparing
    # every operation with every other operation. The exact rules remain in
    # _sets_conflict; this index only avoids impossible comparisons.
    resource_owners: Dict[Tuple[str, int], List[int]] = {}
    for index, operation in enumerate(operations):
        node_resources = (
            operation.access.read_nodes
            .union(operation.access.write_nodes)
            .union(operation.access.delete_nodes)
        )
        element_resources = (
            operation.access.read_elements
            .union(operation.access.write_elements)
            .union(operation.access.delete_elements)
            .union(operation.affected_elements)
        )
        for node in node_resources:
            resource_owners.setdefault(("node", node), []).append(index)
        for element in element_resources:
            resource_owners.setdefault(("element", element), []).append(index)
    candidate_pairs: Set[Tuple[int, int]] = set()
    for owners in resource_owners.values():
        for owner_index, first in enumerate(owners):
            for second in owners[owner_index + 1 :]:
                candidate_pairs.add((first, second) if first < second else (second, first))
    for first_index, second_index in sorted(candidate_pairs):
        first = operations[first_index]
        second = operations[second_index]
        reason = _sets_conflict(first, second)
        if reason is None:
            continue
        graph[first.operation_id].add(second.operation_id)
        graph[second.operation_id].add(first.operation_id)
        edges.append({"first": first.operation_id, "second": second.operation_id, "reason": reason})
    return graph, edges


@dataclass
class OperationBatch:
    batch_id: str
    stage: str
    region_id: str
    operations: List[Operation]

    def to_dict(self) -> Dict[str, object]:
        return {
            "batch_id": self.batch_id,
            "stage": self.stage,
            "region_id": self.region_id,
            "operation_ids": [operation.operation_id for operation in self.operations],
            "operation_count": len(self.operations),
        }


def plan_batches(operations: Sequence[Operation], max_operations: int = 200) -> Tuple[List[OperationBatch], List[Dict[str, str]]]:
    executable = [operation for operation in operations if operation.status == "pending" and operation.operation_type != "manual_review"]
    executable.sort(
        key=lambda operation: (
            operation.stage,
            operation.priority,
            str(operation.metadata.get("region_id", "")),
            operation.operation_id,
        )
    )
    _, conflicts = conflict_graph(executable)
    incompatible = {
        frozenset((edge["first"], edge["second"])) for edge in conflicts
    }
    groups: Dict[Tuple[str, str, str], List[List[Operation]]] = {}
    for operation in executable:
        chain_id = int(operation.legacy_action.get("split_method", 0))
        coordination = (
            "{}:{}".format(operation.operation_type, chain_id)
            if operation.operation_type in ("expand_free_edge", "expand_internal_quad") and chain_id > 0
            else "default"
        )
        key = (operation.stage, str(operation.metadata.get("region_id", "")), coordination)
        buckets = groups.setdefault(key, [])
        placed = False
        for bucket in buckets:
            if coordination == "default" and len(bucket) >= max(1, max_operations):
                continue
            if any(frozenset((operation.operation_id, other.operation_id)) in incompatible for other in bucket):
                continue
            bucket.append(operation)
            placed = True
            break
        if not placed:
            buckets.append([operation])
    batches: List[OperationBatch] = []
    batch_index = 0
    for (stage, region_id, _coordination), buckets in sorted(groups.items()):
        for bucket in buckets:
            batch_index += 1
            batches.append(OperationBatch("{}_batch_{:04d}".format(stage, batch_index), stage, region_id, bucket))
    return batches, conflicts


def _tcl_quoted(value: object) -> str:
    text = str(value).replace("\\", "/")
    text = (
        text.replace("$", "\\$")
        .replace("[", "\\[")
        .replace("]", "\\]")
        .replace('"', '\\"')
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )
    return '"' + text + '"'


def _legacy_tcl_dict(operation: Operation) -> str:
    action = operation.legacy_action
    mapping = (
        ("actionId", "action_id"), ("actionType", "action_type"),
        ("elementId", "element_id"), ("edgeIndex", "edge_index"),
        ("nodeA", "node_a"), ("nodeB", "node_b"),
        ("referenceA", "reference_a"), ("referenceB", "reference_b"),
        ("targetDistance", "target_distance"), ("targetDistanceB", "target_distance_b"),
        ("moveMode", "move_mode"),
        ("splitMethod", "split_method"),
        ("reason", "reason"),
    )
    fields = ["operationId", _tcl_quoted(operation.operation_id)]
    for tcl_key, python_key in mapping:
        fields.extend((tcl_key, _tcl_quoted(action.get(python_key, ""))))
    return "[dict create {}]".format(" ".join(fields))


def write_batch_artifacts(task_dir: Path, operations: Sequence[Operation], batches: Sequence[OperationBatch], conflicts: Sequence[Mapping[str, str]]) -> None:
    batch_dir = task_dir / "batches"
    batch_dir.mkdir(parents=True, exist_ok=True)
    rows = io.StringIO()
    writer = csv.writer(rows, lineterminator="\n")
    writer.writerow(("region_id", "batch_id", "stage", "operation_count", "batch_file"))
    for batch in batches:
        filename = "{}.tcl".format(batch.batch_id)
        writer.writerow((batch.region_id, batch.batch_id, batch.stage, len(batch.operations), "batches/{}".format(filename)))
        lines = [
            "# Generated Local Mesh Optimizer batch; topology logic remains in local_mesh_optimizer.tcl.",
            "set ::LocalMeshOptimizer::generatedBatchId {}".format(_tcl_quoted(batch.batch_id)),
            "set ::LocalMeshOptimizer::generatedBatchOperations [list \\",
        ]
        for operation in batch.operations:
            lines.append("    {} {}".format(_legacy_tcl_dict(operation), "\\"))
        lines.extend(("]", ""))
        atomic_write_text(batch_dir / filename, "\n".join(lines))
    atomic_write_text(task_dir / "batch_tasks.txt", rows.getvalue())
    atomic_write_json(task_dir / "operations.json", [operation.to_dict() for operation in operations])
    atomic_write_json(task_dir / "batches.json", [batch.to_dict() for batch in batches])
    atomic_write_json(task_dir / "conflicts.json", list(conflicts))
