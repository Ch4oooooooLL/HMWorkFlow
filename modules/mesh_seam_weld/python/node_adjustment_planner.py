"""Quality-guarded target-path node adjustment with bounded backoff."""
from __future__ import annotations

import math

try:
    from .element_projection import project_point_to_element
    from .quality_guard import element_metrics
except ImportError:
    from element_projection import project_point_to_element
    from quality_guard import element_metrics


def _distance(first, second):
    return math.sqrt(sum((first[index]-second[index])**2 for index in range(3)))


def _area_vector(points):
    vector = [0.0, 0.0, 0.0]
    for index, point in enumerate(points):
        following = points[(index+1) % len(points)]
        vector[0] += (point[1]-following[1])*(point[2]+following[2])
        vector[1] += (point[2]-following[2])*(point[0]+following[0])
        vector[2] += (point[0]-following[0])*(point[1]+following[1])
    return tuple(vector)


def _parameters(points):
    lengths = [_distance(points[index], points[index+1]) for index in range(len(points)-1)]
    total = sum(lengths)
    if total <= 1.0e-12: raise ValueError("cannot parameterize a zero-length path")
    result, accumulated = [0.0], 0.0
    for length in lengths: accumulated += length; result.append(accumulated/total)
    return result


def _sample(points, parameters, value):
    if value <= 0.0: return points[0]
    if value >= 1.0: return points[-1]
    for index in range(len(parameters)-1):
        if parameters[index] <= value <= parameters[index+1]:
            span = parameters[index+1]-parameters[index]
            ratio = 0.0 if span <= 1.0e-12 else (value-parameters[index])/span
            return tuple(points[index][axis]+ratio*(points[index+1][axis]-points[index][axis]) for axis in range(3))
    return points[-1]


def projected_source_path(source_node_ids, target_path_node_ids, target_element_ids, model):
    elements = [model.elements[element_id] for element_id in target_element_ids if element_id in model.elements]
    if not elements: raise ValueError("target projection has no shell elements")
    projected = []
    for node_id in source_node_ids:
        choices = []
        for element in elements:
            try: result = project_point_to_element(model.nodes[node_id], element.node_ids, model.nodes)
            except ValueError: continue
            choices.append((result["distance"], element.element_id, result["point"]))
        if not choices: raise ValueError("source point cannot be projected to target shell")
        projected.append(min(choices, key=lambda row: (row[0], row[1]))[2])
    projected_parameters = _parameters(projected)
    target_points = [model.nodes[node_id] for node_id in target_path_node_ids]
    target_parameters = _parameters(target_points)
    return [_sample(projected, projected_parameters, value) for value in target_parameters]


def affected_element_ids(path_node_ids, model):
    selected = set(path_node_ids)
    return sorted(element.element_id for element in model.elements.values() if selected.intersection(element.node_ids))


def protected_target_nodes(path_node_ids, model, explicit=(), feature_angle_degrees=45.0):
    protected = set(int(value) for value in explicit)
    ownership = {}
    for element in model.elements.values():
        for node_id in element.node_ids: ownership.setdefault(node_id, set()).add(element.component_id)
    protected.update(node_id for node_id in path_node_ids if len(ownership.get(node_id, ())) > 1)
    cosine_limit = math.cos(math.radians(float(feature_angle_degrees)))
    for node_id in path_node_ids:
        normals=[]
        for element in model.elements.values():
            if node_id not in element.node_ids: continue
            points=[model.nodes[value] for value in element.node_ids]
            vector=_area_vector(points); length=math.sqrt(sum(value*value for value in vector))
            if length > 1.0e-12: normals.append(tuple(value/length for value in vector))
        if any(abs(sum(first[axis]*second[axis] for axis in range(3))) < cosine_limit for index,first in enumerate(normals) for second in normals[index+1:]): protected.add(node_id)
    return protected


def movement_quality(model, targets, affected_ids, max_aspect_ratio=20.0):
    moved_nodes = dict(model.nodes); moved_nodes.update(targets)
    failures = []
    for element_id in affected_ids:
        element = model.elements[element_id]
        original_points = [model.nodes[node_id] for node_id in element.node_ids]
        moved_points = [moved_nodes[node_id] for node_id in element.node_ids]
        original_vector, moved_vector = _area_vector(original_points), _area_vector(moved_points)
        original_norm = math.sqrt(sum(value*value for value in original_vector)); moved_norm = math.sqrt(sum(value*value for value in moved_vector))
        metrics = element_metrics(element.node_ids, moved_nodes)
        if original_norm <= 1.0e-12 or moved_norm <= max(1.0e-12, original_norm*1.0e-6): failures.append((element_id,"collapsed area")); continue
        if sum(original_vector[index]*moved_vector[index] for index in range(3)) <= 0.0: failures.append((element_id,"normal flip")); continue
        if not metrics["valid"]: failures.append((element_id,"invalid shell")); continue
        original_metrics = element_metrics(element.node_ids, model.nodes)
        if metrics["aspect_ratio"] > max_aspect_ratio and metrics["aspect_ratio"] > original_metrics["aspect_ratio"]+1.0e-9: failures.append((element_id,"new aspect failure"))
    return failures


def plan_adjustments(path_node_ids, desired_points, nodes, local_edge_length, settings, protected_node_ids=(), model=None):
    if not settings.get("allow_target_node_move", False): return None
    protected = set(protected_node_ids); maximum = float(settings.get("max_node_move",2.0)); ratio = float(settings.get("max_node_move_ratio",0.25))
    limit = min(maximum, ratio*local_edge_length)
    origins = {node_id:nodes[node_id] for node_id in path_node_ids}
    full = {node_id:tuple(target) for node_id,target in zip(path_node_ids,desired_points)}
    if any(node_id in protected and _distance(origins[node_id],full[node_id]) > 1.0e-12 for node_id in path_node_ids): return None
    if any(_distance(origins[node_id],full[node_id]) > limit for node_id in path_node_ids): return None
    affected = affected_element_ids(path_node_ids,model) if model is not None else []
    for scale in (1.0,0.75,0.5,0.25):
        targets = {node_id:tuple(origins[node_id][axis]+scale*(full[node_id][axis]-origins[node_id][axis]) for axis in range(3)) for node_id in path_node_ids}
        if model is not None and movement_quality(model,targets,affected,float(settings.get("max_adjusted_aspect_ratio",20.0))): continue
        result=[]
        for node_id in path_node_ids:
            move=_distance(origins[node_id],targets[node_id])
            if move > 1.0e-12: result.append({"node_id":node_id,"from":list(origins[node_id]),"to":list(targets[node_id]),"distance":move,"backoff_scale":scale})
        return {"moves":result,"scale":scale,"affected_element_ids":affected,"coordinates":targets}
    return None
