#!/usr/bin/env python3
"""Repeatable offline planning benchmark (does not fabricate HM timings)."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

PYTHON_DIR = Path(__file__).resolve().parents[1] / "python"
sys.path.insert(0, str(PYTHON_DIR))

from adjacency import ShellElement
from batch_planner import plan_batches, prevalidate_operation
from mesh_state import MeshState
from operation_model import adapt_existing_actions, deduplicate_operations
from quality_simulator import optimize_operation_candidate


def benchmark(element_count: int, batch_size: int) -> dict:
    elements = {}
    coordinates = {}
    actions = []
    for index in range(element_count):
        base = index * 4 + 1
        offset = float(index * 3)
        nodes = (base, base + 1, base + 2, base + 3)
        coordinates.update(
            {
                nodes[0]: (offset, 0.0, 0.0), nodes[1]: (offset + 1.0, 0.0, 0.0),
                nodes[2]: (offset + 1.0, 1.0, 0.0), nodes[3]: (offset, 1.0, 0.0),
            }
        )
        element_id = index + 1
        elements[element_id] = ShellElement(element_id, 1, nodes)
        actions.append(
            {
                "region_id": "Region_0001",
                "action_id": "A_{:06d}".format(index + 1),
                "action_type": "split_quad", "element_id": element_id,
                "edge_index": 0, "node_a": 0, "node_b": 0,
                "reference_a": 0, "reference_b": 0, "target_distance": 0.0,
                "split_method": 2, "reason": "synthetic_failed_quad",
            }
        )
    started = time.perf_counter()
    state = MeshState(coordinates, elements)
    state_seconds = time.perf_counter() - started
    started = time.perf_counter()
    operations = adapt_existing_actions(actions, state)
    operations, dedupe = deduplicate_operations(operations)
    adaptation_seconds = time.perf_counter() - started
    started = time.perf_counter()
    for operation in operations:
        valid, reason, _detail = optimize_operation_candidate(
            operation, state, {"maximum_aspect_ratio": 10.0}
        )
        if valid:
            valid, reason = prevalidate_operation(operation, state)
        operation.validation = {"valid": valid, "reason": reason}
        if not valid:
            operation.status = "validation_failed"
    quality_simulation_seconds = time.perf_counter() - started
    started = time.perf_counter()
    batches, conflicts = plan_batches(operations, batch_size)
    batch_seconds = time.perf_counter() - started
    # Split operations sharing method 2 are issued once per generated batch.
    # This is a command-count projection from the executor structure, not a
    # fabricated wall-clock HyperMesh measurement.
    projected_batch_split_calls = len(batches)
    return {
        "synthetic_elements": element_count,
        "batch_size": batch_size,
        "timings_seconds": {
            "mesh_state_build": state_seconds,
            "operation_adaptation": adaptation_seconds,
            "quality_presimulation": quality_simulation_seconds,
            "conflict_batching": batch_seconds,
            "total_python_batch_planning": state_seconds + adaptation_seconds + quality_simulation_seconds + batch_seconds,
        },
        "counts": {
            "legacy_split_hm_command_calls": element_count,
            "projected_batch_split_hm_command_calls": projected_batch_split_calls,
            "generated_batches": len(batches),
            "deduplicated_operations": len(dedupe),
            "conflict_edges": len(conflicts),
        },
        "notes": [
            "The mesh contains disjoint operations assigned to one synthetic region to isolate batch packing overhead.",
            "No HyperMesh wall time is measured by this offline benchmark.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elements", type=int, default=5000)
    parser.add_argument("--batch-size", type=int, default=200)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    result = benchmark(arguments.elements, arguments.batch_size)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if arguments.output:
        arguments.output.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
