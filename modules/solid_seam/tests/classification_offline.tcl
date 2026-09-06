# Offline checks for solid seam-node classification: the dominant broad-face
# direction of plate-like solids, the seam patch ordering, T/L/B votes on
# solid normals, the chunky-solid degradation and the direction usability
# gate.  Runs in a plain Tcl interpreter against deterministic mocks.
set directory [file dirname [info script]]
namespace eval ::SolidSeam { variable MODULE_DIR [file normalize [file join $::directory ..]] }
namespace eval ::HWFlow {}
proc ::HWFlow::txt {zh en} { return $en }
foreach name {logger auto_detect auto_group} {
    source -encoding utf-8 [file join $::SolidSeam::MODULE_DIR tcl $name.tcl]
}
proc assert {condition message} { if {![uplevel 1 [list expr $condition]]} { error $message } }
proc axisAlign {vector axis} { return [expr {abs([::SolidSeam::vdot $vector $axis]) > 0.99}] }

# ---- thin wall (60 x 24 x 120, thin in Y) standing over a floor -----------
array set ::compNodes {
    1 {1 2 3 4 5 6 7 8}
    2 {11 12 13 14 15 16 17 18}
    3 {21 22 23 24 25 26 27 28}
    4 {41 42 43 44 45 46 47 48 49 50 51}
}
array set ::xyz {
    1 {0 0 26}   2 {60 0 26}   3 {60 24 26}   4 {0 24 26}
    5 {0 0 146}  6 {60 0 146}  7 {60 24 146}  8 {0 24 146}
    11 {0 0 0}    12 {150 0 0}  13 {150 60 0}  14 {0 60 0}
    15 {0 0 24}   16 {150 0 24} 17 {150 60 24} 18 {0 60 24}
    21 {0 0 0}   22 {30 0 0}   23 {30 30 0}   24 {0 30 0}
    25 {0 0 30}  26 {30 0 30}  27 {30 30 30}  28 {0 30 30}
    41 {0 0 0}   42 {100 0 0}  43 {100 40 0}  44 {0 40 0}
    45 {0 0 20}  46 {100 0 20} 47 {100 40 20} 48 {0 40 20}
    49 {20 10 10} 50 {30 10 10} 51 {30 10 18} 52 {20 10 18}
}
array set ::compFaces {
    1 {{1 2 6 5} {3 4 8 7} {1 4 3 2} {5 6 7 8} {2 3 7 6} {1 5 8 4}}
    2 {{11 12 13 14} {15 16 17 18} {11 12 16 15} {13 14 18 17} {12 13 17 16} {11 15 18 14}}
    3 {{21 22 23 24} {25 26 27 28} {21 22 26 25} {23 24 28 27} {22 23 27 26} {21 25 28 24}}
    4 {{41 42 46 45} {44 43 47 48} {41 42 43 44} {45 46 47 48} {41 44 48 45} {42 43 47 46} {49 50 51 52}}
}
array set ::compElements {1 {901 902} 2 {903 904} 3 {905 906} 4 {907 908}}
# comp 4 node map: 41..48 box corners (100 x 40 x 20, broad faces in Z),
# 49..52 an isolated Y-plane quad that only touches node 49 - the mid-face
# fallback case (its own normal is unaligned with the dominant axis).
set ::queries 0
proc hm_getvalue {entity selector field} {
    incr ::queries
    if {[string match dataname=* $field]} { set field [string range $field 9 end] }
    if {$entity eq "comps"} {
        scan $selector "id=%d" cid
        if {$field eq "nodes"} { return $::compNodes($cid) }
        if {$field eq "elements"} { return $::compElements($cid) }
        error "unsupported comps query $field"
    }
    if {$entity eq "elems"} {
        if {[string match user_ids=* $selector]} {
            set ids [string range $selector 9 end]
            if {$field eq "id"} { return $ids }
            if {$field eq "config"} {
                set values {}
                foreach id $ids { lappend values 208 }
                return $values
            }
        }
        error "unsupported elems query $selector $field"
    }
    if {$entity eq "nodes"} {
        if {[string match user_ids=* $selector]} {
            set ids [string range $selector 9 end]
            if {$field eq "id"} { return $ids }
            set axis [string index $field 0]
            set values {}
            foreach id $ids { lappend values [lindex $::xyz($id) [lsearch {x y z} $axis]] }
            return $values
        }
        scan $selector "id=%d" nid
        set axis [string index $field 0]
        return [lindex $::xyz($nid) [lsearch {x y z} $axis]]
    }
    error "unsupported query $entity $selector $field"
}
proc ::SolidSeam::nativeBoundaryData {componentId kind {withEdges 0}} {
    if {$kind eq "faces"} {
        return [dict create node_ids $::compNodes($componentId) faces $::compFaces($componentId) edges {}]
    }
    return ""
}

# ---- 1. dominant broad-face direction per component ------------------------
set wallStructure [::SolidSeam::solidExteriorStructure 1]
assert {[dict size $wallStructure] == 3} "Wall structure incomplete"
assert {[axisAlign [dict get $wallStructure dominant] {0 1 0}]} "Wall dominant axis is not the broad face"
set floorStructure [::SolidSeam::solidExteriorStructure 2]
assert {[axisAlign [dict get $floorStructure dominant] {0 0 1}]} "Floor dominant axis is not the broad face"
assert {[::SolidSeam::solidExteriorStructure 3] eq ""} "Chunky solid must degrade to no structure"

# ---- 2. seam patch leads with the dominant-aligned face --------------------
set patch [::SolidSeam::solidSeamPatch 1 1]
assert {[llength $patch] == 3} "Bottom corner node should see three faces"
assert {[axisAlign [dict get [lindex $patch 0] normal] {0 1 0}]} "Seam patch normal is not the broad face"
set floorPatch [::SolidSeam::solidSeamPatch 15 2]
assert {[axisAlign [dict get [lindex $floorPatch 0] normal] {0 0 1}]} "Floor seam patch normal is not the broad face"

# ---- 3. T / L / B votes from solid normals ---------------------------------
set tVote [::SolidSeam::automaticJointVote [dict get [lindex $patch 0] normal] \
    [dict get [lindex $floorPatch 0] normal] {0 0 -2} 6.0]
assert {$tVote eq "T"} "Perpendicular broad faces should vote T"
set lVote [::SolidSeam::automaticJointVote {0 0 -1} {0 0 1} {0 0 -2} 6.0]
assert {$lVote eq "L"} "Parallel plates with normal separation should vote L"
set bVote [::SolidSeam::automaticJointVote {0 0 1} {0 0 1} {1.5 0 0} 6.0]
assert {$bVote eq "B"} "Coplanar end faces should vote B"
set nativeVote [::SolidSeam::automaticJointVote {} {} {0 0 -2} 6.0]
assert {$nativeVote eq "NATIVE"} "Missing normals must keep the NATIVE fallback"

# ---- 3b. mid-face contact nodes fall back to the dominant normal ----------
set fallbackNormal [::SolidSeam::localShellNormal 49 4]
assert {[axisAlign $fallbackNormal {0 0 1}]} "Unaligned mid-face node must fall back to the dominant normal"
set alignedNormal [::SolidSeam::localShellNormal 41 4]
assert {[axisAlign $alignedNormal {0 0 1}]} "Broad-face node keeps its own normal"

# ---- 4. classification switch degrades to the legacy behaviour -------------
set ::SolidSeam::ui(automatic_solid_normals) 0
assert {[llength [::SolidSeam::localShellPatch 1 1]] == 0} "Switch-off must clear the solid patch"
set ::SolidSeam::ui(automatic_solid_normals) 1
assert {[llength [::SolidSeam::localShellPatch 1 1]] == 3} "Switch-on must restore the solid patch"

# ---- 5. direction usability gate -------------------------------------------
set debris [list [dict create node_ids {5 9}] [dict create node_ids {7 8}]]
set real [list [dict create node_ids {1 2 3 4}]]
set rows [::SolidSeam::groupUsableRows [concat $debris $real]]
assert {[llength $rows] == 1 && [dict get [lindex $rows 0] node_ids] eq {1 2 3 4}} "Usability gate kept debris"
assert {[llength [::SolidSeam::groupUsableRows $debris]] == 0} "Debris-only direction must stay empty"

puts "PASS classification checks"
