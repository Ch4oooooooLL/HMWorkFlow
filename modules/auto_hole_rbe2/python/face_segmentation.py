"""Segment exterior faces using the legacy shared-edge normal rule."""
from __future__ import annotations

import math
from collections import defaultdict, deque

from geometry import dot
from topology import polygon_edges


def segment_faces(faces, feature_angle_deg):
    by_id = {face.face_id: face for face in faces}
    edge_faces = defaultdict(list)
    for face in faces:
        for edge in polygon_edges(face.node_ids):
            edge_faces[edge].append(face.face_id)
    for rows in edge_faces.values():
        rows.sort()
    threshold = math.cos(math.radians(feature_angle_deg))
    pending = set(by_id)
    segments = []
    # Iterating a pre-sorted ID list keeps deterministic output without
    # repeatedly scanning the whole pending set.  The former min(pending)
    # loop degraded to O(face_count^2) on highly segmented surfaces.
    for start in sorted(by_id):
        if start not in pending:
            continue
        pending.remove(start)
        queue = deque([start])
        segment = []
        while queue:
            current = queue.popleft()
            segment.append(current)
            for edge in polygon_edges(by_id[current].node_ids):
                for neighbor in edge_faces[edge]:
                    if neighbor in pending and abs(dot(by_id[current].normal, by_id[neighbor].normal)) >= threshold:
                        pending.remove(neighbor)
                        queue.append(neighbor)
        segments.append(sorted(segment))
    return segments, edge_faces
