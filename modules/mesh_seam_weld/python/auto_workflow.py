"""Detection/review/planning orchestration with no HyperMesh API access."""
from __future__ import annotations

import re
from collections import defaultdict

try:
    from .auto_detector import detect_candidates
    from .creation_plan import CreationPlan, execution_batches
    from .local_split_planner import plan_local_split
    from .node_adjustment_planner import plan_adjustments, projected_source_path, protected_target_nodes
    from .quality_guard import validate_strip_connectivity, validate_weld_elements
    from .target_path_solver import solve_existing_edge_path
    from .weld_strip_planner import plan_zipper
except ImportError:
    from auto_detector import detect_candidates
    from creation_plan import CreationPlan, execution_batches
    from local_split_planner import plan_local_split
    from node_adjustment_planner import plan_adjustments, projected_source_path, protected_target_nodes
    from quality_guard import validate_strip_connectivity, validate_weld_elements
    from target_path_solver import solve_existing_edge_path
    from weld_strip_planner import plan_zipper


def _ordered_path(edge_pairs):
    graph = defaultdict(set)
    for first, second in edge_pairs: graph[first].add(second); graph[second].add(first)
    if any(len(value) > 2 for value in graph.values()): return None, False
    endpoints = sorted(node for node, neighbors in graph.items() if len(neighbors) == 1); closed = not endpoints
    current, previous, ordered = endpoints[0] if endpoints else min(graph), None, []
    while current not in ordered:
        ordered.append(current); choices = sorted(node for node in graph[current] if node != previous)
        if not choices: break
        following = choices[0]
        if following == ordered[0]: break
        previous, current = current, following
    return ordered, closed


def _output_component(candidate, model, settings):
    override = candidate.get("output_component_name")
    if override: return override
    names = [model.components[candidate[key]].component_name for key in ("source_component_id", "target_component_id")]
    thicknesses = []
    for name in names:
        match = re.search(r"_T(\d+(?:\.\d+)?)", name, re.IGNORECASE)
        if match: thicknesses.append(float(match.group(1)))
    thickness = candidate.get("thickness") or (thicknesses[0] if thicknesses else None)
    if thickness is None:
        element_properties = getattr(model, "element_properties", {})
        pshell = getattr(model, "pshell", {})
        source_thicknesses = [pshell[element_properties[element_id]]["thickness"] for element_id in candidate.get("source_element_ids", []) if element_id in element_properties and element_properties[element_id] in pshell]
        if source_thicknesses: thickness = min(source_thicknesses)
    if thickness is None: thickness = settings.get("default_weld_thickness")
    if thickness is None: return "SEAM_UNASSIGNED"
    return "SEAM_T{:g}".format(float(thickness))


def detect(model, settings, existing_seams=None):
    return detect_candidates(model, settings, existing_seams)


def _local_split_plan(model, candidate, source, settings, split):
    if split.get("status") != "READY":
        return CreationPlan(candidate["candidate_id"], "LOCAL_SPLIT_PATH" if settings.get("allow_local_split") else "NONE", status=split["status"], warnings=split["warnings"])
    try:
        weld_elements=plan_zipper(source,split["target_node_ids"],split["coordinates"],False,bool(settings.get("allow_weld_end_tria",True)),float(settings.get("max_weld_tria_ratio",0.15)))
    except ValueError as exc:
        return CreationPlan(candidate["candidate_id"],"LOCAL_SPLIT_PATH",status="MANUAL_REVIEW",warnings=[str(exc)])
    all_new=list(split["replacement_elements"])+weld_elements
    quality=validate_weld_elements(all_new,split["coordinates"],float(settings.get("max_split_aspect_ratio",20.0)))
    strip_quality=validate_strip_connectivity(weld_elements,source,split["target_node_ids"])
    if not strip_quality["passed"]: quality["passed"]=False; quality["failed_elements"].extend(strip_quality["failed_elements"])
    if settings.get("quality_guard_enabled",True) and not quality["passed"]:
        return CreationPlan(candidate["candidate_id"],"LOCAL_SPLIT_PATH",status="MANUAL_REVIEW",warnings=[row["reason"] for row in quality["failed_elements"]])
    name=_output_component(candidate,model,settings); property_id=int(candidate.get("weld_property_id",0))
    warnings=[] if property_id else ["property_assignment_required: use batch property assignment after creation"]
    if name == "SEAM_UNASSIGNED": warnings.append("weld thickness is unresolved")
    deleted=list(split["delete_element_ids"])
    return CreationPlan(candidate["candidate_id"],"LOCAL_SPLIT_PATH",new_nodes=split["new_nodes"],replacement_elements=split["replacement_elements"],delete_element_ids=deleted,weld_elements=weld_elements,output_component_name=name,property_id=property_id,status="READY",warnings=warnings,read_nodes=sorted(set(source)),read_elements=sorted(set(candidate.get("source_element_ids",[])+split["read_elements"])),delete_elements=deleted,original_connectivity=split["original_connectivity"],max_new_failed_elements=int(settings.get("max_new_failed_elements",0)))


def plan_candidates(model, candidates, settings, review_state=None):
    review = review_state or {}; plans = []
    for candidate in sorted(candidates, key=lambda row: row["candidate_id"]):
        decision = review.get(candidate["candidate_id"], {}).get("decision", candidate.get("decision", "PENDING"))
        if decision not in ("ACCEPT", "ACCEPTED"):
            plans.append(CreationPlan(candidate["candidate_id"], "NONE", status="REJECTED" if decision == "REJECT" else "PENDING_REVIEW", warnings=["candidate requires explicit user acceptance"]))
            continue
        source, closed = _ordered_path(candidate["source_edge_pairs"])
        if not source or candidate["joint_type"] == "REVIEW":
            plans.append(CreationPlan(candidate["candidate_id"], "NONE", status="MANUAL_REVIEW", warnings=list(candidate.get("warnings", []))+["unsupported or ambiguous source path"])); continue
        target = solve_existing_edge_path(model, candidate["target_component_id"], source, settings, candidate.get("target_hint_node_ids"))
        if target is None:
            split = plan_local_split(model=model,candidate=candidate,source_node_ids=source,closed=closed,settings=settings)
            plans.append(_local_split_plan(model,candidate,source,settings,split)); continue
        adjustment = None
        planning_nodes = model.nodes
        realization_mode = "EXISTING_EDGE_PATH"
        if target.get("requires_adjustment"):
            if settings.get("allow_target_node_move", False):
                try:
                    desired = projected_source_path(source,target["node_ids"],candidate.get("target_hint_element_ids",[]),model)
                    lengths = [sum((model.nodes[target["node_ids"][index]][axis]-model.nodes[target["node_ids"][index+1]][axis])**2 for axis in range(3))**0.5 for index in range(len(target["node_ids"])-1)]
                    local_edge_length = sum(lengths)/len(lengths) if lengths else 0.0
                    protected = protected_target_nodes(target["node_ids"],model,settings.get("protected_node_ids",[]),settings.get("protected_feature_angle",45.0))
                    adjustment = plan_adjustments(target["node_ids"],desired,model.nodes,local_edge_length,settings,protected,model)
                except ValueError:
                    adjustment = None
            if adjustment is None:
                split = plan_local_split(model=model,candidate=candidate,source_node_ids=source,closed=closed,target_path=target,settings=settings)
                plans.append(_local_split_plan(model,candidate,source,settings,split)); continue
            planning_nodes = dict(model.nodes); planning_nodes.update(adjustment["coordinates"]); realization_mode = "ADJUSTED_EDGE_PATH"
        try:
            elements = plan_zipper(source, target["node_ids"], planning_nodes, closed, bool(settings.get("allow_weld_end_tria", True)), float(settings.get("max_weld_tria_ratio", 0.15)))
        except ValueError as exc:
            plans.append(CreationPlan(candidate["candidate_id"], "NONE", status="MANUAL_REVIEW", warnings=[str(exc)])); continue
        quality = validate_weld_elements(elements, planning_nodes)
        strip_quality = validate_strip_connectivity(elements,source,target["node_ids"])
        if not strip_quality["passed"]: quality["passed"]=False; quality["failed_elements"].extend(strip_quality["failed_elements"])
        if settings.get("quality_guard_enabled", True) and not quality["passed"]:
            plans.append(CreationPlan(candidate["candidate_id"], "NONE", status="MANUAL_REVIEW", warnings=[row["reason"] for row in quality["failed_elements"]])); continue
        name = _output_component(candidate, model, settings)
        property_id = int(candidate.get("weld_property_id", 0))
        warnings = [] if property_id else ["property_assignment_required: use batch property assignment after creation"]
        if name == "SEAM_UNASSIGNED": warnings.append("weld thickness is unresolved")
        affected = adjustment["affected_element_ids"] if adjustment else []
        moves = adjustment["moves"] if adjustment else []
        plan = CreationPlan(candidate["candidate_id"], realization_mode, move_nodes=moves, weld_elements=elements, output_component_name=name, property_id=property_id, status="READY", warnings=warnings, read_nodes=sorted(set(source+target["node_ids"])), write_nodes=sorted(move["node_id"] for move in moves), read_elements=sorted(set(candidate.get("source_element_ids", [])+candidate.get("target_hint_element_ids",[])+affected)), max_new_failed_elements=int(settings.get("max_new_failed_elements",0)))
        plans.append(plan)
    planned_batches = execution_batches([plan for plan in plans if plan.status == "READY"],int(settings.get("execution_batch_size",25)))
    for index,batch in enumerate(planned_batches,1):
        for plan in batch: plan.batch_id="B{:04d}".format(index)
    serialized = [plan.to_dict() for plan in plans]
    batches = [[plan.candidate_id for plan in batch] for batch in planned_batches]
    return {"schema_version": "1.0", "plans": serialized, "execution_batches": batches}
