set directory [file dirname [info script]]
namespace eval ::SolidSeam { variable MODULE_DIR [file normalize [file join $::directory ..]] }
namespace eval ::HWFlow {}
proc ::HWFlow::txt {zh en} { return $en }
foreach name {logger auto_detect main} { source -encoding utf-8 [file join $::SolidSeam::MODULE_DIR tcl $name.tcl] }
source [file join $::SolidSeam::MODULE_DIR command_profiles hm2019_penta_mig_common.tcl]
proc assert {condition message} { if {![uplevel 1 [list expr $condition]]} { error $message } }
set failBatch 0
proc hm_getvalue {entity selector field} {
    set name [string range $field 9 end]
    if {[string match user_ids=* $selector]} {
        if {$::failBatch} { return {} }
        set ids [lreverse [string range $selector 9 end]]
    } else { set ids [list [string range $selector 3 end]] }
    set result {}
    foreach id $ids {
        switch -- $name {
            id { set value $id }
            x - y - z { set value [expr {$id*10}] }
            node1 { set value [expr {$id*10+1}] }
            node2 { set value [expr {$id*10+2}] }
            default { set value 0 }
        }
        lappend result $value
    }
    return $result
}
::SolidSeam::beginGroupRecognitionCache {1 2}
::SolidSeam::prefetchCoordinates {2 1}
assert {[::SolidSeam::nodeXYZ 1] eq {10 10 10} && [::SolidSeam::nodeXYZ 2] eq {20 20 20}} "Reordered coordinates corrupted"
set ::SolidSeam::groupStableElements {1 1 2 1}
::SolidSeam::prefetchElementNodes {1 2}
assert {[::SolidSeam::elementNodes 1] eq {11 12} && [::SolidSeam::elementNodes 2] eq {21 22}} "Reordered connectivity corrupted"
set failBatch 1
::SolidSeam::prefetchCoordinates {3}
assert {![info exists ::SolidSeam::groupCoordinates(3)] && [::SolidSeam::nodeXYZ 3] eq {30 30 30}} "Malformed batch failed scalar fallback"
::SolidSeam::endGroupRecognitionCache
set many {}; for {set i 1} {$i <= 1000} {incr i} { lappend many [expr {1000000000+$i}] }
foreach chunk [::SolidSeam::queryChunks $many] {
    assert {[llength $chunk]<=256 && [string length $chunk]<=3000} "Unbounded query"
}
rename ::SolidSeam::prepareSelectionPairsImpl ::SolidSeam::originalPrepare
proc ::SolidSeam::prepareSelectionPairsImpl {pairs} {
    assert {$::SolidSeam::groupRecognitionActive} "Auto cache missing"
    error "injected prepare failure"
}
set ::SolidSeam::ui(input_type) AUTO
assert {[catch {::SolidSeam::prepareSelectionPairs {{component_ids {1 2}}}}]} "Prepare error swallowed"
assert {!$::SolidSeam::groupRecognitionActive && ![array size ::SolidSeam::groupCoordinates]} "Prepare cache leaked"
set active {}; set created 0
proc hm_entityrecorder {entity option} {
    switch -- $option {
        on { dict set ::active $entity 1 }
        off { dict set ::active $entity 0 }
        ids { return {7} }
    }
}
assert {[catch {::SolidSeamCommandProfile::recordCreation {incr ::created; error "partial creation"}}]} "Creation error swallowed"
assert {$created==1 && ![dict get $active elems] && ![dict get $active connectors]} "Recorder leaked or command retried"
set result [::SolidSeamCommandProfile::recordCreation {incr ::created}]
assert {[dict get $result elems] eq {7} && $created==2} "Recorded IDs lost"
rename hm_entityrecorder {}
proc hm_entitylist {entity args} { if {$::created==2} { return {1 2} }; return {1 2 7} }
set result [::SolidSeamCommandProfile::recordCreation {incr ::created}]
assert {[dict get $result elems] eq {7} && $created==3} "Recorder-unavailable fallback failed"
puts "PASS speed checks"
