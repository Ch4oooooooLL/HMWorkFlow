from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import tkinter
import unittest
from pathlib import Path

PYTHON_DIR = Path(__file__).resolve().parents[1] / "python"
sys.path.insert(0, str(PYTHON_DIR))

from hmworkflow.weld_integrity_check.main import main  # noqa: E402
from hmworkflow.weld_integrity_check.fem_reader import FemInputError, read_fem_bundle  # noqa: E402
from modules.weld_integrity_check.tests.test_detector import SETTINGS, model  # noqa: E402


class MainIntegrationTests(unittest.TestCase):
    def test_tcl_exporter_uses_native_fem_without_mesh_traversal(self):
        exporter_path = PYTHON_DIR.parent / "tcl" / "exporter.tcl"
        exporter = exporter_path.read_text(encoding="utf-8")
        self.assertIn("*feoutput_select", exporter)
        self.assertIn("mesh_manifest.json", exporter)
        self.assertNotIn("dataname=nodes", exporter)
        self.assertNotIn("dataname=x", exporter)
        self.assertNotIn("nodes.csv", exporter)
        self.assertNotIn("elements.csv", exporter)
        interpreter = tkinter.Tcl()
        interpreter.eval("namespace eval ::WeldIntegrityCheck {}")
        interpreter.eval("source {{{}}}".format(exporter_path.as_posix()))

    def test_fixed_field_fem_restores_component_ownership_from_manifest(self):
        def card(*fields):
            return "".join(str(field).ljust(8) for field in fields).rstrip()

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fem = root / "selected_components.fem"
            fem.write_text("\n".join((
                "BEGIN BULK",
                card("GRID", 1, "", 0.0, 0.0, 0.0),
                card("GRID", 2, "", 1.0, 0.0, 0.0),
                card("GRID", 3, "", 0.0, 1.0, 0.0),
                card("GRID", 11, "", 0.0, 0.1, 0.0),
                card("GRID", 12, "", 1.0, 0.1, 0.0),
                card("GRID", 13, "", 0.0, 1.1, 0.0),
                card("CTRIA3", 100, 900, 1, 2, 3),
                card("CTRIA3", 200, 900, 11, 12, 13),
                "ENDDATA",
            )) + "\n", encoding="utf-8")
            manifest = {
                "format": "hm_weld_integrity_fem",
                "fem_path": fem.name,
                "components": [
                    {"component_id": 10, "component_name": "A", "element_ids": [100]},
                    {"component_id": 20, "component_name": "B", "element_ids": [200]},
                ],
            }
            manifest_path = root / "mesh_manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            components, nodes, elements = read_fem_bundle(manifest_path)
            self.assertEqual([10, 20], [row["id"] for row in components])
            self.assertEqual({10, 20}, {row["component_id"] for row in elements})
            self.assertEqual(6, len(nodes))

            manifest["components"][1]["element_ids"] = []
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(FemInputError, "no HyperMesh component mapping"):
                read_fem_bundle(manifest_path)

    def test_entry_imports_through_persistent_worker_style_loader(self):
        # HyperMesh does not launch main.py as a script. Its long-lived worker
        # uses spec_from_file_location, where the entry directory is absent
        # from sys.path unless main.py adds it explicitly.
        original_path = list(sys.path)
        for module_name in ("data_io", "detector", "fem_reader"):
            sys.modules.pop(module_name, None)
        sys.path[:] = [value for value in sys.path if Path(value or ".").resolve() != PYTHON_DIR]
        try:
            spec = importlib.util.spec_from_file_location("_weld_integrity_worker_test", str(PYTHON_DIR / "main.py"))
            self.assertIsNotNone(spec); self.assertIsNotNone(spec.loader)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            self.assertTrue(callable(module.main))
        finally:
            sys.path[:] = original_path

    def test_native_fem_bundle_to_result_and_tcl_sidecar(self):
        components, nodes, elements = model()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); input_dir = root / "input"; output_dir = root / "output"
            input_dir.mkdir(); output_dir.mkdir()
            (input_dir / "settings.json").write_text(json.dumps(SETTINGS), encoding="utf-8")
            fem_lines = ["BEGIN BULK"]
            for node_id, xyz in nodes.items():
                fem_lines.append("GRID,{0},,{1},{2},{3}".format(node_id, *xyz))
            for element in elements:
                # PID is deliberately unrelated to the HyperMesh component;
                # ownership must come from the manifest.
                fem_lines.append("{0},{1},900,{2}".format(
                    element["element_type"], element["element_id"],
                    ",".join(str(value) for value in element["node_ids"]),
                ))
            fem_lines.append("ENDDATA")
            (input_dir / "selected_components.fem").write_text("\n".join(fem_lines) + "\n", encoding="utf-8")
            manifest = {
                "schema_version": "1.0", "format": "hm_weld_integrity_fem",
                "run_id": "TEST", "fem_path": "selected_components.fem",
                "components": [
                    {
                        "component_id": component["id"],
                        "component_name": component["name"],
                        "element_ids": [
                            element["element_id"] for element in elements
                            if element["component_id"] == component["id"]
                        ],
                    }
                    for component in components
                ],
            }
            (input_dir / "mesh_manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            output = output_dir / "result.json"; sidecar = output_dir / "result.tcl"; log = output_dir / "python_log.txt"
            code = main(["--input", str(input_dir), "--output", str(output), "--tcl-output", str(sidecar), "--log", str(log)])
            self.assertEqual(0, code)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertTrue(payload["success"]); self.assertEqual(1, payload["summary"]["candidate_pair_count"])
            self.assertTrue(sidecar.read_text(encoding="utf-8").startswith("# WELD_INTEGRITY_RESULT_V1"))
            self.assertTrue(log.is_file())


if __name__ == "__main__":
    unittest.main()
