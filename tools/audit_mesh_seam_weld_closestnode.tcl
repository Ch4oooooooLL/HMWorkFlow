# Audit probe: hm_getclosestnode semantics in batch (HM 2019 / 2022).
#
# The module calls hm_getclosestnode x y z 1 1 (mark 1 = source nodes, i.e.
# exclusion mark) and hm_getclosestnode x y z 1 2.  A previous probe found
# results that were NOT the nearest node.  This probe prints the COORDINATES
# of the returned node so the actual behavior can be identified.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_mesh_seam_weld_closestnode.tcl
#   Results: runtime/audit_mesh_seam_weld_closestnode_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set caseSel [expr {[info exists env(CLS_CASE)] ? $env(CLS_CASE) : "1"}]
set withWall [expr {[info exists env(CLS_WALL)] ? $env(CLS_WALL) : 1}]
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_mesh_seam_weld_closestnode_${version}_c${caseSel}.log"]
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
proc ::MSWC::xyz {nodeId} {
    set v {}
    catch {set v [hm_nodevalue $nodeId]}
    if {[llength $v] == 3} { return [join $v { }] }
    catch {set v [hm_getvalue nodes id=$nodeId dataname=xyz]}
    return [join $v { }]
}

# Grid on the target plane, 4x4 at z=0 (x,y in 0..30 step 10), plus a vertical
# wall sharing the x=20 line (z=0..-10, CLS_WALL=0 skips it), plus a floating
# source path at z=10.
set compTarget [::MSWC::comp CLS_TARGET 11]
array set pn {}
foreach x {0 10 20 30} {
    foreach y {0 10 20 30} {
        set pn($x,$y) [::MSWC::node $x $y 0]
    }
}
set compWall 0
set wallNodes {}
if {$withWall} {
    set compWall [::MSWC::comp CLS_WALL 22]
    foreach y {0 10 20 30} {
        lappend wallNodes [::MSWC::node 20 $y -10]
    }
}
set compSource [::MSWC::comp CLS_SOURCE 33]
set sourceNodes {}
foreach xyz {{5 5 10} {25 5 10} {25 25 10} {5 25 10}} {
    lappend sourceNodes [::MSWC::node {*}$xyz]
}
set fixtureP [expr {[info exists env(CLS_PRINT)] ? $env(CLS_PRINT) : 1}]
if {$fixtureP} {
    foreach n $sourceNodes {
        P "SRC $n" [::MSWC::xyz $n]
    }
    foreach n $wallNodes {
        P "WALL $n" [::MSWC::xyz $n]
    }
    P "PLANE_GRID" "pn(0,0)=$pn(0,0) pn(10,0)=$pn(10,0) pn(20,0)=$pn(20,0) pn(30,0)=$pn(30,0) pn(0,10)=$pn(0,10) pn(10,10)=$pn(10,10) pn(20,10)=$pn(20,10) pn(30,10)=$pn(30,10) pn(0,20)=$pn(0,20) pn(10,20)=$pn(10,20) pn(20,20)=$pn(20,20) pn(30,20)=$pn(30,20) pn(0,30)=$pn(0,30) pn(10,30)=$pn(10,30) pn(20,30)=$pn(20,30) pn(30,30)=$pn(30,30)"
}

proc ::MSWC::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}
proc ::MSWC::query {tag x y z markSpec flag} {
    # markSpec: "none" | "all" | "source" | "target" | "wall" | id-list
    global sourceNodes wallNodes pn
    catch {*clearmark nodes 1}
    catch {*clearmark nodes 2}
    switch -- $markSpec {
        none    { set markArgs {} }
        all     { set markArgs {all} }
        source  { set markArgs $sourceNodes }
        target  { set markArgs [list $pn(10,10) $pn(20,10) $pn(20,20) $pn(10,20)] }
        wall    { set markArgs $wallNodes }
        default { set markArgs $markSpec }
    }
    if {$markSpec ne "none"} {
        if {[catch {eval *createmark nodes 1 $markArgs} mErr]} {
            P "${tag}_MARK_ERROR" $mErr
            return
        }
    }
    set args [list $x $y $z]
    if {$markSpec ne "none"} { lappend args 1 }
    if {$flag ne ""} { lappend args $flag }
    if {[catch {set r [eval hm_getclosestnode $args]} qErr]} {
        P "${tag}_ERROR" $qErr
    } else {
        P "${tag}_RETURN" $r
        P "${tag}_XYZ" [::MSWC::xyz $r]
    }
    catch {*clearmark nodes 1}
}

P "CASE" $caseSel
P "WITH_WALL" $withWall
switch -- $caseSel {
    1 {
        # 5-arg FIRST, before any 3-arg call.
        ::MSWC::query "G_SRCMARK_F1" 5.0 5.0 10.0 source 1
        P "AFTER_G" 1
        ::MSWC::query "C_AT_SRC"    5.0 5.0 10.0 none ""
        P "AFTER_C" 1
    }
    2 {
        # 3-arg first, then 5-arg at a NON-source point.
        ::MSWC::query "A_AT_P1010"  10.0 10.0 0.0 none ""
        ::MSWC::query "B_MID_ELEM"  15.0 15.0 0.0 none ""
        ::MSWC::query "I_TGTMARK_F1" 15.0 15.0 0.0 target 1
        P "AFTER_I" 1
    }
    3 {
        # 5-arg with mark=all at a non-source point.
        ::MSWC::query "J_ALLMARK_F1" 15.0 15.0 0.0 all 1
        P "AFTER_J" 1
    }
    4 {
        # 5-arg with mark=all AT a node.
        ::MSWC::query "K_AT_P1010_F1" 10.0 10.0 0.0 all 1
        P "AFTER_K" 1
    }
    5 {
        # 5-arg source-mark, query point NOT at any node (mid air).
        ::MSWC::query "L_MID_SRCMARK_F1" 15.0 15.0 10.0 source 1
        P "AFTER_L" 1
    }
    6 {
        # 5-arg source-mark at source node, but mark created by "by id".
        catch {*clearmark nodes 1}
        eval *createmark nodes 1 [list "by id"] $sourceNodes
        if {[catch {set r [hm_getclosestnode 5.0 5.0 10.0 1 1]} qErr]} {
            P "O_BYID_ERROR" $qErr
        } else {
            P "O_BYID_RETURN" $r
            P "O_BYID_XYZ" [::MSWC::xyz $r]
        }
        P "AFTER_O" 1
    }
    7 {
        # Bisect-equivalent: NO WALL, source mark, query at source node.
        ::MSWC::query "P_NOWALL_SRCMARK_F1" 5.0 5.0 10.0 source 1
        P "AFTER_P" 1
    }
    8 {
        # Vendor style: mark 1 = single node, query at that node.
        ::MSWC::query "Q_SINGLE_SRC_F1" 5.0 5.0 10.0 [list [lindex $sourceNodes 0]] 1
        P "AFTER_Q" 1
    }
    9 {
        # Source mark but query point at z=0 inside the plane.
        ::MSWC::query "R_SRCMARK_Z0" 15.0 15.0 0.0 source 1
        P "AFTER_R" 1
    }
    10 {
        # Exact bisect L1 replica: only clearmark nodes 1, inline call.
        catch {*clearmark nodes 1}
        eval *createmark nodes 1 $sourceNodes
        if {[catch {set r [hm_getclosestnode 5.0 5.0 10.0 1 1]} qErr]} {
            P "S_INLINE_ERROR" $qErr
        } else {
            P "S_INLINE_RETURN" $r
            P "S_INLINE_XYZ" [::MSWC::xyz $r]
        }
        P "AFTER_S" 1
    }
    11 {
        # Same but with clearmark nodes 2 before the mark.
        catch {*clearmark nodes 1}
        catch {*clearmark nodes 2}
        eval *createmark nodes 1 $sourceNodes
        if {[catch {set r [hm_getclosestnode 5.0 5.0 10.0 1 1]} qErr]} {
            P "T_MARK2CLEAR_ERROR" $qErr
        } else {
            P "T_MARK2CLEAR_RETURN" $r
            P "T_MARK2CLEAR_XYZ" [::MSWC::xyz $r]
        }
        P "AFTER_T" 1
    }
    13 {
        # Fixture WITH target elements (like bisect/full probe), then the
        # case-10 call.  Tests whether element-less models crash the query.
        set targetElems {}
        foreach x0 {0 10 20} x1 {10 20 30} {
            foreach y0 {0 10 20} y1 {10 20 30} {
                lappend targetElems [::MSWC::quad [list \
                    $::pn($x0,$y0) $::pn($x1,$y0) $::pn($x1,$y1) $::pn($x0,$y1)]]
            }
        }
        P "C13_TARGET_ELEMS" [llength $targetElems]
        catch {*clearmark nodes 1}
        eval *createmark nodes 1 $sourceNodes
        if {[catch {set r [hm_getclosestnode 5.0 5.0 10.0 1 1]} qErr]} {
            P "U_WITHELEMS_ERROR" $qErr
        } else {
            P "U_WITHELEMS_RETURN" $r
            P "U_WITHELEMS_XYZ" [::MSWC::xyz $r]
        }
        P "AFTER_U" 1
    }
    14 {
        # Bisect exact order: elements created BEFORE source nodes, no wall.
        set targetElems {}
        foreach x0 {0 10 20} x1 {10 20 30} {
            foreach y0 {0 10 20} y1 {10 20 30} {
                lappend targetElems [::MSWC::quad [list \
                    $::pn($x0,$y0) $::pn($x1,$y0) $::pn($x1,$y1) $::pn($x0,$y1)]]
            }
        }
        P "C14_TARGET_ELEMS" [llength $targetElems]
        catch {*clearmark nodes 1}
        eval *createmark nodes 1 $sourceNodes
        if {[catch {set r [hm_getclosestnode 5.0 5.0 10.0 1 1]} qErr]} {
            P "V_BISECTORDER_ERROR" $qErr
        } else {
            P "V_BISECTORDER_RETURN" $r
            P "V_BISECTORDER_XYZ" [::MSWC::xyz $r]
        }
        P "AFTER_V" 1
    }
    15 {
        # Same as 14 but with the wall present.
        set targetElems {}
        foreach x0 {0 10 20} x1 {10 20 30} {
            foreach y0 {0 10 20} y1 {10 20 30} {
                lappend targetElems [::MSWC::quad [list \
                    $::pn($x0,$y0) $::pn($x1,$y0) $::pn($x1,$y1) $::pn($x0,$y1)]]
            }
        }
        P "C15_TARGET_ELEMS" [llength $targetElems]
        catch {*clearmark nodes 1}
        eval *createmark nodes 1 $sourceNodes
        if {[catch {set r [hm_getclosestnode 5.0 5.0 10.0 1 1]} qErr]} {
            P "W_WALLORDER_ERROR" $qErr
        } else {
            P "W_WALLORDER_RETURN" $r
            P "W_WALLORDER_XYZ" [::MSWC::xyz $r]
        }
        P "AFTER_W" 1
    }
    18 {
        # Last-element theory: create an extra quad far away AFTER the target
        # patch; if the 5-arg search universe follows the last created element,
        # the query result will move to the far quad's nodes.
        set targetElems {}
        foreach x0 {0 10 20} x1 {10 20 30} {
            foreach y0 {0 10 20} y1 {10 20 30} {
                lappend targetElems [::MSWC::quad [list \
                    $::pn($x0,$y0) $::pn($x1,$y0) $::pn($x1,$y1) $::pn($x0,$y1)]]
            }
        }
        set farN1 [::MSWC::node 50 50 0]
        set farN2 [::MSWC::node 60 50 0]
        set farN3 [::MSWC::node 60 60 0]
        set farN4 [::MSWC::node 50 60 0]
        set farElem [::MSWC::quad [list $farN1 $farN2 $farN3 $farN4]]
        P "C18_FAR_ELEM" $farElem
        ::MSWC::query "G_SRCMARK_F1" 5.0 5.0 10.0 source 1
        P "AFTER_G" 1
        ::MSWC::query "I_TGTMARK_F1" 15.0 15.0 0.0 target 1
        P "AFTER_I" 1
        ::MSWC::query "A_AT_P1010"  10.0 10.0 0.0 none ""
    }
    17 {
        # Elements present + *redraw before the queries: does a display
        # refresh widen the search universe of the 5-arg form?
        set targetElems {}
        foreach x0 {0 10 20} x1 {10 20 30} {
            foreach y0 {0 10 20} y1 {10 20 30} {
                lappend targetElems [::MSWC::quad [list \
                    $::pn($x0,$y0) $::pn($x1,$y0) $::pn($x1,$y1) $::pn($x0,$y1)]]
            }
        }
        catch {*redraw}
        P "C17_REDRAWN" 1
        ::MSWC::query "A_AT_P1010"  10.0 10.0 0.0 none ""
        ::MSWC::query "G_SRCMARK_F1" 5.0 5.0 10.0 source 1
        P "AFTER_G" 1
        ::MSWC::query "I_TGTMARK_F1" 15.0 15.0 0.0 target 1
        P "AFTER_I" 1
        ::MSWC::query "J_ALLMARK_F1" 15.0 15.0 0.0 all 1
        P "AFTER_J" 1
        catch {*createmark nodes 1 all}
        ::MSWC::query "R_ALLMARK2_F1" 15.0 15.0 0.0 all 1
        P "AFTER_R" 1
    }
    16 {
        # Elements present (module context), then the full query matrix.
        set targetElems {}
        foreach x0 {0 10 20} x1 {10 20 30} {
            foreach y0 {0 10 20} y1 {10 20 30} {
                lappend targetElems [::MSWC::quad [list \
                    $::pn($x0,$y0) $::pn($x1,$y0) $::pn($x1,$y1) $::pn($x0,$y1)]]
            }
        }
        P "C16_TARGET_ELEMS" [llength $targetElems]
        ::MSWC::query "A_AT_P1010"  10.0 10.0 0.0 none ""
        ::MSWC::query "B_MID_ELEM"  15.0 15.0 0.0 none ""
        ::MSWC::query "C_AT_SRC"    5.0 5.0 10.0 none ""
        ::MSWC::query "G_SRCMARK_F1" 5.0 5.0 10.0 source 1
        P "AFTER_G" 1
        ::MSWC::query "H_SRCMARK_F2" 5.0 5.0 10.0 source 2
        P "AFTER_H" 1
        ::MSWC::query "I_TGTMARK_F1" 15.0 15.0 0.0 target 1
        P "AFTER_I" 1
        ::MSWC::query "J_ALLMARK_F1" 15.0 15.0 0.0 all 1
        P "AFTER_J" 1
        ::MSWC::query "K_AT_P1010_F1" 10.0 10.0 0.0 all 1
        P "AFTER_K" 1
        ::MSWC::query "L_AT_P1010_SRCMARK_F1" 10.0 10.0 0.0 source 1
        P "AFTER_L" 1
        ::MSWC::query "M_SINGLE_MARK_F1" 15.0 15.0 0.0 [list $::pn(10,10)] 1
        P "AFTER_M" 1
        catch {*clearmark nodes 1}
        if {[catch {set r [hm_getclosestnode 15.0 15.0 0.0 1 1]} qErr]} {
            P "N_EMPTY_MARK_ERROR" $qErr
        } else {
            P "N_EMPTY_MARK_RETURN" $r
            P "N_EMPTY_MARK_XYZ" [::MSWC::xyz $r]
        }
        P "AFTER_N" 1
        P "SECTION_4ARG_STARTED" 1
        ::MSWC::query "E_SRCMARK"   5.0 5.0 10.0 source ""
        P "AFTER_4ARG_SRCMARK" 1
        ::MSWC::query "F_TGTMARK"   15.0 15.0 0.0 target ""
        P "AFTER_4ARG_TGTMARK" 1
    }
    default {
        ::MSWC::query "A_AT_P1010"  10.0 10.0 0.0 none ""
        ::MSWC::query "B_MID_ELEM"  15.0 15.0 0.0 none ""
        ::MSWC::query "C_AT_SRC"    5.0 5.0 10.0 none ""
        ::MSWC::query "D_FAR"       100.0 100.0 0.0 none ""
        ::MSWC::query "G_SRCMARK_F1" 5.0 5.0 10.0 source 1
        P "AFTER_G" 1
        ::MSWC::query "H_SRCMARK_F2" 5.0 5.0 10.0 source 2
        P "AFTER_H" 1
        ::MSWC::query "I_TGTMARK_F1" 15.0 15.0 0.0 target 1
        P "AFTER_I" 1
        ::MSWC::query "J_ALLMARK_F1" 15.0 15.0 0.0 all 1
        P "AFTER_J" 1
        ::MSWC::query "K_AT_P1010_F1" 10.0 10.0 0.0 all 1
        P "AFTER_K" 1
        ::MSWC::query "L_AT_P1010_SRCMARK_F1" 10.0 10.0 0.0 source 1
        P "AFTER_L" 1
        ::MSWC::query "M_SINGLE_MARK_F1" 15.0 15.0 0.0 [list $::pn(10,10)] 1
        P "AFTER_M" 1
        catch {*clearmark nodes 1}
        if {[catch {set r [hm_getclosestnode 15.0 15.0 0.0 1 1]} qErr]} {
            P "N_EMPTY_MARK_ERROR" $qErr
        } else {
            P "N_EMPTY_MARK_RETURN" $r
            P "N_EMPTY_MARK_XYZ" [::MSWC::xyz $r]
        }
        P "AFTER_N" 1
        P "SECTION_4ARG_STARTED" 1
        ::MSWC::query "E_SRCMARK"   5.0 5.0 10.0 source ""
        P "AFTER_4ARG_SRCMARK" 1
        ::MSWC::query "F_TGTMARK"   15.0 15.0 0.0 target ""
        P "AFTER_4ARG_TGTMARK" 1
    }
}

P "status" "DONE"
close $channel
exit 0
