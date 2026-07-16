import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path

from fem_io import FemParseError, read_fem
from incremental_fem import IncrementalFemError, write_incremental_fem
from main import main as cli_main
from rbe2_analyzer import analyze
from grouping import build
from pair_planner import plan


SPEC = importlib.util.spec_from_file_location(
    "bolt_fem_schema",
    str(Path(__file__).resolve().parents[1] / "python" / "schema.py"),
)
SCHEMA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCHEMA)


SOURCE_FEM = """$ generated selection
BEGIN BULK
GRID,1,,0.0,0.0,0.0
GRID,2,,5.0,0.0,0.0
GRID,3,,-5.0,0.0,0.0
GRID,4,,0.0,5.0,0.0
GRID,5,,0.0,-5.0,0.0
GRID,10,,0.0,0.0,20.0
GRID,11,,5.0,0.0,20.0
GRID,12,,-5.0,0.0,20.0
GRID,13,,0.0,5.0,20.0
GRID,14,,0.0,-5.0,20.0
RBE2,100,1,123456,2,3
+,4,5
RBE2,101,10,123456,11,12,13,14
ENDDATA
"""


def request(**overrides):
    settings = dict(SCHEMA.DEFAULTS)
    settings.update(overrides.pop("settings", {}))
    data = {
        "settings": settings,
        "id_state": {
            "max_node_id": 100,
            "max_element_id": 1000,
            "max_property_id": 2000,
            "max_material_id": 3000,
        },
        "entity_registry": {"properties": {}, "materials": {}, "components": {}},
    }
    data.update(overrides)
    return data


class FemIoTests(unittest.TestCase):
    def test_reads_grid_rbe2_continuation_and_builds_mesh_model(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "selection.fem"
            path.write_text(SOURCE_FEM, encoding="utf-8")
            parsed = read_fem(path)
        self.assertEqual(parsed.model.nodes[10], (0.0, 0.0, 20.0))
        self.assertEqual(parsed.model.elements[100].node_ids, (1, 2, 3, 4, 5))

    def test_existing_beam_is_indexed_by_unordered_endpoint_pair(self):
        text = SOURCE_FEM.replace("ENDDATA", "CBEAM,900,77,10,1,0.,1.,0.\nENDDATA")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "selection.fem"
            path.write_text(text, encoding="utf-8")
            parsed = read_fem(path)
        self.assertEqual(parsed.existing_segments[(1, 10)], 900)

    def test_reports_card_and_line_for_missing_grid_reference(self):
        text = SOURCE_FEM.replace("11,12,13,14", "11,12,13,999")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.fem"
            path.write_text(text, encoding="utf-8")
            with self.assertRaisesRegex(FemParseError, r"RBE2 101.*missing GRID 999.*line"):
                read_fem(path)


class IncrementalFemTests(unittest.TestCase):
    def _plans(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "selection.fem"
            path.write_text(SOURCE_FEM, encoding="utf-8")
            parsed = read_fem(path)
        settings = dict(SCHEMA.DEFAULTS)
        records, _ = analyze(parsed.model, settings)
        groups = build(records, settings)
        plans, _ = plan(groups, settings)
        return plans

    def test_writes_existing_endpoint_grids_and_cbeam_cards(self):
        plans = self._plans()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "bolt_import.fem"
            manifest = write_incremental_fem(output, plans, request())
            text = output.read_text(encoding="utf-8")
        self.assertIn("MAT1,3001,210000", text)
        self.assertIn("PBEAM,2001,3001", text)
        self.assertIn("GRID,1,,0,0,0", text)
        self.assertIn("GRID,10,,0,0,20", text)
        self.assertIn("CBEAM,1001,2001,1,10", text)
        self.assertNotIn("RBE2,", text)
        self.assertEqual(manifest["created_element_ids"], [1001])
        self.assertEqual(manifest["temporary_node_ids"], [])
        self.assertEqual(manifest["endpoint_replacements"], [])
        self.assertTrue(manifest["reuse_existing_node_ids"])
        self.assertEqual(manifest["expected_segments"][0]["node_1"], 1)
        self.assertEqual(manifest["expected_segments"][0]["node_2"], 10)
        assignment = manifest["property_assignments"][0]
        self.assertEqual(assignment["component_name"], "BOLT_D10_CBEAM")
        self.assertEqual(assignment["property_name"], "BOLT_D10_PBEAM")
        self.assertEqual(assignment["beam_section_name"], "BOLT_D10_SOLID_CIRCLE")
        self.assertEqual(assignment["element_ids"], [1001])
        self.assertTrue(assignment["create_solid_circle"])

    def test_reuses_registered_property_without_emitting_property_or_material(self):
        plans = self._plans()
        req = request(
            entity_registry={
                "properties": {"BOLT_D10_PBEAM": 77},
                "materials": {"steel": 88},
                "components": {},
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "bolt_import.fem"
            manifest = write_incremental_fem(output, plans, req)
            text = output.read_text(encoding="utf-8")
        self.assertNotIn("PBEAM,", text)
        self.assertNotIn("MAT1,", text)
        self.assertIn("CBEAM,1001,77,1,10", text)
        self.assertEqual(manifest["reused_property_ids"], [77])

    def test_reuses_registered_output_component(self):
        plans = self._plans()
        req = request(
            entity_registry={
                "properties": {"BOLT_D10_PBEAM": 77},
                "materials": {},
                "components": {"BOLT_D10_CBEAM": 66},
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "bolt_import.fem"
            manifest = write_incremental_fem(output, plans, req)
            text = output.read_text(encoding="utf-8")
        self.assertIn("$HMCOMP ID 66", text)
        self.assertNotIn('$HMNAME COMP 66', text)
        self.assertEqual(manifest["reused_component_ids"], [66])

    def test_shared_endpoint_emits_one_existing_grid_card(self):
        plans = self._plans()
        duplicate = dict(plans[0])
        duplicate["candidate_id"] = "duplicate"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "bolt_import.fem"
            manifest = write_incremental_fem(output, [plans[0], duplicate], request())
            text = output.read_text(encoding="utf-8")
        self.assertEqual(manifest["temporary_node_ids"], [])
        self.assertEqual(sum(line.startswith("GRID,") for line in text.splitlines()), 2)
        self.assertEqual(len(manifest["created_element_ids"]), 2)

    def test_coincident_distinct_endpoints_keep_their_original_ids(self):
        plans = self._plans()
        second = copy.deepcopy(plans[0])
        second["candidate_id"] = "coincident-distinct"
        second["node_1"] = 999
        with tempfile.TemporaryDirectory() as directory:
            manifest = write_incremental_fem(
                Path(directory) / "bolt_import.fem", [plans[0], second], request()
            )
            text = (Path(directory) / "bolt_import.fem").read_text(encoding="utf-8")
        self.assertIn("GRID,1,,0,0,0", text)
        self.assertIn("GRID,999,,0,0,0", text)
        self.assertEqual(manifest["endpoint_replacements"], [])

    def test_custom_property_must_exist_in_current_hypermesh_model(self):
        plans = self._plans()
        req = request(settings={"propName": "PROJECT_BOLT"})
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "bolt_import.fem"
            with self.assertRaisesRegex(IncrementalFemError, "PROJECT_BOLT.*not present"):
                write_incremental_fem(output, plans, req)

    def test_existing_endpoint_reuse_does_not_require_max_node_id(self):
        plans = self._plans()
        req = request()
        del req["id_state"]["max_node_id"]
        with tempfile.TemporaryDirectory() as directory:
            manifest = write_incremental_fem(Path(directory) / "bolt_import.fem", plans, req)
        self.assertTrue(manifest["reuse_existing_node_ids"])

    def test_dry_run_writes_no_import_file(self):
        plans = self._plans()
        req = request(settings={"dryRun": True})
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "bolt_import.fem"
            manifest = write_incremental_fem(output, plans, req)
            self.assertFalse(output.exists())
        self.assertEqual(manifest["created_element_ids"], [])

    def test_cli_reads_fem_and_writes_delta_and_auditable_result(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            source = directory / "selection.fem"
            source.write_text(SOURCE_FEM, encoding="utf-8")
            request_path = directory / "request.json"
            request_path.write_text(
                __import__("json").dumps(
                    {
                        "schema_version": "1.0",
                        "module": "rbe2_bolt_connector",
                        "run_id": "test-run",
                        "hypermesh_version": "2019",
                        "selected_component_ids": [],
                        "settings": dict(SCHEMA.DEFAULTS),
                        "id_state": request()["id_state"],
                        "entity_registry": request()["entity_registry"],
                        "options": {"debug": False, "keep_runtime_files": True},
                    }
                ),
                encoding="utf-8",
            )
            delta = directory / "bolt_import.fem"
            result = directory / "result.json"
            tcl_result = directory / "result.tcl"
            code = cli_main(
                [
                    "--request", str(request_path), "--mesh", str(source),
                    "--delta", str(delta), "--output", str(result),
                    "--tcl-output", str(tcl_result), "--log", str(directory / "operation.log"),
                ]
            )
            payload = __import__("json").loads(result.read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(payload["summary"]["created_element_ids"], [1001])
        self.assertEqual(payload["summary"]["incremental_fem"], str(delta.resolve()))


class TclImportContractTests(unittest.TestCase):
    def test_executor_uses_same_session_fe_import_and_has_diagnostic_stages(self):
        source = (Path(__file__).resolve().parents[1] / "tcl" / "executor.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn("*feinputwithdata2", source)
        self.assertIn("INCREMENTAL_IMPORT_FAILED", source)
        self.assertIn("incremental_fem", source)
        self.assertIn("expected_element_ids", source)
        self.assertIn("cleanupIncrementalBoltImport", source)
        self.assertIn("created_property_ids", source)
        self.assertIn("created_material_ids", source)
        self.assertIn("reuse_existing_node_ids", source)
        self.assertIn("*feinputwithdata2 $reader [file nativename $incrementalFem] 1", source)
        self.assertNotIn("*equivalence nodes", source)
        self.assertIn("configureImportedBoltAssignments", source)
        self.assertIn("property_assignments", source)
        workflow = (Path(__file__).resolve().parents[1] / "tcl" / "workflow.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn("tk_messageBox -icon error", workflow)
        self.assertIn("task workspace", workflow)

    def test_hm2019_node_replacement_uses_positional_target_location(self):
        full_source = (Path(__file__).resolve().parents[2] / "rbe2_bolt_connector.tcl").read_text(
            encoding="utf-8"
        )
        start = full_source.index("proc ::RB2Bolt::nodeEntityExists")
        end = full_source.index("\nproc ::RB2Bolt::nodeDistanceById", start)
        body = full_source[start:end]
        self.assertIn("*replacenodes $sourceNode $targetNode 1 0", body)
        self.assertNotIn("source_node=", body)
        self.assertNotIn("source_list=", body)
        self.assertIn("$value == 0", body)
        self.assertIn("SOLID_CIRCLE", full_source)
        self.assertIn("*beamsectioncreatestandardsolver 11 0 HMCirc 0", full_source)
        self.assertIn("$attributeId=[list beamsects $beamSectId]", full_source)

    def test_default_selection_mode_is_components(self):
        source = (Path(__file__).resolve().parents[2] / "rbe2_bolt_connector.tcl").read_text(
            encoding="utf-8"
        )
        self.assertRegex(source, r"selectMode\s+components")


if __name__ == "__main__":
    unittest.main()
