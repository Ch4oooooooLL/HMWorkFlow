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


def _add_grid(builder, component_id, property_id, origin, u_step, v_step, u_count, v_count):
    """Append a quad grid to an existing component (mirrors MeshBuilder.grid)."""
    node_grid = []
    for v_index in range(v_count + 1):
        row = []
        for u_index in range(u_count + 1):
            point = tuple(
                origin[axis] + u_index * u_step[axis] + v_index * v_step[axis]
                for axis in range(3)
            )
            row.append(builder.node(point))
        node_grid.append(row)
    for v_index in range(v_count):
        for u_index in range(u_count):
            builder.quad(component_id, property_id, (
                node_grid[v_index][u_index],
                node_grid[v_index][u_index + 1],
                node_grid[v_index + 1][u_index + 1],
                node_grid[v_index + 1][u_index],
            ))


class RecognitionRuleTests(unittest.TestCase):
    def test_complete_single_target_t_edge_is_trusted_seed(self):
        model, _ = FIXTURES.straight_t()
        candidates = detect_candidates(model)
        t_rows = [row for row in candidates if row["candidate_type"] == "T_SEAM"]
        auto_rows = [row for row in t_rows if row["auto_eligible"]]
        # One weldable chain; the web's two vertical end edges are recall-pass
        # extras which must never reach AUTO.
        self.assertEqual(1, len(auto_rows))
        self.assertGreaterEqual(len(auto_rows[0]["source_node_ids"]), 2)
        plan = build_recognition_plan(candidates)
        seed_ids = {seed["candidate_id"] for seed in plan["trusted_seeds"]}
        self.assertIn(auto_rows[0]["candidate_id"], seed_ids)
        # The weldable main edge is delivered for creation; only candidates
        # whose own evidence is unsafe may stay in review.
        reviewed = {
            candidate_id
            for group in plan["potential_groups"]
            for candidate_id in group.get("candidate_ids", [])
        }
        self.assertNotIn(auto_rows[0]["candidate_id"], reviewed)

    def test_complete_supported_t_subchain_is_trusted(self):
        model, _ = FIXTURES.partial_overlap_t()
        candidates = detect_candidates(model)
        t_rows = [row for row in candidates if row["candidate_type"] == "T_SEAM"]
        auto_rows = [row for row in t_rows if row["auto_eligible"]]
        self.assertEqual(1, len(auto_rows))
        # The recall pass reports the fuller chain as REVIEW; it must not
        # upgrade to AUTO and must not replace the supported subchain.
        self.assertTrue(all(
            not row["auto_eligible"] for row in t_rows
            if row["candidate_id"] != auto_rows[0]["candidate_id"]
        ))
        plan = build_recognition_plan(candidates)
        seed_ids = {seed["candidate_id"] for seed in plan["trusted_seeds"]}
        self.assertIn(auto_rows[0]["candidate_id"], seed_ids)
        # Recall delivery keeps every reported chain; the recognizer no longer
        # suppresses a supported edge that the user asked to weld.
        self.assertEqual({row["candidate_id"] for row in t_rows}, seed_ids)
        self.assertFalse(plan["potential_groups"])

    def test_ambiguous_t_relations_require_review_even_with_submit_all(self):
        model, _ = FIXTURES.multi_target_same_edge()
        candidates = detect_candidates(model)
        plan = build_recognition_plan(candidates)
        self.assertFalse([seed for seed in plan["trusted_seeds"] if seed["weld_type"] == "T"])
        self.assertTrue(plan["potential_groups"])

    def test_submit_all_cannot_bypass_coverage_and_duplicate_gates(self):
        candidates = [
            {
                "candidate_id": "T_REVIEW_1", "candidate_type": "T_SEAM",
                "source_component_id": 11, "target_component_id": 21,
                "target_component_ids": [21, 22], "source_node_ids": [101, 102],
                "recognition_status": "POTENTIAL", "auto_eligible": False,
                "duplicate_status": "POSSIBLE_DUPLICATE",
                "reason_codes": ["INNER_BOUNDARY_SOURCE", "ANGLE_BORDERLINE"],
            },
            {
                "candidate_id": "PATCH_REVIEW_1", "candidate_type": "PATCH_SEAM",
                "source_component_id": 12, "target_component_id": 23,
                "source_node_ids": [201, 202, 203, 201], "closed": True,
                "recognition_status": "POTENTIAL", "auto_eligible": False,
                "reason_codes": ["PARTIAL_COVERAGE"],
            },
        ]
        plan = build_recognition_plan(candidates)
        self.assertFalse(plan["trusted_seeds"])
        self.assertTrue(plan["potential_groups"])

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

    def test_small_patch_hole_is_filtered_and_outer_boundary_is_automatic(self):
        model, _ = FIXTURES.patch_small_hole()
        plan = build_recognition_plan(detect_candidates(model))
        self.assertEqual(1, len(plan["trusted_seeds"]))
        self.assertFalse(plan["potential_groups"])

        model, _ = FIXTURES.near_free_edges()
        self.assertFalse(detect_candidates(model))
        legacy = detect_candidates(model, {"include_legacy_near_edges": True})
        self.assertTrue(any(row["candidate_type"] == "NEAR_FREE_EDGES" for row in legacy))


    def test_multi_patch_component_projects_each_patch_loop_onto_base(self):
        # One component carrying two patch shells whose combined area exceeds
        # the base: component area must not flip the projection direction, and
        # each patch loop is an independent trusted weld.
        builder = FIXTURES.MeshBuilder()
        base = builder.grid("BASE_T2", (0, 0, 0), (10, 0, 0), (0, 10, 0), 4, 4, 2.0)
        patches, property_id = builder.component("PATCHES_T1", 1.0)
        _add_grid(builder, patches, property_id, (2, 2, 3), (10, 0, 0), (0, 10, 0), 3, 3)
        _add_grid(builder, patches, property_id, (8, 8, 3), (10, 0, 0), (0, 10, 0), 3, 3)
        candidates = detect_candidates(builder.model())
        patch_rows = [row for row in candidates if row["candidate_type"] == "PATCH_SEAM"]
        self.assertEqual(2, len(patch_rows))
        for row in patch_rows:
            self.assertEqual(patches, row["source_component_id"])
            self.assertEqual(base, row["target_component_id"])
            self.assertTrue(row["auto_eligible"])
            self.assertEqual("TRUSTED", row["recognition_status"])
        self.assertFalse(any(row["source_component_id"] == base for row in candidates))
        plan = build_recognition_plan(candidates)
        self.assertEqual(2, len(plan["trusted_seeds"]))
        self.assertTrue(all(seed["weld_type"] == "PATCH" for seed in plan["trusted_seeds"]))

    def test_separate_patch_components_on_one_base_all_stay_trusted(self):
        # Several distinct patches on one target are not ambiguous: the target
        # carrying multiple patches must not downgrade any of them.
        builder = FIXTURES.MeshBuilder()
        base = builder.grid("BASE_T2", (0, 0, 0), (10, 0, 0), (0, 10, 0), 6, 6, 2.0)
        patch_a = builder.grid("PATCH_A_T1", (5, 5, 3), (10, 0, 0), (0, 10, 0), 2, 2, 1.0)
        patch_b = builder.grid("PATCH_B_T1", (35, 35, 3), (10, 0, 0), (0, 10, 0), 2, 2, 1.0)
        candidates = detect_candidates(builder.model())
        patch_rows = [row for row in candidates if row["candidate_type"] == "PATCH_SEAM"]
        self.assertEqual(2, len(patch_rows))
        self.assertEqual({patch_a, patch_b}, {row["source_component_id"] for row in patch_rows})
        for row in patch_rows:
            self.assertEqual(base, row["target_component_id"])
            self.assertTrue(row["auto_eligible"])
            self.assertEqual("TRUSTED", row["recognition_status"])
            self.assertFalse(row.get("ambiguous_relation", False))
        self.assertEqual(2, len(build_recognition_plan(candidates)["trusted_seeds"]))

    def test_web_face_fully_on_target_trusts_nearest_edge_row(self):
        # A web standing on a base whose far edge carries an upturned flange:
        # the web's side edge partially hits the flange, but the face falls
        # completely on the target and its nearest (bottom) edge row projects
        # completely, so the relation is a trusted seed.
        builder = FIXTURES.MeshBuilder()
        base, base_property = builder.component("BASE_FLANGE_T2", 2.0)
        _add_grid(builder, base, base_property, (-10, -20, 0), (10, 0, 0), (0, 10, 0), 8, 4)
        _add_grid(builder, base, base_property, (70, -20, 0), (0, 10, 0), (0, 0, 10), 4, 1)
        builder.ruled("WEB_T1", FIXTURES.line_points(0, 60, 10), (0, 0, 20), 2, 1.0)
        candidates = detect_candidates(builder.model())
        t_rows = [row for row in candidates if row["candidate_type"] == "T_SEAM"]
        auto_rows = [row for row in t_rows if row["auto_eligible"]]
        self.assertEqual(1, len(auto_rows))
        row = auto_rows[0]
        self.assertEqual("TRUSTED", row["recognition_status"])
        self.assertAlmostEqual(60.0, row["length"], places=6)
        self.assertTrue(
            any("nearest edge row" in reason for reason in row["reasons"]),
            row["reasons"],
        )
        self.assertTrue(all(
            not extra["auto_eligible"] for extra in t_rows
            if extra["candidate_id"] != row["candidate_id"]
        ))
        plan = build_recognition_plan(candidates)
        seed_ids = {seed["candidate_id"] for seed in plan["trusted_seeds"]}
        self.assertIn(row["candidate_id"], seed_ids)
        reviewed = {
            candidate_id
            for group in plan["potential_groups"]
            for candidate_id in group.get("candidate_ids", [])
        }
        self.assertNotIn(row["candidate_id"], reviewed)


    def test_patch_opening_and_outer_boundary_are_both_trusted(self):
        # Large exposed openings are genuine patch weld boundaries. Fastener-
        # sized openings are filtered separately by small_hole_diameter.
        builder = FIXTURES.MeshBuilder()
        base = builder.grid("BASE_T2", (0, 0, 0), (10, 0, 0), (0, 10, 0), 7, 7, 2.0)
        patch = builder.grid(
            "PATCH_RING_T1", (5, 5, 3), (5, 0, 0), (0, 5, 0), 10, 10, 1.0,
            omit={(u, v) for u in range(2, 8) for v in range(2, 8)},
        )
        candidates = detect_candidates(builder.model())
        patch_rows = [row for row in candidates if row["candidate_type"] == "PATCH_SEAM"]
        self.assertEqual(2, len(patch_rows))
        outer = next(row for row in patch_rows if row.get("boundary_class") == "OUTER")
        inner = next(row for row in patch_rows if row.get("boundary_class") == "INNER")
        self.assertEqual(patch, outer["source_component_id"])
        self.assertEqual(base, outer["target_component_id"])
        self.assertTrue(outer["auto_eligible"], outer.get("warnings"))
        self.assertTrue(inner["auto_eligible"], inner.get("warnings"))
        self.assertNotIn("INNER_BOUNDARY_SOURCE", inner["reason_codes"])
        lengths = sorted(row["length"] for row in patch_rows)
        self.assertAlmostEqual(120.0, lengths[0], places=6)
        self.assertAlmostEqual(200.0, lengths[1], places=6)
        self.assertEqual(2, len(build_recognition_plan(candidates)["trusted_seeds"]))

    def test_fastener_opening_does_not_veto_outer_patch_seam(self):
        builder = FIXTURES.MeshBuilder()
        base = builder.grid("BASE_T2", (0, 0, 0), (10, 0, 0), (0, 10, 0), 8, 8, 2.0)
        patch = builder.grid(
            "PATCH_WITH_FASTENER_T1", (10, 10, 3), (5, 0, 0), (0, 5, 0), 10, 10, 1.0,
            omit={(4, 4)},
        )
        rows = [row for row in detect_candidates(builder.model()) if row["candidate_type"] == "PATCH_SEAM"]
        self.assertEqual(1, len(rows))
        self.assertEqual(patch, rows[0]["source_component_id"])
        self.assertEqual(base, rows[0]["target_component_id"])
        self.assertEqual("OUTER", rows[0]["boundary_class"])
        self.assertTrue(rows[0]["auto_eligible"], rows[0].get("warnings"))


if __name__ == "__main__":
    unittest.main()
