from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


PYTHON_DIR = Path(__file__).resolve().parents[1] / "python"
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

from fem_delta import (  # noqa: E402
    EntityIdAllocator,
    FemDeltaError,
    rbe2_lines,
    rbe3_lines,
    write_rigid_incremental_fem,
)


def request(**settings):
    values = {
        "rigidType": "RBE2",
        "dof": 123456,
        "outputComponentName": "AUTO_RBE2_SHELL",
    }
    values.update(settings)
    return {
        "settings": values,
        "id_state": {
            "max_node_id": 100,
            "max_element_id": 200,
            "max_component_id": 10,
        },
        "entity_registry": {"components": {}, "properties": {}, "materials": {}},
    }


def candidate(identifier="W0001"):
    return {
        "candidate_id": identifier,
        "recommended_action": "CREATE",
        "center": [1.25, 2.5, 3.75],
        "dependent_node_ids": list(range(1, 13)),
    }


class EntityIdAllocatorTests(unittest.TestCase):
    def test_allocates_each_entity_space_independently(self):
        allocator = EntityIdAllocator({"max_node_id": 9, "max_element_id": 20})
        self.assertEqual(allocator.reserve("node"), 10)
        self.assertEqual(allocator.reserve("node"), 11)
        self.assertEqual(allocator.reserve("element"), 21)


class RigidCardTests(unittest.TestCase):
    def test_rbe2_continuations_keep_every_dependent_grid(self):
        lines = rbe2_lines(201, 101, "123456", list(range(1, 13)))
        self.assertEqual(lines[0], "RBE2,201,101,123456,1,2,3,4")
        self.assertIn("12", lines[-1].split(","))

    def test_rbe3_has_reference_grid_weight_and_component_group(self):
        lines = rbe3_lines(201, 101, "123456", [1, 2, 3, 4])
        self.assertEqual(lines[0], "RBE3,201,,101,123456,1.0,123456,1,2")
        self.assertEqual(lines[1], "+,3,4")


class RigidDeltaTests(unittest.TestCase):
    def write(self, candidates, req):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name) / "rigids.fem"
        return path, write_rigid_incremental_fem(path, candidates, req)

    def test_writes_grid_rbe2_component_and_manifest(self):
        row = candidate()
        path, manifest = self.write([row], request())
        text = path.read_text(encoding="utf-8")
        self.assertIn('$HMNAME COMP 11 "AUTO_RBE2_SHELL"', text)
        self.assertIn("GRID,101,,1.25,2.5,3.75", text)
        self.assertIn("RBE2,201,101,123456", text)
        self.assertLess(text.index("$HMCOMP ID 11"), text.index("GRID,101"))
        self.assertEqual(text.count("$HMCOMP ID 11"), 1)
        self.assertEqual(manifest["created_node_ids"], [101])
        self.assertEqual(manifest["created_element_ids"], [201])
        self.assertEqual(manifest["expected_rigids"][0]["dependent_node_ids"], list(range(1, 13)))
        self.assertEqual(row["generated_element_id"], 201)

    def test_sets_component_before_first_grid_for_multiple_rigids(self):
        first = candidate("W0001")
        second = candidate("W0002")
        second["center"] = [4.0, 5.0, 6.0]
        path, _ = self.write([first, second], request())
        lines = path.read_text(encoding="utf-8").splitlines()
        component_index = lines.index("$HMCOMP ID 11")
        grid_indices = [index for index, line in enumerate(lines) if line.startswith("GRID,")]
        self.assertEqual(len(grid_indices), 2)
        self.assertLess(component_index, min(grid_indices))

    def test_reuses_existing_component(self):
        req = request()
        req["entity_registry"]["components"] = {"AUTO_RBE2_SHELL": 7}
        path, manifest = self.write([candidate()], req)
        self.assertNotIn("$HMNAME COMP", path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["reused_component_ids"], [7])
        self.assertEqual(manifest["expected_rigids"][0]["component_id"], 7)

    def test_skips_existing_candidate_and_does_not_create_empty_file(self):
        row = candidate()
        row["recommended_action"] = "SKIP_EXISTING"
        path, manifest = self.write([row], request())
        self.assertFalse(path.exists())
        self.assertEqual(manifest["planned_create_count"], 0)

    def test_rejects_invalid_dof_and_duplicate_dependents(self):
        with self.assertRaises(FemDeltaError):
            self.write([candidate()], request(dof="112"))
        row = candidate()
        row["dependent_node_ids"] = [1, 2, 2]
        with self.assertRaises(FemDeltaError):
            self.write([row], request())

    def test_requires_exported_id_state_and_existing_dependent_grids(self):
        req = request()
        del req["id_state"]
        with self.assertRaises(FemDeltaError):
            self.write([candidate()], req)
        req = request()
        req["id_state"]["max_node_id"] = 5
        with self.assertRaises(FemDeltaError):
            self.write([candidate()], req)


if __name__ == "__main__":
    unittest.main()
