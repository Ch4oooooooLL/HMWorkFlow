import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
GENERATOR = ROOT / "examples" / "RBE2_Washer_Stress" / "generate_fem.py"


class StressGeneratorTests(unittest.TestCase):
    def test_smoke_model_has_mixed_washers_and_expected_rbe2_count(self):
        with tempfile.TemporaryDirectory() as directory:
            fem = Path(directory) / "stress.fem"
            manifest = Path(directory) / "stress.json"
            completed = subprocess.run(
                [sys.executable, str(GENERATOR), "--preset", "smoke", "--output", str(fem), "--manifest", str(manifest)],
                check=True,
                capture_output=True,
                text=True,
            )
            data = json.loads(manifest.read_text(encoding="utf-8"))
            deck = fem.read_text(encoding="utf-8")

            self.assertIn('"expected_rbe2_count": 12', completed.stdout)
            self.assertEqual(data["expected"]["created_rbe2"], 12)
            self.assertEqual(set(data["expected"]["rbe2_by_case"]), {
                "D07P5_W04_W06", "D11_W04_W06", "D16_W06_W08", "D25_W08_W08"
            })
            self.assertEqual(data["expected"]["precreated_rbe2"], 0)
            self.assertNotIn("RBE2,", deck)
            self.assertEqual(deck.count('$HMNAME COMP '), 1)
            self.assertTrue(deck.rstrip().endswith("ENDDATA"))


if __name__ == "__main__":
    unittest.main()
