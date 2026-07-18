from __future__ import annotations
try:
    from hmworkflow.core.worker_cache import get_adjacency, get_or_create
except ImportError:  # Standalone HM2019 entry compatibility.
    from worker_cache import get_adjacency, get_or_create


def edges(elements):
    elements = list(elements)
    key = tuple(elements)
    return get_or_create("mesh_seam_weld.edges", key, lambda: _edges(elements))


def _edges(elements):
    owners={}
    for e in elements:
        if len(e.node_ids)<3:continue
        for a,b in zip(e.node_ids,e.node_ids[1:]+e.node_ids[:1]):owners.setdefault(tuple(sorted((a,b))),[]).append(e.element_id)
    return owners
def adjacency(owners,free_only=False):
    return get_adjacency(("mesh_seam_weld", id(owners), bool(free_only)), lambda: _adjacency(owners, free_only))


def _adjacency(owners, free_only=False):
    out={}
    for (a,b),rows in owners.items():
        if free_only and len(rows)!=1:continue
        out.setdefault(a,set()).add(b); out.setdefault(b,set()).add(a)
    return out
