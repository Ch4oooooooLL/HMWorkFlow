"""Validate candidate references before writing an operation plan."""
from __future__ import annotations

try:
    from hmworkflow.core.hybrid_schema import SchemaError
except ImportError:  # Standalone HM2019 entry compatibility.
    from hybrid_schema import SchemaError


def validate(candidates, model):
    seen = set()
    known_nodes = set(model.nodes)
    for candidate in candidates:
        candidate_id = candidate["candidate_id"]
        if candidate_id in seen:
            raise SchemaError("duplicate candidate_id {}".format(candidate_id))
        seen.add(candidate_id)
        missing = sorted(set(candidate["wall_node_ids"]) - known_nodes)
        if missing:
            raise SchemaError("candidate {} references missing nodes {}".format(candidate_id, missing))
        if len(candidate["boundary_loops"]) != 2:
            raise SchemaError("candidate {} must have two boundary loops".format(candidate_id))
