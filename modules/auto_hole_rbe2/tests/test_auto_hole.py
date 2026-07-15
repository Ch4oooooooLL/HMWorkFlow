from __future__ import annotations

import math
import importlib.util
import unittest
from pathlib import Path

from duplicate_detector import annotate, build_index
from face_segmentation import segment_faces
from hole_evaluator import evaluate
from mesh_model import Component, Element, MeshModel
from solid_surface import Face, extract

SPEC = importlib.util.spec_from_file_location(
    "auto_hole_test_schema", str(Path(__file__).resolve().parents[1] / "python" / "schema.py")
)
AUTO_SCHEMA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTO_SCHEMA)
DEFAULTS = AUTO_SCHEMA.DEFAULTS


def tube_faces(count=8, radius=5.0, length=10.0, start_id=1, alternating=0.0):
    nodes, faces = {}, []
    for layer, z in enumerate((0.0, length)):
        for index in range(count):
            value = radius + (alternating if index % 2 else -alternating)
            angle = 2.0 * math.pi * index / count
            nodes[start_id + layer * count + index] = (value * math.cos(angle), value * math.sin(angle), z)
    for index in range(count):
        following = (index + 1) % count
        ids = (
            start_id + index,
            start_id + following,
            start_id + count + following,
            start_id + count + index,
        )
        radial_angle = 2.0 * math.pi * (index + 0.5) / count
        faces.append(Face("F{:03d}".format(start_id + index), start_id + index, ids, (-math.cos(radial_angle), -math.sin(radial_angle), 0.0)))
    model = MeshModel({1: Component(1, "SOLID", "SOLID")}, nodes, {
        face.element_id: Element(face.element_id, 1, "CHEXA", face.node_ids + face.node_ids) for face in faces
    })
    return model, faces


class HoleEvaluationTests(unittest.TestCase):
    def settings(self, **changes):
        value = dict(DEFAULTS)
        value.update(changes)
        return value

    def candidate(self, **settings):
        model, faces = tube_faces()
        result, reason = evaluate(model, [face.face_id for face in faces], {face.face_id: face for face in faces}, self.settings(**settings))
        return model, result, reason

    def test_standard_through_hole(self):
        _, result, reason = self.candidate()
        self.assertEqual(reason, "")
        self.assertAlmostEqual(result["diameter"], 10.0)
        self.assertEqual(len(result["boundary_loops"]), 2)

    def test_radius_limits(self):
        _, result, reason = self.candidate(minRadius=6.0)
        self.assertIsNone(result)
        self.assertEqual(reason, "RADIUS_BELOW_MIN")

    def test_non_circular_channel(self):
        model, faces = tube_faces(alternating=2.0)
        result, reason = evaluate(model, [face.face_id for face in faces], {face.face_id: face for face in faces}, self.settings(cylFitTol=0.1))
        self.assertIsNone(result)
        self.assertEqual(reason, "CYLINDER_FIT")

    def test_blind_hole_pattern_is_rejected(self):
        model, faces = tube_faces()
        cap = Face("CAP", 999, tuple(range(1, 9)), (0.0, 0.0, 1.0))
        faces.append(cap)
        result, reason = evaluate(model, [face.face_id for face in faces], {face.face_id: face for face in faces}, self.settings())
        self.assertIsNone(result)
        self.assertTrue(reason.startswith("BOUNDARY_LOOP_COUNT"))

    def test_local_wall_gap_is_rejected(self):
        model, faces = tube_faces()
        faces.pop()
        result, reason = evaluate(model, [face.face_id for face in faces], {face.face_id: face for face in faces}, self.settings())
        self.assertIsNone(result)
        self.assertTrue(reason.startswith("BOUNDARY_LOOP_COUNT"))

    def test_adjacent_holes_remain_separate_segments(self):
        model1, faces1 = tube_faces(start_id=1)
        model2, faces2 = tube_faces(start_id=100)
        model1.nodes.update({node: (xyz[0] + 20.0, xyz[1], xyz[2]) for node, xyz in model2.nodes.items()})
        segments, _ = segment_faces(faces1 + faces2, 78.0)
        self.assertEqual(len(segments), 2)

    def test_existing_rbe2_exact_node_set(self):
        model, result, _ = self.candidate()
        result["wall_node_ids"] = sorted(model.nodes)
        index = build_index([{"element_id": 77, "dependent_node_ids": list(reversed(sorted(model.nodes)))}])
        annotate(result, index)
        self.assertEqual(result["existing_rbe2_id"], 77)
        self.assertEqual(result["recommended_action"], "SKIP_EXISTING")

    def test_same_center_different_nodes_is_not_duplicate(self):
        _, result, _ = self.candidate()
        index = build_index([{"element_id": 77, "dependent_node_ids": [900, 901]}])
        annotate(result, index)
        self.assertIsNone(result["existing_rbe2_id"])


class SolidSurfaceTests(unittest.TestCase):
    def test_cpenta_and_ctetra_are_supported(self):
        components = {1: Component(1, "MIX", "SOLID")}
        nodes = {
            1: (0, 0, 0), 2: (1, 0, 0), 3: (0, 1, 0), 4: (0, 0, 1),
            5: (1, 0, 1), 6: (0, 1, 1), 7: (2, 0, 0), 8: (2, 1, 0),
            9: (2, 0, 1), 10: (2, 1, 1),
        }
        elements = {
            1: Element(1, 1, "CTETRA", (1, 2, 3, 4)),
            2: Element(2, 1, "CPENTA", (2, 7, 3, 5, 9, 6)),
        }
        faces, warnings = extract(MeshModel(components, nodes, elements), [1], 1.0e-9)
        self.assertEqual(warnings, [])
        self.assertGreaterEqual(len(faces), 7)


if __name__ == "__main__":
    unittest.main()
