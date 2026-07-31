from __future__ import annotations
try:
    from hmworkflow.core.hybrid_schema import SchemaError, validate_request as validate_common
except ImportError:  # Standalone HM2019 entry compatibility.
    from hybrid_schema import SchemaError, validate_request as validate_common
AUTO_DEFAULTS={"search_distance":12.0,"min_seam_length":20.0,"min_path_nodes":3,"parallel_angle_max":15.0,"perpendicular_angle_min":70.0,"max_distance_variation_ratio":0.35,"min_projection_coverage":0.75,"min_overlap_ratio":0.60,"existing_path_search_width":20.0,"max_target_path_offset":8.0,"max_node_move":2.0,"max_node_move_ratio":0.25,"allow_target_node_move":False,"allow_local_split":False,"prefer_quad_weld":True,"allow_weld_end_tria":True,"max_weld_tria_ratio":0.15,"quality_guard_enabled":True,"max_new_failed_elements":0,"existing_weld_search_distance":4.0,"auto_accept_confidence":0.88,"review_confidence":0.60,"execution_batch_size":25}
DEFAULTS={"mode":"source","closed_loop":False,"selected_node_ids":[],"source_node_ids":[],"candidate_node_ids":[],"source_component_ids":[],"target_component_ids":[],"weld_mesh_size":8.0,"mesh_path_param":1,"patch_expand_layers":2}
DEFAULTS.update(AUTO_DEFAULTS)
def validate_request(data):
    data=validate_common(data,"mesh_seam_weld"); s=dict(DEFAULTS); s.update(data["settings"]); s["mode"]=str(s["mode"]).lower(); s["closed_loop"]=bool(s["closed_loop"])
    if s["mode"] not in ("source","target","component_plan","internal_component_plan","auto_detect","auto_plan"):raise SchemaError("unsupported mesh seam mode")
    for k in ("selected_node_ids","source_node_ids","candidate_node_ids","source_component_ids","target_component_ids"):s[k]=[int(v) for v in s[k]]
    if s["mode"]=="internal_component_plan" and (len(s["selected_node_ids"])!=1 or len(s["source_component_ids"])!=1 or not s["target_component_ids"]):raise SchemaError("internal_component_plan requires one selected node, one source component, and target components")
    s["weld_mesh_size"]=float(s["weld_mesh_size"]); s["mesh_path_param"]=int(s["mesh_path_param"]); s["patch_expand_layers"]=int(s["patch_expand_layers"])
    if s["weld_mesh_size"]<=0:raise SchemaError("weld_mesh_size must be positive")
    if s["patch_expand_layers"]<0:raise SchemaError("patch_expand_layers must be non-negative")
    for k in ("search_distance","min_seam_length","parallel_angle_max","perpendicular_angle_min","existing_path_search_width","max_target_path_offset","max_node_move"):
        s[k]=float(s[k])
        if s[k] < 0: raise SchemaError("{} must not be negative".format(k))
    s["min_path_nodes"]=int(s["min_path_nodes"])
    if s["min_path_nodes"] < 2: raise SchemaError("min_path_nodes must be at least 2")
    s["max_new_failed_elements"]=int(s["max_new_failed_elements"])
    if s["max_new_failed_elements"] < 0: raise SchemaError("max_new_failed_elements must not be negative")
    data["settings"]=s; return data
