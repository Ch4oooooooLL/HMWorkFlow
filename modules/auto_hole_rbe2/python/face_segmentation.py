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
    threshold = math.cos(math.radians(feature_angle_deg))
    pending = set(by_id)
    segments = []
    while pending:
        start = min(pending)
        pending.remove(start)
        queue = deque([start])
        segment = []
        while queue:
            current = queue.popleft()
            segment.append(current)
            for edge in polygon_edges(by_id[current].node_ids):
                for neighbor in sorted(edge_faces[edge]):
                    if neighbor in pending and abs(dot(by_id[current].normal, by_id[neighbor].normal)) >= threshold:
                        pending.remove(neighbor)
                        queue.append(neighbor)
        segments.append(sorted(segment))
    return segments, edge_faces
