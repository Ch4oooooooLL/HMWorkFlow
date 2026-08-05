import json
import tempfile
import tkinter
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "batch_mesher"


class TclHarness:
    def __init__(self):
        self.tcl = tkinter.Tcl()
        self.tcl.eval("namespace eval ::HWFlow {}")
        self.tcl.eval("proc ::HWFlow::txt {zh en} {return $en}")
        self.tcl.eval("proc ::HWFlow::loadState {key} {return {}}")
        self.tcl.eval("proc ::HWFlow::saveState {key state} {return}")
        self.tcl.eval("proc ::HWFlow::writeTextFile {path data} {set ch [open $path w]; puts -nonewline $ch $data; close $ch}")
        self.tcl.eval("proc ::HWFlow::readTextFile {path} {set ch [open $path r]; set data [read $ch]; close $ch; return $data}")
        self.tcl.eval(
            "proc ::HWFlow::hyperWorksYear {version} {"
            "if {[regexp {(20[0-9][0-9])} $version -> year]} {return $year}; "
            "if {[regexp {(^|[^0-9])(19|22)([.][0-9]+)*([^0-9]|$)} $version -> x release y z]} {"
            "if {$release eq {19}} {return 2019}; if {$release eq {22}} {return 2022}}; return {}}"
        )
        self.tcl.eval("namespace eval ::HybridCore {}")
        self.tcl.eval("proc ::HybridCore::log {level message} {return \"$level $message\"}")
        for name in ("config.tcl", "selection.tcl", "connectivity.tcl", "logging.tcl", "executor.tcl", "background.tcl"):
            self.tcl.eval(f"source -encoding utf-8 {{{(MODULE / name).as_posix()}}}")
        self.tcl.eval("set ::BatchMesherWorkerNoAutoRun 1")
        self.tcl.eval(f"source -encoding utf-8 {{{(MODULE / 'background_worker.tcl').as_posix()}}}")
        self.tcl.eval("set ::BatchMesherMergeWorkerNoAutoRun 1")
        self.tcl.eval(f"source -encoding utf-8 {{{(MODULE / 'background_merge_worker.tcl').as_posix()}}}")
        self.tcl.eval("proc ::BatchMesher::refreshUi {} {return}")
        self.tcl.eval("::BatchMesher::setDefaults")

    def eval(self, script):
        return self.tcl.eval(script)


class BatchMesherTests(unittest.TestCase):
    def setUp(self):
        self.h = TclHarness()

    def install_model_mock(self):
        self.h.eval(
            r"""
            set ::allSurfaces {1 2 3 4 5 6 7}
            set ::graph [dict create 1 {2} 2 {1 3} 3 {2 7} 4 {5} 5 {4} 6 {7} 7 {3 6}]
            set ::surfaceComp [dict create 1 10 2 10 3 20 4 30 5 30 6 40 7 20]
            set ::compName [dict create 10 FRAME_A 20 WELD_SURF 30 FRAME_B 40 FRAME_C]
            array set ::marks {}
            proc *clearmark {etype markId} { set ::marks($markId) {}; return }
            proc *createmark {etype markId args} {
                if {[llength $args] == 1 && [lindex $args 0] eq "all"} {set ::marks($markId) $::allSurfaces
                } elseif {[llength $args] == 1 && [lindex $args 0] eq "displayed"} {set ::marks($markId) $::allSurfaces
                } else {set ::marks($markId) $args}
            }
            proc *appendmark {etype markId mode} {
                if {$mode ne "by attached"} {error "unsupported mode"}
                set expanded $::marks($markId)
                foreach id $::marks($markId) {
                    if {[dict exists $::graph $id]} {set expanded [concat $expanded [dict get $::graph $id]]}
                }
                set ::marks($markId) [lsort -integer -unique $expanded]
            }
            proc hm_getmark {etype markId} { return $::marks($markId) }
            proc hm_getvalue {etype args} {
                regexp {id=([0-9]+)} $args -> id
                regexp {dataname=(.+)$} $args -> dataname
                if {$etype eq "surfs"} {return [dict get $::surfaceComp $id]}
                return [dict get $::compName $id]
            }
            """
        )

    def test_connectivity_uses_surface_topology_across_components(self):
        self.install_model_mock()
        self.h.eval("set ::BatchMesher::runtime(selected_surfaces) {1 2 3 4 5 6}")
        self.h.eval("::BatchMesher::analyzeConnectivity")
        self.assertEqual(self.h.eval("llength $::BatchMesher::runtime(groups)"), "2")
        first = self.h.eval("dict get [lindex $::BatchMesher::runtime(groups) 0] surface_ids")
        self.assertEqual(set(first.split()), {"1", "2", "3", "6"})
        self.assertEqual(
            self.h.eval("dict get [lindex $::BatchMesher::runtime(groups) 0] component_names"),
            "FRAME_A WELD_SURF FRAME_C",
        )

    def test_model_change_invalidates_analysis(self):
        self.install_model_mock()
        self.h.eval("set ::BatchMesher::runtime(selected_surfaces) {1 2 3}")
        self.h.eval("::BatchMesher::analyzeConnectivity")
        self.h.eval("set ::allSurfaces {1 2 4 5 6 7}")
        with self.assertRaises(tkinter.TclError):
            self.h.eval("::BatchMesher::verifyAnalysisFresh")

    def test_excluded_groups_do_not_create_tasks(self):
        groups = self.h.eval(
            "list [dict create group_id G001 surface_ids {1 2} surface_count 2 excluded 0] "
            "[dict create group_id G002 surface_ids {3} surface_count 1 excluded 1]"
        )
        self.h.tcl.setvar("groups", groups)
        self.assertEqual(self.h.eval("llength [::BatchMesher::buildTasks $groups]"), "1")

    def test_batchmesh_call_passes_user_files_without_generated_parameters(self):
        self.h.eval(
            r"""
            array set ::marks {}
            proc *clearmark {etype markId} {set ::marks($markId) {}}
            proc *createmark {etype markId args} {set ::marks($markId) $args}
            proc *hm_batchmesh2 {args} {set ::batchArgs $args; return ok}
            ::BatchMesher::runBatchMesher2019 {11 12} C:/mesh/a.criteria C:/mesh/a.param
            """
        )
        args = self.h.tcl.splitlist(self.h.eval("set ::batchArgs"))
        self.assertEqual(args[:4], ("surfs", "1", "1", "0"))
        self.assertTrue(args[4].replace("\\", "/").endswith("/mesh/a.criteria"))
        self.assertTrue(args[5].replace("\\", "/").endswith("/mesh/a.param"))

    def test_hmbatch_command_suppresses_command_and_profile_dialogs(self):
        command = self.h.tcl.splitlist(
            self.h.eval(
                "::BatchMesher::buildHmbatchCommand "
                "{C:/Program Files/Altair/hmbatch.exe} {C:/work/worker.tcl}"
            )
        )
        self.assertEqual(command[0], "C:\\Program Files\\Altair\\hmbatch.exe")
        self.assertEqual(
            command[1:4],
            ("-nocommand", "-nouserprofiledialog", "-tcl"),
        )
        self.assertEqual(command[4], "C:\\work\\worker.tcl")

    def test_background_run_enforces_real_hmbatch_preflight(self):
        manager_source = (MODULE / "background.tcl").read_text(encoding="utf-8")
        start_source = manager_source[
            manager_source.index("proc ::BatchMesher::startBackgroundRun") :
            manager_source.index("proc ::BatchMesher::readBackgroundState")
        ]
        self.assertIn("::BatchMesher::probeHmbatchExecutable", start_source)
        self.assertIn("failed the real Tcl startup gate", start_source)
        self.assertLess(
            start_source.index("::BatchMesher::probeHmbatchExecutable"),
            start_source.index("::BatchMesher::launchAvailableWorkers"),
        )

    def test_short_hm2019_versions_are_normalized(self):
        cases = {
            "19": "2019",
            "HyperMesh 19.0": "2019",
            "HyperWorks 2019.1": "2019",
        }
        for raw_version, expected_year in cases.items():
            with self.subTest(raw_version=raw_version):
                self.assertEqual(
                    self.h.eval(
                        f"::BatchMesher::supportedHyperMeshYear {{{raw_version}}}"
                    ),
                    expected_year,
                )

    def test_batchmesher_accepts_hm2019_short_version_formats(self):
        for raw_version in ("19", "19.1", "HyperMesh 2019.1"):
            with self.subTest(raw_version=raw_version):
                self.h.eval(f"proc hm_info {{args}} {{return {{{raw_version}}}}}")
                self.assertEqual(
                    self.h.eval("::BatchMesher::requireHm2019"), raw_version
                )
                self.assertEqual(
                    self.h.eval("set ::BatchMesher::ui(HYPERMESH_VERSION)"),
                    "2019",
                )

    def test_batchmesher_accepts_hm2022_real_version_formats(self):
        for raw_version in ("22", "22.000000", "HyperMesh 2022.3"):
            with self.subTest(raw_version=raw_version):
                self.h.eval(f"proc hm_info {{args}} {{return {{{raw_version}}}}}")
                self.assertEqual(
                    self.h.eval("::BatchMesher::requireSupportedHyperMesh"), raw_version
                )
                self.assertEqual(
                    self.h.eval("set ::BatchMesher::ui(HYPERMESH_VERSION)"),
                    "2022",
                )

    def test_batchmesher_rejects_other_versions(self):
        for raw_version in ("18.0", "HyperMesh 2021.2", "HyperWorks 2023.1"):
            with self.subTest(raw_version=raw_version):
                self.h.eval(f"proc hm_info {{args}} {{return {{{raw_version}}}}}")
                with self.assertRaisesRegex(tkinter.TclError, "2019 or 2022 only"):
                    self.h.eval("::BatchMesher::requireSupportedHyperMesh")

    def test_background_worker_difference_tracks_only_new_elements(self):
        self.assertEqual(
            self.h.eval("::BatchMesherWorker::difference {1 2 3 8 9} {1 3 9}"),
            "2 8",
        )

    def test_complete_import_difference_tracks_only_new_entity_ids(self):
        self.assertEqual(
            self.h.eval("::BatchMesher::idDifference {1 2 4 9} {1 3 9}"),
            "2 4",
        )

    def test_complete_import_always_uses_fe_only_merged_native_model(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            merge_dir = root / "merge"
            merge_dir.mkdir()
            merged_model = merge_dir / "merged_result.hm"
            merged_model.write_text("merged", encoding="utf-8")
            self.h.tcl.setvar("result_root", root.as_posix())
            self.h.eval(
                "set ::BatchMesher::runtime(background_release) 2019; "
                "set ::BatchMesher::runtime(background_merge_dir) [file join $result_root merge]; "
                "set ::BatchMesher::runtime(background_outputs) [list [dict create result_model [file join $result_root task_result.hm]]]"
            )
            self.assertEqual(
                Path(self.h.eval("::BatchMesher::wholeResultImportPath")),
                merged_model,
            )

    def test_merge_failure_state_is_not_overwritten_by_false_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            task_fem = root / "task_result.fem"
            task_fem.write_text("finite element model", encoding="utf-8")
            (root / "optistruct").write_text("template", encoding="utf-8")
            self.h.tcl.setvar("merge_test_root", root.as_posix())
            self.h.eval(
                r"""
                proc hm_info {args} {return 19.0}
                proc hm_answernext {args} {return}
                proc *deletemodel {} {return}
                proc *templatefileset {args} {return}
                proc *clearmark {args} {return}
                proc *createmark {args} {return}
                proc hm_getmark {args} {return {}}
                proc *createstringarray {args} {return}
                proc *feinputwithdata2 {args} {return}
                set ::BatchMesherMergeWorker::config [dict create \
                    run_dir $merge_test_root tasks {} \
                    inputs [list [file join $merge_test_root task_result.fem]] merge_mode fem \
                    main_release 2019 merged_model [file join $merge_test_root merged_result.hm] \
                    state_path [file join $merge_test_root merge.state] \
                    result_fem [file join $merge_test_root result.fem] \
                    export_template [file join $merge_test_root optistruct] \
                    run_log [file join $merge_test_root merge.log]]
                """
            )
            self.assertEqual(self.h.eval("::BatchMesherMergeWorker::main"), "2")
            self.assertEqual(
                self.h.eval(
                    "dict get [string trim [::HWFlow::readTextFile [file join $merge_test_root merge.state]]] overall_status"
                ),
                "failed",
            )
            log_text = (root / "merge.log").read_text(encoding="utf-8")
            self.assertIn("merge_failed", log_text)
            self.assertNotIn("merge_complete", log_text)

    def install_background_worker_model_mock(self, directory):
        self.h.tcl.setvar("worker_dir", Path(directory).as_posix())
        self.h.eval(
            r"""
            set ::workerElements {10}
            array set ::workerMarks {}
            proc *clearmark {etype markId} {set ::workerMarks($etype,$markId) {}}
            proc *createmark {etype markId args} {
                if {[llength $args] == 1 && [lindex $args 0] eq "all"} {
                    if {$etype eq "elems"} {set ::workerMarks($etype,$markId) $::workerElements} else {set ::workerMarks($etype,$markId) {}}
                } else {set ::workerMarks($etype,$markId) $args}
            }
            proc hm_getmark {etype markId} {return $::workerMarks($etype,$markId)}
            proc *deletemark {etype markId} {
                set ::workerElements [::BatchMesherWorker::difference $::workerElements $::workerMarks($etype,$markId)]
            }
            set ::BatchMesherWorker::config [dict create run_dir $worker_dir criteria C:/mesh/a.criteria param C:/mesh/a.param \
                state_path [file join $worker_dir background.state] result_fem [file join $worker_dir result.fem]]
            set ::BatchMesherWorker::records [list [dict create task_id T001 group_id G001 surface_ids {1 2} \
                surface_count 2 component_ids {10} component_names {FRAME_A} status pending elapsed_seconds {} started_at {} ended_at {} error_message {} log_path {}]]
            set ::BatchMesherWorker::successfulElements {}
            """
        )

    def test_background_worker_keeps_successful_new_elements(self):
        with tempfile.TemporaryDirectory() as directory:
            self.install_background_worker_model_mock(directory)
            self.h.eval("proc *hm_batchmesh2 {args} {lappend ::workerElements 20}")
            self.assertEqual(self.h.eval("::BatchMesherWorker::runTask 0"), "0")
            self.assertEqual(
                self.h.eval("dict get [lindex $::BatchMesherWorker::records 0] status"),
                "completed",
            )
            self.assertEqual(self.h.eval("set ::BatchMesherWorker::successfulElements"), "20")

    def test_background_worker_keeps_created_mesh_when_batchmesh_reports_warning(self):
        with tempfile.TemporaryDirectory() as directory:
            self.install_background_worker_model_mock(directory)
            self.h.eval(
                "proc *hm_batchmesh2 {args} {lappend ::workerElements 30; error {native batch failure}}"
            )
            self.assertEqual(self.h.eval("::BatchMesherWorker::runTask 0"), "0")
            self.assertEqual(
                self.h.eval("dict get [lindex $::BatchMesherWorker::records 0] status"),
                "completed",
            )
            self.assertEqual(self.h.eval("set ::workerElements"), "10 30")
            self.assertEqual(self.h.eval("set ::BatchMesherWorker::successfulElements"), "30")
            self.assertIn(
                "native batch failure",
                self.h.eval("dict get [lindex $::BatchMesherWorker::records 0] warning_message"),
            )

    def test_worker_packaging_removes_only_preexisting_elements(self):
        with tempfile.TemporaryDirectory() as directory:
            self.h.tcl.setvar("isolation_root", Path(directory).as_posix())
            self.h.eval(
                r"""
                array set ::isoEntities {
                    elems {10 20} nodes {1 2 3 4} comps {5} props {} mats {}
                    solids {} surfs {100} lines {} points {}
                }
                array set ::isoMarks {}
                proc *clearmark {etype markId} {set ::isoMarks($etype,$markId) {}}
                proc *createmark {etype markId args} {
                    if {[llength $args] == 1 && [lindex $args 0] eq "all"} {
                        set ::isoMarks($etype,$markId) $::isoEntities($etype)
                    } else {set ::isoMarks($etype,$markId) $args}
                }
                proc hm_getmark {etype markId} {return $::isoMarks($etype,$markId)}
                proc *deletemark {etype markId} {
                    if {$etype eq "nodes" && [llength $::isoEntities(surfs)] > 0} {
                        error "nodes are still associated with geometry"
                    }
                    set ::isoEntities($etype) [::BatchMesherWorker::difference \
                        $::isoEntities($etype) $::isoMarks($etype,$markId)]
                }
                proc hm_getvalue {etype args} {
                    set dataName [lindex [split [lindex $args 1] =] 1]
                    if {$etype eq "elems" && $dataName eq "nodes"} {return {3 4}}
                    if {$etype eq "elems" && $dataName in {collector.id collectorid component.id comp.id}} {return 5}
                    error "unsupported dataname"
                }
                proc hm_answernext {args} {return}
                proc *writefile {path args} {set ch [open $path w]; puts $ch native; close $ch}
                set ::BatchMesherWorker::config [dict create \
                    run_dir $isolation_root run_log [file join $isolation_root worker.log] \
                    output_model [file join $isolation_root task_result.hm]]
                set ::BatchMesherWorker::successfulElements {20}
                """
            )
            result = Path(self.h.eval("::BatchMesherWorker::writeIsolatedOutputModel"))
            self.assertTrue(result.is_file())
            self.assertEqual(self.h.eval("set ::isoEntities(elems)"), "20")
            self.assertEqual(self.h.eval("set ::isoEntities(surfs)"), "100")
            self.assertEqual(self.h.eval("set ::isoEntities(nodes)"), "1 2 3 4")
            log_text = (Path(directory) / "worker.log").read_text(encoding="utf-8")
            self.assertIn("isolation_stage_complete stage=remove_unretained_elements", log_text)
            self.assertNotIn("remove_surfs", log_text)
            self.assertNotIn("remove_unretained_nodes", log_text)

    def test_background_ui_uses_detached_run_and_explicit_import(self):
        ui_source = (MODULE / "ui.tcl").read_text(encoding="utf-8")
        manager_source = (MODULE / "background.tcl").read_text(encoding="utf-8")
        worker_source = (MODULE / "background_worker.tcl").read_text(encoding="utf-8")
        self.assertIn("::BatchMesher::startBackgroundRun", ui_source)
        self.assertIn("::BatchMesher::importBackgroundResult", ui_source)
        self.assertNotIn('{start "开始运行" "Start" ::BatchMesher::runTasks}', ui_source)
        self.assertIn("exec {*}$command >$stdoutPath 2>$stderrPath &", manager_source)
        self.assertIn("after $ui(BACKGROUND_POLL_MS) ::BatchMesher::pollBackgroundRunSafely", manager_source)
        self.assertIn("if {$failed && ![dict get $config continue_after_failure]}", worker_source)
        self.assertIn("::BatchMesherWorker::deleteUnretained elems", worker_source)
        self.assertIn("*feoutputwithdata", worker_source)
        self.assertIn("*allsuppressoutput 1", worker_source)
        self.assertIn("*marksuppressoutput $entityType 1 0", worker_source)

    def test_process_alive_regex_does_not_trigger_tcl_command_substitution(self):
        self.h.eval("set ::BatchMesher::runtime(background_pid) 1234")
        self.h.eval(
            "rename exec __native_exec; "
            "proc exec {args} {return {hmbatch.exe                 1234 Console                    1     10,000 K}}"
        )
        try:
            self.assertEqual(self.h.eval("::BatchMesher::backgroundProcessAlive"), "1")
        finally:
            self.h.eval("rename exec {}; rename __native_exec exec")

    def test_detached_hmbatch_launch_uses_isolated_working_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            worker_dir = Path(directory)
            launch_log = worker_dir / "launch.log"
            stdout = worker_dir / "stdout.log"
            stderr = worker_dir / "stderr.log"
            original_directory = Path(self.h.eval("pwd"))
            self.h.tcl.setvar("detached_worker_dir", worker_dir.as_posix())
            self.h.tcl.setvar("detached_launch_log", launch_log.as_posix())
            self.h.tcl.setvar("detached_stdout", stdout.as_posix())
            self.h.tcl.setvar("detached_stderr", stderr.as_posix())
            self.h.eval(
                "set ::env(HMWORKFLOW_BATCH_WORKER) interactive-session; "
                "rename exec __native_exec; "
                "proc exec {args} {"
                "set ::detachedObservedDirectory [pwd]; "
                "set ::detachedObservedMarker $::env(HMWORKFLOW_BATCH_WORKER); return 4321}"
            )
            try:
                self.assertEqual(
                    self.h.eval(
                        "::BatchMesher::launchDetachedHmbatch "
                        "[list C:/Altair/hmbatch.exe -tcl C:/work/background_launcher.tcl] "
                        "$detached_worker_dir $detached_stdout $detached_stderr $detached_launch_log"
                    ),
                    "4321",
                )
            finally:
                self.h.eval("rename exec {}; rename __native_exec exec")
            self.assertEqual(Path(self.h.eval("set ::detachedObservedDirectory")), worker_dir)
            self.assertEqual(self.h.eval("set ::detachedObservedMarker"), "1")
            self.assertEqual(
                self.h.eval("set ::env(HMWORKFLOW_BATCH_WORKER)"),
                "interactive-session",
            )
            self.assertEqual(Path(self.h.eval("pwd")), original_directory)
            report = launch_log.read_text(encoding="utf-8")
            self.assertIn("status=LAUNCH_REQUESTED", report)
            self.assertIn("launcher_pid=4321", report)
            self.assertIn(
                f"working_directory={worker_dir.as_posix()}",
                report.replace("\\", "/"),
            )

    def test_manager_failure_report_exists_when_hmbatch_logs_are_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            worker_dir = Path(directory)
            artifacts = {
                "launch_log": worker_dir / "launch.log",
                "state_path": worker_dir / "background.state",
                "stdout": worker_dir / "hmbatch_stdout.log",
                "stderr": worker_dir / "hmbatch_stderr.log",
            }
            for artifact in artifacts.values():
                artifact.write_text("", encoding="utf-8")
            self.h.tcl.setvar("failure_worker_dir", worker_dir.as_posix())
            for key, artifact in artifacts.items():
                self.h.tcl.setvar(f"failure_{key}", artifact.as_posix())
            report_path = Path(
                self.h.eval(
                    "::BatchMesher::writeWorkerManagerFailure [dict create "
                    "task_id T001 launcher_pid 123 actual_pid {} worker_dir $failure_worker_dir "
                    "launch_log $failure_launch_log state_path $failure_state_path "
                    "stdout $failure_stdout stderr $failure_stderr] {startup timeout}"
                )
            )
            report = report_path.read_text(encoding="utf-8")
            self.assertIn("message=startup timeout", report)
            self.assertIn("task_id=T001", report)
            self.assertIn("bytes=0", report)

    def test_worker_startup_waits_for_state_handshake(self):
        self.assertGreaterEqual(
            int(self.h.eval("set ::BatchMesher::WORKER_STARTUP_TIMEOUT_MS")),
            60000,
        )
        manager_source = (MODULE / "background.tcl").read_text(encoding="utf-8")
        self.assertIn('if {$state eq "" && [dict get $job actual_pid] eq ""}', manager_source)
        self.assertIn("$startupElapsed < $WORKER_STARTUP_TIMEOUT_MS", manager_source)
        self.assertIn("worker initialized actual_pid=", manager_source)

    def test_background_launcher_reports_worker_source_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            self.h.tcl.setvar("launcher_dir", Path(directory).as_posix())
            self.h.tcl.setvar("module_dir", MODULE.as_posix())
            self.h.eval("set ::BatchMesher::MODULE_DIR $module_dir")
            self.h.eval("set ::BatchMesher::runtime(run_dir) $launcher_dir")
            self.h.eval(
                "set launcher [::BatchMesher::writeBackgroundLauncher "
                "[dict create run_dir $launcher_dir tasks {} state_path [file join $launcher_dir state] "
                "result_fem [file join $launcher_dir result.fem]]]"
            )
            launcher = Path(self.h.eval("set launcher"))
            source = launcher.read_text(encoding="utf-8")
            self.assertIn("launcher_error.log", source)
            self.assertIn("overall_status failed", source)
            self.assertIn("catch {source $__bm_worker}", source)
            self.assertNotIn("source -encoding", source)

    def test_one_consolidated_cmd_monitor_auto_closes_when_run_finishes(self):
        with tempfile.TemporaryDirectory() as directory:
            self.h.tcl.setvar("console_dir", Path(directory).as_posix())
            self.h.eval("set ::BatchMesher::runtime(run_dir) $console_dir")
            self.h.eval(
                "set ::BatchMesher::runtime(background_monitor_status_path) [file join $console_dir monitor_status.txt]; "
                "set ::BatchMesher::runtime(background_monitor_done_path) [file join $console_dir monitor.done]; "
                "set console_script [::BatchMesher::writeRunCmdMonitor]"
            )
            source = Path(self.h.eval("set console_script")).read_text(encoding="utf-8")
            self.assertIn("consolidated process monitor", source)
            self.assertIn("monitor_status.txt", source)
            self.assertIn("monitor.done", source)
            self.assertIn('if exist "%DONE%" goto finished', source)
            self.assertIn("This window will close automatically", source)
            self.assertNotIn("pause", source)

            manager_source = (MODULE / "background.tcl").read_text(encoding="utf-8")
            monitor_launch = "catch {::BatchMesher::openRunCmdMonitor}"
            start_source = manager_source[
                manager_source.index("proc ::BatchMesher::startBackgroundRun") :
                manager_source.index("proc ::BatchMesher::readBackgroundState")
            ]
            self.assertLess(
                start_source.index("::BatchMesher::launchAvailableWorkers"),
                start_source.index(monitor_launch),
            )
            self.assertEqual(manager_source.count("::BatchMesher::openRunCmdMonitor"), 2)
            self.assertNotIn("::BatchMesher::openCmdMonitor", manager_source)
            self.assertNotIn("Start-Process", manager_source)

    def test_connectivity_groups_have_isolated_parallel_workers_and_merge_stage(self):
        manager_source = (MODULE / "background.tcl").read_text(encoding="utf-8")
        worker_source = (MODULE / "background_worker.tcl").read_text(encoding="utf-8")
        merge_source = (MODULE / "background_merge_worker.tcl").read_text(encoding="utf-8")
        ui_source = (MODULE / "ui.tcl").read_text(encoding="utf-8")
        self.assertIn("workers $taskId", manager_source)
        self.assertIn("dict set runtime(background_active) $taskId $job", manager_source)
        self.assertIn("$ui(PARALLEL_WORKERS)", manager_source)
        self.assertIn("::BatchMesher::startMergeWorker", manager_source)
        self.assertIn("after 100 ::BatchMesher::autoImportBackgroundResult", manager_source)
        self.assertIn("::BatchMesher::rollbackImportDelta $delta", manager_source)
        self.assertIn("::BatchMesher::importWholeResult $path", manager_source)
        self.assertIn("mesh completed but result packaging failed", manager_source)
        self.assertIn("if {$importAvailable}", manager_source)
        self.assertNotIn("foreach path $paths", manager_source)
        self.assertIn("lappend inputs [dict get $job result_fem]", manager_source)
        self.assertIn('set mergeMode fem', manager_source)
        self.assertIn("*templatefileset", worker_source)
        self.assertIn("*readqualitycriteria", worker_source)
        self.assertIn("worker_pid [pid]", worker_source)
        self.assertIn("CONFIG_CHANGED_DURING_RUN", worker_source)
        self.assertIn("::BatchMesherWorker::writeIsolatedOutputModel", worker_source)
        self.assertNotIn("*feinputwithdata2", worker_source)
        self.assertNotIn("exit 2", worker_source)
        self.assertNotIn("*mergefile", merge_source)
        self.assertIn("*feinputwithdata2", merge_source)
        self.assertIn('overwrite_flag=0', merge_source)
        self.assertIn(
            '*feinputwithdata2 "#optistruct/optistruct" [file nativename $input] 0 0 0 0 0 1 0 1 0',
            merge_source,
        )
        self.assertIn("set command [list *mergefile [file nativename $path] 0 1]", manager_source)
        self.assertIn("final_fem_export_failed", merge_source)
        self.assertIn("::BatchMesher::importWholeFemResult $femPath", manager_source)
        self.assertIn(
            "[file nativename $path] 0 0 0 0 0 1 0 1 0",
            manager_source,
        )
        self.assertNotIn("exit 2", merge_source)
        self.assertIn("*feoutputwithdata", merge_source)
        self.assertIn("Parallel independent tasks", ui_source)

    def test_worker_normalizes_real_hm2022_version(self):
        self.assertEqual(
            self.h.eval("::BatchMesherWorker::releaseFromVersion 22.000000"),
            "2022",
        )

    def test_hm2022_worker_initializes_profile_from_worker_config(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = root / "optistruct"
            criteria = root / "mesh.criteria"
            template.write_text("template", encoding="utf-8")
            criteria.write_text("criteria", encoding="utf-8")
            self.h.tcl.setvar("hm2022_template", template.as_posix())
            self.h.tcl.setvar("hm2022_criteria", criteria.as_posix())
            self.h.eval(
                r"""
                set ::BatchMesherWorker::config [dict create \
                    export_template $hm2022_template criteria $hm2022_criteria]
                set ::hm2022ProfileCalls {}
                proc *templatefileset {path} {
                    lappend ::hm2022ProfileCalls [list template $path]
                }
                proc *readqualitycriteria {path} {
                    lappend ::hm2022ProfileCalls [list criteria $path]
                }
                """
            )
            self.h.eval("::BatchMesherWorker::initializeBatchMeshProfile 2022")
            self.assertEqual(
                Path(self.h.eval("lindex [lindex $::hm2022ProfileCalls 0] 1")),
                template,
            )
            self.assertEqual(
                Path(self.h.eval("lindex [lindex $::hm2022ProfileCalls 1] 1")),
                criteria,
            )

    def test_scale_preflight_rejects_element_size_larger_than_model_span(self):
        with tempfile.TemporaryDirectory() as directory:
            param = Path(directory) / "mesh.param"
            param.write_text("element_size 8.0\n", encoding="utf-8")
            self.h.tcl.setvar("scale_param", param.as_posix())
            self.h.eval(
                r"""
                proc hm_getsurfaceedges {surfaceId} {return {{10 11}}}
                proc hm_getverticesfromedge {edgeId} {
                    if {$edgeId == 10} {return {1 2}}
                    return {3 4}
                }
                proc hm_getvalue {entityType args} {
                    set pointId [lindex [split [lindex $args 0] =] 1]
                    return [dict get {1 {0 0 0} 2 {5 0 0} 3 {0 1 0} 4 {5 1 0}} $pointId]
                }
                """
            )
            with self.assertRaisesRegex(tkinter.TclError, "different length units"):
                self.h.eval("::BatchMesher::validateBatchMeshScale {100} $scale_param")

            param.write_text("element_size 0.008\n", encoding="utf-8")
            result = self.h.eval(
                "::BatchMesher::validateBatchMeshScale {100} $scale_param"
            )
            self.assertEqual(self.h.eval(f"dict get {{{result}}} element_size"), "0.008")

    def test_existing_worker_error_is_not_overwritten_by_packaging_summary(self):
        self.h.eval(
            "set ::BatchMesher::runtime(tasks) [list [dict create task_id T001 "
            "status failed ended_at {} error_message {*hm_batchmesh2 returned 0}]]"
        )
        self.h.eval("::BatchMesher::setTaskFailed T001 {no successful output package}")
        self.assertEqual(
            self.h.eval("dict get [lindex $::BatchMesher::runtime(tasks) 0] error_message"),
            "*hm_batchmesh2 returned 0",
        )

    def test_worker_skips_packaging_when_every_mesh_task_failed(self):
        worker_source = (MODULE / "background_worker.tcl").read_text(encoding="utf-8")
        self.assertIn('packaging_skipped reason=no_successful_mesh_elements', worker_source)
        self.assertIn('set overall [expr {$failures > 0 ? "failed" : "completed"}]', worker_source)

    def test_worker_auto_switches_stale_live_session_to_meter_companion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            criteria = root / "mesh.criteria"
            param = root / "mesh.param"
            meter_criteria = root / "mesh_meter.criteria"
            meter_param = root / "mesh_meter.param"
            criteria.write_text("criteria\n", encoding="utf-8")
            param.write_text("element_size 8.0\n", encoding="utf-8")
            meter_criteria.write_text("criteria\n", encoding="utf-8")
            meter_param.write_text("element_size 0.008\n", encoding="utf-8")
            self.h.tcl.setvar("unit_root", root.as_posix())
            self.h.eval(
                r"""
                set ::BatchMesherWorker::config [dict create \
                    criteria [file join $unit_root mesh.criteria] \
                    param [file join $unit_root mesh.param] \
                    run_log [file join $unit_root worker.log]]
                set ::BatchMesherWorker::records [list [dict create surface_ids {100}]]
                proc hm_getsurfaceedges {surfaceId} {return {{10}}}
                proc hm_getverticesfromedge {edgeId} {return {1 2}}
                proc hm_getvalue {entityType args} {
                    set pointId [lindex [split [lindex $args 0] =] 1]
                    if {$pointId == 1} {return {0 0 0}}
                    return {5 0 0}
                }
                """
            )
            self.assertEqual(
                self.h.eval("::BatchMesherWorker::resolveUnitCompatibleConfiguration"),
                "1",
            )
            self.assertEqual(
                Path(self.h.eval("dict get $::BatchMesherWorker::config param")).as_posix(),
                meter_param.as_posix(),
            )
            self.assertIn(
                "configuration_auto_switched",
                (root / "worker.log").read_text(encoding="utf-8"),
            )

    def test_hmbatch_release_is_not_bound_to_interactive_release(self):
        executor_source = (MODULE / "executor.tcl").read_text(encoding="utf-8")
        manager_source = (MODULE / "background.tcl").read_text(encoding="utf-8")
        worker_source = (MODULE / "background_worker.tcl").read_text(encoding="utf-8")
        merge_source = (MODULE / "background_merge_worker.tcl").read_text(encoding="utf-8")
        self.assertNotIn("does not match the current HyperMesh release", executor_source)
        self.assertNotIn("expected_release", manager_source)
        self.assertNotIn("expected_release", worker_source)
        self.assertNotIn("expected_release", merge_source)
        self.assertIn("::BatchMesherWorker::optistructTemplate", worker_source)
        self.assertIn("::BatchMesherMergeWorker::optistructTemplate", merge_source)
        self.assertEqual(
            self.h.eval("::BatchMesherMergeWorker::releaseFromVersion 22.000000"),
            "2022",
        )

    def test_parallel_scheduler_fills_configured_worker_slots(self):
        self.h.eval(
            "set ::BatchMesher::runtime(background_pending) [list "
            "[dict create task_id T001 status pending] "
            "[dict create task_id T002 status pending] "
            "[dict create task_id T003 status pending]]; "
            "set ::BatchMesher::runtime(background_active) [dict create]; "
            "set ::BatchMesher::runtime(background_merge_pid) {}; "
            "set ::BatchMesher::runtime(stop_after_current) 0; "
            "set ::BatchMesher::runtime(background_startup_verified) 1; "
            "set ::BatchMesher::ui(PARALLEL_WORKERS) 2; "
            "rename ::BatchMesher::launchTaskWorker ::BatchMesher::__realLaunchTaskWorker; "
            "proc ::BatchMesher::launchTaskWorker {task} {"
            "variable runtime; set taskId [dict get $task task_id]; "
            "set fakePid [string range $taskId 1 end]; "
            "dict set runtime(background_active) $taskId [dict create pid $fakePid launcher_pid $fakePid actual_pid {}]; return 1}"
        )
        try:
            self.h.eval("::BatchMesher::launchAvailableWorkers")
            self.assertEqual(
                self.h.eval("dict size $::BatchMesher::runtime(background_active)"),
                "2",
            )
            self.assertEqual(
                self.h.eval("llength $::BatchMesher::runtime(background_pending)"),
                "1",
            )
            self.h.eval("::BatchMesher::releaseWorkerAndRefill T001")
            self.assertEqual(
                self.h.eval("dict size $::BatchMesher::runtime(background_active)"),
                "2",
            )
            self.assertEqual(
                self.h.eval("dict exists $::BatchMesher::runtime(background_active) T001"),
                "0",
            )
            self.assertEqual(
                self.h.eval("dict exists $::BatchMesher::runtime(background_active) T003"),
                "1",
            )
            self.assertEqual(
                self.h.eval("llength $::BatchMesher::runtime(background_pending)"),
                "0",
            )
        finally:
            self.h.eval(
                "rename ::BatchMesher::launchTaskWorker {}; "
                "rename ::BatchMesher::__realLaunchTaskWorker ::BatchMesher::launchTaskWorker"
            )

    def test_parallel_scheduler_starts_one_canary_before_filling_pool(self):
        self.h.eval(
            "set ::BatchMesher::runtime(background_pending) [list "
            "[dict create task_id T001] [dict create task_id T002] [dict create task_id T003]]; "
            "set ::BatchMesher::runtime(background_active) [dict create]; "
            "set ::BatchMesher::runtime(background_merge_pid) {}; "
            "set ::BatchMesher::runtime(stop_after_current) 0; "
            "set ::BatchMesher::runtime(background_startup_verified) 0; "
            "set ::BatchMesher::ui(PARALLEL_WORKERS) 8; "
            "rename ::BatchMesher::launchTaskWorker ::BatchMesher::__realLaunchTaskWorker; "
            "proc ::BatchMesher::launchTaskWorker {task} {"
            "variable runtime; set taskId [dict get $task task_id]; "
            "dict set runtime(background_active) $taskId [dict create launcher_pid 1 actual_pid {}]; return 1}"
        )
        try:
            self.h.eval("::BatchMesher::launchAvailableWorkers")
            self.assertEqual(
                self.h.eval("dict size $::BatchMesher::runtime(background_active)"),
                "1",
            )
            self.assertEqual(
                self.h.eval("llength $::BatchMesher::runtime(background_pending)"),
                "2",
            )
        finally:
            self.h.eval(
                "rename ::BatchMesher::launchTaskWorker {}; "
                "rename ::BatchMesher::__realLaunchTaskWorker ::BatchMesher::launchTaskWorker"
            )

    def test_run_report_is_valid_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).as_posix()
            self.h.eval(f"set ::BatchMesher::runtime(run_dir) {{{path}}}")
            self.h.eval("set ::BatchMesher::runtime(run_id) batchmesh_test")
            self.h.eval("set ::BatchMesher::runtime(run_started_ms) 1000")
            self.h.eval("set ::BatchMesher::runtime(run_finished_ms) 2500")
            self.h.eval("set ::BatchMesher::runtime(selected_surfaces) {1 2}")
            self.h.eval("set ::BatchMesher::ui(HYPERMESH_VERSION) 2019")
            self.h.eval("set ::BatchMesher::runtime(groups) [list [dict create group_id G001 surface_ids {1 2} surface_count 2 component_ids {10} component_names {FRAME_A} excluded 0]]")
            self.h.eval("set ::BatchMesher::runtime(tasks) [::BatchMesher::buildTasks $::BatchMesher::runtime(groups)]")
            self.h.eval("::BatchMesher::writeRunReport 1")
            data = json.loads((Path(directory) / "result.json").read_text(encoding="utf-8"))
            self.assertEqual(data["hypermesh_version"], "2019")
            self.assertEqual(data["groups"][0]["surface_ids"], [1, 2])


if __name__ == "__main__":
    unittest.main()
