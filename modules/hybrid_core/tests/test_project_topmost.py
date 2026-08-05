from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class ProjectTopmostTests(unittest.TestCase):
    def test_common_window_registry_applies_persistent_global_topmost(self):
        common = (ROOT / "modules" / "workflow_common.tcl").read_text(encoding="utf-8")
        self.assertIn("variable PROJECT_TOPMOST -1", common)
        self.assertIn("proc ::HWFlow::projectTopmostEnabled", common)
        self.assertIn("proc ::HWFlow::setProjectTopmost", common)
        self.assertIn("saveState project_ui", common)
        register = common[common.index("proc ::HWFlow::registerWindow"):]
        self.assertIn("::HWFlow::applyProjectTopmost $w", register.split("\n}", 1)[0])
        setter = common[common.index("proc ::HWFlow::setProjectTopmost"):]
        self.assertIn("foreach w [::HWFlow::managedWindows]", setter.split("\n}", 1)[0])

    def test_main_panel_exposes_one_project_wide_toggle(self):
        toolkit = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        self.assertIn("proc ::HWToolkit::toggleProjectTopmost", toolkit)
        self.assertIn("$w.foot.topmost", toolkit)
        self.assertIn("Always on Top: On", toolkit)
        self.assertIn("Always on Top: Off", toolkit)


if __name__ == "__main__":
    unittest.main()
