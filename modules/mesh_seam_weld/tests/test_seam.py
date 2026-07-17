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
from component_planner import plan_component_welds,plan_internal_component_boundaries
from fem_mesh_reader import read_shell_fem
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
    def test_all_free_edge_seed_counts_use_tcl_without_python_fallback(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        self.assertIn("pickNodes",run_action)
        self.assertIn("closedFreeEdgeLoopsFromSeedsLocal",run_action)
        self.assertIn("planning_mode=tcl_boundary",run_action)
        self.assertNotIn("runPythonComponentPlan",run_action)
        self.assertNotIn("sourcePathsForSingleNode",run_action)
        self.assertIn("processWeldPathIsolated",run_action)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_local_boundary_trace_accepts_one_seed_and_deduplicates_same_loop(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::primeSelectedNodeElements {}")
        interp.eval("rename ::MeshSeamWeld::freeEdgeNeighbors {}")
        interp.eval("proc ::MeshSeamWeld::primeSelectedNodeElements {nodes} {return {}}")
        interp.eval("proc ::MeshSeamWeld::freeEdgeNeighbors {node} {dict get {1 {2 4} 2 {1 3} 3 {2 4} 4 {1 3}} $node}")
        self.assertEqual(
            {int(value) for value in interp.eval("lindex [::MeshSeamWeld::closedFreeEdgeLoopsFromSeedsLocal {1}] 0").split()},
            {1,2,3,4},
        )
        self.assertEqual(interp.eval("llength [::MeshSeamWeld::closedFreeEdgeLoopsFromSeedsLocal {1 3}]"),"1")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_free_edge_trace_ignores_non_shell_element_connectivity(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::nodeElementIds {}")
        interp.eval("rename ::MeshSeamWeld::elemNodes {}")
        interp.eval("proc ::MeshSeamWeld::nodeElementIds {node} {return {10 20}}")
        interp.eval("proc ::MeshSeamWeld::elemNodes {elem} {if {$elem == 10} {return {1 2 3 4}}; return {1 2 5 6 7 8 9 10}}")
        interp.eval("catch {unset ::MeshSeamWeld::nodeFreeEdgeNeighborsCache(1)}")
        self.assertEqual({int(value) for value in interp.eval("::MeshSeamWeld::freeEdgeNeighbors 1").split()},{2,4})
    def test_tcl_boundary_fast_path_is_local_and_deduplicates_loops(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        local=module.split("proc ::MeshSeamWeld::closedFreeEdgeLoopsFromSeedsLocal",1)[1].split("proc ::MeshSeamWeld::componentIdsFromNodes",1)[0]
        self.assertIn("closedFreeEdgeLoopFromNode",local)
        self.assertIn("seenLoops",local)
        self.assertNotIn("primeFreeEdgeComponent",local)
        self.assertNotIn("componentFreeEdgeGraph",local)
    def test_internal_single_node_alone_uses_native_fem_plan(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        exporter=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"exporter.tcl").read_text(encoding="utf-8")
        bridge=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"bridge.tcl").read_text(encoding="utf-8")
        self.assertIn("internalSingleNode",run_action)
        self.assertIn("runPythonInternalComponentPlan",run_action)
        self.assertNotIn("runPythonComponentPlan",run_action)
        self.assertIn("*feoutput_select",exporter)
        self.assertIn("source_component.fem",exporter)
        self.assertIn("runPythonInternalComponentPlan",bridge)
        self.assertIn("prepareDeferredWeldJobs",run_action)
    def test_internal_jobs_prepare_all_local_patches_once_and_refresh_only_on_failure(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        deferred=module.split("proc ::MeshSeamWeld::prepareDeferredWeldJobs",1)[1].split("proc ::MeshSeamWeld::createRuledMeshBetweenNodePaths",1)[0]
        self.assertIn("buildTargetElementIndex $targetComps",deferred)
        self.assertIn("localTargetPatchForPath $sourceNodes",deferred)
        self.assertNotIn("pathCenter $sourceNodes",deferred)
        self.assertNotIn("refresh_target_patch 1",module)
        execution=run_action.split("foreach job $weldJobs",1)[1]
        process=execution.index("processWeldPathIsolated")
        refresh=execution.index("buildTargetElementIndex")
        self.assertGreater(refresh,process)
        self.assertIn("retry_patch_extra_layers",execution)
        self.assertIn("component_fallback 1",module)
        self.assertIn("final component-scope retry",execution)
    def test_target_index_bulk_loads_coordinates_and_cooperatively_reports_progress(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body=module.split("proc ::MeshSeamWeld::buildTargetElementIndex",1)[1].split("proc ::MeshSeamWeld::nearestIndexedTargetElem",1)[0]
        self.assertIn("readShellElementConnectivityBulk",body)
        self.assertIn("readNodeCoordinatesBulk",body)
        self.assertIn("cooperativeYield",body)
        self.assertIn("Building target element index",body)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_shell_connectivity_reader_accepts_bulk_mark_result(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::markElements ::MeshSeamWeld::markElements_real")
        interp.eval("proc ::MeshSeamWeld::markElements {ids mark} {return {10 20}}")
        interp.eval("proc hm_getvalue {args} {return [list {1 2 3 4} {5 6 7}]} ")
        interp.eval("set c [::MeshSeamWeld::readShellElementConnectivityBulk {10 20}]")
        self.assertEqual(interp.eval("dict get $c 10"),"1 2 3 4")
        self.assertEqual(interp.eval("dict get $c 20"),"5 6 7")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_failure_diagnosis_returns_stage_reason_and_action(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        result=interp.eval("::MeshSeamWeld::diagnoseFailure {[MSW_STAGE:TARGET_CONTINUITY] target path is disconnected}")
        self.assertEqual(interp.eval("dict get {{{}}} stage".format(result)),"TARGET_CONTINUITY")
        self.assertIn("continuous",interp.eval("dict get {{{}}} reason_en".format(result)))
        self.assertTrue(interp.eval("dict get {{{}}} action_zh".format(result)).strip())
    def test_executor_tags_each_user_relevant_failure_stage(self):
        executor=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"executor.tcl").read_text(encoding="utf-8")
        for stage in ("IMPRINT","TARGET_MATCH","TARGET_CONTINUITY","AUTOMESH"):
            self.assertIn("stageError {}".format(stage),executor)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_plain_text_failure_report_contains_feedback_context(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        with tempfile.TemporaryDirectory() as directory:
            task=Path(directory).as_posix()
            script="""
set context [dict create source_mode internal path_total 3 success_count 2 target_components {7} weld_mesh_size 8]
set failure [dict create path_index 2 source_nodes {11 12 13 14} center {1.0 2.0 3.0} target_components {7} target_elements {101 102} retry_count 1 rollback_ok 1 first_error {[MSW_STAGE:IMPRINT] open failed} final_error {[MSW_STAGE:TARGET_MATCH] partial projection}]
::MeshSeamWeld::writeFailureReport {%s} $context [list $failure]
""" % task
            report=Path(interp.eval(script))
            text=report.read_text(encoding="utf-8")
            self.assertIn("MESH_SEAM_WELD_FAILURE_REPORT",text)
            self.assertIn("path_index=2",text)
            self.assertIn("stage=TARGET_MATCH",text)
            self.assertIn("source_node_count=4",text)
            self.assertIn("raw_error=",text)
    def test_auto_closed_plan_uses_manual_open_imprint_fast_path(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        executor=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"executor.tcl").read_text(encoding="utf-8")
        workflow=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"workflow.tcl").read_text(encoding="utf-8")
        self.assertIn("dict set job closed_loop 1",run_action)
        self.assertIn("imprint_closed_loop 0",run_action)
        self.assertIn("imprintClosedLoop",workflow)
        self.assertIn("imprintClosedLoop",executor)
        tcl_executor=executor.split("proc ::MeshSeamWeld::processWeldPathTcl",1)[1]
        imprint_call=tcl_executor.split("runImprintNodeList",1)[1].split("\n",1)[0]
        self.assertIn("$imprintClosedLoop",imprint_call)
        mesh_call=tcl_executor.split("createRuledMeshBetweenNodePaths",1)[1].split("if {[llength",1)[0]
        self.assertIn("$closedLoop",mesh_call)
        self.assertIn("execution_ms=$executionMs",run_action)
        self.assertIn("Tcl/HyperMesh 执行耗时",run_action)
    def test_imprint_matching_has_no_component_wide_node_fallback(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body=module.split("proc ::MeshSeamWeld::targetCandidatesAfterImprint",1)[1].split("proc ::MeshSeamWeld::matchTargetPathNodes",1)[0]
        self.assertNotIn("componentNodeIds",body)
        self.assertNotIn("fallback=target_components",body)
        self.assertIn("without component-wide fallback",body)
        self.assertIn("error [::HWFlow::txt",body)
    def test_failed_open_imprint_retries_same_local_patch_as_closed(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        retry=run_action.split("set retryTargetElems $jobTargetElems",1)[1].split("if {![dict get $isolated ok]}",1)[0]
        self.assertIn("$jobClosedLoop",run_action)
        self.assertIn("retry_patch_extra_layers",retry)
        self.assertIn("$jobTargetElems 1",retry)
        self.assertIn("final component-scope retry",retry)
        self.assertIn("createFailureMarkerNodes $failureRecords",run_action)
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
            "target_component_ids":[2],"target_element_ids":[201],"center":[0.5,0.5,1.0],"closed_loop":True,
        }]}]
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"result.hmwfr"; write_binary_result(path,payload)
            interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
            interp.eval("source {{{}}}".format(module.as_posix()))
            interp.eval("set p [::HybridCore::readBinaryResultFile {{{}}}]".format(path.as_posix()))
            interp.eval("set c [lindex [dict get $p candidates] 0]; set w [lindex [dict get $c weld_plans] 0]")
            self.assertEqual(interp.eval("dict get $w target_component_ids"),"2")
            self.assertEqual(interp.eval("dict get $w center"),"0.5 0.5 1.0")
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
    def test_internal_component_plan_limits_boundaries_to_selected_shell_island(self):
        components={7:Component(7,"SOURCE","SHELL")}
        nodes={
            1:(0,0,0),2:(1,0,0),3:(2,0,0),4:(0,1,0),5:(1,1,0),
            6:(2,1,0),7:(0,2,0),8:(1,2,0),9:(2,2,0),
            20:(10,0,0),21:(11,0,0),22:(11,1,0),23:(10,1,0),
        }
        elements={
            101:Element(101,7,"CQUAD4",(1,2,5,4)),
            102:Element(102,7,"CQUAD4",(2,3,6,5)),
            103:Element(103,7,"CQUAD4",(4,5,8,7)),
            104:Element(104,7,"CQUAD4",(5,6,9,8)),
            200:Element(200,7,"CQUAD4",(20,21,22,23)),
        }
        plans=plan_internal_component_boundaries(MeshModel(components,nodes,elements),7,5)
        self.assertEqual(len(plans),1)
        self.assertEqual(set(plans[0]["source_node_ids"]),{1,2,3,4,6,7,8,9})
        self.assertEqual(plans[0]["center"],[1.0,1.0,0.0])
        self.assertNotIn(20,plans[0]["source_node_ids"])
    def test_native_fem_reader_accepts_free_and_fixed_shell_cards(self):
        free="""BEGIN BULK
GRID,1,,0.,0.,0.
GRID,2,,1.,0.,0.
GRID,3,,1.,1.,0.
GRID,4,,0.,1.,0.
CQUAD4,101,77,1,2,3,4
ENDDATA
"""
        fixed="\n".join((
            "GRID    1               0.0     0.0     0.0",
            "GRID    2               1.0     0.0     0.0",
            "GRID    3               1.0     1.0     0.0",
            "GRID    4               0.0     1.0     0.0",
            "CQUAD4  101     77      1       2       3       4",
            "ENDDATA", "",
        ))
        with tempfile.TemporaryDirectory() as directory:
            for name,text in (("free.fem",free),("fixed.fem",fixed)):
                path=Path(directory)/name; path.write_text(text,encoding="utf-8")
                model=read_shell_fem(path,7)
                self.assertEqual(model.elements[101].node_ids,(1,2,3,4))
                self.assertEqual(model.elements[101].component_id,7)
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
