"""Merge continuous detected edges without crossing graph branches."""
from __future__ import annotations

from collections import defaultdict

try:
    from .geometry import angle_deg, sub
except ImportError:  # Standalone HM2019 entry compatibility.
    from geometry import angle_deg, sub


def _turn_ok(model, previous, current, following, limit):
    return angle_deg(sub(model.nodes[current], model.nodes[previous]), sub(model.nodes[following], model.nodes[current])) <= limit


def build_chains(model, detected, settings):
    by_pair, adjacency = {}, defaultdict(list)
    for item in detected:
        key = tuple(sorted(item.edge.node_ids))
        by_pair[key] = item
        adjacency[key[0]].append(key[1])
        adjacency[key[1]].append(key[0])
    unused, chains = set(by_pair), []
    while unused:
        seed = min(unused)
        # Find the currently unused connected component. Choosing an endpoint
        # from the whole component avoids starting in the middle of an open
        # chain; a degree-two component is a genuine closed loop.
        component_nodes, pending = set(seed), list(seed)
        while pending:
            node = pending.pop()
            for neighbor in adjacency[node]:
                if tuple(sorted((node, neighbor))) not in unused or neighbor in component_nodes:
                    continue
                component_nodes.add(neighbor)
                pending.append(neighbor)
        degrees = {node: sum(tuple(sorted((node, neighbor))) in unused for neighbor in adjacency[node]) for node in component_nodes}
        endpoints = sorted(node for node, degree in degrees.items() if degree == 1)
        closed_component = bool(component_nodes) and all(degree == 2 for degree in degrees.values())
        start = endpoints[0] if endpoints else min(component_nodes)
        branch_warning = any(degree >= 3 for degree in degrees.values())
        nodes, metrics, previous, current = [start], [], None, start
        while True:
            options = sorted(n for n in adjacency[current] if tuple(sorted((current, n))) in unused)
            if previous is not None:
                options = [n for n in options if _turn_ok(model, previous, current, n, float(settings["max_chain_turn_angle_deg"]))]
            if previous is None and closed_component and options:
                options = options[:1]
            if len(options) != 1:
                branch_warning = branch_warning or len(options) > 1
                break
            following = options[0]
            key = tuple(sorted((current, following)))
            unused.remove(key)
            metrics.append(by_pair[key])
            nodes.append(following)
            previous, current = current, following
            if current == start:
                break
        if not metrics:  # branch seed: emit one edge safely
            key = next(key for key in unused if start in key)
            unused.remove(key)
            other = key[1] if key[0] == start else key[0]
            nodes.append(other)
            metrics.append(by_pair[key])
        length = sum(item.edge.length for item in metrics)
        if length < float(settings["min_weld_length"]) and not settings.get("retain_short_candidates", False):
            continue
        warnings = ["BRANCH_POINT"] if branch_warning else []
        chains.append({"node_ids": nodes[:-1] if len(nodes) > 2 and nodes[0] == nodes[-1] else nodes, "is_closed": len(nodes) > 2 and nodes[0] == nodes[-1], "items": metrics, "length": length, "warnings": warnings})
    return chains
