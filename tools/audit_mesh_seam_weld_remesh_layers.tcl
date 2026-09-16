# Real-machine probe: the configured by-adjacent expansion layers now drive the
# native Create Patch imprint's remesh_layers, and the existing-weld protection
# is enforced instead of only assumed.
#
# NOTE: never wrap *imprint_nodelist in a Tcl proc for this probe - HM2019 makes
# the imprinted path fail opaquely ("0") when the native command is called
# through a Tcl wrapper (verified by A/B on the same model).
#
# Verifies, on the real module and HyperMesh:
#   1. remesh_layers follows patch_expand_layers (2 by default, 0 = split only)
#      and the mother mesh around the seam is reworked when layers > 0;
#   2. with allow_break_existing_weld off (default), an existing SEAM_* strip
#      next to the new seam survives the expanded remesh rings unchanged (or the
#      path is rolled back), and with the setting on it may be remeshed.
#
# Run in a fresh hmbatch process:
#   "D:/Program Files/Altair/2019/hm/bin/win64/hmbatch.exe" \
#     -nocommand -nouserprofiledialog -tcl \
#     tools/audit_mesh_seam_weld_remesh_layers.tcl
# Judge by the last line of runtime/msw_remesh_layers_probe.log.

set root [file normalize [file join [file dirname [info script]] ..]]
set report [open [file join $root runtime msw_remesh_layers_probe.log] w]
fconfigure $report -buffering line
proc P {args} {
    global report
    puts $report [join $args " "]
    flush $report
}

proc probeNode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}

proc probeQuad {nodes} {
    eval *createlist nodes 1 $nodes
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}

proc probeComp {name color} {
    *collectorcreateonly components $name "" $color
    *currentcollector component $name
    return [hm_getvalue comps name=$name dataname=id]
}

proc probeBuildPlate {baseName xMin yMin xMax yMax baseSize} {
    *collectorcreateonly components $baseName "" 11
    *currentcollector component $baseName
    set baseComp [hm_getvalue comps name=$baseName dataname=id]
    set nx [expr {int(ceil(($xMax-$xMin)/$baseSize))}]
    set ny [expr {int(ceil(($yMax-$yMin)/$baseSize))}]
    array set bn {}
    for {set ix 0} {$ix <= $nx} {incr ix} {
        for {set iy 0} {$iy <= $ny} {incr iy} {
            set bn($ix,$iy) [probeNode [expr {$xMin+$ix*$baseSize}] \
                [expr {$yMin+$iy*$baseSize}] 0.0]
        }
    }
    for {set ix 0} {$ix < $nx} {incr ix} {
        for {set iy 0} {$iy < $ny} {incr iy} {
            probeQuad [list $bn($ix,$iy) $bn([expr {$ix+1}],$iy) \
                $bn([expr {$ix+1}],[expr {$iy+1}]) $bn($ix,[expr {$iy+1}])]
        }
    }
    return $baseComp
}

# Straight T joint (the geometry-probe builder): base plate + vertical web whose
# rail runs along y=0 at z=$railZ, from x=$left to x=$right.
proc probeStraightCase {tag left right railZ railSpacing angleDeg baseSize} {
    set cosA [expr {cos($angleDeg*acos(-1.0)/180.0)}]
    set sinA [expr {sin($angleDeg*acos(-1.0)/180.0)}]
    set span [expr {$right-$left}]
    set half [expr {$span/2.0}]
    set cx [expr {($left+$right)/2.0}]
    set margin [expr {max(20.0,4.0*$baseSize)}]
    set baseName "BASE_$tag"; set webName "WEB_$tag"
    set baseComp [probeBuildPlate $baseName \
        [expr {$cx - $half*abs($cosA) - $margin + 0.5*$baseSize}] \
        [expr {-0.5*$span*abs($sinA) - $margin + 0.5*$baseSize}] \
        [expr {$cx + $half*abs($cosA) + $margin}] \
        [expr {0.5*$span*abs($sinA) + $margin}] $baseSize]
    set steps [expr {int(floor($span/$railSpacing))}]
    set railPoints {}
    for {set i 0} {$i <= $steps} {incr i} {
        set t [expr {-$half + $i*$railSpacing}]
        lappend railPoints [list [expr {$cx + $t*$cosA}] [expr {$t*$sinA}] $railZ]
    }
    *collectorcreateonly components $webName "" 22
    *currentcollector component $webName
    set webComp [hm_getvalue comps name=$webName dataname=id]
    set railNodes {}
    set topNodes {}
    foreach point $railPoints {
        lassign $point x y z
        lappend railNodes [probeNode $x $y $z]
        lappend topNodes [probeNode $x $y [expr {$z+15.0}]]
    }
    return [dict create rail $railNodes top $topNodes baseComp $baseComp \
        webComp $webComp closed 0]
}

# The same joint plus an existing weld strip (component $stripName) standing on
# the base row at y=$stripY, sharing the base nodes there.
proc probeStripCase {tag left right railZ railSpacing baseSize stripY stripName} {
    set case [probeStraightCase $tag $left $right $railZ $railSpacing 0.0 $baseSize]
    set baseComp [dict get $case baseComp]
    set xMin [expr {$left - 20.0 + 0.5*$baseSize}]
    set yMin [expr {-20.0 + 0.5*$baseSize}]
    set xMax [expr {$right + 20.0}]
    set yMax [expr {20.0}]
    set nx [expr {int(ceil(($xMax-$xMin)/$baseSize))}]
    set ny [expr {int(ceil(($yMax-$yMin)/$baseSize))}]
    set stripRow {}
    for {set iy 0} {$iy <= $ny} {incr iy} {
        if {abs([expr {$yMin+$iy*$baseSize}] - $stripY) < 1.0e-9} {
            set stripRow $iy; break
        }
    }
    set rowList {}
    if {$stripRow ne ""} {
        *clearmark nodes 1
        eval *createmark nodes 1 "by comp id" $baseComp
        foreach nodeId [hm_getmark nodes 1] {
            set point [dict get [::HybridCore::readNodeCoordinatesBulk \
                [list $nodeId] [list ::MeshSeamWeld::nodeXYZ]] $nodeId]
            if {abs([lindex $point 1] - $stripY) < 1.0e-9} {
                lappend rowList $nodeId
            }
        }
    }
    set rowList [lsort -integer -unique $rowList]
    set stripName [expr {$stripName eq "" ? "" : $stripName}]
    set stripIds {}
    set stripConn {}
    if {[llength $rowList] >= 2 && $stripName ne ""} {
        *collectorcreateonly components $stripName "" 12
        *currentcollector component $stripName
        for {set i 0} {$i < [llength $rowList]-1} {incr i} {
            set a [lindex $rowList $i]; set b [lindex $rowList [expr {$i+1}]]
            set aPoint [dict get [::HybridCore::readNodeCoordinatesBulk [list $a] \
                [list ::MeshSeamWeld::nodeXYZ]] $a]
            set bPoint [dict get [::HybridCore::readNodeCoordinatesBulk [list $b] \
                [list ::MeshSeamWeld::nodeXYZ]] $b]
            lappend stripIds [probeQuad [list $a $b \
                [probeNode [lindex $bPoint 0] [lindex $bPoint 1] \
                    [expr {[lindex $bPoint 2]+2.5}]] \
                [probeNode [lindex $aPoint 0] [lindex $aPoint 1] \
                    [expr {[lindex $aPoint 2]+2.5}]]]]
        }
        set stripConn [::MeshSeamWeld::readShellElementConnectivityBulk \
            $stripIds 1]
    }
    dict set case stripName $stripName
    dict set case stripIds $stripIds
    dict set case stripConn $stripConn
    return $case
}

proc probeRun {tag case layers breakWeld} {
    set ::MeshSeamWeld::cfg(patch_expand_layers) $layers
    set ::MeshSeamWeld::cfg(allow_break_existing_weld) $breakWeld
    set rail [dict get $case rail]
    set baseComp [dict get $case baseComp]
    set webComp [dict get $case webComp]
    set prepared [::MeshSeamWeld::prepareCurrentTargetPatch $rail [list $baseComp] 0]
    set patch [dict get $prepared target_elements]
    set scopeBefore [::MeshSeamWeld::readShellElementConnectivityBulk \
        [lsort -integer -unique [concat $patch \
            [::MeshSeamWeld::adjacentElementsForNodes $rail]]] 1]
    set outcome [::MeshSeamWeld::processWeldPathIsolated $rail [list $baseComp] 0 0 1 1 \
        [list $webComp] "SEAM_$tag" {} $patch 0]
    set survivors 0
    foreach id [dict keys $scopeBefore] {
        set current [::MeshSeamWeld::readShellElementConnectivityBulk [list $id] 1]
        if {[dict size $current] == 1} { incr survivors }
    }
    set stripName ""
    if {[dict exists $case stripName]} { set stripName [dict get $case stripName] }
    P "CASE $tag layers=$layers break=$breakWeld strip=$stripName patch=[llength $patch] scope=[dict size $scopeBefore] scope_replaced=[expr {[dict size $scopeBefore] - $survivors}] ok=[dict get $outcome ok] rollback_ok=[dict get $outcome rollback_ok]"
    if {[dict exists $outcome error]} {
        P "CASE $tag error=[string map [list "\n" " | "] [dict get $outcome error]]"
    }
    set stripIds {}
    if {[dict exists $case stripIds]} { set stripIds [dict get $case stripIds] }
    if {[llength $stripIds] > 0} {
        set stripBefore [dict get $case stripConn]
        set stripNow [::MeshSeamWeld::readShellElementConnectivityBulk $stripIds 1]
        set intact 0
        dict for {id conn} $stripBefore {
            if {[dict exists $stripNow $id] && [dict get $stripNow $id] eq $conn} {
                incr intact
            }
        }
        P "CASE $tag strip_elements=[llength $stripIds] strip_intact=$intact strip_modified=[expr {[llength $stripIds]-$intact}]"
    }
    return $outcome
}

if {[catch {
    source -encoding utf-8 [file join $root modules mesh_seam_weld.tcl]
    rename ::HybridCore::log ::HybridCore::logOriginal
    proc ::HybridCore::log {level message} {
        if {[string toupper $level] eq "WARN" &&
            [string first "mesh_seam_weld" $message] == 0} {
            P "MODULE_WARN $message"
        }
        return [::HybridCore::logOriginal $level $message]
    }
    P "SOURCED [hm_info -appinfo VERSION]"

    # 1. layers: 0 (split only) vs 2 (default, quality remesh), no strip.
    probeRun A [probeStraightCase A 900 1100 2.5 5.0 0.0 5.0] 0 0
    probeRun B [probeStraightCase B 1200 1400 2.5 5.0 0.0 5.0] 2 0

    # 2. protection: existing SEAM strip on the base row next to the seam.
    probeRun C [probeStripCase C 1500 1700 2.5 5.0 5.0 2.5 SEAM_T9_PRE] 2 0
    probeRun D [probeStripCase D 1800 2000 2.5 5.0 5.0 2.5 SEAM_T9_PRE_D] 2 1

    # 3. strip two rows away with default layers.
    probeRun E [probeStripCase E 2100 2300 2.5 5.0 5.0 7.5 SEAM_T9_PRE2] 2 0

    # 4. more layers configured, no strip.
    probeRun F [probeStraightCase F 2400 2600 2.5 5.0 0.0 5.0] 4 0
    P "DONE"
} problem options]} {
    P "FAIL $problem"
    if {[dict exists $options -errorinfo]} { P [dict get $options -errorinfo] }
}
close $report
*quit 1