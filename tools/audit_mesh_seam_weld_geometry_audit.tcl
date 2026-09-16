# Real-machine probe: which shells does the structural geometry audit reject on
# legitimate native-patch imprint/remesh output, and why?
#
# Field report (2026-09-10 18:05, module 0.63): paths 2/4 and 3/4 of one batch
# were blocked with
#   [MSW_STAGE:AUTOMESH] Near-collapsed shell corner: 245959 348487 348488
#   [MSW_STAGE:AUTOMESH] Folded, twisted or self-intersecting shell: ...
# on every retry (mesh size 8 -> 4.8 -> 12), i.e. the rejected shell does not
# depend on the weld mesh size, while the same weld can be created by hand
# without HyperMesh reporting anything.
#
# The probe builds T joints whose source rail is the fixed input of the patch:
# straight rails (including rails with a tight node pair, which the patch has to
# reproduce) and closed circular free-edge loops, runs the real path, then
# repeats a rejected path with the audit in record-only mode and dumps the
# metrics of every rejected shell plus its owning collector.
#
# Run in a fresh hmbatch process:
#   "D:/Program Files/Altair/2019/hm/bin/win64/hmbatch.exe" \
#     -nocommand -nouserprofiledialog -tcl \
#     tools/audit_mesh_seam_weld_geometry_audit.tcl
# Judge by runtime/msw_geometry_audit_probe.log (hmbatch itself exits with 1).

set root [file normalize [file join [file dirname [info script]] ..]]
set report [open [file join $root runtime msw_geometry_audit_probe.log] w]
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

proc probeJoin {values} {
    set text {}
    foreach value $values { lappend text $value }
    return [join $text ,]
}

# Metrics of one rejected shell, in the same quantities the audit tests.
proc probeShellMetrics {nodes coordinates} {
    set count [llength $nodes]
    set lengths {}
    set cosines {}
    set normals {}
    for {set i 0} {$i < $count} {incr i} {
        set p [dict get $coordinates [lindex $nodes $i]]
        set q [dict get $coordinates [lindex $nodes [expr {($i+1)%$count}]]]
        set r [dict get $coordinates [lindex $nodes [expr {($i+$count-1)%$count}]]]
        set a [::MeshSeamWeld::vsub $q $p]
        set b [::MeshSeamWeld::vsub $r $p]
        set aa [::MeshSeamWeld::dot $a $a]; set bb [::MeshSeamWeld::dot $b $b]
        if {$aa <= 1.0e-18 || $bb <= 1.0e-18} {
            lappend lengths 0.0; lappend cosines 0.0; lappend normals {0 0 0}
            continue
        }
        set length [expr {sqrt($aa)}]
        set other [expr {sqrt($bb)}]
        lappend lengths $length
        lappend cosines [expr {[::MeshSeamWeld::dot $a $b]/($length*$other)}]
        lappend normals [::MeshSeamWeld::cross $a $b]
    }
    set sorted [lsort -real $lengths]
    set aspect [expr {[lindex $sorted end]/max(1.0e-12,[lindex $sorted 0])}]
    set reference [lindex $normals 0]
    set referenceDot [::MeshSeamWeld::dot $reference $reference]
    set alignments {}
    foreach normal $normals {
        set denom [expr {sqrt($referenceDot*[::MeshSeamWeld::dot $normal $normal])}]
        if {$denom <= 1.0e-20} { lappend alignments 0.0; continue }
        lappend alignments [format %.4f [expr {[::MeshSeamWeld::dot $reference $normal]/$denom}]]
    }
    set angles {}
    foreach cosine $cosines {
        if {$cosine > 1.0} { set cosine 1.0 }
        if {$cosine < -1.0} { set cosine -1.0 }
        lappend angles [format %.4f [expr {180.0*acos($cosine)/acos(-1.0)}]]
    }
    set area [::MeshSeamWeld::shellArea $nodes $coordinates]
    set longest [lindex $sorted end]
    set ratio [expr {$area/max(1.0e-18,$longest*$longest)}]
    set owner "unknown"
    catch {
        foreach elemId [::MeshSeamWeld::adjacentElementsForNodes $nodes] {
            if {[lsort -integer [::MeshSeamWeld::elemNodes $elemId]] eq \
                    [lsort -integer $nodes]} {
                set owner "[::MeshSeamWeld::elemComponentId $elemId]/elem$elemId"
                break
            }
        }
    }
    set lengthsText {}
    foreach value [lsort -real $lengths] { lappend lengthsText [format %.6g $value] }
    return "owner=$owner nodes=[probeJoin $nodes] edges=[probeJoin $lengthsText] aspect=[format %.3f $aspect] area_over_L2=[format %.3g $ratio] angles=[probeJoin $angles] align=[probeJoin $alignments]"
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

proc probeBuildWeb {webName} {
    set webComp [hm_getvalue comps name=$webName dataname=id]
    return $webComp
}

# Straight rail T joint.  needleGap > 0 inserts one extra rail node that close
# to the middle rail node, i.e. a tight CAD edge the patch has to reproduce.
proc probeStraightCase {tag left right railZ railSpacing angleDeg baseSize needleGap} {
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
        if {$needleGap > 0.0 && $i == int($steps/2)} {
            set tiny [expr {$t + $needleGap}]
            lappend railPoints [list [expr {$cx + $tiny*$cosA}] \
                [expr {$tiny*$sinA}] $railZ]
        }
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

# Closed circular free-edge loop of a tube standing on the plate.
proc probeCircleCase {tag cx cy railZ radius segments baseSize} {
    set margin [expr {max(20.0,4.0*$baseSize)}]
    set baseComp [probeBuildPlate "BASE_$tag" \
        [expr {$cx-$radius-$margin+0.5*$baseSize}] \
        [expr {$cy-$radius-$margin+0.5*$baseSize}] \
        [expr {$cx+$radius+$margin}] [expr {$cy+$radius+$margin}] $baseSize]
    set railNodes {}
    set topNodes {}
    *collectorcreateonly components "WEB_$tag" "" 22
    *currentcollector component "WEB_$tag"
    for {set i 0} {$i < $segments} {incr i} {
        set angle [expr {2.0*acos(-1.0)*$i/$segments}]
        set x [expr {$cx + $radius*cos($angle)}]
        set y [expr {$cy + $radius*sin($angle)}]
        lappend railNodes [probeNode $x $y $railZ]
        lappend topNodes [probeNode $x $y [expr {$railZ+15.0}]]
    }
    for {set i 0} {$i < $segments} {incr i} {
        set next [expr {($i+1)%$segments}]
        probeQuad [list [lindex $railNodes $i] [lindex $railNodes $next] \
            [lindex $topNodes $next] [lindex $topNodes $i]]
    }
    set webComp [probeBuildWeb "WEB_$tag"]
    return [dict create rail $railNodes top $topNodes baseComp $baseComp \
        webComp $webComp closed 1]
}

set ::auditMode strict
set ::auditRejections {}
set ::auditStrictCount 0
set ::auditCurrentTag ""
array set ::probeCase {}
array set ::probePatch {}

# Wraps the module audit so a rejected shell can either fail the path (strict,
# production behaviour) or be recorded with its metrics (record mode).
proc probeInstallAuditHook {} {
    rename ::MeshSeamWeld::shellGeometryAudit ::MeshSeamWeld::shellGeometryAuditOriginal
    proc ::MeshSeamWeld::shellGeometryAudit {nodes coordinates} {
        set code [catch {::MeshSeamWeld::shellGeometryAuditOriginal $nodes $coordinates} area]
        if {!$code} { return $area }
        if {$::auditMode eq "strict"} {
            incr ::auditStrictCount
            return -code error $area
        }
        lappend ::auditRejections [dict create tag $::auditCurrentTag error $area \
            metrics [probeShellMetrics $nodes $coordinates]]
        return [::MeshSeamWeld::shellArea $nodes $coordinates]
    }
}

proc probeRunPath {tag size} {
    set case $::probeCase($tag)
    set rail [dict get $case rail]
    set baseComp [dict get $case baseComp]
    set webComp [dict get $case webComp]
    set closedLoop [dict get $case closed]
    set ::MeshSeamWeld::cfg(weld_mesh_size) $size
    set seamComp "SEAM_$tag"
    if {![info exists ::probePatch($tag)] || [llength $::probePatch($tag)] == 0} {
        set prepared [::MeshSeamWeld::prepareCurrentTargetPatch $rail [list $baseComp] $closedLoop]
        set ::probePatch($tag) [dict get $prepared target_elements]
    }
    set patch $::probePatch($tag)
    if {[llength $patch] == 0} { return [dict create ok 0 error "PATCH_EMPTY" rollback_ok 1] }
    return [::MeshSeamWeld::processWeldPathIsolated $rail [list $baseComp] $closedLoop 0 1 1 \
        [list $webComp] $seamComp {} $patch 0]
}

proc probeText {value} {
    return [string map [list "\n" " | "] $value]
}

proc probeGeometryBlock {text} {
    foreach marker {"Near-collapsed shell corner" "Folded, twisted or self-intersecting" \
            "Collapsed shell aspect ratio" "Collapsed (zero-area) shell" "Collapsed shell"} {
        if {[string first $marker $text] >= 0} { return 1 }
    }
    return 0
}

proc probeCase {tag builder args} {
    set ::probeCase($tag) [$builder $tag {*}$args]
    unset -nocomplain ::probePatch($tag)
    set case $::probeCase($tag)
    set ::auditStrictCount 0
    set ::auditMode strict
    set ::auditCurrentTag $tag
    set outcome [probeRunPath $tag 8.0]
    set text ""
    if {[dict exists $outcome error]} { set text [dict get $outcome error] }
    P "CASE $tag rail=[llength [dict get $case rail]] closed=[dict get $case closed] patch=[llength $::probePatch($tag)] ok=[dict get $outcome ok] rollback_ok=[dict get $outcome rollback_ok] strict_rejections=$::auditStrictCount"
    if {$text ne ""} { P "CASE $tag strict_error=[probeText $text]" }
    if {[dict get $outcome ok]} { return }
    if {![probeGeometryBlock $text]} {
        P "CASE $tag NOT_A_GEOMETRY_BLOCK"
        return
    }
    # Same path with the audit recording instead of failing: the rejected
    # shells and their metrics become visible.
    set ::auditRejections {}
    set ::auditMode record
    set lenient [probeRunPath $tag 8.0]
    P "CASE $tag record_rejections=[llength $::auditRejections] record_ok=[dict get $lenient ok]"
    foreach record $::auditRejections {
        P "CASE $tag REJECTED error={[dict get $record error]} [dict get $record metrics]"
    }
    if {[dict exists $lenient error]} {
        P "CASE $tag record_error=[probeText [dict get $lenient error]]"
    }
}

if {[catch {
    source -encoding utf-8 [file join $root modules mesh_seam_weld.tcl]
    # Tee the module's own WARN lines into the probe report, so "distorted but
    # usable" is visible next to the weld outcome.
    rename ::HybridCore::log ::HybridCore::logOriginal
    proc ::HybridCore::log {level message} {
        if {[string toupper $level] eq "WARN" &&
            [string first "mesh_seam_weld" $message] == 0} {
            P "MODULE_WARN $message"
        }
        return [::HybridCore::logOriginal $level $message]
    }
    probeInstallAuditHook
    P "SOURCED [hm_info -appinfo VERSION]"

    probeCase G0 probeStraightCase 900 1100 2.5 5.00 0.0 5.0 0.0
    probeCase L1 probeStraightCase  900 1100 2.5 5.00 0.0 5.0 0.0
    probeCase L2 probeStraightCase 1500 1700 2.5 5.00 0.0 5.0 0.02
    probeCase L3 probeStraightCase 2100 2300 2.5 5.00 0.0 5.0 0.20
    probeCase L4 probeStraightCase 2700 2900 2.5 0.50 0.0 5.0 0.0
    probeCase L5 probeStraightCase 3300 3500 8.0 5.00 0.0 5.0 0.0
    probeCase R1 probeCircleCase 4000 0 2.5 12.0 20 5.0
    probeCase R2 probeCircleCase 4600 0 0.5 12.0 20 5.0
    probeCase R3 probeCircleCase 5200 0 2.5 12.0 60 5.0
    probeCase R4 probeCircleCase 5800 0 2.5  3.0 20 5.0
    P "DONE"
} problem options]} {
    P "FAIL $problem"
    if {[dict exists $options -errorinfo]} { P [dict get $options -errorinfo] }
}
close $report
*quit 1
