# Offline self-test for modules/mesh_add_washer.tcl (plain Tcl, no HyperMesh).
# Stubs the tiny ::HWFlow surface the module needs at load time, sources the
# module, and exercises the pure-logic procs: string array building, edge
# topology, chain extraction, closed-loop validation, parameter validation.
# Prints "SELFTEST OK" on success so the pytest wrapper can assert on it.
set scriptDir [file dirname [file normalize [info script]]]
set modulePath [file join [file dirname [file dirname $scriptDir]] mesh_add_washer.tcl]

namespace eval ::HWFlow {}
proc ::HWFlow::txt {zh en} { return $en }
proc ::HWFlow::componentIdByName {name} { return "" }
proc ::HWFlow::componentName {compId} { return "COMP_$compId" }
proc ::HWFlow::componentIds {markId} { return {} }

source $modulePath

set failures 0
proc expectEqual {actual expected label} {
    if {$actual eq $expected} {
        puts "PASS $label"
    } else {
        puts "FAIL $label\n  expected: $expected\n  actual:   $actual"
        incr ::failures
    }
}
proc expectError {script needle label} {
    if {[catch {uplevel 1 $script} err]} {
        if {[string first $needle $err] >= 0} {
            puts "PASS $label"
        } else {
            puts "FAIL $label (wrong error: $err)"
            incr ::failures
        }
    } else {
        puts "FAIL $label (no error raised)"
        incr ::failures
    }
}

# ---------------------------------------------------------------- string array
lassign [::WasherTool::buildWasherStringArray 12 {5.0 5.0}] strings count
expectEqual $count 2 "uniform 2-layer string count"
expectEqual $strings {{layer_number = 2 uniform_layers = 1 hole_density = 12} {1 5.0}} "uniform string array"

lassign [::WasherTool::buildWasherStringArray 12 {4.0 5.0 6.0}] strings3 count3
expectEqual $count3 4 "varying 3-layer string count"
expectEqual $strings3 {{layer_number = 3 uniform_layers = 0 hole_density = 12} {1 4.0} {1 5.0} {1 6.0}} "varying string array"

expectEqual [::WasherTool::formatWidth 5] "5.0" "formatWidth integer"
expectEqual [::WasherTool::formatWidth 4.5] "4.5" "formatWidth decimal"

# ---------------------------------------------------------------- topology
# Stub hm_nodelist with a synthetic connectivity table.
array set ::EDGE_CONN {}
proc hm_nodelist {elemId} {
    if {[info exists ::EDGE_CONN($elemId)]} { return $::EDGE_CONN($elemId) }
    return {}
}
proc buildLoopEdges {nodeCount} {
    set elems {}
    array unset ::EDGE_CONN
    for {set i 1} {$i <= $nodeCount} {incr i} {
        set j [expr {$i == $nodeCount ? 1 : $i + 1}]
        set eid [expr {1000 + $i}]
        lappend elems $eid
        set ::EDGE_CONN($eid) [list $i $j]
    }
    return $elems
}
proc buildOpenEdges {nodeCount} {
    set elems {}
    array unset ::EDGE_CONN
    for {set i 1} {$i < $nodeCount} {incr i} {
        set eid [expr {2000 + $i}]
        lappend elems $eid
        set ::EDGE_CONN($eid) [list $i [expr {$i + 1}]]
    }
    return $elems
}

# closed 16-node hole
set loopElems [buildLoopEdges 16]
lassign [::WasherTool::buildEdgeTopology $loopElems] e2n n2e
expectEqual [dict size $e2n] 16 "loop topology edge count"
lassign [::WasherTool::extractChainFromSeed 5 $e2n $n2e] chainEdges chainNodes
expectEqual [llength $chainNodes] 16 "closed loop node count"
expectEqual [llength $chainEdges] 16 "closed loop edge count"
expectEqual [::WasherTool::validateClosedLoop $chainNodes $chainEdges $n2e] 1 "closed loop accepted"

# open chain
set openElems [buildOpenEdges 8]
lassign [::WasherTool::buildEdgeTopology $openElems] e2nO n2eO
lassign [::WasherTool::extractChainFromSeed 3 $e2nO $n2eO] openEdges openNodes
expectError {::WasherTool::validateClosedLoop $openNodes $openEdges $n2eO} "not closed" "open edge rejected"

# branched chain: triangle 1-2-3-1 plus a spur 3-4
array unset ::EDGE_CONN
set spurElems {3001 3002 3003 3004}
set ::EDGE_CONN(3001) {1 2}
set ::EDGE_CONN(3002) {2 3}
set ::EDGE_CONN(3003) {3 1}
set ::EDGE_CONN(3004) {3 4}
lassign [::WasherTool::buildEdgeTopology $spurElems] e2nB n2eB
lassign [::WasherTool::extractChainFromSeed 1 $e2nB $n2eB] branchEdges branchNodes
expectEqual [llength $branchNodes] 4 "branched chain traversed fully"
expectError {::WasherTool::validateClosedLoop $branchNodes $branchEdges $n2eB} "branches" "branched chain rejected"

# seed not on any free edge
expectError {::WasherTool::extractChainFromSeed 99 $e2n $n2e} "not on a free edge" "interior seed rejected"

# two separate loops: chain must stay on the seed's loop
set loopA [buildLoopEdges 16]
set ::EDGE_CONN(5001) {101 102}
set ::EDGE_CONN(5002) {102 103}
set ::EDGE_CONN(5003) {103 104}
set ::EDGE_CONN(5004) {104 101}
lassign [::WasherTool::buildEdgeTopology [concat $loopA {5001 5002 5003 5004}]] e2nT n2eT
lassign [::WasherTool::extractChainFromSeed 2 $e2nT $n2eT] tEdges tNodes
expectEqual [llength $tNodes] 16 "second loop not pulled into the chain"

# ---------------------------------------------------------------- parameters
::WasherTool::validateParameters ;# defaults must pass
puts "PASS default parameters accepted"

set saved $::WasherTool::holeDensity
set ::WasherTool::holeDensity 3
expectError {::WasherTool::validateParameters} "holeDensity" "holeDensity < 4 rejected"
set ::WasherTool::holeDensity $saved
set savedWidths $::WasherTool::layerWidths
set ::WasherTool::layerWidths {}
expectError {::WasherTool::validateParameters} "layerWidths" "empty layerWidths rejected"
set ::WasherTool::layerWidths {5.0 -1.0}
expectError {::WasherTool::validateParameters} "width" "negative width rejected"
set ::WasherTool::layerWidths $savedWidths
set savedRigid $::WasherTool::createRigid
set ::WasherTool::createRigid 1
expectError {::WasherTool::validateParameters} "createRigid" "createRigid=1 rejected in v1"
set ::WasherTool::createRigid $savedRigid

puts "----"
if {$failures == 0} {
    puts "SELFTEST OK"
} else {
    puts "SELFTEST FAILED: $failures failure(s)"
    exit 1
}
