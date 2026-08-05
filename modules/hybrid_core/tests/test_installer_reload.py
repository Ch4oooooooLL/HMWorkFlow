import json
from pathlib import Path
import shutil
import tempfile
import tkinter
import unittest


ROOT = Path(__file__).resolve().parents[3]


class InstallerReloadTests(unittest.TestCase):
    def test_batch_worker_skips_interactive_shortcut_and_python_bootstrap(self):
        interpreter = tkinter.Tcl()
        interpreter.eval("set ::env(HMWORKFLOW_BATCH_WORKER) 1")
        bootstrap = (ROOT / "shortcut_bootstrap.tcl").as_posix()
        interpreter.eval(f"source {{{bootstrap}}}")
        self.assertEqual(interpreter.eval("namespace exists ::HWToolkit"), "0")
        self.assertEqual(interpreter.eval("namespace exists ::HybridCore"), "0")

    def test_startup_mode_writes_current_process_heartbeat(self):
        with tempfile.TemporaryDirectory() as directory:
            interpreter = tkinter.Tcl()
            interpreter.eval("namespace eval ::HWFlow {}")
            interpreter.eval("proc ::HWFlow::txt {zh en} { return $en }")
            interpreter.eval("namespace eval ::HWToolkit { variable MODULES {} }")
            interpreter.eval("set ::env(APPDATA) {{{}}}".format(Path(directory).as_posix()))
            interpreter.eval(
                "set ::env(LOCALAPPDATA) {{{}}}".format(Path(directory).as_posix())
            )
            manager = (ROOT / "modules/shortcut_manager.tcl").as_posix()
            interpreter.eval("source {{{}}}".format(manager))
            interpreter.call("::HWShortcut::initialize", "startup")
            heartbeat = Path(
                str(interpreter.call("::HWShortcut::getStartupHeartbeatFile"))
            )
            payload = json.loads(heartbeat.read_text(encoding="utf-8"))

            self.assertEqual(int(interpreter.eval("pid")), payload["hm_pid"])
            self.assertEqual("1.0", payload["schema_version"])
            self.assertEqual(
                str(ROOT.resolve()).replace("\\", "/"),
                payload["project_root"].replace("\\", "/"),
            )
            self.assertEqual(
                "verified",
                str(
                    interpreter.call(
                        "dict",
                        "get",
                        interpreter.call("::HWShortcut::getStartupHeartbeatInfo"),
                        "status",
                    )
                ),
            )

    def test_install_update_replaces_stale_hybrid_core_session(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "Moved HMWorkFlow"
            init_dir = project / "modules" / "hybrid_core" / "tcl"
            batch_dir = project / "modules" / "batch_mesher"
            init_dir.mkdir(parents=True)
            batch_dir.mkdir(parents=True)
            shutil.copy2(ROOT / "install_update.tcl", project / "install_update.tcl")
            (project / "VERSION").write_text("test-update\n", encoding="utf-8")
            (batch_dir / "background_worker.tcl").write_text(
                """
proc ::BatchMesherWorker::initializeBatchMeshProfile {release} {
    variable config
}
""".strip(),
                encoding="utf-8",
            )

            (project / "hw_toolkit_core.tcl").write_text(
                """
namespace eval ::HWToolkit {
    variable SCRIPT_DIR [file dirname [file normalize [info script]]]
}
proc ::HWToolkit::ensureCoreLoaded {} { return 1 }
proc ::HWToolkit::sourceModules {} {
    namespace eval ::BatchMesher {
        variable MODULE_DIR [file join $::HWToolkit::SCRIPT_DIR modules batch_mesher]
        variable VERSION 2.6
        variable WORKER_STARTUP_TIMEOUT_MS 120000
        variable generation current
    }
    proc ::BatchMesher::launchDetachedHmbatch {command workingDirectory args} {
        set HMWORKFLOW_BATCH_WORKER 1
        set launchDirectory $workingDirectory
    }
    proc ::BatchMesher::writeWorkerManagerFailure {args} {}
    proc ::BatchMesher::buildHmbatchCommand {args} {
        return {-nocommand -nouserprofiledialog}
    }
    proc ::BatchMesher::probeHmbatchExecutable {args} {}
    namespace eval ::HWShortcut {}
    proc ::HWShortcut::initialize {} {}
    proc ::HWShortcut::installAutoLoader {} {}
    proc ::HWShortcut::mainShortcutConfigured {} { return 1 }
    proc ::HWShortcut::showInitialSetup {} {}
    proc ::HWShortcut::nativeLibraryStatus {} { return test }
    return 1
}
proc ::HWToolkit::run {} { set ::toolkitRan 1 }
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
                "set ::env(LOCALAPPDATA) {{{}}}".format(Path(directory).as_posix())
            )
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
namespace eval ::BatchMesher {
    variable generation stale
    variable runtime
    array set runtime {running 0 background_active {} background_after {} background_merge_launcher_pid {} background_merge_pid {}}
}
proc ::BatchMesher::removedByUpdate {} { return stale }
"""
            )

            script = (project / "install_update.tcl").as_posix()
            interpreter.eval(f"source {{{script}}}")
            interpreter.eval("update idletasks")

            self.assertEqual(interpreter.eval("set ::oldWorkerStopped"), "1")
            self.assertEqual(interpreter.eval("set ::staleIdleFired"), "0")
            self.assertEqual(interpreter.eval("set ::HybridCore::generation"), "current")
            self.assertEqual(interpreter.eval("set ::BatchMesher::generation"), "current")
            self.assertEqual(
                interpreter.eval("llength [info commands ::BatchMesher::removedByUpdate]"),
                "0",
            )
            self.assertEqual(
                Path(interpreter.eval("set ::scheduledRoot")).resolve(),
                project.resolve(),
            )
            report = (
                Path(directory)
                / "HMWorkFlow"
                / "runtime"
                / "instances"
                / f"hm-{interpreter.eval('pid')}"
                / "install_update.log"
            )
            self.assertTrue(report.is_file())
            report_text = report.read_text(encoding="utf-8")
            self.assertIn("status=SUCCESS", report_text)
            self.assertIn("package_version=test-update", report_text)


if __name__ == "__main__":
    unittest.main()
