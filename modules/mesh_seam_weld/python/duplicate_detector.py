"""Conservative existing-weld and candidate overlap checks."""
from __future__ import annotations

import math


def _distance(a, b): return math.sqrt(sum((a[i]-b[i])**2 for i in range(3)))


def classify_duplicate(candidate, existing_seams, nodes, maximum):
    if not existing_seams: return "NEW"
    source = [nodes[node_id] for node_id in candidate["source_node_ids"]]
    center = tuple(sum(point[axis] for point in source)/len(source) for axis in range(3))
    pair = {candidate["source_component_id"], candidate["target_component_id"]}
    for seam in existing_seams:
        seam_pair = {int(value) for value in seam.get("mother_component_ids", [])}
        if seam_pair and seam_pair != pair: continue
        seam_center = seam.get("center") or seam.get("centroid")
        if seam_center and _distance(center, tuple(float(value) for value in seam_center)) <= maximum:
            overlap = float(seam.get("overlap_ratio", 1.0))
            return "DUPLICATE" if overlap >= 0.9 else "PARTIAL_OVERLAP"
    return "NEW"
