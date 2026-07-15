from __future__ import annotations

AXIS={"X":0,"Y":1,"Z":2}
def allowed(a,b,axis): return all((not r["planar"]) or r["normal_axis"]==axis for r in (a,b))
def matches(a,b,axis,s):
    if not allowed(a,b,axis):return False
    i=AXIS[axis]; cross=[j for j in range(3) if j!=i]; gap=abs(a["center"][i]-b["center"][i])
    return s["minBeamLength"]<gap<=s["gapTol"] and all(abs(a["center"][j]-b["center"][j])<=s["offsetTol"] for j in cross)

def _for_axis(records,axis,s):
    parent=list(range(len(records)))
    def find(i):
        while parent[i]!=i: parent[i]=parent[parent[i]]; i=parent[i]
        return i
    for i,a in enumerate(records):
        for j in range(i+1,len(records)):
            if matches(a,records[j],axis,s):
                x,y=find(i),find(j)
                if x!=y:parent[y]=x
    groups={}
    for i,row in enumerate(records):groups.setdefault(find(i),[]).append(row)
    return [{"axis":axis,"records":sorted(g,key=lambda r:r["center"][AXIS[axis]])} for g in groups.values() if len(g)>=s["minGroupSize"]]

def build(records,s):
    axes=("X","Y","Z") if s["axisMode"]=="AUTO" else (s["axisMode"],); best={}
    for axis in axes:
        for group in _for_axis(records,axis,s):
            key=tuple(sorted(r["independent_node_id"] for r in group["records"])); i=AXIS[axis]; spread=group["records"][-1]["center"][i]-group["records"][0]["center"][i]
            if key not in best or spread>best[key][0]:best[key]=(spread,group)
    return [best[k][1] for k in sorted(best)]
