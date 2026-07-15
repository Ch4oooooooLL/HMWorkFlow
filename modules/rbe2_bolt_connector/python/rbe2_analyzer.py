from __future__ import annotations
import math
from diameter_selector import estimate
from planar_detector import detect

def analyze(model, settings):
    records=[]; rejected=[]
    for elem in sorted(model.elements.values(),key=lambda e:e.element_id):
        if elem.element_type not in ("RBE2","RIGIDLINK") or len(elem.node_ids)<3: continue
        inode=elem.node_ids[0]; center=model.nodes[inode]; deps=list(elem.node_ids[1:]); points=[model.nodes[n] for n in deps]
        distances=[math.sqrt(sum((p[i]-center[i])**2 for i in range(3))) for p in points]
        dia=estimate(distances,settings)
        if not dia: rejected.append({"element_id":elem.element_id,"reason":"NO_MEANINGFUL_RADIUS"}); continue
        planar,axis,ranges=detect(center,points,settings)
        records.append({"element_id":elem.element_id,"independent_node_id":inode,"dependent_node_ids":deps,"center":list(center),"diameter":dia,"planar":planar,"normal_axis":axis,"ranges":ranges})
    return records,rejected
