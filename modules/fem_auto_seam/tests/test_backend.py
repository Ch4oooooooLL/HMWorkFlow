from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "python"))

from hmworkflow.fem_auto_seam.backend import detect_candidates, plan_candidate_deltas, realize_candidates
from hmworkflow.fem_auto_seam.seam_neighborhood_optimizer import parse_criteria_metadata, parse_param_metadata
from hmworkflow.fem_auto_seam.delta_writer import write_shell_weld_delta
from hmworkflow.fem_auto_seam.main import _mark_duplicates
from hmworkflow.mesh_seam_weld.weld_strip_planner import plan_zipper


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


EXAMPLE_DIR = ROOT / "examples" / "AutoShellSeamBackend"
FIXTURES = _load("auto_seam_backend_fixtures", EXAMPLE_DIR / "generate_fixtures.py")
sys.path.insert(0, str(EXAMPLE_DIR))
RUNNER = _load("auto_seam_backend_runner", EXAMPLE_DIR / "run_backend.py")
PIPELINE = _load("auto_seam_stage2_pipeline", EXAMPLE_DIR / "prepare_stage2_pipeline.py")


class OfflineBackendTests(unittest.TestCase):
    def test_blank_specifications_use_built_in_optimizer_defaults(self):
        criteria = parse_criteria_metadata(None)
        param = parse_param_metadata("")
        self.assertIn("built-in defaults", criteria["authority"])
        self.assertIn("minimum_jacobian", criteria["quality_limits"])
        self.assertIn("built-in defaults", param["authority"])
        self.assertEqual("auto", param["values"]["element_size"])

        model, _ = FIXTURES.angled_t()
        candidates = [row for row in detect_candidates(model) if row["auto_eligible"]]
        planned = plan_candidate_deltas(
            model,
            candidates,
            {
                "id_state": {"max_node_id": 5000, "max_element_id": 8000, "max_component_id": 100},
                "optimize_neighborhood": True,
                "optimization_layers": 2,
                "optimization_iterations": 4,
            },
            None,
            None,
        )
        self.assertIn(planned["optimization"]["status"], ("OPTIMIZED", "NO_SAFE_MOVE"))
        self.assertIn("built-in defaults", planned["optimization"]["criteria"]["authority"])
        self.assertIn("built-in defaults", planned["optimization"]["param"]["authority"])

    def test_persistent_worker_loads_standalone_entry_without_schema_collision(self):
        with tempfile.TemporaryDirectory() as directory:
            task_dir = Path(directory)
            mesh_manifest = EXAMPLE_DIR / "test_fem" / "case_01_straight_t" / "input_manifest.json"
            request_path = task_dir / "request.json"
            existing_path = task_dir / "existing.json"
            output_path = task_dir / "result.hmwfr"
            request_path.write_text(json.dumps({
                "schema_version": "1.0",
                "module": "fem_auto_seam",
                "run_id": "PERSISTENT_IMPORT_REGRESSION",
                "hypermesh_version": "2019",
                "selected_component_ids": [1, 2],
                "settings": {
                    "mode": "detect",
                    "optimize_neighborhood": False,
                    "criteria_path": "",
                    "param_path": "",
                },
                "options": {"debug": False, "keep_runtime_files": True},
            }), encoding="utf-8")
            existing_path.write_text('{"schema_version":"1.0","seams":[]}\n', encoding="utf-8")
            entry = ROOT / "modules" / "fem_auto_seam" / "python" / "main.py"
            worker = ROOT / "modules" / "hybrid_core" / "python" / "persistent_worker.py"
            arguments = [
                "--request", str(request_path), "--mesh", str(mesh_manifest),
                "--existing", str(existing_path), "--output", str(output_path),
                "--tcl-output", str(output_path), "--log", str(task_dir / "operation.log"),
            ]
            payload = {
                "request_id": "fem-auto-seam-import-regression",
                "entry": str(entry),
                "arguments": arguments,
                "task_dir": str(task_dir),
            }
            process = subprocess.Popen(
                [sys.executable, "-u", str(worker), "--owner-pid", str(os.getpid()), "--instance-id", "fem-auto-seam-test"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8",
            )
            stdout, stderr = process.communicate(
                json.dumps(payload) + "\n" + json.dumps({"command": "shutdown"}) + "\n",
                timeout=30,
            )
            worker_stderr = (task_dir / "python_stderr.log").read_text(encoding="utf-8")
            self.assertEqual(0, process.returncode, stderr)
            self.assertIn("HYBRID\tfem-auto-seam-import-regression\tOK\t0", stdout)
            self.assertEqual("", worker_stderr)
            self.assertTrue(output_path.is_file())

    def test_versioned_acceptance_fems_are_ready_without_regeneration(self):
        fixture_root = EXAMPLE_DIR / "test_fem"
        cases = __import__("json").loads((fixture_root / "cases.json").read_text(encoding="utf-8"))
        self.assertEqual(10, len(cases))
        auto_case_count = 0
        review_case_count = 0
        for row in cases:
            manifest = Path(row["manifest"])
            # The generated index may contain an absolute or caller-relative
            # path; the versioned file location is authoritative in checkout.
            if not manifest.is_file():
                manifest = fixture_root / row["name"] / "input_manifest.json"
            model = __import__(
                "hmworkflow.mesh_seam_weld.fem_mesh_reader", fromlist=["read_shell_fem_bundle"]
            ).read_shell_fem_bundle(manifest)
            candidates = detect_candidates(model)
            if any(candidate.get("auto_eligible") for candidate in candidates):
                auto_case_count += 1
            if any(not candidate.get("auto_eligible") for candidate in candidates):
                review_case_count += 1
        self.assertGreaterEqual(auto_case_count, 7)
        self.assertGreaterEqual(review_case_count, 2)

    def test_combined_acceptance_fem_matches_individual_detection_without_cross_pairs(self):
        fixture_root = EXAMPLE_DIR / "test_fem"
        expected = Counter()
        expected_auto = Counter()
        for row in json.loads((fixture_root / "cases.json").read_text(encoding="utf-8")):
            model = __import__(
                "hmworkflow.mesh_seam_weld.fem_mesh_reader", fromlist=["read_shell_fem_bundle"]
            ).read_shell_fem_bundle(fixture_root / row["name"] / "input_manifest.json")
            for candidate in detect_candidates(model):
                expected[candidate["candidate_type"]] += 1
                if candidate["auto_eligible"]:
                    expected_auto[candidate["candidate_type"]] += 1

        combined = __import__(
            "hmworkflow.mesh_seam_weld.fem_mesh_reader", fromlist=["read_shell_fem_bundle"]
        ).read_shell_fem_bundle(fixture_root / "combined_all_cases_manifest.json")
        candidates = detect_candidates(combined)
        actual = Counter(row["candidate_type"] for row in candidates)
        actual_auto = Counter(row["candidate_type"] for row in candidates if row["auto_eligible"])
        self.assertEqual(expected, actual)
        self.assertEqual(expected_auto, actual_auto)

        mapping = json.loads((fixture_root / "combined_cases.json").read_text(encoding="utf-8"))
        owner = {
            component_id: row["case_name"]
            for row in mapping["cases"]
            for component_id in row["component_ids"]
        }
        self.assertTrue(all(
            owner[candidate["source_component_id"]] == owner[candidate["target_component_id"]]
            for candidate in candidates
        ))

    def test_production_pipeline_writes_importable_result_and_transfer_ledger(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = PIPELINE.prepare(Path(directory))
            for key in ("backend_result_fem", "backend_result_manifest", "transfer_manifest", "delta_manifest"):
                artifact = Path(manifest[key])
                self.assertTrue(artifact.is_file(), key)
                self.assertGreater(artifact.stat().st_size, 0, key)
            transfer = __import__("json").loads(Path(manifest["transfer_manifest"]).read_text(encoding="utf-8"))
            self.assertEqual("READY_FOR_HYPERMESH_IMPORT", transfer["status"])
            ready = [row for row in transfer["candidates"] if row["status"] == "READY"]
            self.assertTrue(ready)
            for row in ready:
                for key in ("candidate_type", "confidence", "source_component_id", "target_component_id", "delta_fem"):
                    self.assertIn(key, row)
                self.assertTrue(Path(row["delta_fem"]).is_file())

    def test_complete_generated_matrix_round_trips(self):
        with tempfile.TemporaryDirectory() as directory:
            report = RUNNER.run(Path(directory))
            self.assertEqual("PASS", report["status"])
            self.assertEqual(10, report["case_count"])
            self.assertEqual(10, report["passed_count"])

    def test_partial_overlap_and_multiple_targets_are_auto_candidates(self):
        model, _ = FIXTURES.partial_overlap_t()
        candidates = [row for row in detect_candidates(model) if row["candidate_type"] == "T_SEAM"]
        self.assertEqual(1, len(candidates))
        self.assertAlmostEqual(34.0, candidates[0]["length"], places=4)
        self.assertTrue(candidates[0]["auto_eligible"])

        model, _ = FIXTURES.four_target_t()
        candidates = [row for row in detect_candidates(model) if row["candidate_type"] == "T_SEAM"]
        self.assertEqual(4, len(candidates))
        self.assertEqual(4, len({row["target_component_id"] for row in candidates}))
        self.assertTrue(all(row["auto_eligible"] for row in candidates))

        model, _ = FIXTURES.multi_target_same_edge()
        candidates = [row for row in detect_candidates(model) if row["candidate_type"] == "T_SEAM"]
        grouped = {}
        for row in candidates:
            grouped.setdefault(tuple(row["source_node_ids"]), set()).add(row["target_component_id"])
        self.assertGreaterEqual(max(len(values) for values in grouped.values()), 2)

    def test_angled_and_curved_t_split_multiple_target_shells(self):
        for factory in (FIXTURES.angled_t, FIXTURES.curved_t):
            model, _ = factory()
            candidates = detect_candidates(model)
            result, reports = realize_candidates(model, candidates)
            created = [row for row in reports if row["status"] == "CREATED"]
            self.assertTrue(created)
            self.assertTrue(created[0]["deleted_mother_elements"])
            self.assertTrue(created[0]["created_node_ids"])
            self.assertTrue(created[0]["created_weld_element_ids"])
            self.assertGreater(len(result.elements), len(model.elements))

    def test_small_patch_hole_and_near_edges_remain_review_only(self):
        model, _ = FIXTURES.patch_small_hole()
        candidates = detect_candidates(model)
        patches = [row for row in candidates if row["candidate_type"] == "PATCH_SEAM"]
        self.assertTrue(patches)
        self.assertTrue(all(not row["auto_eligible"] for row in patches))
        self.assertTrue(any("hole" in warning for row in patches for warning in row["warnings"]))

        model, _ = FIXTURES.near_free_edges()
        candidates = detect_candidates(model)
        near = [row for row in candidates if row["candidate_type"] == "NEAR_FREE_EDGES"]
        self.assertTrue(near)
        self.assertTrue(all(not row["auto_eligible"] for row in near))
        self.assertTrue(all(row["target_node_ids"] and row["target_edge_pairs"] for row in near))

    def test_closed_unequal_zipper_is_supported(self):
        nodes = {
            1: (0, 0, 1), 2: (2, 0, 1), 3: (2, 2, 1), 4: (0, 2, 1),
            11: (0, 0, 0), 12: (1, 0, 0), 13: (2, 0, 0),
            14: (2, 2, 0), 15: (0, 2, 0),
        }
        elements = plan_zipper([1, 2, 3, 4], [11, 12, 13, 14, 15], nodes, closed=True, max_tria_ratio=0.5)
        self.assertTrue(elements)
        self.assertTrue(any(row["element_type"] == "CTRIA3" for row in elements))

    def test_hm2019_param_and_criteria_drive_safe_neighborhood_moves(self):
        metadata = parse_param_metadata(EXAMPLE_DIR / "reference.param")
        self.assertEqual(10, metadata["values"]["element_size"])
        self.assertEqual(30, metadata["values"]["feature_angle"])
        model, _ = FIXTURES.angled_t()
        candidates = [row for row in detect_candidates(model) if row["auto_eligible"]]
        planned = plan_candidate_deltas(
            model,
            candidates,
            {
                "id_state": {"max_node_id": 5000, "max_element_id": 8000, "max_component_id": 100},
                "optimize_neighborhood": True,
                "optimization_layers": 2,
                "optimization_iterations": 4,
            },
            EXAMPLE_DIR / "reference.criteria",
            EXAMPLE_DIR / "reference.param",
        )
        self.assertEqual("READY", planned["plans"][0]["status"])
        self.assertTrue(planned["plans"][0]["ids_preallocated"])
        self.assertTrue(all(row["node_id"] > 5000 for row in planned["plans"][0]["new_nodes"]))
        self.assertTrue(all(row["element_id"] > 8000 for row in planned["plans"][0]["replacement_elements"] + planned["plans"][0]["weld_elements"]))
        optimization = planned["optimization"]
        self.assertLessEqual(optimization["quality_after"]["failed_element_count"], optimization["quality_before"]["failed_element_count"])
        self.assertLess(optimization["quality_after"]["objective"], optimization["quality_before"]["objective"])
        self.assertTrue(optimization["moves"])

    def test_preallocated_multi_component_delta_is_written(self):
        model, _ = FIXTURES.partial_overlap_t()
        candidates = [row for row in detect_candidates(model) if row["auto_eligible"]]
        state = {"max_node_id": 5000, "max_element_id": 8000, "max_component_id": 100}
        planned = plan_candidate_deltas(model, candidates, {"id_state": state})
        plan = planned["plans"][0]
        for key in ("candidate_type", "confidence", "source_component_id", "target_component_id", "source_node_ids", "target_node_ids"):
            self.assertIn(key, plan)
        self.assertGreaterEqual(len({row["component_id"] for row in plan["replacement_elements"]}), 2)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "delta.fem"
            manifest = write_shell_weld_delta(path, planned["plans"], {"id_state": state})
            text = path.read_text(encoding="utf-8")
            self.assertIn("$HMCOMP ID 1", text)
            self.assertIn("$HMCOMP ID 2", text)
            self.assertEqual(len(plan["new_nodes"]), len(manifest["created_node_ids"]))

    def test_live_source_pid_is_reused_when_selected_export_omits_pshell_cards(self):
        model, _ = FIXTURES.straight_t()
        source_component = next(
            component_id for component_id, component in model.components.items()
            if "WEB" in component.component_name
        )
        source_pid = next(
            model.element_properties[element.element_id]
            for element in model.elements_for_components([source_component])
        )
        model.pshell = {}
        candidates = [row for row in detect_candidates(model) if row["auto_eligible"]]
        planned = plan_candidate_deltas(
            model,
            candidates,
            {"id_state": {"max_node_id": 5000, "max_element_id": 8000, "max_component_id": 100}},
        )
        plan = planned["plans"][0]
        self.assertEqual(source_pid, plan["property_id"])
        self.assertTrue(all(row["property_id"] == source_pid for row in plan["weld_elements"]))

    def test_existing_seam_near_candidate_midpoint_disables_auto_creation(self):
        model, _ = FIXTURES.straight_t()
        candidates = detect_candidates(model)
        candidate = next(row for row in candidates if row["auto_eligible"])
        points = candidate["target_projection_points"]
        center = [sum(point[axis] for point in points) / len(points) for axis in range(3)]
        _mark_duplicates(candidates, model, [{"center": center}], 4.0)
        self.assertFalse(candidate["auto_eligible"])
        self.assertEqual("POSSIBLE_DUPLICATE", candidate["duplicate_status"])


if __name__ == "__main__":
    unittest.main()
