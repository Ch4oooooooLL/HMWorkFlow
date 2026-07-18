"""Build ordered boundary loops for a segmented face patch."""
from __future__ import annotations

from collections import Counter

try:
    from hmworkflow.core.edge_graph import EdgeGraph
    from hmworkflow.core.topology import polygon_edges
except ImportError:  # Standalone HM2019 entry compatibility.
    from edge_graph import EdgeGraph
    from topology import polygon_edges


def boundary_loops(segment, faces_by_id):
    counts = Counter()
    for face_id in segment:
        counts.update(polygon_edges(faces_by_id[face_id].node_ids))
    boundary = [edge for edge, count in counts.items() if count == 1]
    paths = EdgeGraph(boundary).ordered_paths()
    if any(row["branched"] or not row["closed"] for row in paths):
        return []
    return [list(row["nodes"]) for row in paths]
