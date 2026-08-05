"""Create a non-crossing quad-dominant zipper between two ordered paths."""
from __future__ import annotations

import math


def _distance(a, b): return math.sqrt(sum((a[i]-b[i])**2 for i in range(3)))


def _parameters(path, nodes, closed=False):
    pairs = list(zip(path, path[1:])) + ([(path[-1], path[0])] if closed else [])
    lengths = [_distance(nodes[a], nodes[b]) for a, b in pairs]; total = sum(lengths)
    if total <= 1.0e-12: raise ValueError("zero-length weld path")
    values, accumulated = [0.0], 0.0
    for length in lengths[:-1 if closed else None]: accumulated += length; values.append(accumulated/total)
    return values


def plan_zipper(source, target, nodes, closed=False, allow_end_tria=True, max_tria_ratio=0.15):
    if len(source) < (3 if closed else 2) or len(target) < (3 if closed else 2): raise ValueError("weld paths are too short")
    source_t, target_t = _parameters(source, nodes, closed), _parameters(target, nodes, closed)
    elements, i, j = [], 0, 0; source_limit = len(source) if closed else len(source)-1; target_limit = len(target) if closed else len(target)-1
    while i < source_limit or j < target_limit:
        next_s = (source_t[i+1] if i+1 < len(source_t) else 1.0) if i < source_limit else float("inf")
        next_t = (target_t[j+1] if j+1 < len(target_t) else 1.0) if j < target_limit else float("inf")
        a, b = source[i % len(source)], target[j % len(target)]
        if i < source_limit and j < target_limit and abs(next_s-next_t) <= 1.0e-9:
            ids = [a, source[(i+1)%len(source)], target[(j+1)%len(target)], b]; i += 1; j += 1; kind = "CQUAD4"
        elif next_s < next_t:
            ids = [a, source[(i+1)%len(source)], b]; i += 1; kind = "CTRIA3"
        else:
            ids = [a, target[(j+1)%len(target)], b]; j += 1; kind = "CTRIA3"
        if len(set(ids)) != len(ids): raise ValueError("zipper creates a repeated-node element")
        elements.append({"element_type": kind, "node_ids": ids})
    triangles = sum(row["element_type"] == "CTRIA3" for row in elements)
    if triangles and not allow_end_tria: raise ValueError("zipper needs triangular transition elements")
    if elements and triangles/float(len(elements)) > max_tria_ratio: raise ValueError("zipper triangle ratio exceeds configured limit")
    signatures = set()
    for row in elements:
        signature = tuple(sorted(row["node_ids"]))
        if signature in signatures: raise ValueError("duplicate weld element")
        signatures.add(signature)
    return elements
