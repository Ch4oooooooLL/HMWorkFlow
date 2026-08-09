# Audit probe for modules/mesh_seam_weld native HyperMesh commands (part 2):
# the native ruled-surface automesh chain and the element remesh alternatives.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_mesh_seam_weld_automesh.tcl
#
# Results: runtime/audit_mesh_seam_weld_automesh_<version>.log (ASCII KEY=VALUE)

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_mesh_seam_weld_automesh_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

P "status" "STARTED"
P "version" $version

namespace eval ::MSWA2 {}
proc ::MSWA2::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc ::MSWA2::comp {name color} {
    *collectorcreateonly components $name "" $color
    *currentcollector component $name
    set id [hm_getvalue comps name=$name dataname=id]
    return $id
}
proc ::MSWA2::surfCount {} {
    if {[catch {*createmark surfs 1 all} e]} { return "MARK_ERR" }
    set s {}
    catch {set s [hm_getmark surfs 1]}
    catch {*clearmark surfs 1}
    return [llength $s]
}
proc ::MSWA2::elemCount {} {
    if {[catch {*createmark elems 1 all} e]} { return "MARK_ERR" }
    set s {}
    catch {set s [hm_getmark elems 1]}
    catch {*clearmark elems 1}
    return [llength $s]
}
proc ::MSWA2::totalNodes {} {
    if {[catch {*createmark nodes 1 all} e]} { return "MARK_ERR" }
    set s {}
    catch {set s [hm_getmark nodes 1]}
    catch {*clearmark nodes 1}
    return [llength $s]
}

set compWeld [::MSWA2::comp MSWA2_WELD 11]

# Two parallel node chains: 5 nodes each at z=0 and z=10, 10 apart.
set chainA {}
set chainB {}
foreach i {0 1 2 3 4} {
    set x [expr {$i * 10}]
    lappend chainA [::MSWA2::node $x 0 0]
    lappend chainB [::MSWA2::node $x 0 10]
}
P "PRE_SURF_COUNT" [::MSWA2::surfCount]
P "PRE_ELEM_COUNT" [::MSWA2::elemCount]

# --- 1. surfacemode + linearsurfacebetweennodes ----------------------------
if {[catch {*surfacemode 2} smErr]} {
    P "SURFACEMODE_2_ERROR" $smErr
} else {
    P "SURFACEMODE_2_OK" 1
}
catch {*clearlist nodes 1}
catch {*clearlist nodes 2}
eval *createlist nodes 1 $chainA
eval *createlist nodes 2 $chainB
if {[catch {*linearsurfacebetweennodes 1 2 1} lsErr]} {
    P "LINEARSURF_ERROR" $lsErr
} else {
    P "LINEARSURF_OK" 1
}
P "SURF_COUNT_AFTER_RULED" [::MSWA2::surfCount]
P "ELEM_COUNT_AFTER_RULED" [::MSWA2::elemCount]

# --- 2. Mesh face/edge params (module defaults) ----------------------------
if {[catch {*set_meshfaceparams 0 1 2 0 0 1 0.5 1 1} mfErr]} {
    P "SET_MESHFACEPARAMS_ERROR" $mfErr
} else {
    P "SET_MESHFACEPARAMS_OK" 1
}
set density 4
set meshSize 8.0
foreach edge {0 1 2 3} {
    # Module style: density as element count, everything else default.
    if {[catch {*set_meshedgeparams $edge $density 1 0 0 0 0 0 0} meErr]} {
        P "SET_MESHEDGEPARAMS_${edge}_ERROR" $meErr
    } else {
        P "SET_MESHEDGEPARAMS_${edge}_OK" 1
    }
}

# --- 3. automesh: module call *automesh 0 1 2 ------------------------------
if {[catch {*automesh 0 1 2} amErr]} {
    P "AUTOMESH_MODULE_CALL_ERROR" $amErr
} else {
    P "AUTOMESH_MODULE_CALL_OK" 1
    P "ELEM_COUNT_AFTER_AUTOMESH" [::MSWA2::elemCount]
    P "SURF_COUNT_AFTER_AUTOMESH" [::MSWA2::surfCount]
    set cfgCounts [list]
    catch {
        *createmark elems 1 all
        foreach eid [hm_getmark elems 1] {
            lappend cfgCounts [hm_getvalue elems id=$eid dataname=config]
        }
    }
    set cfg103 0; set cfg104 0; set other 0
    foreach c $cfgCounts {
        if {$c eq "103"} { incr cfg103 } elseif {$c eq "104"} { incr cfg104 } else { incr other }
    }
    P "AUTOMESH_TRIA3_COUNT" $cfg103
    P "AUTOMESH_QUAD4_COUNT" $cfg104
    P "AUTOMESH_OTHER_CONFIG_COUNT" $other
}
if {[catch {*storemeshtodatabase 0} smErr]} {
    P "STOREMESH_ERROR" $smErr
} else {
    P "STOREMESH_OK" 1
}
P "ELEM_COUNT_AFTER_STORE" [::MSWA2::elemCount]
P "SURF_COUNT_AFTER_STORE" [::MSWA2::surfCount]
if {[catch {*ameshclearsurface} acErr]} {
    P "AMESHCLEARSURFACE_ERROR" $acErr
} else {
    P "AMESHCLEARSURFACE_OK" 1
}
P "SURF_COUNT_AFTER_CLEAR" [::MSWA2::surfCount]

# --- 4. rejectmesh existence and no-op safety ------------------------------
if {[catch {*rejectmesh 0} rjErr]} {
    P "REJECTMESH_ERROR" $rjErr
} else {
    P "REJECTMESH_OK" 1
}

# --- 5. element remesh alternatives -----------------------------------------
# a) *interactiveremeshelems (module's possible alternative)
P "EXISTS interactiveremeshelems" [expr {[info commands *interactiveremeshelems] ne ""}]
P "EXISTS defaultremeshelems" [expr {[info commands *defaultremeshelems] ne ""}]
P "EXISTS remeshelems" [expr {[info commands *remeshelems] ne ""}]
# b) remesh the welded strip with vendor-style *defaultremeshelems
set weldElems {}
catch {
    *createmark elems 1 "by comp" $compWeld
    set weldElems [hm_getmark elems 1]
    *clearmark elems 1
}
P "WELD_ELEMS_BEFORE_REMESH" [join $weldElems { }]
if {[llength $weldElems] > 0} {
    catch {*clearmark elems 1}
    eval *createmark elems 1 $weldElems
    set beforeNodes [::MSWA2::totalNodes]
    # vendor signature: *defaultremeshelems markid elemsize 2 2 1 1 1 1 0 0 0 0 0 30
    if {[catch {*defaultremeshelems 1 8.0 2 2 1 1 1 1 0.0 0.0 0.0 0.0 0 30} drErr]} {
        P "DEFAULTREMESHELEMS_ERROR" $drErr
    } else {
        P "DEFAULTREMESHELEMS_OK" 1
        P "NODE_COUNT_DELTA_AFTER_DEFAULT_REMESH" [expr {[::MSWA2::totalNodes] - $beforeNodes}]
        set afterElems {}
        catch {
            *createmark elems 1 "by comp" $compWeld
            set afterElems [hm_getmark elems 1]
            *clearmark elems 1
        }
        P "WELD_ELEMS_AFTER_DEFAULT_REMESH" [join $afterElems { }]
    }
    # c) *interactiveremeshelems on the current weld patch (fresh IDs)
    set currentWeld {}
    catch {
        *clearmark elems 1
        *createmark elems 1 "by comp" $compWeld
        set currentWeld [hm_getmark elems 1]
        *clearmark elems 1
    }
    P "INTERACTIVEREMESHELEMS_INPUT" [join $currentWeld { }]
    if {[llength $currentWeld] > 0} {
        eval *createmark elems 1 $currentWeld
        if {[catch {*interactiveremeshelems 1 8.0 2 2 2 1 1} irErr]} {
            P "INTERACTIVEREMESHELEMS_ERROR" $irErr
        } else {
            P "INTERACTIVEREMESHELEMS_OK" 1
            set afterElems2 {}
            catch {
                *clearmark elems 1
                *createmark elems 1 "by comp" $compWeld
                set afterElems2 [hm_getmark elems 1]
                *clearmark elems 1
            }
            P "WELD_ELEMS_AFTER_INTERACTIVE_REMESH" [join $afterElems2 { }]
        }
    }
}

P "status" "DONE"
close $channel
exit 0
