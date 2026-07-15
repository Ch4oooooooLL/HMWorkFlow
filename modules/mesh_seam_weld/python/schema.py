from __future__ import annotations
from hybrid_schema import SchemaError,validate_request as validate_common
DEFAULTS={"mode":"source","closed_loop":False,"selected_node_ids":[],"source_node_ids":[],"candidate_node_ids":[],"weld_mesh_size":8.0,"mesh_path_param":1}
def validate_request(data):
    data=validate_common(data,"mesh_seam_weld"); s=dict(DEFAULTS); s.update(data["settings"]); s["mode"]=str(s["mode"]).lower(); s["closed_loop"]=bool(s["closed_loop"])
    if s["mode"] not in ("source","target"):raise SchemaError("mode must be source or target")
    for k in ("selected_node_ids","source_node_ids","candidate_node_ids"):s[k]=[int(v) for v in s[k]]
    s["weld_mesh_size"]=float(s["weld_mesh_size"]); s["mesh_path_param"]=int(s["mesh_path_param"])
    if s["weld_mesh_size"]<=0:raise SchemaError("weld_mesh_size must be positive")
    data["settings"]=s; return data
