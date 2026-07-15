from __future__ import annotations
def _area(a,b,c):
    u=[b[i]-a[i] for i in range(3)]; v=[c[i]-a[i] for i in range(3)]; cross=(u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]); return 0.5*sum(x*x for x in cross)**0.5
def plan(source,target,closed,coords=None):
    count=len(source) if closed else len(source)-1
    out=[]
    for i in range(count):
        ids=[source[i],source[(i+1)%len(source)],target[(i+1)%len(target)],target[i]]
        if len(set(ids))<4:raise ValueError("degenerate seam element contains repeated nodes")
        if coords and _area(coords[ids[0]],coords[ids[1]],coords[ids[2]])+_area(coords[ids[0]],coords[ids[2]],coords[ids[3]])<=1.0e-12:raise ValueError("degenerate seam element has near-zero area")
        out.append({"segment_index":i,"node_ids":ids,"preferred_type":"QUAD"})
    return out
