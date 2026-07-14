import importlib.util
import math
import sys
import tempfile
import unittest
from pathlib import Path

PYTHON_DIR = Path(__file__).resolve().parents[1] / "python"
sys.path.insert(0, str(PYTHON_DIR))
from adjacency import ShellElement
from batch_planner import prevalidate_operation
from mesh_state import MeshState
from operation_model import adapt_existing_actions
from optimization_planner import plan_optimization_actions


GENERATOR = (
    Path(__file__).resolve().parents[3]
    / "examples"
    / "LocalMeshOptimizer_Large_Mixed"
    / "generate_fem.py"
)
SPEC = importlib.util.spec_from_file_location("local_mesh_fem_generator", str(GENERATOR))
generator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = generator
SPEC.loader.exec_module(generator)


def edge_lengths(model, element_id):
    element = model.elements[element_id]
    result = []
    for index, node in enumerate(element.nodes):
        following = element.nodes[(index + 1) % len(element.nodes)]
        first, second = model.nodes[node], model.nodes[following]
        result.append(math.sqrt(sum((first[axis] - second[axis]) ** 2 for axis in range(3))))
    return result


class FemGeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = generator.Model()
        generator.build_plate(cls.model, 300, 200, 5.0)
        generator.add_washers(cls.model, 12, 300, 200, 5.0)
        generator.add_manual_failures(cls.model, 300, 200, 5.0)
        cls.stats = generator.validate(cls.model, 10000)

    def test_large_model_and_required_feature_counts(self):
        self.assertEqual(self.stats["nodes"], 63729)
        self.assertEqual(self.stats["shell_elements"], 62424)
        self.assertEqual(self.stats["rbe2_elements"], 132)
        self.assertEqual(len(self.model.groups["WASHER_ELEMENTS"]), 384)
        self.assertEqual(len(self.model.groups["PROCESSABLE_SPLIT_QUAD"]), 1200)
        self.assertEqual(len(self.model.groups["PROCESSABLE_SKINNY_TRIA"]), 1200)
        self.assertEqual(len(self.model.groups["PROCESSABLE_NARROW_QUAD"]), 1200)
        self.assertEqual(len(self.model.groups["MANUAL_ZERO_AREA_TRIA"]), 120)
        self.assertEqual(len(self.model.groups["MANUAL_DUPLICATE_QUADS"]), 240)

    def test_geometry_matches_existing_planner_thresholds(self):
        skinny = self.model.groups["PROCESSABLE_SKINNY_TRIA"][0]
        lengths = sorted(edge_lengths(self.model, skinny))
        self.assertGreaterEqual(lengths[1] / lengths[0], 2.5)
        self.assertGreaterEqual(lengths[2] / lengths[0], 2.5)

        narrow = self.model.groups["PROCESSABLE_NARROW_QUAD"][0]
        lengths = edge_lengths(self.model, narrow)
        opposite = sorted(((lengths[0] + lengths[2]) / 2.0, (lengths[1] + lengths[3]) / 2.0))
        self.assertGreaterEqual(opposite[1] / opposite[0], 2.5)

        moderate = self.model.groups["MANUAL_MODERATE_TRIA"][0]
        lengths = sorted(edge_lengths(self.model, moderate))
        self.assertLess(lengths[1] / lengths[0], 2.5)

    def test_generated_defects_follow_existing_planner_and_precheck(self):
        elements = {
            element_id: ShellElement(element_id, element.property_id, element.nodes)
            for element_id, element in self.model.elements.items()
        }
        automatic_ids = (
            self.model.groups["PROCESSABLE_SPLIT_QUAD"]
            + self.model.groups["PROCESSABLE_SKINNY_TRIA"]
            + self.model.groups["PROCESSABLE_NARROW_QUAD"]
        )
        regions = [{"region_id": "Region_0001", "failed_elements": automatic_ids, "anchor_nodes": []}]
        actions = plan_optimization_actions(elements, automatic_ids, self.model.nodes, regions)
        by_element = {action["element_id"]: action["action_type"] for action in actions}
        actions_by_element = {}
        for action in actions:
            actions_by_element.setdefault(action["element_id"], []).append(action)
        self.assertTrue(all(by_element[element_id] == "split_quad" for element_id in self.model.groups["PROCESSABLE_SPLIT_QUAD"]))
        self.assertTrue(all(by_element[element_id] == "collapse_short_edge" for element_id in self.model.groups["PROCESSABLE_SKINNY_TRIA"]))
        self.assertTrue(all(by_element[element_id] == "collapse_short_edge" for element_id in self.model.groups["PROCESSABLE_NARROW_QUAD"]))
        self.assertTrue(all(
            len(actions_by_element[element_id]) == 2
            and len({frozenset((action["node_a"], action["node_b"])) for action in actions_by_element[element_id]}) == 2
            for element_id in self.model.groups["PROCESSABLE_NARROW_QUAD"]
        ))

        manual_id = self.model.groups["MANUAL_MODERATE_TRIA"][0]
        manual = plan_optimization_actions(
            elements,
            [manual_id],
            self.model.nodes,
            [{"region_id": "Region_0002", "failed_elements": [manual_id], "anchor_nodes": []}],
        )[0]
        self.assertEqual(manual["action_type"], "manual_review")

        zero_quad_id = self.model.groups["MANUAL_ZERO_AREA_QUAD"][0]
        zero_action = plan_optimization_actions(
            elements,
            [zero_quad_id],
            self.model.nodes,
            [{"region_id": "Region_0003", "failed_elements": [zero_quad_id], "anchor_nodes": []}],
        )[0]
        operation = adapt_existing_actions([zero_action], MeshState(self.model.nodes, elements))[0]
        valid, reason = prevalidate_operation(operation, MeshState(self.model.nodes, elements))
        self.assertFalse(valid)
        self.assertEqual(reason, "split_would_create_zero_area_triangle")

    def test_written_fem_has_valid_free_format_and_manifested_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "测试 large mixed.fem"
            generator.write_fem(self.model, output)
            generator.validate_written_fem(output, self.stats)
            text = output.read_text(encoding="utf-8")
            self.assertIn("$ SET_NAME: WASHER_ELEMENTS", text)
            self.assertIn("$ SET_NAME: MANUAL_ZERO_AREA_QUAD", text)
            self.assertTrue(text.rstrip().endswith("ENDDATA"))


if __name__ == "__main__":
    unittest.main()
