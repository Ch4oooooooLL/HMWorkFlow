import json
import sys
import tempfile
import unittest
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
MODULE_DIR = TEST_DIR.parent / "python"
COMMON_DIR = TEST_DIR.parents[1] / "hybrid_core" / "python"
for directory in (str(MODULE_DIR), str(COMMON_DIR)):
    if directory not in sys.path:
        sys.path.insert(0, directory)

from unused_rbe2_detector import analyze_fem, main


FEM = """$ full-model export
BEGIN BULK
GRID,10,,0.,0.,0.
GRID,11,,1.,0.,0.
GRID,12,,0.,1.,0.
GRID,20,,0.,0.,0.
GRID,21,,1.,0.,0.
GRID,22,,0.,1.,0.
GRID,30,,0.,0.,0.
GRID,31,,1.,0.,0.
GRID,32,,0.,1.,0.
GRID,40,,0.,0.,0.
GRID,50,,0.,0.,0.
GRID,51,,1.,0.,0.
GRID,52,,0.,1.,0.
GRID,60,,0.,0.,0.
GRID,61,,1.,0.,0.
GRID,62,,0.,1.,0.
RBE2,100,10,123456,11,12
CBEAM,200,1,10,40,0.,1.,0.
RBE2,101,20,123456,21,22
RBE2,102,30,123456,31
+,32
RBE3,300,,40,123456,1.0,123456,30,31
RBE2,103,50,123456,51,52
RBE2,104,60,123456,50,61,62
ENDDATA
"""


class UnusedRBE2DetectorTests(unittest.TestCase):
    def write_fem(self, text=FEM):
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "model.fem"
        path.write_text(text, encoding="utf-8")
        return directory, path

    def test_any_other_element_reference_marks_center_as_used(self):
        directory, path = self.write_fem()
        try:
            result = analyze_fem(path)
        finally:
            directory.cleanup()
        self.assertEqual(result["unused_rbe2_ids"], [101, 104])
        self.assertEqual(result["rbe2_count"], 5)
        self.assertEqual(result["used_rbe2_count"], 3)

    def test_shell_reference_also_marks_center_as_used(self):
        text = FEM.replace("ENDDATA", "CQUAD4,400,1,20,21,22,11\nENDDATA")
        directory, path = self.write_fem(text)
        try:
            result = analyze_fem(path)
        finally:
            directory.cleanup()
        self.assertEqual(result["unused_rbe2_ids"], [104])

    def test_fixed_field_native_export_is_supported(self):
        text = "\n".join(
            [
                "BEGIN BULK",
                "{:<8}{:>8}{:>8}{:>8}{:>8}{:>8}".format("RBE2", 100, 10, 123456, 11, 12),
                "{:<8}{:>8}{:>8}{:>8}{:>8}{:>8}".format("RBE2", 101, 20, 123456, 21, 22),
                "{:<8}{:>8}{:>8}{:>8}{:>8}".format("CBAR", 200, 1, 10, 30),
                "ENDDATA",
            ]
        )
        directory, path = self.write_fem(text)
        try:
            result = analyze_fem(path)
        finally:
            directory.cleanup()
        self.assertEqual(result["unused_rbe2_ids"], [101])

    def test_cli_returns_unused_ids_in_result_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fem = root / "model.fem"
            fem.write_text(FEM, encoding="utf-8")
            request = root / "request.json"
            request.write_text(
                json.dumps({"module": "shell_washer_hole_rbe2", "run_id": "unused-test"}),
                encoding="utf-8",
            )
            output = root / "result.json"
            tcl_output = root / "result.tcl"
            code = main(
                [
                    "--request", str(request), "--mesh", str(fem),
                    "--output", str(output), "--tcl-output", str(tcl_output),
                    "--log", str(root / "operation.log"),
                ]
            )
            payload = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(payload["summary"]["unused_rbe2_ids"], [101, 104])


class TclUnusedRBE2PipelineContractTests(unittest.TestCase):
    def test_tcl_exports_full_model_and_does_not_open_a_selection_panel(self):
        module_root = TEST_DIR.parent
        source = (module_root.parent / "shell_washer_hole_rbe2.tcl").read_text(encoding="utf-8")
        start = source.index("proc ::RB2W::runFindUnusedRBE2FromSettings")
        end = source.index("\nproc ", start + 5)
        cleanup = source[start:end]
        self.assertIn("::RB2W::runPythonUnusedRBE2Analysis", cleanup)
        self.assertNotIn("selectedUnusedRBE2Scope", cleanup)
        self.assertNotIn("nativeMarkPanel", cleanup)

        exporter = (module_root / "tcl" / "exporter.tcl").read_text(encoding="utf-8")
        self.assertIn("proc ::RB2W::exportWholeModelFem", exporter)
        self.assertIn('*createmark elems 1 all', exporter)
        self.assertIn('*createmark nodes 1 all', exporter)
        self.assertIn("*feoutput_select", exporter)

        bridge = (module_root / "tcl" / "bridge.tcl").read_text(encoding="utf-8")
        self.assertIn("proc ::RB2W::runPythonUnusedRBE2Analysis", bridge)
        self.assertIn("unused_rbe2_detector.py", bridge)


if __name__ == "__main__":
    unittest.main()
