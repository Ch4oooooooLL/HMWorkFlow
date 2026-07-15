"""Pure-data dependent-node duplicate detection."""
from __future__ import annotations


def build_index(existing):
    return {tuple(sorted(row["dependent_node_ids"])): row["element_id"] for row in existing}


def annotate(candidate, index):
    existing = index.get(tuple(sorted(candidate["wall_node_ids"])))
    candidate["existing_rbe2_id"] = existing
    candidate["recommended_action"] = "SKIP_EXISTING" if existing is not None else "CREATE"
    return candidate
