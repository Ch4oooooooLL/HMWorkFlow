from __future__ import annotations
import argparse,importlib.util,sys,time,math
from pathlib import Path
MODULE_DIR=Path(__file__).resolve().parent; COMMON_DIR=MODULE_DIR.parents[1]/"hybrid_core"/"python"
for d in (str(MODULE_DIR),str(COMMON_DIR)):
    if d not in sys.path:sys.path.insert(0,d)
try:
    from .auto_workflow import detect as auto_detect, plan_candidates
    from .report_writer import write_html, write_report
    from .shell_weld_delta import write_manifest, write_plan_delta_files, write_shell_weld_delta
    from .free_edge_path import closed_loop
    from .mesh_topology import adjacency, edges
    from .path_aligner import align_with_metadata
    from .path_matcher import match
    from .path_validator import validate_ordered
    from .result_validator import validate
    from .seam_planner import plan
    from .component_planner import plan_component_welds, plan_internal_component_welds
    from .fem_mesh_reader import read_shell_fem_bundle
    from hmworkflow.core.hybrid_schema import new_result
    from hmworkflow.core.logging_utils import close_logger, create_logger
    from hmworkflow.core.mesh_model import load_json, read_mesh
    from hmworkflow.core.result_writer import write_result
except ImportError:  # Standalone HM2019 entry compatibility.
    from auto_workflow import detect as auto_detect, plan_candidates
    from free_edge_path import closed_loop
    from hybrid_schema import new_result
    from logging_utils import close_logger, create_logger
    from mesh_model import load_json, read_mesh
    from mesh_topology import adjacency, edges
    from path_aligner import align_with_metadata
    from path_matcher import match
    from path_validator import validate_ordered
    from result_validator import validate
    from result_writer import write_result
    from seam_planner import plan
    from report_writer import write_html, write_report
    from shell_weld_delta import write_manifest, write_plan_delta_files, write_shell_weld_delta
    from component_planner import plan_component_welds, plan_internal_component_welds
    from fem_mesh_reader import read_shell_fem_bundle
SPEC=importlib.util.spec_from_file_location("seam_schema",str(MODULE_DIR/"schema.py")); MOD=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MOD)
def calculate(req,model,existing=None):
    s=req["settings"]
    if s["mode"]=="auto_detect":
        candidates=auto_detect(model,s,(existing or {}).get("seams",[]))
        return {"candidate_id":"AUTO","mode":"auto_detect","candidates":candidates,"candidate_count":len(candidates),"warnings":[],"recommended_action":"REVIEW"}
    if s["mode"]=="auto_plan":
        candidates=req.get("candidates") or auto_detect(model,s,(existing or {}).get("seams",[]))
        accepted=set(str(value) for value in req.get("accepted_candidate_ids",[]))
        overrides={str(key):str(value).upper() for key,value in req.get("candidate_type_overrides",{}).items()}
        swapped=set(str(value) for value in req.get("candidate_swap_ids",[]))
        for row in candidates:
            if row["candidate_id"] in overrides: row["joint_type"]=overrides[row["candidate_id"]]; row["reasons"].append("joint type overridden by reviewer")
            if row["candidate_id"] in swapped: row["joint_type"]="REVIEW"; row["warnings"].append("source/target swap requires manual path confirmation")
        review={row["candidate_id"]:{"decision":"ACCEPT" if row["candidate_id"] in accepted else "PENDING"} for row in candidates}
        planned=plan_candidates(model,candidates,s,review)
        planned["detected_candidates"]=candidates
        return {"candidate_id":"AUTO","mode":"auto_plan","creation_plan":planned,"candidate_count":len(planned["plans"]),"warnings":[],"recommended_action":"APPLY_REVIEWED_PLAN"}
    if s["mode"]=="internal_component_plan":
        plans=plan_internal_component_welds(model,s["source_component_ids"][0],s["selected_node_ids"][0],s["target_component_ids"],s["patch_expand_layers"])
        return {"candidate_id":"I0001","mode":"internal_component_plan","weld_plans":plans,"path_count":len(plans),"warnings":[],"recommended_action":"EXECUTE_TCL_PLAN"}
    if s["mode"]=="component_plan":
        weld_plans=plan_component_welds(model,s["source_component_ids"],s["target_component_ids"],s["weld_mesh_size"],s["patch_expand_layers"],s.get("selected_node_ids",[]))
        return {"candidate_id":"B0001","mode":"component_plan","weld_plans":weld_plans,"path_count":len(weld_plans),"warnings":[],"recommended_action":"EXECUTE_BINARY_PLAN"}
    if s["mode"]=="source":
        graph=adjacency(edges(model.elements.values()),free_only=s["closed_loop"]); selected=s["selected_node_ids"]
        path=closed_loop(selected[0],graph) if s["closed_loop"] and len(selected)==1 else validate_ordered(selected,graph,s["closed_loop"])
        validate(path,model); pairs=list(zip(path,path[1:]))+([(path[-1],path[0])] if s["closed_loop"] else []); length=sum(math.sqrt(sum((model.nodes[a][i]-model.nodes[b][i])**2 for i in range(3))) for a,b in pairs); density=max(s["mesh_path_param"],int(math.ceil(length/s["weld_mesh_size"])))
        return {"candidate_id":"S0001","mode":"source","source_component_ids":req["selected_component_ids"],"target_component_ids":[],"source_node_ids":path,"path_node_ids":path,"source_element_ids":sorted(model.elements),"is_closed":s["closed_loop"],"closed_loop":s["closed_loop"],"length":length,"expected_density":density,"topology_status":"VALID","branch_node_ids":[],"warnings":[],"recommended_action":"IMPRINT"}
    source=s["source_node_ids"]; matched=match(source,s["candidate_node_ids"],model.nodes); target,reversed_path,offset,pairing_cost=align_with_metadata(source,matched,model.nodes,s["closed_loop"]); validate(target,model); graph=adjacency(edges(model.elements.values())); validate_ordered(target,graph,s["closed_loop"]); element_plan=plan(source,target,s["closed_loop"],model.nodes)
    return {"candidate_id":"T0001","mode":"target","source_node_ids":source,"target_node_ids":target,"closed_loop":s["closed_loop"],"target_reversed":reversed_path,"target_rotation_offset":offset,"pairing_cost":pairing_cost,"pair_count":len(source),"element_plan":element_plan,"segments":element_plan,"confidence":1.0,"warnings":[],"recommended_action":"CREATE"}
def main(argv=None):
    p=argparse.ArgumentParser()
    for n in ("request","mesh","existing","output","tcl-output","log"):p.add_argument("--"+n,required=True,type=Path)
    a=p.parse_args(argv); logger=create_logger("mesh_seam_weld",a.log)
    try:
        t=time.perf_counter(); req=MOD.validate_request(load_json(a.request)); settings=req["settings"]
        if settings["mode"] in ("internal_component_plan","auto_detect","auto_plan"):
            model=read_shell_fem_bundle(a.mesh)
        else:model=read_mesh(a.mesh)
        existing=load_json(a.existing); read=time.perf_counter()-t; t=time.perf_counter(); candidate=calculate(req,model,existing); detect_seconds=time.perf_counter()-t
        result=new_result("mesh_seam_weld",req["run_id"])
        result["performance"].update({"read_seconds":round(read,6),"parse_seconds":round(read,6),"topology_seconds":0.0,"pair_filter_seconds":0.0,"detection_seconds":round(detect_seconds,6) if settings["mode"]=="auto_detect" else 0.0,"classification_seconds":0.0,"planning_seconds":round(detect_seconds,6) if settings["mode"]=="auto_plan" else 0.0,"python_quality_seconds":0.0,"snapshot_seconds":0.0,"node_move_seconds":0.0,"delete_seconds":0.0,"import_seconds":0.0,"hm_quality_seconds":0.0,"rollback_seconds":0.0,"total_seconds":round(read+detect_seconds,6)})
        if settings["mode"]=="auto_detect":
            result["candidates"]=candidate["candidates"]
            result["summary"]={"mode":"auto_detect","candidate_count":len(candidate["candidates"])}
            write_report(a.output.parent/"candidates.json",{"schema_version":"1.0","candidates":candidate["candidates"]})
        elif settings["mode"]=="auto_plan":
            creation=candidate["creation_plan"]; result["candidates"]=creation["plans"]
            ready=[row for row in creation["plans"] if row["status"]=="READY"]
            result["summary"]={"mode":"auto_plan","candidate_count":len(creation["plans"]),"accepted_count":len(req.get("accepted_candidate_ids",[])),"ready_count":len(ready),"existing_path_count":sum(row["mode"]=="EXISTING_EDGE_PATH" for row in ready),"adjusted_path_count":sum(row["mode"]=="ADJUSTED_EDGE_PATH" for row in ready),"local_split_count":sum(row["mode"]=="LOCAL_SPLIT_PATH" for row in ready),"manual_count":sum(row["status"]=="MANUAL_REVIEW" for row in creation["plans"]),"created_weld_element_count":sum(len(row["weld_elements"]) for row in ready),"replaced_mother_element_count":sum(len(row["replacement_elements"]) for row in ready),"moved_node_count":sum(len(row["move_nodes"]) for row in ready)}
            manifest=write_shell_weld_delta(a.output.parent/"delta.fem",creation["plans"],req)
            delta_files=write_plan_delta_files(a.output.parent/"deltas",creation["plans"])
            for row in manifest["plans"]: row["delta_fem"] = delta_files[row["candidate_id"]]
            write_manifest(a.output.parent/"delta_manifest.json",manifest)
            write_report(a.output.parent/"creation_plan.json",creation)
            detected_by_id={row["candidate_id"]:row for row in creation.get("detected_candidates",[])}
            audit_rows=[]
            for plan in creation["plans"]:
                source=dict(detected_by_id.get(plan["candidate_id"],{})); source.update({"plan_status":plan["status"],"realization_mode":plan["mode"],"batch_id":plan.get("batch_id",""),"plan_warnings":plan.get("warnings",[]),"created_weld_element_ids":[row.get("element_id") for row in plan.get("weld_elements",[])],"created_mother_element_ids":[row.get("element_id") for row in plan.get("replacement_elements",[])],"created_node_ids":[row.get("node_id") for row in plan.get("new_nodes",[])]}); audit_rows.append(source)
            report={"schema_version":"1.0","summary":result["summary"],"performance":result["performance"],"candidates":audit_rows}; write_report(a.output.parent/"report.json",report); write_html(a.output.parent/"report.html",report)
        else:
            result["candidates"]=[candidate]; result["summary"]={"mode":candidate["mode"],"path_node_count":len(candidate.get("path_node_ids",candidate.get("target_node_ids",[]))),"path_count":candidate.get("path_count",1)}
        result["performance"]["detect_seconds"]=round(detect_seconds,6); write_result(a.output,getattr(a,"tcl_output"),"::MeshSeamWeld::pythonResult",result); return 0
    except Exception as exc:logger.exception("seam planning failed"); print("ERROR: {}".format(exc),file=sys.stderr); return 2
    finally:close_logger(logger)
if __name__=="__main__":raise SystemExit(main())
