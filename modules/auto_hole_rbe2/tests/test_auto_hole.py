from __future__ import annotations

import math
import importlib.util
import json
import tempfile
import time
import unittest
from pathlib import Path

from duplicate_detector import annotate, build_index
from face_segmentation import segment_faces
from hole_evaluator import evaluate
from main import main as cli_main
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
    def test_precomputed_shell_faces_are_consumed_directly(self):
        model, faces = tube_faces()
        shell_elements = {
            index: Element(index, 1, "CQUAD4", face.node_ids)
            for index, face in enumerate(faces, 1)
        }
        surface_model = MeshModel(model.components, model.nodes, shell_elements)

        extracted, warnings = extract(surface_model, [1], 1.0e-9)

        self.assertEqual(warnings, [])
        self.assertEqual(len(extracted), len(faces))
        self.assertEqual(
            {tuple(face.node_ids) for face in extracted},
            {tuple(face.node_ids) for face in faces},
        )

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


class SurfaceSegmentationPerformanceTests(unittest.TestCase):
    def test_many_disconnected_surface_faces_do_not_degrade_quadratically(self):
        count = 20000
        faces = [
            Face(
                "S{:06d}".format(index),
                index + 1,
                (3 * index + 1, 3 * index + 2, 3 * index + 3),
                (0.0, 0.0, 1.0),
            )
            for index in range(count)
        ]

        started = time.perf_counter()
        segments, _ = segment_faces(faces, 78.0)
        elapsed = time.perf_counter() - started

        self.assertEqual(len(segments), count)
        self.assertLess(elapsed, 2.0)


class TclWorkflowContractTests(unittest.TestCase):
    def source(self, relative_path):
        return (Path(__file__).resolve().parents[1] / relative_path).read_text(encoding="utf-8")

    def test_export_collects_free_face_node_ids_before_writing_mesh(self):
        source = self.source("tcl/exporter.tcl")
        self.assertIn("proc ::AutoHoleRBE2::collectHybridSurfaceFaces", source)
        self.assertIn("proc ::AutoHoleRBE2::bulkFaceNodeMap", source)
        self.assertIn("mark=2 dataname=nodes", source)
        self.assertIn("proc ::AutoHoleRBE2::bulkNodeCoordinateMap", source)
        self.assertIn("mark=2 dataname=coordinates", source)
        self.assertNotIn("concat $allNodes", source)
        self.assertNotIn('"by comps on mark"', source)
        export_body = source[source.index("proc ::AutoHoleRBE2::exportHybridInputs"):]
        self.assertLess(
            export_body.index("collectHybridSurfaceFaces"),
            export_body.index("writeHybridMesh"),
        )

    def test_candidate_creation_uses_bulk_ui_mode_and_single_validation(self):
        main_source = self.source("../auto_hole_rbe2.tcl")
        executor = self.source("tcl/executor.tcl")

        self.assertIn("proc ::AutoHoleRBE2::beginBulkCreate", main_source)
        self.assertIn("proc ::AutoHoleRBE2::endBulkCreate", main_source)
        self.assertIn("beginBulkCreate", executor)
        self.assertIn("endBulkCreate", executor)
        self.assertNotIn("hybridNodeExists $nodeId", executor)
        self.assertNotIn("rbe2DependentNodeKey $elementId", executor)

    def test_python_delta_import_is_primary_and_legacy_creation_is_fallback(self):
        main_source = self.source("python/main.py")
        bridge = self.source("tcl/bridge.tcl")
        exporter = self.source("tcl/exporter.tcl")
        executor = self.source("tcl/executor.tcl")
        self.assertIn("write_rigid_incremental_fem", main_source)
        self.assertIn("--delta", bridge)
        self.assertIn("incrementalModelStateJson", exporter)
        self.assertIn("importRigidDelta", executor)
        self.assertIn("executePythonCandidatesLegacy", executor)

    def test_creation_failure_has_explicit_rollback(self):
        source = self.source("../auto_hole_rbe2.tcl")
        self.assertIn("proc ::AutoHoleRBE2::cleanupFailedRBE2", source)
        self.assertIn("proc ::AutoHoleRBE2::latestCreatedEntityIds", source)
        create_body = source[source.index("proc ::AutoHoleRBE2::createRBE2"):]
        self.assertIn("cleanupFailedRBE2", create_body)
        self.assertIn("latestCreatedEntityIds", create_body)

    def test_workflow_populates_completion_statistics(self):
        source = self.source("tcl/workflow.tcl")
        for field in ("sourceElems", "freeFaces", "validFaces", "segments", "failed"):
            self.assertIn("stat({})".format(field), source)

    def test_python_result_caps_rejection_details_and_writes_once(self):
        source = self.source("python/main.py")
        self.assertIn("MAX_REJECT_SAMPLES", source)
        self.assertIn("reject_reason_counts", source)
        self.assertEqual(source.count("write_result("), 1)


class IncrementalCliIntegrationTests(unittest.TestCase):
    def test_surface_mesh_cli_writes_grid_and_rbe2_delta(self):
        model, faces = tube_faces()
        settings = dict(DEFAULTS)
        settings.update({"rigidType": "RBE2", "dof": "123456", "outputComponentName": "RBE2_HOLE_AUTO"})
        request = {
            "schema_version": "1.0", "module": "auto_hole_rbe2",
            "run_id": "solid-hole-integration", "hypermesh_version": "2019",
            "selected_component_ids": [1], "settings": settings,
            "id_state": {"max_node_id": max(model.nodes), "max_element_id": max(face.element_id for face in faces), "max_component_id": 1},
            "entity_registry": {"components": {}, "properties": {}, "materials": {}},
            "options": {"debug": False, "keep_runtime_files": True},
        }
        mesh = {
            "schema_version": "1.0",
            "components": [{"component_id": 1, "component_name": "SOLID", "mesh_class": "SOLID"}],
            "nodes": [[node_id, *xyz] for node_id, xyz in model.nodes.items()],
            "elements": [{"element_id": index, "component_id": 1, "element_type": "CQUAD4", "node_ids": list(face.node_ids)} for index, face in enumerate(faces, 1)],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request_path = root / "request.json"; mesh_path = root / "mesh.json"; existing_path = root / "existing.json"
            delta_path = root / "rigids.fem"; result_path = root / "result.json"; tcl_path = root / "result.tcl"; log_path = root / "operation.log"
            request_path.write_text(json.dumps(request), encoding="utf-8")
            mesh_path.write_text(json.dumps(mesh), encoding="utf-8")
            existing_path.write_text(json.dumps({"rbe2": []}), encoding="utf-8")
            code = cli_main(["--request", str(request_path), "--mesh", str(mesh_path), "--existing", str(existing_path), "--delta", str(delta_path), "--output", str(result_path), "--tcl-output", str(tcl_path), "--log", str(log_path)])
            self.assertEqual(code, 0)
            result = json.loads(result_path.read_text(encoding="utf-8"))
            self.assertEqual(result["summary"]["planned_create_count"], 1)
            delta = delta_path.read_text(encoding="utf-8")
            self.assertIn("GRID,", delta)
            self.assertIn("RBE2,", delta)


if __name__ == "__main__":
    unittest.main()
