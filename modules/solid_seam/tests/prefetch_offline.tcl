# Offline checks for the batch connectivity prefetch, the transient ^faces
# ring reader and the component-scoped surface index.  Runs in a plain Tcl
# interpreter against a deterministic hm_getvalue mock.
set directory [file dirname [info script]]
namespace eval ::SolidSeam { variable MODULE_DIR [file normalize [file join $::directory ..]] }
namespace eval ::HWFlow {}
proc ::HWFlow::txt {zh en} { return $en }
foreach name {logger auto_detect auto_group} {
    source -encoding utf-8 [file join $::SolidSeam::MODULE_DIR tcl $name.tcl]
}
proc assert {condition message} { if {![uplevel 1 [list expr $condition]]} { error $message } }

# ---- deterministic mock of the HyperMesh database --------------------------
array set ::compElements {1 {11 12 13} 2 {21 22}}
array set ::compNodes {
    1 {101 102 103 104 105 106 107 108}
    2 {201 202 203 204 205 206 207 208 101 102 103 104}
}
array set ::elemNodes {
    11 {101 102 103 104} 12 {103 104 105 106} 13 {105 106 107 108}
    21 {201 202 203 204 205 206 207 208} 22 {204 205 206 207 101 102 103 104}
}
array set ::nodeXYZ {
    101 {0 0 0} 102 {6 0 0} 103 {6 6 0} 104 {0 6 0} 105 {12 6 0} 106 {12 0 0} 107 {18 0 0} 108 {18 6 0}
    201 {0 0 12} 202 {6 0 12} 203 {6 6 12} 204 {0 6 12} 205 {0 0 18} 206 {6 0 18} 207 {6 6 18} 208 {0 6 18}
}
set ::queries 0
proc hm_getvalue {entity selector field} {
    incr ::queries
    if {[string match dataname=* $field]} { set field [string range $field 9 end] }
    if {$entity eq "comps"} {
        scan $selector "id=%d" cid
        if {$field eq "elements"} { return $::compElements($cid) }
        if {$field eq "nodes"} { return $::compNodes($cid) }
        error "unsupported comps query $selector $field"
    }
    if {[string match user_ids=* $selector]} {
        set ids [string range $selector 9 end]
        if {$entity eq "nodes"} {
            if {$field eq "id"} { return $ids }
            set axis [string index $field 0]
            set values {}
            foreach id $ids { lappend values [lindex $::nodeXYZ($id) [lsearch {x y z} $axis]] }
            return $values
        }
        if {$entity eq "elems"} {
            if {$field eq "id"} { return $ids }
            scan $field "node%d" index
            set values {}
            foreach id $ids {
                lappend values [expr {[info exists ::elemNodes($id)] ? [lindex $::elemNodes($id) [expr {$index-1}]] : 0}]
            }
            return $values
        }
    }
    if {$entity eq "nodes"} {
        scan $selector "id=%d" nid
        set axis [string index $field 0]
        return [lindex $::nodeXYZ($nid) [lsearch {x y z} $axis]]
    }
    if {$entity eq "elems"} {
        scan $selector "id=%d" eid
        if {![info exists ::elemNodes($eid)]} { return 0 }
        scan $field "node%d" index
        return [lindex $::elemNodes($eid) [expr {$index-1}]]
    }
    error "unsupported query $entity $selector $field"
}

# ---- 1. batch prefetch fills the group cache, elementNodes goes quiet ------
::SolidSeam::beginGroupRecognitionCache {1 2}
set ::queries 0
::SolidSeam::prefetchComponentConnectivity {1 2}
assert {[info exists ::SolidSeam::groupElementNodes(11)]} "Prefetch did not fill the connectivity cache"
assert {[llength [::SolidSeam::elementNodes 21]] == 8} "Hexa connectivity was truncated"
set before $::queries
foreach eid {11 12 13 21 22} { ::SolidSeam::elementNodes $eid }
assert {$::queries == $before} "elementNodes issued queries after prefetch"
::SolidSeam::endGroupRecognitionCache

# ---- 2. transient ring reader matches the scalar reader, keeps order -------
set ids {22 21 13 11}
set batched [::SolidSeam::batchedElementRings $ids 8]
set i 0
foreach id $ids {
    assert {[::SolidSeam::elementNodesImpl $id] eq [lindex $batched $i]} "Ring mismatch for element $id"
    incr i
}
assert {![info exists ::SolidSeam::groupElementNodes(11)]} "Cache leaked outside a recognition scope"
rename hm_getvalue hm_getvalue_ok
proc hm_getvalue {entity selector field} {
    if {$entity eq "elems" && [string match user_ids=* $selector]} { error "batch unavailable" }
    return [hm_getvalue_ok $entity $selector $field]
}
set fallback [::SolidSeam::batchedElementRings $ids 8]
assert {$fallback eq $batched} "Scalar fallback differs from the batched read"
rename hm_getvalue {}
rename hm_getvalue_ok hm_getvalue

# ---- 3. transient ids never enter the stable-element cache -----------------
::SolidSeam::beginGroupRecognitionCache {1 2}
::SolidSeam::prefetchComponentConnectivity {1}
set rings [::SolidSeam::batchedElementRings {999} 8]
assert {[lindex $rings 0] eq {}} "Unknown element should yield an empty ring"
assert {![info exists ::SolidSeam::groupElementNodes(999)]} "Transient id leaked into the stable cache"
::SolidSeam::endGroupRecognitionCache

# ---- 4. surface index is built once per cache scope ------------------------
rename ::SolidSeam::spatialIndex surface_index_offline_orig
set ::treeBuilds 0
proc ::SolidSeam::spatialIndex {nodeIds} {
    incr ::treeBuilds
    return [surface_index_offline_orig $nodeIds]
}
::SolidSeam::beginGroupRecognitionCache {1 2}
lassign [::SolidSeam::surfaceNodeSpatialIndex 1 0] treeA nodesA
lassign [::SolidSeam::surfaceNodeSpatialIndex 1 0] treeB nodesB
assert {$treeB eq $treeA} "Surface index rebuilt inside one cache"
assert {$nodesA eq $nodesB && [llength $nodesA] == 8} "Surface node set is wrong"
assert {$::treeBuilds == 1} "spatialIndex ran more than once per cache"
::SolidSeam::endGroupRecognitionCache
assert {![array size ::SolidSeam::groupReadCache]} "Group cache leaked after end"

set ::treeBuilds 0
lassign [::SolidSeam::surfaceNodeSpatialIndex 1 0] treeC nodesC
lassign [::SolidSeam::surfaceNodeSpatialIndex 1 0] treeD nodesD
assert {$treeC eq $treeD} "Fresh builds of the same surface differ"
assert {$::treeBuilds == 2} "Index was cached without a recognition scope"

set ::SolidSeam::detectionCacheActive 1
set ::treeBuilds 0
lassign [::SolidSeam::surfaceNodeSpatialIndex 1 0] treeE nodesE
lassign [::SolidSeam::surfaceNodeSpatialIndex 1 0] treeF nodesF
assert {$::treeBuilds == 1 && $treeE eq $treeF} "Detection-level cache missed"
set ::SolidSeam::detectionCacheActive 0
array unset ::SolidSeam::detectionReadCache
rename ::SolidSeam::spatialIndex {}
rename surface_index_offline_orig ::SolidSeam::spatialIndex

puts "PASS prefetch checks"
