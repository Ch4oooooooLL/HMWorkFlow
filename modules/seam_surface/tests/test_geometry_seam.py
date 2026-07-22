from pathlib import Path
import tkinter
import unittest


ROOT = Path(__file__).resolve().parents[3]
LOADER = ROOT / "modules" / "seam_surface.tcl"
MODULE_DIR = ROOT / "modules" / "seam_surface"


class GeometrySeamTclTests(unittest.TestCase):
    def setUp(self):
        self.tcl = tkinter.Tcl()
        self.tcl.eval(f"source {{{LOADER.as_posix()}}}")

    def test_all_legacy_entries_delegate(self):
        names = {
            "Create_seam_surface_T_path",
            "Create_seam_surface_T_list",
            "Create_seam_surface_L_surf",
            "Create_seam_surface_L_list",
            "Create_seam_combine",
            "Create_seam_connect",
            "Create_seam_project",
            "Create_seam_dist_points",
            "Create_seam_replace",
            "Create_seam_extend",
            "Del_seam_surf",
            "Split_surface",
        }
        for name in names:
            self.assertEqual(self.tcl.eval(f"llength [info commands ::{name}]"), "1")
            self.assertEqual(
                self.tcl.eval(f"llength [info commands ::altair::pmgr::pm_common::{name}]"),
                "1",
            )

    def test_configuration_load_has_no_file_command_shadowing(self):
        path = self.tcl.eval("::hmtoolkit::seam::config::path")
        self.assertTrue(path.replace("\\", "/").endswith("/seam_rules.txt"))
        values = self.tcl.eval("::hmtoolkit::seam::config::load")
        self.assertIn("distance_tolerance", values)
        self.assertEqual(self.tcl.eval("llength [info commands ::hmtoolkit::seam::config::file]"), "0")
        self.assertIn(self.tcl.eval("::hmtoolkit::seam::config::get shortcut_selector_mode"), {"PANEL", "CONFIG"})
        self.assertIn(self.tcl.eval("::hmtoolkit::seam::config::get shortcut_scope"), {"COMPONENT_PAIR", "SURFACE_GROUPS"})

    def test_created_surface_validation_uses_target_component_scope(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::entity::component_surfaces ::hmtoolkit::seam::entity::component_surfaces_real
            rename ::hmtoolkit::seam::validation::surface_ids ::hmtoolkit::seam::validation::surface_ids_real
            proc ::hmtoolkit::seam::entity::component_surfaces {componentId} {return {10 40}}
            proc ::hmtoolkit::seam::validation::surface_ids {ids componentId} {return 1}
            """
        )
        created = self.tcl.eval(
            "::hmtoolkit::seam::validation::created_surfaces_in_component {10} 99"
        )
        self.assertEqual(created, "40")

    def test_shortcut_and_precise_context_contracts_are_wired(self):
        core = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        main = (MODULE_DIR / "main.tcl").read_text(encoding="utf-8")
        ui = (MODULE_DIR / "ui.tcl").read_text(encoding="utf-8")
        self.assertIn('shortcut_proc "::SeamSurf::runShortcut"', core)
        self.assertIn("invokeModule $target shortcut", core)
        self.assertIn("selector::capture_preselection", main)
        self.assertIn("runtime(context_data)", ui)
        self.assertIn("analyze_context $runtime(context_data) $strategy", ui)

    def test_path_topology_is_order_independent(self):
        self.tcl.eval(
            """
            proc test_line_points {id} {
                switch -- $id {
                    10 {return {{0 0 0} {0.5 0 0} {1 0 0}}}
                    20 {return {{2 0 0} {1.5 0 0} {1 0 0}}}
                    30 {return {{9 0 0} {9.5 0 0} {10 0 0}}}
                    40 {return {{1 0 0} {1 0.5 0} {1 1 0}}}
                }
            }
            """
        )
        path = self.tcl.eval(
            "dict get [::hmtoolkit::seam::candidate::path_topology {20 10} test_line_points 0.01] kind"
        )
        disconnected = self.tcl.eval(
            "dict get [::hmtoolkit::seam::candidate::path_topology {30 10} test_line_points 0.01] kind"
        )
        branch = self.tcl.eval(
            "dict get [::hmtoolkit::seam::candidate::path_topology {10 20 40} test_line_points 0.01] kind"
        )
        self.assertEqual(path, "PATH")
        self.assertEqual(disconnected, "LIST")
        self.assertEqual(branch, "BRANCH")

    def test_candidate_extraction_returns_individual_surface_pairs(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::entity::surface_lines ::hmtoolkit::seam::entity::surface_lines_real
            rename ::hmtoolkit::seam::entity::surface_component ::hmtoolkit::seam::entity::surface_component_real
            rename ::hmtoolkit::seam::candidate::line_near_surfaces ::hmtoolkit::seam::candidate::line_near_surfaces_real
            rename ::hmtoolkit::seam::candidate::line_points ::hmtoolkit::seam::candidate::line_points_real
            rename ::hmtoolkit::seam::candidate::surface_normal ::hmtoolkit::seam::candidate::surface_normal_real
            rename ::hmtoolkit::seam::candidate::bbox_overlap_ratio ::hmtoolkit::seam::candidate::bbox_overlap_ratio_real
            proc ::hmtoolkit::seam::entity::surface_lines {surfs} {return [list [expr {100+[lindex $surfs 0]}]]}
            proc ::hmtoolkit::seam::entity::surface_component {surf} {return [expr {1000+$surf}]}
            proc ::hmtoolkit::seam::candidate::line_near_surfaces {line surfs tolerance} {return {1 0.1}}
            proc ::hmtoolkit::seam::candidate::line_points {line} {return [list [list $line 0 0] [list $line 0.5 0] [list $line 1 0]]}
            proc ::hmtoolkit::seam::candidate::surface_normal {surf} {
                if {$surf < 3} {return {1 0 0}}
                return {0 1 0}
            }
            proc ::hmtoolkit::seam::candidate::bbox_overlap_ratio {a b tolerance} {return 1.0}
            """
        )
        candidates = self.tcl.eval(
            "::hmtoolkit::seam::candidate::extract {1 2} {3 4} {10} {20}"
        )
        self.assertEqual(int(self.tcl.eval(f"llength {{{candidates}}}")), 4)
        for index in range(4):
            candidate = self.tcl.eval(f"lindex {{{candidates}}} {index}")
            self.assertEqual(self.tcl.eval(f"llength [dict get {{{candidate}}} source_surfs]"), "1")
            self.assertEqual(self.tcl.eval(f"llength [dict get {{{candidate}}} target_surfs]"), "1")

    def classify(self, angle, source="1", target="", topology="PATH"):
        return self.tcl.eval(
            f"""
            set c [dict create candidate_id X joint_type UNKNOWN strategy REVIEW \
                source_components {{}} target_components {{}} source_surfs {{1}} target_surfs {{2}} \
                seam_lines {{{source}}} paired_target_lines {{{target}}} angle {angle} min_distance 0.1 \
                overlap_ratio 1.0 seam_length 20 path_topology [dict create kind {topology}] \
                confidence 0 reasons {{}} warnings {{}}]
            set c [::hmtoolkit::seam::classifier::classify $c]
            list [dict get $c joint_type] [dict get $c strategy]
            """
        )

    def test_classifier_routes_t_corner_lap_and_review(self):
        self.assertEqual(self.classify(89, "1", ""), "T_JOINT T_PATH")
        self.assertEqual(self.classify(89, "1", "2"), "CORNER_JOINT CONNECT")
        self.assertEqual(self.classify(2, "1", "2"), "LAP_JOINT L_SURF")
        self.assertEqual(self.classify(45, "1", ""), "UNKNOWN REVIEW")
        self.assertEqual(self.classify(89, "1", "", "BRANCH"), "T_JOINT REVIEW")

    def test_executor_has_no_interactive_panels_or_max_id_tracking(self):
        executor = (MODULE_DIR / "executor.tcl").read_text(encoding="utf-8")
        for forbidden in (
            "createmarkpanel",
            "createlistpanel",
            "createlistbypathpanel",
            "Get_max_id",
            "hm_latestentityid",
            'Current_entity "Temp_Surfs',
        ):
            self.assertNotIn(forbidden, executor)
        self.assertIn("snapshot_ids", executor)
        self.assertIn("diff_ids", executor)

    def test_history_is_centralized_and_paired(self):
        executor = (MODULE_DIR / "executor.tcl").read_text(encoding="utf-8")
        state = (MODULE_DIR / "state.tcl").read_text(encoding="utf-8")
        self.assertNotIn("*startnotehistorystate", executor)
        self.assertEqual(state.count("*startnotehistorystate"), 1)
        self.assertEqual(state.count("*endnotehistorystate"), 1)


if __name__ == "__main__":
    unittest.main()
