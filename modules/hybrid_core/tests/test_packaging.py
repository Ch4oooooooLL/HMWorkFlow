import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]


def load_release_audit():
    path = ROOT / "tools/release_audit.py"
    spec = importlib.util.spec_from_file_location("release_audit_under_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


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

    def test_packaging_whitelists_distributable_runtime_and_audits_zip(self):
        powershell = (ROOT / "build_package.ps1").read_text(encoding="utf-8")
        shell = (ROOT / "build_package.sh").read_text(encoding="utf-8")

        self.assertIn('"runtime\\python"', powershell)
        self.assertNotIn('    "runtime"\n', powershell)
        self.assertIn('"runtime/python"', shell)
        self.assertNotIn('    "runtime"\n', shell)
        self.assertIn("New-PortableZipArchive", powershell)
        self.assertIn("tools\\release_audit.py", powershell)
        self.assertIn("tools/release_audit.py", shell)

    def test_release_audit_accepts_a_minimal_clean_archive(self):
        audit = load_release_audit()
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "clean.zip"
            manifest = {
                "package_version": "test",
                "build_time_utc": "2026-07-18T00:00:00Z",
                "source_commit": "abc",
                "runtime_version": "3.8.10",
            }
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("HW/VERSION", "test\n")
                archive.writestr("HW/release_manifest.json", json.dumps(manifest))
                archive.writestr("HW/runtime/python/windows-x64/python.exe", b"exe")
                archive.writestr("HW/runtime/python/windows-x64/python38.zip", b"zip")
                archive.writestr("HW/runtime/python/windows-x64/python38._pth", b"python38")
            self.assertEqual([], audit.audit_archive(archive_path))

    def test_release_audit_rejects_runtime_data(self):
        audit = load_release_audit()
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "bad.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("HW/runtime/instances/hm-1/startup.log", "bad")
            errors = audit.audit_archive(archive_path)
            self.assertTrue(any("non-distributable runtime entry" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
