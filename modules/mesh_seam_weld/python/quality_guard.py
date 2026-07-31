"""Conservative pure-Python quality preflight for newly planned shell strips."""
from __future__ import annotations

import math


def _sub(a, b): return tuple(a[i]-b[i] for i in range(3))
def _cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def _norm(a): return math.sqrt(sum(value*value for value in a))
def _dot(a,b): return sum(a[index]*b[index] for index in range(3))
def triangle_area(a, b, c): return 0.5*_norm(_cross(_sub(b,a),_sub(c,a)))


def _orientation(a, b, c): return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])


def _segments_cross(a, b, c, d):
    return _orientation(a,b,c)*_orientation(a,b,d) < -1.0e-18 and _orientation(c,d,a)*_orientation(c,d,b) < -1.0e-18


def quad_self_intersects(points):
    for first_axis, second_axis in ((0,1),(0,2),(1,2)):
        projected=[(point[first_axis],point[second_axis]) for point in points]
        if _segments_cross(projected[0],projected[1],projected[2],projected[3]) or _segments_cross(projected[1],projected[2],projected[3],projected[0]): return True
    return False


def element_metrics(node_ids, nodes):
    points = [nodes[node_id] for node_id in node_ids]
    edges = [_norm(_sub(points[(i+1)%len(points)], points[i])) for i in range(len(points))]
    if min(edges) <= 1.0e-12: return {"area": 0.0, "aspect_ratio": float("inf"), "valid": False}
    area = triangle_area(points[0], points[1], points[2])
    if len(points) == 4: area += triangle_area(points[0], points[2], points[3])
    crossed = len(points) == 4 and quad_self_intersects(points)
    angles=[]
    for index in range(len(points)):
        before=_sub(points[index-1],points[index]); after=_sub(points[(index+1)%len(points)],points[index])
        cosine=max(-1.0,min(1.0,_dot(before,after)/(_norm(before)*_norm(after)))); angles.append(math.degrees(math.acos(cosine)))
    warpage=0.0
    if len(points) == 4:
        first=_cross(_sub(points[1],points[0]),_sub(points[2],points[0])); second=_cross(_sub(points[2],points[0]),_sub(points[3],points[0]))
        if _norm(first) > 1.0e-12 and _norm(second) > 1.0e-12:
            cosine=max(-1.0,min(1.0,_dot(first,second)/(_norm(first)*_norm(second)))); warpage=math.degrees(math.acos(cosine))
    return {"area":area,"aspect_ratio":max(edges)/min(edges),"minimum_angle":min(angles),"maximum_angle":max(angles),"warpage":warpage,"self_intersecting":crossed,"valid":area > 1.0e-12 and len(set(node_ids)) == len(node_ids) and not crossed}


def validate_weld_elements(elements, nodes, max_aspect_ratio=20.0, min_angle=5.0, max_angle=175.0, max_warpage=30.0):
    failures = []
    signatures = set()
    for index, element in enumerate(elements):
        ids = element["node_ids"]; metrics = element_metrics(ids, nodes); signature = tuple(sorted(ids))
        if signature in signatures: failures.append({"index": index, "reason": "duplicate element"})
        signatures.add(signature)
        if metrics.get("self_intersecting"): failures.append({"index": index, "reason": "self-intersecting weld quad"})
        elif not metrics["valid"]: failures.append({"index": index, "reason": "degenerate element"})
        elif metrics["aspect_ratio"] > max_aspect_ratio: failures.append({"index": index, "reason": "aspect ratio"})
        elif metrics["minimum_angle"] < min_angle or metrics["maximum_angle"] > max_angle: failures.append({"index":index,"reason":"shell angle"})
        elif metrics["warpage"] > max_warpage: failures.append({"index":index,"reason":"warpage"})
    return {"passed": not failures, "failed_elements": failures}


def validate_strip_connectivity(elements, source, target):
    """Require a continuous strip whose every cell touches both path sides."""
    source_set=set(source); target_set=set(target); failures=[]
    for index,element in enumerate(elements):
        ids=set(element["node_ids"])
        if not ids & source_set or not ids & target_set: failures.append({"index":index,"reason":"weld cell does not touch both seam sides"})
        if index and len(set(elements[index-1]["node_ids"]) & ids) < 2: failures.append({"index":index,"reason":"weld strip is not edge-continuous"})
    return {"passed":not failures,"failed_elements":failures}
