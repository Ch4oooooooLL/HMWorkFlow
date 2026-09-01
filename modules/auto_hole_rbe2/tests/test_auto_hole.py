from __future__ import annotations

import math
import importlib.util
import json
import tempfile
import time
import unittest
from pathlib import Path

from hmworkflow.auto_hole_rbe2.duplicate_detector import annotate, build_index
from hmworkflow.auto_hole_rbe2.face_segmentation import segment_faces
from hmworkflow.auto_hole_rbe2.hole_evaluator import evaluate
from hmworkflow.auto_hole_rbe2.main import detect, main as cli_main, read_analysis_mesh
from hmworkflow.auto_hole_rbe2.surface_fem_reader import SurfaceFemError
from hmworkflow.core.mesh_model import Component, Element, MeshModel
from hmworkflow.auto_hole_rbe2.solid_surface import Face, extract

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


def chamfered_tube_faces(
    count=16, radius=5.0, outer_radius=10.0, length=10.0, chamfer_angle_deg=45.0,
):
    """A valid cylindrical wall joined to both openings by conical chamfers."""
    nodes, faces = {}, []
    chamfer_height = (outer_radius - radius) / math.tan(math.radians(chamfer_angle_deg))
    layers = (
        (outer_radius, -chamfer_height), (radius, 0.0),
        (radius, length), (outer_radius, length + chamfer_height),
    )
    for layer, (layer_radius, z) in enumerate(layers):
        for index in range(count):
            angle = 2.0 * math.pi * index / count
            nodes[layer * count + index + 1] = (
                layer_radius * math.cos(angle), layer_radius * math.sin(angle), z,
            )
    element_id = 1
    for band in range(3):
        axial = -1.0 if band == 0 else 0.0 if band == 1 else 1.0
        radial_scale = math.cos(math.radians(chamfer_angle_deg)) if band != 1 else 1.0
        axial_scale = math.sin(math.radians(chamfer_angle_deg)) if band != 1 else 0.0
        for index in range(count):
            following = (index + 1) % count
            ids = (
                band * count + index + 1,
                band * count + following + 1,
                (band + 1) * count + following + 1,
                (band + 1) * count + index + 1,
            )
            angle = 2.0 * math.pi * (index + 0.5) / count
            faces.append(Face(
                "F{:03d}".format(element_id), element_id, ids,
                (-radial_scale * math.cos(angle), -radial_scale * math.sin(angle), axial * axial_scale),
            ))
            element_id += 1
    model = MeshModel({1: Component(1, "SOLID", "SOLID")}, nodes, {
        face.element_id: Element(face.element_id, 1, "CQUAD4", face.node_ids) for face in faces
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

    def test_inner_normal_filter_rejects_outer_cylindrical_surface(self):
        model, faces = tube_faces()
        outer_faces = [
            Face(face.face_id, face.element_id, face.node_ids, tuple(-value for value in face.normal))
            for face in faces
        ]
        result, reason = evaluate(
            model,
            [face.face_id for face in outer_faces],
            {face.face_id: face for face in outer_faces},
            self.settings(requireInnerNormal=True),
        )
        self.assertIsNone(result)
        self.assertEqual(reason, "NOT_INNER_SURFACE")

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

    def test_detection_recovers_cylindrical_wall_from_chamfered_patch(self):
        model, faces = chamfered_tube_faces()
        request = {"selected_component_ids": [1], "settings": self.settings(featureAngleDeg=78.0)}

        candidates = detect(request, model, [], _NullLogger())[2]

        self.assertEqual(len(segment_faces(faces, 78.0)[0]), 1)
        self.assertEqual(len(candidates), 1)
        self.assertAlmostEqual(candidates[0]["diameter"], 10.0)
        self.assertEqual(len(candidates[0]["wall_node_ids"]), 32)
        self.assertIn("ADAPTIVE_PATCH_REFINEMENT", candidates[0]["warnings"])

    def test_refinement_does_not_skip_narrow_valid_feature_angle_window(self):
        model, faces = chamfered_tube_faces(count=12, chamfer_angle_deg=35.0)
        request = {"selected_component_ids": [1], "settings": self.settings(featureAngleDeg=78.0)}

        candidates = detect(request, model, [], _NullLogger())[2]

        self.assertEqual(len(candidates), 1)
        self.assertAlmostEqual(candidates[0]["diameter"], 10.0)
        self.assertGreater(candidates[0]["detection_feature_angle_deg"], 30.0)
        self.assertLess(candidates[0]["detection_feature_angle_deg"], 35.0)


class _NullLogger:
    def exception(self, *_args, **_kwargs):
        pass


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


class NativeSurfaceFemTests(unittest.TestCase):
    def test_missing_shell_cards_reports_actual_fem_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "surface_faces.fem").write_text(
                "BEGIN BULK\nGRID,1,,0.0,0.0,0.0\nPLOTEL,2,1,1\nENDDATA\n",
                encoding="utf-8",
            )
            manifest_path = root / "surface_faces_manifest.json"
            manifest_path.write_text(json.dumps({
                "format": "hm_surface_faces_fem",
                "fem_path": "surface_faces.fem",
                "source_component_id": 1,
            }), encoding="utf-8")

            with self.assertRaises(SurfaceFemError) as caught:
                read_analysis_mesh(manifest_path)

        message = str(caught.exception)
        self.assertIn("GRID=1", message)
        self.assertIn("CTRIA3/CQUAD4=0", message)
        self.assertIn("PLOTEL=1", message)

    def test_native_fem_bundle_preserves_free_face_connectivity_and_node_ids(self):
        model, faces = tube_faces()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fem_path = root / "surface_faces.fem"
            rows = ["BEGIN BULK"]
            rows.extend(
                "GRID,{0},,{1},{2},{3}".format(node_id + 100, *xyz)
                for node_id, xyz in sorted(model.nodes.items())
            )
            rows.extend(
                "CQUAD4,{0},1,{1}".format(
                    index, ",".join(str(node_id + 100) for node_id in face.node_ids)
                )
                for index, face in enumerate(faces, 1)
            )
            rows.append("ENDDATA")
            fem_path.write_text("\n".join(rows) + "\n", encoding="utf-8")
            manifest_path = root / "surface_faces_manifest.json"
            manifest_path.write_text(json.dumps({
                "schema_version": "1.0",
                "format": "hm_surface_faces_fem",
                "fem_path": fem_path.name,
                "source_component_id": 1,
                "source_component_name": "SOLID",
                "element_ids": list(range(1, len(faces) + 1)),
            }), encoding="utf-8")

            restored = read_analysis_mesh(manifest_path)
            candidates = detect(
                {"selected_component_ids": [1], "settings": dict(DEFAULTS)},
                restored, [], _NullLogger(),
            )[2]

        self.assertEqual(set(restored.nodes), {node_id + 100 for node_id in model.nodes})
        self.assertEqual(len(restored.elements), len(faces))
        self.assertEqual(len(candidates), 1)
        self.assertEqual(
            candidates[0]["wall_node_ids"],
            sorted(node_id + 100 for node_id in model.nodes),
        )


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

    def test_export_uses_native_fem_for_generated_free_faces(self):
        source = self.source("tcl/exporter.tcl")
        self.assertIn("proc ::AutoHoleRBE2::collectHybridSurfaceFaces", source)
        self.assertIn("proc ::AutoHoleRBE2::exportHybridSurfaceFem", source)
        self.assertIn("*feoutput_select", source)
        self.assertIn('*createmark elems 1 "by component id" $faceComponentId', source)
        self.assertIn('*createmark nodes 1 "by component id" $faceComponentId', source)
        self.assertIn("surface_faces_manifest.json", source)
        collect_body = source[
            source.index("proc ::AutoHoleRBE2::collectHybridSurfaceFaces"):
            source.index("proc ::AutoHoleRBE2::surfaceFemExportTemplate")
        ]
        self.assertNotIn("bulkFaceNodeMap", collect_body)
        self.assertNotIn("hm_nodelist", collect_body)
        self.assertNotIn("face_elements", source)
        self.assertNotIn("writeHybridMesh $taskDir", source)

    def test_generated_faces_are_mapped_to_optistruct_shell_types_before_export(self):
        source = self.source("tcl/exporter.tcl")
        self.assertIn("proc ::AutoHoleRBE2::prepareSurfaceFacesForFemExport", source)
        self.assertIn("*elementtype 2 1", source)
        self.assertIn("*elementtype 104 1", source)
        self.assertIn("*elementsettypes 1", source)
        self.assertLess(
            source.index("prepareSurfaceFacesForFemExport $faceComponentId"),
            source.index("*feoutput_select"),
        )

    def test_internal_faces_component_is_temporarily_renamed_for_native_export(self):
        source = self.source("tcl/exporter.tcl")
        self.assertIn("proc ::AutoHoleRBE2::temporarySurfaceExportName", source)
        self.assertIn("proc ::AutoHoleRBE2::renameSurfaceExportComponent", source)
        export_body = source[source.index("proc ::AutoHoleRBE2::exportHybridSurfaceFem"):]
        first_rename = export_body.index(
            "renameSurfaceExportComponent $faceComponentId $temporaryName"
        )
        native_export = export_body.index("*feoutput_select")
        restore = export_body.index(
            "renameSurfaceExportComponent $faceComponentId $cfg(faceCompName)"
        )
        self.assertLess(first_rename, native_export)
        self.assertLess(native_export, restore)
        self.assertIn("if {$renamed}", export_body)
        self.assertIn("if {$restoreError ne \"\"}", export_body)

    def test_faces_component_is_deleted_only_after_candidate_execution(self):
        exporter = self.source("tcl/exporter.tcl")
        workflow = self.source("tcl/workflow.tcl")
        export_body = exporter[exporter.index("proc ::AutoHoleRBE2::exportHybridSurfaceFem"):]
        self.assertNotIn("deleteComponentByName", export_body)
        self.assertLess(
            workflow.index("executePythonCandidates $payload"),
            workflow.index("deleteComponentByName"),
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

    def test_python_returns_wall_nodes_and_tcl_creation_is_primary(self):
        main_source = self.source("python/main.py")
        bridge = self.source("tcl/bridge.tcl")
        executor = self.source("tcl/executor.tcl")
        self.assertNotIn("write_rigid_incremental_fem", main_source)
        self.assertIn("--mesh", bridge)
        self.assertIn("executePythonCandidatesLegacy", executor)
        self.assertIn("resolveCandidateWallNodes", executor)
        self.assertIn("hm_getinternalid", executor)
        primary = executor[
            executor.index("proc ::AutoHoleRBE2::executePythonCandidates {payload}"):
            executor.index("proc ::AutoHoleRBE2::executePythonCandidatesBulk {payload}")
        ]
        self.assertNotIn("importRigidDelta", primary)
        self.assertIn("executePythonCandidatesLegacy", primary)

    def test_creation_failure_has_explicit_rollback(self):
        source = self.source("../auto_hole_rbe2.tcl")
        self.assertIn("proc ::AutoHoleRBE2::hybridNodeExists", source)
        self.assertIn("proc ::AutoHoleRBE2::cleanupFailedRBE2", source)
        self.assertIn("proc ::AutoHoleRBE2::latestCreatedEntityIds", source)
        create_body = source[source.index("proc ::AutoHoleRBE2::createRBE2"):]
        self.assertIn("cleanupFailedRBE2", create_body)
        self.assertIn("latestCreatedEntityIds", create_body)

    def test_workflow_populates_completion_statistics(self):
        source = self.source("tcl/workflow.tcl")
        for field in (
            "sourceElems", "freeFaces", "validFaces", "segments", "candidates",
            "adaptiveCandidates", "rejectReasons", "taskDir", "failed",
        ):
            self.assertIn("stat({})".format(field), source)

    def test_zero_candidate_run_surfaces_rejection_reasons_and_task_directory(self):
        workflow = self.source("tcl/workflow.tcl")
        main_source = self.source("../auto_hole_rbe2.tcl")
        self.assertIn("No creatable holes were recognized", workflow)
        self.assertIn("Rejection reasons", main_source)
        self.assertIn("Diagnostics", main_source)

    def test_bugfix_version_is_visible_to_confirm_the_loaded_module(self):
        main_source = self.source("../auto_hole_rbe2.tcl")
        self.assertIn('variable VERSION "1.1.3"', main_source)

    def test_python_result_caps_rejection_details_and_writes_once(self):
        source = self.source("python/main.py")
        self.assertIn("MAX_REJECT_SAMPLES", source)
        self.assertIn("reject_reason_counts", source)
        self.assertEqual(source.count("write_result("), 1)


class IncrementalCliIntegrationTests(unittest.TestCase):
    def test_surface_mesh_cli_returns_wall_nodes_for_tcl_creation(self):
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
            result_path = root / "result.json"; tcl_path = root / "result.tcl"; log_path = root / "operation.log"
            request_path.write_text(json.dumps(request), encoding="utf-8")
            mesh_path.write_text(json.dumps(mesh), encoding="utf-8")
            existing_path.write_text(json.dumps({"rbe2": []}), encoding="utf-8")
            code = cli_main(["--request", str(request_path), "--mesh", str(mesh_path), "--existing", str(existing_path), "--output", str(result_path), "--tcl-output", str(tcl_path), "--log", str(log_path)])
            self.assertEqual(code, 0)
            result = json.loads(result_path.read_text(encoding="utf-8"))
            self.assertEqual(result["summary"]["candidate_count"], 1)
            self.assertEqual(result["candidates"][0]["wall_node_ids"], sorted(model.nodes))


if __name__ == "__main__":
    unittest.main()
