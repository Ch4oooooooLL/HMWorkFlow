"""Bounded deterministic Dijkstra search for an existing target mesh edge."""
from __future__ import annotations

import heapq
import math

try:
    from .element_projection import angle_degrees
    from .shell_topology import edge_graph
except ImportError:
    from element_projection import angle_degrees
    from shell_topology import edge_graph


def _distance(a, b): return math.sqrt(sum((a[i]-b[i])**2 for i in range(3)))


def _point_segment_distance(point, first, second):
    direction = tuple(second[i]-first[i] for i in range(3)); denominator = sum(v*v for v in direction)
    if denominator <= 1.0e-24: return _distance(point, first)
    parameter = max(0.0, min(1.0, sum((point[i]-first[i])*direction[i] for i in range(3))/denominator))
    projected = tuple(first[i]+parameter*direction[i] for i in range(3)); return _distance(point, projected)


def _corridor_distance(point, source_points):
    return min(_point_segment_distance(point, source_points[index], source_points[index+1]) for index in range(len(source_points)-1))


def solve_existing_edge_path(model, component_id, source_node_ids, settings, target_hint_node_ids=None):
    graph, _ = edge_graph(model, component_id, free_only=False)
    source_points = [model.nodes[node_id] for node_id in source_node_ids]
    width = float(settings.get("existing_path_search_width", 20.0)); max_offset = float(settings.get("max_target_path_offset", 8.0))
    allowed = {node_id for node_id in graph if _corridor_distance(model.nodes[node_id], source_points) <= width}
    if target_hint_node_ids: allowed &= set(target_hint_node_ids) | {neighbor for node in target_hint_node_ids for neighbor in graph.get(node, ())}
    if len(allowed) < 2: return None
    start = min(allowed, key=lambda node: (_distance(model.nodes[node], source_points[0]), node))
    end = min(allowed, key=lambda node: (_distance(model.nodes[node], source_points[-1]), node))
    if start == end: return None
    queue, costs, previous = [(0.0, start)], {start: 0.0}, {}
    while queue:
        cost, current = heapq.heappop(queue)
        if cost != costs[current]: continue
        if current == end: break
        for neighbor in sorted(graph.get(current, ())):
            if neighbor not in allowed: continue
            length = _distance(model.nodes[current], model.nodes[neighbor])
            offset = _corridor_distance(model.nodes[neighbor], source_points)
            new_cost = cost + length + 2.0*offset
            if new_cost < costs.get(neighbor, float("inf")):
                costs[neighbor] = new_cost; previous[neighbor] = current; heapq.heappush(queue, (new_cost, neighbor))
    if end not in previous: return None
    path, current = [end], end
    while current != start: current = previous[current]; path.append(current)
    path.reverse()
    reverse_cost = _distance(model.nodes[path[0]], source_points[-1])+_distance(model.nodes[path[-1]], source_points[0])
    forward_cost = _distance(model.nodes[path[0]], source_points[0])+_distance(model.nodes[path[-1]], source_points[-1])
    if reverse_cost < forward_cost: path.reverse()
    offsets = [_corridor_distance(model.nodes[node_id], source_points) for node_id in path]
    return {"node_ids": path, "maximum_offset": max(offsets), "average_offset": sum(offsets)/len(offsets), "search_cost": costs[end], "requires_adjustment": max(offsets) > max_offset}
