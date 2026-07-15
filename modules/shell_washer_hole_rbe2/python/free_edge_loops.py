"""Find deterministic free-edge components and closed loops."""
from __future__ import annotations

from edge_graph import EdgeGraph


def find(incidence):
    free_edges = [edge for edge, attached in incidence.items() if len(attached) == 1]
    rows = []
    for path in EdgeGraph(free_edges).ordered_paths():
        nodes = list(path["nodes"])
        rows.append({
            "nodes": nodes,
            "edges": [[nodes[i], nodes[(i + 1) % len(nodes)]] for i in range(len(nodes))] if path["closed"] else [],
            "closed": bool(path["closed"]),
            "branched": bool(path["branched"]),
        })
    return rows
