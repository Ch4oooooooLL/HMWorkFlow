from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class ComponentCreationPolicyTests(unittest.TestCase):
    def test_shared_component_creation_never_uses_browser_create_dialog(self):
        path = ROOT / "modules" / "workflow_common.tcl"
        text = path.read_text(encoding="utf-8")
        start = text.index("proc ::HWFlow::createComponent {")
        end = text.index("\nproc ::HWFlow::entityExistsByName", start)
        body = text[start:end]
        self.assertNotIn("createComponentThroughBrowser", body)
        self.assertNotIn("hmbr::createonly", body)
        self.assertIn("*createentity comps", body)
        self.assertIn("*collectorcreateonly components", body)

    def test_no_module_calls_browser_component_creation_directly(self):
        offenders = []
        for path in (ROOT / "modules").rglob("*.tcl"):
            if path.name == "workflow_common.tcl":
                continue
            if "createComponentThroughBrowser" in path.read_text(encoding="utf-8"):
                offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
