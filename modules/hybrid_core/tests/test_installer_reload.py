from pathlib import Path
import shutil
import tempfile
import tkinter
import unittest


ROOT = Path(__file__).resolve().parents[3]


class InstallerReloadTests(unittest.TestCase):
    def test_install_update_replaces_stale_hybrid_core_session(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "Moved HMWorkFlow"
            init_dir = project / "modules" / "hybrid_core" / "tcl"
            init_dir.mkdir(parents=True)
            shutil.copy2(ROOT / "install_update.tcl", project / "install_update.tcl")

            (project / "hw_toolkit_core.tcl").write_text(
                """
namespace eval ::HWToolkit {}
proc ::HWToolkit::ensureCoreLoaded {} { return 1 }
proc ::HWToolkit::run {} { set ::toolkitRan 1 }
namespace eval ::HWShortcut {}
proc ::HWShortcut::initialize {} {}
proc ::HWShortcut::installAutoLoader {} {}
proc ::HWShortcut::mainShortcutConfigured {} { return 1 }
proc ::HWShortcut::showInitialSetup {} {}
proc ::HWShortcut::nativeLibraryStatus {} { return test }
""".strip(),
                encoding="utf-8",
            )
            (init_dir / "init.tcl").write_text(
                """
namespace eval ::HybridCore {
    variable ROOT_DIR [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
    variable generation current
}
proc ::HybridCore::scheduleInstanceWorker {} {
    set ::scheduledRoot $::HybridCore::ROOT_DIR
}
""".strip(),
                encoding="utf-8",
            )

            interpreter = tkinter.Tcl()
            interpreter.eval(
                """
namespace eval ::HybridCore {
    variable ROOT_DIR {D:/old/HMWorkFlow}
    variable generation stale
}
proc ::HybridCore::stopPersistentWorker {} { set ::oldWorkerStopped 1 }
proc ::HybridCore::scheduleInstanceWorker {} { set ::oldWorkerScheduled 1 }
proc ::HybridCore::initializeInstanceWorkerSafely {} { set ::staleIdleFired 1 }
set ::oldWorkerStopped 0
set ::staleIdleFired 0
after idle ::HybridCore::initializeInstanceWorkerSafely
"""
            )

            script = (project / "install_update.tcl").as_posix()
            interpreter.eval(f"source {{{script}}}")
            interpreter.eval("update idletasks")

            self.assertEqual(interpreter.eval("set ::oldWorkerStopped"), "1")
            self.assertEqual(interpreter.eval("set ::staleIdleFired"), "0")
            self.assertEqual(interpreter.eval("set ::HybridCore::generation"), "current")
            self.assertEqual(
                Path(interpreter.eval("set ::scheduledRoot")).resolve(),
                project.resolve(),
            )


if __name__ == "__main__":
    unittest.main()
