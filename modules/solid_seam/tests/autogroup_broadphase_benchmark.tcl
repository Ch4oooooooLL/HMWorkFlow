# Standalone scalability benchmark; no HyperMesh model is read or modified.
set directory [file dirname [info script]]
namespace eval ::SolidSeam { variable MODULE_DIR [file normalize [file join $::directory ..]] }
namespace eval ::HWFlow {}
proc ::HWFlow::txt {zh en} { return $en }
foreach name {logger component_selector auto_detect seam_creator ui main} {
    source -encoding utf-8 [file join $::SolidSeam::MODULE_DIR tcl $name.tcl]
}
set metadata {}; set components {}
set count [expr {[llength $argv] ? [lindex $argv 0] : 2000}]
for {set id 1} {$id <= $count} {incr id} {
    # Sparse components represent the common AutoGroup broad-phase workload.
    set low [list [expr {$id*10.0}] [expr {($id%20)*10.0}] 0]
    set high [list [expr {[lindex $low 0]+1}] [expr {[lindex $low 1]+1}] 1]
    dict set metadata $id [list 1.0 [list $low $high]]
    lappend components $id
}
set start [clock microseconds]; set legacyPairs 0; set legacyTests 0
for {set i 0} {$i < [llength $components]} {incr i} {
    set a [lindex $components $i]
    foreach b [lrange $components [expr {$i+1}] end] {
        incr legacyTests
        lassign [dict get $metadata $a] pa ba; lassign [dict get $metadata $b] pb bb
        if {[::SolidSeam::groupBoundsNear $ba $bb [expr {1.5*max($pa,$pb)}]]} { incr legacyPairs }
    }
}
set legacyUs [expr {[clock microseconds]-$start}]
set start [clock microseconds]
set spatial [::SolidSeam::groupSpatialPairs $components $metadata]
set spatialUs [expr {[clock microseconds]-$start}]
if {$legacyPairs != [llength [dict get $spatial pairs]]} { error "pair count differs" }
puts "components=$count theoretical_pairs=$legacyTests legacy_us=$legacyUs spatial_us=$spatialUs speedup=[format %.1f [expr {double($legacyUs)/max(1,$spatialUs)}]]x sweep_tests=[dict get $spatial sweep_tests]"
