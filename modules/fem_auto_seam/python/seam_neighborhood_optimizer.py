"""Criteria/param-driven local smoothing for the standalone FEM seam tool.

The optimizer is intentionally topology preserving.  It never changes the seam
interface, free boundaries, feature edges, or nodes shared with elements outside
the requested neighborhood.  Python proposes and evaluates every move; a later
HyperMesh integration stage remains the final native quality authority.
"""
from __future__ import annotations

import math
import re
import sys
from collections import defaultdict, deque
from pathlib import Path

MODULES_DIR = Path(__file__).resolve().parents[2]
OPTIMIZER_PYTHON = MODULES_DIR / "local_mesh_optimizer" / "python"
if str(OPTIMIZER_PYTHON) not in sys.path:
    sys.path.insert(0, str(OPTIMIZER_PYTHON))

from criteria_parser import parse_criteria_metadata as parse_criteria_file_metadata  # noqa: E402


DEFAULT_QUALITY_LIMITS = {
    "minimum_length": 3.0,
    "maximum_length": 9.0,
    "maximum_aspect_ratio": 5.0,
    "maximum_warpage": 20.0,
    "maximum_angle_quad": 150.0,
    "minimum_angle_quad": 30.0,
    "maximum_angle_tria": 130.0,
    "minimum_angle_tria": 20.0,
    "maximum_skew": 60.0,
    "minimum_jacobian": 0.5,
}
DEFAULT_PARAM_VALUES = {
    "element_size": "auto",
    "feature_angle": 30.0,
    "smooth_elems_target": 0.2,
    "move_nodes_across_feature_edges": 0,
    "move_nodes_across_free_edges": 0,
}


def parse_criteria_metadata(path=None):
    if path is None or not str(path).strip():
        return {
            "path": "",
            "size_bytes": 0,
            "preview": [],
            "quality_limits": dict(DEFAULT_QUALITY_LIMITS),
            "authority": "FEM Automatic Seam built-in defaults",
        }
    return parse_criteria_file_metadata(Path(path))


def parse_param_metadata(path=None):
    """Parse scalar HM2019 BatchMesher parameters used by local smoothing."""
    if path is None or not str(path).strip():
        return {
            "path": "",
            "size_bytes": 0,
            "values": dict(DEFAULT_PARAM_VALUES),
            "preview": [],
            "authority": "FEM Automatic Seam built-in defaults",
        }
    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError(str(path))
    if path.stat().st_size <= 0:
        raise ValueError("Param file is empty")
    values = {}
    preview = []
    scalar = re.compile(r"^\s*([A-Za-z][A-Za-z0-9_]*)\s*(?:\(\s*)?([^\s)#]+)(?:\s*\))?")
    with path.open("r", encoding="utf-8-sig", errors="replace") as stream:
        for raw in stream:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            preview.append(line[:300])
            match = scalar.match(line)
            if match is None:
                continue
            key, text = match.group(1).lower(), match.group(2)
            if text.lower() == "auto":
                values[key] = "auto"
                continue
            try:
                value = float(text)
            except ValueError:
                continue
            values[key] = int(value) if value.is_integer() else value
    return {
        "path": str(path.resolve()),
        "size_bytes": path.stat().st_size,
        "values": values,
        "preview": preview[:20],
        "authority": "HyperMesh",
    }


def _sub(first, second):
    return tuple(first[index] - second[index] for index in range(3))


def _add(first, second):
    return tuple(first[index] + second[index] for index in range(3))


def _scale(value, factor):
    return tuple(component * factor for component in value)


def _dot(first, second):
    return sum(first[index] * second[index] for index in range(3))


def _cross(first, second):
    return (
        first[1] * second[2] - first[2] * second[1],
        first[2] * second[0] - first[0] * second[2],
        first[0] * second[1] - first[1] * second[0],
    )


def _norm(value):
    return math.sqrt(_dot(value, value))


def _unit(value):
    length = _norm(value)
    return (0.0, 0.0, 0.0) if length <= 1.0e-15 else _scale(value, 1.0 / length)


def _angle(first, center, second):
    left, right = _sub(first, center), _sub(second, center)
    denominator = _norm(left) * _norm(right)
    if denominator <= 1.0e-15:
        return 0.0
    cosine = max(-1.0, min(1.0, _dot(left, right) / denominator))
    return math.degrees(math.acos(cosine))


def _element_metrics(element, nodes):
    points = [nodes[node_id] for node_id in element.node_ids]
    count = len(points)
    lengths = [_norm(_sub(points[(index + 1) % count], points[index])) for index in range(count)]
    angles = [_angle(points[index - 1], points[index], points[(index + 1) % count]) for index in range(count)]
    first_cross = _cross(_sub(points[1], points[0]), _sub(points[2], points[0]))
    area = 0.5 * _norm(first_cross)
    warpage = 0.0
    if count == 4:
        second_cross = _cross(_sub(points[2], points[0]), _sub(points[3], points[0]))
        area += 0.5 * _norm(second_cross)
        if _norm(first_cross) > 1.0e-15 and _norm(second_cross) > 1.0e-15:
            cosine = max(-1.0, min(1.0, _dot(first_cross, second_cross) / (_norm(first_cross) * _norm(second_cross))))
            warpage = math.degrees(math.acos(cosine))
    ideal = 60.0 if count == 3 else 90.0
    jacobian = 0.0
    if max(lengths, default=0.0) > 1.0e-15:
        jacobian = min(1.0, 2.0 * area / max(sum(value * value for value in lengths), 1.0e-15))
        jacobian *= 2.0 if count == 4 else math.sqrt(3.0)
        jacobian = min(1.0, jacobian)
    return {
        "area": area,
        "minimum_length": min(lengths),
        "maximum_length": max(lengths),
        "maximum_aspect_ratio": max(lengths) / max(min(lengths), 1.0e-15),
        "minimum_angle": min(angles),
        "maximum_angle": max(angles),
        "maximum_skew": max(abs(value - ideal) for value in angles),
        "maximum_warpage": warpage,
        "minimum_jacobian": jacobian,
        "node_count": count,
    }


def _penalties(metrics, limits):
    result = []
    minimums = {
        "minimum_length": metrics["minimum_length"],
        "minimum_jacobian": metrics["minimum_jacobian"],
        "minimum_angle_quad" if metrics["node_count"] == 4 else "minimum_angle_tria": metrics["minimum_angle"],
    }
    maximums = {
        "maximum_length": metrics["maximum_length"],
        "maximum_aspect_ratio": metrics["maximum_aspect_ratio"],
        "maximum_warpage": metrics["maximum_warpage"],
        "maximum_skew": metrics["maximum_skew"],
        "maximum_angle_quad" if metrics["node_count"] == 4 else "maximum_angle_tria": metrics["maximum_angle"],
    }
    for name, value in minimums.items():
        if name in limits and value < float(limits[name]):
            result.append((name, (float(limits[name]) - value) / max(abs(float(limits[name])), 1.0e-12)))
    for name, value in maximums.items():
        if name in limits and value > float(limits[name]):
            result.append((name, (value - float(limits[name])) / max(abs(float(limits[name])), 1.0e-12)))
    if metrics["area"] <= 1.0e-12:
        result.append(("area", 1.0e6))
    return result


def _quality_summary(model, element_ids, limits):
    failed = []
    total_penalty = 0.0
    worst_penalty = 0.0
    objective = 0.0
    for element_id in sorted(set(element_ids)):
        element = model.elements.get(element_id)
        if element is None:
            continue
        metrics = _element_metrics(element, model.nodes)
        penalties = _penalties(metrics, limits)
        penalty = sum(value for _, value in penalties)
        total_penalty += penalty
        worst_penalty = max(worst_penalty, penalty)
        objective += penalty + 0.01 * max(0.0, metrics["maximum_aspect_ratio"] - 1.0) + metrics["maximum_skew"] / 18000.0
        if penalties:
            failed.append({
                "element_id": element_id,
                "criteria": [name for name, _ in penalties],
                "penalty": round(penalty, 9),
            })
    return {
        "checked_element_count": len(set(element_ids)),
        "failed_element_count": len(failed),
        "total_penalty": round(total_penalty, 9),
        "worst_penalty": round(worst_penalty, 9),
        "objective": round(objective, 9),
        "failed_elements": failed,
    }


def _topology(model):
    node_elements = defaultdict(set)
    edge_elements = defaultdict(list)
    node_neighbors = defaultdict(set)
    for element_id, element in model.elements.items():
        node_ids = list(element.node_ids)
        for node_id in node_ids:
            node_elements[node_id].add(element_id)
        for index, first in enumerate(node_ids):
            second = node_ids[(index + 1) % len(node_ids)]
            edge = tuple(sorted((first, second)))
            edge_elements[edge].append(element_id)
            node_neighbors[first].add(second)
            node_neighbors[second].add(first)
    element_neighbors = defaultdict(set)
    for owners in edge_elements.values():
        for first in owners:
            element_neighbors[first].update(second for second in owners if second != first)
    return node_elements, edge_elements, node_neighbors, element_neighbors


def _element_normal(element, nodes):
    points = [nodes[node_id] for node_id in element.node_ids[:3]]
    return _unit(_cross(_sub(points[1], points[0]), _sub(points[2], points[0])))


def _feature_nodes(model, edge_elements, angle_limit):
    protected = set()
    for edge, owners in edge_elements.items():
        if len(owners) == 1:
            protected.update(edge)
        elif len(owners) == 2:
            first = _element_normal(model.elements[owners[0]], model.nodes)
            second = _element_normal(model.elements[owners[1]], model.nodes)
            cosine = max(-1.0, min(1.0, _dot(first, second)))
            if math.degrees(math.acos(cosine)) >= angle_limit:
                protected.update(edge)
    return protected


def _expand_elements(seed, neighbors, layers):
    selected = set(seed)
    frontier = deque((element_id, 0) for element_id in seed)
    while frontier:
        element_id, depth = frontier.popleft()
        if depth >= layers:
            continue
        for neighbor in neighbors.get(element_id, ()):
            if neighbor not in selected:
                selected.add(neighbor)
                frontier.append((neighbor, depth + 1))
    return selected


def optimize_seam_neighborhood(model, realization_reports, criteria_path, param_path, layers=2, iterations=4, settings=None):
    """Move safe interior nodes only when local criteria quality improves."""
    settings = dict(settings or {})
    criteria = parse_criteria_metadata(criteria_path)
    param = parse_param_metadata(param_path)
    limits = dict(criteria.get("quality_limits", {}))
    values = param.get("values", {})
    layers = max(0, int(layers))
    iterations = max(0, int(iterations))
    node_elements, edge_elements, node_neighbors, element_neighbors = _topology(model)
    seam_components = {int(row["seam_component_id"]) for row in realization_reports if row.get("status") == "CREATED"}
    seam_elements = {element_id for element_id, element in model.elements.items() if element.component_id in seam_components}
    seam_nodes = {node_id for element_id in seam_elements for node_id in model.elements[element_id].node_ids}
    seed = set()
    for row in realization_reports:
        if row.get("status") != "CREATED":
            continue
        seed.update(int(value) for value in row.get("created_source_elements", []))
        seed.update(int(value) for value in row.get("created_mother_elements", []))
    seed.intersection_update(model.elements)
    neighborhood = _expand_elements(seed, element_neighbors, layers).difference(seam_elements)
    feature_angle = float(values.get("feature_angle", 30.0))
    protected = _feature_nodes(model, edge_elements, feature_angle).union(seam_nodes)
    for node_id, attached in node_elements.items():
        if attached.intersection(neighborhood) and not attached.issubset(neighborhood.union(seam_elements)):
            protected.add(node_id)
    candidate_nodes = sorted({node_id for element_id in neighborhood for node_id in model.elements[element_id].node_ids}.difference(protected))
    element_size = values.get("element_size", settings.get("element_size", 0.0))
    if not isinstance(element_size, (int, float)) or float(element_size) <= 0.0:
        lengths = []
        for edge in edge_elements:
            if node_elements[edge[0]].intersection(neighborhood):
                lengths.append(_norm(_sub(model.nodes[edge[0]], model.nodes[edge[1]])))
        element_size = sum(lengths) / len(lengths) if lengths else 1.0
    smoothing_target = values.get("smooth_elems_target", 0.2)
    if not isinstance(smoothing_target, (int, float)):
        smoothing_target = 0.2
    max_move = float(settings.get("maximum_node_move", float(element_size) * max(0.02, min(0.25, float(smoothing_target)))))
    before = _quality_summary(model, neighborhood, limits)
    original_coordinates = dict(model.nodes)
    moves = {}
    accepted_attempts = 0
    for _iteration in range(iterations):
        changed = False
        for node_id in candidate_nodes:
            neighbors = sorted(node_neighbors.get(node_id, ()))
            if len(neighbors) < 3:
                continue
            current = model.nodes[node_id]
            centroid = tuple(sum(model.nodes[other][axis] for other in neighbors) / len(neighbors) for axis in range(3))
            attached = node_elements[node_id].intersection(neighborhood)
            normal_sum = (0.0, 0.0, 0.0)
            for element_id in attached:
                normal_sum = _add(normal_sum, _element_normal(model.elements[element_id], model.nodes))
            normal = _unit(normal_sum)
            delta = _sub(centroid, current)
            delta = _sub(delta, _scale(normal, _dot(delta, normal)))
            if _norm(delta) <= 1.0e-10:
                continue
            origin = original_coordinates[node_id]
            remaining = max_move - _norm(_sub(current, origin))
            if remaining <= 1.0e-10:
                continue
            if _norm(delta) > remaining:
                delta = _scale(delta, remaining / _norm(delta))
            affected = set(attached)
            local_before = _quality_summary(model, affected, limits)
            accepted = None
            for factor in (1.0, 0.5, 0.25, 0.125):
                trial = _add(current, _scale(delta, factor))
                model.nodes[node_id] = trial
                local_after = _quality_summary(model, affected, limits)
                safe = (
                    local_after["failed_element_count"] <= local_before["failed_element_count"]
                    and local_after["worst_penalty"] <= local_before["worst_penalty"] + 1.0e-10
                    and local_after["objective"] < local_before["objective"] - 1.0e-10
                )
                if safe:
                    accepted = trial
                    accepted_attempts += 1
                    break
            if accepted is None:
                model.nodes[node_id] = current
            else:
                moves[node_id] = accepted
                changed = True
        if not changed:
            break
    after = _quality_summary(model, neighborhood, limits)
    move_rows = [
        {
            "node_id": node_id,
            "from": list(original_coordinates[node_id]),
            "to": list(model.nodes[node_id]),
            "distance": round(_norm(_sub(model.nodes[node_id], original_coordinates[node_id])), 9),
        }
        for node_id in sorted(moves)
        if _norm(_sub(model.nodes[node_id], original_coordinates[node_id])) > 1.0e-10
    ]
    return {
        "schema_version": "1.0",
        "status": "OPTIMIZED" if move_rows else "NO_SAFE_MOVE",
        "criteria": criteria,
        "param": param,
        "settings": {"layers": layers, "iterations": iterations, "maximum_node_move": max_move},
        "seed_element_ids": sorted(seed),
        "neighborhood_element_ids": sorted(neighborhood),
        "protected_node_ids": sorted(protected),
        "candidate_node_ids": candidate_nodes,
        "moves": move_rows,
        "accepted_attempt_count": accepted_attempts,
        "quality_before": before,
        "quality_after": after,
    }
