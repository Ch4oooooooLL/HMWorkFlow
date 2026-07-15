import unittest
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
from main import calculate
from mesh_model import Component,Element,MeshModel
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
if __name__=="__main__":unittest.main()
