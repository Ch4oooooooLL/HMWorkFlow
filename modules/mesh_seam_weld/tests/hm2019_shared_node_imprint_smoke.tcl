# HyperMesh 2019 batch smoke test for the fast pre-imprint rejection of a
# planar target whose projected seed nodes are shared with a non-coplanar
# shell component.
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
    foreach xyz {{10 0 8} {10 10 8} {10 20 8}} {
        lappend sourceNodes [::SharedNodeSmoke::node {*}$xyz]
    }

    set prepared [::MeshSeamWeld::prepareCurrentTargetPatch \
        $sourceNodes [list $targetComp] 0]
    set markedTargets [dict get $prepared shared_external_elements]
    set sharedExternalCount [llength $markedTargets]
    set totalCount [llength [dict get $prepared target_elements]]
    set mode skipped_shared_node_topology
    set wallDetected 0
    foreach wallElem $wallElems {
        if {[lsearch -exact $markedTargets $wallElem] >= 0} {
            set wallDetected 1
            break
        }
    }
    if {!$wallDetected || $sharedExternalCount < 1} {
        error "Expected at least one non-coplanar wall element in fast diagnostics"
    }
    foreach elemId [dict get $prepared target_elements] {
        if {[lsearch -exact $wallElems $elemId] >= 0} {
            error "External wall element $elemId leaked into the target-component patch"
        }
    }
    ::HybridCore::closeLog
    return "target_component=$targetComp wall_component=$wallComp\ntarget_elements=$totalCount shared_external_elements=$sharedExternalCount\nmode=$mode"
}

set code [catch {runSharedNodeImprintSmoke $root $outputDir} details options]
if {$code != 0} {
    catch {::HybridCore::closeLog}
    writeSharedNodeReport $reportPath FAIL $details
    return -options $options $details
}
writeSharedNodeReport $reportPath PASS $details
