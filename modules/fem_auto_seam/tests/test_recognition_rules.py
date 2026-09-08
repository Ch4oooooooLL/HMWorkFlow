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
        self.assertEqual(1, len(t_rows))
        row = t_rows[0]
        self.assertEqual("TRUSTED", row["recognition_status"])
        self.assertTrue(row["auto_eligible"])
        self.assertAlmostEqual(60.0, row["length"], places=6)
        self.assertTrue(
            any("nearest edge row" in reason for reason in row["reasons"]),
            row["reasons"],
        )
        plan = build_recognition_plan(candidates)
        self.assertEqual(1, len(plan["trusted_seeds"]))
        self.assertFalse(plan["potential_groups"])


    def test_patch_opening_edge_is_reviewed_while_outer_boundary_stays_trusted(self):
        # V2 defaults inner loops to REVIEW because they can represent either
        # ring welds or fastener openings.
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
        self.assertFalse(inner["auto_eligible"])
        self.assertIn("INNER_BOUNDARY_SOURCE", inner["reason_codes"])
        lengths = sorted(row["length"] for row in patch_rows)
        self.assertAlmostEqual(120.0, lengths[0], places=6)
        self.assertAlmostEqual(200.0, lengths[1], places=6)
        self.assertEqual(1, len(build_recognition_plan(candidates)["trusted_seeds"]))


if __name__ == "__main__":
    unittest.main()
