from __future__ import annotations
import argparse,importlib.util,sys,time,math
from pathlib import Path
MODULE_DIR=Path(__file__).resolve().parent; COMMON_DIR=MODULE_DIR.parents[1]/"hybrid_core"/"python"
for d in (str(MODULE_DIR),str(COMMON_DIR)):
    if d not in sys.path:sys.path.insert(0,d)
from free_edge_path import closed_loop
from hybrid_schema import new_result
from logging_utils import close_logger,create_logger
from mesh_model import load_json,read_mesh
from mesh_topology import adjacency,edges
from path_aligner import align_with_metadata
from path_matcher import match
from path_validator import validate_ordered
from result_validator import validate
from result_writer import write_result
from seam_planner import plan
SPEC=importlib.util.spec_from_file_location("seam_schema",str(MODULE_DIR/"schema.py")); MOD=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MOD)
def calculate(req,model):
    s=req["settings"]
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
        t=time.perf_counter(); req=MOD.validate_request(load_json(a.request)); model=read_mesh(a.mesh); read=time.perf_counter()-t; t=time.perf_counter(); candidate=calculate(req,model); detect=time.perf_counter()-t
        result=new_result("mesh_seam_weld",req["run_id"]); result["candidates"]=[candidate]; result["summary"]={"mode":candidate["mode"],"path_node_count":len(candidate.get("path_node_ids",candidate.get("target_node_ids",[])))}; result["performance"]["read_seconds"]=round(read,6); result["performance"]["detect_seconds"]=round(detect,6); write_result(a.output,getattr(a,"tcl_output"),"::MeshSeamWeld::pythonResult",result); return 0
    except Exception as exc:logger.exception("seam planning failed"); print("ERROR: {}".format(exc),file=sys.stderr); return 2
    finally:close_logger(logger)
if __name__=="__main__":raise SystemExit(main())
