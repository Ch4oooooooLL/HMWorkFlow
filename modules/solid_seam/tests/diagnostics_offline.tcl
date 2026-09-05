set directory [file dirname [file normalize [info script]]]
namespace eval ::SolidSeam {}
source -encoding utf-8 [file join $directory .. tcl diagnostics.tcl]

proc assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}
proc ::SolidSeam::nodeDistance {p q} {
    set dx [expr {[lindex $p 0]-[lindex $q 0]}]
    set dy [expr {[lindex $p 1]-[lindex $q 1]}]
    set dz [expr {[lindex $p 2]-[lindex $q 2]}]
    return [expr {sqrt($dx*$dx+$dy*$dy+$dz*$dz)}]
}

set base [dict create candidate_id AUTO_1 source_component_id 1 target_component_id 2 node_ids {10 11 12} \
    is_closed 0 suggested_realization PENTA_MIG_T joint_type T_JOINT side_mode POSITIVE \
    line_spacing 6 weld_width 6.0 realization_tolerance 15.000]
set a [::SolidSeam::candidateFingerprint $base]
dict set base recognition_timings {matching_ms 10}
dict set base shadow_face_summary {potential_false_negatives 2}
dict set base candidate_id GROUP_9_AUTO_1
assert {[::SolidSeam::candidateFingerprint $base] eq $a} "Diagnostic fields or display id changed fingerprint"
dict set base node_ids {10 12 11}
assert {[::SolidSeam::candidateFingerprint $base] ne $a} "Creation node order did not change fingerprint"

set triangle [::SolidSeam::shadowTriangleRecord {0 0 0} {10 0 0} {0 10 0}]
set tree [::SolidSeam::shadowBuildBVH [list $triangle]]
assert {abs([::SolidSeam::shadowNearestFaceDistance $tree {3 3 4}]-4.0) < 1.0e-9} "Interior point-to-face distance wrong"
assert {abs([::SolidSeam::pointTriangleDistance {8 8 0} {0 0 0} {10 0 0} {0 10 0}]-[expr {sqrt(18.0)}]) < 1.0e-9} "Edge region distance wrong"
assert {abs([::SolidSeam::pointTriangleDistance {2 3 0} {0 0 0} {5 0 0} {10 0 0}]-3.0) < 1.0e-9} "Degenerate triangle fallback wrong"

set triangles {}
for {set i 0} {$i < 40} {incr i} {
    set x [expr {double(($i*17)%23)}]; set y [expr {double(($i*11)%19)}]; set z [expr {double(($i*7)%13)}]
    lappend triangles [::SolidSeam::shadowTriangleRecord [list $x $y $z] [list [expr {$x+1.0}] $y $z] [list $x [expr {$y+1.0}] $z]]
}
set tree [::SolidSeam::shadowBuildBVH $triangles]
for {set i 0} {$i < 30} {incr i} {
    set point [list [expr {double(($i*5)%29)}] [expr {double(($i*3)%17)}] [expr {double(($i*13)%31)}]]
    set brute 1.0e100
    foreach t $triangles {
        set d [::SolidSeam::pointTriangleDistance $point [lindex $t 3] [lindex $t 4] [lindex $t 5]]
        if {$d < $brute} { set brute $d }
    }
    assert {abs([::SolidSeam::shadowNearestFaceDistance $tree $point]-$brute) < 1.0e-9} "BVH result differs from brute force"
}
puts "PASS solid seam diagnostics checks"

