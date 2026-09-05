set directory [file dirname [info script]]
namespace eval ::SolidSeam { variable MODULE_DIR [file normalize [file join $::directory ..]] }
namespace eval ::HWFlow {}
proc ::HWFlow::txt {zh en} { return $en }
foreach name {logger auto_detect} {
    source -encoding utf-8 [file join $::SolidSeam::MODULE_DIR tcl $name.tcl]
}
proc assert {condition message} { if {![uplevel 1 [list expr $condition]]} { error $message } }
set version 1; set fail 0
proc hm_getvalue {entity selector field} {
    if {[string match user_ids=* $selector]} { error "Batch unsupported by this mock" }
    if {$selector eq "id=1"} { incr ::sourceQueries; return $::version }
    incr ::temporaryQueries
    return $::temporaryQueries
}
proc ::SolidSeam::nativeBoundaryDataImpl {component kind withEdges} {
    incr ::extractions
    assert {$withEdges} "First extraction omitted connectivity"
    return [dict create node_ids {1 2} faces {} edges {{1 2}}]
}
proc ::SolidSeam::detectSeamsImpl {source target settings} {
    set nodes [::SolidSeam::componentNodeIds $source]
    assert {[::SolidSeam::componentNodeIds $source] eq $nodes} "Source snapshot changed"
    set old [::SolidSeam::componentNodeIds 99]
    assert {[::SolidSeam::componentNodeIds 99] ne $old} "Reused temporary ID was cached"
    ::SolidSeam::nativeBoundaryData $source edges
    set graph [::SolidSeam::freeBoundaryGraph $source]
    assert {[::SolidSeam::freeBoundaryGraph $source] eq $graph} "Graph cache differs"
    if {$::fail} { error "injected failure" }
    return $nodes
}
foreach version {1 2} {
    set sourceQueries 0; set temporaryQueries 0; set extractions 0
    set result [::SolidSeam::autoDetectSeams 1 2 {automatic 1}]
    assert {$result == $version} "Stale data from previous detection"
    assert {$sourceQueries == 1 && $temporaryQueries == 2 && $extractions == 1} "Repeated native reads"
    assert {![array size ::SolidSeam::detectionReadCache] && !$::SolidSeam::detectionCacheActive} "Cache leaked after success"
}
set fail 1
assert {[catch {::SolidSeam::autoDetectSeams 1 2 {automatic 1}}]} "Error swallowed"
assert {![array size ::SolidSeam::detectionReadCache] && $::SolidSeam::detectionComponents eq {} && !$::SolidSeam::detectionCacheActive} "Cache leaked after error"
set version 3
assert {[::SolidSeam::componentNodeIds 1] == 3} "Read outside detection used cache"
set version 4
assert {[::SolidSeam::componentNodeIds 1] == 4} "Model edits were hidden"
puts "PASS detection cache checks"
