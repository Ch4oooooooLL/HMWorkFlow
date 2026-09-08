from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class FemAutoSeamModuleBoundaryTests(unittest.TestCase):
    def test_toolkit_registers_the_module_and_undo(self):
        toolkit = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        self.assertIn("fem_auto_seam {", toolkit)
        self.assertIn('proc     "::FemAutoSeam::runAction"', toolkit)
        self.assertIn('settings_proc "::FemAutoSeam::runSettings"', toolkit)
        self.assertIn('undo_proc "::FemAutoSeam::undoLast"', toolkit)
        self.assertIn("Python 识别 T 型与贴片焊缝", toolkit)

    def test_production_workflow_is_recognition_and_seed_execution_only(self):
        module = (ROOT / "modules" / "fem_auto_seam.tcl").read_text(encoding="utf-8")
        workflow = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "seed_workflow.tcl").read_text(encoding="utf-8")
        self.assertIn("seed_workflow.tcl", module)
        self.assertIn("exportFemBundle", workflow)
        self.assertIn("trusted_seeds", workflow)
        self.assertIn("potential_groups", workflow)
        self.assertIn("::MeshSeamWeld::executeSeedJobs", workflow)
        self.assertNotIn("executeAutoPlans", workflow)
        self.assertNotIn("backend_result.fem", workflow)
        self.assertNotIn("openAutoResultModel", workflow)

    def test_potential_groups_use_incremental_hmascii_component_sets(self):
        workflow = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "seed_workflow.tcl").read_text(encoding="utf-8")
        self.assertIn('\\"comps\\",0', workflow)
        self.assertIn("*setid($componentId)", workflow)
        self.assertIn('set reader "#hmascii\\\\hmascii"', workflow)
        self.assertIn("*feinputwithdata2", workflow)
        self.assertIn("potential_component_groups.hmascii", workflow)
        self.assertIn("HM2019 uses the four-field HMASCII set form", workflow)

    def test_mesh_seam_owns_patch_and_creation(self):
        loader = (ROOT / "modules" / "mesh_seam_weld.tcl").read_text(encoding="utf-8")
        adapter = (ROOT / "modules" / "mesh_seam_weld" / "tcl" / "seed_executor.tcl").read_text(encoding="utf-8")
        self.assertIn("seed_executor.tcl", loader)
        self.assertIn("prepareCurrentTargetPatch", adapter)
        self.assertIn("processWeldPathIsolated", adapter)
        self.assertIn("assignCreatedSeamComponentProperties", adapter)
        self.assertNotIn("FemAutoSeam", adapter)

    def test_detection_settings_expose_trusted_and_potential_tolerances(self):
        module = (ROOT / "modules" / "fem_auto_seam.tcl").read_text(encoding="utf-8")
        workflow = (ROOT / "modules" / "fem_auto_seam" / "tcl" / "workflow.tcl").read_text(encoding="utf-8")
        for token in (
            "search_distance", "min_seam_length", "parallel_angle_max",
            "perpendicular_angle_min", "potential_search_multiplier",
            "potential_angle_margin", "potential_length_ratio",
        ):
            self.assertIn(token, module)
            self.assertIn(token, workflow)


if __name__ == "__main__":
    unittest.main()
