import importlib.util, json, math, tempfile, unittest
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


if __name__=="__main__": unittest.main()
