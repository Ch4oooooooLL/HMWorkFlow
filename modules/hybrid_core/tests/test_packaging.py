from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]


class PackagingScriptTests(unittest.TestCase):
    def test_powershell_packaging_uses_a_local_python_for_self_test(self):
        source = (ROOT / "build_package.ps1").read_text(encoding="utf-8")

        self.assertIn("Resolve-LocalPythonCommand", source)
        self.assertIn("$LocalPython", source)
        self.assertNotIn("& $PortablePythonExe $RuntimeSelfTest", source)

    def test_embedded_runtime_points_at_the_manually_unpacked_standard_library(self):
        entries = [
            line.strip()
            for line in (ROOT / "runtime/python/windows-x64/python38._pth").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]

        self.assertIn("python38", entries)
        self.assertNotIn("python38.zip", entries)
        self.assertTrue((ROOT / "runtime/python/windows-x64/python38.zip").is_file())

    def test_packaging_excludes_locally_unpacked_standard_library(self):
        powershell = (ROOT / "build_package.ps1").read_text(encoding="utf-8")
        shell = (ROOT / "build_package.sh").read_text(encoding="utf-8")

        self.assertIn('Remove-Item -LiteralPath $StagedUnpackedStdlib -Recurse -Force', powershell)
        self.assertIn('rm -rf "$STAGED_UNPACKED_STDLIB"', shell)


if __name__ == "__main__":
    unittest.main()
