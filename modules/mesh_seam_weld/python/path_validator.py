from __future__ import annotations
def validate_ordered(nodes,adj,closed=False):
    if len(nodes)<(3 if closed else 2):raise ValueError("path has too few nodes")
    if len(nodes)!=len(set(nodes)):raise ValueError("path contains duplicate nodes")
    pairs=list(zip(nodes,nodes[1:])); pairs += [(nodes[-1],nodes[0])] if closed else []
    if any(b not in adj.get(a,()) for a,b in pairs):raise ValueError("selected nodes do not form a continuous element-edge path")
    return list(nodes)
