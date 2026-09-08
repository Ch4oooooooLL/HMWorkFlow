from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "python"))

from hmworkflow.core.mesh_model import Element
from hmworkflow.fem_auto_seam.backend import build_recognition_plan, detect_candidates, write_fem_bundle
from hmworkflow.fem_auto_seam.main import _recognition_document, _write_recognition_debug
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
        self.assertEqual(1, len(rows))
        row = rows[0]
        self.assertEqual("AUTO", row["decision"])
        self.assertEqual([1, 2, 3, 4], row["target_component_ids"])
        self.assertEqual(4, len(row["support_runs"]))
        self.assertIn("MULTI_TARGET_CONTINUOUS", row["reason_codes"])
        seed = build_recognition_plan(rows)["trusted_seeds"][0]
        self.assertEqual([1, 2, 3, 4], seed["target_component_ids"])
        self.assertEqual(row["support_runs"], seed["support_runs"])

    def test_competing_stacked_target_is_review_with_reason(self):
        model, _ = FIXTURES.multi_target_same_edge()
        row = next(value for value in detect_candidates(model) if value["candidate_type"] == "T_SEAM")
        self.assertEqual("REVIEW", row["decision"])
        self.assertIn("TARGET_AMBIGUITY", row["reason_codes"])
        self.assertTrue(row["review"]["alternative_targets"])

    def test_target_hole_interrupts_support_and_forces_review(self):
        builder = FIXTURES.MeshBuilder()
        builder.grid(
            "TARGET_WITH_SLOT_T2", (0, -20, 0), (10, 0, 0), (0, 10, 0), 8, 4, 2.0,
            omit={(u, v) for u in (3, 4) for v in range(4)},
        )
        builder.ruled("WEB_T1", FIXTURES.line_points(0, 80, 10), (0, 0, 20), 2, 1.0)
        rows = [value for value in detect_candidates(builder.model()) if value["candidate_type"] == "T_SEAM"]
        self.assertTrue(rows)
        self.assertTrue(all(value["decision"] == "REVIEW" for value in rows))
        self.assertTrue(all("HOLE_INTERRUPTION" in value["reason_codes"] for value in rows))

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
        review_model, _ = FIXTURES.partial_overlap_t()
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
