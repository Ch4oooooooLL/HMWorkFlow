from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class FemAutoSeamModuleBoundaryTests(unittest.TestCase):
    def test_toolkit_registers_a_separate_module(self):
        toolkit = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        self.assertIn("fem_auto_seam {", toolkit)
        self.assertIn('proc     "::FemAutoSeam::runAction"', toolkit)
        self.assertIn('settings_proc "::FemAutoSeam::runSettings"', toolkit)
        self.assertIn('undo_proc "::FemAutoSeam::undoLast"', toolkit)

    def test_configuration_and_task_workspace_are_independent(self):
        module = (ROOT / "modules" / "fem_auto_seam.tcl").read_text(encoding="utf-8")
        workflow = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "workflow.tcl").read_text(encoding="utf-8")
        self.assertIn("saveArrayState fem_auto_seam", module)
        self.assertIn("applyStateToArray fem_auto_seam", module)
        self.assertIn("createTaskWorkspace fem_auto_seam", workflow)
        self.assertIn('"module": "fem_auto_seam"', workflow.replace('\\"', '"'))
        self.assertIn("createOriginalModelBackup", workflow)
        self.assertIn("validateBackendTransfer", workflow)
        self.assertIn("before.hm", workflow)
        self.assertIn("result.fem", workflow)
        self.assertIn("cleanupTaskWorkspace", workflow)
        self.assertIn("::HybridCore::closeLog", workflow)
        self.assertIn("Cleanup cannot invalidate", workflow)
        self.assertIn("effectiveSpecificationPath", module)
        self.assertTrue((ROOT / "modules" / "fem_auto_seam" / "defaults" / "fem_auto_seam_default.criteria").is_file())
        self.assertTrue((ROOT / "modules" / "fem_auto_seam" / "defaults" / "fem_auto_seam_default.param").is_file())

    def test_mesh_seam_weld_has_no_fem_auto_seam_configuration(self):
        original = (ROOT / "modules" / "mesh_seam_weld.tcl").read_text(encoding="utf-8")
        self.assertNotIn("fem_auto_seam", original)
        self.assertNotIn("optimize_neighborhood", original)
        self.assertNotIn("criteria_path", original)

    def test_review_ui_is_owned_by_the_new_namespace(self):
        ui = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "auto_ui.tcl").read_text(encoding="utf-8")
        self.assertIn("::FemAutoSeam::showPendingReview", ui)
        self.assertIn(".fem_auto_seam_review", ui)
        self.assertIn("::MeshSeamWeld::runAction", ui)
        self.assertIn("pendingReviewOpenMeshSeamWeld", ui)
        self.assertIn("autoReviewFitIsolated", ui)
        self.assertIn("after idle", ui)
        self.assertIn("*viewfit", ui)

    def test_workflow_reports_background_and_per_candidate_progress(self):
        workflow = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "workflow.tcl").read_text(encoding="utf-8")
        executor = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "fast_executor.tcl").read_text(encoding="utf-8")
        for token in ("progressOpen", "progressUpdate", "progressClose", "Python 正在后台检测焊缝"):
            self.assertIn(token, workflow)
        self.assertIn("Applying candidate $index/$readyTotal", executor)
        self.assertIn("ROLLED_BACK", executor)

    def test_optimization_is_mandatory_and_python_owned(self):
        module = (ROOT / "modules" / "fem_auto_seam.tcl").read_text(encoding="utf-8")
        workflow = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "workflow.tcl").read_text(encoding="utf-8")
        schema = (ROOT / "modules" / "fem_auto_seam" / "python" / "schema.py").read_text(encoding="utf-8")
        self.assertIn("optimize_neighborhood 1", module)
        self.assertIn('"optimize_neighborhood": true', workflow.replace('\\"', '"'))
        self.assertIn('settings["optimize_neighborhood"] = True', schema)
        self.assertNotIn("$w.main.optimize", module)


if __name__ == "__main__":
    unittest.main()
