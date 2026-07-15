from __future__ import annotations
def closed_loop(seed,adj):
    if len(adj.get(seed,()))!=2:raise ValueError("seed is not on a manifold closed free edge")
    path=[seed]; prev=None; current=seed
    while True:
        choices=sorted(n for n in adj.get(current,()) if n!=prev)
        if not choices:raise ValueError("free edge path ended before closure")
        nxt=choices[0]
        if nxt==seed:break
        if nxt in path:raise ValueError("free edge path self-intersects")
        if len(adj.get(nxt,()))!=2:raise ValueError("free edge path is branched or open")
        path.append(nxt); prev,current=current,nxt
        if len(path)>len(adj)+1:raise ValueError("free edge traversal exceeded topology")
    if len(path)<3:raise ValueError("closed loop needs at least three nodes")
    return path
