"""Classify shell seam candidates from local normals and edge context."""
from __future__ import annotations

from collections import Counter

try:
    from .element_projection import angle_degrees, cross, norm, triangle_normal
except ImportError:
    from element_projection import angle_degrees, cross, norm, triangle_normal


def element_normal(element, nodes):
    ids = element.node_ids
    return triangle_normal(nodes[ids[0]], nodes[ids[1]], nodes[ids[2]])


def representative_normal(element_ids, model):
    values = []
    for element_id in element_ids:
        element = model.elements.get(element_id)
        if element and len(element.node_ids) in (3, 4):
            try: values.append(element_normal(element, model.nodes))
            except ValueError: continue
    if not values: return None
    reference = values[0]; aligned = [tuple(-v for v in value) if sum(value[i]*reference[i] for i in range(3)) < 0 else value for value in values]
    average = tuple(sum(value[i] for value in aligned)/len(aligned) for i in range(3))
    return average if norm(average) > 1.0e-12 else None


def classify(region, model, target_topology, settings, target_free_edges):
    source_normal = representative_normal(region["source_element_ids"], model)
    target_normal = representative_normal(region["target_near_element_ids"], model)
    warnings, reasons = [], []
    if source_normal is None or target_normal is None:
        return "REVIEW", 0.0, ["unstable or degenerate local normal"], warnings
    angle = angle_degrees(source_normal, target_normal)
    parallel = float(settings.get("parallel_angle_max", 15.0)); perpendicular = float(settings.get("perpendicular_angle_min", 70.0))
    target_edge_nodes = {node for edge in target_free_edges for node in edge[:2]}
    boundary_hits = sum(node in target_edge_nodes for node in region["target_near_node_ids"])
    near_target_boundary = bool(region["target_near_node_ids"]) and boundary_hits / float(len(region["target_near_node_ids"])) >= 0.8
    distances = (region["minimum_distance"], region["average_distance"], region["maximum_distance"])
    variation = (distances[2]-distances[0])/max(distances[1], 1.0e-9)
    if variation > float(settings.get("max_distance_variation_ratio", 0.35)):
        warnings.append("distance variation exceeds configured ratio")
    if angle <= parallel:
        joint_type = "L_SURF"; reasons.append("local shell normals are parallel")
    elif angle >= perpendicular:
        joint_type = "CONNECT" if near_target_boundary else "T_PATH"
        reasons.append("both paths are free edges" if near_target_boundary else "source free edge projects to target shell interior")
    else:
        return "REVIEW", 0.45, ["normal angle is ambiguous ({:.3f} deg)".format(angle)], warnings
    distance_score = max(0.0, 1.0-region["average_distance"]/max(float(settings.get("search_distance", 12.0)), 1.0e-9))
    confidence = 0.55 + 0.25*distance_score + (0.15 if variation <= float(settings.get("max_distance_variation_ratio", 0.35)) else 0.0)
    if region.get("branched"): warnings.append("source free-edge path branches"); joint_type = "REVIEW"; confidence = min(confidence, 0.4)
    return joint_type, round(min(confidence, 0.99), 6), reasons, warnings


def promote_list_types(candidates):
    counts = Counter((row["pair_id"], row["joint_type"]) for row in candidates if row["joint_type"] in ("T_PATH", "L_SURF"))
    for row in candidates:
        if counts[(row["pair_id"], row["joint_type"])] > 1:
            row["joint_type"] = "T_LIST" if row["joint_type"] == "T_PATH" else "L_LIST"
    return candidates
