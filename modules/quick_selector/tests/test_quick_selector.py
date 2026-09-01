from __future__ import annotations

import tempfile
import tkinter as tk
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
QUICK_SELECTOR = ROOT / "modules" / "quick_selector.tcl"
SHORTCUT_MANAGER = ROOT / "modules" / "shortcut_manager.tcl"
TOOLKIT_CORE = ROOT / "hw_toolkit_core.tcl"


class TclHarness:
    def __init__(self) -> None:
        self.tcl = tk.Tcl()
        self.tcl.eval(f"source -encoding utf-8 {{{QUICK_SELECTOR.as_posix()}}}")
        self.tcl.eval(
            """
            set ::Toolbox::QuickSelector::SETTINGS(enabled) 1
            set ::Toolbox::QuickSelector::SETTINGS(debug) 0
            namespace eval ::hmtk::HMEntitySelectorMgr {
                variable _prevActiveSelectors {::mockSelector}
            }
            namespace eval ::hm::context {}
            proc ::hm::context::GetSelectionTool {} { return ::mockSelectionTool }
            proc ::mockSelector {method args} {
                switch -- $method {
                    IsSelectorActive { return 1 }
                    GetCurrentEntityType { return Elements }
                    GetSelectionName { return panel_selector_2 }
                    ExecSelectionCommand { return 1 }
                }
                error "unexpected selector method: $method"
            }
            set ::mockSelectedCount 1
            set ::mockNativeCalls {}
            proc ::mockSelectionTool {method args} {
                switch -- $method {
                    GetNumSelected { return $::mockSelectedCount }
                    GetEntityType { return Elements }
                    SelectByFace - ByAttached - EnterAdvancedSelectionMode {
                        lappend ::mockNativeCalls [list $method {*}$args]
                        return 1
                    }
                }
                error "unexpected selection method: $method"
            }
            proc hm_entitycanselectby {method entity} { return 1 }
            proc hm_usermessage {message} { set ::lastMessage $message }
            """
        )


class QuickSelectorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.h = TclHarness()

    def test_by_face_uses_active_native_selector(self) -> None:
        self.assertEqual(self.h.tcl.eval("::Toolbox::QuickSelector::ByFace"), "1")
        self.assertEqual(self.h.tcl.eval("set ::mockNativeCalls"), "SelectByFace")
        self.assertEqual(
            self.h.tcl.eval("dict get $::Toolbox::QuickSelector::LAST_RESULT entity"),
            "elems",
        )

    def test_by_attached_calls_native_selection_tool(self) -> None:
        self.assertEqual(self.h.tcl.eval("::Toolbox::QuickSelector::ByAttached"), "1")
        self.assertEqual(self.h.tcl.eval("set ::mockNativeCalls"), "ByAttached")

    def test_path_enters_native_advanced_mode_in_place(self) -> None:
        self.assertEqual(
            self.h.tcl.eval("::Toolbox::QuickSelector::EnableByPathMode"), "1"
        )
        self.assertEqual(
            self.h.tcl.eval("set ::mockNativeCalls"),
            "{EnterAdvancedSelectionMode {by path}}",
        )

    def test_action_is_safe_noop_without_seed(self) -> None:
        self.h.tcl.eval("set ::mockSelectedCount 0")
        self.assertEqual(self.h.tcl.eval("::Toolbox::QuickSelector::ByFace"), "0")
        self.assertEqual(self.h.tcl.eval("set ::mockNativeCalls"), "")
        self.assertEqual(
            self.h.tcl.eval("dict get $::Toolbox::QuickSelector::LAST_RESULT reason"),
            "no_seed",
        )

    def test_missing_active_selector_is_safe_noop(self) -> None:
        self.h.tcl.eval("set ::hmtk::HMEntitySelectorMgr::_prevActiveSelectors {}")
        self.assertEqual(self.h.tcl.eval("::Toolbox::QuickSelector::ByAttached"), "0")
        self.assertEqual(
            self.h.tcl.eval("dict get $::Toolbox::QuickSelector::LAST_RESULT reason"),
            "no_active_selector",
        )


class ShortcutActionRegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.tcl = tk.Tcl()
        self.tcl.setvar("env(APPDATA)", self.temp_dir.name)
        self.tcl.eval(
            """
            namespace eval ::HWToolkit {
                variable MODULES {demo {group Mesh label_zh Demo label_en Demo}}
            }
            proc ::HWToolkit::moduleText {info field} { return Demo }
            proc ::HWToolkit::groupText {group} { return $group }
            proc ::HWToolkit::allModuleKeys {} { return demo }
            proc ::HWToolkit::refreshShortcutDisplays {} {}
            proc ::HWToolkit::requestShortcutModule {target} { set ::dispatchedModule $target }
            proc hm_registerkeyproc {key file command} { set ::nativeBinding($key) $command }
            """
        )
        self.tcl.eval(f"source -encoding utf-8 {{{SHORTCUT_MANAGER.as_posix()}}}")
        self.tcl.eval("::HWShortcut::ensureActionProviders")
        self.tcl.eval("proc ::HWShortcut::getAutoLoaderStatusValue {} { return enabled }")
        self.tcl.eval("proc ::HWShortcut::refreshManager {} {}")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_quick_selector_actions_are_features_not_modules(self) -> None:
        self.assertEqual(
            self.tcl.eval("::HWShortcut::targetKind hm.selection.by_face"), "action"
        )
        self.assertNotIn(
            "hm.selection.by_face", self.tcl.eval("::HWShortcut::managerModuleKeys").split()
        )
        self.assertIn(
            "hm.selection.by_face", self.tcl.eval("::HWShortcut::managerActionKeys").split()
        )

    def test_module_and_feature_shortcuts_share_conflict_detection(self) -> None:
        self.tcl.eval("::HWShortcut::applyBinding demo Control-Shift-F")
        with self.assertRaises(tk.TclError):
            self.tcl.eval(
                "::HWShortcut::applyBinding hm.selection.by_face Control-Shift-F"
            )

    def test_action_binding_persists_with_stable_action_id(self) -> None:
        self.tcl.eval(
            "::HWShortcut::applyBinding hm.selection.by_face Control-Shift-A"
        )
        config = Path(self.temp_dir.name) / "HMWorkFlow" / "shortcuts.cfg"
        self.assertIn("hm.selection.by_face", config.read_text(encoding="utf-8"))
        self.tcl.eval("::HWShortcut::loadConfig")
        self.assertEqual(
            self.tcl.eval("::HWShortcut::targetShortcut hm.selection.by_face"),
            "Control-Shift-A",
        )

    def test_settings_ui_keeps_module_and_feature_sections_separate(self) -> None:
        manager_source = SHORTCUT_MANAGER.read_text(encoding="utf-8")
        core_source = TOOLKIT_CORE.read_text(encoding="utf-8")
        self.assertIn("labelframe $w.modules", manager_source)
        self.assertIn("labelframe $w.features", manager_source)
        self.assertIn("功能快捷键（与模块快捷键独立）", manager_source)
        self.assertIn("快速选择功能设置", manager_source)
        self.assertIn("工具箱设置", core_source)


if __name__ == "__main__":
    unittest.main()
