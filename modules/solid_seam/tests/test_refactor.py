"""Exercise actual Tcl procedures without a running HyperMesh model."""
import os
import shutil
import subprocess
import unittest
from pathlib import Path


class RefactorTests(unittest.TestCase):
    def test_tcl_behaviour(self):
        candidates = [os.environ.get("TCLSH"), shutil.which("tclsh")]
        if os.name == "nt":
            for base in (Path("D:/Program Files/Altair"), Path("C:/Program Files/Altair")):
                candidates.extend(str(p) for p in base.glob("*/hw/tcl/*/win64/bin/tclsh85t.exe"))
        interpreter = next((p for p in candidates if p and Path(p).is_file()), None)
        if not interpreter:
            self.skipTest("Set TCLSH to a Tcl 8.5+ interpreter")
        for filename, marker in (("refactor_offline.tcl", "PASS all refactor checks"),
                                 ("auto_group_offline.tcl", "PASS AutoGroup checks"),
                                 ("cache_offline.tcl", "PASS detection cache checks"),
                                 ("prefetch_offline.tcl", "PASS prefetch checks"),
                                 ("classification_offline.tcl", "PASS classification checks"),
                                 ("speed_offline.tcl", "PASS speed checks"),
                                 ("diagnostics_offline.tcl", "PASS solid seam diagnostics checks"),
                                 ("face_distance_parameterized_benchmark.tcl", "PASS parameterized face-distance benchmark")):
            with self.subTest(script=filename):
                script = Path(__file__).with_name(filename)
                result = subprocess.run([interpreter, str(script)], stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, universal_newlines=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(marker, result.stdout)
