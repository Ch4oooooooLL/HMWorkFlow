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
        self.assertGreater(float(self.tcl.eval("::hmtoolkit::seam::config::get stitch_tolerance")), 0.0)

    def test_stitching_is_local_uses_all_edges_and_requires_two_connected_sides(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::validation::created_surfaces_in_component ::hmtoolkit::seam::validation::created_surfaces_in_component_real
            proc ::hmtoolkit::seam::entity::exists {entityType id} {return 1}
            set ::stitch_marks {}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {
                lappend ::stitch_marks [list $entityType $markId $ids]
                return [llength $ids]
            }
            set ::stitch_modes {}
            proc *selfstitchcombine {markId mode tolerance1 tolerance2} {
                lappend ::stitch_modes [list $markId $mode $tolerance1 $tolerance2]
            }
            proc ::hmtoolkit::seam::validation::created_surfaces_in_component {before componentId} {return {50 51}}
            proc ::hmtoolkit::seam::executor::external_owner_surfaces {seamSurfs} {return {10 11 20 21}}
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::equivalence_created_surfaces "
            "{50 51} {10 11} {20 21} 900 {40}"
        )
        self.assertEqual(result, "50 51")
        self.assertEqual(
            self.tcl.eval("lindex $::stitch_marks 0"),
            "surfs 1 {10 11 20 21 50 51}",
        )
        self.assertEqual(self.tcl.eval("lindex [lindex $::stitch_modes 0] 1"), "134")

    def test_partial_target_topology_is_rejected_instead_of_reported_as_success(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::validation::created_surfaces_in_component ::hmtoolkit::seam::validation::created_surfaces_in_component_real
            proc ::hmtoolkit::seam::entity::exists {entityType id} {return 1}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {return [llength $ids]}
            proc *selfstitchcombine {args} {}
            proc ::hmtoolkit::seam::validation::created_surfaces_in_component {before componentId} {return {50}}
            proc ::hmtoolkit::seam::executor::external_owner_surfaces {seamSurfs} {
                return {10 20}
            }
            """
        )
        with self.assertRaisesRegex(tkinter.TclError, "not topologically connected"):
            self.tcl.eval(
                "::hmtoolkit::seam::executor::equivalence_created_surfaces "
                "{50} {10} {20 21} 900 {40}"
            )

    def test_stitching_retries_each_created_surface_against_each_contact_surface(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::validation::created_surfaces_in_component ::hmtoolkit::seam::validation::created_surfaces_in_component_real
            proc ::hmtoolkit::seam::entity::exists {entityType id} {return 1}
            set ::pairwise_stitch_mark {}
            set ::pairwise_stitch_sets {}
            set ::pairwise_owners {}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {
                set ::pairwise_stitch_mark [lsort -integer -unique $ids]
                return [llength $ids]
            }
            proc *selfstitchcombine {args} {
                lappend ::pairwise_stitch_sets $::pairwise_stitch_mark
                if {$::pairwise_stitch_mark eq "10 50"} {lappend ::pairwise_owners 10}
                if {$::pairwise_stitch_mark eq "20 51"} {lappend ::pairwise_owners 20}
                set ::pairwise_owners [lsort -integer -unique $::pairwise_owners]
            }
            proc ::hmtoolkit::seam::validation::created_surfaces_in_component {before componentId} {
                return {50 51}
            }
            proc ::hmtoolkit::seam::executor::external_owner_surfaces {seamSurfs} {
                return $::pairwise_owners
            }
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::equivalence_created_surfaces "
            "{50 51} {10} {20} 900 {40}"
        )
        self.assertEqual(result, "50 51")
        stitched = self.tcl.eval("set ::pairwise_stitch_sets")
        self.assertIn("{10 50}", stitched)
        self.assertIn("{20 51}", stitched)

    def test_topology_validation_uses_shared_edge_ids_when_reverse_query_is_unavailable(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::entity::surface_lines ::hmtoolkit::seam::entity::surface_lines_real
            rename ::hmtoolkit::seam::validation::created_surfaces_in_component ::hmtoolkit::seam::validation::created_surfaces_in_component_real
            proc ::hmtoolkit::seam::entity::exists {entityType id} {return 1}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {return [llength $ids]}
            proc ::hmtoolkit::seam::entity::surface_lines {surfaceIds} {
                set lines {}
                foreach surfaceId $surfaceIds {
                    switch -- $surfaceId {
                        10 {set lines [concat $lines {100 101}]}
                        20 {set lines [concat $lines {200 201}]}
                        50 {set lines [concat $lines {100 200 500}]}
                    }
                }
                return [lsort -integer -unique $lines]
            }
            proc *selfstitchcombine {args} {}
            proc ::hmtoolkit::seam::validation::created_surfaces_in_component {before componentId} {return {50}}
            proc ::hmtoolkit::seam::executor::external_owner_surfaces {seamSurfs} {return {}}
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::equivalence_created_surfaces "
            "{50} {10} {20} 900 {40}"
        )
        self.assertEqual(result, "50")

    def test_connect_builds_all_four_required_ruled_surface_lists(self):
        self.tcl.eval(
            """
            set ::ruled_surface_lists {}
            proc *createlist {entityType listId args} {
                lappend ::ruled_surface_lists [list $entityType $listId $args]
            }
            """
        )
        self.tcl.eval(
            "::hmtoolkit::seam::executor::prepare_ruled_surface_lists "
            "{101 102} {201 202}"
        )
        self.assertEqual(
            self.tcl.eval("set ::ruled_surface_lists"),
            "{lines 1 {101 102}} {nodes 1 {}} {lines 2 {201 202}} {nodes 2 {}}",
        )

    def test_connect_line_paths_are_sorted_by_endpoint_continuity(self):
        self.tcl.eval(
            """
            proc test_connect_line_points {id} {
                switch -- $id {
                    10 {return {{0 0 0} {1 0 0}}}
                    20 {return {{2 0 0} {1 0 0}}}
                    30 {return {{3 0 0} {2 0 0}}}
                }
            }
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::candidate::ordered_line_path "
            "{30 10 20} test_connect_line_points 0.01"
        )
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} lines"), "10 20 30")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} closed"), "0")

    def test_connect_line_paths_reverse_second_side_to_prevent_twist(self):
        self.tcl.eval(
            """
            proc test_connect_pair_points {id} {
                switch -- $id {
                    10 {return {{0 100 0} {10 0 0}}}
                    20 {return {{5 0 1} {10 100 1}}}
                    30 {return {{10 100 1} {20 110 1}}}
                }
            }
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::candidate::organize_ruled_surface_lines "
            "{10} {30 20} test_connect_pair_points 0.01"
        )
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} first_lines"), "10")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} second_lines"), "30 20")

    def test_connect_line_paths_reject_disconnected_or_branched_input(self):
        self.tcl.eval(
            """
            proc test_invalid_connect_points {id} {
                switch -- $id {
                    10 {return {{0 0 0} {1 0 0}}}
                    20 {return {{5 0 0} {6 0 0}}}
                    30 {return {{1 0 0} {2 0 0}}}
                    40 {return {{1 0 0} {1 1 0}}}
                }
            }
            """
        )
        with self.assertRaisesRegex(tkinter.TclError, "disconnected"):
            self.tcl.eval(
                "::hmtoolkit::seam::candidate::ordered_line_path "
                "{10 20} test_invalid_connect_points 0.01"
            )
        with self.assertRaisesRegex(tkinter.TclError, "branched"):
            self.tcl.eval(
                "::hmtoolkit::seam::candidate::ordered_line_path "
                "{10 30 40} test_invalid_connect_points 0.01"
            )

    def test_connect_closed_paths_align_their_break_and_direction(self):
        self.tcl.eval(
            """
            proc test_closed_connect_points {id} {
                switch -- $id {
                    10 {return {{0 0 0} {1 0 0}}}
                    11 {return {{1 0 0} {1 1 0}}}
                    12 {return {{1 1 0} {0 1 0}}}
                    13 {return {{0 1 0} {0 0 0}}}
                    20 {return {{0.1 0.1 1} {1 0 1}}}
                    21 {return {{1 0 1} {1 1 1}}}
                    22 {return {{1 1 1} {-0.2 1 1}}}
                    23 {return {{-0.2 1 1} {0.1 0.1 1}}}
                }
            }
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::candidate::organize_ruled_surface_lines "
            "{11 13 10 12} {22 20 23 21} test_closed_connect_points 0.01"
        )
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} first_lines"), "13 12 11 10")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} second_lines"), "23 22 21 20")

    def test_connect_captures_input_surface_owners_before_creating_the_seam(self):
        body = self.tcl.eval("info body ::hmtoolkit::seam::executor::_connect_edges")
        first_owner = body.index("set firstSurfs")
        second_owner = body.index("set secondSurfs")
        creation = body.index("*linearsurfacebetweenlines")
        self.assertLess(first_owner, creation)
        self.assertLess(second_owner, creation)

    def test_t_list_creation_equivalences_new_seam_before_reporting_success(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::validation::require_ids ::hmtoolkit::seam::validation::require_ids_real
            rename ::hmtoolkit::seam::candidate::path_topology ::hmtoolkit::seam::candidate::path_topology_real
            rename ::hmtoolkit::seam::naming::thickness_from_data ::hmtoolkit::seam::naming::thickness_from_data_real
            rename ::hmtoolkit::seam::naming::get_or_create_component ::hmtoolkit::seam::naming::get_or_create_component_real
            rename ::hmtoolkit::seam::entity::component_surfaces ::hmtoolkit::seam::entity::component_surfaces_real
            rename ::hmtoolkit::seam::entity::snapshot_ids ::hmtoolkit::seam::entity::snapshot_ids_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::validation::created_surfaces_for_component ::hmtoolkit::seam::validation::created_surfaces_for_component_real
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {return [dict get $data $key]}
            proc ::hmtoolkit::seam::candidate::path_topology {args} {return [dict create kind PATH]}
            proc ::hmtoolkit::seam::naming::thickness_from_data {data} {return 1.2}
            proc ::hmtoolkit::seam::naming::get_or_create_component {thickness} {return {SEAM_T1.2_Surf 900}}
            proc ::hmtoolkit::seam::entity::component_surfaces {componentId} {return {40}}
            proc ::hmtoolkit::seam::entity::snapshot_ids {entityType} {return {1 2 50}}
            set ::create_t_marks {}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {
                lappend ::create_t_marks [list $entityType $markId $ids]
            }
            set ::created_surface_counter 49
            proc ::hmtoolkit::seam::validation::created_surfaces_for_component {before beforeAll componentId} {
                incr ::created_surface_counter
                return [list $::created_surface_counter]
            }
            set ::connect_surface_calls {}
            proc *connect_surfaces_11 {args} {lappend ::connect_surface_calls $args}
            set ::equivalence_calls {}
            proc ::hmtoolkit::seam::executor::equivalence_created_surfaces {created source target componentId before} {
                lappend ::equivalence_calls [list $created $source $target $componentId $before]
                return $created
            }
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::_create_t "
            "[dict create seam_lines {101} source_surfs {10} target_surfs {20 21} "
            "source_components {1} target_components {2}] T_LIST"
        )
        self.assertEqual(self.tcl.eval("llength $::connect_surface_calls"), "2")
        self.assertIn("surfs 2 20", self.tcl.eval("set ::create_t_marks"))
        self.assertIn("surfs 2 21", self.tcl.eval("set ::create_t_marks"))
        self.assertEqual(
            self.tcl.eval("set ::equivalence_calls"),
            "{50 10 20 900 40} {51 10 21 900 40}",
        )
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} created_surfs"), "50 51")

    def test_extend_processes_and_validates_every_target_independently(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::validation::require_ids ::hmtoolkit::seam::validation::require_ids_real
            rename ::hmtoolkit::seam::executor::surfaces_from_lines ::hmtoolkit::seam::executor::surfaces_from_lines_real
            rename ::hmtoolkit::seam::entity::surface_component ::hmtoolkit::seam::entity::surface_component_real
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {
                return [dict get $data $key]
            }
            proc ::hmtoolkit::seam::executor::surfaces_from_lines {lineIds} {return {10}}
            proc ::hmtoolkit::seam::entity::surface_component {surfaceId} {return 5}
            proc ::HWFlow::componentName {componentId} {return SOURCE_SEAM}
            set ::extend_target_calls {}
            proc ::hmtoolkit::seam::executor::extend_to_target {line source target sourceCompId sourceCompName} {
                lappend ::extend_target_calls $target
                return [list [expr {$target + 100}]]
            }
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::_extend_surface "
            "[dict create seam_lines {101} target_surfs {20 21}]"
        )
        self.assertEqual(self.tcl.eval("set ::extend_target_calls"), "20 21")
        self.assertEqual(
            self.tcl.eval(f"dict get {{{result}}} created_surfs"),
            "120 121",
        )

    def test_l_surface_captures_component_baseline_before_topology_validation(self):
        body = self.tcl.eval("info body ::hmtoolkit::seam::executor::_create_l_surface")
        baseline = (
            "set before [::hmtoolkit::seam::entity::component_surfaces "
            "[lindex $component 1]]"
        )
        self.assertIn(baseline, body)
        self.assertLess(body.index(baseline), body.index("equivalence_created_surfaces"))

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

    def test_shortcut_and_continuous_precise_contracts_are_wired(self):
        core = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        main = (MODULE_DIR / "main.tcl").read_text(encoding="utf-8")
        ui = (MODULE_DIR / "ui.tcl").read_text(encoding="utf-8")
        self.assertIn('shortcut_proc "::SeamSurf::runShortcut"', core)
        self.assertIn("invokeModule $target shortcut", core)
        self.assertIn("selector::capture_preselection", main)
        self.assertIn("runtime(context_data)", ui)
        self.assertIn("run_continuous $strategy", ui)

    def test_shortcut_opens_feature_window_without_starting_selection(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::open_panel ::hmtoolkit::seam::open_panel_real
            rename ::hmtoolkit::seam::ui::shortcut_selector_panel ::hmtoolkit::seam::ui::shortcut_selector_panel_real
            set ::shortcut_open_count 0
            proc ::hmtoolkit::seam::open_panel {} {
                incr ::shortcut_open_count
                return FEATURE_WINDOW
            }
            proc ::hmtoolkit::seam::ui::shortcut_selector_panel {} {
                error "shortcut must not start geometry selection"
            }
            """
        )
        self.assertEqual(self.tcl.eval("::hmtoolkit::seam::ui::run_shortcut"), "FEATURE_WINDOW")
        self.assertEqual(self.tcl.eval("set ::shortcut_open_count"), "1")

    def test_list_based_creation_strategies_default_to_line_path(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::selector::list_panel ::hmtoolkit::seam::selector::list_panel_real
            rename ::hmtoolkit::seam::selector::mark_panel ::hmtoolkit::seam::selector::mark_panel_real
            rename ::hmtoolkit::seam::selector::surfaces_for_lines ::hmtoolkit::seam::selector::surfaces_for_lines_real
            rename ::hmtoolkit::seam::selector::components_for_surfaces ::hmtoolkit::seam::selector::components_for_surfaces_real
            set ::list_panel_calls {}
            proc ::hmtoolkit::seam::selector::list_panel {mode listId prompt} {
                lappend ::list_panel_calls "$mode:$listId"
                return [dict create valid 1 ids [list [expr {100+$listId}]]]
            }
            proc ::hmtoolkit::seam::selector::surface_list_panel {listId prompt} {
                return [dict create valid 1 ids {20 21}]
            }
            proc ::hmtoolkit::seam::selector::mark_panel {entityType markId prompt args} {
                return [dict create valid 1 ids {20}]
            }
            proc ::hmtoolkit::seam::selector::surfaces_for_lines {lineIds} {return {30}}
            proc ::hmtoolkit::seam::selector::components_for_surfaces {surfIds} {return {40}}
            """
        )
        expected = {
            "T_LIST": "PATH:1",
            "L_LIST": "PATH:1",
            "CONNECT": "PATH:1 PATH:2",
            "PROJECT": "PATH:1",
        }
        for strategy, calls in expected.items():
            with self.subTest(strategy=strategy):
                self.tcl.eval("set ::list_panel_calls {}")
                result = self.tcl.eval(
                    f"::hmtoolkit::seam::selector::select_strategy_input {strategy}"
                )
                self.assertEqual(self.tcl.eval(f"dict get {{{result}}} valid"), "1")
                self.assertEqual(self.tcl.eval("set ::list_panel_calls"), calls)

    def test_l_list_collects_multiple_target_surfaces_from_a_surface_list(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::selector::list_panel ::hmtoolkit::seam::selector::list_panel_real
            rename ::hmtoolkit::seam::selector::mark_panel ::hmtoolkit::seam::selector::mark_panel_real
            rename ::hmtoolkit::seam::selector::surfaces_for_lines ::hmtoolkit::seam::selector::surfaces_for_lines_real
            rename ::hmtoolkit::seam::selector::components_for_surfaces ::hmtoolkit::seam::selector::components_for_surfaces_real
            set ::surface_list_calls 0
            set ::target_mark_calls 0
            proc ::hmtoolkit::seam::selector::list_panel {mode listId prompt} {
                return [dict create valid 1 ids {101 102}]
            }
            proc ::hmtoolkit::seam::selector::surface_list_panel {listId prompt} {
                incr ::surface_list_calls
                return [dict create valid 1 ids {201 202 203}]
            }
            proc ::hmtoolkit::seam::selector::mark_panel {entityType markId prompt args} {
                incr ::target_mark_calls
                return [dict create valid 1 ids {999}]
            }
            proc ::hmtoolkit::seam::selector::surfaces_for_lines {lineIds} {return {301}}
            proc ::hmtoolkit::seam::selector::components_for_surfaces {surfIds} {return $surfIds}
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::selector::select_strategy_input L_LIST"
        )
        self.assertEqual(self.tcl.eval("set ::surface_list_calls"), "1")
        self.assertEqual(self.tcl.eval("set ::target_mark_calls"), "0")
        self.assertEqual(
            self.tcl.eval(f"dict get {{{result}}} target_surfs"),
            "201 202 203",
        )
        self.assertEqual(
            self.tcl.eval(f"dict get {{{result}}} target_components"),
            "201 202 203",
        )

    def test_project_collects_multiple_target_surfaces_and_executes_them_together(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::selector::list_panel ::hmtoolkit::seam::selector::list_panel_real
            rename ::hmtoolkit::seam::selector::surface_list_panel ::hmtoolkit::seam::selector::surface_list_panel_real
            proc ::hmtoolkit::seam::selector::list_panel {mode listId prompt} {
                return [dict create valid 1 ids {101 102}]
            }
            proc ::hmtoolkit::seam::selector::surface_list_panel {listId prompt} {
                return [dict create valid 1 ids {201 202 203}]
            }
            """
        )
        selected = self.tcl.eval(
            "::hmtoolkit::seam::selector::select_strategy_input PROJECT"
        )
        self.assertEqual(
            self.tcl.eval(f"dict get {{{selected}}} target_surfs"),
            "201 202 203",
        )

        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::validation::require_ids ::hmtoolkit::seam::validation::require_ids_real
            rename ::hmtoolkit::seam::entity::snapshot_ids ::hmtoolkit::seam::entity::snapshot_ids_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::entity::diff_ids ::hmtoolkit::seam::entity::diff_ids_real
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {return [dict get $data $key]}
            set ::project_snapshot_count 0
            proc ::hmtoolkit::seam::entity::snapshot_ids {entityType} {
                incr ::project_snapshot_count
                return [list 1 2 [expr {300+$::project_snapshot_count}]]
            }
            set ::project_marks {}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {
                lappend ::project_marks [list $entityType $markId $ids]
            }
            proc ::hmtoolkit::seam::entity::diff_ids {before after} {return [list [lindex $after end]]}
            proc *surfacemarksplitwithlines {args} {incr ::project_split_called}
            set ::project_split_called 0
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::_split_surface "
            "[dict create seam_lines {101 102} target_surfs {201 202 203}] PROJECT"
        )
        self.assertEqual(self.tcl.eval("set ::project_split_called"), "3")
        self.assertIn("surfs 1 201", self.tcl.eval("set ::project_marks"))
        self.assertIn("surfs 1 202", self.tcl.eval("set ::project_marks"))
        self.assertIn("surfs 1 203", self.tcl.eval("set ::project_marks"))
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} success"), "1")

    def test_project_keeps_successful_in_place_splits_when_no_surface_id_is_added(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::validation::require_ids ::hmtoolkit::seam::validation::require_ids_real
            rename ::hmtoolkit::seam::entity::snapshot_ids ::hmtoolkit::seam::entity::snapshot_ids_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {
                return [dict get $data $key]
            }
            proc ::hmtoolkit::seam::entity::snapshot_ids {entityType} {return {20 21}}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {return [llength $ids]}
            set ::in_place_split_calls 0
            proc *surfacemarksplitwithlines {args} {incr ::in_place_split_calls}
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::_split_surface "
            "[dict create seam_lines {101} target_surfs {20 21}] PROJECT"
        )
        self.assertEqual(self.tcl.eval("set ::in_place_split_calls"), "2")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} success"), "1")
        self.assertEqual(
            self.tcl.eval(f"dict get {{{result}}} modified_surfs"),
            "20 21",
        )
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} created_surfs"), "")

    def test_l_surface_keeps_surviving_in_place_results_from_temp_components(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::entity::component_surfaces ::hmtoolkit::seam::entity::component_surfaces_real
            rename ::hmtoolkit::seam::entity::surface_component ::hmtoolkit::seam::entity::surface_component_real
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            proc ::hmtoolkit::seam::entity::component_surfaces {componentId} {
                switch -- $componentId {
                    91 {return {501 502}}
                    92 {return {503}}
                    default {return {}}
                }
            }
            proc ::hmtoolkit::seam::entity::surface_component {surfaceId} {
                switch -- $surfaceId {
                    501 - 502 {return 91}
                    503 {return 92}
                    900 {return 10}
                }
                return ""
            }
            proc ::hmtoolkit::seam::entity::exists {entityType id} {return 1}
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::lap_result_surfaces "
            "{{TMP_A 91} {TMP_B 92}} {900}"
        )
        self.assertEqual(result, "501 502 503")

    def test_l_surface_tracks_solids_that_native_boolean_and_trim_modify_in_place(self):
        self.tcl.eval(
            """
            set ::solid_component_mark ""
            proc *createmark {entityType markId selector componentName} {
                if {$entityType eq "solids" && $selector eq "by comp"} {
                    set ::solid_component_mark $componentName
                }
            }
            proc hm_getmark {entityType markId} {
                switch -- $::solid_component_mark {
                    TMP_A {return {701}}
                    TMP_B {return {702 703}}
                }
                return {}
            }
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::temp_component_solids "
            "{{TMP_A 91} {TMP_B 92}}"
        )
        self.assertEqual(result, "701 702 703")

    def test_replace_point_keeps_successful_in_place_vertex_projection(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::validation::require_ids ::hmtoolkit::seam::validation::require_ids_real
            rename ::hmtoolkit::seam::entity::snapshot_ids ::hmtoolkit::seam::entity::snapshot_ids_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {
                return [dict get $data $key]
            }
            proc ::hmtoolkit::seam::entity::snapshot_ids {entityType} {return {301}}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {return [llength $ids]}
            set ::project_point_calls 0
            set ::vertices_combine_calls 0
            proc *projectpointstoedges {args} {incr ::project_point_calls}
            proc *verticescombine {args} {incr ::vertices_combine_calls}
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::_replace_point "
            "[dict create points {301} seam_lines {401}]"
        )
        self.assertEqual(self.tcl.eval("set ::project_point_calls"), "1")
        self.assertEqual(self.tcl.eval("set ::vertices_combine_calls"), "0")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} success"), "1")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} modified_lines"), "401")

    def test_extend_keeps_source_surface_when_native_extension_is_in_place(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            rename ::hmtoolkit::seam::entity::surface_component ::hmtoolkit::seam::entity::surface_component_real
            proc ::hmtoolkit::seam::entity::exists {entityType id} {return 1}
            proc ::hmtoolkit::seam::entity::surface_component {surfaceId} {
                if {$surfaceId in {10 50}} {return 5}
                return 9
            }
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::extended_result_surfaces {10} {} 5"
        )
        self.assertEqual(result, "10")

    def test_extend_prefers_the_named_seam_surface_when_edge_has_multiple_owners(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::entity::surface_component ::hmtoolkit::seam::entity::surface_component_real
            proc ::hmtoolkit::seam::entity::surface_component {surfaceId} {
                if {$surfaceId == 50} {return 5}
                return 6
            }
            proc ::HWFlow::componentName {componentId} {
                if {$componentId == 5} {return SEAM_T1.2_Surf}
                return PART_T1.2_STEEL
            }
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::resolve_extend_source {10 50}"
        )
        self.assertEqual(result, "50")

    def test_extend_does_not_require_offset_guide_surface_to_be_coincident(self):
        body = self.tcl.eval("info body ::hmtoolkit::seam::executor::extend_to_target")
        self.assertNotIn("equivalence_extended_surfaces", body)

    def test_non_continuous_action_closes_window_and_reports_execution_failure(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::interactive::run ::hmtoolkit::seam::interactive::run_real
            rename ::hmtoolkit::seam::ui::dismiss_window ::hmtoolkit::seam::ui::dismiss_window_real
            rename ::hmtoolkit::seam::ui::set_status ::hmtoolkit::seam::ui::set_status_real
            set ::non_continuous_window_closes 0
            set ::reported_errors {}
            proc ::hmtoolkit::seam::ui::dismiss_window {} {incr ::non_continuous_window_closes}
            proc ::hmtoolkit::seam::ui::set_status {message} {}
            proc ::hmtoolkit::seam::interactive::run {strategy} {
                return [dict create success 0 cancelled 0 message "native $strategy failed"]
            }
            proc hm_errormessage {message} {lappend ::reported_errors $message}
            """
        )
        result = self.tcl.eval("::hmtoolkit::seam::ui::run_precise EXTEND")
        self.assertEqual(self.tcl.eval("set ::non_continuous_window_closes"), "1")
        self.assertEqual(self.tcl.eval("set ::reported_errors"), "{native EXTEND failed}")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} success"), "0")

    def test_continuous_action_reports_failure_before_next_selection(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::interactive::run ::hmtoolkit::seam::interactive::run_real
            rename ::hmtoolkit::seam::ui::dismiss_window ::hmtoolkit::seam::ui::dismiss_window_real
            rename ::hmtoolkit::seam::ui::set_status ::hmtoolkit::seam::ui::set_status_real
            set ::continuous_failure_calls 0
            set ::continuous_reported_errors {}
            proc ::hmtoolkit::seam::ui::dismiss_window {} {}
            proc ::hmtoolkit::seam::ui::set_status {message} {}
            proc hm_errormessage {message} {lappend ::continuous_reported_errors $message}
            proc ::hmtoolkit::seam::interactive::run {strategy} {
                incr ::continuous_failure_calls
                if {$::continuous_failure_calls == 1} {
                    return [dict create success 0 cancelled 0 message "first creation failed"]
                }
                return [dict create success 0 cancelled 1 message "Operation cancelled."]
            }
            """
        )
        self.tcl.eval("::hmtoolkit::seam::ui::run_continuous L_LIST")
        self.assertEqual(self.tcl.eval("set ::continuous_failure_calls"), "2")
        self.assertEqual(
            self.tcl.eval("set ::continuous_reported_errors"),
            "{first creation failed}",
        )

    def test_project_enters_continuous_mode_even_with_incoming_context(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::interactive::run ::hmtoolkit::seam::interactive::run_real
            rename ::hmtoolkit::seam::ui::analyze_context ::hmtoolkit::seam::ui::analyze_context_real
            set ::project_continuous_calls {}
            set ::hmtoolkit::seam::runtime(context_data) [dict create valid 1 source_surfs {1} target_surfs {2} source_components {3} target_components {4}]
            proc destroy {window} {}
            proc ::hmtoolkit::seam::ui::analyze_context {args} {error "PROJECT must enter continuous selection"}
            proc ::hmtoolkit::seam::interactive::run {strategy} {
                lappend ::project_continuous_calls $strategy
                return [dict create success 0 cancelled 1 message "Operation cancelled."]
            }
            """
        )
        result = self.tcl.eval("::hmtoolkit::seam::ui::run_precise PROJECT")
        self.assertEqual(self.tcl.eval("set ::project_continuous_calls"), "PROJECT")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} cancelled"), "1")

    def test_precise_creation_repeats_until_selection_is_cancelled(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::interactive::run ::hmtoolkit::seam::interactive::run_real
            rename ::hmtoolkit::seam::ui::analyze_context ::hmtoolkit::seam::ui::analyze_context_real
            set ::continuous_calls 0
            set ::continuous_window_closes {}
            set ::hmtoolkit::seam::runtime(context_data) [dict create valid 1 source_surfs {1} target_surfs {2} source_components {3} target_components {4}]
            proc destroy {window} {
                lappend ::continuous_window_closes "$window:$::hmtoolkit::seam::runtime(active_strategy)"
            }
            proc ::hmtoolkit::seam::ui::analyze_context {args} {
                error "precise creation must enter its selector instead of analyzing incoming context"
            }
            proc ::hmtoolkit::seam::interactive::run {strategy} {
                incr ::continuous_calls
                if {$::continuous_calls >= 3} {
                    return [dict create success 0 cancelled 1 message "Operation cancelled."]
                }
                return [dict create success 1 cancelled 0 message "Created $strategy"]
            }
            """
        )
        result = self.tcl.eval("::hmtoolkit::seam::ui::run_precise T_LIST")
        self.assertEqual(self.tcl.eval("set ::continuous_calls"), "3")
        self.assertEqual(
            self.tcl.eval("set ::continuous_window_closes"),
            ".geometry_seam:T_LIST",
        )
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} cancelled"), "1")
        self.assertEqual(self.tcl.eval("set ::hmtoolkit::seam::runtime(active_strategy)"), "")

    def test_escape_stops_active_creation_before_it_closes_the_window(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::ui::close ::hmtoolkit::seam::ui::close_real
            set ::close_calls 0
            proc ::hmtoolkit::seam::ui::close {} {incr ::close_calls}
            set ::hmtoolkit::seam::runtime(active_strategy) T_LIST
            ::hmtoolkit::seam::ui::handle_escape
            """
        )
        self.assertEqual(self.tcl.eval("set ::hmtoolkit::seam::runtime(active_strategy)"), "")
        self.assertEqual(self.tcl.eval("set ::close_calls"), "0")
        self.tcl.eval("::hmtoolkit::seam::ui::handle_escape")
        self.assertEqual(self.tcl.eval("set ::close_calls"), "1")

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

    def test_every_mutating_strategy_uses_the_shared_undo_transaction(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::transaction::run ::hmtoolkit::seam::transaction::run_real
            set ::undo_transactions {}
            proc ::hmtoolkit::seam::transaction::run {label scriptBody} {
                lappend ::undo_transactions $label
                return [dict create success 1 strategy TEST created_surfs {} created_components {} warnings {} message ok]
            }
            """
        )
        strategies = {
            "T_PATH",
            "T_LIST",
            "L_SURF",
            "L_LIST",
            "CONNECT",
            "PROJECT",
            "EXTEND",
            "COMBINE",
            "SPLIT",
            "REPLACE_POINT",
            "DISTRIBUTE_POINTS",
            "DELETE",
        }
        for strategy in strategies:
            with self.subTest(strategy=strategy):
                result = self.tcl.eval(
                    f"::hmtoolkit::seam::executor::dispatch {strategy} {{}}"
                )
                self.assertEqual(self.tcl.eval(f"dict get {{{result}}} success"), "1")
        self.assertEqual(
            int(self.tcl.eval("llength $::undo_transactions")),
            len(strategies),
        )


if __name__ == "__main__":
    unittest.main()
