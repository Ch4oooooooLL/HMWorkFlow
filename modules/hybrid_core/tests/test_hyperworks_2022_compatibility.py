from __future__ import annotations

import re
import tempfile
import tkinter
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class HyperWorks2022CompatibilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.common_path = ROOT / "modules/workflow_common.tcl"

    def test_utf8_is_explicit_across_the_startup_chain(self) -> None:
        expectations = {
            "hw_toolkit.tcl": r"source\s+-encoding\s+utf-8\s+\$installerFile",
            "install_update.tcl": r"source\s+-encoding\s+utf-8\s+\$coreFile",
            "shortcut_bootstrap.tcl": r"source\s+-encoding\s+utf-8\s+\$hmworkflowCore",
        }
        for relative_path, pattern in expectations.items():
            with self.subTest(path=relative_path):
                source = (ROOT / relative_path).read_text(encoding="utf-8")
                self.assertRegex(source, pattern)

        core = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        self.assertIn("[list source -encoding utf-8 $f]", core)

    def test_shared_loader_reads_nested_toolkit_scripts_as_utf8(self) -> None:
        common = (ROOT / "modules/workflow_common.tcl").read_text(encoding="utf-8")
        self.assertIn("proc ::HWFlow::sourceUtf8", common)
        self.assertIn("source -encoding utf-8", common)

        loaders = {
            "modules/auto_hole_rbe2.tcl": 4,
            "modules/shell_washer_hole_rbe2.tcl": 1,
            "modules/rbe2_bolt_connector.tcl": 1,
            "modules/mesh_seam_weld.tcl": 1,
            "modules/seam_surface.tcl": 1,
            "modules/weld_integrity_check.tcl": 1,
        }
        for relative_path, minimum_calls in loaders.items():
            with self.subTest(path=relative_path):
                source = (ROOT / relative_path).read_text(encoding="utf-8")
                calls = len(re.findall(r"::HWFlow::sourceUtf8\b", source))
                self.assertGreaterEqual(calls, minimum_calls)

        for relative_path in (
            "modules/solid_seam_connector.tcl",
            "modules/hybrid_core/tcl/init.tcl",
        ):
            with self.subTest(path=relative_path):
                source = (ROOT / relative_path).read_text(encoding="utf-8")
                self.assertIn("source -encoding utf-8", source)

    def test_2019_and_2022_are_declared_supported_hyperworks_generations(self) -> None:
        common = (ROOT / "modules/workflow_common.tcl").read_text(encoding="utf-8")
        self.assertIn("variable SUPPORTED_HYPERWORKS_YEARS {2019 2022}", common)
        self.assertIn("proc ::HWFlow::hyperWorksYear", common)
        self.assertIn("proc ::HWFlow::hyperWorksCompatibility", common)
        self.assertRegex(common, r"2022\s+\{\s*return\s+new")
        preflight = common[
            common.index("proc ::HWFlow::engineeringPreflight") :
            common.index("proc ::HWFlow::formatEngineeringPreflight")
        ]
        self.assertNotIn("hyperWorksCompatibility", preflight)
        self.assertIn("informational only", preflight)

    def test_main_panel_shortcut_uses_a_reentrant_2022_window_lifecycle(self) -> None:
        core = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        panel = core[
            core.index("proc ::HWToolkit::showPanel") :
            core.index("proc ::HWToolkit::shortcutText")
        ]
        drain = core[
            core.index("proc ::HWToolkit::drainShortcutLaunch") :
            core.index("proc ::HWToolkit::openGuide")
        ]

        self.assertNotRegex(panel, r"(?m)^\s*tkwait\s+window\b")
        self.assertIn(
            "wm protocol $w WM_DELETE_WINDOW ::HWToolkit::closePanel", panel
        )
        self.assertIn("::HWToolkit::run 0", drain)

        tcl = tkinter.Tcl()
        tcl.eval(f"source -encoding utf-8 {{{(ROOT / 'hw_toolkit_core.tcl').as_posix()}}}")
        tcl.eval(
            r'''
            namespace eval ::HWShortcut {}
            set ::shortcut_refreshes 0
            set ::panel_opens 0
            proc ::HWShortcut::initialize {} { incr ::shortcut_refreshes }
            proc ::HWToolkit::sourceModules {} { return 1 }
            proc ::HWToolkit::clearExistingWindows {} { return }
            proc ::HWToolkit::showPanel {} { incr ::panel_opens }
            '''
        )

        tcl.eval("::HWToolkit::run 0")
        self.assertEqual(tcl.eval("set ::shortcut_refreshes"), "0")
        self.assertEqual(tcl.eval("set ::panel_opens"), "1")
        tcl.eval("::HWToolkit::run")
        self.assertEqual(tcl.eval("set ::shortcut_refreshes"), "1")
        self.assertEqual(tcl.eval("set ::panel_opens"), "2")

    def test_2022_startup_waits_for_native_shortcut_api_and_tracks_context(self) -> None:
        manager_path = ROOT / "modules" / "shortcut_manager.tcl"
        source = manager_path.read_text(encoding="utf-8")
        bootstrap = (ROOT / "shortcut_bootstrap.tcl").read_text(encoding="utf-8")

        self.assertIn("::HWShortcut::startStartupInitialization", bootstrap)
        self.assertIn("after $STARTUP_RETRY_MS", source)
        self.assertIn("::HM_Framework::p_RegisterKeys", source)
        self.assertIn("::hm::context::ContextBase::setkeys", source)

        tcl = tkinter.Tcl()
        tcl.eval(f"source -encoding utf-8 {{{manager_path.as_posix()}}}")
        tcl.eval(
            r'''
            rename ::HWShortcut::initialize ::HWShortcut::initialize_real
            set ::startup_modes {}
            proc ::HWShortcut::initialize {{mode manual}} {
                lappend ::startup_modes $mode
                return 1
            }
            set ::HWShortcut::STARTUP_RETRY_MS 100000
            set ::HWShortcut::STARTUP_MAX_ATTEMPTS 2
            '''
        )

        self.assertEqual(tcl.eval("::HWShortcut::startStartupInitialization"), "0")
        self.assertEqual(tcl.eval("llength $::startup_modes"), "0")
        tcl.eval("proc hm_registerkeyproc {key file command} { return }")
        self.assertEqual(tcl.eval("::HWShortcut::attemptStartupInitialization"), "1")
        self.assertEqual(tcl.splitlist(tcl.eval("set ::startup_modes")), ("startup",))
        tcl.eval(
            r'''
            namespace eval ::HM_Framework {}
            proc ::HM_Framework::p_RegisterKeys {} { return }
            rename ::HWFlow::hyperWorksYear ::HWFlow::hyperWorksYear_real
            proc ::HWFlow::hyperWorksYear {{version ""}} { return 2022 }
            rename ::HWShortcut::loadConfig ::HWShortcut::loadConfig_real
            proc ::HWShortcut::loadConfig {} { return }
            rename ::HWShortcut::registerAll ::HWShortcut::registerAll_real
            set ::context_refreshes 0
            proc ::HWShortcut::registerAll {} {
                incr ::context_refreshes
                return [dict create registered 1 errors {}]
            }
            ::HWShortcut::installContextKeyHooks
            ::HM_Framework::p_RegisterKeys
            '''
        )
        self.assertEqual(tcl.eval("set ::context_refreshes"), "1")

    def test_short_hmbatch_release_values_are_normalized_to_years(self) -> None:
        tcl = tkinter.Tcl()
        tcl.eval(f"source -encoding utf-8 {{{self.common_path.as_posix()}}}")
        cases = {
            "19": "2019",
            "HyperMesh 19.0": "2019",
            "22.1": "2022",
            "HyperWorks 2022.3": "2022",
        }
        for raw_version, expected_year in cases.items():
            with self.subTest(raw_version=raw_version):
                self.assertEqual(
                    tcl.eval(f"::HWFlow::hyperWorksYear {{{raw_version}}}"),
                    expected_year,
                )

    def test_2022_mark_panel_falls_back_to_edit_widget_and_clears_busy_state(self) -> None:
        tcl = tkinter.Tcl()
        tcl.eval(f"source -encoding utf-8 {{{self.common_path.as_posix()}}}")
        tcl.eval(
            r'''
            set ::panel_calls {}
            proc hm_info {args} { return "HyperWorks 2022.3" }
            proc *clearmark {entity mark} { return }
            proc *createmarkpanel {entity mark prompt args} {
                lappend ::panel_calls create
                error "unable to create panel mark"
            }
            proc *editmarkpanel {entity mark prompt args} {
                lappend ::panel_calls edit
                return
            }
            proc hm_getmark {entity mark} { return {41 42} }
            '''
        )

        selected = tcl.splitlist(
            tcl.eval("::HWFlow::nativeMarkPanel elems 1 {Select elements}")
        )

        self.assertEqual(selected, ("41", "42"))
        self.assertEqual(tcl.splitlist(tcl.eval("set ::panel_calls")), ("create", "edit"))
        self.assertEqual(tcl.eval("set ::HWFlow::NATIVE_PANEL_ACTIVE"), "0")

    def test_2019_mark_panel_keeps_the_legacy_selector_without_fallback(self) -> None:
        tcl = tkinter.Tcl()
        tcl.eval(f"source -encoding utf-8 {{{self.common_path.as_posix()}}}")
        tcl.eval(
            r'''
            set ::panel_calls {}
            proc hm_info {args} { return "HyperMesh 2019.0" }
            proc *clearmark {entity mark} { return }
            proc *createmarkpanel {entity mark prompt args} {
                lappend ::panel_calls create
                return
            }
            proc *editmarkpanel {entity mark prompt args} {
                lappend ::panel_calls edit
                return
            }
            proc hm_getmark {entity mark} { return {7} }
            '''
        )

        self.assertEqual(
            tcl.eval("::HWFlow::nativeMarkPanel elems 1 {Select elements}"), "7"
        )
        self.assertEqual(tcl.splitlist(tcl.eval("set ::panel_calls")), ("create",))

    def test_model_io_guard_removes_stale_output_answers_prompts_and_recovers(self) -> None:
        tcl = tkinter.Tcl()
        tcl.eval(f"source -encoding utf-8 {{{self.common_path.as_posix()}}}")
        tcl.eval(
            r'''
            set ::answers {}
            set ::import_error_modes {}
            proc hm_answernext {answer} { lappend ::answers $answer }
            proc hm_info {key} {
                if {$key eq "displayimporterrors"} { return 1 }
                return ""
            }
            proc *displayimporterrors {mode} { lappend ::import_error_modes $mode }
            proc successful_io {} { return done }
            proc failing_io {} { error boom }
            '''
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "stale.fem"
            output.write_text("stale", encoding="utf-8")
            result = tcl.eval(
                f"::HWFlow::runHyperMeshIo export successful_io {{{output.as_posix()}}}"
            )

        self.assertEqual(result, "done")
        self.assertFalse(output.exists())
        self.assertEqual(tcl.splitlist(tcl.eval("set ::answers")), ("yes",))
        with self.assertRaises(tkinter.TclError):
            tcl.eval("::HWFlow::runHyperMeshIo import failing_io")
        self.assertEqual(tcl.splitlist(tcl.eval("set ::answers")), ("yes", "all"))
        self.assertEqual(tcl.splitlist(tcl.eval("set ::import_error_modes")), ("0", "1"))
        self.assertEqual(tcl.eval("set ::HWFlow::MODEL_IO_ACTIVE"), "0")

    def test_all_native_fem_import_export_calls_use_the_guard(self) -> None:
        paths = (
            "modules/auto_hole_rbe2/tcl/exporter.tcl",
            "modules/mesh_seam_weld/tcl/exporter.tcl",
            "modules/shell_washer_hole_rbe2/tcl/exporter.tcl",
            "modules/solid_seam/tcl/mesh_exporter.tcl",
            "modules/hybrid_core/tcl/incremental_import.tcl",
            "modules/rbe2_bolt_connector/tcl/executor.tcl",
        )
        for relative_path in paths:
            with self.subTest(path=relative_path):
                source = (ROOT / relative_path).read_text(encoding="utf-8")
                native_calls = len(
                    re.findall(r"\[list\s+\*fe(?:output_select|inputwithdata2)\b", source)
                )
                self.assertGreater(native_calls, 0)
                self.assertGreaterEqual(
                    source.count("::HWFlow::runHyperMeshIo"), native_calls
                )
                self.assertNotRegex(
                    source,
                    r"(?m)^\s*\*fe(?:output_select|inputwithdata2)\s",
                )


if __name__ == "__main__":
    unittest.main()
