# Isolated probe: what does *defaultremeshelems do to the boundary of a curved
# shell strip whose boundary nodes are all fixed?  Dumps coordinates, edge
# lengths and per-new-node deviation from the original boundary polyline.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_curved_strip_remesh.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_curved_strip_remesh_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
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
    set x 0.0; set y 0.0; set z 0.0
    catch {lassign [hm_getvalue nodes id=$nodeId dataname=coordinates] x y z}
    return [list $x $y $z]
}
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

# --- Fixture: curved strip patch, no geometry association ---------------------
# Source rail: circle radius 97 at x=0.  Target rail: circle radius 100 at
# x=0 (radial projection).  Strip is 3 mm wide, curved.  Both rails are chords.
set Rsource 97.0
set Rtarget 100.0
set dtheta 10.0
set nSeg 9
set compPatch [FXComp PROBE_STRIP 6]
*currentcollector component PROBE_STRIP

array set sNode {}
array set tNode {}
for {set j 0} {$j <= $nSeg} {incr j} {
    set ang [expr {$j * $dtheta * 3.14159265358979 / 180.0}]
    set sNode($j) [FXNode 0 [expr {$Rsource * cos($ang)}] [expr {$Rsource * sin($ang)}]]
    set tNode($j) [FXNode 0 [expr {$Rtarget * cos($ang)}] [expr {$Rtarget * sin($ang)}]]
}
set stripElems {}
for {set j 0} {$j < $nSeg} {incr j} {
    lappend stripElems [FXQuad [list $sNode($j) $tNode($j) $tNode([expr {$j+1}]) $sNode([expr {$j+1}])]]
}
P "STRIP_ELEMS" [llength $stripElems]
P "STRIP_IDS" [join $stripElems ,]
P "NODE_S0" "$sNode(0) [join [XYZ $sNode(0)] ,]"
P "NODE_T0" "$tNode(0) [join [XYZ $tNode(0)] ,]"
P "GAP_MEASURED" [format %.6f [Dist [XYZ $sNode(0)] [XYZ $tNode(0)]]]

set boundaryBefore [BoundaryEdges $stripElems]
P "BOUNDARY_BEFORE_COUNT" [llength $boundaryBefore]
foreach edge $boundaryBefore {
    set pair [split $edge ,]
    set a [lindex $pair 0]; set b [lindex $pair 1]
    P "BEFORE_EDGE $edge" "length=[format %.6f [Dist [XYZ $a] [XYZ $b]]]"
}
set fixedNodes {}
foreach edge $boundaryBefore {
    foreach n [split $edge ,] { if {[lsearch -exact $fixedNodes $n] < 0} { lappend fixedNodes $n } }
}
P "FIXED_NODES" [llength $fixedNodes]

# --- Remesh exactly as executor.tcl does --------------------------------------
eval *createmark elems 1 $stripElems
eval *createmark nodes 2 $fixedNodes
catch {*elementsaddnodesfixed 1 2}
set remeshErr "none"
set code [catch {*defaultremeshelems 1 8 2 2 1 1 1 1 0 0 0 0 2 30} remeshErr]
P "REMESH_CODE" $code
P "REMESH_ERR" $remeshErr

catch {*createmark elems 1 "by comp" PROBE_STRIP}
set weldElems [hm_getmark elems 1]
catch {*clearmark elems 1}
P "WELD_ELEMS" [llength $weldElems]
P "WELD_IDS" [join $weldElems ,]

set boundaryAfter [BoundaryEdges $weldElems]
P "BOUNDARY_AFTER_COUNT" [llength $boundaryAfter]
foreach edge $boundaryAfter {
    set pair [split $edge ,]
    set a [lindex $pair 0]; set b [lindex $pair 1]
    P "AFTER_EDGE $edge" "length=[format %.6f [Dist [XYZ $a] [XYZ $b]]] a=[join [XYZ $a] ,] b=[join [XYZ $b] ,]"
}

array set afterNodes {}
foreach edge $boundaryAfter {
    foreach n [split $edge ,] { set afterNodes($n) 1 }
}
set lostNodes {}
foreach n $fixedNodes { if {![info exists afterNodes($n)]} { lappend lostNodes $n } }
P "LOST_BOUNDARY_NODES" [join $lostNodes ,]
set newNodes {}
foreach n [array names afterNodes] {
    if {[lsearch -exact $fixedNodes $n] < 0} { lappend newNodes $n }
}
P "NEW_BOUNDARY_NODES" [join $newNodes ,]
foreach n $newNodes {
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
    P "NEW_NODE $n" "xyz=[join $p ,] nearest_segment=$bestSeg deviation=[format %.6f $best] seg_len=[format %.6f $segLen] relative=[format %.6f [expr {$segLen > 0 ? $best/$segLen : 0}]]"
}
close $channel
