from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
HYBRID_CORE = ROOT / "modules" / "hybrid_core"


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


class HybridCoreTclPolicyTests(unittest.TestCase):
    def test_resolve_python_declares_root_dir(self):
        path = ROOT / "modules" / "hybrid_core" / "tcl" / "python_runtime.tcl"
        text = path.read_text(encoding="utf-8")
        start = text.index("proc ::HybridCore::resolvePython {} {")
        end = text.index("\nproc ::HybridCore::pythonVersion", start)
        body = text[start:end]
        self.assertIn("variable ROOT_DIR", body)
        self.assertIn("file join $ROOT_DIR runtime python windows-x64 python.exe", body)

    def test_incremental_import_has_conflict_verification_and_cleanup(self):
        source = (HYBRID_CORE / "tcl" / "incremental_import.tcl").read_text(encoding="utf-8")
        self.assertIn("proc ::HybridCore::importRigidDelta", source)
        self.assertIn("incremental IDs are already occupied", source)
        self.assertIn("verifyRigidManifest", source)
        self.assertIn("organizeRigidManifest", source)
        organize_body = source.split("proc ::HybridCore::organizeRigidManifest", 1)[1].split(
            "proc ::HybridCore::componentEntityCount", 1
        )[0]
        self.assertIn("moveIdsToComponent {elems elements}", organize_body)
        self.assertNotIn("moveIdsToComponent {nodes}", organize_body)
        self.assertNotIn("dict lappend byComponent", organize_body)
        self.assertIn("lappend elementIds [dict get $row element_id]", organize_body)
        self.assertIn("deleteEmptyNewComponents", source)
        delete_body = source.split("proc ::HybridCore::deleteEmptyNewComponents", 1)[1].split(
            "proc ::HybridCore::importRigidDelta", 1
        )[0]
        self.assertIn("componentEntityCount $componentId elems", delete_body)
        self.assertNotIn("componentEntityCount $componentId nodes", delete_body)
        self.assertIn("cleanupIncrementalEntities", source)


if __name__ == "__main__":
    unittest.main()
