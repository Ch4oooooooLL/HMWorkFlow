from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "python"))

from hmworkflow.fem_auto_seam.backend import build_recognition_plan, detect_candidates


def _fixtures():
    path = ROOT / "examples" / "AutoShellSeamBackend" / "generate_fixtures.py"
    spec = importlib.util.spec_from_file_location("fem_auto_recognition_fixtures", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


FIXTURES = _fixtures()


class RecognitionRuleTests(unittest.TestCase):
    def test_complete_single_target_t_edge_is_trusted_seed(self):
        model, _ = FIXTURES.straight_t()
        candidates = detect_candidates(model)
        plan = build_recognition_plan(candidates)
        self.assertEqual(1, len(plan["trusted_seeds"]))
        self.assertEqual("T", plan["trusted_seeds"][0]["weld_type"])
        self.assertGreaterEqual(len(plan["trusted_seeds"][0]["source_node_ids"]), 2)
        self.assertFalse(plan["potential_groups"])

    def test_partial_t_overlap_is_potential_component_pair(self):
        model, _ = FIXTURES.partial_overlap_t()
        plan = build_recognition_plan(detect_candidates(model))
        self.assertFalse(plan["trusted_seeds"])
        self.assertEqual([[1, 2]], [row["component_ids"] for row in plan["potential_groups"]])

    def test_same_t_edge_hitting_multiple_targets_becomes_one_group(self):
        model, _ = FIXTURES.multi_target_same_edge()
        plan = build_recognition_plan(detect_candidates(model))
        self.assertFalse(plan["trusted_seeds"])
        self.assertEqual(1, len(plan["potential_groups"]))
        self.assertEqual([1, 2, 3], plan["potential_groups"][0]["component_ids"])

    def test_fully_contained_smaller_patch_supplies_all_free_edge_nodes(self):
        model, _ = FIXTURES.patch()
        candidates = detect_candidates(model)
        plan = build_recognition_plan(candidates)
        self.assertEqual(1, len(plan["trusted_seeds"]))
        seed = plan["trusted_seeds"][0]
        self.assertEqual("PATCH", seed["weld_type"])
        self.assertTrue(seed["closed_loop"])
        patch = next(row for row in candidates if row["candidate_type"] == "PATCH_SEAM")
        self.assertEqual(patch["source_node_ids"], seed["source_node_ids"])

    def test_small_hole_patch_and_legacy_near_edges_are_not_automatic(self):
        model, _ = FIXTURES.patch_small_hole()
        plan = build_recognition_plan(detect_candidates(model))
        self.assertFalse(plan["trusted_seeds"])
        self.assertEqual([1, 2], plan["potential_groups"][0]["component_ids"])

        model, _ = FIXTURES.near_free_edges()
        self.assertFalse(detect_candidates(model))
        legacy = detect_candidates(model, {"include_legacy_near_edges": True})
        self.assertTrue(any(row["candidate_type"] == "NEAR_FREE_EDGES" for row in legacy))


if __name__ == "__main__":
    unittest.main()
