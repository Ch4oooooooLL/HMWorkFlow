"""Unified operation model and adapter for existing optimizer actions."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Dict, Iterable, List, Mapping, Set, Tuple

from mesh_state import MeshState, edge_key


@dataclass
class AccessSet:
    read_nodes: Set[int] = field(default_factory=set)
    write_nodes: Set[int] = field(default_factory=set)
    delete_nodes: Set[int] = field(default_factory=set)
    read_elements: Set[int] = field(default_factory=set)
    write_elements: Set[int] = field(default_factory=set)
    delete_elements: Set[int] = field(default_factory=set)

    def to_dict(self) -> Dict[str, List[int]]:
        return {key: sorted(value) for key, value in asdict(self).items()}


@dataclass
class Operation:
    operation_id: str
    operation_type: str
    source_elements: List[int]
    source_nodes: List[int]
    affected_elements: List[int]
    affected_nodes: List[int]
    priority: int
    stage: str
    access: AccessSet
    validation: Dict[str, object] = field(default_factory=dict)
    metadata: Dict[str, object] = field(default_factory=dict)
    status: str = "pending"
    legacy_action: Dict[str, object] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, object]:
        return {
            "operation_id": self.operation_id,
            "operation_type": self.operation_type,
            "source_elements": self.source_elements,
            "source_nodes": self.source_nodes,
            "affected_elements": self.affected_elements,
            "affected_nodes": self.affected_nodes,
            "delete_elements": sorted(self.access.delete_elements),
            "create_elements": [],
            "delete_nodes": sorted(self.access.delete_nodes),
            "keep_nodes": [],
            "replace_nodes": {},
            "priority": self.priority,
            "stage": self.stage,
            "read_set": self.access.to_dict(),
            "validation": self.validation,
            "metadata": self.metadata,
            "status": self.status,
            "legacy_action": self.legacy_action,
        }

    def dedupe_key(self) -> Tuple[object, ...]:
        if self.operation_type in (
            "collapse_short_edge",
            "expand_free_edge",
            "expand_triangle_short_edge",
        ):
            first = int(self.legacy_action.get("node_a", 0))
            second = int(self.legacy_action.get("node_b", 0))
            return (self.operation_type, edge_key(first, second))
        element = self.source_elements[0] if self.source_elements else 0
        return (self.operation_type, element)


PRIORITY = {
    "collapse_short_edge": 0,
    "expand_free_edge": 1,
    "expand_internal_quad": 1,
    "expand_triangle_short_edge": 1,
    "split_quad": 2,
    "manual_review": 3,
}


def adapt_existing_actions(actions: Iterable[Mapping[str, object]], state: MeshState) -> List[Operation]:
    """Add batching metadata without changing the legacy planner decision."""
    operations: List[Operation] = []
    for index, source in enumerate(actions, 1):
        action = dict(source)
        action_type = str(action["action_type"])
        element_id = int(action["element_id"])
        element = state.elements.get(element_id)
        source_nodes = list(element.nodes) if element is not None else []
        affected = state.affected_elements(source_nodes, [element_id], rings=1)
        affected_nodes: Set[int] = set(source_nodes)
        for affected_id in affected:
            affected_element = state.elements.get(affected_id)
            if affected_element is not None:
                affected_nodes.update(affected_element.nodes)
        access = AccessSet(read_nodes=set(affected_nodes), read_elements=set(affected))
        if action_type == "split_quad":
            access.write_elements.update(affected)
            access.delete_elements.add(element_id)
        elif action_type == "collapse_short_edge":
            endpoints = {int(action["node_a"]), int(action["node_b"])}
            access.write_nodes.update(endpoints)
            access.write_elements.update(affected)
            # HyperMesh chooses the survivor/degenerated entities. Record this
            # uncertainty instead of inventing a keep/delete direction.
        elif action_type == "expand_free_edge":
            moving = {int(action["node_a"]), int(action["node_b"])}
            access.write_nodes.update(moving)
            access.write_elements.update(state.affected_elements(moving, rings=0))
            affected_nodes.update(
                {int(action.get("reference_a", 0)), int(action.get("reference_b", 0))}
            )
        elif action_type == "expand_triangle_short_edge":
            moving = {int(action["node_a"]), int(action["node_b"])}
            access.write_nodes.update(moving)
            access.write_elements.update(state.affected_elements(moving, rings=0))
        elif action_type == "expand_internal_quad":
            move_mode = int(action.get("move_mode", 0))
            moving = set()
            if move_mode in (0, 1):
                moving.update((int(action["node_a"]), int(action["node_b"])))
            if move_mode in (0, 2):
                moving.update((int(action["reference_a"]), int(action["reference_b"])))
            access.write_nodes.update(moving)
            access.write_elements.update(state.affected_elements(moving, rings=0))
        operation_id = "OP_{:06d}".format(index)
        operations.append(
            Operation(
                operation_id=operation_id,
                operation_type=action_type,
                source_elements=[element_id],
                source_nodes=sorted(set(source_nodes)),
                affected_elements=sorted(affected),
                affected_nodes=sorted(node for node in affected_nodes if node),
                priority=PRIORITY[action_type],
                stage="topology_repair",
                access=access,
                metadata={
                    "region_id": str(action["region_id"]),
                    "reason": str(action.get("reason", "")),
                    "chain_id": int(action.get("split_method", 0)),
                    "hm_managed_entity_ids": action_type in ("split_quad", "collapse_short_edge"),
                },
                legacy_action=action,
            )
        )
    return operations


def deduplicate_operations(operations: Iterable[Operation]) -> Tuple[List[Operation], List[Dict[str, str]]]:
    """Stable first-wins deduplication matching the legacy sorted order."""
    unique: List[Operation] = []
    seen: Dict[Tuple[object, ...], Operation] = {}
    events: List[Dict[str, str]] = []
    for operation in operations:
        key = operation.dedupe_key()
        previous = seen.get(key)
        if previous is None:
            seen[key] = operation
            unique.append(operation)
            continue
        operation.status = "conflict_detected"
        operation.validation = {
            "valid": False,
            "reason": "duplicate_of:{}".format(previous.operation_id),
        }
        events.append(
            {
                "operation_id": operation.operation_id,
                "kept_operation_id": previous.operation_id,
                "reason": "duplicate_operation",
            }
        )
    return unique, events
