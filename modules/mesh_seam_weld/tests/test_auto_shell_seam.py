from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "python"))

from hmworkflow.core.mesh_model import Component, Element, MeshModel
from hmworkflow.mesh_seam_weld.auto_workflow import detect, plan_candidates
from hmworkflow.mesh_seam_weld.element_projection import project_point_to_element, project_point_to_triangle
from hmworkflow.mesh_seam_weld.local_split_planner import plan_local_split
from hmworkflow.mesh_seam_weld.quality_guard import element_metrics
from hmworkflow.mesh_seam_weld.report_writer import write_html
from hmworkflow.mesh_seam_weld.shell_topology import free_edge_paths
from hmworkflow.mesh_seam_weld.shell_weld_delta import write_plan_delta_files, write_shell_weld_delta
from hmworkflow.mesh_seam_weld.weld_strip_planner import plan_zipper
from hmworkflow.mesh_seam_weld.node_adjustment_planner import plan_adjustments


SETTINGS = {
    "search_distance": 0.5, "min_seam_length": 1.5, "min_path_nodes": 3,
    "parallel_angle_max": 15.0, "perpendicular_angle_min": 70.0,
    "max_distance_variation_ratio": 0.35, "existing_path_search_width": 1.0,
    "max_target_path_offset": 0.5, "allow_local_split": False,
    "allow_weld_end_tria": True, "max_weld_tria_ratio": 0.34,
    "quality_guard_enabled": True, "existing_weld_search_distance": 0.1,
    "execution_batch_size": 25,
}


def t_model(target_row_y=0.0):
    nodes = {
        1:(0,-1,0), 2:(1,-1,0), 3:(2,-1,0),
        4:(0,target_row_y,0), 5:(1,target_row_y,0), 6:(2,target_row_y,0),
        7:(0,1,0), 8:(1,1,0), 9:(2,1,0),
        11:(0,0,0.2), 12:(1,0,0.2), 13:(2,0,0.2),
        14:(0,0,1.2), 15:(1,0,1.2), 16:(2,0,1.2),
    }
    elements = {
        1:Element(1,10,"CQUAD4",(1,2,5,4)), 2:Element(2,10,"CQUAD4",(2,3,6,5)),
        3:Element(3,10,"CQUAD4",(4,5,8,7)), 4:Element(4,10,"CQUAD4",(5,6,9,8)),
        11:Element(11,20,"CQUAD4",(11,12,15,14)), 12:Element(12,20,"CQUAD4",(12,13,16,15)),
    }
    return MeshModel({10:Component(10,"PLATE_T8","SHELL"),20:Component(20,"WEB_T6","SHELL")},nodes,elements)


class AutomaticShellSeamTests(unittest.TestCase):
    def test_fast_tcl_path_has_explicit_mode_and_no_legacy_realization(self):
        loader=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        self.assertIn("FAST_AUTO",loader); self.assertIn("LEGACY_MANUAL",loader); self.assertIn("runAutoWorkflow",loader)
        fast="\n".join((ROOT/"modules"/"mesh_seam_weld"/"tcl"/name).read_text(encoding="utf-8") for name in ("auto_workflow.tcl","fast_executor.tcl","delta_import.tcl"))
        for forbidden in ("*imprint_nodelist","*linearsurfacebetweenlines","*surfacemarksplitwithlines"):
            self.assertNotIn(forbidden,fast)
        self.assertIn("state checkpoints",fast)
        self.assertIn("applyAutoPlanMoves",fast)
        self.assertIn("autoNativeQualityFailures",fast)
        self.assertIn("restoreAutoSnapshot $checkpoint",fast)

    def test_integrity_review_links_to_auto_creator(self):
        core=(ROOT/"modules"/"weld_integrity_check"/"tcl"/"core.tcl").read_text(encoding="utf-8")
        review=(ROOT/"modules"/"weld_integrity_check"/"tcl"/"review.tcl").read_text(encoding="utf-8")
        self.assertIn("::MeshSeamWeld::openAutoCandidate",core); self.assertIn("创建焊缝",review)

    def test_triangle_and_quad_projection(self):
        result = project_point_to_triangle((0.2,0.2,1),(0,0,0),(1,0,0),(0,1,0))
        self.assertEqual("FACE", result["location"]); self.assertAlmostEqual(1.0,result["distance"])
        quad = project_point_to_element((0.8,0.8,0.5),(1,2,3,4),{1:(0,0,0),2:(1,0,0),3:(1,1,0),4:(0,1,0)})
        self.assertAlmostEqual(0.5,quad["distance"])

    def test_topology_extracts_open_and_closed_paths(self):
        paths = free_edge_paths(t_model())
        self.assertTrue(paths[10]); self.assertTrue(all(path.closed for path in paths[10]))

    def test_t_path_detects_and_plans_existing_edge(self):
        model=t_model(); candidates=detect(model,SETTINGS)
        candidate=next(row for row in candidates if row["joint_type"] == "T_PATH")
        result=plan_candidates(model,candidates,SETTINGS,{candidate["candidate_id"]:{"decision":"ACCEPT"}})
        plan=next(row for row in result["plans"] if row["candidate_id"]==candidate["candidate_id"])
        self.assertEqual("EXISTING_EDGE_PATH",plan["mode"]); self.assertEqual("READY",plan["status"])
        self.assertTrue(all(row["element_type"]=="CQUAD4" for row in plan["weld_elements"]))

    def test_planning_requires_explicit_acceptance(self):
        model=t_model(); candidates=detect(model,SETTINGS)
        result=plan_candidates(model,candidates,SETTINGS)
        self.assertTrue(all(row["status"]=="PENDING_REVIEW" for row in result["plans"]))

    def test_adjusted_edge_path_moves_target_nodes_with_quality_guard(self):
        model=t_model(0.2); settings=dict(SETTINGS,allow_target_node_move=True,max_target_path_offset=0.25,max_node_move=0.3,max_node_move_ratio=0.5)
        candidates=detect(model,settings); candidate=next(row for row in candidates if row["joint_type"]=="T_PATH")
        result=plan_candidates(model,candidates,settings,{candidate["candidate_id"]:{"decision":"ACCEPT"}})
        plan=next(row for row in result["plans"] if row["candidate_id"]==candidate["candidate_id"])
        self.assertEqual("ADJUSTED_EDGE_PATH",plan["mode"])
        self.assertEqual("READY",plan["status"]); self.assertTrue(plan["move_nodes"])
        self.assertTrue(all(move["distance"] <= 0.3 for move in plan["move_nodes"]))

    def test_adjustment_respects_protected_nodes(self):
        model=t_model(0.2); settings=dict(SETTINGS,allow_target_node_move=True,max_target_path_offset=0.25,max_node_move=0.3,max_node_move_ratio=0.5,protected_node_ids=[5])
        candidate=next(row for row in detect(model,settings) if row["joint_type"]=="T_PATH")
        plan=next(row for row in plan_candidates(model,[candidate],settings,{candidate["candidate_id"]:{"decision":"ACCEPT"}})["plans"])
        self.assertEqual("MANUAL_REVIEW",plan["status"])

    def test_adjustment_hard_limit_rejects_excess_move(self):
        model=t_model(); result=plan_adjustments([4],[(0,1,0)],model.nodes,1.0,{"allow_target_node_move":True,"max_node_move":0.2,"max_node_move_ratio":1.0},model=model)
        self.assertIsNone(result)

    def test_zipper_supports_unequal_open_paths(self):
        nodes={1:(0,0,0),2:(1,0,0),3:(2,0,0),11:(0,1,0),12:(0.5,1,0),13:(1,1,0),14:(2,1,0)}
        elements=plan_zipper([1,2,3],[11,12,13,14],nodes,max_tria_ratio=0.5)
        self.assertTrue(any(row["element_type"]=="CTRIA3" for row in elements))

    def test_delta_ids_are_stable_and_component_is_named(self):
        request={"id_state":{"max_node_id":20,"max_element_id":30,"max_property_id":2,"max_material_id":1,"max_component_id":5},"entity_registry":{"components":{}}}
        plan={"candidate_id":"W000001","status":"READY","output_component_name":"SEAM_T8","weld_elements":[{"element_type":"CQUAD4","node_ids":[1,2,3,4]}]}
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/"delta.fem"; manifest=write_shell_weld_delta(path,[plan],request)
            self.assertEqual([31],manifest["created_weld_element_ids"]); self.assertIn('$HMNAME COMP 6 "SEAM_T8"',path.read_text(encoding="utf-8"))

    def test_candidate_delta_is_written_after_id_allocation(self):
        request={"id_state":{"max_node_id":20,"max_element_id":30,"max_property_id":2,"max_material_id":1,"max_component_id":5},"entity_registry":{"components":{}}}
        plan={"candidate_id":"W000001","status":"READY","output_component_name":"SEAM_T8","property_id":2,"weld_elements":[{"element_type":"CQUAD4","node_ids":[1,2,3,4]}]}
        with tempfile.TemporaryDirectory() as temp:
            write_shell_weld_delta(Path(temp)/"delta.fem",[plan],request)
            written=write_plan_delta_files(Path(temp)/"deltas",[plan])
            candidate_delta=Path(written["W000001"])
            self.assertTrue(candidate_delta.is_file())
            self.assertIn("CQUAD4,31,2,1,2,3,4",candidate_delta.read_text(encoding="utf-8"))
            self.assertEqual(str(candidate_delta.resolve()),plan["delta_fem"])

    def _split_model(self, element_type):
        nodes={1:(0,0,0),2:(2,0,0),3:(2,1,0),4:(0,1,0),11:(0,0.5,0.2),12:(1,0.5,0.2),13:(2,0.5,0.2)}
        connectivity=(1,2,3,4)
        if element_type == "CTRIA3":
            nodes.update({3:(0,2,0),11:(0,1,0.2),12:(0.5,0.75,0.2),13:(1,1,0.2)})
            connectivity=(1,2,3)
        model=MeshModel({10:Component(10,"TARGET_T2","SHELL")},nodes,{1:Element(1,10,element_type,connectivity)})
        model.element_properties={1:7}
        return model

    def test_local_split_templates_preserve_area_component_and_property(self):
        for element_type in ("CTRIA3","CQUAD4"):
            model=self._split_model(element_type)
            split=plan_local_split(model=model,candidate={"target_hint_element_ids":[1]},source_node_ids=[11,12,13],settings={"allow_local_split":True,"search_distance":1.0,"max_split_aspect_ratio":50.0})
            self.assertEqual("READY",split["status"])
            self.assertEqual([1],split["delete_element_ids"])
            self.assertTrue(all(row["property_id"]==7 and row["component_id"]==10 for row in split["replacement_elements"]))
            original=element_metrics(model.elements[1].node_ids,model.nodes)["area"]
            replacement=sum(element_metrics(row["node_ids"],split["coordinates"])["area"] for row in split["replacement_elements"])
            self.assertAlmostEqual(original,replacement)

    def test_local_split_delta_allocates_grids_and_replacement_shells(self):
        model=self._split_model("CQUAD4")
        split=plan_local_split(model=model,candidate={"target_hint_element_ids":[1]},source_node_ids=[11,12,13],settings={"allow_local_split":True,"search_distance":1.0,"max_split_aspect_ratio":50.0})
        plan={"candidate_id":"W000002","status":"READY","output_component_name":"SEAM_T2","property_id":9,"new_nodes":split["new_nodes"],"replacement_elements":split["replacement_elements"],"delete_element_ids":[1],"weld_elements":[{"element_type":"CQUAD4","node_ids":[11,12,-2,-1]},{"element_type":"CQUAD4","node_ids":[12,13,-3,-2]}]}
        request={"id_state":{"max_node_id":100,"max_element_id":200,"max_property_id":9,"max_material_id":1,"max_component_id":10},"entity_registry":{"components":{}}}
        with tempfile.TemporaryDirectory() as temp:
            manifest=write_shell_weld_delta(Path(temp)/"delta.fem",[plan],request)
            self.assertEqual([101,102,103],manifest["created_node_ids"])
            self.assertEqual(len(split["replacement_elements"]),len(manifest["created_mother_element_ids"]))
            self.assertTrue(all(min(row["node_ids"]) > 0 for row in plan["replacement_elements"]+plan["weld_elements"]))
            text=(Path(temp)/"delta.fem").read_text(encoding="utf-8")
            self.assertIn("$HMCOMP ID 10",text); self.assertIn("CTRIA3,",text); self.assertIn("CQUAD4,",text)

    def test_v3_tcl_deletes_only_after_reference_validation_and_checkpoints(self):
        fast=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"fast_executor.tcl").read_text(encoding="utf-8")
        self.assertLess(fast.index("validateAutoPlanReferences"),fast.index("deleteAutoPlanMotherElements"))
        self.assertLess(fast.index("saveAutoSnapshot $checkpoint"),fast.index("deleteAutoPlanMotherElements"))
        delta=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"delta_import.tcl").read_text(encoding="utf-8")
        self.assertIn("mother shell $elementId connectivity changed",delta)
        self.assertIn("candidate GRID IDs are already occupied",delta)

    def test_html_report_contains_auditable_mode_performance_and_warnings(self):
        report={"summary":{"ready_count":1},"performance":{"planning_seconds":0.25},"candidates":[{"candidate_id":"W000001","joint_type":"T_PATH","confidence":0.9,"duplicate_status":"NEW","realization_mode":"ADJUSTED_EDGE_PATH","plan_status":"READY","plan_warnings":["property_assignment_required"]}]}
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/"report.html"; write_html(path,report); content=path.read_text(encoding="utf-8")
            self.assertIn("ADJUSTED_EDGE_PATH",content); self.assertIn("planning_seconds",content); self.assertIn("property_assignment_required",content)

    def test_executor_emits_timing_cancellation_and_execution_audit(self):
        fast=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"fast_executor.tcl").read_text(encoding="utf-8")
        workflow=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"auto_workflow.tcl").read_text(encoding="utf-8")
        self.assertIn("cancel.flag",fast); self.assertIn("hm_quality_seconds",fast)
        self.assertIn("execution_report.json",workflow); self.assertIn("writeAutoExecutionReport",workflow)


if __name__ == "__main__": unittest.main()
