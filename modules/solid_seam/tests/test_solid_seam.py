import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from hmworkflow.solid_seam.edge_chain_builder import build_chains
from hmworkflow.solid_seam.duplicate_detector import classify as classify_duplicate
from hmworkflow.solid_seam.joint_classifier import classify as classify_joint
from hmworkflow.solid_seam.fem_mesh_reader import read_fem
from hmworkflow.solid_seam.main import classify_workflow, component_pairs, detect, main as cli_main
from hmworkflow.solid_seam.mesh_reader import read_mesh
from hmworkflow.solid_seam.schema import validate_request
from hmworkflow.solid_seam.solid_edge_extractor import extract_candidate_edges
from hmworkflow.solid_seam.solid_surface_extractor import extract_surface_faces
from hmworkflow.solid_seam.result_writer import write_tcl
from hmworkflow.solid_seam.realization_parameter_selector import select as select_realization_parameters
from hmworkflow.solid_seam.schema import Element, MeshModel, Component


def cube_mesh(shell=True):
    nodes = [
        {"node_id": i + 1, "xyz": xyz}
        for i, xyz in enumerate([(0, 0, 0), (10, 0, 0), (10, 10, 0), (0, 10, 0), (0, 0, 10), (10, 0, 10), (10, 10, 10), (0, 10, 10)])
    ]
    components = [{"component_id": 10, "component_name": "CASTING", "mesh_class": "SOLID"}]
    elements = [{"element_id": 100, "component_id": 10, "element_type": "CHEXA", "node_ids": list(range(1, 9))}]
    if shell:
        components.append({"component_id": 20, "component_name": "SHELL", "mesh_class": "SHELL"})
        nodes += [{"node_id": 21, "xyz": [0, -2, 0]}, {"node_id": 22, "xyz": [10, -2, 0]}, {"node_id": 23, "xyz": [10, -2, 10]}, {"node_id": 24, "xyz": [0, -2, 10]}]
        elements.append({"element_id": 200, "component_id": 20, "element_type": "CQUAD4", "node_ids": [21, 22, 23, 24]})
    return {"schema_version": "1.0", "components": components, "nodes": nodes, "elements": elements, "existing_connectors": []}


class SolidSeamTests(unittest.TestCase):
    def write_mesh(self, payload):
        handle = tempfile.NamedTemporaryFile("w", suffix=".json", encoding="utf-8", delete=False)
        json.dump(payload, handle)
        handle.close()
        self.addCleanup(lambda: Path(handle.name).unlink(missing_ok=True))
        return read_mesh(Path(handle.name))

    def test_supported_solid_surface_counts(self):
        cases = {
            "CTETRA": (4, [(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)]),
            "CPYRA": (5, [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0), (0.5, 0.5, 1)]),
            "CPENTA": (5, [(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 0, 1), (0, 1, 1)]),
            "CHEXA": (6, [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0), (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]),
        }
        for element_type, (count, xyz) in cases.items():
            payload = {"schema_version": "1.0", "components": [{"component_id": 1, "component_name": "S", "mesh_class": "SOLID"}], "nodes": [{"node_id": i + 1, "xyz": p} for i, p in enumerate(xyz)], "elements": [{"element_id": 1, "component_id": 1, "element_type": element_type, "node_ids": list(range(1, len(xyz) + 1))}], "existing_connectors": []}
            faces, warnings = extract_surface_faces(self.write_mesh(payload), 1)
            self.assertEqual(count, len(faces))
            self.assertEqual([], warnings)

    def test_cube_feature_edges(self):
        model = self.write_mesh(cube_mesh(False))
        faces, _ = extract_surface_faces(model, 10)
        self.assertEqual(12, len(extract_candidate_edges(model, faces, 35.0)))

    def test_pair_rules_never_add_multiselect_solid_pairs(self):
        request = {"mode": "MULTI_SOLID_SHELL", "solid_component_ids": [1, 2], "shell_component_ids": [3, 4]}
        self.assertEqual([(1, 3), (1, 4), (2, 3), (2, 4)], component_pairs(request))

    def test_native_fem_is_classified_by_python(self):
        fem = """$HMNAME COMP                  10\"SOLID_A\"\n$HMNAME COMP                  20\"SHELL_B\"\nBEGIN BULK\nGRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\nGRID,3,,0.,1.,0.\nGRID,4,,0.,0.,1.\nGRID,5,,2.,0.,0.\nCTETRA,100,10,1,2,3,4\nCTRIA3,200,20,2,5,3\nENDDATA\n"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "selection.fem"
            path.write_text(fem, encoding="utf-8")
            model = read_fem(path)
        self.assertEqual("SOLID", model.components[10].mesh_class)
        self.assertEqual("SHELL", model.components[20].mesh_class)
        self.assertEqual("SOLID_A", model.components[10].component_name)

    def test_per_component_fem_override_ignores_solver_property_id(self):
        fem = """$HMNAME COMP                  10\"SOLID_A\"\nBEGIN BULK\nGRID,1,,0.,0.,0.\nGRID,2,,1.,0.,0.\nGRID,3,,0.,1.,0.\nGRID,4,,0.,0.,1.\nCTETRA,100,999,1,2,3,4\nENDDATA\n"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "component_10.fem"
            path.write_text(fem, encoding="utf-8")
            model = read_fem(path, component_id=10)
        self.assertEqual({10}, set(model.components))
        self.assertEqual(10, model.elements[0].component_id)

    def test_two_solid_selection_is_direct_and_preserves_source_order(self):
        model = MeshModel(
            {1: Component(1, "FIRST", "SOLID"), 2: Component(2, "SECOND", "SOLID")},
            {}, [], [],
        )
        request = validate_request({"schema_version": "1.0", "run_id": "x", "selected_component_ids": [1, 2], "primary_component_ids": [1], "secondary_component_ids": [2], "settings": {}})
        classified = classify_workflow(request, model)
        self.assertEqual("SOLID_SOLID_PAIR", classified["mode"])
        self.assertFalse(classified["requires_review"])
        self.assertEqual([(1, 2)], component_pairs(classified))

    def test_two_shell_selection_is_direct(self):
        model = MeshModel(
            {1: Component(1, "FIRST", "SHELL"), 2: Component(2, "SECOND", "SHELL")},
            {}, [], [],
        )
        request = validate_request({"schema_version": "1.0", "run_id": "x", "selected_component_ids": [1, 2], "primary_component_ids": [1], "secondary_component_ids": [2], "settings": {}})
        classified = classify_workflow(request, model)
        self.assertEqual("SHELL_SHELL_PAIR", classified["mode"])
        self.assertFalse(classified["requires_review"])
        self.assertEqual([(1, 2)], component_pairs(classified))

    def test_two_shells_detect_source_boundary_nodes(self):
        payload = {
            "schema_version": "1.0",
            "components": [
                {"component_id": 1, "component_name": "SOURCE", "mesh_class": "SHELL"},
                {"component_id": 2, "component_name": "TARGET", "mesh_class": "SHELL"},
            ],
            "nodes": [
                {"node_id": 1, "xyz": [0, 0, 0]}, {"node_id": 2, "xyz": [10, 0, 0]},
                {"node_id": 3, "xyz": [10, 10, 0]}, {"node_id": 4, "xyz": [0, 10, 0]},
                {"node_id": 11, "xyz": [0, -2, 0]}, {"node_id": 12, "xyz": [10, -2, 0]},
                {"node_id": 13, "xyz": [10, -12, 0]}, {"node_id": 14, "xyz": [0, -12, 0]},
            ],
            "elements": [
                {"element_id": 1, "component_id": 1, "element_type": "CQUAD4", "node_ids": [1, 2, 3, 4]},
                {"element_id": 2, "component_id": 2, "element_type": "CQUAD4", "node_ids": [11, 12, 13, 14]},
            ],
            "existing_connectors": [],
        }
        model = self.write_mesh(payload)
        settings = {"search_distance": 3.0, "max_search_distance": 5.0, "min_weld_length": 5.0, "min_valid_ratio": 0.7, "feature_angle_deg": 35.0, "max_chain_turn_angle_deg": 60.0, "gap_jump_limit": 1.0, "allow_closed_loop": True, "retain_short_candidates": False, "detect_duplicates": True, "high_confidence_threshold": 0.85, "review_confidence_threshold": 0.6}
        request = {"mode": "SHELL_SHELL_PAIR", "source_component_ids": [1], "target_component_ids": [2], "solid_component_ids": [], "shell_component_ids": [1, 2], "settings": settings}
        candidates = detect(request, model, __import__("logging").getLogger("test"))
        self.assertTrue(candidates)
        self.assertTrue(all(set(candidate["node_ids"]).issubset({1, 2, 3, 4}) for candidate in candidates))

    def test_mixed_selection_requires_review_and_a_solid(self):
        model = MeshModel(
            {1: Component(1, "S1", "SOLID"), 2: Component(2, "H1", "SHELL"), 3: Component(3, "H2", "SHELL")},
            {}, [], [],
        )
        request = validate_request({"schema_version": "1.0", "run_id": "x", "selected_component_ids": [1, 2, 3], "primary_component_ids": [1, 2, 3], "secondary_component_ids": [], "settings": {}})
        classified = classify_workflow(request, model)
        self.assertEqual("MIXED_COMPONENTS", classified["mode"])
        self.assertTrue(classified["requires_review"])
        self.assertEqual([(1, 2), (1, 3)], component_pairs(classified))

    def test_integration_detects_nearby_cube_edges(self):
        model = self.write_mesh(cube_mesh())
        request = validate_request({"schema_version": "1.0", "run_id": "test", "mode": "SOLID_SHELL_PAIR", "selected_component_ids": [10, 20], "solid_component_ids": [10], "shell_component_ids": [20], "settings": {"search_distance": 3.0, "max_search_distance": 5.0, "min_weld_length": 5.0, "min_valid_ratio": 0.7, "feature_angle_deg": 35.0, "max_chain_turn_angle_deg": 60.0, "gap_jump_limit": 1.0, "allow_closed_loop": True, "retain_short_candidates": False, "detect_duplicates": True, "high_confidence_threshold": 0.85, "review_confidence_threshold": 0.6}})
        import logging
        candidates = detect(request, model, logging.getLogger("test"))
        self.assertGreaterEqual(len(candidates), 1)
        self.assertTrue(all(c["target_component"]["component_id"] == 20 for c in candidates))
        self.assertTrue(all(len(c["node_ids"]) >= 2 for c in candidates))
        self.assertTrue(all(c["realization_parameters"]["line_spacing"] > 0.0 for c in candidates))

    def test_adaptive_realization_parameters_match_plate_geometry(self):
        nodes = {
            1: (0, 0, 0), 2: (10, 0, 0), 3: (20, 0, 0), 4: (30, 0, 0), 5: (40, 0, 0),
            6: (50, 0, 0), 7: (60, 0, 0), 8: (70, 0, 0), 9: (80, 0, 0),
            10: (0, 10, 0), 11: (80, 10, 0), 12: (0, 0, 40), 13: (80, 0, 40),
            14: (0, 10, 40), 15: (80, 10, 40),
        }
        model = MeshModel(
            {101: Component(101, "PLATE", "SOLID")}, nodes,
            [Element(1, 101, "CHEXA", tuple(nodes))], [],
        )
        edge = type("Edge", (), {"face_normals": ((0.0, 1.0, 0.0),)})()
        item = type("Item", (), {"edge": edge, "target_normals": ((0.0, 0.0, 1.0),), "maximum_distance": 5.0})()
        chain = {"node_ids": list(range(1, 10)), "items": [item], "is_closed": False}
        oriented, parameters = select_realization_parameters(model, 101, chain, {"max_search_distance": 25.0}, "T_JOINT")
        self.assertEqual(list(range(1, 10)), oriented)
        self.assertEqual(10.0, parameters["mesh_size"])
        self.assertEqual(10.0, parameters["source_thickness"])
        self.assertEqual(5.0, parameters["line_spacing"])
        self.assertEqual(6.0, parameters["weld_width"])
        self.assertEqual(15.0, parameters["realization_tolerance"])
        self.assertFalse(parameters["right_angled"])
        self.assertFalse(parameters["orientation_reversed"])

        reverse_chain = dict(chain, node_ids=list(range(9, 0, -1)))
        reversed_nodes, reversed_parameters = select_realization_parameters(model, 101, reverse_chain, {"max_search_distance": 25.0}, "T_JOINT")
        self.assertEqual(list(range(1, 10)), reversed_nodes)
        self.assertTrue(reversed_parameters["orientation_reversed"])

    def test_duplicate_connector_is_confirmed(self):
        candidate = {"source_solid": {"component_id": 1}, "target_component": {"component_id": 2}, "node_ids": [10, 11, 12]}
        existing = [{"linked_component_ids": [1, 2], "location_node_ids": [10, 11, 12]}]
        self.assertEqual("CONFIRMED", classify_duplicate(candidate, existing, []))

    def test_joint_classifier_maps_t_lap_angled_and_unknown(self):
        class Edge:
            pass
        class Item:
            pass
        def chain(source, target, boundary=0.0):
            edge = Edge(); edge.face_normals = source
            item = Item(); item.edge = edge; item.target_normals = target; item.target_boundary_ratio = boundary
            return {"items": [item]}
        self.assertEqual("T_JOINT", classify_joint(chain([(1, 0, 0)], [(0, 1, 0)]))[0])
        self.assertEqual("LAP_JOINT", classify_joint(chain([(1, 0, 0)], [(1, 0, 0)]))[0])
        self.assertEqual("BUTT_JOINT", classify_joint(chain([(1, 0, 0)], [(1, 0, 0)], 1.0))[0])
        self.assertEqual("ANGLED_JOINT", classify_joint(chain([(1, 0, 0)], [(0.866, 0.5, 0)]))[0])
        self.assertEqual("UNKNOWN", classify_joint(chain([], []))[0])

    def test_invalid_multiselect_mode_is_rejected(self):
        with self.assertRaises(ValueError):
            validate_request({"schema_version": "1.0", "run_id": "x", "mode": "MULTI_SOLID_SHELL", "selected_component_ids": [1, 2, 3], "solid_component_ids": [1, 2, 3], "shell_component_ids": [], "settings": {}})

    def test_closed_edge_loop_is_one_chain(self):
        class Edge:
            def __init__(self, a, b):
                self.node_ids = (a, b)
                self.length = 10.0
        class Detected:
            def __init__(self, a, b):
                self.edge = Edge(a, b)
        model = type("Model", (), {"nodes": {1: (0, 0, 0), 2: (10, 0, 0), 3: (10, 10, 0), 4: (0, 10, 0)}})()
        settings = {"max_chain_turn_angle_deg": 100.0, "min_weld_length": 1.0, "retain_short_candidates": False}
        chains = build_chains(model, [Detected(1, 2), Detected(2, 3), Detected(3, 4), Detected(4, 1)], settings)
        self.assertEqual(1, len(chains))
        self.assertTrue(chains[0]["is_closed"])
        self.assertEqual({1, 2, 3, 4}, set(chains[0]["node_ids"]))

    def test_tcl_sidecar_escapes_names(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "candidates.tcl"
            write_tcl(path, [{"candidate_id": "C0001", "status": "PENDING", "connection_mode": "SOLID_SHELL", "edge_class": "SOLID_FEATURE_EDGE", "joint_type": "T_JOINT", "suggested_realization": "PENTA_MIG_T", "length": 1.0, "average_distance": 0.1, "maximum_distance": 0.2, "valid_ratio": 1.0, "confidence": 0.9, "confidence_level": "HIGH", "duplicate_state": "NONE", "is_closed": False, "source_solid": {"component_id": 1, "component_name": "A {cast}"}, "target_component": {"component_id": 2, "component_name": "B\\shell"}, "node_ids": [1, 2], "warnings": []}])
            text = path.read_text(encoding="utf-8")
            self.assertIn("set ::SolidSeam::candidateRows", text)
            self.assertIn('"A {cast}"', text)
            self.assertIn('"B\\\\shell"', text)

    def test_cli_writes_versioned_json_and_tcl_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mesh_path, request_path = root / "mesh.json", root / "request.json"
            mesh_path.write_text(json.dumps(cube_mesh()), encoding="utf-8")
            request = {"schema_version": "1.0", "run_id": "cli_test", "mode": "SOLID_SHELL_PAIR", "selected_component_ids": [10, 20], "solid_component_ids": [10], "shell_component_ids": [20], "settings": {"search_distance": 3.0, "max_search_distance": 5.0, "min_weld_length": 5.0, "min_valid_ratio": 0.7, "feature_angle_deg": 35.0, "max_chain_turn_angle_deg": 60.0, "gap_jump_limit": 1.0, "allow_closed_loop": True, "retain_short_candidates": False, "detect_duplicates": True, "high_confidence_threshold": 0.85, "review_confidence_threshold": 0.6}}
            request_path.write_text(json.dumps(request), encoding="utf-8")
            output, sidecar, log = root / "candidates.json", root / "candidates.tcl", root / "operation.log"
            code = cli_main(["--request", str(request_path), "--mesh", str(mesh_path), "--output", str(output), "--tcl-output", str(sidecar), "--log", str(log)])
            self.assertEqual(0, code)
            self.assertEqual("1.0", json.loads(output.read_text(encoding="utf-8"))["schema_version"])
            self.assertTrue(sidecar.is_file())
            self.assertTrue(log.is_file())
            binary = root / "candidates.hmwfr"
            code = cli_main(["--request", str(request_path), "--mesh", str(mesh_path), "--output", str(output), "--tcl-output", str(binary), "--log", str(log)])
            self.assertEqual(0, code)
            self.assertEqual(b"HMWFR1\x00\x00", binary.read_bytes()[:8])

    def test_cli_merges_per_component_fems_and_returns_workflow_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "component_1.fem"
            second = root / "component_2.fem"
            first.write_text("BEGIN BULK\nGRID,1,,0.,0.,0.\nGRID,2,,10.,0.,0.\nGRID,3,,10.,10.,0.\nGRID,4,,0.,10.,0.\nCQUAD4,1,101,1,2,3,4\nENDDATA\n", encoding="utf-8")
            second.write_text("BEGIN BULK\nGRID,11,,0.,-2.,0.\nGRID,12,,10.,-2.,0.\nGRID,13,,10.,-12.,0.\nGRID,14,,0.,-12.,0.\nCQUAD4,2,202,11,12,13,14\nENDDATA\n", encoding="utf-8")
            settings = {"search_distance": 3.0, "max_search_distance": 5.0, "min_weld_length": 5.0, "min_valid_ratio": 0.7, "feature_angle_deg": 35.0, "max_chain_turn_angle_deg": 60.0, "gap_jump_limit": 1.0, "allow_closed_loop": True, "retain_short_candidates": False, "detect_duplicates": True, "high_confidence_threshold": 0.85, "review_confidence_threshold": 0.6}
            request = root / "request.json"
            request.write_text(json.dumps({"schema_version": "1.0", "run_id": "fem_pair", "selected_component_ids": [1, 2], "primary_component_ids": [1], "secondary_component_ids": [2], "settings": settings}), encoding="utf-8")
            output, sidecar = root / "candidates.json", root / "candidates.tcl"
            code = cli_main(["--request", str(request), "--mesh", str(first), "--mesh", str(second), "--output", str(output), "--tcl-output", str(sidecar)])
            self.assertEqual(0, code)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual("SHELL_SHELL_PAIR", payload["mode"])
            self.assertFalse(payload["requires_review"])
            self.assertIn("set ::SolidSeam::requiresReview 0", sidecar.read_text(encoding="utf-8"))

    def test_direct_script_launch_finds_sibling_modules(self):
        """Match the isolated child-process launch used by HyperMesh Tcl."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mesh_path, request_path = root / "mesh.json", root / "request.json"
            mesh_path.write_text(json.dumps(cube_mesh()), encoding="utf-8")
            request = {"schema_version": "1.0", "run_id": "subprocess_test", "mode": "SOLID_SHELL_PAIR", "selected_component_ids": [10, 20], "solid_component_ids": [10], "shell_component_ids": [20], "settings": {"search_distance": 3.0, "max_search_distance": 5.0, "min_weld_length": 5.0, "min_valid_ratio": 0.7, "feature_angle_deg": 35.0, "max_chain_turn_angle_deg": 60.0, "gap_jump_limit": 1.0, "allow_closed_loop": True, "retain_short_candidates": False, "detect_duplicates": True, "high_confidence_threshold": 0.85, "review_confidence_threshold": 0.6}}
            request_path.write_text(json.dumps(request), encoding="utf-8")
            output, sidecar, log = root / "candidates.json", root / "candidates.tcl", root / "operation.log"
            completed = subprocess.run([sys.executable, str(ROOT / "python" / "main.py"), "--request", str(request_path), "--mesh", str(mesh_path), "--output", str(output), "--tcl-output", str(sidecar), "--log", str(log)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertNotIn("ModuleNotFoundError", completed.stderr)
            self.assertTrue(output.is_file())


if __name__ == "__main__":
    unittest.main()
