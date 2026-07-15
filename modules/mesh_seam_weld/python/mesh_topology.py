from __future__ import annotations
def edges(elements):
    owners={}
    for e in elements:
        if len(e.node_ids)<3:continue
        for a,b in zip(e.node_ids,e.node_ids[1:]+e.node_ids[:1]):owners.setdefault(tuple(sorted((a,b))),[]).append(e.element_id)
    return owners
def adjacency(owners,free_only=False):
    out={}
    for (a,b),rows in owners.items():
        if free_only and len(rows)!=1:continue
        out.setdefault(a,set()).add(b); out.setdefault(b,set()).add(a)
    return out
