import importlib.util, json, math, tempfile, tkinter, unittest
from pathlib import Path
from free_edge_loops import find
from loop_geometry import calculate
from mesh_model import Component, Element, MeshModel
from main import main as cli_main
from rbe2_duplicate_detector import annotate, duplicate_groups, index
from shell_topology import build
from washer_detector import validate_hole, validate_washer

SPEC=importlib.util.spec_from_file_location("washer_test_schema",str(Path(__file__).resolve().parents[1]/"python"/"schema.py")); MOD=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MOD)


def annulus(count=8,inner=(5.0,5.0),outer=(7.0,7.0),z_wave=0.0,missing=None):
    nodes={}; elements={}; nid=1
    rings=[]
    for rx,ry in (inner,outer):
        ring=[]
        for i in range(count):
            angle=2*math.pi*i/count; nodes[nid]=(rx*math.cos(angle),ry*math.sin(angle),z_wave*math.sin(2*angle)); ring.append(nid); nid+=1
        rings.append(ring)
    eid=1
    for i in range(count):
        if i==missing: continue
        j=(i+1)%count; elements[eid]=Element(eid,1,"CQUAD4",(rings[0][i],rings[0][j],rings[1][j],rings[1][i])); eid+=1
    return MeshModel({1:Component(1,"SHELL","SHELL")},nodes,elements),rings


class WasherTests(unittest.TestCase):
    def settings(self,**changes): value=dict(MOD.DEFAULTS); value.update(changes); return value
    def detect_inner(self,model):
        incidence,neighbors,element_nodes=build(model.elements.values()); loops=find(incidence); loop=min((row for row in loops if row["closed"]),key=lambda row:calculate(model,row["nodes"])["mean_radius"]); geom,reason=validate_hole(model,loop,self.settings()); self.assertEqual(reason,""); return loop,geom,validate_washer(model,loop,geom,incidence,neighbors,element_nodes,self.settings())
    def test_standard_circle_and_one_layer_washer(self):
        model,_=annulus(); loop,geom,(washer,reason)=self.detect_inner(model); self.assertEqual(reason,""); self.assertEqual(len(washer["dependent_node_ids"]),16)
    def test_multiple_holes_are_separate(self):
        model1,_=annulus(); model2,_=annulus(); offset=100; shifted={k+offset:(v[0]+20,v[1],v[2]) for k,v in model2.nodes.items()}; elems=dict(model1.elements); elems.update({k+offset:Element(k+offset,1,e.element_type,tuple(n+offset for n in e.node_ids)) for k,e in model2.elements.items()}); incidence,_,_=build(list(elems.values())); self.assertEqual(sum(row["closed"] for row in find(incidence)),4)
    def test_oval_hole(self):
        model,_=annulus(inner=(5,3),outer=(7,4.2)); incidence,_,_=build(model.elements.values()); loop=min(find(incidence),key=lambda r:calculate(model,r["nodes"])["mean_radius"]); geom,reason=validate_hole(model,loop,self.settings()); self.assertEqual(reason,""); self.assertEqual(geom["shape"],"oval")
    def test_nonplanar_loop_can_be_rejected_by_fit(self):
        model,_=annulus(z_wave=4); incidence,_,_=build(model.elements.values()); loop=min(find(incidence),key=lambda r:calculate(model,r["nodes"])["mean_radius"]); geom,reason=validate_hole(model,loop,self.settings(CIRCULARITY_TOL=0.01,ALLOW_OVAL_HOLES=False)); self.assertIsNone(geom)
    def test_open_free_edge(self):
        rows=find({(1,2):[1],(2,3):[2],(3,4):[3]}); self.assertEqual(len(rows),1); self.assertFalse(rows[0]["closed"])
    def test_branched_free_edge(self):
        rows=find({(1,2):[1],(2,3):[2],(2,4):[3]}); self.assertTrue(rows[0]["branched"])
    def test_too_few_nodes(self):
        model,_=annulus(count=4); incidence,_,_=build(model.elements.values()); loop=find(incidence)[0]; geom,reason=validate_hole(model,loop,self.settings()); self.assertEqual(reason,"TOO_FEW_EDGE_NODES")
    def test_incomplete_washer(self):
        model,_=annulus(missing=0); incidence,neighbors,nodes=build(model.elements.values()); loop={"nodes":list(range(1,9)),"edges":[[i,1 if i==8 else i+1] for i in range(1,9)],"closed":True,"branched":False}; geom=calculate(model,loop["nodes"]); geom["shape"]="circular"; washer,reason=validate_washer(model,loop,geom,incidence,neighbors,nodes,self.settings(WASHER_ELEM_COUNT_TOL=0.0)); self.assertIsNone(washer)
    def test_duplicate_rbe2(self):
        row={"dependent_node_ids":[1,2,3]}; annotate(row,index([{"element_id":9,"dependent_node_ids":[1,2,3]}])); self.assertEqual(row["existing_rbe2_id"],9)
    def test_different_node_set_not_duplicate(self):
        row={"dependent_node_ids":[1,2,4]}; annotate(row,index([{"element_id":9,"dependent_node_ids":[1,2,3]}])); self.assertIsNone(row["existing_rbe2_id"])
    def test_outer_loop_is_not_valid_washer_hole(self):
        model,_=annulus(); incidence,neighbors,nodes=build(model.elements.values()); loop=max(find(incidence),key=lambda r:calculate(model,r["nodes"])["mean_radius"]); geom,_=validate_hole(model,loop,self.settings()); washer,reason=validate_washer(model,loop,geom,incidence,neighbors,nodes,self.settings()); self.assertIsNone(washer); self.assertEqual(reason,"WASHER_WIDTH")
    def test_duplicate_group_plan(self):
        rows=[{"element_id":9,"dependent_node_ids":[1,2,3]},{"element_id":7,"dependent_node_ids":[3,2,1]}]; group=duplicate_groups(rows)[0]; self.assertEqual(group["keep_element_id"],7); self.assertEqual(group["delete_element_ids"],[9])


class IncrementalImportContractTests(unittest.TestCase):
    def source(self, relative_path):
        return (Path(__file__).resolve().parents[1] / relative_path).read_text(encoding="utf-8")

    def test_python_generates_rigid_delta_and_bridge_passes_it(self):
        main = self.source("python/main.py")
        bridge = self.source("tcl/bridge.tcl")
        exporter = self.source("tcl/exporter.tcl")
        self.assertIn("write_rigid_incremental_fem", main)
        self.assertIn('"delta"', main)
        self.assertIn("--delta", bridge)
        self.assertIn("incrementalModelStateJson", exporter)
        self.assertIn("rigid_import.fem", exporter)

    def test_tcl_prefers_verified_import_and_retains_legacy_fallback(self):
        executor = self.source("tcl/executor.tcl")
        self.assertIn("importRigidDelta", executor)
        self.assertIn("executePythonCandidatesLegacy", executor)
        self.assertIn("using legacy Tcl creation", executor)

    def test_cli_writes_importable_rigid_delta_and_manifest(self):
        model, _ = annulus()
        settings = dict(MOD.DEFAULTS)
        settings.update({"rigidType": "RBE2", "dof": "123456", "outputComponentName": "AUTO_RBE2_SHELL"})
        request = {
            "schema_version": "1.0", "module": "shell_washer_hole_rbe2",
            "run_id": "washer-integration", "hypermesh_version": "2019",
            "selected_component_ids": [1], "settings": settings,
            "id_state": {"max_node_id": max(model.nodes), "max_element_id": max(model.elements), "max_component_id": 1},
            "entity_registry": {"components": {}, "properties": {}, "materials": {}},
            "options": {"debug": False, "keep_runtime_files": True},
        }
        mesh = {
            "schema_version": "1.0",
            "components": [{"component_id": 1, "component_name": "SHELL", "mesh_class": "SHELL"}],
            "nodes": [[node_id, *xyz] for node_id, xyz in model.nodes.items()],
            "elements": [{"element_id": element.element_id, "component_id": 1, "element_type": element.element_type, "node_ids": list(element.node_ids)} for element in model.elements.values()],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = {name: root / name for name in ("request.json", "mesh.json", "existing.json", "rigids.fem", "result.json", "result.tcl", "operation.log")}
            paths["request.json"].write_text(json.dumps(request), encoding="utf-8")
            paths["mesh.json"].write_text(json.dumps(mesh), encoding="utf-8")
            paths["existing.json"].write_text(json.dumps({"rbe2": []}), encoding="utf-8")
            code = cli_main(["--request", str(paths["request.json"]), "--mesh", str(paths["mesh.json"]), "--existing", str(paths["existing.json"]), "--delta", str(paths["rigids.fem"]), "--output", str(paths["result.json"]), "--tcl-output", str(paths["result.tcl"]), "--log", str(paths["operation.log"])])
            self.assertEqual(code, 0)
            result = json.loads(paths["result.json"].read_text(encoding="utf-8"))
            self.assertGreater(result["summary"]["planned_create_count"], 0)
            self.assertIn("RBE2,", paths["rigids.fem"].read_text(encoding="utf-8"))

    def test_cli_batches_selected_components_into_distinct_output_collectors(self):
        model1, _ = annulus()
        model2, _ = annulus()
        node_offset, element_offset = 100, 100
        nodes = dict(model1.nodes)
        nodes.update({node_id + node_offset: (xyz[0] + 25.0, xyz[1], xyz[2]) for node_id, xyz in model2.nodes.items()})
        elements = dict(model1.elements)
        elements.update({
            element_id + element_offset: Element(
                element_id + element_offset,
                2,
                element.element_type,
                tuple(node_id + node_offset for node_id in element.node_ids),
            )
            for element_id, element in model2.elements.items()
        })
        model = MeshModel(
            {1: Component(1, "SHELL_A", "SHELL"), 2: Component(2, "SHELL_B", "SHELL")},
            nodes,
            elements,
        )
        settings = dict(MOD.DEFAULTS)
        settings.update({
            "rigidType": "RBE2",
            "dof": "123456",
            "outputComponentNames": {"1": "AUTO_RBE2_SHELL_A", "2": "AUTO_RBE2_SHELL_B"},
        })
        request = {
            "schema_version": "1.0", "module": "shell_washer_hole_rbe2",
            "run_id": "washer-batch-integration", "hypermesh_version": "2019",
            "selected_component_ids": [1, 2], "settings": settings,
            "id_state": {"max_node_id": max(model.nodes), "max_element_id": max(model.elements), "max_component_id": 2},
            "entity_registry": {"components": {}, "properties": {}, "materials": {}},
            "options": {"debug": False, "keep_runtime_files": True},
        }
        mesh = {
            "schema_version": "1.0",
            "components": [
                {"component_id": 1, "component_name": "SHELL_A", "mesh_class": "SHELL"},
                {"component_id": 2, "component_name": "SHELL_B", "mesh_class": "SHELL"},
            ],
            "nodes": [[node_id, *xyz] for node_id, xyz in model.nodes.items()],
            "elements": [{
                "element_id": element.element_id,
                "component_id": element.component_id,
                "element_type": element.element_type,
                "node_ids": list(element.node_ids),
            } for element in model.elements.values()],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = {name: root / name for name in ("request.json", "mesh.json", "existing.json", "rigids.fem", "result.json", "result.tcl", "operation.log")}
            paths["request.json"].write_text(json.dumps(request), encoding="utf-8")
            paths["mesh.json"].write_text(json.dumps(mesh), encoding="utf-8")
            paths["existing.json"].write_text(json.dumps({"rbe2": []}), encoding="utf-8")
            code = cli_main(["--request", str(paths["request.json"]), "--mesh", str(paths["mesh.json"]), "--existing", str(paths["existing.json"]), "--delta", str(paths["rigids.fem"]), "--output", str(paths["result.json"]), "--tcl-output", str(paths["result.tcl"]), "--log", str(paths["operation.log"])])
            self.assertEqual(code, 0)
            result = json.loads(paths["result.json"].read_text(encoding="utf-8"))
            self.assertEqual(result["summary"]["planned_create_count"], 2)
            self.assertEqual(
                {row["source_component_id"] for row in result["candidates"]},
                {1, 2},
            )
            delta = paths["rigids.fem"].read_text(encoding="utf-8")
            self.assertIn('"AUTO_RBE2_SHELL_A"', delta)
            self.assertIn('"AUTO_RBE2_SHELL_B"', delta)
            generated_components = {row["generated_component_id"] for row in result["candidates"]}
            self.assertEqual(len(generated_components), 2)

    def test_tcl_workflow_invokes_python_once_for_all_eligible_components(self):
        workflow = self.source("tcl/workflow.tcl")
        bridge = self.source("tcl/bridge.tcl")
        exporter = self.source("tcl/exporter.tcl")
        module = self.source("../shell_washer_hole_rbe2.tcl")
        self.assertIn("proc ::RB2W::processComponents {compIds}", workflow)
        self.assertIn("runPythonRecognition $compIds", workflow)
        self.assertIn("proc ::RB2W::runPythonRecognition {compIds", bridge)
        self.assertIn("exportHybridInputs $taskDir $runId $compIds", bridge)
        self.assertIn("selected_component_ids", exporter)
        self.assertIn("set result [RB2W::processComponents $eligibleComps]", module)
        self.assertNotIn("set result [RB2W::processComponent $c", module)


class UnusedRBE2CleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source_path = Path(__file__).resolve().parents[2] / "shell_washer_hole_rbe2.tcl"
        cls.interp = tkinter.Tcl()
        cls.interp.eval("source {%s}" % cls.source_path.as_posix())

    def test_only_center_nodes_without_any_other_element_are_unused(self):
        result = self.interp.eval(
            "set rows [list "
            "[dict create eid 10 center 100] "
            "[dict create eid 20 center 200] "
            "[dict create eid 30 center 300]]; "
            "set incidence [dict create "
            "100 {10} "
            "200 {20 99} "
            "300 {30 31}]; "
            "::RB2W::unusedRBE2IdsFromIncidence $rows $incidence"
        )
        self.assertEqual(self.interp.splitlist(result), ("10",))

    def test_unknown_center_or_incidence_is_never_a_delete_candidate(self):
        result = self.interp.eval(
            "set rows [list "
            "[dict create eid 10 center {}] "
            "[dict create eid 20 center 200]]; "
            "set incidence [dict create]; "
            "::RB2W::unusedRBE2IdsFromIncidence $rows $incidence"
        )
        self.assertEqual(self.interp.splitlist(result), ())

    def test_cleanup_is_exposed_only_from_shell_rbe2_subpage(self):
        shell_source = self.source_path.read_text(encoding="utf-8")
        bolt_source = (self.source_path.parent / "rbe2_bolt_connector.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'button $w.btn.unused -text [::HWFlow::txt "检测未使用 RBE2"',
            shell_source,
        )
        self.assertIn("::RB2W::elementIncidenceForNode", shell_source)
        self.assertIn("::RB2W::queueUnusedRBE2DeletePanel", shell_source)
        self.assertNotIn("button $w.btn.unused", bolt_source)

    def test_settings_window_closes_before_cleanup_and_progress_closes_before_delete(self):
        source = self.source_path.read_text(encoding="utf-8")
        dialog_start = source.index("proc ::RB2W::showPanel")
        dialog_end = source.index("\nproc ::RB2W::pickComponents", dialog_start)
        dialog = source[dialog_start:dialog_end]
        self.assertIn('-command "::RB2W::requestUnusedRBE2Cleanup"', dialog)
        self.assertNotIn('-command "::RB2W::runFindUnusedRBE2FromSettings"', dialog)

        request_start = source.index("proc ::RB2W::requestUnusedRBE2Cleanup")
        request_end = source.index("\nproc ", request_start + 5)
        request = source[request_start:request_end]
        self.assertIn("set ui(action) find_unused_rbe2", request)
        self.assertIn("destroy .rb2w_panel", request)

        settings_start = source.index("proc ::RB2W::runSettings")
        settings_end = source.index("\nforeach hybridFile", settings_start)
        settings = source[settings_start:settings_end]
        self.assertLess(settings.index("::RB2W::showPanel 1"), settings.index("::RB2W::runFindUnusedRBE2FromSettings"))

        cleanup_start = source.index("proc ::RB2W::runFindUnusedRBE2FromSettings")
        cleanup_end = source.index("\nproc ", cleanup_start + 5)
        cleanup = source[cleanup_start:cleanup_end]
        self.assertIn("::HWFlow::progressOpen", cleanup)
        self.assertLess(cleanup.rindex("::HWFlow::progressClose"), cleanup.index("RB2W::queueUnusedRBE2DeletePanel"))

    def test_delete_panel_handoff_is_deferred_and_rebuilds_marks(self):
        source = self.source_path.read_text(encoding="utf-8")
        queue_start = source.index("proc ::RB2W::queueUnusedRBE2DeletePanel")
        queue_end = source.index("\nproc ", queue_start + 5)
        queue = source[queue_start:queue_end]
        self.assertIn("after idle ::RB2W::openPendingUnusedRBE2DeletePanel", queue)

        open_start = source.index("proc ::RB2W::openPendingUnusedRBE2DeletePanel")
        open_end = source.index("\nproc ", open_start + 5)
        open_pending = source[open_start:open_end]
        self.assertLess(
            open_pending.index("RB2W::markUnusedRBE2ForDelete"),
            open_pending.index("hm_callpanel"),
        )
        self.assertIn(
            "after idle [list ::RB2W::restoreUnusedRBE2DeleteMark $elemIds]",
            open_pending,
        )
        self.assertIn("*marktousermark", source[source.index("proc ::RB2W::markUnusedRBE2ForDelete"):open_start])

    def test_solver_ids_are_resolved_through_hm_id_pools_before_marking(self):
        interp = tkinter.Tcl()
        interp.eval("source {%s}" % self.source_path.as_posix())
        interp.eval(
            "proc hm_getidpools {entityType returnType} {return {RIGID_IDPOOL}}; "
            "proc hm_getinternalid {pool solverId searchType} {"
            "if {$solverId == 100} {return 501}; "
            "if {$solverId == 200} {return 502}; "
            "error {not found}}; "
            "rename ::RB2W::elemIsRBE2 ::RB2W::elemIsRBE2_original; "
            "proc ::RB2W::elemIsRBE2 {eid} {expr {$eid == 501 || $eid == 502}}"
        )
        result = interp.eval("::RB2W::resolveUnusedRBE2InternalIds {100 200 999}")
        self.assertEqual(interp.splitlist(interp.eval("dict get {%s} internal_ids" % result)), ("501", "502"))
        self.assertEqual(interp.splitlist(interp.eval("dict get {%s} unresolved_solver_ids" % result)), ("999",))

    def test_pool_resolution_does_not_depend_on_rbe2_card_query(self):
        interp = tkinter.Tcl()
        interp.eval("source {%s}" % self.source_path.as_posix())
        interp.eval(
            "proc hm_getidpools {entityType returnType} {return {ELEMENT_IDPOOL}}; "
            "proc hm_getinternalid {pool solverId searchType} {"
            "if {$solverId == 100} {return 501}; error {not found}}; "
            "rename ::RB2W::elemIsRBE2 ::RB2W::elemIsRBE2_original; "
            "proc ::RB2W::elemIsRBE2 {eid} {return 0}; "
            "rename ::RB2W::markRigidLinkCandidates ::RB2W::markRigidLinkCandidates_original; "
            "proc ::RB2W::markRigidLinkCandidates {markId} {"
            "error {fallback scan must not be needed after an exact pool lookup}}"
        )
        result = interp.eval("::RB2W::resolveUnusedRBE2InternalIds {100}")
        self.assertEqual(
            interp.splitlist(interp.eval("dict get {%s} internal_ids" % result)),
            ("501",),
        )
        self.assertEqual(
            interp.splitlist(interp.eval("dict get {%s} unresolved_solver_ids" % result)),
            (),
        )

    def test_solver_id_resolution_falls_back_to_database_rbe2_records(self):
        interp = tkinter.Tcl()
        interp.eval("source {%s}" % self.source_path.as_posix())
        interp.eval(
            "proc hm_getidpools {args} {error {pool API unavailable}}; "
            "proc hm_getinternalid {args} {error {pool API unavailable}}; "
            "proc hm_getsolverid {entityType internalId searchType} {"
            "if {$internalId == 701} {return {300 RIGID_IDPOOL}}; "
            "if {$internalId == 702} {return {400 RIGID_IDPOOL}}; "
            "error {not found}}; "
            "rename ::RB2W::markRigidLinkCandidates ::RB2W::markRigidLinkCandidates_original; "
            "proc ::RB2W::markRigidLinkCandidates {markId} {return {1 {701 702} {by config 55}}}"
        )
        result = interp.eval("::RB2W::resolveUnusedRBE2InternalIds {300 999}")
        self.assertEqual(interp.splitlist(interp.eval("dict get {%s} internal_ids" % result)), ("701",))
        self.assertEqual(interp.splitlist(interp.eval("dict get {%s} unresolved_solver_ids" % result)), ("999",))

    def test_solver_id_resolution_scans_all_elements_when_rigid_mark_filter_is_unavailable(self):
        interp = tkinter.Tcl()
        interp.eval("source {%s}" % self.source_path.as_posix())
        interp.eval(
            "proc hm_getidpools {args} {error {pool API unavailable}}; "
            "proc hm_getinternalid {args} {error {pool API unavailable}}; "
            "proc hm_getsolverid {entityType internalId searchType} {"
            "if {$internalId == 901} {return {700 SHELL_IDPOOL}}; "
            "if {$internalId == 902} {return {300 RIGID_IDPOOL}}; "
            "error {not found}}; "
            "rename ::RB2W::elemIsRBE2 ::RB2W::elemIsRBE2_original; "
            "proc ::RB2W::elemIsRBE2 {eid} {return 0}; "
            "rename ::RB2W::markRigidLinkCandidates ::RB2W::markRigidLinkCandidates_original; "
            "proc ::RB2W::markRigidLinkCandidates {markId} {return {0 {} {}}}; "
            "set ::elementMark {}; "
            "proc *createmark {entityType markId args} {"
            "if {[lindex $args 0] eq {all}} {set ::elementMark {901 902}; return}; "
            "if {[lindex $args 0] eq {by id only}} {set args [lrange $args 1 end]}; "
            "set ::elementMark $args}; "
            "proc *clearmark {args} {set ::elementMark {}}; "
            "proc *marktousermark {args} {}; "
            "proc hm_getmark {entityType markId} {return $::elementMark}"
        )
        result = interp.eval("::RB2W::resolveUnusedRBE2InternalIds {300}")
        self.assertEqual(
            interp.splitlist(interp.eval("dict get {%s} internal_ids" % result)),
            ("902",),
        )
        self.assertEqual(
            interp.splitlist(interp.eval("dict get {%s} unresolved_solver_ids" % result)),
            (),
        )
        self.assertEqual(interp.eval("::RB2W::markUnusedRBE2ForDelete {300}"), "elems")
        self.assertEqual(interp.splitlist(interp.eval("hm_getmark elems 1")), ("902",))

    def test_equal_solver_and_internal_ids_do_not_scan_all_rbe2(self):
        interp = tkinter.Tcl()
        interp.eval("source {%s}" % self.source_path.as_posix())
        interp.eval(
            "proc hm_getidpools {args} {return {}}; "
            "rename ::RB2W::elemIsRBE2 ::RB2W::elemIsRBE2_original; "
            "proc ::RB2W::elemIsRBE2 {eid} {expr {$eid == 801}}; "
            "rename ::RB2W::markRigidLinkCandidates ::RB2W::markRigidLinkCandidates_original; "
            "proc ::RB2W::markRigidLinkCandidates {markId} {error {full RBE2 scan must not run}}"
        )
        result = interp.eval("::RB2W::resolveUnusedRBE2InternalIds {801}")
        self.assertEqual(interp.splitlist(interp.eval("dict get {%s} internal_ids" % result)), ("801",))


if __name__=="__main__": unittest.main()
