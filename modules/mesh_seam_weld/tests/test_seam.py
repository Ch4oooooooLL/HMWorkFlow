import json,tempfile,unittest
from pathlib import Path
try:
    import tkinter
except ImportError:
    tkinter=None
from hmworkflow.mesh_seam_weld.free_edge_path import closed_loop
from hmworkflow.mesh_seam_weld.mesh_topology import adjacency,edges
from hmworkflow.mesh_seam_weld.path_aligner import align,cost
from hmworkflow.mesh_seam_weld.path_matcher import match
from hmworkflow.mesh_seam_weld.path_validator import validate_ordered
from hmworkflow.mesh_seam_weld.seam_planner import plan
from hmworkflow.mesh_seam_weld.component_planner import plan_component_welds,plan_internal_component_boundaries,plan_internal_component_welds
from hmworkflow.mesh_seam_weld.fem_mesh_reader import read_shell_fem,read_shell_fem_bundle
from hmworkflow.mesh_seam_weld.main import calculate
from hmworkflow.core.mesh_model import Component,Element,MeshModel
from hmworkflow.core.hybrid_schema import new_result
from hmworkflow.core.result_writer import write_binary_result
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
    def test_target_continuity_clears_reused_element_cache_before_connectivity_read(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body=module.split("proc ::MeshSeamWeld::targetPathEdgeSet",1)[1].split("proc ::MeshSeamWeld::targetPathIsContinuous",1)[0]
        self.assertLess(body.index("unset elemNodesCache"),body.index("readElementConnectivityBulk"))
    def test_default_workflow_uses_tcl_fast_path(self):
        workflow=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"workflow.tcl").read_text(encoding="utf-8")
        body=workflow.split("proc ::MeshSeamWeld::processWeldPath",1)[1]
        self.assertIn("processWeldPathTcl",body)
        self.assertNotIn("processWeldPathPython",body)
    def test_all_free_edge_seed_counts_use_tcl_without_python_fallback(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        self.assertIn("pickNodes",run_action)
        self.assertIn("buildNativeFreeEdgeGraphs",run_action)
        self.assertIn("pathsFromNativeFreeEdgeGraphs",run_action)
        self.assertIn("planning_mode=hm_native_edges",run_action)
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
    def test_tcl_boundary_fast_path_builds_boundary_graph_in_one_mesh_batch(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        bulk=module.split("proc ::MeshSeamWeld::buildNativeFreeEdgeGraphs",1)[1].split("proc ::MeshSeamWeld::pathsFromNativeFreeEdgeGraphs",1)[0]
        self.assertIn("buildNativeFreeEdgeGraphs",run_action)
        self.assertNotIn("closedFreeEdgeLoopsFromSeedsLocal",run_action)
        self.assertIn("componentElementIds",bulk)
        self.assertIn("edgeGraphFromPlotElements",bulk)
        self.assertIn("deleteComponentById",bulk)
        self.assertNotIn("closedFreeEdgeLoopFromNode",bulk)

    def test_closed_boundary_graph_walk_uses_linear_time_queue(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        walk=module.split("proc ::MeshSeamWeld::closedLoopsFromFreeEdgeGraph",1)[1].split("proc ::MeshSeamWeld::sourcePathsForSingleNode",1)[0]
        self.assertIn("queueIndex",walk)
        self.assertNotIn("set queue [lrange $queue 1 end]",walk)

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_graph_walk_completes_a_long_closed_boundary(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        result=interp.eval("""
set graph [dict create]
set count 5000
for {set node 1} {$node <= $count} {incr node} {
    set previous [expr {$node == 1 ? $count : $node - 1}]
    set next [expr {$node == $count ? 1 : $node + 1}]
    dict set graph $node [list $previous $next]
}
set loops [::MeshSeamWeld::closedLoopsFromFreeEdgeGraph $graph]
list [llength $loops] [llength [lindex $loops 0]]
""")
        self.assertEqual(result,"1 5000")

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_bulk_boundary_discovery_reads_component_mesh_once_and_deduplicates_seeds(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        for name in ("componentIdsFromNodes","componentElementIds","readShellElementConnectivityBulk"):
            interp.eval("rename ::MeshSeamWeld::{0} ::MeshSeamWeld::{0}_real".format(name))
        interp.eval("set ::componentReads 0")
        interp.eval("proc ::MeshSeamWeld::componentIdsFromNodes {nodes} {return {7}}")
        interp.eval("proc ::MeshSeamWeld::componentElementIds {id} {incr ::componentReads; return {101}}")
        interp.eval("proc ::MeshSeamWeld::readShellElementConnectivityBulk {ids args} {return {101 {1 2 3 4}}}")
        self.assertEqual(interp.eval("llength [::MeshSeamWeld::closedFreeEdgeLoopsFromSeedsBulk {1 3}]"),"1")
        self.assertEqual(interp.eval("set ::componentReads"),"1")
    def test_all_single_node_modes_use_native_find_edges_without_python_or_fem(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        native=module.split("proc ::MeshSeamWeld::createNativeFreeEdgeComponent",1)[1].split("proc ::MeshSeamWeld::pathsFromNativeFreeEdgeGraphs",1)[0]
        runtime_loader=module.rsplit("foreach hybridFile",1)[1]
        self.assertIn("buildNativeFreeEdgeGraphs",run_action)
        self.assertIn("*findedges comps 1 0",native)
        self.assertIn("^edges",native)
        self.assertIn("^MSWE_",native)
        self.assertNotIn("runPythonInternalComponentPlan",run_action)
        self.assertNotIn("runPythonComponentPlan",run_action)
        self.assertNotIn("prepareDeferredWeldJobs",run_action)
        self.assertNotIn("selected_components.fem",run_action)
        self.assertNotIn("bridge.tcl",runtime_loader)
        self.assertNotIn("exporter.tcl",runtime_loader)

    def test_native_plot_edge_graph_uses_bulk_connectivity_and_ui_checkpoints(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body=module.split("proc ::MeshSeamWeld::edgeGraphFromPlotElements",1)[1].split("proc ::MeshSeamWeld::renameComponentById",1)[0]
        self.assertIn("readElementConnectivityBulk",body)
        self.assertIn("$edgeElemIds {2}",body)
        self.assertIn("responsiveCheckpoint",body)
        self.assertNotIn("set nodes [::MeshSeamWeld::elemNodes $elemId]",body)

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_bulk_connectivity_reader_accepts_two_node_plot_elements(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::markElements ::MeshSeamWeld::markElements_real")
        interp.eval("proc ::MeshSeamWeld::markElements {ids mark} {return $ids}")
        interp.eval("proc hm_getvalue {type args} {return {{1 2} {2 3} {3 1}}}")
        result=interp.eval("::MeshSeamWeld::readElementConnectivityBulk {10 11 12} {2} 2")
        self.assertEqual(interp.eval("dict get {{{}}} 10".format(result)),"1 2")
        self.assertEqual(interp.eval("dict get {{{}}} 12".format(result)),"3 1")

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_responsive_checkpoint_yields_only_at_bounded_intervals(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::HWFlow::progressPumpEvents ::HWFlow::progressPumpEvents_real")
        interp.eval("set ::yieldCount 0")
        interp.eval("proc ::HWFlow::progressPumpEvents {force} {incr ::yieldCount}")
        interp.eval("::MeshSeamWeld::responsiveCheckpoint 1 128")
        interp.eval("::MeshSeamWeld::responsiveCheckpoint 127 128")
        interp.eval("::MeshSeamWeld::responsiveCheckpoint 128 128")
        interp.eval("::MeshSeamWeld::responsiveCheckpoint 256 128")
        self.assertEqual(interp.eval("set ::yieldCount"),"2")

    def test_long_running_mesh_loops_have_responsive_checkpoints(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        projection=module.split("proc ::MeshSeamWeld::projectNodesToTargetComponents",1)[1].split("proc ::MeshSeamWeld::expandTargetElementPatch",1)[0]
        closest=module.split("proc ::MeshSeamWeld::targetNodesFromClosestQuery",1)[1].split("proc ::MeshSeamWeld::targetElementsAfterImprint",1)[0]
        post_imprint=module.split("proc ::MeshSeamWeld::targetElementsAfterImprint",1)[1].split("proc ::MeshSeamWeld::legacyComponentTargetCandidatesAfterImprint",1)[0]
        support=module.split("proc ::MeshSeamWeld::localImprintSharedNeighborElements",1)[1].split("proc ::MeshSeamWeld::clearLocalTopologyCaches",1)[0]
        patch=module.split("proc ::MeshSeamWeld::expandTargetElementPatch",1)[1].split("proc ::MeshSeamWeld::prepareWeldJobs",1)[0]
        strip=module.split("proc ::MeshSeamWeld::createDirectStructuredStrip",1)[1].split("proc ::MeshSeamWeld::createDirectSingleLayerStrip",1)[0]
        self.assertIn("responsiveCheckpoint",projection)
        self.assertIn("responsiveCheckpoint",closest)
        self.assertIn("responsiveCheckpoint",post_imprint)
        self.assertIn("responsiveCheckpoint",support)
        self.assertGreaterEqual(patch.count("responsiveCheckpoint"),2)
        self.assertGreaterEqual(strip.count("responsiveCheckpoint"),2)

    def test_each_long_path_reports_target_imprint_validation_and_mesh_phases(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        executor=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"executor.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        fast=executor.split("proc ::MeshSeamWeld::processWeldPathTcl",1)[1]
        self.assertIn("Preparing current target patch",run_action)
        self.assertIn("Validating post-imprint nodes",fast)
        self.assertIn("Creating structured weld mesh",fast)

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_plot_elements_form_ordered_native_free_edge_graph(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::elemNodes ::MeshSeamWeld::elemNodes_real")
        interp.eval("proc ::MeshSeamWeld::elemNodes {id} {dict get {10 {1 2} 11 {2 3} 12 {3 4} 13 {4 1} 99 {1 2 3 4}} $id}")
        graph=interp.eval("::MeshSeamWeld::edgeGraphFromPlotElements {10 11 12 13 99}")
        self.assertEqual({int(v) for v in interp.eval("dict keys {{{}}}".format(graph)).split()},{1,2,3,4})
        self.assertEqual(interp.eval("llength [::MeshSeamWeld::closedLoopsFromFreeEdgeGraph {{{}}}]".format(graph)),"1")

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_native_find_edges_preserves_existing_global_edge_component(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::HWFlow::componentIdByName ::HWFlow::componentIdByName_real")
        interp.eval("rename ::HWFlow::componentName ::HWFlow::componentName_real")
        interp.eval("rename ::MeshSeamWeld::markComponents ::MeshSeamWeld::markComponents_real")
        interp.eval("array set ::componentNames {100 ^edges 7 SOURCE}")
        interp.eval("proc ::HWFlow::componentIdByName {name} {foreach id [array names ::componentNames] {if {$::componentNames($id) eq $name} {return $id}}; return {}}")
        interp.eval("proc ::HWFlow::componentName {id} {return $::componentNames($id)}")
        interp.eval("proc ::MeshSeamWeld::markComponents {ids mark} {return 1}")
        interp.eval("proc *renamecollector {type old new} {foreach id [array names ::componentNames] {if {$::componentNames($id) eq $old} {set ::componentNames($id) $new; return}}; error missing}")
        interp.eval("proc *findedges {args} {set ::componentNames(200) ^edges}")
        interp.eval("proc *clearmark {args} {}")
        self.assertEqual(interp.eval("::MeshSeamWeld::createNativeFreeEdgeComponent 7 1"),"200")
        self.assertEqual(interp.eval("set ::componentNames(100)"),"^edges")
        self.assertEqual(interp.eval("set ::componentNames(200)"),"^MSWE_7_1")

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_native_edge_graphs_split_internal_and_free_edge_single_points(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        graphs="{7 {1 {2 4} 2 {1 3} 3 {2 4} 4 {1 3} 11 {12 14} 12 {11 13} 13 {12 14} 14 {11 13}}}"
        internal=interp.eval("::MeshSeamWeld::pathsFromNativeFreeEdgeGraphs {99} %s" % graphs)
        self.assertEqual(interp.eval("dict get {{{}}} internal_single_node".format(internal)),"1")
        self.assertEqual(interp.eval("llength [dict get {{{}}} paths]".format(internal)),"2")
        boundary=interp.eval("::MeshSeamWeld::pathsFromNativeFreeEdgeGraphs {3} %s" % graphs)
        self.assertEqual(interp.eval("dict get {{{}}} internal_single_node".format(boundary)),"0")
        self.assertEqual(
            {int(v) for v in interp.eval("lindex [dict get {{{}}} paths] 0".format(boundary)).split()},
            {1,2,3,4},
        )

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_single_point_on_open_native_edge_is_not_misclassified_as_internal(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        graphs="{7 {1 {2} 2 {1 3} 3 {2} 11 {12 14} 12 {11 13} 13 {12 14} 14 {11 13}}}"
        with self.assertRaises(tkinter.TclError):
            interp.eval("::MeshSeamWeld::pathsFromNativeFreeEdgeGraphs {2} %s" % graphs)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_internal_fem_export_manifest_maps_all_selected_components(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        exporter=ROOT/"modules"/"mesh_seam_weld"/"tcl"/"exporter.tcl"
        interp.eval("source {{{}}}".format(exporter.as_posix()))
        for name in ("componentElementIds","componentExportName","optistructExportTemplate"):
            interp.eval("rename ::MeshSeamWeld::{0} ::MeshSeamWeld::{0}_real".format(name))
        interp.eval("proc ::MeshSeamWeld::componentElementIds {id} {dict get {7 {101} 9 {201 202} 10 {301}} $id}")
        interp.eval("proc ::MeshSeamWeld::componentExportName {id} {return COMP_$id}")
        interp.eval("proc ::MeshSeamWeld::optistructExportTemplate {} {return template}")
        interp.eval("proc *createmark {args} {lappend ::createdMarks $args}")
        interp.eval("proc hm_getmark {args} {return {1}}")
        interp.eval("proc *feoutput_select {template output mark reserved1 reserved2} {set channel [open $output w]; puts $channel {BEGIN BULK}; close $channel}")
        with tempfile.TemporaryDirectory() as directory:
            result=interp.eval("::MeshSeamWeld::exportInternalComponentFemBundle {{{}}} RUN 7 {{9 10}}".format(Path(directory).as_posix()))
            manifest_path=Path(interp.eval("dict get {{{}}} manifest".format(result)))
            manifest=json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual([row["component_id"] for row in manifest["components"]],[7,9,10])
            self.assertEqual(manifest["components"][1]["element_ids"],[201,202])
            self.assertIn("{by component id} 7 9 10",interp.eval("set ::createdMarks"))
    def test_all_jobs_prepare_target_patch_just_in_time_without_python_plan(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        prepare=module.split("proc ::MeshSeamWeld::prepareWeldJobs",1)[1].split("proc ::MeshSeamWeld::prepareCurrentTargetPatch",1)[0]
        execution=run_action.split("set pathTotal [llength $sourcePaths]",1)[1].split("set executionMs",1)[0]
        self.assertNotIn("projectNodesToTargetComponents",prepare)
        self.assertNotIn("localTargetPatchFromProjectedNodes",prepare)
        self.assertIn("prepareCurrentTargetPatch $sourceNodes",execution)
        self.assertIn("dict set job target_elements",execution)
        self.assertNotIn("prepareDeferredWeldJobs",run_action)
        self.assertNotIn("refresh_target_patch 1",module)
        self.assertNotIn("buildTargetElementIndex",execution)
        self.assertNotIn("retryTargetElems",execution)
        self.assertNotIn("component-scope retry",execution)
        self.assertIn("createFailureMarkerNodes [list $failure]",execution)
        self.assertIn("retry_count 0",execution)
    def test_tcl_boundary_jobs_project_nodes_without_full_component_index(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body=module.split("proc ::MeshSeamWeld::prepareCurrentTargetPatch",1)[1].split("proc ::MeshSeamWeld::directStructuredStripQuadNodeLists",1)[0]
        self.assertIn("readNodeCoordinatesBulk",body)
        self.assertIn("projectNodesToTargetComponents",body)
        self.assertIn("localTargetPatchFromProjectedNodes",body)
        self.assertNotIn("buildTargetElementIndex",body)
        self.assertNotIn("componentElementIds",body)
        projection=module.split("proc ::MeshSeamWeld::projectNodesToTargetComponents",1)[1].split("proc ::MeshSeamWeld::localTargetPatchFromProjectedNodes",1)[0]
        self.assertIn("hm_getclosestnode",projection)
        self.assertNotIn("hm_getmark",projection)

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_target_patch_collects_all_attached_elements_with_one_bulk_query(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        for name in ("adjacentElementsForNodes","elemComponentId","isLinearShellElement","expandTargetElementPatch"):
            interp.eval("rename ::MeshSeamWeld::{0} ::MeshSeamWeld::{0}_real".format(name))
        interp.eval("set ::adjacentCalls 0")
        interp.eval("proc ::MeshSeamWeld::adjacentElementsForNodes {nodes} {incr ::adjacentCalls; set ::queriedNodes $nodes; return {101 102 201}}")
        interp.eval("proc ::MeshSeamWeld::elemComponentId {id} {if {$id == 201} {return 8}; return 7}")
        interp.eval("proc ::MeshSeamWeld::isLinearShellElement {id} {return 1}")
        interp.eval("proc ::MeshSeamWeld::expandTargetElementPatch {ids comps args} {set ::seedElems $ids; return $ids}")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::localTargetPatchFromProjectedNodes {11 12 13 14 15} {7}"),
            "101 102",
        )
        self.assertEqual(interp.eval("set ::adjacentCalls"),"1")
        self.assertEqual(interp.eval("set ::queriedNodes"),"11 12 13 14 15")
    def test_target_patch_expansion_is_bounded_to_two_or_three_layers(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body=module.split("proc ::MeshSeamWeld::expandTargetElementPatch",1)[1].split("proc ::MeshSeamWeld::localTargetPatchFromProjectedNodes",1)[0]
        self.assertIn("max(2, min(3",body)
        self.assertIn("*appendmark",body)
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
    def test_runtime_messages_do_not_call_every_node_path_a_closed_loop(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        isolated=module.split("proc ::MeshSeamWeld::processWeldPathIsolated",1)[1].split("proc ::MeshSeamWeld::stageError",1)[0]
        self.assertIn("正在准备边界/路径任务",run_action)
        self.assertIn("首个失败边界/路径",run_action)
        self.assertNotIn("首个失败闭环",run_action)
        self.assertIn('closedLoop ? "闭合边界" : "开放节点路径"',isolated)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_plain_text_failure_report_contains_feedback_context(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        with tempfile.TemporaryDirectory() as directory:
            task=Path(directory).as_posix()
            script="""
set context [dict create source_mode internal path_total 3 success_count 2 target_components {7} weld_mesh_size 8]
set failure [dict create path_index 2 source_nodes {11 12 13 14} center {1.0 2.0 3.0} target_components {7} target_elements {101 102} shared_external_element_count 3 retry_count 1 rollback_ok 1 first_error {[MSW_STAGE:IMPRINT] open failed} final_error {[MSW_STAGE:TARGET_MATCH] partial projection}]
::MeshSeamWeld::writeFailureReport {%s} $context [list $failure]
""" % task
            report=Path(interp.eval(script))
            text=report.read_text(encoding="utf-8")
            self.assertIn("MESH_SEAM_WELD_FAILURE_REPORT",text)
            self.assertIn("path_index=2",text)
            self.assertIn("stage=TARGET_MATCH",text)
            self.assertIn("source_node_count=4",text)
            self.assertIn("shared_external_element_count=3",text)
            self.assertIn("raw_error=",text)
    def test_auto_closed_plan_imprints_closed_once_without_retry(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        executor=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"executor.tcl").read_text(encoding="utf-8")
        workflow=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"workflow.tcl").read_text(encoding="utf-8")
        self.assertIn("dict set job closed_loop 1",run_action)
        self.assertIn("imprint_closed_loop 1",run_action)
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
        self.assertIn("Local target elements are required",body)
        self.assertIn("targetElemIds",body)
        self.assertIn("localTargetNodesFromElements",body)
        self.assertNotIn("targetNodesFromClosestQuery",body)

    def test_complete_native_imprint_list_keeps_native_order_without_quadratic_rematch(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body=module.split("proc ::MeshSeamWeld::targetPathNodesAfterImprint",1)[1].split("proc ::MeshSeamWeld::pathPairingCost",1)[0]
        exact=body.split("if {[llength $imprintNodes] == [llength $sourceNodes]}",1)[1].split("}",1)[0]
        self.assertIn("return $imprintNodes",exact)
        self.assertNotIn("matchTargetPathNodes",exact)

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_refreshed_local_target_scope_expands_and_filters_components(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::markElements ::MeshSeamWeld::markElements_real")
        interp.eval("rename ::MeshSeamWeld::elemComponentId ::MeshSeamWeld::elemComponentId_real")
        interp.eval("proc ::MeshSeamWeld::markElements {ids mark} {set ::markedElems $ids; return $ids}")
        interp.eval("proc ::MeshSeamWeld::elemComponentId {id} {if {$id == 202} {return 77}; return 9}")
        interp.eval("proc hm_getmark {type mark} {return $::markedElems}")
        interp.eval("proc *appendmark {type mark option} {set ::markedElems [concat $::markedElems {201 202}]} ")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::markRefreshedLocalTargetElements {101} {9} 1"),
            "101 201",
        )
    def test_failed_local_imprint_is_marked_and_skipped_without_retry(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        run_action=module.split("proc ::MeshSeamWeld::runAction",1)[1].split("proc ::MeshSeamWeld::run",1)[0]
        self.assertIn("$jobClosedLoop",run_action)
        self.assertNotIn("retryTargetElems",run_action)
        self.assertNotIn("component_fallback",run_action)
        self.assertNotIn("component-scope retry",run_action)
        self.assertIn("createFailureMarkerNodes [list $failure]",run_action)
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
    def test_internal_component_plan_returns_nearby_target_element_patch(self):
        components={7:Component(7,"SOURCE","SHELL"),9:Component(9,"TARGET","SHELL")}
        nodes={
            1:(0,0,1),2:(1,0,1),3:(2,0,1),4:(0,1,1),5:(1,1,1),
            6:(2,1,1),7:(0,2,1),8:(1,2,1),9:(2,2,1),
            11:(0,0,0),12:(1,0,0),13:(2,0,0),14:(0,1,0),15:(1,1,0),
            16:(2,1,0),17:(0,2,0),18:(1,2,0),19:(2,2,0),
        }
        elements={
            101:Element(101,7,"CQUAD4",(1,2,5,4)),
            102:Element(102,7,"CQUAD4",(2,3,6,5)),
            103:Element(103,7,"CQUAD4",(4,5,8,7)),
            104:Element(104,7,"CQUAD4",(5,6,9,8)),
            201:Element(201,9,"CQUAD4",(11,12,15,14)),
            202:Element(202,9,"CQUAD4",(12,13,16,15)),
            203:Element(203,9,"CQUAD4",(14,15,18,17)),
            204:Element(204,9,"CQUAD4",(15,16,19,18)),
        }
        plans=plan_internal_component_welds(MeshModel(components,nodes,elements),7,5,[9],1)
        self.assertEqual(len(plans),1)
        self.assertEqual(plans[0]["target_component_ids"],[9])
        self.assertEqual(set(plans[0]["target_element_ids"]),{201,202,203,204})
        self.assertEqual(plans[0]["projection_mode"],"LOCAL_ELEMENTS")
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
    def test_native_fem_bundle_restores_hypermesh_component_ownership(self):
        fem="""BEGIN BULK
GRID,1,,0.,0.,1.
GRID,2,,1.,0.,1.
GRID,3,,1.,1.,1.
GRID,4,,0.,1.,1.
GRID,11,,0.,0.,0.
GRID,12,,1.,0.,0.
GRID,13,,1.,1.,0.
GRID,14,,0.,1.,0.
CQUAD4,101,77,1,2,3,4
CQUAD4,201,88,11,12,13,14
ENDDATA
"""
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/"selected_components.fem").write_text(fem,encoding="utf-8")
            manifest={
                "schema_version":"1.0","format":"hm_selected_components_fem",
                "fem_path":"selected_components.fem","components":[
                    {"component_id":7,"component_name":"SOURCE","role":"source","element_ids":[101]},
                    {"component_id":9,"component_name":"TARGET","role":"target","element_ids":[201]},
                ],
            }
            path=root/"selected_components_manifest.json"
            path.write_text(json.dumps(manifest),encoding="utf-8")
            model=read_shell_fem_bundle(path)
            self.assertEqual(model.elements[101].component_id,7)
            self.assertEqual(model.elements[201].component_id,9)
            self.assertEqual(model.components[9].component_name,"TARGET")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_local_imprint_uses_element_target(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::markElements ::MeshSeamWeld::markElements_real")
        interp.eval("rename ::MeshSeamWeld::markComponents ::MeshSeamWeld::markComponents_real")
        interp.eval("rename ::MeshSeamWeld::markRefreshedLocalTargetElements ::MeshSeamWeld::markRefreshedLocalTargetElements_real")
        interp.eval("proc ::MeshSeamWeld::markElements {ids mark} {return $ids}")
        interp.eval("proc ::MeshSeamWeld::markComponents {ids mark} {return 1}")
        interp.eval("proc ::MeshSeamWeld::markRefreshedLocalTargetElements {ids comps mark args} {return {201 202 203}}")
        interp.eval("proc *clearlist {args} {}; proc *createlist {args} {}")
        interp.eval("proc *imprint_nodelist {listId entityType markId options} {set ::imprintEntityType $entityType}")
        interp.eval("::MeshSeamWeld::runImprintNodeList {1 2 3} {9} 1 {101 102}")
        self.assertEqual(interp.eval("set ::imprintEntityType"),"elements")
        self.assertEqual(interp.eval("set ::MeshSeamWeld::lastImprintTargetMode"),"local_elements")
        self.assertEqual(interp.eval("set ::MeshSeamWeld::lastImprintTargetElemCount"),"2")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_shared_node_shells_from_other_components_are_diagnostic_only(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        for name in ("elemNodes","adjacentElementsForNodes","isLinearShellElement"):
            interp.eval("rename ::MeshSeamWeld::{0} ::MeshSeamWeld::{0}_real".format(name))
        interp.eval("proc ::MeshSeamWeld::elemNodes {id} {dict get {101 {1 2 3 4} 201 {1 4 5 6} 301 {1 2 7 8}} $id}")
        interp.eval("proc ::MeshSeamWeld::adjacentElementsForNodes {nodes} {return {101 201 301}}")
        interp.eval("proc ::MeshSeamWeld::isLinearShellElement {id} {expr {$id != 301}}")
        neighbors=interp.eval("::MeshSeamWeld::localImprintSharedNeighborElements {101}")
        self.assertEqual(neighbors,"201")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_shared_node_halo_accepts_linear_shells_and_rejects_four_node_solids(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("proc hm_getvalue {type args} {set id [string range [lindex $args 0] 3 end]; dict get {201 104 301 208} $id}")
        self.assertEqual(interp.eval("::MeshSeamWeld::isLinearShellElement 201"),"1")
        self.assertEqual(interp.eval("::MeshSeamWeld::isLinearShellElement 301"),"0")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_imprint_receives_only_projected_target_elements(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        for name in ("markElements","localImprintSharedNeighborElements","elemNodes","clearLocalTopologyCaches"):
            interp.eval("rename ::MeshSeamWeld::{0} ::MeshSeamWeld::{0}_real".format(name))
        interp.eval("proc ::MeshSeamWeld::markElements {ids mark} {set ::imprintMarked $ids; return $ids}")
        interp.eval("proc ::MeshSeamWeld::localImprintSharedNeighborElements {core} {return {201 202}}")
        interp.eval("proc ::MeshSeamWeld::elemNodes {id} {return {1 2 3 4}}")
        interp.eval("proc ::MeshSeamWeld::clearLocalTopologyCaches {elems nodes} {set ::clearedElems $elems}")
        interp.eval("proc *clearlist {args} {}; proc *createlist {args} {}")
        interp.eval("proc *imprint_nodelist {listId entityType markId options} {set ::imprintEntityType $entityType}")
        interp.eval("::MeshSeamWeld::runImprintNodeList {1 2 3} {9} 1 {101 102}")
        self.assertEqual(interp.eval("set ::imprintMarked"),"101 102")
        self.assertEqual(interp.eval("set ::MeshSeamWeld::lastImprintTargetMode"),"local_elements")
        self.assertEqual(interp.eval("set ::MeshSeamWeld::lastImprintCoreElemCount"),"2")
        self.assertEqual(interp.eval("set ::MeshSeamWeld::lastImprintSupportElemCount"),"0")
        self.assertEqual(interp.eval("set ::MeshSeamWeld::lastImprintSharedNeighborElemCount"),"2")
        self.assertEqual(interp.eval("set ::MeshSeamWeld::lastImprintTargetElemCount"),"2")
    def test_local_imprint_never_falls_back_to_components(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body=module.split("proc ::MeshSeamWeld::runImprintNodeList",1)[1].split("proc ::MeshSeamWeld::targetNodesFromImprintList",1)[0]
        self.assertIn("markRefreshedLocalTargetElements",body)
        self.assertIn("localImprintSharedNeighborElements",body)
        self.assertNotIn("markComponents",body)
        self.assertNotIn("components comps",body)
        self.assertIn("No local target elements were prepared",body)
        support=module.split("proc ::MeshSeamWeld::localImprintSharedNeighborElements",1)[1].split("proc ::MeshSeamWeld::clearLocalTopologyCaches",1)[0]
        self.assertIn("adjacentElementsForNodes",support)
        self.assertNotIn("componentElementIds",support)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_tcl_projection_builds_patch_from_nearby_target_nodes(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        for name in ("adjacentElementsForNodes","elemComponentId","isLinearShellElement","nodeXYZ","expandTargetElementPatch"):
            interp.eval("rename ::MeshSeamWeld::{0} ::MeshSeamWeld::{0}_real".format(name))
        interp.eval("array set ::xyz {1 {0 0 1} 2 {1 0 1}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}")
        interp.eval("proc *clearmark {args} {}; proc *createmark {args} {}")
        interp.eval("proc hm_getclosestnode {x y z elemMark nodeMark} {expr {$x < 0.5 ? 11 : 12}}")
        interp.eval("set p [::MeshSeamWeld::projectNodesToTargetComponents {1 2} {9}]")
        self.assertEqual(interp.eval("dict get $p projected 1"),"11")
        self.assertEqual(interp.eval("dict get $p projected 2"),"12")
        interp.eval("proc ::MeshSeamWeld::adjacentElementsForNodes {ids} {return {201 202}}")
        interp.eval("proc ::MeshSeamWeld::elemComponentId {id} {return 9}")
        interp.eval("proc ::MeshSeamWeld::isLinearShellElement {id} {return 1}")
        interp.eval("proc ::MeshSeamWeld::expandTargetElementPatch {ids comps args} {return {201 202 203}}")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::localTargetPatchFromProjectedNodes {11 12} {9}"),
            "201 202 203",
        )

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_closed_loop_projection_adds_radial_seeds_for_surrounding_cylinder(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real")
        interp.eval("array set ::xyz {1 {1 0 0} 2 {0 1 0} 3 {-1 0 0} 4 {0 -1 0} 11 {5 0 0} 12 {0 5 0} 13 {-5 0 0} 14 {0 -5 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}")
        interp.eval("proc *clearmark {args} {}; proc *createmark {args} {}")
        # At the inner loop all source nodes collapse to one coarse target
        # node.  Queries near the estimated enclosing radius recover the
        # circumferential target seeds needed by the local imprint patch.
        interp.eval("proc hm_getclosestnode {x y z elemMark nodeMark} {if {abs($x) < 2.0 && abs($y) < 2.0} {return 11}; if {abs($x) >= abs($y)} {expr {$x >= 0 ? 11 : 13}} else {expr {$y >= 0 ? 12 : 14}}}")
        interp.eval("set p [::MeshSeamWeld::projectNodesToTargetComponents {1 2 3 4} {9} 1]")
        self.assertEqual(interp.eval("dict get $p radial_assist"),"1")
        self.assertEqual(
            {int(v) for v in interp.eval("dict get $p patch_nodes").split()},
            {11,12,13,14},
        )

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_open_projection_does_not_add_radial_seeds(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real")
        interp.eval("array set ::xyz {1 {0 0 0} 2 {1 0 0} 3 {2 0 0} 11 {5 0 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}")
        interp.eval("proc *clearmark {args} {}; proc *createmark {args} {}; proc hm_getclosestnode {args} {return 11}")
        interp.eval("set p [::MeshSeamWeld::projectNodesToTargetComponents {1 2 3} {9} 0]")
        self.assertEqual(interp.eval("dict get $p radial_assist"),"0")
        self.assertEqual(interp.eval("dict get $p patch_nodes"),"11")

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_open_circular_arc_projection_adds_radial_cylinder_seeds(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real")
        interp.eval("array set ::xyz {1 {1 0 0} 2 {0 1 0} 3 {-1 0 0} 11 {5 0 0} 12 {0 5 0} 13 {-5 0 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}")
        interp.eval("proc *clearmark {args} {}; proc *createmark {args} {}")
        interp.eval("proc hm_getclosestnode {x y z elemMark nodeMark} {if {abs($x) < 2.0 && abs($y) < 2.0} {return 11}; if {abs($x) >= abs($y)} {expr {$x >= 0 ? 11 : 13}} else {return 12}}")
        interp.eval("set p [::MeshSeamWeld::projectNodesToTargetComponents {1 2 3} {9} 0]")
        self.assertEqual(interp.eval("dict get $p radial_assist"),"1")
        self.assertEqual(
            {int(v) for v in interp.eval("dict get $p patch_nodes").split()},
            {11,12,13},
        )
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
        interp.eval("rename ::MeshSeamWeld::markRefreshedLocalTargetElements ::MeshSeamWeld::markRefreshedLocalTargetElements_real")
        interp.eval("rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real")
        interp.eval("proc ::MeshSeamWeld::markRefreshedLocalTargetElements {ids comps mark args} {return {101 102}}")
        interp.eval("array set ::xyz {1 {0 0 1} 2 {1 0 1} 11 {0 0 0} 12 {1 0 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}")
        interp.eval("proc *clearmark {args} {}; proc *createmark {args} {}")
        interp.eval("proc hm_getclosestnode {x y z elemMark nodeMark} {if {$x < 0.5} {return 11}; return 12}")
        interp.eval("proc hm_latestentityid {type} {error {latest ID must not be used}}")
        self.assertEqual(interp.eval("::MeshSeamWeld::targetNodesFromClosestQuery {1 2} {9} {101 102}"),"11 12")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_post_imprint_topology_wrapper_accepts_duplicate_closest_anchors(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::localTargetNodesFromElements ::MeshSeamWeld::localTargetNodesFromElements_real")
        interp.eval("rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real")
        interp.eval("array set ::xyz {1 {0 0 1} 2 {1 0 1} 3 {1 1 1} 4 {0 1 1} 11 {0 0 0} 12 {1 0 0} 13 {1 1 0} 14 {0 1 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}")
        interp.eval("proc ::MeshSeamWeld::localTargetNodesFromElements {elems comps} {set ::MeshSeamWeld::lastLocalTargetEdges [dict create 11,12 1 12,13 1 13,14 1 11,14 1]; return {11 12 13 14}}")
        interp.eval("proc ::MeshSeamWeld::closestTargetAnchors {source comps elems} {return {11 11 13 14}}")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::targetNodesFromPostImprintTopology {1 2 3 4} {9} {101 102} 1"),
            "11 12 13 14",
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_post_imprint_fallback_uses_new_nodes_from_local_patch(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::targetNodesFromImprintList ::MeshSeamWeld::targetNodesFromImprintList_real")
        interp.eval("rename ::MeshSeamWeld::localTargetNodesFromElements ::MeshSeamWeld::localTargetNodesFromElements_real")
        interp.eval("proc ::MeshSeamWeld::targetNodesFromImprintList {source before} {return {}}")
        interp.eval("proc ::MeshSeamWeld::localTargetNodesFromElements {elems comps} {return {11 12 13 14}}")
        interp.eval("proc hm_getlist {args} {return {}}")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::targetCandidatesAfterImprint {1 2} {9} {} {101 102} {11 12}"),
            "13 14",
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_topology_constrained_matching_selects_continuous_closed_target(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real")
        interp.eval("array set ::xyz {1 {0 0 1} 2 {1 0 1} 3 {1 1 1} 4 {0 1 1} 11 {0 0 0} 12 {1 0 0} 13 {1 1 0} 14 {0 1 0} 21 {0.1 0 0} 22 {0.9 0 0} 23 {0.9 1 0} 24 {0.1 1 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}")
        interp.eval("set ::MeshSeamWeld::lastLocalTargetEdges [dict create 11,12 1 12,13 1 13,14 1 11,14 1]")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::matchContinuousTargetPathNodes {1 2 3 4} {11 12 13 14 21 22 23 24} 1"),
            "11 12 13 14",
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_duplicate_closest_anchors_are_resolved_by_post_imprint_topology(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real")
        interp.eval("array set ::xyz {1 {0 0 1} 2 {1 0 1} 3 {1 1 1} 4 {0 1 1} 11 {0 0 0} 12 {1 0 0} 13 {1 1 0} 14 {0 1 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}")
        interp.eval("set ::MeshSeamWeld::lastLocalTargetEdges [dict create 11,12 1 12,13 1 13,14 1 11,14 1]")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::matchContinuousTargetPathNodes {1 2 3 4} {11 12 13 14} 1 {11 11 13 14}"),
            "11 12 13 14",
        )

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_surrounding_cylinder_recovers_closed_target_ring_with_different_node_count(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        result=interp.eval("""
rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real
array set ::xyz {}
set source {}
set target {}
set edges [dict create]
for {set i 0} {$i < 4} {incr i} {
    set id [expr {$i + 1}]; set a [expr {2.0*acos(-1.0)*$i/4.0}]
    set ::xyz($id) [list [expr {cos($a)}] [expr {sin($a)}] 0.0]
    lappend source $id
}
for {set i 0} {$i < 8} {incr i} {
    set id [expr {11 + $i}]; set a [expr {2.0*acos(-1.0)*$i/8.0}]
    set ::xyz($id) [list [expr {5.0*cos($a)}] [expr {5.0*sin($a)}] 0.0]
    lappend target $id
    dict set edges [::MeshSeamWeld::canonicalEdgeKey $id [expr {11 + (($i + 1) % 8)}]] 1
}
proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}
set ::MeshSeamWeld::lastLocalTargetEdges $edges
::MeshSeamWeld::matchVariableTargetPathNodes $source $target 1 {11 13 15 17}
""")
        self.assertEqual(tuple(interp.splitlist(result)),tuple(str(11+i) for i in range(8)))

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_surrounding_cylinder_recovers_open_target_arc_with_different_node_count(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("set ::MeshSeamWeld::lastLocalTargetEdges [dict create 11,12 1 12,13 1 13,14 1 14,15 1]")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::matchVariableTargetPathNodes {1 2 3} {11 12 13 14 15} 0 {11 13 15}"),
            "11 12 13 14 15",
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_open_variable_path_erases_noisy_anchor_backtracks(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("set ::MeshSeamWeld::lastLocalTargetEdges [dict create 11,12 1 12,13 1 13,14 1 14,15 1]")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::matchVariableTargetPathNodes {1 2 3 4 5 6} {11 12 13 14 15} 0 {11 12 11 12 14 15}"),
            "11 12 13 14 15",
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_open_endpoint_fallback_ignores_bad_interior_anchor_branch(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("set ::MeshSeamWeld::lastLocalTargetEdges [dict create 11,12 1 12,13 1 13,14 1 14,15 1 12,21 1]")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::matchOpenTargetPathFromEndpoints {1 2 3 4} {11 12 13 14 15 21} {11 21 13 15}"),
            "11 12 13 14 15",
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_failure_detail_is_short_and_removes_stage_prefix(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        self.assertEqual(
            interp.eval("::MeshSeamWeld::briefFailureDetail {[MSW_STAGE:TARGET_MATCH] exact matching reason} 100"),
            "exact matching reason",
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_fifty_one_node_loop_recovers_from_one_duplicate_anchor(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        result=interp.eval("""
rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real
array set ::xyz {}
set source {}
set target {}
set anchors {}
set edges [dict create]
set count 51
for {set index 0} {$index < $count} {incr index} {
    set sourceNode [expr {$index + 1}]
    set targetNode [expr {1001 + $index}]
    set angle [expr {2.0*acos(-1.0)*$index/double($count)}]
    set ::xyz($sourceNode) [list [expr {cos($angle)}] [expr {sin($angle)}] 1.0]
    set ::xyz($targetNode) [list [expr {cos($angle)}] [expr {sin($angle)}] 0.0]
    lappend source $sourceNode
    lappend target $targetNode
    if {$index == 1} {
        lappend anchors 1001
    } else {
        lappend anchors $targetNode
    }
    set nextNode [expr {1001 + (($index + 1) % $count)}]
    dict set edges [::MeshSeamWeld::canonicalEdgeKey $targetNode $nextNode] 1
}
proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}
set ::MeshSeamWeld::lastLocalTargetEdges $edges
set path [::MeshSeamWeld::matchContinuousTargetPathNodes $source $target 1 $anchors]
list [llength $path] [llength [lsort -integer -unique $path]]
""")
        self.assertEqual(result,"51 51")
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_topology_tracking_can_leave_a_long_run_of_duplicate_anchor_neighborhoods(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        result=interp.eval("""
rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::nodeXYZ_real
array set ::xyz {}
set source {}
set target {}
set anchors {}
set edges [dict create]
set count 349
for {set index 0} {$index < $count} {incr index} {
    set sourceNode [expr {$index + 1}]
    set targetNode [expr {1001 + $index}]
    set angle [expr {2.0*acos(-1.0)*$index/double($count)}]
    set ::xyz($sourceNode) [list [expr {10.0*cos($angle)}] [expr {10.0*sin($angle)}] 1.0]
    set ::xyz($targetNode) [list [expr {10.0*cos($angle)}] [expr {10.0*sin($angle)}] 0.0]
    lappend source $sourceNode
    lappend target $targetNode
    lappend anchors 1001
    set nextNode [expr {1001 + (($index + 1) % $count)}]
    dict set edges [::MeshSeamWeld::canonicalEdgeKey $targetNode $nextNode] 1
}
proc ::MeshSeamWeld::nodeXYZ {id} {return $::xyz($id)}
set ::MeshSeamWeld::lastLocalTargetEdges $edges
set path [::MeshSeamWeld::matchContinuousTargetPathNodes $source $target 1 $anchors]
list $path [llength [lsort -integer -unique $path]]
""")
        path,unique_count=interp.splitlist(result)
        self.assertEqual(tuple(interp.splitlist(path)),tuple(str(1001+i) for i in range(349)))
        self.assertEqual(unique_count,"349")
    def test_topology_matcher_uses_bounded_candidates_and_backpointers(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body=module.split("proc ::MeshSeamWeld::matchContinuousTargetPathNodes",1)[1].split("proc ::MeshSeamWeld::targetPathNodesAfterImprint",1)[0]
        self.assertIn("boundedTargetCandidates",body)
        self.assertIn("backPointers",body)
        self.assertNotIn("previousPath",body)
        self.assertNotIn("rankedLayers",body)
        self.assertNotIn("foreach candidate $candidateNodes",body)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_direct_single_layer_closed_strip_preserves_pairing_at_seam(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        quads=interp.splitlist(
            interp.eval("::MeshSeamWeld::directStripQuadNodeLists {1 2 3 4} {11 12 13 14} 1")
        )
        self.assertEqual(
            [tuple(interp.splitlist(quad)) for quad in quads],
            [
                ("1","2","12","11"),
                ("2","3","13","12"),
                ("3","4","14","13"),
                ("4","1","11","14"),
            ],
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_direct_multi_layer_closed_strip_preserves_every_cross_chain(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        quads=interp.splitlist(
            interp.eval("::MeshSeamWeld::directStructuredStripQuadNodeLists {{1 101 11} {2 102 12} {3 103 13}} 1")
        )
        self.assertEqual(
            [tuple(interp.splitlist(quad)) for quad in quads],
            [
                ("1","2","102","101"),("101","102","12","11"),
                ("2","3","103","102"),("102","103","13","12"),
                ("3","1","101","103"),("103","101","11","13"),
            ],
        )

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_unequal_closed_paths_generate_continuous_zipper_elements(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        elems=interp.splitlist(interp.eval(
            "::MeshSeamWeld::unequalStripElementNodeLists {1 2 3 4} {11 12 13 14 15 16 17 18} 1"
        ))
        parsed=[tuple(interp.splitlist(elem)) for elem in elems]
        self.assertEqual(len(parsed),8)
        self.assertTrue(all(len(elem) in (3,4) for elem in parsed))
        self.assertEqual({node for elem in parsed for node in elem},{str(i) for i in range(1,5)}|{str(i) for i in range(11,19)})

    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_unequal_open_paths_generate_continuous_zipper_elements(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        elems=interp.splitlist(interp.eval(
            "::MeshSeamWeld::unequalStripElementNodeLists {1 2 3} {11 12 13 14 15} 0"
        ))
        self.assertEqual(len(elems),4)
        self.assertTrue(all(len(interp.splitlist(elem)) in (3,4) for elem in elems))
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_anchored_unequal_strip_keeps_the_real_projected_corner_node(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("array set ::xyz {1 {0 0 1} 2 {2 0 1} 3 {3 0 1} 11 {0 0 0} 12 {1 0 0} 13 {2 0 0} 14 {3 0 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {node} {return $::xyz($node)}")
        correspondence=interp.eval("::MeshSeamWeld::anchoredTargetCorrespondence {1 2 3} {11 12 13 14} 0")
        self.assertEqual(interp.eval("dict get {{{}}} anchor_indices".format(correspondence)),"0 2 3")
        elems=interp.splitlist(interp.eval(
            "::MeshSeamWeld::anchoredUnequalStripElementNodeLists {1 2 3} {11 12 13 14} {0 2 3} 0"
        ))
        self.assertEqual(len(elems),3)
        first_two=[tuple(interp.splitlist(elem)) for elem in elems[:2]]
        self.assertTrue(any("13" in elem for elem in first_two))
    def test_equal_paths_use_corner_safe_structured_mesh_and_unequal_paths_use_native_ruled(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        ruled=module.split("proc ::MeshSeamWeld::createRuledMeshBetweenNodePaths",1)[1].split("proc ::MeshSeamWeld::createNativeRuledMeshBetweenNodePaths",1)[0]
        native=module.split("proc ::MeshSeamWeld::createNativeRuledMeshBetweenNodePaths",1)[1].split("proc ::MeshSeamWeld::pathCenter",1)[0]
        self.assertIn("createNativeRuledMeshBetweenNodePaths",ruled)
        self.assertIn("createDirectStructuredStrip",ruled)
        self.assertIn("createAnchoredStructuredStrip",ruled)
        self.assertIn("anchoredTargetCorrespondence",ruled)
        self.assertIn("maximumPathCrossDistance",ruled)
        self.assertIn("*linearsurfacebetweennodes 1 2 1",native)
        self.assertIn("*automesh",native)
        self.assertIn("maximumPathCrossDistance",native)
        self.assertIn("if {$closedLoop}",native)
        self.assertIn("createClosedStripElements",native)
        self.assertIn("*createmark nodes 1 -1",module)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_unequal_paths_are_aligned_by_geometry_without_requiring_equal_counts(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("array set ::xyz {1 {0 0 1} 2 {1 0 1} 3 {2 0 1} 11 {2 0 0} 12 {0 0 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {node} {return $::xyz($node)}")
        self.assertEqual(
            tuple(interp.splitlist(interp.eval("::MeshSeamWeld::alignTargetPathNodes {1 2 3} {11 12} 0"))),
            ("12","11"),
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_cross_density_uses_widest_interior_correspondence_not_only_endpoints(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("array set ::xyz {1 {0 0 0} 2 {1 0 0} 3 {2 0 0} 11 {0 1 0} 12 {1 5 0} 13 {2 1 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {node} {return $::xyz($node)}")
        self.assertEqual(
            float(interp.eval("::MeshSeamWeld::maximumPathCrossDistance {1 2 3} {11 12 13} 0")),
            5.0,
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_equal_target_path_repairs_local_native_list_slip_by_geometric_correspondence(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("array set ::xyz {1 {0 0 1} 2 {1 0 1} 3 {2 0 1} 4 {3 0 1} 11 {0 0 0} 12 {1 0 0} 13 {2 0 0} 14 {3 0 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {node} {return $::xyz($node)}")
        interp.eval("proc ::MeshSeamWeld::targetPathIsContinuous {nodes comps closed} {return 1}")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::refineEqualTargetPathCorrespondence {1 2 3 4} {11 13 12 14} {9} 0"),
            "11 12 13 14",
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_equal_target_path_keeps_native_order_when_closest_mapping_is_not_continuous(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("array set ::xyz {1 {0 0 1} 2 {1 0 1} 3 {2 0 1} 11 {0 0 0} 12 {1 0 0} 13 {2 0 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {node} {return $::xyz($node)}")
        interp.eval("proc ::MeshSeamWeld::targetPathIsContinuous {nodes comps closed} {return 0}")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::refineEqualTargetPathCorrespondence {1 2 3} {11 13 12} {9} 0"),
            "11 13 12",
        )
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_ruled_side_one_is_the_unchanged_mesh_edit_node_list(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::alignTargetPathNodes ::MeshSeamWeld::alignTargetPathNodes_real")
        interp.eval("rename ::MeshSeamWeld::createNativeRuledMeshBetweenNodePaths ::MeshSeamWeld::createNativeRuledMeshBetweenNodePaths_real")
        interp.eval("rename ::MeshSeamWeld::anchoredTargetCorrespondence ::MeshSeamWeld::anchoredTargetCorrespondence_real")
        interp.eval("proc ::MeshSeamWeld::alignTargetPathNodes {source target closed} {return {14 13 12 11}}")
        interp.eval("proc ::MeshSeamWeld::anchoredTargetCorrespondence {source target closed} {return {}}")
        interp.eval("proc ::MeshSeamWeld::createNativeRuledMeshBetweenNodePaths {source target comp closed} {set ::ruledInputs [list $source $target $closed]; return {901}}")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::createRuledMeshBetweenNodePaths {1 2 3} {11 12 13 14} SEAM 1 {9}"),
            "901",
        )
        self.assertEqual(interp.eval("set ::ruledInputs"),"{1 2 3} {14 13 12 11} 1")
    def test_unequal_paths_keep_native_ruled_fallback(self):
        module=(ROOT/"modules"/"mesh_seam_weld.tcl").read_text(encoding="utf-8")
        ruled=module.split("proc ::MeshSeamWeld::createRuledMeshBetweenNodePaths",1)[1].split("proc ::MeshSeamWeld::createNativeRuledMeshBetweenNodePaths",1)[0]
        native=module.split("proc ::MeshSeamWeld::createNativeRuledMeshBetweenNodePaths",1)[1].split("proc ::MeshSeamWeld::pathCenter",1)[0]
        self.assertNotIn("contiguousMatchedNodeRuns",ruled)
        self.assertIn("createDirectStructuredStrip",ruled)
        self.assertNotIn("Source and target node path counts do not match",native)
        self.assertIn("*linearsurfacebetweennodes 1 2 1",native)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_partial_correspondence_keeps_only_contiguous_matched_runs(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("array set ::xyz {1 {0 0 1} 2 {1 0 1} 3 {2 0 1} 4 {3 0 1} 5 {4 0 1} 11 {0 0 0} 12 {1 0 0} 14 {3 0 0} 15 {4 0 0}}")
        interp.eval("proc ::MeshSeamWeld::nodeXYZ {node} {return $::xyz($node)}")
        pairs=interp.splitlist(interp.eval("::MeshSeamWeld::monotonicClosestNodePairs {1 2 3 4 5} {11 12 14 15}"))
        self.assertEqual(
            [tuple(interp.splitlist(pair)) for pair in pairs],
            [("0","0","1","11"),("1","1","2","12"),("3","2","4","14"),("4","3","5","15")],
        )
        runs=interp.splitlist(interp.eval("::MeshSeamWeld::contiguousMatchedNodeRuns [::MeshSeamWeld::monotonicClosestNodePairs {1 2 3 4 5} {11 12 14 15}]"))
        self.assertEqual(
            [tuple(interp.splitlist(run)) for run in runs],
            [("1 2","11 12"),("4 5","14 15")],
        )
    def test_partial_native_imprint_list_is_rejected_when_topology_recovery_fails(self):
        executor=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"executor.tcl").read_text(encoding="utf-8")
        fast=executor.split("proc ::MeshSeamWeld::processWeldPathTcl",1)[1]
        self.assertNotIn("partial_native_imprint_list",fast)
        self.assertIn("native imprint result was incomplete",fast)
    def test_executor_accepts_a_shorter_continuous_native_imprint_path(self):
        executor=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"executor.tcl").read_text(encoding="utf-8")
        fast=executor.split("proc ::MeshSeamWeld::processWeldPathTcl",1)[1]
        native_call=fast.split("targetNodesFromImprintList",1)[1].split("]",1)[0]
        self.assertIn(" 0",native_call)
        self.assertNotIn("strict one-to-one correspondence",fast)
        self.assertIn("alignTargetPathNodes",fast)
    def test_executor_passes_local_target_scope_to_post_imprint_matching(self):
        executor=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"executor.tcl").read_text(encoding="utf-8")
        fast=executor.split("proc ::MeshSeamWeld::processWeldPathTcl",1)[1]
        call=fast.split("targetNodesFromPostImprintTopology",1)[1].split("]",1)[0]
        self.assertIn("$currentTargetElems",call)
        refresh=fast.split("targetElementsAfterImprint",1)[1].split("]",1)[0]
        self.assertIn("$targetElemIds",refresh)
        self.assertIn("$sourceNodes",refresh)
        self.assertIn("$closedLoop",refresh)
        self.assertIn("imprint_scope=",fast)
        self.assertIn("imprint_target_elems=",fast)
    def test_executor_accepts_complete_native_path_before_rebuilding_stale_elements(self):
        executor=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"executor.tcl").read_text(encoding="utf-8")
        fast=executor.split("proc ::MeshSeamWeld::processWeldPathTcl",1)[1]
        self.assertLess(fast.index("targetNodesFromImprintList"),fast.index("targetElementsAfterImprint"))
        rebuild=fast.split("targetElementsAfterImprint",1)[0]
        self.assertIn('set currentTargetElems {}',rebuild)
        self.assertIn('if {[llength $targetNodes] == 0',rebuild)
    @unittest.skipIf(tkinter is None,"tkinter Tcl runtime is unavailable")
    def test_post_imprint_scope_reprojects_when_every_old_element_id_is_gone(self):
        interp=tkinter.Tcl(); module=ROOT/"modules"/"mesh_seam_weld.tcl"
        interp.eval("source {{{}}}".format(module.as_posix()))
        interp.eval("rename ::MeshSeamWeld::markElements ::MeshSeamWeld::markElements_real")
        interp.eval("rename ::MeshSeamWeld::markRefreshedLocalTargetElements ::MeshSeamWeld::markRefreshedLocalTargetElements_real")
        interp.eval("rename ::MeshSeamWeld::prepareCurrentTargetPatch ::MeshSeamWeld::prepareCurrentTargetPatch_real")
        interp.eval("proc hm_getlist {args} {return {}}")
        interp.eval("proc ::MeshSeamWeld::markElements {ids mark} {return {}}")
        interp.eval("proc ::MeshSeamWeld::markRefreshedLocalTargetElements {ids comps mark args} {return {}}")
        interp.eval("proc ::MeshSeamWeld::prepareCurrentTargetPatch {source comps closed} {set ::reprojectArgs [list $source $comps $closed]; return [dict create target_elements {501 502 503}]} ")
        self.assertEqual(
            interp.eval("::MeshSeamWeld::targetElementsAfterImprint {9} {101 102} {1 2 3} 0"),
            "501 502 503",
        )
        self.assertEqual(interp.eval("set ::reprojectArgs"),"{1 2 3} 9 0")
    def test_executor_rules_only_with_post_imprint_nodes(self):
        executor=(ROOT/"modules"/"mesh_seam_weld"/"tcl"/"executor.tcl").read_text(encoding="utf-8")
        fast=executor.split("proc ::MeshSeamWeld::processWeldPathTcl",1)[1]
        after=fast.split("runImprintNodeList",1)[1]
        self.assertIn("targetElementsAfterImprint",after)
        self.assertIn("targetNodesFromImprintList",after)
        self.assertIn("targetNodesFromPostImprintTopology",after)
        self.assertIn("native_imprint_list",after)
        self.assertIn("post_imprint_topology",after)
        self.assertNotIn("targetNodesFromClosestQuery",after)
        self.assertIn("targetPathIsContinuous",after)
        self.assertIn("refineEqualTargetPathCorrespondence",after)
        ruled=after.split("createRuledMeshBetweenNodePaths",1)[0]
        self.assertNotIn("targetCandidatesAfterImprint",ruled)
        self.assertNotIn("targetPathNodesAfterImprint",ruled)
        self.assertIn("alignTargetPathNodes",ruled)
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
