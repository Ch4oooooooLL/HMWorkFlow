set directory [file dirname [info script]]
namespace eval ::SolidSeam { variable MODULE_DIR [file normalize [file join $::directory ..]] }
namespace eval ::HWFlow {}
proc ::HWFlow::txt {zh en} { return $en }
foreach name {logger component_selector auto_detect seam_creator ui main} {
    source -encoding utf-8 [file join $::SolidSeam::MODULE_DIR tcl $name.tcl]
}
proc assert {condition message} { if {![uplevel 1 [list expr $condition]]} { error $message } }
set ::SolidSeam::ui(input_type) AUTO_GROUP
set ::SolidSeam::ui(tolerance) invalid
::SolidSeam::validateSettings
proc ::HWFlow::nativeMarkPanel {args} { return $::picks }
set ::picks {3 1 2 1}
assert {[::SolidSeam::selectAutoGroupComponents] eq {1 2 3}} "Multi-selection not deduplicated"
set ::picks {}
assert {[::SolidSeam::selectAutoGroupComponents] eq {}} "Empty selection did not cancel"
set ::picks {1}
assert {[catch {::SolidSeam::selectAutoGroupComponents}]} "Single component accepted"
assert {[::SolidSeam::groupBoundsNear {{0 0 0} {1 1 1}} {{2 1 1} {3 2 2}} 1]} "Touching radius rejected"
assert {![::SolidSeam::groupBoundsNear {{0 0 0} {1 1 1}} {{2 2 2} {3 3 3}} 1]} "Diagonal distance ignored"
set metadata {}; set generated {}
for {set id 1} {$id <= 120} {incr id} {
    # Deterministic mixture of compact, overlapping and elongated boxes.
    set x [expr {double(($id*37)%91)}]; set y [expr {double(($id*19)%47)}]; set z [expr {double(($id*11)%31)}]
    set pitch [expr {0.5+double(($id*7)%9)/4.0}]
    set length [expr {$id%17 == 0 ? 35.0 : 1.0+($id%5)}]
    dict set metadata $id [list $pitch [list [list $x $y $z] [list [expr {$x+$length}] [expr {$y+2}] [expr {$z+1}]]]]
    lappend generated $id
}
set expected {}
for {set i 0} {$i < [llength $generated]} {incr i} {
    set a [lindex $generated $i]
    foreach b [lrange $generated [expr {$i+1}] end] {
        lassign [dict get $metadata $a] pa ba; lassign [dict get $metadata $b] pb bb
        if {[::SolidSeam::groupBoundsNear $ba $bb [expr {1.5*max($pa,$pb)}]]} { lappend expected [list $a $b] }
    }
}
set spatial [::SolidSeam::groupSpatialPairs $generated $metadata]
assert {[dict get $spatial pairs] eq $expected} "Spatial broadphase changed exact pairs or order"
set sparseMeta {}; set sparseIds {}
for {set id 1} {$id <= 2000} {incr id} {
    dict set sparseMeta $id [list 1.0 [list [list [expr {$id*10.0}] 0 0] [list [expr {$id*10.0+1}] 1 1]]]
    lappend sparseIds $id
}
set sparse [::SolidSeam::groupSpatialPairs $sparseIds $sparseMeta]
assert {[dict get $sparse total] == 1999000 && [dict get $sparse pairs] eq {} && [dict get $sparse sweep_tests] == 0} "Sparse broadphase did quadratic work"
proc ::SolidSeam::componentMeshPitch {id} { if {$id == 9} { error "Invalid mesh" }; return 1.0 }
proc ::SolidSeam::groupComponentBounds {id} {
    if {$id == 4} { return {{100 100 100} {101 101 101}} }
    return {{0 0 0} {1 1 1}}
}
set calls {}
proc ::SolidSeam::autoDetectSeams {source target settings} {
    lappend ::calls [list $source $target]
    assert {[dict get $settings automatic] && [dict get $settings search_distance] == 1.5} "Manual parameters leaked"
    if {$source == 2 && $target == 3} { error "isolated detection failure" }
    if {[list $source $target] ni {{2 1} {1 3} {3 1}}} { return {} }
    set gap [expr {$source == 3 ? 0.5 : 0.1}]
    return [list [dict create candidate_id AUTO_${source}_${target} source_component_id $source target_component_id $target \
        maximum_gap $gap mesh_size 1.0 status PENDING]]
}
set plans [::SolidSeam::prepareAutoGroup {4 3 2 1 9 1}]
assert {[llength $plans] == 2} "Wrong pair count"
assert {[llength $calls] == 6} "Far components not culled or duplicate input reprocessed"
set row [lindex [dict get [lindex $plans 0] candidates] 0]
assert {[dict get $row source_component_id] == 2 && [dict get $row target_component_id] == 1} "Reverse-only pair missed"
set row [lindex [dict get [lindex $plans 1] candidates] 0]
assert {[dict get $row source_component_id] == 1 && [dict get $row target_component_id] == 3} "Direction scoring or shared component failed"
assert {[dict get $row status] eq "ACCEPTED"} "Candidate not accepted"
assert {[string match {*detection failures 1*invalid components 1*unmatched components: 4*} $::SolidSeam::autoGroupSummary]} "Failures or isolated components hidden"
assert {[::SolidSeam::prepareAutoGroup {}] eq {}} "Empty input generated work"
namespace eval ::HybridCore {}
proc ::HybridCore::createTaskWorkspace {args} { return [dict create task_dir "" run_id test] }
proc ::HWFlow::nativePanelSessionBegin {} { incr ::sessions; return {} }
proc ::HWFlow::nativePanelSessionEnd {args} { incr ::sessions -1 }
proc ::SolidSeam::saveState {} {}
proc ::SolidSeam::executeSelectionPlan {plan} {
    assert {[llength $::calls] == 6} "Creation began before all directions were prepared"
    lappend ::executed [dict get $plan pair_index]
    return [expr {[dict get $plan pair_index] != 1}]
}
# No real workspace is needed for orchestration tests.
proc ::SolidSeam::log {args} {}
set sessions 0; set calls {}; set executed {}; set picks {1 2 3}
assert {[::SolidSeam::runDetection]} "Failed pair prevented later success"
assert {$executed eq {1 2} && $sessions == 0 && !$::SolidSeam::running} "Batch did not finish/restore session"
assert {[string match {*1 successful pairs, 1 failed pairs*} $::SolidSeam::ui(status)]} "Incorrect batch result"
rename ::SolidSeam::prepareAutoGroupImpl ::SolidSeam::realPrepareAutoGroupImpl
proc ::SolidSeam::prepareAutoGroupImpl {components} {
    set ::SolidSeam::groupCoordinates(1) {1 2 3}
    error "unexpected preparation failure"
}
assert {[catch {::SolidSeam::prepareAutoGroup {1 2}}]} "Unexpected error swallowed"
assert {!$::SolidSeam::groupRecognitionActive && ![array size ::SolidSeam::groupCoordinates] &&
    ![array size ::SolidSeam::groupReadCache] && ![array size ::SolidSeam::groupElementNodes] &&
    ![array size ::SolidSeam::groupElementConfigs]} "Group cache leaked after error"
rename ::SolidSeam::prepareAutoGroupImpl {}
rename ::SolidSeam::realPrepareAutoGroupImpl ::SolidSeam::prepareAutoGroupImpl
puts "PASS AutoGroup checks"
