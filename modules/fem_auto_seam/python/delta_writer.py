"""Write auditable incremental FEM for new weld and replacement shells."""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

COMMON_DIR = Path(__file__).resolve().parents[2] / "hybrid_core" / "python"
if str(COMMON_DIR) not in sys.path: sys.path.insert(0, str(COMMON_DIR))
from fem_delta import EntityIdAllocator, FemDeltaError  # noqa: E402


def _shell_line(element, default_pid=0):
    card=element["element_type"]; ids=[int(value) for value in element["node_ids"]]
    if card not in ("CTRIA3","CQUAD4") or len(ids) != (3 if card == "CTRIA3" else 4) or min(ids) <= 0:
        raise FemDeltaError("invalid planned shell")
    pid=int(element.get("property_id",default_pid)); pid_field=str(pid) if pid > 0 else ""
    return "{},{},{},{}".format(card,int(element["element_id"]),pid_field,",".join(str(value) for value in ids))


def _allocate_plan_entities(plan, allocator, manifest):
    node_map={}
    for node in plan.get("new_nodes",[]):
        temporary=int(node["node_id"])
        if temporary >= 0 or temporary in node_map: raise FemDeltaError("new node placeholders must be unique negative IDs")
        coordinates=[float(value) for value in node["coordinates"]]
        if len(coordinates) != 3 or not all(math.isfinite(value) for value in coordinates): raise FemDeltaError("invalid new GRID coordinates")
        actual=allocator.reserve("node"); node_map[temporary]=actual; node["node_id"]=actual
        manifest["created_node_ids"].append(actual)
    for collection in (plan.get("replacement_elements",[]),plan.get("weld_elements",[])):
        for element in collection: element["node_ids"]=[node_map.get(int(value),int(value)) for value in element["node_ids"]]
    for element in plan.get("replacement_elements",[]):
        element["element_id"]=allocator.reserve("element"); manifest["created_mother_element_ids"].append(element["element_id"])
    for element in plan.get("weld_elements",[]):
        element["element_id"]=allocator.reserve("element"); manifest["created_weld_element_ids"].append(element["element_id"])


def _plan_lines(plan, include_name=True):
    lines=[]
    for node in plan.get("new_nodes",[]):
        lines.append("GRID,{},,{:.12g},{:.12g},{:.12g}".format(int(node["node_id"]),*node["coordinates"]))
    replacements=plan.get("replacement_elements",[])
    if replacements:
        by_component={}
        for element in replacements:
            by_component.setdefault(int(element["component_id"]),[]).append(element)
        for target_component in sorted(by_component):
            lines.append("$HMCOMP ID {}".format(target_component))
            for element in by_component[target_component]:
                lines.append(_shell_line(element))
    if include_name: lines.append('$HMNAME COMP {} "{}"'.format(int(plan["output_component_id"]),str(plan["output_component_name"]).replace('"','')))
    lines.append("$HMCOMP ID {}".format(int(plan["output_component_id"])))
    for element in plan.get("weld_elements",[]): lines.append(_shell_line(element,int(plan.get("property_id",0))))
    return lines


def write_shell_weld_delta(path, plans, request):
    path=Path(path); state=request.get("id_state",{})
    for key in ("max_node_id","max_element_id","max_component_id"):
        if key not in state: raise FemDeltaError("request.id_state.{} is required".format(key))
    allocator=EntityIdAllocator(state); registry=request.get("entity_registry",{}).get("components",{})
    component_ids={}; lines=["$ HMWF_AUTO_SHELL_SEAM_DELTA_V2","BEGIN BULK"]
    manifest={"schema_version":"1.0","format":"hm_auto_shell_seam_delta","created_node_ids":[],"created_mother_element_ids":[],"created_weld_element_ids":[],"created_component_ids":[],"reused_component_ids":[],"property_assignment_required":False,"plans":[]}
    for plan in sorted(plans,key=lambda row:row["candidate_id"]):
        if plan.get("status") != "READY": continue
        name=plan["output_component_name"]
        if plan.get("ids_preallocated"):
            component_ids[name]=int(plan["output_component_id"])
            if component_ids[name] <= int(state["max_component_id"]):
                raise FemDeltaError("preallocated component ID is not above the live model maximum")
            if component_ids[name] not in manifest["created_component_ids"]:
                manifest["created_component_ids"].append(component_ids[name])
            created_nodes=[int(row["node_id"]) for row in plan.get("new_nodes",[])]
            created_mothers=[int(row["element_id"]) for row in plan.get("replacement_elements",[])]
            created_welds=[int(row["element_id"]) for row in plan.get("weld_elements",[])]
            if any(value <= int(state["max_node_id"]) for value in created_nodes):
                raise FemDeltaError("preallocated GRID ID is not above the live model maximum")
            if any(value <= int(state["max_element_id"]) for value in created_mothers+created_welds):
                raise FemDeltaError("preallocated element ID is not above the live model maximum")
            if len(set(created_nodes)) != len(created_nodes) or len(set(created_mothers+created_welds)) != len(created_mothers+created_welds):
                raise FemDeltaError("preallocated entity IDs are not unique")
            manifest["created_node_ids"].extend(created_nodes)
            manifest["created_mother_element_ids"].extend(created_mothers)
            manifest["created_weld_element_ids"].extend(created_welds)
        elif name not in component_ids:
            if name in registry:
                component_ids[name]=int(registry[name]); manifest["reused_component_ids"].append(component_ids[name])
            else:
                component_ids[name]=allocator.reserve("component"); manifest["created_component_ids"].append(component_ids[name])
        plan["output_component_id"]=component_ids[name]
        if not plan.get("ids_preallocated"):
            _allocate_plan_entities(plan,allocator,manifest)
        if int(plan.get("property_id",0)) <= 0 and plan.get("weld_elements"): manifest["property_assignment_required"]=True
        lines.extend(_plan_lines(plan,include_name=True))
        manifest["plans"].append({"candidate_id":plan["candidate_id"],"component_id":component_ids[name],"property_id":int(plan.get("property_id",0)),"created_node_ids":[row["node_id"] for row in plan.get("new_nodes",[])],"deleted_mother_element_ids":list(plan.get("delete_element_ids",[])),"created_mother_element_ids":[row["element_id"] for row in plan.get("replacement_elements",[])],"created_weld_element_ids":[row["element_id"] for row in plan.get("weld_elements",[])],"expected_mother_connectivity":[row["node_ids"] for row in plan.get("replacement_elements",[])],"expected_weld_connectivity":[row["node_ids"] for row in plan.get("weld_elements",[])]})
    lines.extend(("ENDDATA","")); path.parent.mkdir(parents=True,exist_ok=True); path.write_text("\n".join(lines),encoding="utf-8")
    return manifest


def write_manifest(path, manifest):
    Path(path).write_text(json.dumps(manifest,ensure_ascii=False,sort_keys=True,indent=2)+"\n",encoding="utf-8")


def write_plan_delta_files(directory, plans):
    directory=Path(directory); directory.mkdir(parents=True,exist_ok=True); written={}
    for plan in sorted(plans,key=lambda row:row["candidate_id"]):
        if plan.get("status") != "READY": continue
        lines=["$ HMWF_AUTO_SHELL_SEAM_CANDIDATE_DELTA_V2","BEGIN BULK"]+_plan_lines(plan,include_name=True)+["ENDDATA",""]
        path=directory/"{}.fem".format(plan["candidate_id"]); path.write_text("\n".join(lines),encoding="utf-8")
        plan["delta_fem"]=str(path.resolve()); written[plan["candidate_id"]]=plan["delta_fem"]
    return written
