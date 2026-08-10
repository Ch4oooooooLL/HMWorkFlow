import os
from pathlib import Path
import time
import tkinter
import unittest


# The Windows store Python on some machines transiently fails to read its
# bundled tcl/tcl8.6/init.tcl (files appear missing between processes). When a
# stable local copy exists (created once by the developer), point Tcl at it
# before any interpreter is constructed; CI and normal Python installs are
# unaffected because the path does not exist there.
_STABLE_TCL = Path(os.environ.get("LOCALAPPDATA", "")) / "hmworkflow_test_tcl" / "tcl" / "tcl8.6"
if _STABLE_TCL.joinpath("init.tcl").exists():
    os.environ["TCL_LIBRARY"] = str(_STABLE_TCL)


ROOT = Path(__file__).resolve().parents[3]
LOADER = ROOT / "modules" / "seam_surface.tcl"
MODULE_DIR = ROOT / "modules" / "seam_surface"


class GeometrySeamTclTests(unittest.TestCase):
    def setUp(self):
        # The Windows store Python on some machines transiently fails to read
        # its bundled tcl/tcl8.6/init.tcl when a fresh interpreter is created;
        # a bounded retry keeps the suite runnable there without hiding real
        # failures from the module under test.
        last_error = None
        for _attempt in range(6):
            try:
                self.tcl = tkinter.Tcl()
                self.tcl.eval(f"source {{{LOADER.as_posix()}}}")
                break
            except tkinter.TclError as error:
                last_error = error
                time.sleep(0.4)
        else:
            raise last_error

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

    def test_t_surface_selects_two_surface_groups_and_rejects_overlap(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::selector::mark_panel ::hmtoolkit::seam::selector::mark_panel_real
            rename ::hmtoolkit::seam::selector::components_for_surfaces ::hmtoolkit::seam::selector::components_for_surfaces_real
            set ::t_surface_panels {}
            proc ::hmtoolkit::seam::selector::mark_panel {entityType markId prompt args} {
                lappend ::t_surface_panels [list $entityType $markId]
                if {$markId == 1} {return [dict create valid 1 ids {10 11}]}
                return [dict create valid 1 ids {20 21}]
            }
            proc ::hmtoolkit::seam::selector::components_for_surfaces {surfIds} {
                return [lsort -integer -unique [lmap id $surfIds {expr {$id + 100}}]]
            }
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::selector::select_strategy_input T_PATH"
        )
        self.assertEqual(self.tcl.eval("set ::t_surface_panels"), "{surfs 1} {surfs 2}")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} valid"), "1")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} source_surfs"), "10 11")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} target_surfs"), "20 21")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} source_components"), "110 111")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} target_components"), "120 121")

        self.tcl.eval(
            """
            proc ::hmtoolkit::seam::selector::mark_panel {entityType markId prompt args} {
                if {$markId == 1} {return [dict create valid 1 ids {10 11}]}
                return [dict create valid 1 ids {10 21}]
            }
            """
        )
        overlapped = self.tcl.eval(
            "::hmtoolkit::seam::selector::select_strategy_input T_PATH"
        )
        self.assertEqual(self.tcl.eval(f"dict get {{{overlapped}}} valid"), "0")
        self.assertIn("reselect", self.tcl.eval(f"dict get {{{overlapped}}} message"))

        self.tcl.eval(
            """
            proc ::hmtoolkit::seam::selector::mark_panel {entityType markId prompt args} {
                return [dict create valid 0 cancelled 1 message "Operation cancelled."]
            }
            """
        )
        cancelled = self.tcl.eval(
            "::hmtoolkit::seam::selector::select_strategy_input T_PATH"
        )
        self.assertEqual(self.tcl.eval(f"dict get {{{cancelled}}} cancelled"), "1")

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
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            rename ::hmtoolkit::seam::entity::diff_ids ::hmtoolkit::seam::entity::diff_ids_real
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {return [dict get $data $key]}
            proc ::hmtoolkit::seam::entity::exists {entityType id} {return 1}
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

    def test_t_surface_uses_grouped_targets_and_keeps_mode1_results(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::validation::require_ids ::hmtoolkit::seam::validation::require_ids_real
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            rename ::hmtoolkit::seam::entity::snapshot_ids ::hmtoolkit::seam::entity::snapshot_ids_real
            rename ::hmtoolkit::seam::entity::component_surfaces ::hmtoolkit::seam::entity::component_surfaces_real
            rename ::hmtoolkit::seam::entity::surface_component ::hmtoolkit::seam::entity::surface_component_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::validation::created_surfaces_for_component ::hmtoolkit::seam::validation::created_surfaces_for_component_real
            rename ::hmtoolkit::seam::validation::created_surfaces_in_component ::hmtoolkit::seam::validation::created_surfaces_in_component_real
            rename ::hmtoolkit::seam::executor::equivalence_created_surfaces ::hmtoolkit::seam::executor::equivalence_created_surfaces_real
            rename ::hmtoolkit::seam::native::ensure_current_component ::hmtoolkit::seam::native::ensure_current_component_real
            set ::ts_state {10 20 21}
            set ::ts_seams {}
            set ::ts_calls 0
            set ::ts_marks {}
            set ::ts_connect_args {}
            set ::ts_equivalence_calls 0
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {return [dict get $data $key]}
            proc ::hmtoolkit::seam::naming::thickness_from_data {data} {return 8.0}
            proc ::hmtoolkit::seam::naming::get_or_create_component {thickness} {return {SEAM_T8_Surf 900}}
            proc ::hmtoolkit::seam::native::ensure_current_component {args} {}
            proc ::hmtoolkit::seam::entity::exists {entityType id} {expr {[lsearch -exact $::ts_state $id] >= 0}}
            proc ::hmtoolkit::seam::entity::snapshot_ids {entityType} {return $::ts_state}
            proc ::hmtoolkit::seam::entity::component_surfaces {componentId} {
                if {$componentId == 900} {return $::ts_seams}
                return {}
            }
            proc ::hmtoolkit::seam::entity::surface_component {surfaceId} {
                if {$surfaceId in {10 11}} {return 1}
                if {$surfaceId in {20 21}} {return 2}
                if {$surfaceId in {60 61}} {return 900}
                return ""
            }
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {
                lappend ::ts_marks [list $entityType $markId $ids]
            }
            proc ::hmtoolkit::seam::validation::created_surfaces_for_component {before beforeAll componentId} {
                return $::ts_seams
            }
            proc ::hmtoolkit::seam::validation::created_surfaces_in_component {before componentId} {return $::ts_seams}
            proc ::hmtoolkit::seam::executor::equivalence_created_surfaces {created source target component before} {
                incr ::ts_equivalence_calls
                return $created
            }
            proc *connect_surfaces_11 {args} {
                lappend ::ts_connect_args $args
                incr ::ts_calls
                set ::ts_state {10 20 21 60 61}
                set ::ts_seams {60 61}
            }
            proc *clearmark {args} {}
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::_create_t_surface "
            "[dict create source_surfs {10} target_surfs {20 21} "
            "source_components {1} target_components {2}]"
        )
        self.assertEqual(self.tcl.eval("set ::ts_calls"), "1")
        self.assertEqual(
            self.tcl.eval("lindex $::ts_connect_args 0"),
            self.tcl.eval(
                "list 1 2 1 [::hmtoolkit::seam::config::get t_surface_trim_mode] "
                "[::hmtoolkit::seam::config::get connect_extend_distance] "
                "[::hmtoolkit::seam::config::get connect_min_angle_to_target] "
                "[::hmtoolkit::seam::config::get connect_max_angle_edge_to_surf] "
                "1 0 2 [::hmtoolkit::seam::config::get connect_guide_angle] 59 0"
            ),
        )
        marks = self.tcl.eval("set ::ts_marks")
        self.assertIn("surfs 1 10", marks)
        self.assertIn("surfs 2 {20 21}", marks)
        self.assertEqual(self.tcl.eval("set ::ts_equivalence_calls"), "0")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} created_surfs"), "60 61")
        self.assertIn("Extended surface(s)", self.tcl.eval(f"dict get {{{result}}} message"))

    def test_t_list_runs_trim_then_surface_only_ruled_workflow(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::validation::require_ids ::hmtoolkit::seam::validation::require_ids_real
            rename ::hmtoolkit::seam::candidate::path_topology ::hmtoolkit::seam::candidate::path_topology_real
            rename ::hmtoolkit::seam::candidate::select_projected_trim_path ::hmtoolkit::seam::candidate::select_projected_trim_path_real
            rename ::hmtoolkit::seam::candidate::organize_ruled_surface_lines ::hmtoolkit::seam::candidate::organize_ruled_surface_lines_real
            rename ::hmtoolkit::seam::entity::snapshot_ids ::hmtoolkit::seam::entity::snapshot_ids_real
            rename ::hmtoolkit::seam::entity::component_surfaces ::hmtoolkit::seam::entity::component_surfaces_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::validation::created_surfaces_for_component ::hmtoolkit::seam::validation::created_surfaces_for_component_real
            rename ::hmtoolkit::seam::native::ensure_current_component ::hmtoolkit::seam::native::ensure_current_component_real
            set ::tl_events {}
            set ::tl_line_snapshots 0
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {return [dict get $data $key]}
            proc ::hmtoolkit::seam::candidate::path_topology {args} {
                return [dict create kind PATH branch_nodes 0]
            }
            proc ::hmtoolkit::seam::candidate::select_projected_trim_path {source created} {
                set ::tl_projected_candidates $created
                return {200 201}
            }
            proc ::hmtoolkit::seam::candidate::organize_ruled_surface_lines {first second} {
                return [dict create first_lines $first second_lines $second]
            }
            proc ::hmtoolkit::seam::naming::thickness_from_data {data} {return 8.0}
            proc ::hmtoolkit::seam::naming::get_or_create_component {thickness} {return {SEAM_T8_Surf 900}}
            proc ::hmtoolkit::seam::entity::snapshot_ids {entityType} {
                if {$entityType eq "lines"} {
                    incr ::tl_line_snapshots
                    if {$::tl_line_snapshots == 1} {return {100 101}}
                    return {100 101 200 201}
                }
                return {}
            }
            proc ::hmtoolkit::seam::entity::component_surfaces {componentId} {return {}}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {
                lappend ::tl_events [list mark $entityType $markId $ids]
            }
            proc ::hmtoolkit::seam::native::ensure_current_component {args} {}
            proc ::hmtoolkit::seam::validation::created_surfaces_for_component {args} {return {300}}
            proc *surfacemarksplitwithlines {args} {lappend ::tl_events [linsert $args 0 trim]}
            proc *surfacemode {mode} {lappend ::tl_events [list surfacemode $mode]}
            proc *createlist {entityType listId args} {lappend ::tl_events [list list $entityType $listId $args]}
            proc *linearsurfacebetweenlines {args} {lappend ::tl_events [linsert $args 0 ruled]}
            proc *connect_surfaces_11 {args} {error "T List must not use extend"}
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::_create_t_list_ruled "
            "[dict create seam_lines {100 101} target_surfs {20 21} "
            "source_surfs {10} source_components {1} target_components {2}]"
        )
        events = self.tcl.eval("set ::tl_events")
        self.assertIn("trim 1 2 0 13 0", events)
        self.assertIn("surfacemode 4", events)
        self.assertIn("ruled 1 1 2 2 1", events)
        self.assertLess(events.index("trim 1 2 0 13 0"), events.index("ruled 1 1 2 2 1"))
        self.assertEqual(self.tcl.eval("set ::tl_projected_candidates"), "200 201")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} created_surfs"), "300")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} projected_lines"), "200 201")

    def test_projected_trim_path_selection_prefers_matching_connected_group(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::candidate::line_points ::hmtoolkit::seam::candidate::line_points_real
            rename ::hmtoolkit::seam::candidate::line_length ::hmtoolkit::seam::candidate::line_length_real
            proc ::hmtoolkit::seam::candidate::line_points {lineId} {
                switch -- $lineId {
                    1 {return {{0 0 5} {5 0 5} {10 0 5}}}
                    10 {return {{0 0 0} {2.5 0 0} {5 0 0}}}
                    11 {return {{5 0 0} {7.5 0 0} {10 0 0}}}
                    20 {return {{0 0 100} {5 0 100} {10 0 100}}}
                }
            }
            proc ::hmtoolkit::seam::candidate::line_length {lineId} {
                if {$lineId in {10 11}} {return 5.0}
                return 10.0
            }
            proc hm_findclosestpointonline {x y z lineId} {
                switch -- $lineId {
                    1 {set lineZ 5.0}
                    10 - 11 {set lineZ 0.0}
                    20 {set lineZ 100.0}
                }
                return [list 0 0 $lineZ [expr {abs($z-$lineZ)}]]
            }
            """
        )
        self.assertEqual(
            self.tcl.eval("::hmtoolkit::seam::candidate::select_projected_trim_path {1} {10 11 20}"),
            "10 11",
        )

    def test_project_keeps_successful_in_place_splits_when_no_surface_id_is_added(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::validation::require_ids ::hmtoolkit::seam::validation::require_ids_real
            rename ::hmtoolkit::seam::entity::snapshot_ids ::hmtoolkit::seam::entity::snapshot_ids_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {
                return [dict get $data $key]
            }
            proc ::hmtoolkit::seam::entity::exists {entityType id} {return 1}
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

    def test_project_fails_when_native_split_is_a_no_op(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::validation::require_ids ::hmtoolkit::seam::validation::require_ids_real
            rename ::hmtoolkit::seam::entity::snapshot_ids ::hmtoolkit::seam::entity::snapshot_ids_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            rename ::hmtoolkit::seam::entity::surface_lines ::hmtoolkit::seam::entity::surface_lines_real
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {
                return [dict get $data $key]
            }
            proc ::hmtoolkit::seam::entity::exists {entityType id} {return 1}
            proc ::hmtoolkit::seam::entity::snapshot_ids {entityType} {return {20 21}}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {return [llength $ids]}
            proc ::hmtoolkit::seam::entity::surface_lines {surfaceIds} {return {500 501}}
            set ::noop_split_calls 0
            proc *surfacemarksplitwithlines {args} {incr ::noop_split_calls}
            """
        )
        with self.assertRaisesRegex(
            tkinter.TclError,
            "did not change the selected surfaces",
        ):
            self.tcl.eval(
                "::hmtoolkit::seam::executor::_split_surface "
                "[dict create seam_lines {101} target_surfs {20 21}] PROJECT"
            )

    def test_distribute_points_fails_when_nothing_was_created(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::validation::require_ids ::hmtoolkit::seam::validation::require_ids_real
            rename ::hmtoolkit::seam::entity::snapshot_ids ::hmtoolkit::seam::entity::snapshot_ids_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::entity::diff_ids ::hmtoolkit::seam::entity::diff_ids_real
            proc ::hmtoolkit::seam::validation::require_ids {data key entityType args} {
                return [dict get $data $key]
            }
            proc ::hmtoolkit::seam::candidate::line_length {lineId} {return 30.0}
            proc ::hmtoolkit::seam::entity::snapshot_ids {entityType} {return {1 2}}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {return [llength $ids]}
            proc ::hmtoolkit::seam::entity::diff_ids {before after} {return {}}
            proc *edgesmarkaddpoints {args} {
                error "undocumented command failed on this profile"
            }
            """
        )
        with self.assertRaisesRegex(
            tkinter.TclError,
            "No distributed points were created",
        ):
            self.tcl.eval(
                "::hmtoolkit::seam::executor::_distribute_points "
                "[dict create seam_lines {101 102}]"
            )

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
            rename ::hmtoolkit::seam::ui::show ::hmtoolkit::seam::ui::show_real
            set ::non_continuous_window_closes 0
            set ::non_continuous_reshows 0
            set ::reported_errors {}
            proc ::hmtoolkit::seam::ui::dismiss_window {} {incr ::non_continuous_window_closes}
            proc ::hmtoolkit::seam::ui::show {args} {incr ::non_continuous_reshows}
            proc ::hmtoolkit::seam::ui::set_status {message} {}
            proc ::hmtoolkit::seam::interactive::run {strategy} {
                return [dict create success 0 cancelled 0 message "native $strategy failed"]
            }
            proc hm_errormessage {message} {lappend ::reported_errors $message}
            """
        )
        result = self.tcl.eval("::hmtoolkit::seam::ui::run_precise EXTEND")
        self.assertEqual(self.tcl.eval("set ::non_continuous_window_closes"), "1")
        self.assertEqual(self.tcl.eval("set ::non_continuous_reshows"), "1")
        self.assertEqual(self.tcl.eval("set ::reported_errors"), "{native EXTEND failed}")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} success"), "0")

    def test_continuous_action_reports_failure_before_next_selection(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::interactive::run ::hmtoolkit::seam::interactive::run_real
            rename ::hmtoolkit::seam::ui::dismiss_window ::hmtoolkit::seam::ui::dismiss_window_real
            rename ::hmtoolkit::seam::ui::set_status ::hmtoolkit::seam::ui::set_status_real
            rename ::hmtoolkit::seam::ui::show ::hmtoolkit::seam::ui::show_real
            set ::continuous_failure_calls 0
            set ::continuous_reported_errors {}
            proc ::hmtoolkit::seam::ui::dismiss_window {} {}
            proc ::hmtoolkit::seam::ui::show {args} {}
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
            rename ::hmtoolkit::seam::ui::show ::hmtoolkit::seam::ui::show_real
            set ::project_continuous_calls {}
            proc destroy {window} {}
            proc ::hmtoolkit::seam::ui::show {args} {}
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
            rename ::hmtoolkit::seam::ui::show ::hmtoolkit::seam::ui::show_real
            set ::continuous_calls 0
            set ::continuous_window_closes {}
            proc destroy {window} {
                lappend ::continuous_window_closes "$window:$::hmtoolkit::seam::runtime(active_strategy)"
            }
            proc ::hmtoolkit::seam::ui::show {args} {}
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

    # ------------------------------------------------------------------
    # 2026-08-07 audit follow-up: API contract, native wrapper and
    # mark/current-component ownership tests
    # ------------------------------------------------------------------

    def test_native_compat_layer_is_loaded(self):
        self.assertEqual(
            self.tcl.eval("llength [info commands ::hmtoolkit::seam::native::set_current_component_checked]"),
            "1",
        )
        self.assertEqual(
            self.tcl.eval("llength [info commands ::hmtoolkit::seam::native::undocumented::trim_solids_by_surfaces]"),
            "1",
        )

    def test_extend_wrapper_uses_documented_offset_and_connect_arguments(self):
        # Dual-version probe evidence (2026-08-07, local 2019.0.0.70 and
        # 2022.0.0.33): *offset_surfaces_and_modify parses
        # entity_type mark_id surf_mark_id line_mark offset_type offset with
        # the signed distance LAST. The old "recorded" layout consumed the
        # configured distance as an ignored flag and hard-coded a +2 offset
        # on both builds; the documented layout is the route used here. This
        # test exercises the real extend_to_target body, not a mocked stub.
        self.tcl.eval(
            """
            set ::hmtoolkit::seam::runtime(active_temp_token) TOKEN
            rename ::hmtoolkit::seam::temp::create_component ::hmtoolkit::seam::temp::create_component_real
            rename ::hmtoolkit::seam::entity::mark ::hmtoolkit::seam::entity::mark_real
            rename ::hmtoolkit::seam::entity::exists ::hmtoolkit::seam::entity::exists_real
            rename ::hmtoolkit::seam::entity::surface_component ::hmtoolkit::seam::entity::surface_component_real
            rename ::hmtoolkit::seam::validation::surface_ids ::hmtoolkit::seam::validation::surface_ids_real
            proc ::hmtoolkit::seam::temp::create_component {token} {return {TMP_A 91}}
            proc ::hmtoolkit::seam::native::ensure_current_component {name id} {return $id}
            set ::extend_marks {}
            proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {
                lappend ::extend_marks [list $entityType $markId $ids]
                return [llength $ids]
            }
            set ::duplicate_calls {}
            proc *duplicatemark {args} {lappend ::duplicate_calls $args}
            proc ::hmtoolkit::seam::native::mark_by_component_checked {entityType markId compName} {return {1001}}
            set ::offset_calls {}
            proc *offset_surfaces_and_modify {args} {lappend ::offset_calls $args}
            set ::extend_snapshots 0
            proc ::hmtoolkit::seam::entity::snapshot_ids {entityType args} {
                incr ::extend_snapshots
                if {$::extend_snapshots == 1} {return {1 2 3}}
                return {1 2 3 60}
            }
            set ::connect_calls {}
            proc *connect_surfaces_11 {args} {lappend ::connect_calls $args}
            set ::move_calls {}
            proc *movemark {args} {lappend ::move_calls $args}
            proc ::hmtoolkit::seam::entity::exists {entityType id} {return 1}
            proc ::hmtoolkit::seam::entity::surface_component {surfaceId} {
                if {$surfaceId == 10} {return 5}
                return 9
            }
            proc ::hmtoolkit::seam::validation::surface_ids {ids componentId} {return 1}
            """
        )
        result = self.tcl.eval(
            "::hmtoolkit::seam::executor::extend_to_target 101 {10} {20} 5 SOURCE_SEAM"
        )
        self.assertEqual(result, "10")
        self.assertEqual(
            self.tcl.eval("lindex $::offset_calls 0"),
            "surfaces 2 0 1 2 -12.0",
        )
        self.assertEqual(
            self.tcl.eval("lindex $::connect_calls 0"),
            "1 1 3 2 0 15 30 1 0 2 30 3 0",
        )
        # Source and offset guides share mark 1; the target is marked in
        # mark 2 for the duplicate/offset stage.
        marks = self.tcl.eval("set ::extend_marks")
        self.assertIn("surfs 2 20", marks)
        self.assertIn("surfs 2 1001", marks)
        self.assertIn("surfs 1 {10 1001}", marks)
        self.assertEqual(self.tcl.eval("lindex $::duplicate_calls 0"), "surfs 2 1")
        self.assertEqual(self.tcl.eval("lindex $::move_calls 0"), "surfs 1 SOURCE_SEAM")

    def test_parameters_panel_covers_only_baseline_configurable_items(self):
        ui = (MODULE_DIR / "ui.tcl").read_text(encoding="utf-8")
        config = (MODULE_DIR / "config.tcl").read_text(encoding="utf-8")
        for key in (
            "endpoint_merge_tolerance",
            "distance_tolerance",
            "stitch_tolerance",
            "cleanup_tolerance",
            "area_tolerance",
            "volume_tolerance",
            "min_seam_length",
            "point_spacing",
            "geometry_offset_distance",
            "extend_offset_distance",
            "connect_extend_distance",
            "connect_min_angle_to_target",
            "connect_max_angle_edge_to_surf",
            "connect_guide_angle",
            "lap_connect_distance",
            "thickness_override",
        ):
            self.assertIn(key, config)
            self.assertIn(key, ui)
        # The 2022.3-only knobs must not be offered on the 2019/2022.2 panel.
        for removed in (
            "connect_extend_distance_auto",
            "connect_extend_distance_factor",
            "replace_point_projection_distance",
            "extend_offset_type",
            "extend_connect_trim_mode",
            "use_public_query_apis",
        ):
            self.assertNotIn(removed, ui)
        for key in ("lap_boolean_opcode", "diagnostic_preserve_failed_geometry",
                    "t_surface_trim_mode", "topology_connection_required",
                    "private_history_api"):
            self.assertIn(key, config)
            self.assertIn(key, ui)
        self.assertIn("8=union", ui.lower())
        self.assertIn("14=intersect", ui.lower())

    def test_extend_source_file_keeps_the_2019_baseline_arguments(self):
        executor = (MODULE_DIR / "executor.tcl").read_text(encoding="utf-8")
        # EXTEND keeps the dual-version mode-3 route, while the T action uses
        # the separately probed surface-to-surface extend route.
        self.assertIn("*offset_surfaces_and_modify surfaces 2 0 1 2", executor)
        self.assertIn("*connect_surfaces_11 1 1 3 2", executor)
        self.assertIn("*connect_surfaces_11 1 2 1 $trimMode $distance", executor)
        self.assertNotIn("_create_t_list_project_ruled", executor)
        self.assertIn("_create_t_list_ruled", executor)
        self.assertIn("_create_t_surface", executor)

    def test_diagnose_module_is_loaded_and_has_a_report_entry(self):
        self.assertEqual(
            self.tcl.eval("llength [info commands ::hmtoolkit::seam::diagnose::run]"),
            "1",
        )
        self.assertEqual(
            self.tcl.eval("llength [info commands ::hmtoolkit::seam::ui::run_diagnose]"),
            "1",
        )
        loader = (MODULE_DIR / ".." / "seam_surface.tcl").read_text(encoding="utf-8")
        self.assertIn("diagnose.tcl", loader)
        report = self.tcl.eval("::hmtoolkit::seam::diagnose::run")
        self.assertIn("GEOMETRY SEAM DIAGNOSTIC", report)
        self.assertIn("HyperMesh:", report)
        # The read-only probe list must cover the executor's native commands.
        for command in ("*connect_surfaces_11", "*linearsurfacebetweenlines",
                        "*surfacemarksplitwithlines", "*offset_surfaces_and_modify",
                        "*boolean_merge_solids", "*edgesmarkaddpoints",
                        "*projectpointstoedges", "hm_getmark", "hm_getvalue"):
            self.assertIn(command, report)

    def test_diagnose_probe_row_reports_missing_ok_and_exists(self):
        self.tcl.eval(
            """
            rename ::hmtoolkit::seam::diagnose::exists ::hmtoolkit::seam::diagnose::exists_real
            proc ::hmtoolkit::seam::diagnose::exists {name} {
                if {$name eq "hm_present_query"} {return 1}
                if {$name eq "hm_failing_query"} {return 1}
                if {$name eq "*destructive_cmd"} {return 1}
                return 0
            }
            proc hm_present_query {args} {return {1 2 3}}
            proc hm_failing_query {args} {error "bad arguments"}
            proc *destructive_cmd {args} {}
            """
        )
        ok_row = self.tcl.eval(
            "::hmtoolkit::seam::diagnose::probe_row hm_present_query {} probe"
        )
        self.assertIn("OK", ok_row)
        self.assertIn("returned:", ok_row)
        err_row = self.tcl.eval(
            "::hmtoolkit::seam::diagnose::probe_row hm_failing_query {} probe"
        )
        self.assertIn("ERR", err_row)
        self.assertIn("probe error", err_row)
        exist_row = self.tcl.eval(
            "::hmtoolkit::seam::diagnose::probe_row *destructive_cmd {} exists"
        )
        self.assertIn("EXIST", exist_row)
        missing_row = self.tcl.eval(
            "::hmtoolkit::seam::diagnose::probe_row *ghost_cmd {} exists"
        )
        self.assertIn("MISS", missing_row)
        self.assertIn("command not found", missing_row)


if __name__ == "__main__":
    unittest.main()
