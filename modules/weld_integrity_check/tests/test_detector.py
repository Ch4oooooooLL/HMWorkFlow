from __future__ import annotations

import sys
import unittest
from pathlib import Path

PYTHON_DIR = Path(__file__).resolve().parents[1] / "python"
sys.path.insert(0, str(PYTHON_DIR))

from detector import detect  # noqa: E402


SETTINGS = {
    "max_search_distance": 0.25,
    "min_contact_length": 1.5,
    "min_continuous_nodes": 3,
    "prefer_free_edges": True,
    "ignore_shared_nodes": True,
}


def strip(component_id, y, start=0.0, segments=3, node_start=1, element_start=1):
    nodes, elements = {}, []
    for index in range(segments + 1):
        nodes[node_start + index] = (start + index, y, 0.0)
        nodes[node_start + segments + 1 + index] = (start + index, y + 0.5, 0.0)
    for index in range(segments):
        elements.append({
            "element_id": element_start + index,
            "component_id": component_id,
            "element_type": "CQUAD4",
            "node_ids": [node_start + index, node_start + index + 1, node_start + segments + 2 + index, node_start + segments + 1 + index],
        })
    return nodes, elements


def model(offset=0.1, second_start=0.0, second_segments=3):
    nodes_a, elements_a = strip(10, 0.0, node_start=1, element_start=1)
    nodes_b, elements_b = strip(20, offset, start=second_start, segments=second_segments, node_start=101, element_start=101)
    combined_nodes = dict(nodes_a)
    combined_nodes.update(nodes_b)
    return (
        [{"id": 10, "name": "FRAME", "entity_type": "shell"}, {"id": 20, "name": "BRACKET", "entity_type": "shell"}],
        combined_nodes,
        elements_a + elements_b,
    )


class DetectorTests(unittest.TestCase):
    def test_typical_near_shells_create_one_pair(self):
        components, nodes, elements = model()
        result = detect(components, nodes, elements, dict(SETTINGS))
        self.assertTrue(result["success"])
        self.assertEqual(1, result["summary"]["candidate_pair_count"])
        self.assertGreaterEqual(result["summary"]["candidate_region_count"], 1)
        self.assertTrue(result["pairs"][0]["regions"][0]["target_near_element_ids"])

    def test_typical_t_joint_shells_create_candidate(self):
        # Horizontal target plate in z=0; vertical source plate has its free
        # bottom edge at z=0.1 along the same x node line.
        nodes_a, elements_a = strip(10, 0.0, node_start=1, element_start=1)
        nodes_b = {}
        for index in range(4):
            nodes_b[101 + index] = (float(index), 0.0, 0.1)
            nodes_b[105 + index] = (float(index), 0.0, 1.1)
        elements_b = [
            {"element_id": 101 + index, "component_id": 20, "element_type": "CQUAD4", "node_ids": [101 + index, 102 + index, 106 + index, 105 + index]}
            for index in range(3)
        ]
        result = detect(
            [{"id": 10, "name": "HORIZONTAL"}, {"id": 20, "name": "VERTICAL"}],
            {**nodes_a, **nodes_b}, elements_a + elements_b, dict(SETTINGS),
        )
        self.assertEqual(1, result["summary"]["candidate_pair_count"])

    def test_separated_components_create_no_pair(self):
        components, nodes, elements = model(offset=10.0)
        result = detect(components, nodes, elements, dict(SETTINGS))
        self.assertEqual([], result["pairs"])

    def test_corner_only_is_filtered(self):
        components, nodes, elements = model(offset=0.1, second_start=2.9, second_segments=3)
        result = detect(components, nodes, elements, dict(SETTINGS))
        self.assertEqual([], result["pairs"])

    def test_pair_direction_is_unique(self):
        components, nodes, elements = model()
        result = detect(components, nodes, elements, dict(SETTINGS))
        keys = [(min(row["component_a"]["id"], row["component_b"]["id"]), max(row["component_a"]["id"], row["component_b"]["id"])) for row in result["pairs"]]
        self.assertEqual(len(keys), len(set(keys)))

    def test_shared_nodes_are_ignored(self):
        components, nodes, elements = model()
        for element in elements:
            if element["component_id"] == 20:
                element["node_ids"] = [value - 100 if value <= 104 else value for value in element["node_ids"]]
        result = detect(components, nodes, elements, dict(SETTINGS))
        self.assertEqual([], result["pairs"])

    def test_two_distant_regions_are_retained_in_one_pair(self):
        nodes_a, elements_a = strip(10, 0.0, segments=8, node_start=1, element_start=1)
        nodes_b1, elements_b1 = strip(20, 0.1, start=0.0, segments=2, node_start=101, element_start=101)
        nodes_b2, elements_b2 = strip(20, 0.1, start=6.0, segments=2, node_start=201, element_start=201)
        settings = dict(SETTINGS); settings["min_contact_length"] = 1.0
        result = detect(
            [{"id": 10, "name": "A"}, {"id": 20, "name": "B"}],
            {**nodes_a, **nodes_b1, **nodes_b2}, elements_a + elements_b1 + elements_b2, settings,
        )
        self.assertEqual(1, len(result["pairs"]))
        self.assertEqual(2, result["pairs"][0]["candidate_region_count"])

    def test_many_separated_components_are_coarsely_filtered(self):
        components, nodes, elements = [], {}, []
        for index in range(80):
            component_id = index + 1
            part_nodes, part_elements = strip(component_id, index * 10.0, segments=2, node_start=1 + index * 20, element_start=1 + index * 10)
            components.append({"id": component_id, "name": "C{}".format(component_id)})
            nodes.update(part_nodes); elements.extend(part_elements)
        result = detect(components, nodes, elements, dict(SETTINGS))
        self.assertEqual(0, result["summary"]["candidate_pair_count"])


if __name__ == "__main__":
    unittest.main()
