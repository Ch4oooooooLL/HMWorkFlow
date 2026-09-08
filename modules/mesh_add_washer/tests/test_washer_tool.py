"""Exercise the mesh Add Washer Tcl logic without a running HyperMesh model."""
import os
import shutil
import subprocess
import unittest
from pathlib import Path


class WasherToolOfflineTests(unittest.TestCase):
    def test_tcl_behaviour(self):
        candidates = [os.environ.get("TCLSH"), shutil.which("tclsh")]
        if os.name == "nt":
            for base in (Path("D:/Program Files/Altair"), Path("C:/Program Files/Altair")):
                candidates.extend(str(p) for p in base.glob("*/hw/tcl/*/win64/bin/tclsh85t.exe"))
        interpreter = next((p for p in candidates if p and Path(p).is_file()), None)
        if not interpreter:
            self.skipTest("Set TCLSH to a Tcl 8.5+ interpreter")
        script = Path(__file__).with_name("washer_offline.tcl")
        result = subprocess.run([interpreter, str(script)], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SELFTEST OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
