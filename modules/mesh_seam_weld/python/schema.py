from __future__ import annotations
try:
    from hmworkflow.core.hybrid_schema import SchemaError, validate_request as validate_common
except ImportError:  # Standalone HM2019 entry compatibility.
    from hybrid_schema import SchemaError, validate_request as validate_common
DEFAULTS={"mode":"source","closed_loop":False,"selected_node_ids":[],"source_node_ids":[],"candidate_node_ids":[],"source_component_ids":[],"target_component_ids":[],"weld_mesh_size":8.0,"mesh_path_param":1,"patch_expand_layers":2}
def validate_request(data):
    data=validate_common(data,"mesh_seam_weld"); s=dict(DEFAULTS); s.update(data["settings"]); s["mode"]=str(s["mode"]).lower(); s["closed_loop"]=bool(s["closed_loop"])
    if s["mode"] not in ("source","target","component_plan","internal_component_plan"):raise SchemaError("mode must be source, target, component_plan, or internal_component_plan")
    for k in ("selected_node_ids","source_node_ids","candidate_node_ids","source_component_ids","target_component_ids"):s[k]=[int(v) for v in s[k]]
    if s["mode"]=="internal_component_plan" and (len(s["selected_node_ids"])!=1 or len(s["source_component_ids"])!=1 or not s["target_component_ids"]):raise SchemaError("internal_component_plan requires one selected node, one source component, and target components")
    s["weld_mesh_size"]=float(s["weld_mesh_size"]); s["mesh_path_param"]=int(s["mesh_path_param"]); s["patch_expand_layers"]=int(s["patch_expand_layers"])
    if s["weld_mesh_size"]<=0:raise SchemaError("weld_mesh_size must be positive")
    if s["patch_expand_layers"]<0:raise SchemaError("patch_expand_layers must be non-negative")
    data["settings"]=s; return data
