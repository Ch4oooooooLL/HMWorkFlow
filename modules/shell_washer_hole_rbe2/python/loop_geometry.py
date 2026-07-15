"""Legacy-compatible loop geometry and shape statistics."""
from __future__ import annotations

from geometry import centroid, distance, dot, normalize, subtract
from statistics import mean, population_stddev


def calculate(model, nodes):
    if not nodes: raise ValueError("empty loop")
    center = centroid(model.nodes[node] for node in nodes)
    radii = [distance(model.nodes[node], center) for node in nodes]
    average = mean(radii); minimum = min(radii); maximum = max(radii)
    relative = population_stddev(radii) / average if average > 1.0e-12 else 999.0
    ratio = maximum / minimum if minimum > 1.0e-12 else 999.0
    perimeter = sum(distance(model.nodes[nodes[i]], model.nodes[nodes[(i + 1) % len(nodes)]]) for i in range(len(nodes)))
    normal_raw=[0.0,0.0,0.0]
    for i,node in enumerate(nodes):
        a=model.nodes[node]; b=model.nodes[nodes[(i+1)%len(nodes)]]
        normal_raw[0]+=(a[1]-b[1])*(a[2]+b[2]); normal_raw[1]+=(a[2]-b[2])*(a[0]+b[0]); normal_raw[2]+=(a[0]-b[0])*(a[1]+b[1])
    try: normal=normalize(normal_raw); planarity=max(abs(dot(subtract(model.nodes[node],center),normal)) for node in nodes)
    except ValueError: normal=(0.0,0.0,0.0); planarity=float("inf")
    return {"center": center, "normal": normal, "planarity_error": planarity, "mean_radius": average, "min_radius": minimum, "max_radius": maximum, "radial_rel": relative, "axis_ratio": ratio, "perimeter": perimeter}
