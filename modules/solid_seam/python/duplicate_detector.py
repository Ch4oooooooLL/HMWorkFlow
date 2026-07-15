"""Detect overlaps against existing connectors and the current batch."""
from __future__ import annotations


def node_overlap(a, b):
    sa, sb = set(a), set(b)
    return len(sa & sb) / float(max(1, min(len(sa), len(sb))))


def classify(candidate, existing, prior):
    pair = {candidate["source_solid"]["component_id"], candidate["target_component"]["component_id"]}
    for connector in existing:
        if set(connector.get("linked_component_ids", [])) == pair:
            overlap = node_overlap(candidate["node_ids"], connector.get("location_node_ids", []))
            if overlap >= 0.8:
                return "CONFIRMED"
            if overlap >= 0.25:
                return "POSSIBLE"
    for other in prior:
        other_pair = {other["source_solid"]["component_id"], other["target_component"]["component_id"]}
        if other_pair == pair and node_overlap(candidate["node_ids"], other["node_ids"]) >= 0.8:
            return "CONFIRMED"
    return "NONE"
