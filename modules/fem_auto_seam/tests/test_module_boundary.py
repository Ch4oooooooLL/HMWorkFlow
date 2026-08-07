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
        self.assertIn("Full diagnostic task retained", workflow)
        self.assertIn("before.hm", workflow)
        self.assertIn("result.fem", workflow)
        self.assertIn("cleanupTaskWorkspace", workflow)
        self.assertIn("::HybridCore::closeLog", workflow)
        self.assertIn("Cleanup cannot invalidate", workflow)
        self.assertIn("effectiveSpecificationPath", module)
        self.assertTrue((ROOT / "modules" / "fem_auto_seam" / "defaults" / "fem_auto_seam_default.criteria").is_file())

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

    def test_workflow_reports_background_and_batch_remesh_progress(self):
        workflow = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "workflow.tcl").read_text(encoding="utf-8")
        executor = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "fast_executor.tcl").read_text(encoding="utf-8")
        for token in ("progressOpen", "progressUpdate", "progressClose", "Python 正在后台检测焊缝"):
            self.assertIn(token, workflow)
        self.assertIn("Opening the modified FEM as the new model", executor)
        self.assertIn("bounded chunks", executor)
        self.assertIn("autoRemeshChunks", executor)
        self.assertIn("progressPumpEvents", executor)
        self.assertIn("*interactiveremeshelems", executor)
        self.assertIn("*elementsaddnodesfixed", executor)
        self.assertIn("*storemeshtodatabase 1", executor)
        self.assertNotIn("checkpoints", executor)
        self.assertEqual(1, executor.count("*interactiveremeshelems"))

    def test_long_python_and_native_stages_remain_cancelable_without_double_restore(self):
        workflow = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "workflow.tcl").read_text(encoding="utf-8")
        runner = (ROOT / "modules" / "hybrid_core" / "tcl" / "process_runner.tcl").read_text(encoding="utf-8")
        backend = (ROOT / "modules" / "fem_auto_seam" / "python" / "backend.py").read_text(encoding="utf-8")
        self.assertIn('"FEM Automatic Seam"] $message 1', workflow)
        self.assertIn("executeAutoPlans owns the task transaction", workflow)
        self.assertIn("progressCancelled", runner)
        self.assertIn("stopPersistentWorker 1", runner)
        self.assertIn("python_stage.json", runner)
        self.assertIn("Python background detection processes", runner)
        self.assertIn('with_name("pythonw.exe")', backend)
        self.assertIn("multiprocessing.set_executable", backend)

    def test_model_is_replaced_from_the_edited_fem_without_import_merge(self):
        importer = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "delta_import.tcl").read_text(encoding="utf-8")
        executor = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "fast_executor.tcl").read_text(encoding="utf-8")
        workflow = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "workflow.tcl").read_text(encoding="utf-8")
        backend = (ROOT / "modules" / "fem_auto_seam" / "python" / "backend.py").read_text(encoding="utf-8")
        self.assertIn("openAutoResultModel", importer)
        self.assertIn("*readfile [file nativename $resultFem] 0", importer)
        self.assertIn("validateAutoModelContents", importer)
        self.assertIn("still contains replaced mother shells", importer)
        self.assertNotIn("feinputwithdata2", importer)
        self.assertNotIn("writeAutoPlanRepairDelta", importer)
        self.assertNotIn("HMWF_AUTO_SHELL_SEAM_REPAIR_V1", importer)
        self.assertIn("executeAutoPlans owns the task transaction", workflow)
        self.assertIn("selected_component_ids", backend)
        self.assertIn("other_card_lines", backend)

    def test_python_only_plans_topology_and_hypermesh_owns_remesh(self):
        module = (ROOT / "modules" / "fem_auto_seam.tcl").read_text(encoding="utf-8")
        workflow = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "workflow.tcl").read_text(encoding="utf-8")
        backend = (ROOT / "modules" / "fem_auto_seam" / "python" / "backend.py").read_text(encoding="utf-8")
        self.assertIn("remesh_element_size 8.0", module)
        self.assertIn("remesh_element_size remesh_expand_layers remesh_feature_angle", workflow)
        self.assertNotIn("optimize_seam_neighborhood", backend)
        self.assertIn('"execution_mode": "HYPERMESH_BATCH_AUTOMESH"', backend)


if __name__ == "__main__":
    unittest.main()
