"""Stable automatic shell-seam creation-plan records."""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Dict, List


@dataclass
class CreationPlan:
    candidate_id: str
    realization_mode: str
    move_nodes: List[Dict] = field(default_factory=list)
    delete_element_ids: List[int] = field(default_factory=list)
    new_nodes: List[Dict] = field(default_factory=list)
    replacement_elements: List[Dict] = field(default_factory=list)
    weld_elements: List[Dict] = field(default_factory=list)
    output_component_name: str = ""
    property_id: int = 0
    status: str = "MANUAL_REVIEW"
    warnings: List[str] = field(default_factory=list)
    read_nodes: List[int] = field(default_factory=list)
    write_nodes: List[int] = field(default_factory=list)
    read_elements: List[int] = field(default_factory=list)
    delete_elements: List[int] = field(default_factory=list)
    original_connectivity: Dict[str, List[int]] = field(default_factory=dict)
    max_new_failed_elements: int = 0
    batch_id: str = ""

    def to_dict(self):
        row = asdict(self); row["mode"] = row["realization_mode"]
        return row


def conflict(first, second):
    return bool(set(first.write_nodes) & (set(second.read_nodes) | set(second.write_nodes)) or set(first.delete_elements) & (set(second.read_elements) | set(second.delete_elements)))


def execution_batches(plans, batch_size=25):
    batches = []
    for plan in sorted(plans, key=lambda row: row.candidate_id):
        placed = False
        for batch in batches:
            if len(batch) < batch_size and not any(conflict(plan, other) for other in batch): batch.append(plan); placed = True; break
        if not placed: batches.append([plan])
    return batches
