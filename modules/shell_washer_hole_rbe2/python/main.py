from __future__ import annotations

import argparse, importlib.util, sys, time
from pathlib import Path

MODULE_DIR = Path(__file__).resolve().parent; COMMON_DIR = MODULE_DIR.parents[1] / "hybrid_core" / "python"
for directory in (str(MODULE_DIR), str(COMMON_DIR)):
    if directory not in sys.path: sys.path.insert(0, directory)

from free_edge_loops import find
from fem_delta import write_rigid_incremental_fem
from hybrid_schema import new_result
from logging_utils import close_logger, create_logger
from mesh_model import load_json, read_mesh
from rbe2_duplicate_detector import annotate, duplicate_groups, index
from result_validator import validate
from result_writer import write_result
from shell_topology import build
from washer_detector import validate_hole, validate_washer

SPEC = importlib.util.spec_from_file_location("washer_schema", str(MODULE_DIR / "schema.py")); MOD = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MOD)


def detect(request, model, existing, logger):
    candidates, rejected = [], []
    duplicate_index = index(existing)
    for component_id in request["selected_component_ids"]:
        elements = model.elements_for_components([component_id])
        incidence, neighbors, element_nodes = build(elements)
        for loop in find(incidence):
            geom, reason = validate_hole(model, loop, request["settings"])
            if geom is None: rejected.append({"component_id": component_id, "loop_node_ids": loop["nodes"], "reject_reasons": [reason]}); continue
            washer, reason = validate_washer(model, loop, geom, incidence, neighbors, element_nodes, request["settings"])
            if washer is None: rejected.append({"component_id": component_id, "loop_node_ids": loop["nodes"], "reject_reasons": [reason]}); continue
            candidate = {
                "candidate_id": "W{:04d}".format(len(candidates) + 1), "component_id": component_id,
                "source_component_id": component_id,
                "loop_node_ids": loop["nodes"], "loop_edge_keys": ["{}:{}".format(*sorted(edge)) for edge in loop["edges"]],
                "inner_loop_node_ids": loop["nodes"], "inner_loop_edge_keys": ["{}:{}".format(*sorted(edge)) for edge in loop["edges"]],
                "center": [round(v, 12) for v in geom["center"]], "diameter": round(2.0 * geom["mean_radius"], 12),
                "normal": [round(v,12) for v in geom["normal"]], "equivalent_diameter": round(2.0*geom["mean_radius"],12),
                "roundness": round(max(0.0,1.0-geom["radial_rel"]),12), "planarity_error": round(geom["planarity_error"],12),
                "shape": geom["shape"], "circularity": round(geom["radial_rel"], 12), "axis_ratio": round(geom["axis_ratio"], 12),
                "seed_element_ids": washer["seed_element_ids"], "washer_element_ids": washer["washer_element_ids"], "outer_node_ids": washer["outer_node_ids"],
                "dependent_node_ids": washer["dependent_node_ids"], "washer_layer_count": request["settings"]["INNER_WASHER_NODE_LOOPS"]-1,"washer_status":"VALID", "confidence": round(max(0.0, 1.0 - geom["radial_rel"]), 6),
                "warnings": [], "reject_reasons": [],
            }
            annotate(candidate, duplicate_index); candidates.append(candidate)
    validate(candidates, model); return candidates, rejected


def main(argv=None):
    p=argparse.ArgumentParser();
    for name in ("request","mesh","existing","delta","output","tcl-output","log"): p.add_argument("--"+name, required=True, type=Path)
    a=p.parse_args(argv); logger=create_logger("shell_washer_hole_rbe2", a.log)
    try:
        started=time.perf_counter(); request=MOD.validate_request(load_json(a.request)); model=read_mesh(a.mesh); existing=MOD.validate_existing(load_json(a.existing)); read_time=time.perf_counter()-started
        started=time.perf_counter(); candidates,rejected=detect(request,model,existing,logger); detect_time=time.perf_counter()-started
        started=time.perf_counter(); manifest=write_rigid_incremental_fem(a.delta,candidates,request); write_time=time.perf_counter()-started
        result=new_result("shell_washer_hole_rbe2",request["run_id"]); result["candidates"]=candidates; result["summary"]={"candidate_count":len(candidates),"rejected_count":len(rejected),"rejected":rejected,"duplicate_groups":duplicate_groups(existing),**manifest}; result["performance"]["read_seconds"]=round(read_time,6); result["performance"]["detect_seconds"]=round(detect_time,6); result["performance"]["write_seconds"]=round(write_time,6)
        write_result(a.output,getattr(a,"tcl_output"),"::RB2W::pythonResult",result); return 0
    except Exception as exc: logger.exception("washer detection failed"); print("ERROR: {}".format(exc),file=sys.stderr); return 2
    finally: close_logger(logger)


if __name__=="__main__": raise SystemExit(main())
