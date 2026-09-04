set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
namespace eval ::SolidSeam { variable MODULE_DIR [file join $::root modules solid_seam] }
namespace eval ::HWFlow {}
proc ::HWFlow::txt {zh en} { return $en }
foreach name {logger component_selector auto_detect seam_creator candidate_editor ui main} {
    source -encoding utf-8 [file join $::SolidSeam::MODULE_DIR tcl $name.tcl]
}
proc assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}
proc check {name script} {
    if {[catch {uplevel 1 $script} err opts]} {
        puts stderr "FAIL $name: $err\n[dict get $opts -errorinfo]"
        exit 1
    }
    puts "PASS $name"
}
proc *clearmark {args} {}
proc *clearlist {args} { set ::nativeNodes {} }
proc *createlistpanel {args} { set ::nativeNodes $::picks }
proc *createlistbypathpanel {args} { set ::nativeNodes $::picks; incr ::pathPanelCalls }
proc hm_getlist {args} { return $::nativeNodes }
proc ::HWFlow::nativePanelSessionBegin {} { incr ::sessions; return restored }
proc ::HWFlow::nativePanelSessionEnd {windows} { incr ::sessions -1 }
proc ::HWFlow::nativeMarkPanel {args} { return $::targetPick }
proc *createmark {entity slot args} { set ::markedNode [lindex $args end] }
proc hm_getmark {entity slot} { return [dict get $::incidence $::markedNode] }
proc hm_getvalue {entity selector data} {
    if {$data eq "dataname=config"} { return 104 }
    return [dict get $::owners [string range $selector 3 end]]
}
set ::sessions 0
set ::pathPanelCalls 0
set ::owners {1 20 2 20 3 20 4 10 5 30}
set ::incidence {9 {1 4} 2 {2 4} 7 {3 4} 8 {5} 6 {1 5}}
check ordered_nodes_and_auto_links {
    set ::picks {9 2 7}; set ::targetPick 10
    set selection [::SolidSeam::selectNodesAndComponents]
    assert {[dict get $selection node_ids] eq {9 2 7}} "Node order changed"
    assert {[dict get $selection component_ids] eq {20 10}} "Source/target roles changed"
    assert {$::sessions == 0 && $::nativeNodes eq ""} "Selection UI/list leaked"
    assert {$::pathPanelCalls == 1} "Node input did not use native by-path collector"
}
check cancellation_clears_previous_nodes {
    set ::picks {}; set ::nativeNodes {9 2 7}
    assert {[::SolidSeam::selectNodesAndComponents] eq ""} "Cancel reused nodes"
    assert {$::SolidSeam::selectionOutcome eq "SUBMIT"} "Empty node path did not submit"
    set ::picks {9 2 7}; set ::targetPick {}
    assert {[::SolidSeam::selectNodesAndComponents] eq ""} "Cancel reused target"
    assert {$::SolidSeam::selectionOutcome eq "RETRY"} "Empty target submitted incomplete pair"
}
check single_node_input_keeps_source_target_roles {
    set ::picks {9}; set ::targetPick 10
    set selection [::SolidSeam::selectNodesAndComponents]
    assert {[dict get $selection node_ids] eq {9} && [dict get $selection component_ids] eq {20 10}} "Single seed rejected or incorrectly linked"
}
check ownership_rejects_mixed_or_ambiguous_source {
    assert {[catch {::SolidSeam::sourceComponentForNodes {9 8} 10}]} "Mixed components accepted"
    assert {[catch {::SolidSeam::sourceComponentForNodes {6} 10}]} "Ambiguous component accepted"
}
check explicit_parameters_and_type_side_matrix {
    foreach type {T B L} {
        foreach side {POSITIVE NEGATIVE BOTH} {
            array set ::SolidSeam::ui [list weld_type $type side_mode $side default_width 2.25 default_spacing 1.75 tolerance 0.5]
            ::SolidSeam::validateSettings
            set c [::SolidSeam::applyCreationSettings [dict create node_ids {9 2 7}]]
            assert {[dict get $c node_ids] eq {9 2 7}} "Settings reordered nodes"
            assert {[dict get $c suggested_realization] eq "PENTA_MIG_$type"} "Wrong realization"
            assert {[dict get $c side_mode] eq $side} "Side lost"
            assert {[dict get $c weld_width] == 2.25 && [dict get $c line_spacing] == 1.75 && [dict get $c realization_tolerance] == 0.5} "Parameters changed"
        }
    }
}
check invalid_numeric_inputs {
    foreach bad {0 -1 NaN Inf -Inf 1e999 text {}} {
        set ::SolidSeam::ui(tolerance) $bad
        assert {[catch {::SolidSeam::validateSettings}]} "Accepted invalid tolerance $bad"
    }
    set ::SolidSeam::ui(tolerance) 15
}
check settings_persistence_keys {
    foreach key {input_type weld_type side_mode tolerance default_spacing default_width} {
        assert {$key in [::SolidSeam::stateKeys]} "Missing saved key $key"
    }
}
check auto_mode_ignores_disabled_manual_numbers {
    set saved [array get ::SolidSeam::ui]
    array set ::SolidSeam::ui {input_type AUTO tolerance invalid default_width invalid default_spacing invalid}
    ::SolidSeam::validateSettings
    array set ::SolidSeam::ui $saved
}
check automatic_joint_geometry_and_scale {
    assert {[::SolidSeam::automaticJointVote {0 0 1} {1 0 0} {0 0 3} 10] eq "T"} "T joint misclassified"
    assert {[::SolidSeam::automaticJointVote {0 0 1} {0 0 -1} {5 0 0} 10] eq "B"} "Coplanar butt joint misclassified"
    assert {[::SolidSeam::automaticJointVote {0 0 1} {0 0 -1} {5 0 0.1} 10] eq "L"} "Offset lap joint misclassified"
    assert {[::SolidSeam::automaticJointVote {} {0 0 1} {0 0 3} 10] eq "NATIVE"} "Missing normal guessed"
    foreach scale {0.001 1 1000} {
        assert {[::SolidSeam::automaticJointVote {0 0 1} {0 0 1} [list 0 0 [expr {0.1*$scale}]] [expr {10*$scale}]] eq "L"} "Units changed classification"
    }
}
check auto_boundary_paths_keep_topology_and_closure {
    set graph {1 {2} 2 {1 3} 3 {2} 4 {5} 5 {4} 6 {7 8} 7 {6 8} 8 {6 7}}
    set paths [::SolidSeam::automaticBoundaryPaths {1 2 3 4 5 6 7 8} $graph]
    assert {[llength $paths] == 3} "Disconnected edges joined"
    assert {[dict get [lindex $paths 2] is_closed] == 1} "Closed edge became open"
    assert {[dict get [lindex $paths 0] node_ids] eq {1 2 3}} "Open edge reordered"
    assert {[catch {::SolidSeam::automaticBoundaryPaths {1 2 3 4} {1 {2 3 4} 2 {1} 3 {1} 4 {1}}}]} "Branched boundary guessed"
    set many {}
    for {set i 0} {$i < 10000} {incr i} { lappend many $i }
    set sample [::SolidSeam::sampleEvenly $many 128]
    assert {[llength $sample] == 128 && [lindex $sample 0] == 0 && [lindex $sample end] == 9999} "Sampling unbounded or biased to component start"
}
check branched_boundaries_split_at_junctions {
    set graph {1 {2} 2 {1 3 4} 3 {2} 4 {2} 5 {6 7} 6 {5 7} 7 {5 6}}
    set paths [::SolidSeam::automaticBoundaryPaths [dict keys $graph] $graph 1]
    assert {[llength $paths] == 4} "Lost independent branches or loop"
    set edges {}
    foreach record $paths {
        set nodes [dict get $record node_ids]
        if {[dict get $record is_closed]} { lappend nodes [lindex $nodes 0] }
        for {set i 1} {$i < [llength $nodes]} {incr i} {
            set a [lindex $nodes [expr {$i-1}]]; set b [lindex $nodes $i]
            assert {$b in [dict get $graph $a]} "Invented edge"
            dict incr edges [lsort -integer [list $a $b]]
        }
        if {2 in $nodes} { assert {[llength $nodes] == 2} "Traversed junction" }
    }
    assert {[dict size $edges] == 6} "Missing edge"
    dict for {edge count} $edges { assert {$count == 1} "Duplicate edge" }
}
check open_edge_middle_is_not_a_separate_layer {
    rename ::SolidSeam::freeBoundaryGraph ::SolidSeam::originalFreeGraph
    rename ::SolidSeam::nodeXYZ ::SolidSeam::originalXYZ
    proc ::SolidSeam::freeBoundaryGraph {id} { return $::testGraph }
    proc ::SolidSeam::nodeXYZ {id} { return [dict get $::testXYZ $id] }
    set ::testGraph {1 {2} 2 {1 3} 3 {2 4} 4 {3 5} 5 {4 6} 6 {5 7} 7 {6}}
    set ::testXYZ {1 {0 0 3} 2 {10 0 3} 3 {20 0 9} 4 {30 0 9} 5 {40 0 9} 6 {50 0 3} 7 {60 0 3}}
    set pairs {{1 101 3} {2 102 3} {3 103 9} {4 104 9} {5 105 9} {6 106 3} {7 107 3}}
    set anchors [concat [lrange $pairs 0 1] [lrange $pairs 5 6]]
    assert {[::SolidSeam::retainBoundaryInteriors 1 $pairs $anchors] eq $pairs} "Smooth middle removed"
    set missing [lreplace $pairs 3 3]
    assert {[::SolidSeam::retainBoundaryInteriors 1 $missing $anchors] eq $anchors} "Bridged out-of-range middle"
    set ::testXYZ {1 {0 0 3} 2 {10 0 3} 3 {10 0 9} 4 {30 0 9} 5 {50 0 9} 6 {50 0 3} 7 {60 0 3}}
    assert {[::SolidSeam::retainBoundaryInteriors 1 $pairs $anchors] eq $anchors} "Restored notch sidewalls"
    rename ::SolidSeam::nodeXYZ {}
    rename ::SolidSeam::originalXYZ ::SolidSeam::nodeXYZ
    rename ::SolidSeam::freeBoundaryGraph {}
    rename ::SolidSeam::originalFreeGraph ::SolidSeam::freeBoundaryGraph
}
check launch_opens_panel_without_selection {
    rename ::SolidSeam::showPanel ::SolidSeam::realShowPanel
    proc ::SolidSeam::showPanel {} { return panel_opened }
    assert {[::SolidSeam::runAction] eq "panel_opened"} "Launch entered selector"
    rename ::SolidSeam::showPanel {}
    rename ::SolidSeam::realShowPanel ::SolidSeam::showPanel
}
check auto_creation_preserves_inferred_parameters {
    set saved [array get ::SolidSeam::ui]
    array set ::SolidSeam::ui {input_type AUTO weld_type T tolerance invalid default_width invalid default_spacing invalid side_mode NEGATIVE}
    foreach command {automaticSettings autoDetectSeams createAcceptedCandidates} {
        rename ::SolidSeam::$command ::SolidSeam::saved_$command
    }
    proc ::SolidSeam::automaticSettings {source target} { return {automatic 1} }
    proc ::SolidSeam::autoDetectSeams {source target settings} {
        assert {$settings eq {automatic 1}} "Auto used manual search settings"
        return [list [dict create suggested_realization PENTA_MIG_B joint_type BUTT_JOINT \
            line_spacing 0.06 weld_width 0.06 realization_tolerance 0.15 parameter_strategy AUTO_GEOMETRY_V1 side_mode POSITIVE]]
    }
    proc ::SolidSeam::createAcceptedCandidates {} { set ::capturedAuto $::SolidSeam::candidateRows }
    ::SolidSeam::autoDetectAndCreate {20 10}
    set row [lindex $::capturedAuto 0]
    assert {[dict get $row suggested_realization] eq "PENTA_MIG_B" && [dict get $row weld_width] == 0.06 && [dict get $row realization_tolerance] == 0.15} "Manual values overwrote Auto"
    assert {[dict get $row side_mode] eq "POSITIVE" && [dict get $row status] eq "ACCEPTED"} "Side/acceptance not propagated"
    foreach command {automaticSettings autoDetectSeams createAcceptedCandidates} {
        rename ::SolidSeam::$command {}; rename ::SolidSeam::saved_$command ::SolidSeam::$command
    }
    array set ::SolidSeam::ui $saved
}
check failed_realizations_are_not_reported_as_success {
    proc ::SolidSeam::createOneCandidate {candidate} { error "native failure" }
    proc ::SolidSeam::writeRealizationResult {results} { set ::results $results }
    set ::SolidSeam::candidateRows [list [dict create candidate_id test status ACCEPTED]]
    assert {[catch {::SolidSeam::createAcceptedCandidates}]} "Failure reported as success"
    assert {[dict get [lindex $::results 0] status] eq "FAILED"} "Failure not recorded"
}
check single_seed_closed_boundary_rules {
    set graph {1 {2 4} 2 {1 3} 3 {2 4} 4 {1 3} 11 {12 13} 12 {11 13} 13 {11 12}}
    assert {[::SolidSeam::closedPathsForSeed 3 $graph] eq {{3 2 1 4}}} "Boundary seed chose another loop or wrong order"
    assert {[llength [::SolidSeam::closedPathsForSeed 99 $graph]] == 2} "Interior seed did not include both boundaries"
    dict set graph 21 {22}; dict set graph 22 {21}
    assert {[catch {::SolidSeam::closedPathsForSeed 21 $graph}]} "Open boundary silently replaced by unrelated loop"
    assert {[catch {::SolidSeam::closedPathsForSeed 1 {1 {2 3 4} 2 {1 3} 3 {1 2} 4 {1}}}]} "Branched boundary accepted"
    assert {[catch {::SolidSeam::closedPathsForSeed 99 {}}]} "Missing boundary accepted"
}
check closed_arc_topology_covers_every_edge_once {
    source -encoding utf-8 [file join $::SolidSeam::MODULE_DIR command_profiles hm2019_penta_mig_common.tcl]
    foreach loop {{8 3 10} {8 3 10 4} {8 3 10 4 2}} {
        set edges {}
        foreach arc [::SolidSeamCommandProfile::closedBoundaryArcs $loop] {
            assert {[llength $arc] == [llength [lsort -unique $arc]]} "Native list would remove duplicate nodes"
            for {set i 1} {$i < [llength $arc]} {incr i} {
                lappend edges [lsort -integer [list [lindex $arc [expr {$i-1}]] [lindex $arc $i]]]
            }
        }
        set expected {}
        for {set i 0} {$i < [llength $loop]} {incr i} {
            lappend expected [lsort -integer [list [lindex $loop $i] [lindex $loop [expr {($i+1)%[llength $loop]}]]]]
        }
        assert {[lsort $edges] eq [lsort $expected]} "Closed arcs omitted or duplicated a boundary edge"
    }
}
check snapshots_never_select_the_model {
    proc hm_entitylist {entity kind mode} {
        assert {$kind eq "id" && $mode eq "all"} "Snapshot scope changed"
        return $::modelIds
    }
    rename *createmark ::savedCreateMark
    proc *createmark {args} { error "Snapshot attempted to mark entities" }
    set ::modelIds {}
    for {set i 1} {$i <= 300000} {incr i} { lappend ::modelIds $i }
    assert {[llength [::SolidSeamCommandProfile::snapshotIds elems]] == 300000} "Incomplete snapshot"
    assert {[::SolidSeamCommandProfile::newIds {100 900} {4 100 900 1000}] eq {4 1000}} "New IDs incorrectly assume monotonic allocation"
    rename *createmark {}; rename ::savedCreateMark *createmark
    unset ::modelIds
}
check internal_query_marks_clear_on_success_and_failure {
    foreach cmd {*createmark *clearmark hm_getmark} { rename $cmd saved_$cmd }
    proc *createmark {entity slot args} { set ::markState($entity,$slot) {7 8 9} }
    proc *clearmark {entity slot} { set ::markState($entity,$slot) {} }
    proc hm_getmark {entity slot} {
        if {$::readFails} { error "Simulated native read failure" }
        return $::markState($entity,$slot)
    }
    set ::readFails 0
    assert {[::SolidSeam::queryMarkedIds elems 1 "by node id" 20] eq {7 8 9}} "Query lost IDs"
    assert {$::markState(elems,1) eq ""} "Component query left elements marked"
    set ::readFails 1
    assert {[catch {::SolidSeam::queryMarkedIds elems 1 "by node id" 20}]} "Read failure swallowed"
    assert {$::markState(elems,1) eq ""} "Read failure left elements marked"
    foreach cmd {*createmark *clearmark hm_getmark} { rename $cmd {}; rename saved_$cmd $cmd }
}
check component_connectivity_queries_do_not_mark {
    rename hm_getvalue saved_hm_getvalue
    rename *createmark saved_create_mark
    proc hm_getvalue {entity selector data} {
        assert {$entity eq "comps" && $selector eq "id=20"} "Wrong component scope"
        if {$data eq "dataname=elements"} { return {7 8 9} }
        if {$data eq "dataname=nodes"} { return {11 12 13} }
        error "Unexpected component query"
    }
    proc *createmark {args} { error "Component connectivity selected entities" }
    assert {[::SolidSeam::componentElementIds 20] eq {7 8 9}} "Element query lost IDs"
    assert {[::SolidSeam::componentNodeIds 20] eq {11 12 13}} "Node query lost IDs"
    rename hm_getvalue {}; rename saved_hm_getvalue hm_getvalue
    rename *createmark {}; rename saved_create_mark *createmark
}
check spatial_index_matches_brute_force {
    rename ::SolidSeam::nodeXYZ ::SolidSeam::modelNodeXYZ
    proc ::SolidSeam::nodeXYZ {id} { incr ::coordinateReads; return [dict get $::xyz $id] }
    set ::xyz {}; set ids {}; set ::coordinateReads 0
    expr {srand(9182)}
    for {set i 1} {$i <= 300} {incr i} {
        dict set ::xyz $i [list [expr {rand()*100-50}] [expr {rand()*100-50}] [expr {rand()*100-50}]]
        lappend ids $i
    }
    set tree [::SolidSeam::spatialIndex $ids]
    foreach id [lrange $ids 0 79] {
        set point [dict get $::xyz $id]
        set nearest 1.0e100; set expected ""
        foreach other $ids {
            if {$other == $id} { continue }
            set distance [::SolidSeam::nodeDistance $point [dict get $::xyz $other]]
            if {$distance < $nearest} { set nearest $distance; set expected $other }
        }
        lassign [::SolidSeam::nearestNode $tree $point 1.0e100 $id] actual distance
        assert {$actual == $expected && abs($distance-$nearest) < 1e-9} "Nearest mismatch"
    }
    assert {$::coordinateReads == 300} "Coordinates reread during search"
    set tree [::SolidSeam::spatialTree {{-1 0 0 3} {1 0 0 2}} 0]
    assert {[lindex [::SolidSeam::nearestNode $tree {0 0 0} 1] 0] == 2} "Radius boundary/tie mismatch"
    assert {[lindex [::SolidSeam::nearestNode $tree {0 0 0} 0.99] 0] eq ""} "Radius ignored"
    assert {[lindex [::SolidSeam::nearestNode {} {0 0 0}] 0] eq ""} "Empty index failed"
    rename ::SolidSeam::nodeXYZ {}
    rename ::SolidSeam::modelNodeXYZ ::SolidSeam::nodeXYZ
}
check detection_cache_cleared_on_failure {
    rename ::SolidSeam::detectSeamsImpl ::SolidSeam::realDetect
    proc ::SolidSeam::detectSeamsImpl {args} {
        set ::SolidSeam::detectionCoordinates(42) {1 2 3}
        error "test failure"
    }
    assert {[catch {::SolidSeam::autoDetectSeams 1 2 {}}]} "Error swallowed"
    assert {!$::SolidSeam::detectionCacheActive && ![info exists ::SolidSeam::detectionCoordinates(42)]} "Stale geometry cache"
}
check automatic_side_uses_native_conventions {
    set source [list [dict create normal {1 0 0} center {0 0 1}]]
    set positive [list [dict create normal {0 0 1} center {1 0 0}]]
    set negative [list [dict create normal {0 0 1} center {-1 0 0}]]
    assert {[::SolidSeam::automaticSideVote T {1 0 0} {0 0 1} {0 0 0} $source $positive 1] eq "POSITIVE"} "Positive supported side missed"
    assert {[::SolidSeam::automaticSideVote T {1 0 0} {0 0 1} {0 0 0} $source $negative 1] eq "NEGATIVE"} "Negative supported side missed"
    assert {[::SolidSeam::automaticSideVote T {-1 0 0} {0 0 1} {0 0 0} $source $positive 1] eq "NEGATIVE"} "Source normal reversal ignored"
    assert {[::SolidSeam::automaticSideVote T {1 0 0} {0 0 1} {0 0 0} $source [concat $positive $negative] 1] eq "UNKNOWN"} "Symmetric T guessed design intent"
    assert {[::SolidSeam::automaticSideVote L {} {} {} {} {} 1] eq "NEGATIVE"} "Native lap side mapping wrong"
    assert {[::SolidSeam::automaticSideVote B {} {} {} {} {} 1] eq "UNKNOWN"} "Butt side guessed"
}
check inferred_side_confidence_and_explicit_both {
    rename ::SolidSeam::localShellPatch ::SolidSeam::savedPatch
    rename ::SolidSeam::nodeXYZ ::SolidSeam::savedXYZ
    proc ::SolidSeam::nodeXYZ {n} { return [list 0 0 [expr {$n-1}]] }
    proc ::SolidSeam::localShellPatch {n comp} {
        return [list [dict create normal {0 0 1} center [list 1 0 [expr {$n-1}]]]]
    }
    set candidate [dict create mesh_size 10 maximum_gap 1 source_component_id 20 target_component_id 10]
    set saved $::SolidSeam::ui(side_mode)
    set ::SolidSeam::ui(side_mode) POSITIVE
    set inferred [::SolidSeam::applyAutomaticParameters $candidate {{1 2 1}}]
    assert {[dict get $inferred side_mode] eq "NEGATIVE" && [dict get $inferred side_confidence] == 1.0} "L side inference not applied"
    set ::SolidSeam::ui(side_mode) BOTH
    set both [::SolidSeam::applyAutomaticParameters $candidate {{1 2 1}}]
    assert {[dict get $both side_mode] eq "BOTH" && [dict get $both side_strategy] eq "EXPLICIT_BOTH"} "Explicit both sides overridden"
    set ::SolidSeam::ui(side_mode) $saved
    rename ::SolidSeam::localShellPatch {}; rename ::SolidSeam::savedPatch ::SolidSeam::localShellPatch
    rename ::SolidSeam::nodeXYZ {}; rename ::SolidSeam::savedXYZ ::SolidSeam::nodeXYZ
}
check missing_element_notch_splits_without_bridging {
    rename ::SolidSeam::nodeXYZ ::SolidSeam::originalNodeXYZ
    rename ::SolidSeam::localShellPatch ::SolidSeam::originalShellPatch
    proc ::SolidSeam::nodeXYZ {node} { return [dict get $::notchXYZ $node] }
    proc ::SolidSeam::localShellPatch {node component} {
        set p [::SolidSeam::nodeXYZ $node]
        return [list [dict create center [list [lindex $p 0] [expr {[lindex $p 1]+$::scale}] 0] normal {0 0 1}]]
    }
    foreach ::scale {0.001 1 1000} {
        set ::notchXYZ {}; set n 0
        foreach p {{-2 0} {-1 0} {0 0} {0 1} {1 1} {1 0} {2 0} {3 0}} {
            incr n; dict set ::notchXYZ $n [list [expr {[lindex $p 0]*$::scale}] [expr {[lindex $p 1]*$::scale}] 0]
        }
        set result [::SolidSeam::excludeBoundaryNotches [list [dict create node_ids {1 2 3 4 5 6 7 8} is_closed 0]] 20 $::scale]
        assert {[llength $result] == 2} "Notch was not split"
        assert {[dict get [lindex $result 0] node_ids] eq {1 2 3} && [dict get [lindex $result 1] node_ids] eq {6 7 8}} "Notch nodes retained or mouth bridged"
        set reverse [::SolidSeam::excludeBoundaryNotches [list [dict create node_ids {8 7 6 5 4 3 2 1} is_closed 0]] 20 $::scale]
        assert {[llength $reverse] == 2} "Notch filter depends on path direction"
        # An outward tab must not be treated as missing material.
        dict set ::notchXYZ 4 [list 0 [expr {-$::scale}] 0]
        dict set ::notchXYZ 5 [list $::scale [expr {-$::scale}] 0]
        set tab [::SolidSeam::excludeBoundaryNotches [list [dict create node_ids {1 2 3 4 5 6 7 8} is_closed 0]] 20 $::scale]
        assert {[llength $tab] == 1 && [llength [dict get [lindex $tab 0] node_ids]] == 8} "Outward tab removed"
    }
    rename ::SolidSeam::nodeXYZ {}; rename ::SolidSeam::originalNodeXYZ ::SolidSeam::nodeXYZ
    rename ::SolidSeam::localShellPatch {}; rename ::SolidSeam::originalShellPatch ::SolidSeam::localShellPatch
}
# Exercise the real collection/preparation/execution controller. Native model
# operations are substituted; assert no realization until ALL pairs are ready.
namespace eval ::HybridCore {}
proc ::SolidSeam::saveState {} { incr ::saves }
proc ::SolidSeam::newRun {} {
    assert {$::steps eq ""} "Workspace created before batch submission"
    incr ::batches
    set ::SolidSeam::runtimeDir "batch_$::batches"
    set ::SolidSeam::candidateRows {}
}
proc ::HybridCore::finalizeTaskWorkspace {path status} { lappend ::finalized [list $path $status] }
proc ::SolidSeam::log {args} {}
proc ::SolidSeam::message {icon text} { lappend ::messages $text }
proc ::HWFlow::nativePanelSessionBegin {} { incr ::begins; incr ::sessions; return restored }
proc ::HWFlow::nativePanelSessionEnd {windows} { incr ::ends; incr ::sessions -1 }
proc nextInput {} {
    assert {$::sessions == 1} "Module panel visible during selection"
    assert {$::batches == 0 && $::prepared eq "" && $::created eq ""} "Model work started before submission"
    assert {$::SolidSeam::selectedComponentIds eq "" && $::nativeNodes eq ""} "Previous input was reused"
    assert {[::SolidSeam::runDetection] == 0} "Reentrant Start was accepted"
    ::SolidSeam::showPanel
    if {[llength $::steps] == 0} { error "Controller did not stop on submit" }
    set step [lindex $::steps 0]; set ::steps [lrange $::steps 1 end]
    if {$step eq "invalid"} { error "Invalid input" }
    if {$step eq "target_cancel"} { set ::SolidSeam::selectionOutcome RETRY; return {} }
    if {$step eq "submit"} { set ::SolidSeam::selectionOutcome SUBMIT; return {} }
    return $step
}
proc ::SolidSeam::selectNodesAndComponents {} {
    set source [nextInput]
    if {$source eq ""} { return {} }
    return [dict create node_ids [list $source 2 7] component_ids [list $source 10]]
}
proc ::SolidSeam::selectComponents {} {
    set source [nextInput]
    if {$source eq ""} { return {} }
    return [list $source 10]
}
proc prepareBatch {mode nodes comps prepareOnly} {
    assert {$::sessions == 1 && $::steps eq ""} "Preparation preceded submission"
    assert {$prepareOnly == 1 && $::created eq ""} "Preparation mutated model"
    set source [lindex $comps 0]
    assert {$comps eq [list $source 10]} "Link order changed or crossed pairs"
    if {$mode eq "NODES_COMPS"} { assert {$nodes eq [list $source 2 7]} "Node order changed" }
    lappend ::prepared $source
    if {$source == 30} { error "Boundary detection failed" }
    return [list [dict create candidate_id TEST source_component_id $source]]
}
proc ::SolidSeam::createFromNodes {nodes comps {prepareOnly 0}} { prepareBatch NODES_COMPS $nodes $comps $prepareOnly }
proc ::SolidSeam::autoDetectAndCreate {comps {prepareOnly 0}} { prepareBatch $::SolidSeam::ui(input_type) {} $comps $prepareOnly }
proc ::SolidSeam::createAcceptedCandidates {} {
    assert {$::steps eq "" && $::prepared eq $::expectedPrepared} "Realization preceded full preparation"
    assert {$::sessions == 1} "Panel reopened between pairs"
    set row [lindex $::SolidSeam::candidateRows 0]
    set source [dict get $row source_component_id]
    lappend ::created $source
    lappend ::candidateIds [dict get $row candidate_id]
    if {$source == 40} { error "Native creation failed" }
}
proc resetBatchTest {mode steps expected} {
    set ::SolidSeam::ui(input_type) $mode
    set ::steps $steps; set ::expectedPrepared $expected
    set ::sessions 0; set ::begins 0; set ::ends 0; set ::batches 0; set ::saves 0
    set ::created {}; set ::prepared {}; set ::finalized {}; set ::messages {}; set ::candidateIds {}
}
check batch_all_modes_cache_then_submit {
    foreach mode {NODES_COMPS COMPS_COMPS AUTO} {
        resetBatchTest $mode {20 target_cancel 21 submit} {20 21}
        assert {[::SolidSeam::runDetection] == 1} "Completed work not reported"
        assert {$::created eq {20 21}} "Target cancel lost cache or source order"
        assert {$::candidateIds eq {PAIR_1_TEST PAIR_2_TEST}} "Candidate IDs collide across groups"
        assert {$::sessions == 0 && $::begins == 1 && $::ends == 1} "Incorrect panel lifecycle"
        assert {$::finalized eq {{batch_1 SUCCESS} {batch_2 SUCCESS}}} "Incorrect workspace lifecycle"
        assert {!$::SolidSeam::running && $::saves == 1 && $::SolidSeam::queuedPairCount == 0} "Session state leaked"
        assert {[string match {*2 successful pairs, 0 failed pairs*} $::SolidSeam::ui(status)]} "Missing summary"
        resetBatchTest $mode {submit} {}
        assert {[::SolidSeam::runDetection] == 0 && $::batches == 0} "Empty cache created work"
        assert {$::sessions == 0 && !$::SolidSeam::running} "Immediate submit left panel hidden"
    }
}
check batch_errors_do_not_drop_later_pairs {
    resetBatchTest NODES_COMPS {invalid 30 40 20 submit} {30 40 20}
    assert {[::SolidSeam::runDetection] == 1} "No recovery after preparation/creation failures"
    assert {$::created eq {40 20}} "Failed preparation was executed or later pair dropped"
    assert {$::finalized eq {{batch_1 FAILED} {batch_2 FAILED} {batch_3 SUCCESS}}} "Failure lifecycle incorrect"
    assert {[llength $::messages] == 3} "Errors missing or reported twice"
    assert {[string match {*1 successful pairs, 2 failed pairs*} $::SolidSeam::ui(status)]} "Failure count lost"
}
check batch_invalid_settings_do_not_enter_selection {
    resetBatchTest NODES_COMPS {submit} {}
    set ::SolidSeam::ui(tolerance) 0
    assert {[::SolidSeam::runDetection] == 0} "Invalid settings accepted"
    assert {$::begins == 0 && $::steps eq {submit} && !$::SolidSeam::running} "Invalid settings entered session"
    set ::SolidSeam::ui(tolerance) 15
}
check batch_unexpected_error_restores_panel {
    resetBatchTest NODES_COMPS {} {}
    rename ::SolidSeam::collectSelectionPairs ::SolidSeam::realCollectSelectionPairs
    proc ::SolidSeam::collectSelectionPairs {} { error "Unexpected controller failure" }
    assert {[::SolidSeam::runDetection] == 0} "Unexpected error escaped"
    assert {$::sessions == 0 && $::ends == 1 && !$::SolidSeam::running} "Error stranded hidden panel"
}
puts "PASS all refactor checks"
