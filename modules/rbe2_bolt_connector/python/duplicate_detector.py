from __future__ import annotations
def annotate(plans,index):
    for p in plans:
        eid=index.get(tuple(sorted((p["node_1"],p["node_2"]))))
        p["existing_element_id"]=eid; p["existing_connector_id"]=eid; p["recommended_action"]="SKIP_EXISTING" if eid else "CREATE"
