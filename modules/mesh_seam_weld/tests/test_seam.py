import tempfile,unittest
from pathlib import Path
try:
    import tkinter
except ImportError:
    tkinter=None
from free_edge_path import closed_loop
from mesh_topology import adjacency,edges
from path_aligner import align,cost
from path_matcher import match
from path_validator import validate_ordered
from seam_planner import plan
from component_planner import plan_component_welds
from main import calculate
from mesh_model import Component,Element,MeshModel
from hybrid_schema import new_result
from result_writer import write_binary_result
ROOT=Path(__file__).resolve().parents[3]

class SeamTests(unittest.TestCase):
    def coords(self):return {1:(0,0,0),2:(1,0,0),3:(2,0,0),4:(0,1,0),11:(0,0,1),12:(1,0,1),13:(2,0,1),14:(0,1,1)}
    def test_open_valid(self):self.assertEqual(validate_ordered([1,2,3],{1:{2},2:{1,3},3:{2}}),[1,2,3])
    def test_open_disconnected(self):
        with self.assertRaises(ValueError):validate_ordered([1,3],{1:{2},2:{1,3},3:{2}})
    def test_duplicate_path_node(self):
        with self.assertRaises(ValueError):validate_ordered([1,2,1],{1:{2},2:{1}})
    def test_closed_loop(self):self.assertEqual(closed_loop(1,{1:{2,4},2:{1,3},3:{2,4},4:{1,3}}),[1,2,3,4])
    def test_branched_loop_rejected(self):
        with self.assertRaises(ValueError):closed_loop(1,{1:{2,3,4}})
    def test_nearest_match(self):self.assertEqual(match([1,2,3],[13,11,12],self.coords()),[11,12,13])
    def test_not_enough_targets(self):
        with self.assertRaises(ValueError):match([1,2,3],[11,12],self.coords())
    def test_open_reverse_alignment(self):self.assertEqual(align([1,2,3],[13,12,11],self.coords()),[11,12,13])
    def test_closed_rotation_alignment(self):self.assertEqual(align([1,2,3,4],[13,14,11,12],self.coords(),True),[11,12,13,14])
    def test_open_plan_segments(self):self.assertEqual(len(plan([1,2,3],[11,12,13],False)),2)
    def test_closed_plan_segments(self):self.assertEqual(len(plan([1,2,3,4],[11,12,13,14],True)),4)
    def test_discontinuous_imprint_target_rejected(self):
        with self.assertRaises(ValueError):validate_ordered([11,13,12],{11:{12},12:{11,13},13:{12}},False)
    def test_target_calculation_accepts_continuous_closed_path(self):
        coords=self.coords(); model=MeshModel({1:Component(1,"T","SHELL")},coords,{1:Element(1,1,"CQUAD4",(11,12,13,14))})
        req={"selected_component_ids":[1],"settings":{"mode":"target","source_node_ids":[1,2,3,4],"candidate_node_ids":[11,12,13,14],"closed_loop":True}}
        self.assertEqual(calculate(req,model)["target_node_ids"],[11,12,13,14])
    def test_target_calculation_rejects_disconnected_candidates(self):
        coords=self.coords(); coords.update({15:(3,0,1),16:(3,1,1),17:(4,0,1),18:(4,1,1)})
        elems={1:Element(1,1,"CQUAD4",(11,12,15,16)),2:Element(2,1,"CQUAD4",(13,14,18,17))}
        model=MeshModel({1:Component(1,"T","SHELL")},coords,elems)
        req={"selected_component_ids":[1],"settings":{"mode":"target","source_node_ids":[1,2,3],"candidate_node_ids":[11,12,13],"closed_loop":False}}
        with self.assertRaises(ValueError):calculate(req,model)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_target_continuity_uses_target_component_edges(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::adjacentElementsForNodes ::MeshSeamWeld::adjacentElementsForNodes_real")
        interp.eval("rename ::MeshSeamWeld::elemComponentId ::MeshSeamWeld::elemComponentId_real")
        interp.eval("rename ::MeshSeamWeld::elemNodes ::MeshSeamWeld::elemNodes_real")
        interp.eval("proc ::MeshSeamWeld::adjacentElementsForNodes {nodes} {return {101}}")
        interp.eval("proc ::MeshSeamWeld::elemComponentId {id} {return 9}")
        interp.eval("proc ::MeshSeamWeld::elemNodes {id} {return {1 2 3 4}}")
        self.assertEqual(interp.eval("::MeshSeamWeld::targetPathIsContinuous {1 2 3 4} {9} 1"),"1")
        interp.eval("rename ::MeshSeamWeld::adjacentElementsForNodes {}")
        interp.eval("rename ::MeshSeamWeld::elemNodes {}")
        interp.eval("proc ::MeshSeamWeld::adjacentElementsForNodes {nodes} {return {101 102}}")
        interp.eval("proc ::MeshSeamWeld::elemNodes {id} {if {$id == 101} {return {1 2 5 6}}; return {3 4 7 8}}")
        self.assertEqual(interp.eval("::MeshSeamWeld::targetPathIsContinuous {1 2 3} {9} 0"),"0")
    def test_default_workflow_uses_tcl_fast_path(self):
        workflow=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"workflow.tcl").read_text(encoding="utf-8")
        body=workflow.split("proc ::MeshSeamWeld::processWeldPath",1)[1]
        self.assertIn("processWeldPathTcl",body)
        self.assertNotIn("processWeldPathPython",body)
    def test_component_workflow_uses_one_binary_python_plan(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        self.assertIn("pickNodes",run_action)
        self.assertIn("runPythonComponentPlan",run_action)
        self.assertNotIn("sourcePathsForSingleNode",run_action)
        self.assertNotIn("closedFreeEdgeLoopsFromSeeds",run_action)
        self.assertIn("processWeldPathIsolated",run_action)
    def test_component_exporter_writes_combined_binary_mesh(self):
        exporter=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"exporter.tcl").read_text(encoding="utf-8")
        self.assertIn("writeComponentPlanMesh",exporter)
        self.assertIn("writeBinaryMesh",exporter)
        self.assertIn("sourceComponentIds",exporter)
        self.assertIn("targetComponentIds",exporter)
        self.assertNotIn("mesh.json",exporter)
    def test_component_bridge_loads_binary_result(self):
        bridge=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"bridge.tcl").read_text(encoding="utf-8")
        self.assertIn("runPythonComponentPlan",bridge)
        self.assertIn("result.hmwfr",bridge)
        self.assertIn("loadBinaryResult",bridge)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_nested_component_plan_round_trips_through_tcl_binary_decoder(self):
        payload=new_result("mesh_seam_weld","run-1")
        payload["candidates"]=[{"candidate_id":"B0001","mode":"component_plan","weld_plans":[{
            "source_node_ids":[1,2,3,4],"source_component_ids":[1],
            "target_component_ids":[2],"target_element_ids":[201],"closed_loop":True,
        }]}]
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"result.hmwfr"; write_binary_result(path,payload)
            interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
            interp.eval("source {{{}}}".format(module.as_posix()))
            interp.eval("set p [::HybridCore::readBinaryResultFile {{{}}}]".format(path.as_posix()))
            interp.eval("set c [lindex [dict get $p candidates] 0]; set w [lindex [dict get $c weld_plans] 0]")
            self.assertEqual(interp.eval("dict get $w target_component_ids"),"2")
    def test_component_planner_single_boundary_seed_limits_result_to_its_loop(self):
        components={1:Component(1,"SOURCE","SHELL"),2:Component(2,"TARGET","SHELL")}
        nodes={
            1:(0,0,1),2:(1,0,1),3:(1,1,1),4:(0,1,1),
            5:(10,0,1),6:(11,0,1),7:(11,1,1),8:(10,1,1),
            11:(0,0,0),12:(11,0,0),13:(11,1,0),14:(0,1,0),
        }
        elements={101:Element(101,1,"CQUAD4",(1,2,3,4)),102:Element(102,1,"CQUAD4",(5,6,7,8)),201:Element(201,2,"CQUAD4",(11,12,13,14))}
        plans=plan_component_welds(MeshModel(components,nodes,elements),[1],[2],8.0,2,[6])
        self.assertEqual(len(plans),1)
        self.assertEqual(set(plans[0]["source_node_ids"]),{5,6,7,8})
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_local_imprint_uses_element_target(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::markElements ::MeshSeamWeld::markElements_real")
        interp.eval("rename ::MeshSeamWeld::markComponents ::MeshSeamWeld::markComponents_real")
        interp.eval("proc ::MeshSeamWeld::markElements {ids mark} {return $ids}")
        interp.eval("proc ::MeshSeamWeld::markComponents {ids mark} {return 1}")
        interp.eval("proc *clearlist {args} {}; proc *createlist {args} {}")
        interp.eval("proc *imprint_nodelist {listId entityType markId options} {set ::imprintEntityType $entityType}")
        interp.eval("::MeshSeamWeld::runImprintNodeList {1 2 3} {9} 1 {101 102}")
        self.assertEqual(interp.eval("set ::imprintEntityType"),"elements")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_local_patch_index_finds_nearest_target(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        for name in ("componentElementIds","elemNodes","nodeXYZ"):
            interp.eval("rename ::MeshSeamWeld::{0} ::MeshSeamWeld::{0}_real".format(name))
        interp.eval("proc ::MeshSeamWeld::componentElementIds {comp} {return {101 102}}")
        interp.eval("proc ::MeshSeamWeld::elemNodes {id} {if {$id == 101} {return {11 12 15 14}}; return {12 13 16 15}}")
        interp.eval("array set ::xyz {1 {0.2 0.2 8} 11 {0 0 0} 12 {5 0 0} 13 {10 0 0} 14 {0 5 0} 15 {5 5 0} 16 {10 5 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}")
        interp.eval("::MeshSeamWeld::buildTargetElementIndex {9}")
        self.assertEqual(interp.eval("::MeshSeamWeld::nearestIndexedTargetElem {0.2 0.2 8}"),"101")
        self.assertIn("101",interp.eval("::MeshSeamWeld::localTargetPatchForPath {1}").split())
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_latest_id_survives_undo_zero(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("proc hm_latestentityid {type} {return 0}")
        interp.eval("set ::MeshSeamWeld::lastKnownNodeId 178222")
        self.assertEqual(interp.eval("::MeshSeamWeld::safeLatestEntityId nodes"),"178222")
        with self.assertRaises(tkinter.TclError):
            interp.eval("::MeshSeamWeld::entityIdsCreatedAfter nodes 0")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_failed_local_patch_invalidates_only_local_elements(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::componentElementIds ::MeshSeamWeld::componentElementIds_real")
        interp.eval("rename ::MeshSeamWeld::elemNodes ::MeshSeamWeld::elemNodes_real")
        interp.eval('proc ::MeshSeamWeld::componentElementIds {comp} {error "full component scan"}')
        interp.eval("proc ::MeshSeamWeld::elemNodes {id} {return {11 12 13 14}}")
        interp.eval("::MeshSeamWeld::invalidateTargetCaches {9} 100 200 {101 102}")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_closest_target_query_does_not_need_latest_id(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::markElementsByComponents ::MeshSeamWeld::markElementsByComponents_real")
        interp.eval("rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real")
        interp.eval("proc ::MeshSeamWeld::markElementsByComponents {comps mark} {return {101 102}}")
        interp.eval("array set ::xyz {1 {0 0 1} 2 {1 0 1} 11 {0 0 0} 12 {1 0 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}")
        interp.eval("proc *clearmark {args} {}; proc *createmark {args} {}")
        interp.eval("proc hm_getclosestnode {x y z elemMark nodeMark} {if {$x < 0.5} {return 11}; return 12}")
        interp.eval("proc hm_latestentityid {type} {error {latest ID must not be used}}")
        self.assertEqual(interp.eval("::MeshSeamWeld::targetNodesFromClosestQuery {1 2} {9}"),"11 12")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_collection_difference_accepts_reused_lower_ids(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        self.assertEqual(interp.eval("::MeshSeamWeld::idsAddedToCollection {160000 160800} {108800 160000 160800}"),"108800")
    def test_fast_executor_has_no_latest_id_dependency(self):
        executor=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"executor.tcl").read_text(encoding="utf-8")
        self.assertNotIn("safeLatestEntityId",executor)
        self.assertNotIn("hm_latestentityid",executor)
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        ruled=module.split("proc ::MeshSeamWeld::createRuledMeshBetweenNodePaths",1)[1].split("proc ::MeshSeamWeld::pathCenter",1)[0]
        self.assertNotIn("hm_latestentityid",ruled)
        self.assertNotIn("entityIdsCreatedAfter",ruled)
    def test_degenerate_element_rejected(self):
        with self.assertRaises(ValueError):plan([1,2],[1,12],False)
    def test_free_edges_from_shell(self):
        m=MeshModel({1:Component(1,"S","SHELL")},self.coords(),{1:Element(1,1,"CQUAD4",(1,2,3,4))}); self.assertEqual(len([k for k,v in edges(m.elements.values()).items() if len(v)==1]),4)

    def test_component_planner_returns_binary_execution_plan(self):
        components={1:Component(1,"SOURCE","SHELL"),2:Component(2,"TARGET","SHELL")}
        nodes={
            1:(0,0,1),2:(1,0,1),3:(1,1,1),4:(0,1,1),
            11:(0,0,0),12:(1,0,0),13:(1,1,0),14:(0,1,0),
        }
        elements={
            101:Element(101,1,"CQUAD4",(1,2,3,4)),
            201:Element(201,2,"CQUAD4",(11,12,13,14)),
        }
        plans=plan_component_welds(MeshModel(components,nodes,elements),[1],[2],8.0,2)
        self.assertEqual(len(plans),1)
        self.assertEqual(plans[0]["source_node_ids"],[1,2,3,4])
        self.assertEqual(plans[0]["source_component_ids"],[1])
        self.assertEqual(plans[0]["target_component_ids"],[2])
        self.assertEqual(plans[0]["target_element_ids"],[201])
        self.assertTrue(plans[0]["closed_loop"])
        self.assertEqual(plans[0]["projection_mode"],"LOCAL_ELEMENTS")

    def test_component_planner_assigns_each_loop_to_nearest_target_component(self):
        components={
            1:Component(1,"SOURCE_A","SHELL"),2:Component(2,"SOURCE_B","SHELL"),
            10:Component(10,"TARGET_A","SHELL"),20:Component(20,"TARGET_B","SHELL"),
        }
        nodes={
            1:(0,0,1),2:(1,0,1),3:(1,1,1),4:(0,1,1),
            5:(100,0,1),6:(101,0,1),7:(101,1,1),8:(100,1,1),
            11:(0,0,0),12:(1,0,0),13:(1,1,0),14:(0,1,0),
            21:(100,0,0),22:(101,0,0),23:(101,1,0),24:(100,1,0),
        }
        elements={
            101:Element(101,1,"CQUAD4",(1,2,3,4)),102:Element(102,2,"CQUAD4",(5,6,7,8)),
            201:Element(201,10,"CQUAD4",(11,12,13,14)),202:Element(202,20,"CQUAD4",(21,22,23,24)),
        }
        plans=plan_component_welds(MeshModel(components,nodes,elements),[1,2],[10,20],8.0,0)
        self.assertEqual([p["target_component_ids"] for p in plans],[[10],[20]])

    def test_component_mode_calculate_returns_all_plans_in_one_result(self):
        components={1:Component(1,"SOURCE","SHELL"),2:Component(2,"TARGET","SHELL")}
        nodes={1:(0,0,1),2:(1,0,1),3:(1,1,1),4:(0,1,1),11:(0,0,0),12:(1,0,0),13:(1,1,0),14:(0,1,0)}
        elements={101:Element(101,1,"CQUAD4",(1,2,3,4)),201:Element(201,2,"CQUAD4",(11,12,13,14))}
        req={"selected_component_ids":[1],"settings":{"mode":"component_plan","source_component_ids":[1],"target_component_ids":[2],"weld_mesh_size":8.0,"patch_expand_layers":2}}
        result=calculate(req,MeshModel(components,nodes,elements))
        self.assertEqual(result["mode"],"component_plan")
        self.assertEqual(len(result["weld_plans"]),1)
        self.assertEqual(result["weld_plans"][0]["target_component_ids"],[2])
if __name__=="__main__":unittest.main()
