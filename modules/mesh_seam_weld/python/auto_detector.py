"""Automatic shell seam candidate detection and engineering classification."""
from __future__ import annotations

import sys
from pathlib import Path

COMMON_DIR = Path(__file__).resolve().parents[2] / "hybrid_core" / "python"
if str(COMMON_DIR) not in sys.path: sys.path.insert(0, str(COMMON_DIR))
from shell_weld_detection import analyze_component_pair, build_component_topology, find_candidate_component_pairs  # noqa: E402

try:
    from .duplicate_detector import classify_duplicate
    from .joint_classifier import classify, promote_list_types
    from .shell_topology import model_records
except ImportError:
    from duplicate_detector import classify_duplicate
    from joint_classifier import classify, promote_list_types
    from shell_topology import model_records


def detect_candidates(model, settings, existing_seams=None):
    components, elements = model_records(model); topologies = build_component_topology(components, model.nodes, elements)
    candidates = []
    for first_id, second_id in find_candidate_component_pairs(topologies, float(settings["search_distance"])):
        first, second = topologies[first_id], topologies[second_id]
        pair_id = "P{:06d}_{:06d}".format(first_id, second_id)
        regions = analyze_component_pair(first, second, model.nodes, settings)
        for region in regions:
            source = topologies[region["source_component_id"]]; target = topologies[region["target_component_id"]]
            region["branched"] = any(path["branched"] for path in __import__("shell_weld_detection").connected_edge_paths(source.free_edges, model.nodes) if set(region["source_node_ids"]) & set(path["node_ids"]))
            joint_type, confidence, reasons, warnings = classify(region, model, target, settings, target.free_edges)
            row = {"candidate_id": "", "pair_id": pair_id, "joint_type": joint_type, "source_component_id": source.component_id, "target_component_id": target.component_id, "source_node_ids": region["source_node_ids"], "source_edge_pairs": region["source_edge_pairs"], "source_element_ids": region["source_element_ids"], "target_hint_node_ids": region["target_near_node_ids"], "target_hint_element_ids": region["target_near_element_ids"], "length": region["region_length"], "confidence": confidence, "distance": {"minimum": region["minimum_distance"], "average": region["average_distance"], "maximum": region["maximum_distance"]}, "reasons": reasons, "warnings": warnings, "center": region["region_center"]}
            row["duplicate_status"] = classify_duplicate(row, existing_seams or [], model.nodes, float(settings.get("existing_weld_search_distance", 4.0)))
            if row["duplicate_status"] != "NEW": row["joint_type"] = "REVIEW"; row["warnings"].append(row["duplicate_status"])
            candidates.append(row)
    candidates.sort(key=lambda row: (row["pair_id"], tuple(round(value, 9) for value in row["center"]), -row["length"], min(row["source_node_ids"])))
    for index, row in enumerate(candidates, 1): row["candidate_id"] = "W{:06d}".format(index)
    return promote_list_types(candidates)
