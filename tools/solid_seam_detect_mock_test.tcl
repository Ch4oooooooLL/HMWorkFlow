# Mock-based offline test for modules/solid_seam/tcl/auto_detect.tcl.
#
# Stubs the HyperMesh commands used by the detector (mark management,
# hm_getvalue) with synthetic shell/solid meshes and verifies the node
# finding rules of the solid seam module:
#   * node candidates come from the FIRST component only,
#   * only boundary (free edge) nodes are candidates,
#   * solid components use the boundary of the outer face that faces the
#     target, with pitch-adaptive bands so curved contact faces keep their
#     whole outline.
#
# Run with a plain Tcl 8.6 interpreter (no HyperMesh needed):
#   tclsh tools/solid_seam_detect_mock_test.tcl

set root [file dirname [file dirname [file normalize [info script]]]]

# ---------------------------------------------------------------------------
# HyperMesh command stubs
# ---------------------------------------------------------------------------
namespace eval ::M {
    array set nodeXYZ {}
    array set elemComp {}
    array set elemConfig {}
    array set elemNodes {}
    array set compName {}
    array set mark {}
    proc addNode {id x y z} { set ::M::nodeXYZ($id) [list $x $y $z] }
    proc addElem {id comp config nodes} {
        set ::M::elemComp($id) $comp
        set ::M::elemConfig($id) $config
        set ::M::elemNodes($id) $nodes
    }
}
proc *clearmark {type slot} { catch {unset ::M::mark($type,$slot)} }
proc *createmark {type slot args} {
    if {[lindex $args 0] eq "all"} {
        set ids {}
        if {$type eq "nodes"} { set ids [array names ::M::nodeXYZ] }
        if {$type eq "elems"} { set ids [array names ::M::elemComp] }
        set ::M::mark($type,$slot) [lsort -integer $ids]
        return
    }
    set compId [lindex $args 1]
    set ids {}
    if {$type eq "nodes"} {
        foreach e [array names ::M::elemComp] {
            if {$::M::elemComp($e) == $compId} {
                foreach n $::M::elemNodes($e) { lappend ids $n }
            }
        }
    } else {
        foreach e [array names ::M::elemComp] {
            if {$::M::elemComp($e) == $compId} { lappend ids $e }
        }
    }
    set ::M::mark($type,$slot) [lsort -integer -unique $ids]
}
proc hm_getmark {type slot} { return $::M::mark($type,$slot) }
proc hm_getvalue {args} {
    set entity [lindex $args 0]
    set id ""; set dataname ""
    foreach token [lrange $args 1 end] {
        set kv [split $token =]
        if {[llength $kv] == 2} {
            set k [lindex $kv 0]; set v [lindex $kv 1]
            if {$k eq "id"} { set id $v }
            if {$k eq "dataname"} { set dataname $v }
        }
    }
    switch -- $entity {
        nodes {
            if {$dataname eq "x"} { return [lindex $::M::nodeXYZ($id) 0] }
            if {$dataname eq "y"} { return [lindex $::M::nodeXYZ($id) 1] }
            if {$dataname eq "z"} { return [lindex $::M::nodeXYZ($id) 2] }
        }
        elems {
            if {$dataname eq "config"} { return $::M::elemConfig($id) }
            if {[string match node* $dataname]} {
                set i [string range $dataname 4 end]
                if {$i <= [llength $::M::elemNodes($id)]} {
                    return [lindex $::M::elemNodes($id) [expr {$i - 1}]]
                }
                return ""
            }
        }
        comps {
            if {$dataname eq "name"} { return $::M::compName($id) }
            if {$dataname in {nodes elements}} {
                set ids {}
                foreach element [array names ::M::elemComp] {
                    if {$::M::elemComp($element) != $id} { continue }
                    if {$dataname eq "nodes"} {
                        set ids [concat $ids $::M::elemNodes($element)]
                    } else { lappend ids $element }
                }
                return [lsort -integer -unique $ids]
            }
        }
    }
    error "unknown hm_getvalue: $args"
}

# ---------------------------------------------------------------------------
# Synthetic meshes
# ---------------------------------------------------------------------------
# S1 (comp 1): shell plate 3x2 quads, 10 mm mesh, z=0
::M::addNode 1001 0 0 0;    ::M::addNode 1002 10 0 0;  ::M::addNode 1003 20 0 0;  ::M::addNode 1004 30 0 0
::M::addNode 1005 0 10 0;   ::M::addNode 1006 10 10 0; ::M::addNode 1007 20 10 0; ::M::addNode 1008 30 10 0
::M::addNode 1009 0 20 0;   ::M::addNode 1010 10 20 0; ::M::addNode 1011 20 20 0; ::M::addNode 1012 30 20 0
::M::addElem 1 1 104 {1001 1002 1006 1005}
::M::addElem 2 1 104 {1002 1003 1007 1006}
::M::addElem 3 1 104 {1003 1004 1008 1007}
::M::addElem 4 1 104 {1005 1006 1010 1009}
::M::addElem 5 1 104 {1006 1007 1011 1010}
::M::addElem 6 1 104 {1007 1008 1012 1011}
set ::M::compName(1) "S1_SHELL_PLATE"

# V1 (comp 2): solid block 2x1x1 hexes, 10 mm mesh, z=0..10
::M::addNode 6001 0 0 0;   ::M::addNode 6002 10 0 0;  ::M::addNode 6003 10 10 0; ::M::addNode 6004 0 10 0
::M::addNode 6005 0 0 10;  ::M::addNode 6006 10 0 10; ::M::addNode 6007 10 10 10; ::M::addNode 6008 0 10 10
::M::addNode 6009 20 10 0; ::M::addNode 6010 20 0 0;  ::M::addNode 6011 20 10 10; ::M::addNode 6012 20 0 10
::M::addElem 23 2 208 {6001 6002 6003 6004 6005 6006 6007 6008}
::M::addElem 24 2 208 {6002 6010 6009 6003 6006 6012 6011 6007}
set ::M::compName(2) "V1_SOLID_BLOCK"

# T1 (comp 3): shell plate 3x2 quads at z=-3 (flat target under V1)
::M::addNode 2001 0 0 -3;   ::M::addNode 2002 10 0 -3; ::M::addNode 2003 20 0 -3; ::M::addNode 2004 30 0 -3
::M::addNode 2005 0 10 -3;  ::M::addNode 2006 10 10 -3; ::M::addNode 2007 20 10 -3; ::M::addNode 2008 30 10 -3
::M::addNode 2009 0 20 -3;  ::M::addNode 2010 10 20 -3; ::M::addNode 2011 20 20 -3; ::M::addNode 2012 30 20 -3
::M::addElem 7 3 104 {2001 2002 2006 2005}
::M::addElem 8 3 104 {2002 2003 2007 2006}
::M::addElem 9 3 104 {2003 2004 2008 2007}
::M::addElem 10 3 104 {2005 2006 2010 2009}
::M::addElem 11 3 104 {2006 2007 2011 2010}
::M::addElem 12 3 104 {2007 2008 2012 2011}
set ::M::compName(3) "T1_FLAT_TARGET"

# V2 (comp 4): solid block 3x1x1 hexes, 10 mm mesh, bottom face at z=0
::M::addNode 3001 0 0 0;   ::M::addNode 3002 0 10 0;  ::M::addNode 3003 0 0 10;  ::M::addNode 3004 0 10 10
::M::addNode 3005 10 0 0;  ::M::addNode 3006 10 10 0; ::M::addNode 3007 10 0 10;  ::M::addNode 3008 10 10 10
::M::addNode 3009 20 0 0;  ::M::addNode 3010 20 10 0; ::M::addNode 3011 20 0 10;  ::M::addNode 3012 20 10 10
::M::addNode 3013 30 0 0;  ::M::addNode 3014 30 10 0; ::M::addNode 3015 30 0 10;  ::M::addNode 3016 30 10 10
::M::addElem 13 4 208 {3001 3005 3006 3002 3003 3007 3008 3004}
::M::addElem 14 4 208 {3005 3009 3010 3006 3007 3011 3012 3008}
::M::addElem 15 4 208 {3009 3013 3014 3010 3011 3015 3016 3012}
set ::M::compName(4) "V2_SOLID_CURVED"

# T2 (comp 5): curved target, gap 3.0 + 0.1*x (3.0 .. 6.0 mm along x)
::M::addNode 4001 0 0 -3.0;   ::M::addNode 4002 10 0 -4.0;  ::M::addNode 4003 20 0 -5.0;  ::M::addNode 4004 30 0 -6.0
::M::addNode 4005 0 10 -3.0;  ::M::addNode 4006 10 10 -4.0; ::M::addNode 4007 20 10 -5.0;  ::M::addNode 4008 30 10 -6.0
::M::addElem 19 5 104 {4001 4002 4006 4005}
::M::addElem 20 5 104 {4002 4003 4007 4006}
::M::addElem 21 5 104 {4003 4004 4008 4007}
set ::M::compName(5) "T2_CURVED_TARGET"

# PYR (comp 6): single pyramid5 (config 205), base 10x10, apex at z=10
::M::addNode 5001 0 0 0; ::M::addNode 5002 10 0 0; ::M::addNode 5003 10 10 0; ::M::addNode 5004 0 10 0; ::M::addNode 5005 5 5 10
::M::addElem 22 6 205 {5001 5002 5003 5004 5005}
set ::M::compName(6) "PYR_PYRAMID"

# ---------------------------------------------------------------------------
# Load the module under test
# ---------------------------------------------------------------------------
source [file join $root modules solid_seam tcl auto_detect.tcl]

set ::pass 0; set ::fail 0
proc check {name expected got} {
    if {[string equal $expected $got]} {
        puts "PASS $name"
        incr ::pass
    } else {
        puts "FAIL $name expected=[list $expected] got=[list $got]"
        incr ::fail
    }
}

# --- rule 1: shells -> free edge (boundary) nodes only ---------------------
set shellBoundary [::SolidSeam::boundaryNodesOfComponent 1]
check "shell boundary = perimeter" {1001 1002 1003 1004 1005 1008 1009 1010 1011 1012} \
    $shellBoundary

# --- rule 2: solids -> silhouette (free edges of the body); the old count
# --- threshold of 1 returned {} for any pure solid comp
set solidBoundary [::SolidSeam::boundaryNodesOfComponent 2]
check "solid boundary = silhouette" {6001 6002 6003 6004 6005 6006 6007 6008 6009 6010 6011 6012} \
    $solidBoundary

# --- pyramid5 with the complete face set -> all edges counted twice
check "pyramid boundary = all nodes" {5001 5002 5003 5004 5005} \
    [::SolidSeam::boundaryNodesOfComponent 6]

# --- rule 3: solids -> boundary of the face closest to the target ----------
# V1 vs the flat target T1: closest face = bottom (z=0), its outline is the
# bottom ring.  (Side faces stay excluded: their rim nodes are a full pitch
# above the contact plane.)
check "flat solid facing boundary = bottom ring" {6001 6002 6003 6004 6009 6010} \
    [::SolidSeam::solidFacingBoundaryNodes 2 3]

# V2 vs the curved target T2: the bottom ring's gap varies 3.0-6.0 mm along
# the arc; the pitch-adaptive bands must keep the WHOLE bottom ring (the old
# fixed 0.01/1.0 bands kept only the first quad).
check "curved solid facing boundary = full bottom ring" {3001 3002 3005 3006 3009 3010 3013 3014} \
    [::SolidSeam::solidFacingBoundaryNodes 4 5]

# --- detectJunctionNodes with a solid source -------------------------------
set junctionPairs [::SolidSeam::detectJunctionNodes 2 3 15.0]
set junctionSources {}
foreach pair $junctionPairs { lappend junctionSources [lindex $pair 0] }
check "solid junction sources = closest face boundary only" \
    {6001 6002 6003 6004 6009 6010} [lsort -integer -unique $junctionSources]

# --- autoDetectSeams: nodes always from the FIRST component -----------------
# Source S1 (shell plate) + target V1 (solid block on top of it).  Every
# candidate node must be a boundary node of S1 (1001..), never a V1 node
# (6001..) and never an interior S1 node (1006/1007).
set settings [dict create \
    search_distance 15.0 max_search_distance 25.0 min_weld_length 10.0 \
    gap_jump_limit 5.0 default_width 6.0 default_spacing 6.0]
set candidates [::SolidSeam::autoDetectSeams 1 2 $settings]
set fromFirstComp 1
set boundaryOnly 1
set count 0
foreach candidate $candidates {
    incr count
    foreach n [dict get $candidate node_ids] {
        if {$n < 1001 || $n > 1012} { set fromFirstComp 0 }
        if {$n eq "1006" || $n eq "1007"} { set boundaryOnly 0 }
    }
}
check "first-comp rule: candidates non-empty and all nodes from comp 1" \
    [expr {$count > 0 ? "1" : "0"}] $fromFirstComp
check "first-comp rule: no interior source nodes" "1" $boundaryOnly

puts "\n$::pass passed, $::fail failed"
exit [expr {$::fail == 0 ? 0 : 1}]
