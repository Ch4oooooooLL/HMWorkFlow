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
        self.tcl.eval("namespace eval ::HybridCore {}")
        self.tcl.eval("proc ::HybridCore::log {level message} {return \"$level $message\"}")
        for name in ("config.tcl", "selection.tcl", "connectivity.tcl", "logging.tcl", "executor.tcl"):
            self.tcl.eval(f"source -encoding utf-8 {{{(MODULE / name).as_posix()}}}")
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

    def test_run_report_is_valid_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).as_posix()
            self.h.eval(f"set ::BatchMesher::runtime(run_dir) {{{path}}}")
            self.h.eval("set ::BatchMesher::runtime(run_id) batchmesh_test")
            self.h.eval("set ::BatchMesher::runtime(run_started_ms) 1000")
            self.h.eval("set ::BatchMesher::runtime(run_finished_ms) 2500")
            self.h.eval("set ::BatchMesher::runtime(selected_surfaces) {1 2}")
            self.h.eval("set ::BatchMesher::runtime(groups) [list [dict create group_id G001 surface_ids {1 2} surface_count 2 component_ids {10} component_names {FRAME_A} excluded 0]]")
            self.h.eval("set ::BatchMesher::runtime(tasks) [::BatchMesher::buildTasks $::BatchMesher::runtime(groups)]")
            self.h.eval("::BatchMesher::writeRunReport 1")
            data = json.loads((Path(directory) / "result.json").read_text(encoding="utf-8"))
            self.assertEqual(data["hypermesh_version"], "2019")
            self.assertEqual(data["groups"][0]["surface_ids"], [1, 2])


if __name__ == "__main__":
    unittest.main()
