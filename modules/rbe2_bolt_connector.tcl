# ============================================================================
# RBE2_BoltConnector_v0_5.tcl
# HyperMesh 2019 oriented Tcl/Tk script
#
# Function:
#   Select RBE2 elements or components containing RBE2 elements, group their
#   independent nodes along X/Y/Z by tolerance, and create CBEAM bolt segments
#   between adjacent RBE2 center nodes only after sorting along the detected axis. Created beam elements are organized into
#   components named by nominal even hole diameter: BOLT_Dxx_CBEAM.
#
# v0.5 grouping logic fix:
#   - Planar RBE2 records only participate in grouping along their detected
#     normal axis. They are no longer searched/connected in their own plane.
#   - Groups containing spatial RBE2 records only are previewed/skipped and do
#     not create CBEAM elements.
#   - CBEAM creation still uses the HyperMesh 2019 compatible
#     *barelementcreatewithoffsets workflow from v0.4.
#
# Notes:
#   - Radius/diameter estimation uses the inner ring of dependent nodes:
#       diameter = 2 * minimum meaningful center-to-dependent-node radius,
#       then floor to an even integer.
#   - Planar RBE2 records only search along their detected normal axis.
#   - If a group contains planar RBE2 and spatial RBE2, diameter is taken from
#     planar RBE2 records first; spatial RBE2 records are still connected.
#   - Spatial-only RBE2 groups are skipped and do not create CBEAM elements.
#   - No nodes are moved to components. Only CBEAM elements are organized.
#   - Property/beamsection creation is deliberately not forced in this first
#     version; it focuses on reliable geometry connection and organization.
# ============================================================================

namespace eval ::RB2Bolt {
    variable P
    array set P {
        selectMode       components
        axisMode         AUTO
        gapTol           100.0
        offsetTol        5.0
        minGroupSize     2
        minBeamLength    0.001
        planeAbsTol      0.5
        planeFlatRatio   0.12
        radialAbsTol     0.5
        radialRelTol     0.08
        elemType         CBEAM
        compPrefix       BOLT
        propName         {}
        dryRun           0
    }
    variable done 0
    variable _sortAxis 2
}

# ------------------------- small utilities ---------------------------------
proc ::RB2Bolt::msg {txt} {
    catch {hm_usermessage $txt}
    catch {puts $txt}
    catch {update}
}

proc ::RB2Bolt::abs {v} {
    expr {$v < 0 ? -$v : $v}
}

proc ::RB2Bolt::dist3 {x1 y1 z1 x2 y2 z2} {
    expr {sqrt(($x1-$x2)*($x1-$x2) + ($y1-$y2)*($y1-$y2) + ($z1-$z2)*($z1-$z2))}
}

proc ::RB2Bolt::safeName {name} {
    set out $name
    regsub -all {[^A-Za-z0-9_]+} $out {_} out
    regsub -all {_+} $out {_} out
    return [string trim $out _]
}

proc ::RB2Bolt::coordIndex {axis} {
    switch -- $axis {
        X {return 2}
        Y {return 3}
        Z {return 4}
    }
    return 4
}

proc ::RB2Bolt::crossIndices {axis} {
    switch -- $axis {
        X {return {3 4}}
        Y {return {2 4}}
        Z {return {2 3}}
    }
    return {2 3}
}

proc ::RB2Bolt::rangeNormalAxis {rx ry rz} {
    set pairs [lsort -real -index 1 [list [list X $rx] [list Y $ry] [list Z $rz]]]
    return [lindex [lindex $pairs 0] 0]
}

proc ::RB2Bolt::recIsPlanar {rec} {
    expr {[llength $rec] > 6 && [lindex $rec 6]}
}

proc ::RB2Bolt::recNormalAxis {rec} {
    if {[llength $rec] > 7} {return [lindex $rec 7]}
    return ""
}

proc ::RB2Bolt::groupHasPlanar {g} {
    foreach rec $g {
        if {[recIsPlanar $rec]} {return 1}
    }
    return 0
}

proc ::RB2Bolt::nodeXYZ {nid} {
    set x [hm_getvalue nodes id=$nid dataname=x]
    set y [hm_getvalue nodes id=$nid dataname=y]
    set z [hm_getvalue nodes id=$nid dataname=z]
    return [list $x $y $z]
}

proc ::RB2Bolt::evenFloorDiameter {dia} {
    if {$dia <= 0} {return 0}
    set d [expr {int(floor($dia))}]
    if {$d < 1} {return 0}
    if {[expr {$d % 2}] != 0} {incr d -1}
    if {$d < 1} {return 0}
    return $d
}

proc ::RB2Bolt::median {vals} {
    set n [llength $vals]
    if {$n == 0} {return 0.0}
    set s [lsort -real $vals]
    set mid [expr {$n / 2}]
    if {[expr {$n % 2}] == 1} {
        return [lindex $s $mid]
    }
    return [expr {([lindex $s [expr {$mid-1}]] + [lindex $s $mid]) / 2.0}]
}

proc ::RB2Bolt::chooseModeDiameter {ds} {
    array unset cnt
    array set cnt {}
    foreach d $ds {
        if {$d <= 0} {continue}
        if {![info exists cnt($d)]} {set cnt($d) 0}
        incr cnt($d)
    }
    set best 0
    set bestc -1
    foreach d [array names cnt] {
        if {$cnt($d) > $bestc || ($cnt($d) == $bestc && ($best == 0 || $d < $best))} {
            set best $d
            set bestc $cnt($d)
        }
    }
    return $best
}

# ------------------------- GUI ---------------------------------------------
proc ::RB2Bolt::showDialog {} {
    variable P
    variable done
    set done 0

    catch {destroy .rb2bolt_dlg}
    toplevel .rb2bolt_dlg
    wm title .rb2bolt_dlg "RBE2 Bolt Connector v0.5"
    wm resizable .rb2bolt_dlg 0 0

    set r 0
    label .rb2bolt_dlg.l0 -text "选择对象"
    tk_optionMenu .rb2bolt_dlg.m0 ::RB2Bolt::P(selectMode) components elements
    grid .rb2bolt_dlg.l0 -row $r -column 0 -sticky e -padx 6 -pady 4
    grid .rb2bolt_dlg.m0 -row $r -column 1 -sticky ew -padx 6 -pady 4
    incr r

    label .rb2bolt_dlg.l1 -text "搜索轴向"
    tk_optionMenu .rb2bolt_dlg.m1 ::RB2Bolt::P(axisMode) AUTO X Y Z
    grid .rb2bolt_dlg.l1 -row $r -column 0 -sticky e -padx 6 -pady 4
    grid .rb2bolt_dlg.m1 -row $r -column 1 -sticky ew -padx 6 -pady 4
    incr r

    label .rb2bolt_dlg.l2 -text "轴向最大连接距离"
    entry .rb2bolt_dlg.e2 -textvariable ::RB2Bolt::P(gapTol) -width 14
    grid .rb2bolt_dlg.l2 -row $r -column 0 -sticky e -padx 6 -pady 4
    grid .rb2bolt_dlg.e2 -row $r -column 1 -sticky ew -padx 6 -pady 4
    incr r

    label .rb2bolt_dlg.l3 -text "横向中心偏心容差"
    entry .rb2bolt_dlg.e3 -textvariable ::RB2Bolt::P(offsetTol) -width 14
    grid .rb2bolt_dlg.l3 -row $r -column 0 -sticky e -padx 6 -pady 4
    grid .rb2bolt_dlg.e3 -row $r -column 1 -sticky ew -padx 6 -pady 4
    incr r

    label .rb2bolt_dlg.l4 -text "最小RBE2数量/组"
    entry .rb2bolt_dlg.e4 -textvariable ::RB2Bolt::P(minGroupSize) -width 14
    grid .rb2bolt_dlg.l4 -row $r -column 0 -sticky e -padx 6 -pady 4
    grid .rb2bolt_dlg.e4 -row $r -column 1 -sticky ew -padx 6 -pady 4
    incr r

    label .rb2bolt_dlg.l5 -text "最小CBEAM长度"
    entry .rb2bolt_dlg.e5 -textvariable ::RB2Bolt::P(minBeamLength) -width 14
    grid .rb2bolt_dlg.l5 -row $r -column 0 -sticky e -padx 6 -pady 4
    grid .rb2bolt_dlg.e5 -row $r -column 1 -sticky ew -padx 6 -pady 4
    incr r

    label .rb2bolt_dlg.l6 -text "平面RBE2绝对厚度判据"
    entry .rb2bolt_dlg.e6 -textvariable ::RB2Bolt::P(planeAbsTol) -width 14
    grid .rb2bolt_dlg.l6 -row $r -column 0 -sticky e -padx 6 -pady 4
    grid .rb2bolt_dlg.e6 -row $r -column 1 -sticky ew -padx 6 -pady 4
    incr r

    label .rb2bolt_dlg.l7 -text "元素类型"
    tk_optionMenu .rb2bolt_dlg.m7 ::RB2Bolt::P(elemType) CBEAM CBAR
    grid .rb2bolt_dlg.l7 -row $r -column 0 -sticky e -padx 6 -pady 4
    grid .rb2bolt_dlg.m7 -row $r -column 1 -sticky ew -padx 6 -pady 4
    incr r

    label .rb2bolt_dlg.l8 -text "输出Component前缀"
    entry .rb2bolt_dlg.e8 -textvariable ::RB2Bolt::P(compPrefix) -width 14
    grid .rb2bolt_dlg.l8 -row $r -column 0 -sticky e -padx 6 -pady 4
    grid .rb2bolt_dlg.e8 -row $r -column 1 -sticky ew -padx 6 -pady 4
    incr r

    label .rb2bolt_dlg.l9 -text "1D属性名称(可选)"
    entry .rb2bolt_dlg.e9 -textvariable ::RB2Bolt::P(propName) -width 14
    grid .rb2bolt_dlg.l9 -row $r -column 0 -sticky e -padx 6 -pady 4
    grid .rb2bolt_dlg.e9 -row $r -column 1 -sticky ew -padx 6 -pady 4
    incr r

    checkbutton .rb2bolt_dlg.c10 -text "仅预览分组，不创建CBEAM" -variable ::RB2Bolt::P(dryRun)
    grid .rb2bolt_dlg.c10 -row $r -column 0 -columnspan 2 -sticky w -padx 6 -pady 4
    incr r

    frame .rb2bolt_dlg.btns
    button .rb2bolt_dlg.btns.ok -text "确定" -width 10 -command {set ::RB2Bolt::done 1}
    button .rb2bolt_dlg.btns.cancel -text "取消" -width 10 -command {set ::RB2Bolt::done -1}
    pack .rb2bolt_dlg.btns.ok .rb2bolt_dlg.btns.cancel -side left -padx 8 -pady 8
    grid .rb2bolt_dlg.btns -row $r -column 0 -columnspan 2

    bind .rb2bolt_dlg <Return> {set ::RB2Bolt::done 1}
    bind .rb2bolt_dlg <Escape> {set ::RB2Bolt::done -1}

    tkwait variable ::RB2Bolt::done
    catch {destroy .rb2bolt_dlg}
    return [expr {$done == 1}]
}

proc ::RB2Bolt::validateParams {} {
    variable P
    foreach key {gapTol offsetTol minBeamLength planeAbsTol planeFlatRatio radialAbsTol radialRelTol} {
        if {[catch {expr {double($P($key))}} v]} {
            tk_messageBox -icon error -message "参数 $key 不是有效数字。"
            return 0
        }
        set P($key) $v
    }
    if {[catch {expr {int($P(minGroupSize))}} v]} {
        tk_messageBox -icon error -message "最小RBE2数量/组 不是有效整数。"
        return 0
    }
    set P(minGroupSize) $v
    if {$P(gapTol) <= 0 || $P(offsetTol) <= 0 || $P(minGroupSize) < 2} {
        tk_messageBox -icon error -message "轴向距离、横向容差必须 > 0；最小RBE2数量必须 >= 2。"
        return 0
    }
    set P(compPrefix) [safeName $P(compPrefix)]
    if {$P(compPrefix) eq ""} {set P(compPrefix) BOLT}
    set P(propName) [string trim $P(propName)]
    return 1
}

# ------------------------- selection and RBE2 parsing -----------------------
proc ::RB2Bolt::selectedElementIds {} {
    variable P
    set out {}
    catch {hm_markclear elems 1}
    catch {hm_markclear elems 2}
    catch {hm_markclear comps 1}

    if {$P(selectMode) eq "components"} {
        *createmarkpanel comps 1 "Select components containing RBE2 elements"
        set comps [hm_getmark comps 1]
        if {[llength $comps] == 0} {return {}}
        foreach cid $comps {
            catch {hm_markclear elems 2}
            if {![catch {*createmark elems 2 "by comp id" $cid}]} {
                foreach e [hm_getmark elems 2] {lappend out $e}
            }
        }
    } else {
        *createmarkpanel elems 1 "Select RBE2 elements"
        foreach e [hm_getmark elems 1] {lappend out $e}
    }
    return [lsort -integer -unique $out]
}

proc ::RB2Bolt::isRigidLink {eid} {
    set cfg ""
    if {[catch {hm_getvalue elems id=$eid dataname=config} cfg]} {return 0}
    if {$cfg == 55} {return 1}
    set typ ""
    catch {set typ [hm_getvalue elems id=$eid dataname=typename]}
    if {[string match -nocase *RBE2* $typ] || [string match -nocase *rigid* $typ]} {return 1}
    return 0
}

proc ::RB2Bolt::rbe2Record {eid} {
    variable P

    if {![isRigidLink $eid]} {return ""}

    set inode ""
    if {[catch {hm_getvalue elems id=$eid dataname=independentnode.id} inode] || $inode eq "" || $inode == 0} {
        return ""
    }

    set allnodes {}
    if {[catch {hm_getvalue elems id=$eid dataname=nodes} allnodes]} {
        return ""
    }

    set xyz [nodeXYZ $inode]
    set cx [lindex $xyz 0]
    set cy [lindex $xyz 1]
    set cz [lindex $xyz 2]

    set depnodes {}
    foreach n $allnodes {
        if {$n != $inode} {lappend depnodes $n}
    }
    if {[llength $depnodes] < 2} {return ""}

    set xs {}; set ys {}; set zs {}; set dists {}
    foreach n $depnodes {
        if {[catch {set nxyz [nodeXYZ $n]}]} {continue}
        set x [lindex $nxyz 0]
        set y [lindex $nxyz 1]
        set z [lindex $nxyz 2]
        lappend xs $x; lappend ys $y; lappend zs $z
        set d [dist3 $cx $cy $cz $x $y $z]
        if {$d > $P(minBeamLength)} {lappend dists $d}
    }
    if {[llength $dists] == 0} {return ""}

    set sx [lsort -real $xs]
    set sy [lsort -real $ys]
    set sz [lsort -real $zs]
    set rx [expr {[lindex $sx end] - [lindex $sx 0]}]
    set ry [expr {[lindex $sy end] - [lindex $sy 0]}]
    set rz [expr {[lindex $sz end] - [lindex $sz 0]}]
    set rangePairs [lsort -real -index 1 [list [list X $rx] [list Y $ry] [list Z $rz]]]
    set minr [lindex [lindex $rangePairs 0] 1]
    set maxr [lindex [lindex $rangePairs end] 1]
    set normalAxis [lindex [lindex $rangePairs 0] 0]

    set planar 0
    if {$maxr > 0} {
        if {$minr <= $P(planeAbsTol) || ($minr / $maxr) <= $P(planeFlatRatio)} {
            set planar 1
        }
    }
    if {!$planar} {set normalAxis ""}

    # Estimate inner free-edge radius from the first radial cluster.
    set sd [lsort -real $dists]
    set r0 [lindex $sd 0]
    set rtol [expr {$P(radialAbsTol) > ($P(radialRelTol) * $r0) ? $P(radialAbsTol) : ($P(radialRelTol) * $r0)}]
    set inner {}
    foreach d $sd {
        if {$d <= $r0 + $rtol} {lappend inner $d}
    }
    set radius [median $inner]
    set dia [evenFloorDiameter [expr {2.0 * $radius}]]

    # record = eid inode x y z dia planar normalAxis
    # normalAxis is only valid for planar RBE2 records and is one of X/Y/Z.
    return [list $eid $inode $cx $cy $cz $dia $planar $normalAxis]
}

proc ::RB2Bolt::collectRBE2Records {elemIds} {
    set records {}
    set total [llength $elemIds]
    set i 0
    foreach eid $elemIds {
        incr i
        if {[expr {$i % 200}] == 0} {
            msg "Reading RBE2: $i / $total"
        }
        set rec [rbe2Record $eid]
        if {$rec ne ""} {lappend records $rec}
    }
    return $records
}

# ------------------------- grouping ----------------------------------------
proc ::RB2Bolt::ufFind {i parentName} {
    upvar 1 $parentName parent
    set p $parent($i)
    if {$p != $i} {
        set parent($i) [ufFind $p parent]
    }
    return $parent($i)
}

proc ::RB2Bolt::ufUnion {a b parentName} {
    upvar 1 $parentName parent
    set ra [ufFind $a parent]
    set rb [ufFind $b parent]
    if {$ra != $rb} {set parent($rb) $ra}
}

proc ::RB2Bolt::pairAxisAllowedByPlanarity {ra rb axis} {
    foreach rec [list $ra $rb] {
        if {[recIsPlanar $rec]} {
            set na [recNormalAxis $rec]
            if {$na ne "" && $axis ne $na} {return 0}
        }
    }
    return 1
}

proc ::RB2Bolt::pairMatchAxis {ra rb axis} {
    variable P
    if {![pairAxisAllowedByPlanarity $ra $rb $axis]} {return 0}
    set ai [coordIndex $axis]
    set cis [crossIndices $axis]
    set c1 [lindex $cis 0]
    set c2 [lindex $cis 1]

    set da [abs [expr {[lindex $ra $ai] - [lindex $rb $ai]}]]
    if {$da <= $P(minBeamLength) || $da > $P(gapTol)} {return 0}

    set dc1 [abs [expr {[lindex $ra $c1] - [lindex $rb $c1]}]]
    set dc2 [abs [expr {[lindex $ra $c2] - [lindex $rb $c2]}]]
    if {$dc1 <= $P(offsetTol) && $dc2 <= $P(offsetTol)} {return 1}
    return 0
}

proc ::RB2Bolt::intFloor {v} {
    expr {int(floor(double($v)))}
}

proc ::RB2Bolt::buildGroupsForAxis {records axis} {
    variable P
    set n [llength $records]
    if {$n < $P(minGroupSize)} {return {}}

    array unset parent
    array set parent {}
    for {set i 0} {$i < $n} {incr i} {set parent($i) $i}

    set cis [crossIndices $axis]
    set c1 [lindex $cis 0]
    set c2 [lindex $cis 1]
    set bin $P(offsetTol)

    array unset bucket
    array set bucket {}
    for {set i 0} {$i < $n} {incr i} {
        set rec [lindex $records $i]
        set b1 [intFloor [expr {[lindex $rec $c1] / $bin}]]
        set b2 [intFloor [expr {[lindex $rec $c2] / $bin}]]
        lappend bucket($b1,$b2) $i
    }

    for {set i 0} {$i < $n} {incr i} {
        set rec [lindex $records $i]
        set b1 [intFloor [expr {[lindex $rec $c1] / $bin}]]
        set b2 [intFloor [expr {[lindex $rec $c2] / $bin}]]
        for {set di -1} {$di <= 1} {incr di} {
            for {set dj -1} {$dj <= 1} {incr dj} {
                set key [expr {$b1+$di}],[expr {$b2+$dj}]
                if {![info exists bucket($key)]} {continue}
                foreach j $bucket($key) {
                    if {$j <= $i} {continue}
                    if {[pairMatchAxis $rec [lindex $records $j] $axis]} {
                        ufUnion $i $j parent
                    }
                }
            }
        }
    }

    array unset groups
    array set groups {}
    for {set i 0} {$i < $n} {incr i} {
        set r [ufFind $i parent]
        lappend groups($r) [lindex $records $i]
    }

    set out {}
    foreach k [array names groups] {
        set g $groups($k)
        if {[llength $g] >= $P(minGroupSize)} {
            lappend out [list $axis [sortGroupByAxis $g $axis]]
        }
    }
    return $out
}

proc ::RB2Bolt::recCompareAxis {a b} {
    variable _sortAxis
    set va [lindex $a $_sortAxis]
    set vb [lindex $b $_sortAxis]
    if {$va < $vb} {return -1}
    if {$va > $vb} {return 1}
    return 0
}

proc ::RB2Bolt::sortGroupByAxis {g axis} {
    variable _sortAxis
    set _sortAxis [coordIndex $axis]
    return [lsort -command ::RB2Bolt::recCompareAxis $g]
}

proc ::RB2Bolt::groupKey {g} {
    set nodes {}
    foreach rec $g {lappend nodes [lindex $rec 1]}
    return [join [lsort -integer $nodes] _]
}

proc ::RB2Bolt::groupSpread {g axis} {
    set ci [coordIndex $axis]
    set vals {}
    foreach rec $g {lappend vals [lindex $rec $ci]}
    set s [lsort -real $vals]
    expr {[lindex $s end] - [lindex $s 0]}
}

proc ::RB2Bolt::buildGroups {records} {
    variable P
    if {$P(axisMode) eq "AUTO"} {
        set axes {X Y Z}
    } else {
        set axes [list $P(axisMode)]
    }

    array unset bestG
    array set bestG {}
    array unset bestS
    array set bestS {}
    array unset bestA
    array set bestA {}

    foreach axis $axes {
        set gs [buildGroupsForAxis $records $axis]
        foreach item $gs {
            set a [lindex $item 0]
            set g [lindex $item 1]
            set key [groupKey $g]
            set sp [groupSpread $g $a]
            if {![info exists bestG($key)] || $sp > $bestS($key)} {
                set bestG($key) $g
                set bestS($key) $sp
                set bestA($key) $a
            }
        }
    }

    set out {}
    foreach key [array names bestG] {
        lappend out [list $bestA($key) $bestG($key)]
    }
    return $out
}

proc ::RB2Bolt::groupDiameter {g} {
    set planarDs {}
    set allDs {}
    foreach rec $g {
        set d [lindex $rec 5]
        if {$d > 0} {
            lappend allDs $d
            if {[lindex $rec 6]} {lappend planarDs $d}
        }
    }
    if {[llength $planarDs] > 0} {
        return [chooseModeDiameter $planarDs]
    }
    return [chooseModeDiameter $allDs]
}

# ------------------------- creation ----------------------------------------
proc ::RB2Bolt::ensureComponent {name} {
    set id ""
    if {![catch {hm_getvalue comps name=$name dataname=id} id] && $id ne "" && $id != 0} {
        catch {*currentcollector component $name}
        return $id
    }
    *createentity comps name=$name
    set id 0
    catch {set id [hm_getvalue comps name=$name dataname=id]}
    catch {*currentcollector component $name}
    return $id
}

proc ::RB2Bolt::orientVecForNodes {n1 n2} {
    set a [nodeXYZ $n1]
    set b [nodeXYZ $n2]
    set dx [expr {[lindex $b 0] - [lindex $a 0]}]
    set dy [expr {[lindex $b 1] - [lindex $a 1]}]
    set dz [expr {[lindex $b 2] - [lindex $a 2]}]
    set len [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
    if {$len <= 0.0} {return {0.0 0.0 1.0}}

    # The orientation vector must not be parallel to the CBEAM axis.
    # Prefer global Z; use global Y when the beam itself is almost Z-directional.
    set uz [expr {abs($dz / $len)}]
    if {$uz < 0.90} {
        return {0.0 0.0 1.0}
    }
    return {0.0 1.0 0.0}
}

proc ::RB2Bolt::createBeamBetween {n1 n2 elemType compName} {
    variable P
    set xyz1 [nodeXYZ $n1]
    set xyz2 [nodeXYZ $n2]
    set len [dist3 [lindex $xyz1 0] [lindex $xyz1 1] [lindex $xyz1 2] [lindex $xyz2 0] [lindex $xyz2 1] [lindex $xyz2 2]]
    if {$len <= $P(minBeamLength)} {return 0}

    ensureComponent $compName

    # HyperMesh 2019 compatible creation path.
    # This command creates a BAR2-type bar/beam according to the current 1D element
    # type setting. In Nastran/OptiStruct profiles, set: 1D > elem types > BAR2 = CBEAM.
    set ov [orientVecForNodes $n1 $n2]
    if {[catch {*createvector 1 [lindex $ov 0] [lindex $ov 1] [lindex $ov 2]} verr]} {
        msg "Create orientation vector failed for nodes $n1-$n2: $verr"
        return 0
    }

    if {$P(propName) ne ""} {
        set propCandidates [list $P(propName)]
    } else {
        # Different HM/profile versions accept either 0 or an empty property name
        # when creating a bar without assigning a property. Try both.
        set propCandidates [list 0 ""]
    }

    # Full-offset syntax first. If the installed profile accepts the shorter
    # legacy syntax only, try that as fallback.
    set lastErr ""
    foreach prop $propCandidates {
        set err1 ""
        set rc1 [catch {*barelementcreatewithoffsets $n1 $n2 1 0 1 0 0 $prop 0 0 0 0 0 0 0 0} err1]
        if {$rc1 == 0} {return 1}
        set lastErr "barFull=$err1"

        set err2 ""
        set rc2 [catch {*barelementcreatewithoffsets $n1 $n2 1 0 1 0 0 $prop} err2]
        if {$rc2 == 0} {return 1}
        append lastErr "; barShort=$err2"
    }

    # Last fallback: *createelements1d without newer HM2020+ options.
    # Use plural nodes for *createlist, matching HyperMesh command syntax.
    catch {*createlist nodes 1}
    *createlist nodes 1 $n1 $n2
    set cmd [list *createelements1d nodes list=1 elemsize=$len elemtype=$elemType useshell=0 breakangle=0 elemdensity=1 useelemdensity=0 biasdensity=0 biasstyle=0]
    if {$P(propName) ne ""} {lappend cmd property=$P(propName)}
    set err3 ""
    if {[catch {eval $cmd} err3]} {
        msg "Create $elemType failed: nodes $n1-$n2; $lastErr; create1d=$err3"
        return 0
    }
    return 1
}

proc ::RB2Bolt::pairGroupRecords {g axis} {
    # Build adjacent pairs after sorting along the bolt axis.
    # For sorted RBE2 centers 1,2,3,4, this creates 1-2, 2-3, 3-4.
    # It deliberately avoids skipped/span connections such as 1-3 or 1-4.
    set n [llength $g]
    set pairs {}
    if {$n < 2} {return $pairs}

    for {set i 0} {$i < [expr {$n - 1}]} {incr i} {
        set ri [lindex $g $i]
        set rj [lindex $g [expr {$i + 1}]]
        if {[pairMatchAxis $ri $rj $axis]} {
            lappend pairs [list $ri $rj]
        }
    }
    return $pairs
}

proc ::RB2Bolt::createBolts {groups} {
    variable P
    set created 0
    set skipped 0
    set pairTotal 0
    set spatialOnlyGroups 0
    set groupCount [llength $groups]
    set gi 0

    foreach item $groups {
        incr gi
        set axis [lindex $item 0]
        set g [lindex $item 1]
        set pairs [pairGroupRecords $g $axis]
        incr pairTotal [llength $pairs]
        set unpaired [expr {([llength $g] > 1 ? ([llength $g] - 1) : 0) - [llength $pairs]}]

        if {![groupHasPlanar $g]} {
            incr spatialOnlyGroups
            incr skipped [expr {[llength $pairs] + $unpaired}]
            msg "Bolt group $gi / $groupCount, axis=$axis, spatial-only RBE2 group, RBE2=[llength $g], skipped_creation=1"
            continue
        }

        set dia [groupDiameter $g]
        if {$dia <= 0} {set dia UNKNOWN}
        set compName [safeName [format "%s_D%s_%s" $P(compPrefix) $dia $P(elemType)]]

        msg "Bolt group $gi / $groupCount, axis=$axis, D=$dia, RBE2=[llength $g], adjacent_segments=[llength $pairs], skipped_segments=$unpaired"

        if {$P(dryRun)} {continue}

        foreach pr $pairs {
            set r1 [lindex $pr 0]
            set r2 [lindex $pr 1]
            set n1 [lindex $r1 1]
            set n2 [lindex $r2 1]
            if {[createBeamBetween $n1 $n2 $P(elemType) $compName]} {
                incr created
            } else {
                incr skipped
            }
        }
        incr skipped $unpaired
    }
    return [list $created $skipped $pairTotal $spatialOnlyGroups]
}

# ------------------------- entry point -------------------------------------
proc ::RB2Bolt::run {} {
    variable P
    if {![showDialog]} {
        msg "RBE2 Bolt Connector cancelled."
        return
    }
    if {![validateParams]} {return}

    msg "RBE2 Bolt Connector started. Make sure BAR2 element type is set to CBEAM if CBEAM output is required."

    set elemIds [selectedElementIds]
    if {[llength $elemIds] == 0} {
        tk_messageBox -icon warning -message "没有选择到元素。"
        return
    }

    msg "Selected elements: [llength $elemIds]"
    set records [collectRBE2Records $elemIds]
    if {[llength $records] < 2} {
        tk_messageBox -icon warning -message "选中范围内可用 RBE2 少于 2 个，无法创建螺栓连接。"
        return
    }

    msg "Valid RBE2 records: [llength $records]. Building groups..."
    set groups [buildGroups $records]
    if {[llength $groups] == 0} {
        tk_messageBox -icon warning -message "未找到满足容差条件的 RBE2 分组。可尝试增大轴向最大连接距离或横向中心偏心容差。"
        return
    }

    set result [createBolts $groups]
    set created [lindex $result 0]
    set skipped [lindex $result 1]
    set spatialOnlyGroups [lindex $result 3]

    set txt "RBE2 Bolt Connector finished.\n\nRBE2数量: [llength $records]\n分组数量: [llength $groups]\n空间RBE2-only跳过组数: $spatialOnlyGroups\n创建 $P(elemType): $created\n跳过/失败: $skipped"
    tk_messageBox -icon info -message $txt
    msg $txt
}


