from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
EXAMPLE = ROOT / "examples" / "FemAutoSeam_Validation"


class LargeCliValidationTests(unittest.TestCase):
    def test_generated_bundle_runs_detect_and_plan_through_production_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            task_dir = Path(directory) / "large_cli"
            process = subprocess.run(
                [
                    sys.executable,
                    str(EXAMPLE / "run_cli.py"),
                    "--output", str(task_dir),
                    "--copies", "1",
                    "--workers", "1",
                    "--max-seconds", "60",
                ],
                cwd=str(ROOT),
                text=True,
                encoding="utf-8",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=60,
            )
            self.assertEqual(0, process.returncode, process.stdout + process.stderr)
            report = json.loads((task_dir / "validation_report.json").read_text(encoding="utf-8"))
            manifest = json.loads((task_dir / "input" / "model_manifest.json").read_text(encoding="utf-8"))
            self.assertEqual("PASS", report["status"])
            self.assertTrue(report["candidate_cache_hit"])
            self.assertGreater(report["ready_plan_count"], 0)
            self.assertGreater(report["created_weld_element_count"], 0)
            self.assertEqual("hm_selected_components_fem", manifest["format"])
            self.assertEqual("model.fem", manifest["fem_path"])
            self.assertTrue((task_dir / "output" / "backend_result.fem").is_file())
            self.assertTrue((task_dir / "output" / "transfer_manifest.json").is_file())


if __name__ == "__main__":
    unittest.main()
