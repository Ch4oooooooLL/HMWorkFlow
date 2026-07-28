# HyperMesh 2019 batch smoke test for a local imprint whose planar target
# shares nodes with a non-coplanar shell component.
#
# Run with:
#   hmbatch.exe -tcl hm2019_shared_node_imprint_smoke.tcl

set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
set outputDir [file join $root runtime tasks mesh_seam_weld shared_node_smoke]
file mkdir $outputDir
set reportPath [file join $outputDir hm2019_shared_node_imprint_smoke.txt]

proc writeSharedNodeReport {path status details} {
    set channel [open $path w]
    puts $channel "status=$status"
    puts $channel $details
    close $channel
}

namespace eval ::SharedNodeSmoke {}
proc ::SharedNodeSmoke::component {name color} {
    *collectorcreateonly components $name "" $color
    set id [hm_getvalue comps name=$name dataname=id]
    *currentcollector component $name
    return $id
}
proc ::SharedNodeSmoke::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc ::SharedNodeSmoke::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}

proc runSharedNodeImprintSmoke {root outputDir} {
    source [file join $root modules mesh_seam_weld.tcl]
    ::HybridCore::openLog [file join $outputDir operation.log]

    set targetComp [::SharedNodeSmoke::component SHARED_NODE_TARGET 11]
    array set planeNode {}
    foreach x {0 10 20} {
        foreach y {0 10 20} {
            set planeNode($x,$y) [::SharedNodeSmoke::node $x $y 0]
        }
    }
    set targetElems {}
    foreach x0 {0 10} x1 {10 20} {
        foreach y0 {0 10} y1 {10 20} {
            lappend targetElems [::SharedNodeSmoke::quad [list \
                $planeNode($x0,$y0) $planeNode($x1,$y0) \
                $planeNode($x1,$y1) $planeNode($x0,$y1)]]
        }
    }

    # This vertical wall is deliberately a different component and shares the
    # complete x=10 node line with the planar target.
    set wallComp [::SharedNodeSmoke::component SHARED_NODE_WALL 22]
    set wallBottom0 [::SharedNodeSmoke::node 10 0 -10]
    set wallBottom1 [::SharedNodeSmoke::node 10 10 -10]
    set wallBottom2 [::SharedNodeSmoke::node 10 20 -10]
    set wallElems [list \
        [::SharedNodeSmoke::quad [list $planeNode(10,0) $planeNode(10,10) $wallBottom1 $wallBottom0]] \
        [::SharedNodeSmoke::quad [list $planeNode(10,10) $planeNode(10,20) $wallBottom2 $wallBottom1]]]

    ::SharedNodeSmoke::component SHARED_NODE_SOURCE 33
    set sourceNodes {}
    foreach xyz {{3 3 8} {17 3 8} {17 17 8} {3 17 8}} {
        lappend sourceNodes [::SharedNodeSmoke::node {*}$xyz]
    }

    ::MeshSeamWeld::runImprintNodeList \
        $sourceNodes [list $targetComp] 1 $targetElems
    set sharedExternalCount $::MeshSeamWeld::lastImprintSharedNeighborElemCount
    set totalCount $::MeshSeamWeld::lastImprintTargetElemCount
    set mode $::MeshSeamWeld::lastImprintTargetMode
    set markedTargets {}
    catch {set markedTargets [hm_getmark elements 2]}
    if {[llength $markedTargets] == 0} {
        catch {set markedTargets [hm_getmark elems 2]}
    }
    foreach wallElem $wallElems {
        if {[lsearch -exact $markedTargets $wallElem] >= 0} {
            error "Non-coplanar wall element $wallElem was incorrectly added to the Mesh Edit Elements input"
        }
    }
    if {$sharedExternalCount < [llength $wallElems]} {
        error "Expected both non-coplanar wall elements in diagnostics; got $sharedExternalCount"
    }
    if {$mode ne "local_elements"} {
        error "Expected local target-elements imprint mode, got $mode"
    }
    ::HybridCore::closeLog
    return "target_component=$targetComp wall_component=$wallComp\ncore_elements=[llength $targetElems] shared_external_elements=$sharedExternalCount total_imprint_elements=$totalCount\nmode=$mode"
}

set code [catch {runSharedNodeImprintSmoke $root $outputDir} details options]
if {$code != 0} {
    catch {::HybridCore::closeLog}
    writeSharedNodeReport $reportPath FAIL $details
    return -options $options $details
}
writeSharedNodeReport $reportPath PASS $details
