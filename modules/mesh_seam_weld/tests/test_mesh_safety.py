import unittest
from pathlib import Path
import tkinter

ROOT = Path(__file__).resolve().parents[3]


class MeshSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tcl = tkinter.Tcl()
        self.tcl.call('source', str(ROOT / 'modules/mesh_seam_weld.tcl'))
        self.tcl.eval('''
set xyz {1 {0 0 0} 2 {2 0 0} 3 {2 -2 0} 4 {0 -2 0}
         5 {0 2 0} 6 {2 2 0} 11 {0 0 1} 12 {2 0 1} 13 {2 0 3} 14 {0 0 3}}
set conn {100 {4 3 2 1} 101 {1 2 6 5} 200 {11 12 13 14}}
set comp {100 10 101 10 200 20 300 30}
set compNames {10 PANEL_A 20 PANEL_B}
proc ::HybridCore::log {level message} {lappend ::logLines $level $message}
proc ::HWFlow::componentName {compId} {
    if {[dict exists $::compNames $compId]} {return [dict get $::compNames $compId]}
    return "BASE_$compId"
}
proc ::MeshSeamWeld::clearLocalTopologyCaches args {}
proc ::MeshSeamWeld::nodeXYZ {id} {dict get $::xyz $id}
proc ::HybridCore::readNodeCoordinatesBulk {ids args} {
    set result {}; foreach id $ids {dict set result $id [dict get $::xyz $id]}; return $result
}
proc ::MeshSeamWeld::readShellElementConnectivityBulk {ids args} {
    set result {}; foreach id $ids {if {[dict exists $::conn $id]} {dict set result $id [dict get $::conn $id]}}; return $result
}
proc ::MeshSeamWeld::adjacentElementsForNodes {nodes} {return {100 101 200}}
proc ::MeshSeamWeld::elemComponentId {id} {dict get $::comp $id}
proc ::MeshSeamWeld::componentElementIds {comp} {
    set result {}; dict for {id ids} $::conn {if {[dict get $::comp $id] == $comp} {lappend result $id}}; return $result
}
set before [::MeshSeamWeld::structuralMeshSnapshot {11 12} {100 101}]
dict set conn 300 {1 2 12 11}
''')

    def validate(self):
        return self.tcl.eval('::MeshSeamWeld::validateStructuralMesh $before {300} {11 12} 0')

    def test_valid_t_seam_keeps_both_structural_faces(self):
        self.assertEqual('1', self.validate())

    def test_missing_base_face_rejected(self):
        self.tcl.eval('dict unset conn 100')
        with self.assertRaisesRegex(tkinter.TclError, '(boundary changed|area changed)'):
            self.validate()

    def test_duplicate_base_face_rejected(self):
        self.tcl.eval('dict set conn 102 {1 2 3 4}; dict set comp 102 10')
        with self.assertRaisesRegex(tkinter.TclError, 'Duplicate structural'):
            self.validate()

    def test_moved_web_node_is_warned_when_result_topology_is_valid(self):
        self.tcl.eval('dict set xyz 11 {0 0 0.4}')
        self.assertEqual('1', self.validate())
        self.assertIn('diagnostic tolerance', self.tcl.eval('join $::logLines " "'))

    def test_duplicate_weld_on_base_rejected(self):
        self.tcl.eval('dict set conn 300 {1 2 6 5}')
        with self.assertRaisesRegex(tkinter.TclError, 'Duplicate structural shell'):
            self.validate()

    def test_coincident_disconnected_target_rail_rejected(self):
        self.tcl.eval('dict set xyz 21 {0 0 0}; dict set xyz 22 {2 0 0}; dict set conn 300 {21 22 12 11}')
        with self.assertRaisesRegex(tkinter.TclError, 'disconnected'):
            self.validate()

    def test_free_boundary_may_reuse_same_coordinate_with_new_id(self):
        self.tcl.eval('dict set xyz 21 {0 -2 0}; dict set conn 100 {21 3 2 1}')
        self.assertEqual('1', self.validate())

    def test_shared_attachment_can_be_renumbered_in_place(self):
        self.tcl.eval('dict lappend before protected_nodes 4; dict set xyz 21 {0 -2 0}; dict set conn 100 {21 3 2 1}')
        self.assertEqual('1', self.validate())

    def test_disappeared_attachment_without_exact_replacement_is_warned(self):
        # A node from the snapshot's outer incidence halo can disappear even
        # though it is not part of the surviving local boundary.  This is the
        # field failure reported for node 196345.
        self.tcl.eval('dict set before coordinates 99 {8 8 0}; dict lappend before protected_nodes 99')
        self.assertEqual('1', self.validate())
        self.assertIn('replaced and smoothed', self.tcl.eval('join $::logLines " "'))

    def test_local_structural_boundary_retessellation_is_warned(self):
        # Replacing an old boundary node with a smoothed node changes the old
        # edge chain but leaves a usable local face and only modest area drift.
        # This reproduces the field error for target node 31118.
        self.tcl.eval('dict set xyz 21 {0 -1.5 0}; dict set conn 100 {21 3 2 1}')
        self.assertEqual('1', self.validate())
        self.assertIn('boundary was retessellated', self.tcl.eval('join $::logLines " "'))

    def test_strict_mode_still_rejects_boundary_retessellation(self):
        self.tcl.eval('set ::MeshSeamWeld::cfg(strict_patch_boundary_check) 1; dict set xyz 21 {0 -1.5 0}; dict set conn 100 {21 3 2 1}')
        with self.assertRaisesRegex(tkinter.TclError, 'Structural boundary changed'):
            self.validate()

    def test_source_node_can_be_renumbered_in_place_by_native_remesh(self):
        self.tcl.eval('''
dict set xyz 21 {0 0 1}
dict unset xyz 11
dict set conn 200 {21 12 13 14}
dict set conn 300 {1 2 12 21}
''')
        self.assertEqual('1', self.validate())
        self.assertIn('renumbered in place', self.tcl.eval('join $::logLines " "'))

    def test_geometric_duplicate_with_different_node_ids_is_rejected(self):
        self.tcl.eval('''
dict set xyz 21 {0 0 0}; dict set xyz 22 {2 0 0}
dict set xyz 23 {2 2 0}; dict set xyz 24 {0 2 0}
dict set conn 300 {21 22 23 24}
''')
        with self.assertRaisesRegex(tkinter.TclError, 'Coincident duplicate'):
            self.validate()

    def test_replacement_ids_can_be_reused_without_false_baseline_exemption(self):
        self.tcl.eval('dict set conn 100 {1 3 2 4}')
        with self.assertRaises(tkinter.TclError):
            self.validate()

    def test_geometry_rejects_destroyed_shells(self):
        # Only a shell without usable geometry fails the weld: a self-
        # intersecting boundary (bow-tie), a zero-area shell, coincident nodes.
        for points in (
            ((0, 0, 0), (2, 2, 0), (0, 2, 0), (2, 0, 0)),
            ((0, 0, 0), (4, 4, 0), (0, 4, 0), (1, 0.2, 0)),
            ((0, 0, 0), (5, 0, 0), (10, 0, 0)),
            ((0, 0, 0), (1, 0, 0), (2, 0, 0), (3, 0, 0)),
            ((0, 0, 0), (1, 0, 0), (1, 1, 0), (1, 0, 0)),
        ):
            with self.subTest(points=points):
                coords = tuple(v for pair in enumerate(points, 1) for v in pair)
                nodes = tuple(range(1, len(points) + 1))
                with self.assertRaises(tkinter.TclError):
                    self.tcl.call('::MeshSeamWeld::shellGeometryAudit', nodes, coords)

    def test_geometry_keeps_distorted_but_usable_shells(self):
        # A constrained rail remesh legitimately closes needles, slivers, high
        # aspect ratios, concave corners and warps; HyperMesh's own Create Patch
        # produces exactly these shells by hand without complaint (2026-09-10
        # field repro), so they are reported, never fatal.
        for points in (
            ((0, 0, 0), (10, 0, 0), (10, 0.09, 0)),               # 1-degree needle
            ((0, 0, 0), (10, 0, 0), (10, 0.02, 0)),                # thin sliver
            ((0, 0, 0), (2, 0, 0), (2, 0.001, 0), (0, 0.001, 0)),  # aspect 2000
            ((0, 0, 0), (2, 0, 0), (0.4, 0.4, 0), (0, 2, 0)),      # concave corner
            ((0, 0, 0), (2, 0, 0), (2, 2, 4), (0, 2, 0)),          # heavily warped
            ((0, 0, 0), (5, 0, 0), (10, 0.001, 0), (5, 6, 0)),     # 179-degree corner
        ):
            with self.subTest(points=points):
                coords = tuple(v for pair in enumerate(points, 1) for v in pair)
                nodes = tuple(range(1, len(points) + 1))
                self.tcl.eval('set ::MeshSeamWeld::shellGeometryWarnings 0')
                self.tcl.call('::MeshSeamWeld::shellGeometryAudit', nodes, coords)
                self.assertEqual('1', self.tcl.eval('set ::MeshSeamWeld::shellGeometryWarnings'))

    def test_needle_weld_shells_are_kept_and_reported(self):
        # 2026-09-10 field report, reproduced on HyperMesh 2019: the patch has to
        # reproduce a fixed source rail feature, so its new shells can be
        # needles.  The weld must survive; the distortion is reported as a
        # warning instead of failing the path.
        self.tcl.eval('''
dict set xyz 31 {0.001 0 0}
dict set conn 300 {1 31 12 11}
''')
        self.assertEqual('1', self.validate())
        self.assertEqual('1', self.tcl.eval('expr {[llength $::logLines] > 0}'))
        self.assertIn('distorted but usable', self.tcl.eval('join $::logLines " "').lower())

    def test_bowtie_weld_shell_is_still_rejected(self):
        # A self-intersecting new weld shell is destroyed geometry and the path
        # must fail, even though the surrounding T is intact.
        self.tcl.eval('''
dict set xyz 31 {0 0 0}; dict set xyz 32 {10 10 0}
dict set xyz 33 {0 10 0}; dict set xyz 34 {10 0 0}
dict set conn 300 {31 32 33 34}
''')
        with self.assertRaisesRegex(tkinter.TclError, 'Self-intersecting'):
            self.validate()

    def test_valid_existing_weld_rebuild_is_warned_and_kept(self):
        # HM's native remesh_layers can rebuild a neighbouring SEAM_* element
        # even when it was excluded from the input mark.  Replacing its ID with
        # an equivalent shell is not structural damage and must not block the
        # requested weld; the full topology validation below remains decisive.
        self.tcl.eval('set ::compNames {10 PANEL_A 20 SEAM_T2}')
        self.tcl.eval('dict unset conn 200')
        self.tcl.eval('dict set conn 201 {11 12 13 14}; dict set comp 201 20')
        # The real output-component delta cannot distinguish the replacement
        # 201 from this path's new shell 300; both arrive as weldElems.
        self.assertEqual(
            '1', self.tcl.eval(
                '::MeshSeamWeld::validateStructuralMesh $before {201 300} {11 12} 0'))
        self.assertIn('continuing with topology validation',
                      self.tcl.eval('join $::logLines " "'))
        self.assertEqual(
            0, self.tcl.call(
                '::MeshSeamWeld::weldFailureIsStructuralDamage',
                '[MSW_STAGE:AUTOMESH] Existing weld mesh was modified by this path: weld component 20 lost element 200.'))

    def test_existing_weld_connectivity_change_reaches_geometry_validation(self):
        self.tcl.eval('set ::compNames {10 PANEL_A 20 SEAM_T2}')
        self.tcl.eval('dict set conn 200 {11 12 14 13}')
        with self.assertRaisesRegex(
                tkinter.TclError,
                '(Structural boundary changed|Self-intersecting|zero usable area)'):
            self.validate()

    def test_enabling_weld_break_allows_existing_weld_remesh(self):
        self.tcl.eval('set ::compNames {10 PANEL_A 20 SEAM_T2}')
        self.tcl.eval('set ::MeshSeamWeld::cfg(allow_break_existing_weld) 1')
        self.tcl.eval('dict unset conn 200')
        self.tcl.eval('dict set conn 201 {11 12 13 14}; dict set comp 201 20')
        self.assertEqual('1', self.validate())

    def test_valid_subdivided_end_caps_are_allowed(self):
        self.tcl.eval('::MeshSeamWeld::validateWeldAttachment {{1 2} {2 21} {21 12} {12 11} {11 22} {22 1}} {{1 2} 1 {11 12} 1} {11 12} 0')

    def test_failure_restores_entire_structural_state_in_transaction(self):
        self.tcl.eval('''
set savedConn $conn; set savedXYZ $xyz
proc *sethistoryrecord args {set ::historyEnabled 1}
proc *startnotehistorystate args {
    if {![info exists ::historyEnabled]} {error "history recorder was not enabled"}
    set ::savedConn $::conn; set ::savedXYZ $::xyz
}
proc *endnotehistorystate args {}
proc *undohistorystate args {set ::conn $::savedConn; set ::xyz $::savedXYZ}
proc ::MeshSeamWeld::processWeldPath args {
    dict unset ::conn 100; dict set ::xyz 11 {99 99 99}
    return -code error -errorcode {MESH_SEAM_WELD AUTOMESH KEEP_IMPRINT} {[MSW_STAGE:AUTOMESH] broken mesh}
}
proc ::MeshSeamWeld::clearTransientSelections args {}
proc ::MeshSeamWeld::invalidateTargetCaches args {}
set result [::MeshSeamWeld::processWeldPathIsolated {11 12} {10} 0 0 1 1 {20} {} {1 0 1} {100 101} 0]
''')
        self.assertEqual('0', self.tcl.eval('dict get $result ok'))
        self.assertEqual('1', self.tcl.eval('dict get $result rollback_ok'))
        self.assertEqual('1', self.tcl.eval('expr {$conn eq $savedConn && $xyz eq $savedXYZ}'))

    def test_noop_native_undo_is_not_reported_as_successful_rollback(self):
        self.tcl.eval('''
proc *sethistoryrecord args {}
proc *startnotehistorystate args {}
proc *endnotehistorystate args {}
proc *undohistorystate args {}
proc ::MeshSeamWeld::processWeldPath args {
    set ::MeshSeamWeld::activeStructuralSnapshot $::before
    dict unset ::conn 100
    error {[MSW_STAGE:AUTOMESH] damage}
}
proc ::MeshSeamWeld::clearTransientSelections args {}
proc ::MeshSeamWeld::invalidateTargetCaches args {}
set result [::MeshSeamWeld::processWeldPathIsolated {11 12} {10} 0 0 1 1 {20} {} {1 0 1} {100 101} 0]
''')
        self.assertEqual('0', self.tcl.eval('dict get $result rollback_ok'))
        self.assertIn('rollback verification failed', self.tcl.eval('dict get $result error'))

    def test_seed_batch_stops_after_unverified_rollback(self):
        self.tcl.eval('''
set calls 0
proc ::MeshSeamWeld::prepareCurrentTargetPatch args {return {target_components 10 target_elements {100 101}}}
proc ::MeshSeamWeld::processWeldPathIsolated args {
    incr ::calls; return {ok 0 rollback_ok 0 error broken}
}
set jobs {}
foreach id {A B C} {
    lappend jobs [dict create candidate_id $id source_component_id 20 source_node_ids {11 12} target_component_ids 10 closed_loop 0]
}
set result [::MeshSeamWeld::executeSeedJobs $jobs]
''')
        self.assertEqual('1', self.tcl.eval('set calls'))
        self.assertEqual('3', self.tcl.eval('dict get $result failed'))

    def test_seed_batch_honors_cancel_before_starting_next_weld(self):
        self.tcl.eval('''
set calls 0
proc ::MeshSeamWeld::prepareCurrentTargetPatch args {incr ::calls; return {target_components 10 target_elements {100 101}}}
rename ::HWFlow::progressCancelled ::HWFlow::progressCancelledOriginal
proc ::HWFlow::progressCancelled {} {return 1}
set jobs {}
foreach id {A B C} {
    lappend jobs [dict create candidate_id $id source_component_id 20 source_node_ids {11 12} target_component_ids 10 closed_loop 0]
}
set result [::MeshSeamWeld::executeSeedJobs $jobs 1 2]
''')
        self.assertEqual('0', self.tcl.eval('set calls'))
        self.assertEqual('1', self.tcl.eval('dict get $result cancelled'))
        self.assertEqual('3', self.tcl.eval('dict get $result failed'))

    def test_seed_batch_stops_after_safe_in_path_cancellation(self):
        self.tcl.eval('''
set calls 0
proc ::MeshSeamWeld::prepareCurrentTargetPatch args {return {target_components 10 target_elements {100 101}}}
proc ::MeshSeamWeld::processWeldPathIsolated args {
    incr ::calls
    return {ok 0 rollback_ok 1 error {[MSW_STAGE:CANCELLED] stopped} block_kind creation}
}
set jobs {}
foreach id {A B C} {
    lappend jobs [dict create candidate_id $id source_component_id 20 source_node_ids {11 12} target_component_ids 10 closed_loop 0]
}
set result [::MeshSeamWeld::executeSeedJobs $jobs]
''')
        self.assertEqual('1', self.tcl.eval('set calls'))
        self.assertEqual('1', self.tcl.eval('dict get $result cancelled'))
        self.assertEqual('cancelled', self.tcl.eval('dict get [lindex [dict get $result results] 0] block_kind'))

    def test_cannot_mutate_without_enabling_native_history(self):
        self.tcl.eval('''
proc *sethistoryrecord args {error disabled}
proc ::MeshSeamWeld::processWeldPath args {error "unexpected mutation"}
set result [::MeshSeamWeld::processWeldPathIsolated {11 12} {10} 0 0 1 1 {20} {} {1 0 1} {100 101} 0]
''')
        self.assertEqual('0', self.tcl.eval('dict get $result ok'))
        self.assertIn('TRANSACTION', self.tcl.eval('dict get $result error'))

    def test_failed_path_that_recorded_nothing_is_verified_instead_of_undone(self):
        # HM2022 duplicate weld: the failed *imprint_nodelist records no undo
        # entry and leaves the model untouched.  Undoing "1" there would remove
        # the previously created weld, so the path must be verified, not undone.
        self.tcl.eval('''
proc *sethistoryrecord args {}
proc *startnotehistorystate args {}
proc *endnotehistorystate args {}
proc hm_getundoactions {} {return {Mesh seam weld open node path 1/1}}
set undoCalls 0
proc *undohistorystate args {incr ::undoCalls}
proc ::MeshSeamWeld::processWeldPath args {
    set ::MeshSeamWeld::activeStructuralSnapshot $::before
    error {[MSW_STAGE:IMPRINT] Local-element imprint_nodelist failed; this loop was skipped: 0}
}
proc ::MeshSeamWeld::clearTransientSelections args {}
proc ::MeshSeamWeld::invalidateTargetCaches args {}
set result [::MeshSeamWeld::processWeldPathIsolated {11 12} {10} 0 0 1 1 {20} {} {1 0 1} {100 101} 0]
''')
        self.assertEqual('0', self.tcl.eval('dict get $result ok'))
        self.assertEqual('1', self.tcl.eval('dict get $result rollback_ok'))
        self.assertEqual('0', self.tcl.eval('set undoCalls'))

    def test_failed_path_undoes_exactly_the_entries_it_recorded(self):
        self.tcl.eval('''
proc *sethistoryrecord args {}
proc *startnotehistorystate args {}
proc *endnotehistorystate args {}
proc hm_getundoactions {} {
    if {[info exists ::mutated]} {
        return [list {Mesh seam weld open node path 1/1} {Previous user work}]
    }
    return {Previous user work}
}
set undoArgs {}
proc *undohistorystate args {lappend ::undoArgs $args; return 1}
proc ::MeshSeamWeld::processWeldPath args {
    set ::mutated 1
    set ::MeshSeamWeld::activeStructuralSnapshot $::before
    error {[MSW_STAGE:AUTOMESH] broken}
}
proc ::MeshSeamWeld::clearTransientSelections args {}
proc ::MeshSeamWeld::invalidateTargetCaches args {}
set result [::MeshSeamWeld::processWeldPathIsolated {11 12} {10} 0 0 1 1 {20} {} {1 0 1} {100 101} 0]
''')
        self.assertEqual('1', self.tcl.eval('dict get $result rollback_ok'))
        self.assertEqual('1', self.tcl.eval('set undoArgs'))

    def test_undo_action_count_uses_the_previous_newest_boundary(self):
        self.tcl.eval('proc hm_getundoactions {} {return {}}')
        count = lambda before, after: int(
            self.tcl.call('::MeshSeamWeld::pushedUndoActionCount', before, after))
        self.assertEqual(0, count(['Previous'], ['Previous']))
        self.assertEqual(1, count(['Previous'], ['Path', 'Previous']))
        self.assertEqual(2, count(['Previous'], ['A', 'B', 'Previous']))
        self.assertEqual(0, count([], []))
        self.assertEqual(2, count([], ['A', 'B']))
        # A rerun of the same weld pushes an identically named entry, so the
        # count must come from the stack tail, not from the newest label.
        self.assertEqual(1, count(['Path 1/1'], ['Path 1/1', 'Path 1/1']))
        # An evicted pre-path stack is not a boundary: the count is unknown and
        # the caller falls back to a single undo plus verification.
        self.assertEqual(-1, count(['Evicted', 'Previous'], ['New', 'Previous']))
        # A build without the stack query cannot report a count.
        self.tcl.eval('rename hm_getundoactions {}')
        self.assertEqual(-1, count([], []))

    # Native-undo and batch stubs shared by the retry-policy cases.  A failing
    # attempt damages the snapshot (a dragged attachment node and a leftover
    # output element) and records one undo entry, so the rollback has something
    # real to restore and the verification has something real to prove.
    RETRY_STUBS = '''
proc *sethistoryrecord args {}
proc *startnotehistorystate args {set ::savedConn $::conn; set ::savedXYZ $::xyz}
proc *endnotehistorystate args {}
proc ::MeshSeamWeld::clearTransientSelections args {}
proc ::MeshSeamWeld::invalidateTargetCaches args {}
set cleanup 0
proc ::MeshSeamWeld::removeFailedPathOutputComponent {comp pre} {incr ::cleanup}
set calls 0; set sizes {}
proc ::MeshSeamWeld::processWeldPath args {
    incr ::calls
    lappend ::sizes $::MeshSeamWeld::cfg(weld_mesh_size)
    set ::mutated 1
    dict set ::conn 400 {1 2 12 11}
    dict set ::comp 400 30
    dict set ::xyz 11 {0 0 2}
    set ::MeshSeamWeld::activeStructuralSnapshot $::before
    error $::failure
}
'''

    def retry_case(self, prelude, failure, undo_body=None):
        if undo_body is None:
            undo_body = 'set ::conn $::savedConn; set ::xyz $::savedXYZ; unset -nocomplain ::mutated'
        self.tcl.eval('\n'.join([
            'proc *undohistorystate args {%s}' % undo_body,
            'proc hm_getundoactions {} {',
            '    if {[info exists ::mutated]} { return [list Attempt {Previous user work}] }',
            '    return {Previous user work}',
            '}',
            'set failure {%s}' % failure,
            self.RETRY_STUBS,
            prelude,
            'set result [::MeshSeamWeld::processWeldPathIsolated {11 12} {10} 0 0 1 1 {20} SEAM_T1 {1 0 1} {100 101} 0]',
        ]))

    def test_creation_failure_is_retried_with_adjusted_mesh_size(self):
        # The user already decided that this location can carry a weld, so an
        # AUTOMESH failure is retried with 0.6x and 1.5x the weld mesh size in
        # its own verified transaction before the path is reported as blocked.
        self.retry_case(
            'set ::MeshSeamWeld::cfg(weld_mesh_size) 4\n'
            'proc ::MeshSeamWeld::processWeldPath args {\n'
            '    incr ::calls\n'
            '    lappend ::sizes $::MeshSeamWeld::cfg(weld_mesh_size)\n'
            '    set ::mutated 1\n'
            '    dict set ::conn 400 {1 2 12 11}\n'
            '    dict set ::comp 400 30\n'
            '    dict set ::xyz 11 {0 0 2}\n'
            '    set ::MeshSeamWeld::activeStructuralSnapshot $::before\n'
            '    if {$::calls < 3} { error {[MSW_STAGE:AUTOMESH] Native patch has no boundary.} }\n'
            '    return {weldElems {300}}\n'
            '}\n',
            'unused')
        self.assertEqual('1', self.tcl.eval('dict get $result ok'))
        self.assertEqual('1', self.tcl.eval('dict get $result rollback_ok'))
        self.assertEqual('4 2.4 6.0', self.tcl.eval('set sizes'))
        self.assertEqual('4', self.tcl.eval('set ::MeshSeamWeld::cfg(weld_mesh_size)'))
        self.assertIn('weldElems {300}', self.tcl.eval('dict get $result result'))

    def test_structural_damage_is_reported_instead_of_retried(self):
        # Damage to the mother mesh is never retried: it is blocked with an
        # actionable reason, because the fix belongs in the creation algorithm.
        self.retry_case(
            'set ::MeshSeamWeld::cfg(weld_mesh_size) 4\n',
            'Structural boundary changed in component 10: the attachment face was deleted')
        self.assertEqual('1', self.tcl.eval('set calls'))
        self.assertEqual('0', self.tcl.eval('dict get $result ok'))
        self.assertEqual('structural_damage', self.tcl.eval('dict get $result block_kind'))
        self.tcl.eval('set diagnosis [::MeshSeamWeld::diagnoseFailure $failure]')
        self.assertEqual('structural_damage', self.tcl.eval('dict get $diagnosis block_kind'))
        self.assertTrue(self.tcl.eval('string length [dict get $diagnosis action_zh]'))
        self.assertIn('creation-algorithm defect', self.tcl.eval('dict get $diagnosis action_en'))

    def test_creation_failure_without_a_configured_size_is_not_retried(self):
        self.retry_case(
            'catch {unset ::MeshSeamWeld::cfg(weld_mesh_size)}\n',
            '[MSW_STAGE:AUTOMESH] Native patch has no boundary.')
        self.assertEqual('1', self.tcl.eval('set calls'))
        self.assertEqual('0', self.tcl.eval('dict get $result ok'))
        self.assertEqual('creation', self.tcl.eval('dict get $result block_kind'))

    def test_retry_stops_when_its_rollback_cannot_be_verified(self):
        # A retry that cannot prove it restored the model is never repeated and
        # never reported as a clean block: the batch must stop instead.  The
        # first undo (the failed path itself) still works, the retry's does not.
        self.retry_case(
            'set ::MeshSeamWeld::cfg(weld_mesh_size) 4\n',
            '[MSW_STAGE:AUTOMESH] Native patch has no boundary.',
            undo_body='incr ::undoCalls\n'
                      'if {$::undoCalls == 1} { set ::conn $::savedConn; '
                      'set ::xyz $::savedXYZ; unset -nocomplain ::mutated }')
        self.assertEqual('2', self.tcl.eval('set calls'))
        self.assertEqual('0', self.tcl.eval('dict get $result ok'))
        self.assertEqual('0', self.tcl.eval('dict get $result rollback_ok'))
        self.assertIn('retry rollback verification failed', self.tcl.eval('dict get $result error'))

    def test_partial_automesh_failures_are_not_structural_damage(self):
        for text, expected in (
            ('[MSW_STAGE:AUTOMESH] Native patch has no boundary.', 0),
            ('[MSW_STAGE:IMPRINT] Local-element imprint_nodelist failed', 0),
            ('Weld strip is disconnected from the mother mesh.', 1),
            ('Duplicate structural shell 5 repeats shell 4', 1),
            ('Structural attachment node 11 moved 3.5 (limit 1)', 0),
            ('Structural area changed in component 10 by 40.0 percent', 1),
        ):
            with self.subTest(text=text):
                self.assertEqual(expected, self.tcl.call(
                    '::MeshSeamWeld::weldFailureIsStructuralDamage', text))


if __name__ == '__main__':
    unittest.main()
