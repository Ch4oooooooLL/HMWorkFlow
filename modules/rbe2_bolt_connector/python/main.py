from __future__ import annotations
import argparse,importlib.util,sys,time
from pathlib import Path
MODULE_DIR=Path(__file__).resolve().parent; COMMON_DIR=MODULE_DIR.parents[1]/"hybrid_core"/"python"
for d in (str(MODULE_DIR),str(COMMON_DIR)):
    if d not in sys.path:sys.path.insert(0,d)
from duplicate_detector import annotate
from grouping import build
from hybrid_schema import new_result
from logging_utils import close_logger,create_logger
from mesh_model import load_json,read_mesh
from pair_planner import plan
from rbe2_analyzer import analyze
from result_validator import validate
from result_writer import write_result
SPEC=importlib.util.spec_from_file_location("bolt_schema",str(MODULE_DIR/"schema.py")); MOD=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MOD)
def calculate(request,model,existing):
    records,rejected=analyze(model,request["settings"]); groups=build(records,request["settings"]); plans,group_rejected=plan(groups,request["settings"]); annotate(plans,existing); validate(plans,model)
    used={p["rbe2_a"]["element_id"] for p in plans}|{p["rbe2_b"]["element_id"] for p in plans}; unused=[r["element_id"] for r in records if r["planar"] and r["element_id"] not in used]
    return records,groups,plans,rejected+group_rejected,unused
def main(argv=None):
    p=argparse.ArgumentParser()
    for n in ("request","mesh","existing","output","tcl-output","log"):p.add_argument("--"+n,required=True,type=Path)
    a=p.parse_args(argv); logger=create_logger("rbe2_bolt_connector",a.log)
    try:
        t=time.perf_counter(); req=MOD.validate_request(load_json(a.request)); model=read_mesh(a.mesh); existing=MOD.validate_existing(load_json(a.existing)); read=time.perf_counter()-t
        t=time.perf_counter(); records,groups,plans,rejected,unused=calculate(req,model,existing); detect=time.perf_counter()-t
        result=new_result("rbe2_bolt_connector",req["run_id"]); result["candidates"]=plans; result["summary"]={"record_count":len(records),"group_count":len(groups),"pair_count":len(plans),"unused_shell_rbe2_ids":unused,"rejected":rejected}; result["performance"]["read_seconds"]=round(read,6); result["performance"]["detect_seconds"]=round(detect,6); write_result(a.output,getattr(a,"tcl_output"),"::RB2Bolt::pythonResult",result); return 0
    except Exception as exc:logger.exception("bolt planning failed"); print("ERROR: {}".format(exc),file=sys.stderr); return 2
    finally:close_logger(logger)
if __name__=="__main__":raise SystemExit(main())
