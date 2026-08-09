# Bisect the *imprint_nodelist hard-crash observed in the full audit probe.
# The module's own smoke test passes, so the crash must come from a model
# state difference.  Each case builds a fresh fixture and runs ONE imprint.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_mesh_seam_weld_imprint_repro.tcl
#   Results: runtime/audit_mesh_seam_weld_imprint_repro_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_mesh_seam_weld_imprint_repro_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

P "status" "STARTED"
P "version" $version

namespace eval ::MSWC {}
proc ::MSWC::comp {name color} {
    *collectorcreateonly components $name "" $color
    *currentcollector component $name
    return [hm_getvalue comps name=$name dataname=id]
}
proc ::MSWC::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc ::MSWC::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}

# Baseline fixture identical to the module smoke test (3x3 plane + wall).
proc ::MSWC::buildPlane {size wall sharedExtra} {
    set compTarget [::MSWC::comp MSWC_TARGET 11]
    array unset pn
    array set pn {}
    for {set i 0} {$i <= $size} {incr i} {
        for {set j 0} {$j <= $size} {incr j} {
            set pn($i,$j) [::MSWC::node [expr {$i * 10}] [expr {$j * 10}] 0]
        }
    }
    set targetElems {}
    for {set i 0} {$i < $size} {incr i} {
        for {set j 0} {$j < $size} {incr j} {
            lappend targetElems [::MSWC::quad [list \
                $pn($i,$j) $pn([expr {$i+1}],$j) \
                $pn([expr {$i+1}],[expr {$j+1}]) $pn($i,[expr {$j+1}])]]
        }
    }
    set wallElems {}
    if {$wall} {
        set compWall [::MSWC::comp MSWC_WALL 22]
        set line [expr {int($size/2) * 10}]
        for {set j 0} {$j < $size} {incr j} {
            set wb0 [::MSWC::node $line [expr {$j * 10}] -10]
            set wb1 [::MSWC::node $line [expr {($j + 1) * 10}] -10]
            lappend wallElems [::MSWC::quad [list \
                $pn([expr {$line/10}],$j) $pn([expr {$line/10}],[expr {$j+1}]) $wb1 $wb0]]
        }
    }
    if {$sharedExtra} {
        # Duplicate nodes at existing plane locations (as the CLS section
        # of the full probe created before the imprint section).
        ::MSWC::node 0 0 0
        ::MSWC::node [expr {$size * 10}] 0 0
        ::MSWC::node [expr {$size * 10}] [expr {$size * 10}] 0
    }
    set sourceNodes {}
    set compSource [::MSWC::comp MSWC_SOURCE 33]
    set half [expr {$size * 10 - 3}]
    foreach xyz [list [list 3 3 8] [list $half 3 8] [list $half $half 8] [list 3 $half 8]] {
        lappend sourceNodes [::MSWC::node {*}$xyz]
    }
    return [list $compTarget $targetElems $sourceNodes]
}

proc ::MSWC::runCase {tag size wall sharedExtra options closeNodeList} {
    set fixture [::MSWC::buildPlane $size $wall $sharedExtra]
    set compTarget [lindex $fixture 0]
    set targetElems [lindex $fixture 1]
    set sourceNodes [lindex $fixture 2]
    catch {*clearmark nodes 1}
    *createmark nodes 1 all
    set totalNodes [llength [hm_getmark nodes 1]]
    *clearmark nodes 1
    P "${tag}_TOTAL_NODES" $totalNodes
    catch {*clearlist nodes 1}
    catch {*clearlist nodes 2}
    catch {*clearmark elems 2}
    catch {*clearmark elements 2}
    if {[catch {eval *createlist nodes 1 $sourceNodes} lErr]} {
        P "${tag}_PREP_ERROR" $lErr
        return
    }
    if {[catch {eval *createmark elements 2 $targetElems} mErr]} {
        P "${tag}_PREP_MARK_ERROR" $mErr
        return
    }
    set preMax 0
    catch {set preMax [hm_latestentityid nodes]}
    P "${tag}_PRE_MAX_NODE" $preMax
    P "${tag}_CALL" "*imprint_nodelist 1 elements 2 $options"
    if {[catch {*imprint_nodelist 1 elements 2 $options} iErr]} {
        P "${tag}_ERROR" $iErr
    } else {
        P "${tag}_OK" 1
        set list2 {}
        catch {set list2 [hm_getlist nodes 2]}
        P "${tag}_LIST2_COUNT" [llength $list2]
        P "${tag}_LIST2" [join $list2 { }]
    }
}

set optOpen "remain 3 to_dest_component 0 remesh_layers 2 remesh_mode 2 angle 30.000000 create_joint_elems 0 close_node_list 0"
set optClosed "remain 3 to_dest_component 0 remesh_layers 2 remesh_mode 2 angle 30.000000 create_joint_elems 0 close_node_list 1"

# Run a single case selected by the MSW_CASE environment variable so each
# case starts from a fresh session (a hard crash cannot poison the others).
set caseSelector [expr {[info exists env(MSW_CASE)] ? $env(MSW_CASE) : "1"}]
P "SELECTED_CASE" $caseSelector
switch -- $caseSelector {
    1 { ::MSWC::runCase "CASE1_BASELINE_OPEN"    3 1 0 $optOpen 0 }
    2 { ::MSWC::runCase "CASE2_BASELINE_CLOSED"  3 1 0 $optClosed 1 }
    3 { ::MSWC::runCase "CASE3_DUPNODES_OPEN"    3 1 1 $optOpen 0 }
    4 { ::MSWC::runCase "CASE4_SIZE4_OPEN"       4 1 0 $optOpen 0 }
    5 { ::MSWC::runCase "CASE5_NOWALL_OPEN"      3 0 0 $optOpen 0 }
    6 { ::MSWC::runCase "CASE6_CLOSED_NO_WALL"   3 0 0 $optClosed 1 }
    default { P "UNKNOWN_CASE" $caseSelector }
}

P "status" "DONE"
close $channel
exit 0
