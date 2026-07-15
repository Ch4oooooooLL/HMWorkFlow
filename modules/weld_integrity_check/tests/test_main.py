from __future__ import annotations

import csv
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

PYTHON_DIR = Path(__file__).resolve().parents[1] / "python"
sys.path.insert(0, str(PYTHON_DIR))

from main import main  # noqa: E402
from test_detector import SETTINGS, model  # noqa: E402


class MainIntegrationTests(unittest.TestCase):
    def test_entry_imports_through_persistent_worker_style_loader(self):
        # HyperMesh does not launch main.py as a script. Its long-lived worker
        # uses spec_from_file_location, where the entry directory is absent
        # from sys.path unless main.py adds it explicitly.
        original_path = list(sys.path)
        for module_name in ("data_io", "detector"):
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

    def test_csv_json_to_result_and_tcl_sidecar(self):
        components, nodes, elements = model()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); input_dir = root / "input"; output_dir = root / "output"
            input_dir.mkdir(); output_dir.mkdir()
            (input_dir / "components.json").write_text(json.dumps(components), encoding="utf-8")
            (input_dir / "settings.json").write_text(json.dumps(SETTINGS), encoding="utf-8")
            (input_dir / "free_edges.csv").write_text("component_id,node_1,node_2,owner_element\n", encoding="utf-8")
            with (input_dir / "nodes.csv").open("w", newline="", encoding="utf-8") as stream:
                writer = csv.writer(stream); writer.writerow(("node_id", "x", "y", "z"))
                for node_id, xyz in nodes.items(): writer.writerow((node_id,) + xyz)
            with (input_dir / "elements.csv").open("w", newline="", encoding="utf-8") as stream:
                writer = csv.writer(stream); writer.writerow(("element_id", "component_id", "element_type", "node_ids"))
                for element in elements: writer.writerow((element["element_id"], element["component_id"], element["element_type"], " ".join(str(value) for value in element["node_ids"])))
            output = output_dir / "result.json"; sidecar = output_dir / "result.tcl"; log = output_dir / "python_log.txt"
            code = main(["--input", str(input_dir), "--output", str(output), "--tcl-output", str(sidecar), "--log", str(log)])
            self.assertEqual(0, code)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertTrue(payload["success"]); self.assertEqual(1, payload["summary"]["candidate_pair_count"])
            self.assertTrue(sidecar.read_text(encoding="utf-8").startswith("# WELD_INTEGRITY_RESULT_V1"))
            self.assertTrue(log.is_file())


if __name__ == "__main__":
    unittest.main()
