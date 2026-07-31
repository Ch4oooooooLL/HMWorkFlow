"""Conservative V3 split of one planar first-order shell by one open chord."""
from __future__ import annotations

import math

try:
    from .element_projection import cross, dot, norm, unit
    from .quality_guard import element_metrics
except ImportError:
    from element_projection import cross, dot, norm, unit
    from quality_guard import element_metrics


def _sub(a, b): return tuple(a[index]-b[index] for index in range(3))
def _add(a, b): return tuple(a[index]+b[index] for index in range(3))
def _scale(a, value): return tuple(a[index]*value for index in range(3))


def _plane(nodes, coordinates):
    origin = coordinates[nodes[0]]
    axis_x = unit(_sub(coordinates[nodes[1]], origin))
    normal = unit(cross(axis_x, _sub(coordinates[nodes[2]], origin)))
    axis_y = cross(normal, axis_x)
    return origin, axis_x, axis_y, normal


def _project(point, plane):
    origin, axis_x, axis_y, normal = plane
    delta = _sub(point, origin)
    projected = _sub(point, _scale(normal, dot(delta, normal)))
    local = _sub(projected, origin)
    return projected, (dot(local, axis_x), dot(local, axis_y)), abs(dot(delta, normal))


def _orient(a, b, c): return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])


def _point_in_convex(point, polygon, tolerance):
    values = [_orient(polygon[index], polygon[(index+1) % len(polygon)], point) for index in range(len(polygon))]
    return min(values) >= -tolerance or max(values) <= tolerance


def _edge_parameter(point, first, second):
    direction = (second[0]-first[0], second[1]-first[1])
    denominator = direction[0]*direction[0]+direction[1]*direction[1]
    if denominator <= 1.0e-24: return 0.0, float("inf")
    value = ((point[0]-first[0])*direction[0]+(point[1]-first[1])*direction[1])/denominator
    nearest = (first[0]+value*direction[0], first[1]+value*direction[1])
    return value, math.hypot(point[0]-nearest[0], point[1]-nearest[1])


def _boundary_edge(point, polygon, tolerance):
    matches = []
    for index in range(len(polygon)):
        parameter, distance = _edge_parameter(point, polygon[index], polygon[(index+1) % len(polygon)])
        if distance <= tolerance and tolerance < parameter < 1.0-tolerance:
            matches.append((distance, index))
    return min(matches)[1] if matches else None


def _polygon_area(points):
    return 0.5*sum(points[index][0]*points[(index+1) % len(points)][1]-points[(index+1) % len(points)][0]*points[index][1] for index in range(len(points)))


def _inside_triangle(point, a, b, c, sign):
    return all(sign*_orient(first, second, point) >= -1.0e-12 for first, second in ((a,b),(b,c),(c,a)))


def _triangulate(ids, points):
    """Ear clip a simple planar polygon, preserving its winding."""
    remaining = list(range(len(ids))); triangles = []
    sign = 1.0 if _polygon_area(points) > 0 else -1.0
    while len(remaining) > 3:
        clipped = False
        for offset, current in enumerate(remaining):
            previous = remaining[offset-1]; following = remaining[(offset+1) % len(remaining)]
            if sign*_orient(points[previous],points[current],points[following]) <= 1.0e-12: continue
            if any(_inside_triangle(points[other],points[previous],points[current],points[following],sign) for other in remaining if other not in (previous,current,following)): continue
            triangles.append([ids[previous],ids[current],ids[following]])
            del remaining[offset]; clipped = True; break
        if not clipped: raise ValueError("local split polygon cannot be triangulated safely")
    triangles.append([ids[index] for index in remaining])
    return triangles


def _boundary_chain(start_edge, end_edge, node_ids):
    result=[]; index=(start_edge+1) % len(node_ids)
    while True:
        result.append(node_ids[index])
        if index == end_edge: return result
        index=(index+1) % len(node_ids)


def _edge_owner_count(first, second, model):
    key={int(first),int(second)}
    return sum(1 for row in model.elements.values() if any({row.node_ids[index],row.node_ids[(index+1) % len(row.node_ids)]} == key for index in range(len(row.node_ids))))


def plan_local_split(*args, **kwargs):
    settings = kwargs.get("settings") or (args[-1] if args and isinstance(args[-1], dict) else {})
    if not settings.get("allow_local_split", False):
        return {"status": "MANUAL_REVIEW", "warnings": ["local split is disabled"]}
    model=kwargs.get("model"); candidate=kwargs.get("candidate") or {}; source=list(kwargs.get("source_node_ids") or [])
    if kwargs.get("closed",False):
        return {"status":"MANUAL_REVIEW","warnings":["local split does not support closed source paths"]}
    hints=sorted(set(int(value) for value in candidate.get("target_hint_element_ids",[])))
    if model is None or len(hints) != 1 or len(source) < 2:
        return {"status":"MANUAL_REVIEW","warnings":["local split requires one target shell and one open source path"]}
    element=model.elements.get(hints[0])
    if element is None or element.element_type not in ("CTRIA3","CQUAD4"):
        return {"status":"MANUAL_REVIEW","warnings":["local split supports only one CTRIA3/CQUAD4 mother shell"]}
    property_id=int(getattr(model,"element_properties",{}).get(element.element_id,0))
    if property_id <= 0:
        return {"status":"MANUAL_REVIEW","warnings":["mother shell property is unresolved"]}
    node_ids=list(element.node_ids); plane=_plane(node_ids,model.nodes)
    polygon=[_project(model.nodes[node_id],plane)[1] for node_id in node_ids]
    edge_scale=sum(math.hypot(polygon[(i+1)%len(polygon)][0]-polygon[i][0],polygon[(i+1)%len(polygon)][1]-polygon[i][1]) for i in range(len(polygon)))/len(polygon)
    tolerance=max(1.0e-9,edge_scale*1.0e-7)
    projected=[]; local=[]
    for source_id in source:
        point,coordinates,distance=_project(model.nodes[source_id],plane)
        if not _point_in_convex(coordinates,polygon,tolerance):
            return {"status":"MANUAL_REVIEW","warnings":["projected source path leaves the mother shell"]}
        if distance > float(settings.get("search_distance",float("inf"))):
            return {"status":"MANUAL_REVIEW","warnings":["source path exceeds local split projection distance"]}
        projected.append(point); local.append(coordinates)
    first_edge=_boundary_edge(local[0],polygon,tolerance); last_edge=_boundary_edge(local[-1],polygon,tolerance)
    if first_edge is None or last_edge is None or first_edge == last_edge:
        return {"status":"MANUAL_REVIEW","warnings":["local split chord must terminate inside two distinct mother edges"]}
    for edge_index in (first_edge,last_edge):
        if _edge_owner_count(node_ids[edge_index],node_ids[(edge_index+1) % len(node_ids)],model) != 1:
            return {"status":"MANUAL_REVIEW","warnings":["local split endpoint touches a shared edge; multi-shell propagation is required"]}
    # A simple chord may bend, but it may not self-intersect or collapse.
    if any(norm(_sub(projected[index+1],projected[index])) <= tolerance for index in range(len(projected)-1)):
        return {"status":"MANUAL_REVIEW","warnings":["local split path contains a collapsed segment"]}
    temporary_ids=[-(index+1) for index in range(len(projected))]
    side_a=[temporary_ids[0]]+_boundary_chain(first_edge,last_edge,node_ids)+[temporary_ids[-1]]+list(reversed(temporary_ids[1:-1]))
    side_b=[temporary_ids[-1]]+_boundary_chain(last_edge,first_edge,node_ids)+[temporary_ids[0]]+temporary_ids[1:-1]
    coordinate_map=dict(model.nodes); coordinate_map.update(dict(zip(temporary_ids,projected)))
    local_map=dict(zip(temporary_ids,local)); local_map.update(dict(zip(node_ids,polygon)))
    try:
        connectivity=[]
        for polygon_ids in (side_a,side_b): connectivity.extend(_triangulate(polygon_ids,[local_map[value] for value in polygon_ids]))
    except ValueError as exc:
        return {"status":"MANUAL_REVIEW","warnings":[str(exc)]}
    replacements=[]
    original_normal=plane[3]
    for ids in connectivity:
        metrics=element_metrics(ids,coordinate_map)
        if not metrics["valid"] or metrics["aspect_ratio"] > float(settings.get("max_split_aspect_ratio",20.0)):
            return {"status":"MANUAL_REVIEW","warnings":["local split replacement shell fails geometry quality"]}
        replacement_normal=unit(cross(_sub(coordinate_map[ids[1]],coordinate_map[ids[0]]),_sub(coordinate_map[ids[2]],coordinate_map[ids[0]])))
        if dot(original_normal,replacement_normal) <= 0.0:
            return {"status":"MANUAL_REVIEW","warnings":["local split replacement shell reverses the mother normal"]}
        replacements.append({"element_type":"CTRIA3","node_ids":ids,"property_id":property_id,"component_id":element.component_id,"original_element_id":element.element_id})
    replacement_edges=[]
    for row in replacements:
        ids=row["node_ids"]; replacement_edges.extend(tuple(sorted((ids[index],ids[(index+1)%len(ids)]))) for index in range(len(ids)))
    for first,second in zip(temporary_ids,temporary_ids[1:]):
        if replacement_edges.count(tuple(sorted((first,second)))) != 2:
            return {"status":"MANUAL_REVIEW","warnings":["local split did not create a continuous shared constraint edge"]}
    original_area=element_metrics(node_ids,model.nodes)["area"]
    replacement_area=sum(element_metrics(row["node_ids"],coordinate_map)["area"] for row in replacements)
    if original_area <= 0 or abs(replacement_area-original_area)/original_area > 1.0e-7:
        return {"status":"MANUAL_REVIEW","warnings":["local split does not preserve mother-shell area"]}
    return {"status":"READY","warnings":[],"target_node_ids":temporary_ids,
            "new_nodes":[{"node_id":node_id,"coordinates":list(point)} for node_id,point in zip(temporary_ids,projected)],
            "replacement_elements":replacements,"delete_element_ids":[element.element_id],
            "original_connectivity":{str(element.element_id):node_ids},"read_elements":[element.element_id],
            "coordinates":coordinate_map}
