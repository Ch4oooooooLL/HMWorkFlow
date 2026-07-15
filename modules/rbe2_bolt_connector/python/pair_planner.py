from __future__ import annotations
import math
from diameter_selector import choose
from grouping import matches

def plan(groups,s):
    plans=[]; rejected=[]
    for gi,g in enumerate(groups,1):
        rows=g["records"]
        if not any(r["planar"] for r in rows): rejected.append({"group_id":gi,"reason":"SPATIAL_ONLY"}); continue
        dia=choose(rows); comp="{}_D{}_{}".format(s["compPrefix"],dia if dia else "UNKNOWN",s["elemType"])
        for a,b in zip(rows,rows[1:]):
            if not matches(a,b,g["axis"],s): rejected.append({"group_id":gi,"reason":"ADJACENT_PAIR_OUT_OF_TOLERANCE"}); continue
            delta=[b["center"][i]-a["center"][i] for i in range(3)]; ai={"X":0,"Y":1,"Z":2}[g["axis"]]
            plans.append({"candidate_id":"B{:04d}".format(len(plans)+1),"group_id":"G{:04d}".format(gi),"axis":g["axis"],
                "rbe2_a":{"element_id":a["element_id"],"center_node_id":a["independent_node_id"],"center":a["center"]},
                "rbe2_b":{"element_id":b["element_id"],"center_node_id":b["independent_node_id"],"center":b["center"]},
                "node_1":a["independent_node_id"],"node_2":b["independent_node_id"],"axial_distance":abs(delta[ai]),
                "transverse_offset":math.sqrt(sum(delta[i]**2 for i in range(3) if i!=ai)),"diameter_a":a["diameter"],"diameter_b":b["diameter"],
                "diameter":dia,"recommended_diameter":dia,"component_name":comp,"recommended_component_name":comp,
                "property_name":s["propName"],"recommended_property_name":s["propName"],"element_type":s["elemType"],"recommended_element_type":s["elemType"],
                "confidence":1.0,"warnings":[]})
    return plans,rejected
