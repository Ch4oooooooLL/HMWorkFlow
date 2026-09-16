from __future__ import annotations

import importlib.util
import math
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "python"))

from hmworkflow.core.mesh_model import Element
from hmworkflow.fem_auto_seam.backend import build_recognition_plan, detect_candidates, write_fem_bundle
from hmworkflow.fem_auto_seam.main import _recognition_document, _write_recognition_debug
from hmworkflow.fem_auto_seam.schema import validate_request
from hmworkflow.mesh_seam_weld.fem_mesh_reader import read_shell_fem, read_shell_fem_bundle


def _fixtures():
    path = ROOT / "examples" / "AutoShellSeamBackend" / "generate_fixtures.py"
    spec = importlib.util.spec_from_file_location("fem_auto_v2_fixtures", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


FIXTURES = _fixtures()


class RecognitionV2Tests(unittest.TestCase):
    def _corpus_model(self, case_name):
        manifest = (
            ROOT / "examples" / "validation_weld_recognition_v2" / "atomic" /
            case_name / "input_manifest.json"
        )
        return read_shell_fem_bundle(manifest)

    def test_geometry_relative_tangential_tolerance_keeps_warped_t_auto(self):
        model = self._corpus_model("TC018_slightly_warped_target")
        rows = [row for row in detect_candidates(model) if row["candidate_type"] == "T_SEAM"]
        automatic = [row for row in rows if row["decision"] == "AUTO"]
        self.assertEqual(1, len(automatic))
        self.assertGreater(automatic[0]["length"], 300.0)

    def test_complete_supported_middle_subchain_is_not_vetoed_by_parent_boundary(self):
        model = self._corpus_model("TC013_partial_target_middle")
        rows = [row for row in detect_candidates(model) if row["candidate_type"] == "T_SEAM"]
        self.assertEqual(1, len(rows))
        self.assertEqual("AUTO", rows[0]["decision"])
        self.assertNotIn("PARTIAL_COVERAGE", rows[0]["reason_codes"])
        self.assertAlmostEqual(1.0, rows[0]["projection_coverage"], places=7)

    def test_curved_target_is_evidence_not_an_auto_veto_when_local_support_is_complete(self):
        model = self._corpus_model("TC019_curved_target")
        row = next(value for value in detect_candidates(model) if value["candidate_type"] == "T_SEAM")
        self.assertEqual("AUTO", row["decision"])
        self.assertIn("CURVED_TARGET", row["reason_codes"])
        self.assertTrue(row["auto_eligible"])

    def test_visible_perpendicular_angle_setting_controls_v2_auto_gate(self):
        request = validate_request({
            "schema_version": "1.0", "module": "fem_auto_seam", "run_id": "angle-rule",
            "hypermesh_version": "2019", "selected_component_ids": [1, 2],
            "settings": {"perpendicular_angle_min": 70.0}, "options": {},
        })
        self.assertEqual(70.0, request["settings"]["t_angle_auto_min_deg"])
        model = self._corpus_model("TC021_angle_70")
        row = next(
            value for value in detect_candidates(model, request["settings"])
            if value["candidate_type"] == "T_SEAM"
        )
        self.assertEqual("AUTO", row["decision"])
        self.assertNotIn("ANGLE_BORDERLINE", row["reason_codes"])

    def test_explicit_recall_angle_override_generates_a_seed_for_shallow_candidate(self):
        model = self._corpus_model("TC022_angle_55")
        rows = [
            row for row in detect_candidates(model, {
                "t_recall_angle_min_deg": 45.0,
                "t_recall_angle_max_deg": 135.0,
            }) if row["candidate_type"] == "T_SEAM"
        ]
        self.assertTrue(rows)
        seeds = [seed for seed in build_recognition_plan(rows)["trusted_seeds"] if seed["weld_type"] == "T"]
        self.assertTrue(seeds)
        self.assertEqual("ALL_CANDIDATES", seeds[0]["delivery_mode"])

    def test_generalized_t_at_40_or_140_degrees_is_recalled_by_default(self):
        builder = FIXTURES.MeshBuilder()
        slope = math.tan(math.radians(50.0))
        builder.grid(
            "SLOPED_BASE_T2", (-10, -20, 3.0 - 20.0 * slope),
            (10, 0, 0), (0, 10, 10.0 * slope), 8, 4, 2.0,
        )
        builder.ruled(
            "LONG_WEB_T1", FIXTURES.line_points(0, 60, 10, y=0.0, z=3.0),
            (0, 0, 20), 2, 1.0,
        )
        rows = [
            row for row in detect_candidates(builder.model())
            if row["candidate_type"] == "T_SEAM"
        ]
        self.assertTrue(rows)
        self.assertTrue(any(abs(row["normal_angle"] - 40.0) < 1.0 for row in rows), rows)
        plan = build_recognition_plan(rows)
        self.assertEqual(len(rows), len(plan["trusted_seeds"]))
        main = next(row for row in rows if row["candidate_id"] == plan["trusted_seeds"][0]["candidate_id"])
        self.assertGreaterEqual(main["length"], 60.0)
        self.assertAlmostEqual(main["projection_coverage"], 1.0)
        self.assertFalse(plan["potential_groups"])  # every reported T chain is delivered

    def test_visible_60_degree_setting_builds_a_valid_relaxed_review_envelope(self):
        request = validate_request({
            "schema_version": "1.0", "module": "fem_auto_seam", "run_id": "angle-60",
            "hypermesh_version": "2019", "selected_component_ids": [1, 2],
            "settings": {
                "perpendicular_angle_min": 60.0,
                "potential_angle_margin": 10.0,
            },
            "options": {},
        })
        settings = request["settings"]
        self.assertEqual(60.0, settings["t_angle_auto_min_deg"])
        self.assertEqual(50.0, settings["t_angle_review_min_deg"])
        self.assertLessEqual(settings["t_angle_review_min_deg"], settings["t_angle_auto_min_deg"])
        self.assertGreaterEqual(settings["t_angle_review_max_deg"], settings["t_angle_auto_max_deg"])

    def test_separate_supported_edge_runs_do_not_reject_each_other(self):
        model = self._corpus_model("TC030_projection_jump")
        rows = [row for row in detect_candidates(model) if row["candidate_type"] == "T_SEAM"]
        auto_rows = [row for row in rows if row["auto_eligible"]]
        self.assertEqual(2, len(auto_rows))
        self.assertTrue(all(row["decision"] == "AUTO" for row in auto_rows))
        # The web's end edges are recall-pass extras and stay non-auto.
        auto_ids = {row["candidate_id"] for row in auto_rows}
        self.assertTrue(all(
            not row["auto_eligible"] for row in rows
            if row["candidate_id"] not in auto_ids
        ))

    def test_half_thickness_sum_plus_bevel_clearance_is_valid_t_contact(self):
        builder = FIXTURES.MeshBuilder()
        builder.grid("TARGET_T10", (0, -20, 0), (10, 0, 0), (0, 10, 0), 8, 4, 10.0)
        builder.ruled("WEB_T6", FIXTURES.line_points(10, 70, 10, z=11.0), (0, 0, 20), 2, 6.0)
        row = next(value for value in detect_candidates(builder.model()) if value["candidate_type"] == "T_SEAM")
        self.assertEqual("AUTO", row["decision"])
        self.assertAlmostEqual(6.0, row["geometry"]["skin_error_max"], places=6)

    def test_thick_shell_contact_envelope_can_exceed_fixed_search_distance(self):
        builder = FIXTURES.MeshBuilder()
        builder.grid("TARGET_T20", (0, -20, 0), (10, 0, 0), (0, 10, 0), 8, 4, 20.0)
        # Target physical top skin is z=10.  A T30 web midsurface edge at z=28
        # is 18 mm from that skin: source half thickness (15) plus a 3 mm toe.
        builder.ruled("WEB_T30", FIXTURES.line_points(10, 70, 10, z=28.0), (0, 0, 20), 2, 30.0)
        row = next(value for value in detect_candidates(builder.model()) if value["candidate_type"] == "T_SEAM")
        self.assertEqual("AUTO", row["decision"])
        self.assertAlmostEqual(18.0, row["geometry"]["skin_error_max"], places=6)

    def test_endpoint_only_abrupt_target_is_not_merged_into_main_support(self):
        model = self._corpus_model("TC042_web_junction")
        rows = [
            value for value in detect_candidates(model)
            if value["candidate_type"] == "T_SEAM" and len(value["target_component_ids"]) > 1
        ]
        self.assertFalse(rows)

    def test_physical_skin_and_zoffs_drive_zero_residual(self):
        builder = FIXTURES.MeshBuilder()
        target = builder.grid("TARGET_T2", (-10, -20, 0), (10, 0, 0), (0, 10, 0), 8, 4, 2.0)
        builder.ruled("WEB_T1", FIXTURES.line_points(0, 60, 10, z=2.0), (0, 0, 20), 2, 1.0)
        model = builder.model()
        model.element_zoffs = {
            element.element_id: 1.0
            for element in model.elements_for_components([target])
        }
        row = next(value for value in detect_candidates(model) if value["candidate_type"] == "T_SEAM")
        self.assertEqual("AUTO", row["decision"])
        self.assertAlmostEqual(0.0, row["geometry"]["skin_error_max"], places=7)

    def test_reversed_target_normals_preserve_t_angle(self):
        model, _ = FIXTURES.straight_t()
        for element_id in [value for value, element in model.elements.items() if element.component_id == 1]:
            element = model.elements[element_id]
            model.elements[element_id] = Element(
                element.element_id, element.component_id, element.element_type,
                tuple(reversed(element.node_ids)),
            )
        row = next(value for value in detect_candidates(model) if value["candidate_type"] == "T_SEAM")
        self.assertEqual("AUTO", row["decision"])
        self.assertAlmostEqual(90.0, row["geometry"]["angle_mean_deg"], places=6)

    def test_continuous_multi_component_support_is_one_auto_job(self):
        model, _ = FIXTURES.four_target_t()
        rows = [value for value in detect_candidates(model) if value["candidate_type"] == "T_SEAM"]
        auto_rows = [row for row in rows if row["auto_eligible"]]
        self.assertEqual(1, len(auto_rows))
        row = auto_rows[0]
        self.assertEqual("AUTO", row["decision"])
        self.assertEqual([1, 2, 3, 4], row["target_component_ids"])
        self.assertEqual(4, len(row["support_runs"]))
        self.assertIn("MULTI_TARGET_CONTINUOUS", row["reason_codes"])
        seed = next(
            seed for seed in build_recognition_plan(rows)["trusted_seeds"]
            if seed["candidate_id"] == row["candidate_id"]
        )
        self.assertEqual([1, 2, 3, 4], seed["target_component_ids"])
        self.assertEqual(row["support_runs"], seed["support_runs"])

    def test_competing_stacked_target_is_review_with_reason(self):
        model, _ = FIXTURES.multi_target_same_edge()
        row = next(value for value in detect_candidates(model) if value["candidate_type"] == "T_SEAM")
        self.assertEqual("REVIEW", row["decision"])
        self.assertIn("TARGET_AMBIGUITY", row["reason_codes"])
        self.assertTrue(row["review"]["alternative_targets"])

    def test_target_hole_inside_one_edge_remains_an_internal_interruption(self):
        builder = FIXTURES.MeshBuilder()
        builder.grid(
            "TARGET_WITH_SLOT_T2", (0, -20, 0), (10, 0, 0), (0, 10, 0), 8, 4, 2.0,
            omit={(u, v) for u in (3, 4) for v in range(4)},
        )
        builder.ruled("WEB_T1", FIXTURES.line_points(0, 80, 10), (0, 0, 20), 2, 1.0)
        rows = [value for value in detect_candidates(builder.model()) if value["candidate_type"] == "T_SEAM"]
        self.assertTrue(rows)
        hole_rows = [row for row in rows if "HOLE_INTERRUPTION" in row["reason_codes"]]
        self.assertEqual(2, len(hole_rows))
        self.assertTrue(all(row["decision"] == "REVIEW" for row in hole_rows))
        # Recall extras (the web's end edges) are REVIEW as well, but they are
        # not part of the interrupted chain and carry no hole evidence.
        self.assertTrue(all(row["decision"] == "REVIEW" for row in rows))

    def test_confidence_cannot_bypass_or_veto_hard_gate(self):
        model, _ = FIXTURES.straight_t()
        row = next(
            value for value in detect_candidates(model, {"auto_accept_confidence": 0.999})
            if value["candidate_type"] == "T_SEAM"
        )
        self.assertLess(row["confidence"], 0.999)
        self.assertEqual("AUTO", row["decision"])
        self.assertTrue(row["auto_eligible"])

    def test_fem_reader_preserves_zoffs_and_continuation_nodal_thickness(self):
        text = """BEGIN BULK
GRID,1,,0.,0.,0.
GRID,2,,10.,0.,0.
GRID,3,,10.,10.,0.
GRID,4,,0.,10.,0.
CQUAD4,10,100,1,2,3,4,0.,0.25,
+,,,1.1,1.2,1.3,1.4
PSHELL,100,1,2.0
MAT1,1,210000.,,0.3
ENDDATA
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "shell.fem"
            path.write_text(text, encoding="utf-8")
            model = read_shell_fem(path, 7, "SHELL")
            self.assertEqual(0.25, model.element_zoffs[10])
            self.assertEqual((1.1, 1.2, 1.3, 1.4), model.element_nodal_thicknesses[10])
            manifest = write_fem_bundle(model, Path(directory) / "roundtrip.fem")
            restored = read_shell_fem_bundle(manifest)
        self.assertEqual(0.25, restored.element_zoffs[10])
        self.assertEqual((1.1, 1.2, 1.3, 1.4), restored.element_nodal_thicknesses[10])

    def test_v2_debug_artifacts_keep_auto_and_review_delivery_classes(self):
        auto_model, _ = FIXTURES.straight_t()
        review_model, _ = FIXTURES.multi_target_same_edge()
        candidates = detect_candidates(auto_model) + detect_candidates(review_model)
        document = _recognition_document(candidates, "selected.fem", {"schema_version": 2})
        self.assertEqual("2.0", document["schema_version"])
        self.assertTrue(document["auto"])
        self.assertTrue(document["review"])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "recognition_debug.csv"
            _write_recognition_debug(path, candidates)
            debug = path.read_text(encoding="utf-8-sig")
        self.assertIn("skin_error_p95", debug)
        self.assertIn("reason_codes", debug)


if __name__ == "__main__":
    unittest.main()
