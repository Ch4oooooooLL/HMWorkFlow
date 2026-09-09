# Curved generalized-T probe: reproduce the mesh_seam_weld native Create Patch
# chain on a concentric-cylinder T joint (curved source rail + curved target
# surface, constant gap) and report exactly what the mixed element remesh does
# to the patch attachment boundary.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_curved_t_patch_boundary.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_curved_t_patch_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc L {text} {
    variable channel
    puts $channel "$text"
}
proc FXComp {name color} {
    *collectorcreateonly components $name "" $color
    return [hm_getvalue comps name=$name dataname=id]
}
proc FXNode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc FXQuad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}
proc Conn {elementId} {
    set nodes ""
    catch {set nodes [hm_getvalue elems id=$elementId dataname=nodes]}
    return $nodes
}
proc XYZ {nodeId} {
    catch {set coords [hm_getvalue nodes id=$nodeId dataname=coordinates]}
    return $coords
}
# Boundary edges of a shell element set: edges owned by exactly one element.
proc BoundaryEdges {elemIds} {
    array set counts {}
    foreach elemId $elemIds {
        set nodes [Conn $elemId]
        set count [llength $nodes]
        for {set i 0} {$i < $count} {incr i} {
            set a [lindex $nodes $i]
            set b [lindex $nodes [expr {($i + 1) % $count}]]
            if {$a > $b} { set t $a; set a $b; set b $t }
            lappend counts($a,$b) $elemId
        }
    }
    set result {}
    foreach key [lsort [array names counts]] {
        if {[llength $counts($key)] == 1} { lappend result $key }
    }
    return $result
}
proc Dist {p q} {
    set dx [expr {[lindex $p 0] - [lindex $q 0]}]
    set dy [expr {[lindex $p 1] - [lindex $q 1]}]
    set dz [expr {[lindex $p 2] - [lindex $q 2]}]
    return [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
}
# Distance from a point to the segment a-b.
proc SegDist {a b p} {
    set ax [lindex $a 0]; set ay [lindex $a 1]; set az [lindex $a 2]
    set bx [lindex $b 0]; set by [lindex $b 1]; set bz [lindex $b 2]
    set px [lindex $p 0]; set py [lindex $p 1]; set pz [lindex $p 2]
    set vx [expr {$bx-$ax}]; set vy [expr {$by-$ay}]; set vz [expr {$bz-$az}]
    set wx [expr {$px-$ax}]; set wy [expr {$py-$ay}]; set wz [expr {$pz-$az}]
    set vv [expr {$vx*$vx+$vy*$vy+$vz*$vz}]
    if {$vv <= 0} { return [Dist $a $p] }
    set t [expr {($wx*$vx+$wy*$vy+$wz*$vz)/$vv}]
    if {$t < 0} { set t 0 } elseif {$t > 1} { set t 1 }
    set dx [expr {$wx-$t*$vx}]; set dy [expr {$wy-$t*$vy}]; set dz [expr {$wz-$t*$vz}]
    return [expr {sqrt($dx*$dx+$dy*$dy+$dz*$dz)}]
}
proc MinPolylineDist {polyline p} {
    set best 1.0e30
    for {set i 0} {$i < [llength $polyline]} {incr i} {
        set a [XYZ [lindex $polyline $i]]
        set b [XYZ [lindex $polyline [expr {($i + 1) % [llength $polyline]}]]]
        set d [SegDist $a $b $p]
        if {$d < $best} { set best $d }
    }
    return $best
}

# --- Fixture: concentric cylinders, constant gap ------------------------------
# Target outer shell radius 100 (curved surface).  Source bulkhead radius 97;
# its free edge at x=0 is a circle (curved source path).  Gap = 3 mm.
set Rtarget 100.0
set Rsource 97.0
set gap 3.0
set dtheta 10.0
set dx 10.0
set xMax 40.0
set nTheta 9
set nX 4

set compTarget [FXComp PROBE_TARGET 3]
set compSource [FXComp PROBE_SOURCE 4]
set compSeam [FXComp SEAM_PROBE 5]

# Target mesh (outer shell).
*currentcollector component PROBE_TARGET
array set tNode {}
for {set i 0} {$i <= $nX} {incr i} {
    set x [expr {$i * $dx}]
    for {set j 0} {$j <= $nTheta} {incr j} {
        set ang [expr {$j * $dtheta * 3.14159265358979 / 180.0}]
        set tNode($i,$j) [FXNode $x [expr {$Rtarget * cos($ang)}] [expr {$Rtarget * sin($ang)}]]
    }
}
set targetElems {}
for {set i 0} {$i < $nX} {incr i} {
    for {set j 0} {$j < $nTheta} {incr j} {
        lappend targetElems [FXQuad [list $tNode($i,$j) $tNode([expr {$i+1}],$j) \
            $tNode([expr {$i+1}],[expr {$j+1}]) $tNode($i,[expr {$j+1}])]]
    }
}

# Source bulkhead mesh (radius 97).  Free edge at x=0 is the source path.
*currentcollector component PROBE_SOURCE
array set sNode {}
for {set i 0} {$i <= $nX} {incr i} {
    set x [expr {$i * $dx}]
    for {set j 0} {$j <= $nTheta} {incr j} {
        set ang [expr {$j * $dtheta * 3.14159265358979 / 180.0}]
        set sNode($i,$j) [FXNode $x [expr {$Rsource * cos($ang)}] [expr {$Rsource * sin($ang)}]]
    }
}
set sourceElems {}
for {set i 0} {$i < $nX} {incr i} {
    for {set j 0} {$j < $nTheta} {incr j} {
        lappend sourceElems [FXQuad [list $sNode($i,$j) $sNode([expr {$i+1}],$j) \
            $sNode([expr {$i+1}],[expr {$j+1}]) $sNode($i,[expr {$j+1}])]]
    }
}
set sourcePath {}
for {set j 0} {$j <= $nTheta} {incr j} { lappend sourcePath $sNode(0,$j) }
P "SOURCE_PATH_NODES" [llength $sourcePath]
P "GAP" $gap
P "TARGET_ELEMS" [llength $targetElems]
P "SOURCE_ELEMS" [llength $sourceElems]

# --- Native Create Patch (same options as runImprintNodeList createPatch) -----
set beforeSeam {}
catch {set beforeSeam [hm_getvalue comps name=SEAM_PROBE dataname=entitycount]}
*currentcollector component SEAM_PROBE
catch {*clearlist nodes 2}
eval *createlist nodes 1 $sourcePath
*createmark elements 2 $targetElems
set options "remain 3 to_dest_component 0 remesh_layers 2 remesh_mode 2 angle 30.000000 create_joint_elems 1 close_node_list 0"
set imprintErr "none"
set code [catch {*imprint_nodelist 1 elements 2 $options} imprintErr]
P "IMPRINT_CODE" $code
P "IMPRINT_ERR" $imprintErr
catch {*createmark elems 1 "by comp" SEAM_PROBE}
set patchElems [hm_getmark elems 1]
catch {*clearmark elems 1}
P "PATCH_ELEMS" [llength $patchElems]
if {[llength $patchElems] == 0} {
    P "VERDICT" "NO_PATCH"
    close $channel
    return
}
P "PATCH_IDS" [join [lsort -integer $patchElems] ,]
set patchShape {}
foreach eid $patchElems { lappend patchShape "[Conn $eid]|[llength [Conn $eid]]" }
P "PATCH_CONN" [join $patchShape { }]

set boundaryBefore [BoundaryEdges $patchElems]
P "BOUNDARY_BEFORE_COUNT" [llength $boundaryBefore]
P "BOUNDARY_BEFORE" [join $boundaryBefore { }]
set fixedNodes {}
foreach edge $boundaryBefore {
    foreach n [split $edge ,] { if {[lsearch -exact $fixedNodes $n] < 0} { lappend fixedNodes $n } }
}
P "FIXED_NODES" [llength $fixedNodes]

# --- Mixed element remesh exactly as the module does --------------------------
eval *createmark elems 1 $patchElems
eval *createmark nodes 2 $fixedNodes
set fixErr "none"
set code [catch {*elementsaddnodesfixed 1 2} fixErr]
P "FIXNODES_CODE" $code
P "FIXNODES_ERR" $fixErr
set remeshErr "none"
set code [catch {*defaultremeshelems 1 8 2 2 1 1 1 1 0 0 0 0 2 30} remeshErr]
P "REMESH_CODE" $code
P "REMESH_ERR" $remeshErr

catch {*createmark elems 1 "by comp" SEAM_PROBE}
set weldElems [hm_getmark elems 1]
catch {*clearmark elems 1}
P "WELD_ELEMS" [llength $weldElems]
P "WELD_IDS" [join [lsort -integer $weldElems] ,]
set weldShape {}
foreach eid $weldElems { lappend weldShape "[Conn $eid]|[llength [Conn $eid]]" }
P "WELD_CONN" [join $weldShape { }]

set boundaryAfter [BoundaryEdges $weldElems]
P "BOUNDARY_AFTER_COUNT" [llength $boundaryAfter]
P "BOUNDARY_AFTER" [join $boundaryAfter { }]

# Which original boundary nodes survived as boundary nodes?
array set afterNodes {}
foreach edge $boundaryAfter {
    foreach n [split $edge ,] { set afterNodes($n) 1 }
}
set lostNodes {}
foreach n $fixedNodes { if {![info exists afterNodes($n)]} { lappend lostNodes $n } }
P "LOST_BOUNDARY_NODES" [llength $lostNodes]
P "LOST_BOUNDARY_NODE_IDS" [join $lostNodes ,]

# Which before edges are neither preserved nor replaced by a collinear chain?
array set afterAdj {}
foreach edge $boundaryAfter {
    set pair [split $edge ,]
    set a [lindex $pair 0]; set b [lindex $pair 1]
    lappend afterAdj($a) $b
    lappend afterAdj($b) $a
}
set newBoundaryNodes {}
foreach n [array names afterNodes] {
    if {[lsearch -exact $fixedNodes $n] < 0} { lappend newBoundaryNodes $n }
}
P "NEW_BOUNDARY_NODES" [llength $newBoundaryNodes]

# Report every new boundary node: nearest original segment and deviation.
set polyline {}
foreach n $fixedNodes { lappend polyline $n }
foreach n $newBoundaryNodes {
    set p [XYZ $n]
    set best 1.0e30; set bestSeg ""
    foreach edge $boundaryBefore {
        set pair [split $edge ,]
        set a [lindex $pair 0]; set b [lindex $pair 1]
        set d [SegDist [XYZ $a] [XYZ $b] $p]
        if {$d < $best} { set best $d; set bestSeg "$a-$b" }
    }
    set segLen 0.0
    if {$bestSeg ne ""} {
        set pair [split $bestSeg -]
        set segLen [Dist [XYZ [lindex $pair 0]] [XYZ [lindex $pair 1]]]
    }
    P "NEW_NODE $n" "nearest_segment=$bestSeg deviation=[format %.6f $best] segment_length=[format %.6f $segLen] relative=[format %.6f [expr {$segLen > 0 ? $best/$segLen : 0}]]"
}

# Rebuild the relaxed check verdict the way executor.tcl does it.
set changed 0
array set seenBefore {}
foreach edge $boundaryBefore { set seenBefore($edge) 1 }
array set seenAfter {}
foreach edge $boundaryAfter { set seenAfter($edge) 1 }
foreach edge $boundaryBefore {
    if {[info exists seenAfter($edge)]} { continue }
    set pair [split $edge ,]
    set a [lindex $pair 0]; set b [lindex $pair 1]
    set found 0
    if {[info exists afterAdj($a)] && [lsearch -exact $afterAdj($a) $b] >= 0} { set found 1 }
    if {!$found} { incr changed; P "BEFORE_EDGE_NOT_PRESERVED" $edge }
}
foreach edge $boundaryAfter {
    if {[info exists seenBefore($edge)]} { continue }
    set pair [split $edge ,]
    set a [lindex $pair 0]; set b [lindex $pair 1]
    set onOriginal 0
    foreach bedge $boundaryBefore {
        set bpair [split $bedge ,]
        set c [lindex $bpair 0]; set d [lindex $bpair 1]
        set ca [XYZ $c]; set cd [XYZ $d]
        if {[SegDist $ca $cd [XYZ $a]] <= 1.0e-3 * [Dist $ca $cd] &&
            [SegDist $ca $cd [XYZ $b]] <= 1.0e-3 * [Dist $ca $cd]} { set onOriginal 1; break }
    }
    if {!$onOriginal} { incr changed; P "AFTER_EDGE_NOT_ON_ORIGINAL" "$edge endpoints_a=[join [XYZ $a] ,] b=[join [XYZ $b] ,]" }
}
P "RELAXED_CHECK_CHANGED" $changed
P "VERDICT" [expr {$changed ? "REJECTED" : "ACCEPTED"}]

close $channel
puts "report written to $reportPath"
