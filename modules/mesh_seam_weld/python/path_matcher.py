from __future__ import annotations
def match(source,candidates,coords):
    if len(candidates)<len(source):raise ValueError("not enough imprint nodes")
    available=set(candidates); out=[]
    for sid in source:
        p=coords[sid]; best=min(available,key=lambda n:(sum((coords[n][i]-p[i])**2 for i in range(3)),n)); available.remove(best); out.append(best)
    return out
