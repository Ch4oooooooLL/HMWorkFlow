# Bisect which earlier probe section poisons the session so that a later
# *imprint_nodelist call hard-crashes it.  MSW_LEVEL selects how much of the
# pre-imprint workload runs (0=imprint only, 1=+closestnode flag tests,
# 2=+duplicate-node fixture, 3=+queries on main fixture).
#
#   MSW_LEVEL=n hmbatch.exe -nocommand -nouserprofiledialog \
#       -tcl tools/audit_mesh_seam_weld_imprint_bisect.tcl
#   Results: runtime/audit_mesh_seam_weld_imprint_bisect_<version>_<level>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set level [expr {[info exists env(MSW_LEVEL)] ? $env(MSW_LEVEL) : 0}]
set reportPath [file join $outputDir "audit_mesh_seam_weld_imprint_bisect_${version}_${level}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

P "status" "STARTED"
P "version" $version
P "level" $level

namespace eval ::MSWD {}
proc ::MSWD::comp {name color} {
    *collectorcreateonly components $name "" $color
    *currentcollector component $name
    return [hm_getvalue comps name=$name dataname=id]
}
proc ::MSWD::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc ::MSWD::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}

set compTarget [::MSWD::comp MSWD_TARGET 11]
array set tn {}
foreach x {0 10 20 30} {
    foreach y {0 10 20 30} {
        set tn($x,$y) [::MSWD::node $x $y 0]
    }
}
set targetElems {}
foreach x0 {0 10 20} x1 {10 20 30} {
    foreach y0 {0 10 20} y1 {10 20 30} {
        lappend targetElems [::MSWD::quad [list \
            $tn($x0,$y0) $tn($x1,$y0) $tn($x1,$y1) $tn($x0,$y1)]]
    }
}
set sourceNodes {}
foreach xyz {{5 5 10} {25 5 10} {25 25 10} {5 25 10}} {
    lappend sourceNodes [::MSWD::node {*}$xyz]
}
P "PRE_TOTAL_NODES" [llength [hm_getmark nodes 1]]
foreach x {0 10 20 30} {
    foreach y {0 10 20 30} {
        P "PN_$x,$y=$tn($x,$y)" [join [hm_nodevalue $tn($x,$y)] { }]
    }
}
P "SRC_IDS" [join $sourceNodes { }]
foreach n $sourceNodes {
    P "SRC_$n" [join [hm_nodevalue $n] { }]
}
catch {*createmark nodes 1 all}
set allIds [hm_getmark nodes 1]
catch {*clearmark nodes 1}
foreach n $allIds {
    P "ALL_$n" [join [hm_nodevalue $n] { }]
}

if {$level >= 1} {
    # Exact-module-style closestnode calls first: query AT a source node with
    # the source nodes marked (the module's targetNodesFromClosestQuery).
    catch {*clearmark nodes 1}
    eval *createmark nodes 1 $sourceNodes
    foreach {tag args} {
        "CLS_AT_SRC_F1"  {5.0 5.0 10.0 1 1}
        "CLS_AT_SRC_F0"  {5.0 5.0 10.0 1 0}
        "CLS_AT_SRC_F2"  {5.0 5.0 10.0 1 2}
        "CLS_MID_F1"     {15.0 15.0 10.0 1 1}
    } {
        if {[catch {set c [eval hm_getclosestnode $args]} cErr]} {
            P "${tag}_ERROR" $cErr
        } else {
            P "${tag}" $c
            P "${tag}_IS_SOURCE" [expr {[lsearch -exact $sourceNodes $c] >= 0}]
            set cv {}
            catch {set cv [hm_nodevalue $c]}
            P "${tag}_XYZ" [join $cv { }]
        }
    }
    catch {*clearmark nodes 1}
}

if {$level >= 2} {
    # Duplicate nodes at existing locations (like the old CLS fixture).
    set na [::MSWD::node 10 0 0]
    set nb [::MSWD::node 12 0 0]
    set nc [::MSWD::node 20 0 0]
    catch {*clearmark nodes 1}
    catch {*clearmark nodes 2}
    foreach {tag args} {
        "CLS2_NOMARK"    {11.0 0.0 0.0}
        "CLS2_F0"        {11.0 0.0 0.0 1 0}
        "CLS2_F1"        {11.0 0.0 0.0 1 1}
        "CLS2_F2"        {11.0 0.0 0.0 1 2}
        "CLS2_MARK2_F1"  {11.0 0.0 0.0 2 1}
    } {
        eval *createmark nodes 1 $na $nc
        eval *createmark nodes 2 $na $nb
        if {[catch {set c [eval hm_getclosestnode $args]} cErr]} {
            P "${tag}_ERROR" $cErr
        } else {
            P "${tag}" $c
        }
        catch {*clearmark nodes 1}
        catch {*clearmark nodes 2}
    }
    P "CLS2_DUP_IDS" "$na $nb $nc"
}

if {$level >= 4} {
    # The distinctive call from the full probe: query point lies ON a node
    # that is inside the exclusion mark (returned 0 there).
    catch {*clearmark nodes 1}
    catch {*clearmark nodes 2}
    eval *createmark nodes 2 [list $tn(20,0) $tn(20,10) $tn(20,20) $tn(20,30)]
    if {[catch {set c [hm_getclosestnode 20.0 10.0 0.0 2 1]} cErr]} {
        P "CLS4_ON_MARKNODE_ERROR" $cErr
    } else {
        P "CLS4_ON_MARKNODE" $c
    }
    catch {*clearmark nodes 1}
    catch {*clearmark nodes 2}
    # and the plain-node mark style
    catch {*clearmark nodes 1}
    eval *createmark nodes 1 [list $tn(10,10)]
    if {[catch {set c [hm_getclosestnode 10.0 10.0 0.0 1 1]} cErr]} {
        P "CLS4_SINGLE_MARK_ERROR" $cErr
    } else {
        P "CLS4_SINGLE_MARK" $c
    }
    catch {*clearmark nodes 1}
}

if {$level >= 3} {
    # The remaining query functions from the full probe.
    set probeNode [lindex $sourceNodes 0]
    catch {set nv [hm_nodevalue $probeNode]}
    P "NODEVALUE" $nv
    catch {set nl [hm_nodelist [lindex $targetElems 0]]}
    P "NODELIST" $nl
    catch {set id [hm_latestentityid nodes]}
    P "LATEST" $id
    catch {*clearmark elems 2}
    catch {eval hm_createmark elems 2 [list "by node id"] [list $tn(10,10)]}
    set m {}
    catch {set m [hm_getmark elems 2]}
    P "HM_CREATEMARK" [join $m { }]
    catch {*clearmark elems 2}
}

# --- imprint ----------------------------------------------------------------
set options "remain 3 to_dest_component 0 remesh_layers 2 remesh_mode 2 angle 30.000000 create_joint_elems 0 close_node_list 1"
proc ::MSWD::runImprint {tag} {
    global sourceNodes targetElems options
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
    if {[catch {*imprint_nodelist 1 elements 2 $options} iErr]} {
        P "${tag}_ERROR" $iErr
    } else {
        P "${tag}_OK" 1
        set preMax 0
        catch {set preMax [hm_latestentityid nodes]}
        P "${tag}_MAX_NODE_AFTER" $preMax
        foreach li {0 1 2 3} {
            set lv {}
            catch {set lv [hm_getlist nodes $li]}
            P "${tag}_LIST${li}_COUNT" [llength $lv]
            P "${tag}_LIST${li}" [join $lv { }]
        }
        foreach mi {1 2} {
            set mv {}
            catch {*createmark nodes $mi all}
            set mv {}
            catch {set mv [hm_getmark nodes $mi]}
            P "${tag}_MARK${mi}_IS_ALL" [expr {[llength $mv] > 0}]
            catch {*clearmark nodes $mi}
        }
    }
}

proc ::MSWD::rebuildFixture {} {
    # Recreate the whole fixture on top of the current model state.
    global sourceNodes targetElems
    set sourceNodes {}
    set targetElems {}
    set newPlane {}
    foreach x {0 10 20 30} {
        foreach y {0 10 20 30} {
            lappend newPlane [::MSWD::node $x $y 0]
        }
    }
    for {set i 0} {$i < 3} {incr i} {
        for {set j 0} {$j < 3} {incr j} {
            lappend targetElems [::MSWD::quad [list \
                [lindex $newPlane [expr {$i*4+$j}]] \
                [lindex $newPlane [expr {$i*4+$j+1}]] \
                [lindex $newPlane [expr {($i+1)*4+$j+1}]] \
                [lindex $newPlane [expr {($i+1)*4+$j}]]]]
        }
    }
    foreach xyz {{5 5 10} {25 5 10} {25 25 10} {5 25 10}} {
        lappend sourceNodes [::MSWD::node {*}$xyz]
    }
    P "REBUILD_DONE_MAX" [::MSWD::node 99 99 99]
}

switch -- $level {
    5 {
        ::MSWD::runImprint "IMP1"
        ::MSWD::rebuildFixture
        P "REBUILD_OK" 1
        ::MSWD::runImprint "IMP2"
    }
    6 {
        # no imprint first: just rebuild, then imprint
        ::MSWD::rebuildFixture
        P "REBUILD_OK" 1
        ::MSWD::runImprint "IMP_AFTER_REBUILD"
    }
    7 {
        # full-probe pattern: build fixture, rebuild a second fixture, then imprint
        ::MSWD::rebuildFixture
        P "REBUILD_OK" 1
        ::MSWD::runImprint "IMP_AFTER_REBUILD"
    }
    default {
        ::MSWD::runImprint "IMPRINT"
    }
}

P "status" "DONE"
close $channel
exit 0
