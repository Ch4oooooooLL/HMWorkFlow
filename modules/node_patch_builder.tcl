# ============================================================================
# Node Patch Builder
# Ordered local shell repair for HyperMesh 2019 / 2022.
# Sourcing this file never opens a window or changes the model.
# ============================================================================

namespace eval ::NodePatch {
    variable VERSION "1.1"
    variable cfg
    array set cfg {
        debug 0
        edge_line_tol_factor 0.25
        node_snap_tol_factor 0.05
        edge_path_angle_tol 20.0
        surface_angle_tol 25.0
        path_length_ratio_max 1.20
        path_ambiguity_ratio 1.05
        planarity_tol_factor 0.30
        min_edge_factor 0.15
        max_trace_elements 100
        max_graph_states 1200
        # One cap per boundary side. A many-sided shell boundary multiplies the
        # corner-to-corner corridors a single analysis may expand, so the per
        # side budgets shrink proportionally and stay divisible by the number
        # of sides (max 10/1200 for the historical 3/4-node boundary).
        max_boundary_corners 50
        trace_budget_per_side 10
        graph_budget_per_side 120
        output_component_mode new
        output_component_prefix PATCH
    }
    variable selectedNodes {}
    variable selectedMeshSize 0.0
    variable previewResult {}
    variable lastHistoryAvailable 0
    variable ui
    array set ui {status "Select at least 3 boundary corner nodes in perimeter order."}
}

proc ::NodePatch::tr {zh en} {
    if {[llength [info commands ::HWFlow::txt]] > 0} { return [::HWFlow::txt $zh $en] }
    return $en
}

proc ::NodePatch::log {level message} {
    variable cfg
    if {$level eq "DEBUG" && !$cfg(debug)} { return }
    catch {puts [format {[NodePatch][%s] %s} $level $message]}
}

proc ::NodePatch::fail {code message} { error [format {[NodePatch][ERROR][%s] %s} $code $message] }

proc ::NodePatch::uniq {items} {
    set out {}; array set seen {}
    foreach item $items { if {![info exists seen($item)]} { set seen($item) 1; lappend out $item } }
    return $out
}

proc ::NodePatch::vadd {a b} { return [list [expr {[lindex $a 0]+[lindex $b 0]}] [expr {[lindex $a 1]+[lindex $b 1]}] [expr {[lindex $a 2]+[lindex $b 2]}]] }
proc ::NodePatch::vsub {a b} { return [list [expr {[lindex $a 0]-[lindex $b 0]}] [expr {[lindex $a 1]-[lindex $b 1]}] [expr {[lindex $a 2]-[lindex $b 2]}]] }
proc ::NodePatch::vscale {a s} { return [list [expr {[lindex $a 0]*$s}] [expr {[lindex $a 1]*$s}] [expr {[lindex $a 2]*$s}]] }
proc ::NodePatch::vdot {a b} { return [expr {[lindex $a 0]*[lindex $b 0]+[lindex $a 1]*[lindex $b 1]+[lindex $a 2]*[lindex $b 2]}] }
proc ::NodePatch::vcross {a b} { return [list [expr {[lindex $a 1]*[lindex $b 2]-[lindex $a 2]*[lindex $b 1]}] [expr {[lindex $a 2]*[lindex $b 0]-[lindex $a 0]*[lindex $b 2]}] [expr {[lindex $a 0]*[lindex $b 1]-[lindex $a 1]*[lindex $b 0]}]] }
proc ::NodePatch::vlength {a} { return [expr {sqrt([::NodePatch::vdot $a $a])}] }
proc ::NodePatch::vunit {a} { set n [::NodePatch::vlength $a]; if {$n < 1.0e-14} { error "zero length vector" }; return [::NodePatch::vscale $a [expr {1.0/$n}]] }
proc ::NodePatch::distance {a b} { return [::NodePatch::vlength [::NodePatch::vsub $a $b]] }
proc ::NodePatch::clamp {x lo hi} { if {$x<$lo} {return $lo}; if {$x>$hi} {return $hi}; return $x }
proc ::NodePatch::angleDeg {a b {unsigned 0}} {
    set d [expr {[::NodePatch::vdot [::NodePatch::vunit $a] [::NodePatch::vunit $b]]}]
    if {$unsigned} { set d [expr {abs($d)}] }
    return [expr {acos([::NodePatch::clamp $d -1.0 1.0])*180.0/acos(-1.0)}]
}
proc ::NodePatch::pointSegmentDistance {p a b} {
    set ab [::NodePatch::vsub $b $a]; set dd [::NodePatch::vdot $ab $ab]
    if {$dd < 1.0e-20} { return [::NodePatch::distance $p $a] }
    set t [::NodePatch::clamp [expr {[::NodePatch::vdot [::NodePatch::vsub $p $a] $ab]/$dd}] 0.0 1.0]
    return [::NodePatch::distance $p [::NodePatch::vadd $a [::NodePatch::vscale $ab $t]]]
}

proc ::NodePatch::edgeKey {a b} { if {$a<$b} {return "$a,$b"}; return "$b,$a" }
proc ::NodePatch::elementEdges {nodes} {
    set out {}; set n [llength $nodes]
    for {set i 0} {$i<$n} {incr i} { lappend out [list [lindex $nodes $i] [lindex $nodes [expr {($i+1)%$n}]]] }
    return $out
}

proc ::NodePatch::nodeXYZ {nodeId} {
    foreach axis {x y z} {
        if {[catch {set value [hm_getvalue nodes id=$nodeId dataname=$axis]}]} {
            if {![catch {set xyz [hm_nodevalue $nodeId]}] && [llength $xyz]>=3} { return [lrange $xyz 0 2] }
            ::NodePatch::fail F03 "Cannot read coordinates for node $nodeId."
        }
        lappend xyz $value
    }
    return $xyz
}

proc ::NodePatch::elemNodes {elemId} {
    set nodes {}
    catch {set nodes [hm_getvalue elems id=$elemId dataname=nodes]}
    if {[llength $nodes]==0} { catch {set nodes [hm_nodelist $elemId]} }
    set nodes [::NodePatch::uniq $nodes]
    # The local repair and trace geometry is defined on TRIA3/QUAD4 shells.
    if {[llength $nodes] ni {3 4}} { return {} }
    return $nodes
}

proc ::NodePatch::nodeElements {nodeId} {
    foreach dn {elems elements} {
        if {![catch {set ids [hm_getvalue nodes id=$nodeId dataname=$dn]}] && [llength $ids]>0} {
            set out {}; foreach id [::NodePatch::uniq $ids] { if {[llength [::NodePatch::elemNodes $id]] in {3 4}} {lappend out $id} }; return $out
        }
    }
    set out {}
    foreach selector [list [list "by node id" $nodeId] [list "by node" $nodeId] [list "by nodes" $nodeId]] {
        catch {*clearmark elems 2}
        if {![catch {eval *createmark elems 2 $selector}]} { catch {set out [hm_getmark elems 2]} }
        catch {*clearmark elems 2}
        if {[llength $out]>0} { break }
    }
    set shell {}; foreach id [::NodePatch::uniq $out] {if {[llength [::NodePatch::elemNodes $id]] in {3 4}} {lappend shell $id}}
    return $shell
}

proc ::NodePatch::edgeElements {a b} {
    set right {}; array set inB {}
    foreach e [::NodePatch::nodeElements $b] {set inB($e) 1}
    foreach e [::NodePatch::nodeElements $a] {if {[info exists inB($e)] && [lsearch -exact [::NodePatch::elementEdges [::NodePatch::elemNodes $e]] [list $a $b]]>=0} {lappend right $e; continue}; if {[info exists inB($e)] && [lsearch -exact [::NodePatch::elementEdges [::NodePatch::elemNodes $e]] [list $b $a]]>=0} {lappend right $e}}
    return [::NodePatch::uniq $right]
}

proc ::NodePatch::elementNormal {nodes} {
    set p0 [::NodePatch::nodeXYZ [lindex $nodes 0]]; set p1 [::NodePatch::nodeXYZ [lindex $nodes 1]]; set p2 [::NodePatch::nodeXYZ [lindex $nodes 2]]
    return [::NodePatch::vunit [::NodePatch::vcross [::NodePatch::vsub $p1 $p0] [::NodePatch::vsub $p2 $p0]]]
}

proc ::NodePatch::localMeshSize {a b} {
    set lengths {}
    foreach node [list $a $b] {
        foreach elem [::NodePatch::nodeElements $node] {
            foreach edge [::NodePatch::elementEdges [::NodePatch::elemNodes $elem]] {
                lappend lengths [::NodePatch::distance [::NodePatch::nodeXYZ [lindex $edge 0]] [::NodePatch::nodeXYZ [lindex $edge 1]]]
            }
        }
    }
    if {[llength $lengths]==0} { ::NodePatch::fail F03 "Selected nodes do not belong to shell elements." }
    set lengths [lsort -real $lengths]; return [lindex $lengths [expr {[llength $lengths]/2}]]
}

# Corner neighbourhood scale for a boundary of any side count. Only elements
# touching the selected corners are sampled, so no side count multiplies the
# scan into the surrounding model.
proc ::NodePatch::boundaryMeshSize {corners} {
    set lengths {}
    foreach node $corners {
        foreach elem [::NodePatch::nodeElements $node] {
            foreach edge [::NodePatch::elementEdges [::NodePatch::elemNodes $elem]] {
                lappend lengths [::NodePatch::distance [::NodePatch::nodeXYZ [lindex $edge 0]] [::NodePatch::nodeXYZ [lindex $edge 1]]]
            }
        }
    }
    if {[llength $lengths]==0} { ::NodePatch::fail F03 "Selected nodes do not belong to shell elements." }
    set lengths [lsort -real $lengths]; return [lindex $lengths [expr {[llength $lengths]/2}]]
}

# Per side caps for one corner-to-corner side. A boundary with many corners
# multiplies the corridors a single analysis expands, so each side receives a
# proportionally smaller share of the whole-boundary budget instead of the flat
# historical 3/4-node allowance; the floor keeps small boundaries fully covered.
proc ::NodePatch::sideBudgets {sides totalPerSide floorTotal} {
    set sides [expr {$sides<1 ? 1 : $sides}]
    set perSide [expr {$totalPerSide/$sides}]
    if {$perSide<1} { set perSide 1 }
    set total [expr {$perSide*$sides}]
    if {$total<$floorTotal} { set total $floorTotal }
    return [list $perSide $total]
}

proc ::NodePatch::validateCorners {nodes} {
    variable cfg
    set count [llength $nodes]
    if {$count<3} { ::NodePatch::fail F01 "Select at least 3 boundary corner nodes." }
    if {$count>$cfg(max_boundary_corners)} { ::NodePatch::fail F01 "A patch boundary accepts at most $cfg(max_boundary_corners) corner nodes, got $count." }
    if {[llength [lsort -integer -unique $nodes]] != $count} { ::NodePatch::fail F02 "Duplicate corner nodes are not allowed." }
    foreach n $nodes { if {[llength [::NodePatch::nodeElements $n]]==0} {::NodePatch::fail F03 "Node $n does not belong to a TRIA3/QUAD4 shell."} }
    return $nodes
}

# Returns graph edges in a narrow capsule around AB. Expansion starts at A and
# therefore never scans the complete model.
proc ::NodePatch::candidateEdgeGraph {a b h {maxStates 0}} {
    variable cfg
    if {$maxStates<=0} { set maxStates $cfg(max_graph_states) }
    set pa [::NodePatch::nodeXYZ $a]; set pb [::NodePatch::nodeXYZ $b]
    set tol [expr {$cfg(edge_line_tol_factor)*$h}]
    set queue [list $a]; array set visited {}; set graph [dict create]; set states 0
    while {[llength $queue]>0 && $states<$maxStates} {
        set node [lindex $queue 0]; set queue [lrange $queue 1 end]
        if {[info exists visited($node)]} {continue}; set visited($node) 1; incr states
        foreach elem [::NodePatch::nodeElements $node] {
            set en [::NodePatch::elemNodes $elem]
            foreach edge [::NodePatch::elementEdges $en] {
                foreach {u v} $edge break
                if {$u!=$node && $v!=$node} {continue}
                set other [expr {$u==$node ? $v : $u}]
                set po [::NodePatch::nodeXYZ $other]
                if {[::NodePatch::pointSegmentDistance $po $pa $pb] > $tol && $other!=$b} {continue}
                if {[llength [::NodePatch::edgeElements $node $other]]>2} {::NodePatch::fail F07 "Non-manifold edge [::NodePatch::edgeKey $node $other] detected."}
                dict lappend graph $node $other; dict lappend graph $other $node
                if {![info exists visited($other)]} {lappend queue $other}
            }
        }
    }
    return $graph
}

proc ::NodePatch::stateCompare {x y} {
    set a [lindex $x 0]; set b [lindex $y 0]
    if {$a<$b} {return -1}; if {$a>$b} {return 1}; return 0
}

proc ::NodePatch::existingEdgeChain {a b h {maxStates 0}} {
    variable cfg
    if {$maxStates<=0} { set maxStates $cfg(max_graph_states) }
    set graph [::NodePatch::candidateEdgeGraph $a $b $h $maxStates]
    if {![dict exists $graph $a]} {return {}}
    set pa [::NodePatch::nodeXYZ $a]; set pb [::NodePatch::nodeXYZ $b]; set abLen [::NodePatch::distance $pa $pb]
    if {$abLen<1.0e-12} {return {}}
    set open [list [list 0.0 [list $a]]]; set solutions {}; set expanded 0
    while {[llength $open]>0 && $expanded<$maxStates && [llength $solutions]<2} {
        set open [lsort -command ::NodePatch::stateCompare $open]
        set item [lindex $open 0]; set open [lrange $open 1 end]
        set cost [lindex $item 0]; set path [lindex $item 1]; set cur [lindex $path end]; incr expanded
        if {$cur==$b} {lappend solutions $item; continue}
        if {![dict exists $graph $cur]} {continue}
        foreach next [::NodePatch::uniq [dict get $graph $cur]] {
            if {[lsearch -exact $path $next]>=0} {continue}
            set pcur [::NodePatch::nodeXYZ $cur]; set pn [::NodePatch::nodeXYZ $next]
            set edgeLen [::NodePatch::distance $pcur $pn]
            set newLength [expr {$cost+$edgeLen}]
            if {$newLength>$cfg(path_length_ratio_max)*$abLen} {continue}
            if {[llength $path]>1} {
                set pp [::NodePatch::nodeXYZ [lindex $path end-1]]
                if {[::NodePatch::angleDeg [::NodePatch::vsub $pcur $pp] [::NodePatch::vsub $pn $pcur]]>$cfg(edge_path_angle_tol)} {continue}
            }
            lappend open [list $newLength [concat $path [list $next]]]
        }
    }
    if {[llength $solutions]==0} {return {}}
    set best [lindex $solutions 0]
    if {[lindex $best 0]>$cfg(path_length_ratio_max)*$abLen} {return {}}
    if {[llength $solutions]>1 && [lindex [lindex $solutions 1] 0] < $cfg(path_ambiguity_ratio)*[lindex $best 0]} {
        ::NodePatch::fail F04 "Ambiguous existing edge path between $a and $b. Please adjust selected nodes."
    }
    return [lindex $best 1]
}

proc ::NodePatch::basisForNormal {normal} {
    set trial {1.0 0.0 0.0}; if {abs([::NodePatch::vdot $normal $trial])>0.85} {set trial {0.0 1.0 0.0}}
    set e1 [::NodePatch::vunit [::NodePatch::vcross $normal $trial]]
    return [list $e1 [::NodePatch::vunit [::NodePatch::vcross $normal $e1]]]
}
proc ::NodePatch::project2 {p origin basis} {set d [::NodePatch::vsub $p $origin]; return [list [::NodePatch::vdot $d [lindex $basis 0]] [::NodePatch::vdot $d [lindex $basis 1]]]}
proc ::NodePatch::cross2 {a b} {return [expr {[lindex $a 0]*[lindex $b 1]-[lindex $a 1]*[lindex $b 0]}]}

# 2-D segment intersection. Result is {t u}; t belongs to AB, u to edge CD.
proc ::NodePatch::segmentIntersection2 {a b c d {eps 1.0e-10}} {
    set r [list [expr {[lindex $b 0]-[lindex $a 0]}] [expr {[lindex $b 1]-[lindex $a 1]}]]
    set s [list [expr {[lindex $d 0]-[lindex $c 0]}] [expr {[lindex $d 1]-[lindex $c 1]}]]
    set den [::NodePatch::cross2 $r $s]; set ca [list [expr {[lindex $c 0]-[lindex $a 0]}] [expr {[lindex $c 1]-[lindex $a 1]}]]
    if {abs($den)<$eps} {return {}}
    set t [expr {double([::NodePatch::cross2 $ca $s])/$den}]; set u [expr {double([::NodePatch::cross2 $ca $r])/$den}]
    if {$t<-$eps || $t>1.0+$eps || $u<-$eps || $u>1.0+$eps} {return {}}
    return [list [::NodePatch::clamp $t 0.0 1.0] [::NodePatch::clamp $u 0.0 1.0]]
}

proc ::NodePatch::traceExitCandidates {elem a b currentT h} {
    variable cfg
    set nodes [::NodePatch::elemNodes $elem]; set normal [::NodePatch::elementNormal $nodes]
    set origin [::NodePatch::nodeXYZ [lindex $nodes 0]]; set basis [::NodePatch::basisForNormal $normal]
    set pa [::NodePatch::project2 [::NodePatch::nodeXYZ $a] $origin $basis]
    set pb [::NodePatch::project2 [::NodePatch::nodeXYZ $b] $origin $basis]
    set epsT [expr {max(1.0e-8, $cfg(node_snap_tol_factor)*$h/max([::NodePatch::distance [::NodePatch::nodeXYZ $a] [::NodePatch::nodeXYZ $b]],1.0e-12))}]
    set out {}
    foreach edge [::NodePatch::elementEdges $nodes] {
        foreach {n1 n2} $edge break
        set p1 [::NodePatch::project2 [::NodePatch::nodeXYZ $n1] $origin $basis]; set p2 [::NodePatch::project2 [::NodePatch::nodeXYZ $n2] $origin $basis]
        set hit [::NodePatch::segmentIntersection2 $pa $pb $p1 $p2]
        if {[llength $hit]==0} {continue}
        foreach {t u} $hit break
        if {$t <= $currentT+$epsT} {continue}
        set edgeLength [::NodePatch::distance [::NodePatch::nodeXYZ $n1] [::NodePatch::nodeXYZ $n2]]
        set snap ""; if {$u*$edgeLength<$cfg(node_snap_tol_factor)*$h} {set snap $n1}; if {(1.0-$u)*$edgeLength<$cfg(node_snap_tol_factor)*$h} {set snap $n2}
        lappend out [list $t $n1 $n2 $u $snap]
    }
    return [lsort -real -index 0 $out]
}

proc ::NodePatch::traceAcrossShell {a b h {maxElements 0}} {
    variable cfg
    if {$maxElements<=0} { set maxElements $cfg(max_trace_elements) }
    set starts [::NodePatch::nodeElements $a]; set candidates {}
    foreach elem $starts {foreach hit [::NodePatch::traceExitCandidates $elem $a $b 0.0 $h] {lappend candidates [list [lindex $hit 0] $elem $hit]}}
    set candidates [lsort -real -index 0 $candidates]
    if {[llength $candidates]==0} {::NodePatch::fail F05 "No continuous shell patch starts from node $a toward node $b."}
    if {[llength $candidates]>1 && abs([lindex [lindex $candidates 0] 0]-[lindex [lindex $candidates 1] 0])<1.0e-8 && [lindex [lindex $candidates 0] 1] != [lindex [lindex $candidates 1] 1]} {::NodePatch::fail F08 "Intersection is not unique near start node $a."}
    set current [lindex [lindex $candidates 0] 1]; set currentT 0.0; set visited {}; set steps {}
    for {set count 0} {$count<$maxElements} {incr count} {
        if {[lsearch -exact $visited $current]>=0} {::NodePatch::fail F08 "Element traversal loop detected at element $current."}
        lappend visited $current
        set nodes [::NodePatch::elemNodes $current]
        if {[lsearch -exact $nodes $b]>=0} { lappend steps [dict create element $current enter_t $currentT exit_t 1.0 exit_edge {} snap_node $b]; return $steps }
        set hits [::NodePatch::traceExitCandidates $current $a $b $currentT $h]
        if {[llength $hits]==0} {::NodePatch::fail F05 "Line leaves the shell patch at element $current."}
        set hit [lindex $hits 0]; foreach {nextT e1 e2 u snap} $hit break
        set tied [list $hit]
        for {set hi 1} {$hi<[llength $hits]} {incr hi} {if {abs([lindex [lindex $hits $hi] 0]-$nextT)>=1.0e-8} {break}; lappend tied [lindex $hits $hi]}
        if {[llength $tied]>1} {
            set commonSnap $snap
            foreach tiedHit $tied {if {$commonSnap eq "" || [lindex $tiedHit 4] ne $commonSnap} {::NodePatch::fail F08 "Intersection is not unique at element $current."}; set tiedOwners [::NodePatch::edgeElements [lindex $tiedHit 1] [lindex $tiedHit 2]]; if {[llength $tiedOwners]>2} {::NodePatch::fail F07 "Non-manifold edge [::NodePatch::edgeKey [lindex $tiedHit 1] [lindex $tiedHit 2]] detected."}}
            # A line may pass exactly through an existing vertex. In that case
            # the forward element can share only the vertex (not the exit edge)
            # with the current element. Keep only node-adjacent shells through
            # which AB continues monotonically.
            set forward {}
            foreach candidate [::NodePatch::nodeElements $commonSnap] {
                if {$candidate==$current || [lsearch -exact $visited $candidate]>=0} {continue}
                set angle [::NodePatch::angleDeg [::NodePatch::elementNormal $nodes] [::NodePatch::elementNormal [::NodePatch::elemNodes $candidate]] 1]
                if {$angle>$cfg(surface_angle_tol)} {continue}
                if {[lsearch -exact [::NodePatch::elemNodes $candidate] $b]>=0 || [llength [::NodePatch::traceExitCandidates $candidate $a $b $nextT $h]]>0} {lappend forward $candidate}
            }
            set forward [::NodePatch::uniq $forward]
            if {[llength $forward]!=1} {::NodePatch::fail F08 "Existing-node intersection at $commonSnap has [llength $forward] possible forward shell paths."}
            set next [lindex $forward 0]
            lappend steps [dict create element $current enter_t $currentT exit_t $nextT exit_edge [list $e1 $e2] edge_u $u snap_node $snap]
            ::NodePatch::log DEBUG "pair=$a-$b element=$current vertex=$commonSnap t=$nextT next=$next"
            set current $next; set currentT $nextT
            continue
        }
        set owners [::NodePatch::edgeElements $e1 $e2]
        if {[llength $owners]>2} {::NodePatch::fail F07 "Non-manifold edge [::NodePatch::edgeKey $e1 $e2] detected."}
        set next ""; foreach owner $owners {if {$owner!=$current} {set next $owner}}
        lappend steps [dict create element $current enter_t $currentT exit_t $nextT exit_edge [list $e1 $e2] edge_u $u snap_node $snap]
        if {$next eq ""} {::NodePatch::fail F05 "AB crosses boundary edge [::NodePatch::edgeKey $e1 $e2] and would pass through air."}
        set angle [::NodePatch::angleDeg [::NodePatch::elementNormal $nodes] [::NodePatch::elementNormal [::NodePatch::elemNodes $next]] 1]
        if {$angle>$cfg(surface_angle_tol)} {::NodePatch::fail F06 "Surface normal jump ${angle}deg exceeds $cfg(surface_angle_tol)deg at edge [::NodePatch::edgeKey $e1 $e2]."}
        ::NodePatch::log DEBUG "pair=$a-$b element=$current exit=[::NodePatch::edgeKey $e1 $e2] t=$nextT next=$next"
        set current $next; set currentT $nextT
    }
    ::NodePatch::fail F08 "Trace exceeded $maxElements elements."
}

proc ::NodePatch::analyzePair {a b {h 0.0} {maxStates 0} {maxElements 0}} {
    if {$h<=0.0} { set h [::NodePatch::localMeshSize $a $b] }
    set chain [::NodePatch::existingEdgeChain $a $b $h $maxStates]
    if {[llength $chain]>0} {::NodePatch::log INFO "Pair $a-$b: existing chain, [llength $chain] nodes"; return [dict create mode existing h $h chain $chain affected_elements {}]}
    set trace [::NodePatch::traceAcrossShell $a $b $h $maxElements]
    ::NodePatch::log INFO "Pair $a-$b: tracing, [llength $trace] elements"
    set affected {}
    foreach step $trace {lappend affected [dict get $step element]}
    return [dict create mode split h $h chain {} trace $trace affected_elements $affected]
}

proc ::NodePatch::boundaryPairs {corners} {
    set out {}; set n [llength $corners]
    for {set i 0} {$i<$n} {incr i} {lappend out [list [lindex $corners $i] [lindex $corners [expr {($i+1)%$n}]]]}
    return $out
}

proc ::NodePatch::polygonNormal {points} {
    set nx 0.0; set ny 0.0; set nz 0.0; set n [llength $points]
    for {set i 0} {$i<$n} {incr i} {set p [lindex $points $i]; set q [lindex $points [expr {($i+1)%$n}]]; set nx [expr {$nx+([lindex $p 1]-[lindex $q 1])*([lindex $p 2]+[lindex $q 2])}]; set ny [expr {$ny+([lindex $p 2]-[lindex $q 2])*([lindex $p 0]+[lindex $q 0])}]; set nz [expr {$nz+([lindex $p 0]-[lindex $q 0])*([lindex $p 1]+[lindex $q 1])}]}
    return [::NodePatch::vunit [list $nx $ny $nz]]
}

proc ::NodePatch::boundary2D {nodes} {
    set points {}; set centroid {0.0 0.0 0.0}
    foreach n $nodes {set p [::NodePatch::nodeXYZ $n]; lappend points $p; set centroid [::NodePatch::vadd $centroid $p]}
    set centroid [::NodePatch::vscale $centroid [expr {1.0/[llength $points]}]]
    set normal [::NodePatch::polygonNormal $points]; set basis [::NodePatch::basisForNormal $normal]; set p2 {}
    foreach p $points {lappend p2 [::NodePatch::project2 $p $centroid $basis]}
    return [dict create points3 $points points2 $p2 origin $centroid normal $normal basis $basis]
}

proc ::NodePatch::segmentsCrossStrict {a b c d} {
    set hit [::NodePatch::segmentIntersection2 $a $b $c $d 1.0e-9]
    if {[llength $hit]==0} {return 0}; foreach {t u} $hit break
    return [expr {$t>1.0e-8 && $t<1.0-1.0e-8 && $u>1.0e-8 && $u<1.0-1.0e-8}]
}

proc ::NodePatch::validateBoundaryGeometry {nodes h} {
    variable cfg
    if {[llength $nodes]<3} {::NodePatch::fail F09 "Boundary has fewer than three nodes."}
    set data [::NodePatch::boundary2D $nodes]; set p2 [dict get $data points2]; set p3 [dict get $data points3]; set n [llength $nodes]
    for {set i 0} {$i<$n} {incr i} {for {set j [expr {$i+1}]} {$j<$n} {incr j} {if {$j==$i+1 || ($i==0 && $j==$n-1)} {continue}; if {[::NodePatch::segmentsCrossStrict [lindex $p2 $i] [lindex $p2 [expr {($i+1)%$n}]] [lindex $p2 $j] [lindex $p2 [expr {($j+1)%$n}]]]} {::NodePatch::fail F09 "Boundary is self-intersecting. Reselect nodes in perimeter order."}}}
    set maxD 0.0; set origin [dict get $data origin]; set normal [dict get $data normal]
    foreach p $p3 {set d [expr {abs([::NodePatch::vdot [::NodePatch::vsub $p $origin] $normal])}]; if {$d>$maxD} {set maxD $d}}
    if {$maxD>$cfg(planarity_tol_factor)*$h} {::NodePatch::fail F10 "Boundary planarity deviation $maxD exceeds [expr {$cfg(planarity_tol_factor)*$h}]."}
    return $data
}

proc ::NodePatch::analyze {corners {hint 0.0}} {
    variable cfg
    set corners [::NodePatch::validateCorners $corners]
    set pairDefs [::NodePatch::boundaryPairs $corners]; set sides [llength $pairDefs]
    foreach {perSideStates stateBudget} [::NodePatch::sideBudgets $sides $cfg(graph_budget_per_side) 360] break
    foreach {perSideElements elementBudget} [::NodePatch::sideBudgets $sides $cfg(trace_budget_per_side) 30] break
    # One shared local mesh size is derived from the corner neighbourhood only:
    # it feeds the tolerance comparisons (capsule width, planarity, minimum
    # edge length) so every side must be judged against the same scale. Sides
    # that are really too long for that scale still fail through the existing
    # detour and element-count limits.
    set h $hint
    if {$h<=0.0} { set h [::NodePatch::boundaryMeshSize $corners] }
    set pairs {}; set affected {}; set hsum 0.0
    foreach pair $pairDefs {
        set result [::NodePatch::analyzePair [lindex $pair 0] [lindex $pair 1] $h $stateBudget $elementBudget]
        lappend pairs $result; set affected [concat $affected [dict get $result affected_elements]]; set hsum [expr {$hsum+[dict get $result h]}]
    }
    # Preview uses corner geometry. Build performs a second validation using the
    # complete realized chains before patch element creation.
    ::NodePatch::validateBoundaryGeometry $corners $h
    return [dict create corners $corners pairs $pairs affected_elements [::NodePatch::uniq $affected] h $h]
}

proc ::NodePatch::analysisSummary {analysis} {
    set lines {}; set defs [::NodePatch::boundaryPairs [dict get $analysis corners]]; set pairs [dict get $analysis pairs]
    for {set i 0} {$i<[llength $pairs]} {incr i} {foreach {a b} [lindex $defs $i] break; set pair [lindex $pairs $i]; if {[dict get $pair mode] eq "existing"} {lappend lines "Edge $a-$b: EXISTING ([llength [dict get $pair chain]] nodes)"} else {lappend lines "Edge $a-$b: SPLIT ([llength [dict get $pair trace]] elems)"}}
    set lines [linsert $lines 0 "Boundary: [llength [dict get $analysis corners]] corners / [llength $pairs] sides"]
    return [join $lines "\n"]
}

proc ::NodePatch::newTrackedNode {xyz} {
    foreach {x y z} $xyz break
    if {[catch {*createnode $x $y $z 0 0 0} err]} {::NodePatch::fail F12 "Failed to create split node: $err"}
    catch {*clearmark nodes 1}; if {[catch {*createmark nodes 1 -1}]} {::NodePatch::fail F12 "Cannot identify new split node."}; set ids [hm_getmark nodes 1]; catch {*clearmark nodes 1}
    if {[llength $ids]!=1} {::NodePatch::fail F12 "New split node is not uniquely identifiable."}; return [lindex $ids 0]
}
proc ::NodePatch::newElement {nodes} {
    set cfg [expr {[llength $nodes]==3 ? 103 : 104}]
    if {[catch {eval *createlist nodes 1 $nodes; *createelement $cfg 1 1 1} err]} {::NodePatch::fail F12 "Failed to create shell element on nodes $nodes: $err"}
    catch {*clearmark elems 1}; *createmark elems 1 -1; set ids [hm_getmark elems 1]; catch {*clearmark elems 1}
    if {[llength $ids]!=1} {::NodePatch::fail F12 "New shell element is not uniquely identifiable."}; return [lindex $ids 0]
}
proc ::NodePatch::elemComponent {elem} {foreach dn {component.id collector.id component collectorid} {if {![catch {set x [hm_getvalue elems id=$elem dataname=$dn]}] && $x ne "" && $x!=0} {return $x}}; return ""}
proc ::NodePatch::elemProperty {elem} {foreach dn {property.id propertyid prop.id} {if {![catch {set x [hm_getvalue elems id=$elem dataname=$dn]}] && [string is integer -strict $x] && $x>0} {return $x}}; return ""}
proc ::NodePatch::componentName {id} {if {$id eq ""} {return ""}; foreach dn {name} {if {![catch {set x [hm_getvalue comps id=$id dataname=$dn]}]} {return $x}}; return ""}

proc ::NodePatch::assignElementProperty {elem property} {
    if {$property eq "" || $property<=0} {return}
    if {![catch {uplevel #0 [list *setvalue elems id=$elem STATUS=1 "propertyid={props $property}"]}]} {return}
    if {[catch {uplevel #0 [list *setvalue elems id=$elem STATUS=1 propertyid=$property]} err]} {::NodePatch::fail F12 "Cannot preserve property $property on replacement element $elem: $err"}
}

proc ::NodePatch::setCurrentComponentById {id} {
    set name [::NodePatch::componentName $id]; if {$name eq ""} {::NodePatch::fail F12 "Cannot resolve component $id."}
    if {[catch {*currentcollector component $name}]} {catch {*currentcollector components $name}}
}

proc ::NodePatch::cyclicPath {items start end} {
    set out [list [lindex $items $start]]; set n [llength $items]; set i $start
    while {$i!=$end} {set i [expr {($i+1)%$n}]; lappend out [lindex $items $i]; if {[llength $out]>$n+1} {error "cyclic path failure"}}
    return $out
}

# Insert chord endpoints into the original polygon and return the two replacement
# polygons. endpoint descriptors are {node vertexIndex} or {node edgeIndex}.
proc ::NodePatch::splitPolygonPlans {poly d1 d2} {
    set expanded {}; set indices {}; set n [llength $poly]
    for {set i 0} {$i<$n} {incr i} {
        set node [lindex $poly $i]; lappend expanded $node
        foreach d [list $d1 $d2] {if {[lindex $d 1] eq "vertex" && [lindex $d 2]==$i} {dict set indices [lindex $d 0] [expr {[llength $expanded]-1}]}}
        foreach d [list $d1 $d2] {if {[lindex $d 1] eq "edge" && [lindex $d 2]==$i} {lappend expanded [lindex $d 0]; dict set indices [lindex $d 0] [expr {[llength $expanded]-1}]}}
    }
    set a [lindex $d1 0]; set b [lindex $d2 0]; set ia [dict get $indices $a]; set ib [dict get $indices $b]
    set p1 [::NodePatch::cyclicPath $expanded $ia $ib]; set p2 [::NodePatch::cyclicPath $expanded $ib $ia]
    return [list $p1 $p2]
}

proc ::NodePatch::polygonElementPlans {poly} {
    set poly [::NodePatch::uniq $poly]; set n [llength $poly]
    if {$n<3} {return {}}; if {$n in {3 4}} {return [list $poly]}
    set out {}; for {set i 1} {$i<$n-1} {incr i} {lappend out [list [lindex $poly 0] [lindex $poly $i] [lindex $poly [expr {$i+1}]]]}; return $out
}

proc ::NodePatch::validateReplacementPlan {nodes h {original {}}} {
    variable cfg
    set originalKeys [dict create]
    foreach edge [::NodePatch::elementEdges $original] {dict set originalKeys [::NodePatch::edgeKey [lindex $edge 0] [lindex $edge 1]] 1}
    foreach edge [::NodePatch::elementEdges $nodes] {
        set key [::NodePatch::edgeKey [lindex $edge 0] [lindex $edge 1]]
        if {[dict exists $originalKeys $key]} {continue}
        set length [::NodePatch::distance [::NodePatch::nodeXYZ [lindex $edge 0]] [::NodePatch::nodeXYZ [lindex $edge 1]]]
        if {$length<$cfg(min_edge_factor)*$h} {::NodePatch::fail F11 "Split would create a short edge ($length < [expr {$cfg(min_edge_factor)*$h}]) on nodes $nodes."}
    }
    if {[llength $nodes]==3 && [dict get [::NodePatch::triangleMetrics $nodes] area]<=1.0e-14} {::NodePatch::fail F12 "Replacement triangle is degenerate: $nodes."}
    return 1
}

proc ::NodePatch::descriptorForPoint {poly node edge snap} {
    if {$snap ne ""} {return [list $snap vertex [lsearch -exact $poly $snap]]}
    foreach {a b} $edge break; set edges [::NodePatch::elementEdges $poly]
    set index -1; for {set i 0} {$i<[llength $edges]} {incr i} {set e [lindex $edges $i]; if {[::NodePatch::edgeKey [lindex $e 0] [lindex $e 1]] eq [::NodePatch::edgeKey $a $b]} {set index $i; break}}
    if {$index<0} {::NodePatch::fail F12 "Trace edge is not on replacement element."}; return [list $node edge $index]
}

proc ::NodePatch::deleteElements {ids} {if {[llength $ids]==0} {return}; catch {*clearmark elems 1}; eval *createmark elems 1 $ids; *deletemark elems 1; catch {*clearmark elems 1}}

proc ::NodePatch::realizeSplitPair {a b pair edgeNodeMapVar} {
    upvar 1 $edgeNodeMapVar edgeNodeMap
    set trace [dict get $pair trace]; set h [dict get $pair h]; set pa [::NodePatch::nodeXYZ $a]; set pb [::NodePatch::nodeXYZ $b]; set ab [::NodePatch::vsub $pb $pa]
    set chain [list $a]; set pointNodes [list $a]; set exitDescriptors {}
    foreach step $trace {
        set edge [dict get $step exit_edge]; set snap [dict get $step snap_node]
        if {[llength $edge]==0} {lappend pointNodes $b; lappend exitDescriptors {}; continue}
        if {$snap ne ""} {set node $snap} else {set key [::NodePatch::edgeKey [lindex $edge 0] [lindex $edge 1]]; if {[dict exists $edgeNodeMap $key]} {set node [dict get $edgeNodeMap $key]} else {set xyz [::NodePatch::vadd $pa [::NodePatch::vscale $ab [dict get $step exit_t]]]; set node [::NodePatch::newTrackedNode $xyz]; dict set edgeNodeMap $key $node; ::NodePatch::log DEBUG "created_node=$node edge=$key"}}
        lappend chain $node; lappend pointNodes $node; lappend exitDescriptors [list $edge $snap]
    }
    if {[lindex $chain end]!=$b} {lappend chain $b}
    set originalElems {}; set newElems {}
    for {set i 0} {$i<[llength $trace]} {incr i} {
        set step [lindex $trace $i]; set elem [dict get $step element]; set poly [::NodePatch::elemNodes $elem]; set startNode [lindex $pointNodes $i]; set endNode [lindex $pointNodes [expr {$i+1}]]
        if {$startNode==$endNode} {continue}
        if {$i==0} {set d1 [list $a vertex [lsearch -exact $poly $a]]} else {foreach {entryEdge entrySnap} [lindex $exitDescriptors [expr {$i-1}]] break; set d1 [::NodePatch::descriptorForPoint $poly $startNode $entryEdge $entrySnap]}
        if {[llength [dict get $step exit_edge]]==0} {set d2 [list $b vertex [lsearch -exact $poly $b]]} else {set d2 [::NodePatch::descriptorForPoint $poly $endNode [dict get $step exit_edge] [dict get $step snap_node]]}
        # A chord that is already an element edge requires no rebuild.
        if {[lindex $d1 1] eq "vertex" && [lindex $d2 1] eq "vertex" && ([expr {abs([lindex $d1 2]-[lindex $d2 2])}]==1 || [expr {abs([lindex $d1 2]-[lindex $d2 2])}]==[expr {[llength $poly]-1}])} {continue}
        set comp [::NodePatch::elemComponent $elem]; set property [::NodePatch::elemProperty $elem]; ::NodePatch::setCurrentComponentById $comp
        foreach replacement [::NodePatch::splitPolygonPlans $poly $d1 $d2] {foreach plan [::NodePatch::polygonElementPlans $replacement] {::NodePatch::validateReplacementPlan $plan $h $poly; set newElem [::NodePatch::newElement $plan]; ::NodePatch::assignElementProperty $newElem $property; lappend newElems $newElem}}
        lappend originalElems $elem
    }
    ::NodePatch::deleteElements [::NodePatch::uniq $originalElems]
    # Confirm every consecutive pair is now a true shell edge.
    for {set i 0} {$i<[llength $chain]-1} {incr i} {if {[llength [::NodePatch::edgeElements [lindex $chain $i] [lindex $chain [expr {$i+1}]]]]==0} {::NodePatch::fail F12 "Split did not create a continuous edge chain at [lindex $chain $i]-[lindex $chain [expr {$i+1}]]."}}
    return [dict create chain $chain created_elements $newElems deleted_elements $originalElems]
}

proc ::NodePatch::pointInTriangle2 {p a b c} {
    set ab [::NodePatch::cross2 [list [expr {[lindex $b 0]-[lindex $a 0]}] [expr {[lindex $b 1]-[lindex $a 1]}]] [list [expr {[lindex $p 0]-[lindex $a 0]}] [expr {[lindex $p 1]-[lindex $a 1]}]]]
    set bc [::NodePatch::cross2 [list [expr {[lindex $c 0]-[lindex $b 0]}] [expr {[lindex $c 1]-[lindex $b 1]}]] [list [expr {[lindex $p 0]-[lindex $b 0]}] [expr {[lindex $p 1]-[lindex $b 1]}]]]
    set ca [::NodePatch::cross2 [list [expr {[lindex $a 0]-[lindex $c 0]}] [expr {[lindex $a 1]-[lindex $c 1]}]] [list [expr {[lindex $p 0]-[lindex $c 0]}] [expr {[lindex $p 1]-[lindex $c 1]}]]]
    return [expr {($ab>=-1.0e-10 && $bc>=-1.0e-10 && $ca>=-1.0e-10)||($ab<=1.0e-10 && $bc<=1.0e-10 && $ca<=1.0e-10)}]
}

proc ::NodePatch::earClip {nodes} {
    set data [::NodePatch::boundary2D $nodes]; set pts [dict get $data points2]; set area 0.0; set n [llength $nodes]
    for {set i 0} {$i<$n} {incr i} {set p [lindex $pts $i]; set q [lindex $pts [expr {($i+1)%$n}]]; set area [expr {$area+[lindex $p 0]*[lindex $q 1]-[lindex $q 0]*[lindex $p 1]}]}
    set indices {}; for {set i 0} {$i<$n} {incr i} {lappend indices $i}; if {$area<0} {set indices [lreverse $indices]}
    set triangles {}; set guard 0
    while {[llength $indices]>3 && $guard<1000} {
        incr guard; set clipped 0; set m [llength $indices]
        for {set k 0} {$k<$m} {incr k} {
            set ia [lindex $indices [expr {($k-1+$m)%$m}]]; set ib [lindex $indices $k]; set ic [lindex $indices [expr {($k+1)%$m}]]
            set a [lindex $pts $ia]; set b [lindex $pts $ib]; set c [lindex $pts $ic]
            set turn [::NodePatch::cross2 [list [expr {[lindex $b 0]-[lindex $a 0]}] [expr {[lindex $b 1]-[lindex $a 1]}]] [list [expr {[lindex $c 0]-[lindex $b 0]}] [expr {[lindex $c 1]-[lindex $b 1]}]]]
            if {$turn<=1.0e-12} {continue}; set contains 0
            foreach ix $indices {if {$ix in [list $ia $ib $ic]} {continue}; if {[::NodePatch::pointInTriangle2 [lindex $pts $ix] $a $b $c]} {set contains 1; break}}
            if {$contains} {continue}
            lappend triangles [list [lindex $nodes $ia] [lindex $nodes $ib] [lindex $nodes $ic]]; set indices [lreplace $indices $k $k]; set clipped 1; break
        }
        if {!$clipped} {::NodePatch::fail F12 "Boundary triangulation failed (degenerate or non-simple polygon)."}
    }
    if {[llength $indices]==3} {lappend triangles [list [lindex $nodes [lindex $indices 0]] [lindex $nodes [lindex $indices 1]] [lindex $nodes [lindex $indices 2]]]}
    return $triangles
}

proc ::NodePatch::uniqueComponentName {} {
    variable cfg; set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]; set base "$cfg(output_component_prefix)_$stamp"; set name $base; set i 1
    while {[llength [info commands ::HWFlow::componentIdByName]]>0 && [::HWFlow::componentIdByName $name] ne ""} {set name "${base}_[format %02d $i]"; incr i}
    return $name
}

proc ::NodePatch::createPatchComponent {} {
    variable cfg
    if {$cfg(output_component_mode) eq "current"} {return ""}
    set name [::NodePatch::uniqueComponentName]
    if {[catch {*createentity comps includeid=0 name=$name} err]} {if {[catch {*createentity comps name=$name} err2]} {::NodePatch::fail F12 "Cannot create patch component: $err / $err2"}}
    if {[catch {*currentcollector component $name}]} {catch {*currentcollector components $name}}
    return $name
}

proc ::NodePatch::averageAdjacentNormal {boundary} {
    set sum {0.0 0.0 0.0}; set seen {}
    for {set i 0} {$i<[llength $boundary]} {incr i} {
        set a [lindex $boundary $i]; set b [lindex $boundary [expr {($i+1)%[llength $boundary]}]]
        foreach elem [::NodePatch::edgeElements $a $b] {if {[lsearch -exact $seen $elem]>=0} {continue}; lappend seen $elem; set n [::NodePatch::elementNormal [::NodePatch::elemNodes $elem]]; if {[::NodePatch::vdot $sum $n]<0.0} {set n [::NodePatch::vscale $n -1.0]}; set sum [::NodePatch::vadd $sum $n]}
    }
    if {[::NodePatch::vlength $sum]<1.0e-12} {return {}}
    return [::NodePatch::vunit $sum]
}

proc ::NodePatch::triangleMetrics {nodes} {
    set a [::NodePatch::nodeXYZ [lindex $nodes 0]]; set b [::NodePatch::nodeXYZ [lindex $nodes 1]]; set c [::NodePatch::nodeXYZ [lindex $nodes 2]]
    set lengths [list [::NodePatch::distance $a $b] [::NodePatch::distance $b $c] [::NodePatch::distance $c $a]]; set sorted [lsort -real $lengths]
    set area [expr {0.5*[::NodePatch::vlength [::NodePatch::vcross [::NodePatch::vsub $b $a] [::NodePatch::vsub $c $a]]]}]
    set minAngle 180.0
    foreach triple [list [list $b $a $c] [list $a $b $c] [list $a $c $b]] {foreach {p center q} $triple break; set angle [::NodePatch::angleDeg [::NodePatch::vsub $p $center] [::NodePatch::vsub $q $center]]; if {$angle<$minAngle} {set minAngle $angle}}
    return [dict create area $area min_edge [lindex $sorted 0] max_edge [lindex $sorted end] min_angle $minAngle aspect [expr {[lindex $sorted end]/max([lindex $sorted 0],1.0e-20)}]]
}

proc ::NodePatch::validateCreatedPatch {patchElems boundary h} {
    variable cfg
    set keys [dict create]; set patchEdgeCounts [dict create]
    foreach elem $patchElems {
        set nodes [::NodePatch::elemNodes $elem]; if {[llength $nodes]!=3} {::NodePatch::fail F12 "Patch element $elem is not TRIA3."}
        set key [join [lsort -integer $nodes] ,]; if {[dict exists $keys $key]} {::NodePatch::fail F12 "Duplicate patch connectivity $key."}; dict set keys $key 1
        set metrics [::NodePatch::triangleMetrics $nodes]
        if {[dict get $metrics area]<=1.0e-14 || [dict get $metrics min_edge]<1.0e-8*$h} {::NodePatch::fail F12 "Patch element $elem is degenerate."}
        if {[dict get $metrics min_edge]<$cfg(min_edge_factor)*$h || [dict get $metrics min_angle]<10.0 || [dict get $metrics aspect]>10.0} {::NodePatch::log WARN "Patch element $elem quality warning: metrics=$metrics"}
        foreach edge [::NodePatch::elementEdges $nodes] {set ekey [::NodePatch::edgeKey [lindex $edge 0] [lindex $edge 1]]; if {[dict exists $patchEdgeCounts $ekey]} {dict incr patchEdgeCounts $ekey} else {dict set patchEdgeCounts $ekey 1}}
    }
    foreach ekey [dict keys $patchEdgeCounts] {if {[dict get $patchEdgeCounts $ekey]==1} {foreach {a b} [split $ekey ,] break; if {[llength [::NodePatch::edgeElements $a $b]]<2} {::NodePatch::fail F13 "Unexpected free patch edge $ekey."}}}
    return 1
}

proc ::NodePatch::flattenChains {chains} {
    set out {}; set first 1
    foreach chain $chains {if {$first} {set out $chain; set first 0} else {set out [concat $out [lrange $chain 1 end]]}}
    if {[llength $out]>1 && [lindex $out 0]==[lindex $out end]} {set out [lrange $out 0 end-1]}
    return $out
}

proc ::NodePatch::buildFromAnalysis {analysis} {
    variable lastHistoryAvailable
    variable cfg
    set corners [dict get $analysis corners]; set pairs [dict get $analysis pairs]; set pairDefs [::NodePatch::boundaryPairs $corners]
    foreach {perSideStates stateBudget} [::NodePatch::sideBudgets [llength $pairDefs] $cfg(graph_budget_per_side) 360] break
    foreach {perSideElements elementBudget} [::NodePatch::sideBudgets [llength $pairDefs] $cfg(trace_budget_per_side) 30] break
    foreach command {::*startnotehistorystate ::*endnotehistorystate ::*undohistorystate} {if {[llength [info commands $command]]==0} {::NodePatch::fail F12 "Required rollback command $command is unavailable; model was not modified."}}
    set historyName "Node Patch Builder"; set historyStarted 0
    if {[catch {*startnotehistorystate $historyName} historyErr]} {::NodePatch::fail F12 "Cannot start rollback-safe history state: $historyErr"}
    set historyStarted 1
    set code [catch {
        set edgeNodeMap [dict create]; set chains {}; set createdSplit 0
        for {set i 0} {$i<[llength $pairs]} {incr i} {
            set pair [lindex $pairs $i]; foreach {a b} [lindex $pairDefs $i] break
            if {[dict get $pair mode] eq "existing"} {set chain [dict get $pair chain]} else {
                # Earlier sides can replace an element referenced by the preview
                # plan. Re-analyze this one side against live topology, still
                # inside the same all-or-nothing history transaction.
                set livePair [::NodePatch::analyzePair $a $b [dict get $analysis h] $stateBudget $elementBudget]
                if {[dict get $livePair mode] eq "existing"} {set chain [dict get $livePair chain]} else {set realized [::NodePatch::realizeSplitPair $a $b $livePair edgeNodeMap]; set chain [dict get $realized chain]; incr createdSplit [llength [dict get $realized created_elements]]}
            }
            if {[lindex $chain 0]!=$a || [lindex $chain end]!=$b} {::NodePatch::fail F12 "Boundary chain endpoint mismatch for $a-$b."}; lappend chains $chain
        }
        set boundary [::NodePatch::flattenChains $chains]; ::NodePatch::validateBoundaryGeometry $boundary [dict get $analysis h]
        set referenceNormal [::NodePatch::averageAdjacentNormal $boundary]
        set patchComp [::NodePatch::createPatchComponent]; set patchElems {}
        foreach triangle [::NodePatch::earClip $boundary] {if {[llength $referenceNormal]>0 && [::NodePatch::vdot [::NodePatch::elementNormal $triangle] $referenceNormal]<0.0} {set triangle [list [lindex $triangle 0] [lindex $triangle 2] [lindex $triangle 1]]}; lappend patchElems [::NodePatch::newElement $triangle]}
        if {[llength $patchElems]==0} {::NodePatch::fail F12 "No patch elements were created."}
        ::NodePatch::validateCreatedPatch $patchElems $boundary [dict get $analysis h]
        set result [dict create chains $chains boundary $boundary split_elements $createdSplit patch_elements $patchElems component $patchComp]
    } err opts]
    if {$historyStarted} {catch {*endnotehistorystate $historyName}}
    if {$code} {if {$historyStarted} {if {[catch {*undohistorystate 1} undoErr]} {append err "; rollback failed: $undoErr"}}; set lastHistoryAvailable 0; return -options $opts $err}
    set lastHistoryAvailable $historyStarted
    ::NodePatch::log INFO "Boundary validated; created [llength [dict get $result patch_elements]] patch elements."
    return $result
}

proc ::NodePatch::selectNodes {} {
    variable selectedNodes; variable selectedMeshSize; variable previewResult; variable ui
    catch {*clearmark nodes 1}
    if {[catch {*createlistpanel nodes 1 [::NodePatch::tr "按边界顺序选择 3 个及以上节点" "Select 3 or more nodes in perimeter order"]} err]} {set ui(status) "Selection cancelled."; return {}}
    set nodes {}; catch {set nodes [hm_getlist nodes 1]}; catch {*clearmark nodes 1}
    if {[catch {::NodePatch::validateCorners $nodes} msg]} {set ui(status) $msg; ::NodePatch::showMessage warning $msg; return {}}
    if {[catch {set size [::NodePatch::boundaryMeshSize $nodes]} msg]} {set ui(status) $msg; ::NodePatch::showMessage warning $msg; return {}}
    set selectedNodes $nodes; set selectedMeshSize $size; set previewResult {}; set ui(status) "[::NodePatch::tr "已选节点" "Selected nodes"] ([llength $nodes]): [join $nodes { -> }]"; ::NodePatch::refreshUI; return $nodes
}

proc ::NodePatch::preview {} {
    variable selectedNodes; variable selectedMeshSize; variable previewResult; variable ui
    if {[catch {set previewResult [::NodePatch::analyze $selectedNodes $selectedMeshSize]} err]} {set ui(status) $err; ::NodePatch::showMessage error $err; return {}}
    set affected [dict get $previewResult affected_elements]
    if {[llength $affected]>0} {catch {*clearmark elems 1}; catch {eval *createmark elems 1 $affected; *reviewmark elems 1 0}}
    set ui(status) "[::NodePatch::analysisSummary $previewResult]\nPreview ready: [llength $affected] shell elements would be locally split."; ::NodePatch::refreshUI; return $previewResult
}

proc ::NodePatch::build {} {
    variable selectedNodes; variable selectedMeshSize; variable previewResult; variable ui
    if {[catch {::NodePatch::validateCorners $selectedNodes} msg]} {set ui(status) $msg; ::NodePatch::showMessage warning $msg; return {}}
    if {[catch {set analysis [::NodePatch::analyze $selectedNodes $selectedMeshSize]} err]} {set ui(status) $err; ::NodePatch::showMessage error $err; return {}}
    set previewResult $analysis
    if {[catch {set result [::NodePatch::buildFromAnalysis $analysis]} err]} {set ui(status) $err; ::NodePatch::showMessage error $err; return {}}
    set ui(status) "Created [llength [dict get $result patch_elements]] patch elements; [dict get $result split_elements] replacement shell elements."; ::NodePatch::refreshUI; return $result
}

proc ::NodePatch::undoLast {} {
    variable lastHistoryAvailable; variable ui
    if {!$lastHistoryAvailable} {::NodePatch::showMessage warning "No Node Patch action is available to undo."; return 0}
    if {[catch {*undohistorystate 1} err]} {::NodePatch::showMessage error "Undo failed: $err"; return 0}
    set lastHistoryAvailable 0; set ui(status) "Last Node Patch action was undone."; ::NodePatch::refreshUI; return 1
}

proc ::NodePatch::showMessage {icon message} {if {[llength [info commands tk_messageBox]]>0} {tk_messageBox -icon $icon -title "Node Patch Builder" -message $message} else {catch {hm_usermessage $message}}}
proc ::NodePatch::refreshUI {} {variable ui; if {[llength [info commands winfo]]>0 && [winfo exists .node_patch_builder.status]} {catch {.node_patch_builder.status configure -text $ui(status)}}}
proc ::NodePatch::close {} {if {[llength [info commands destroy]]>0} {catch {destroy .node_patch_builder}}}

proc ::NodePatch::runAction {} {
    variable ui; variable cfg
    if {[llength [info commands toplevel]]==0} {error "Tk is unavailable."}
    set w .node_patch_builder; catch {destroy $w}; toplevel $w; wm title $w "Node Patch Builder"; wm resizable $w 0 0
    frame $w.buttons -padx 12 -pady 12; pack $w.buttons -fill x
    button $w.buttons.select -text [::NodePatch::tr "选择边界节点" "Select Boundary Nodes"] -width 18 -command ::NodePatch::selectNodes
    button $w.buttons.preview -text [::NodePatch::tr "预览" "Preview"] -width 12 -command ::NodePatch::preview
    button $w.buttons.build -text [::NodePatch::tr "生成补片" "Build Patch"] -width 14 -command ::NodePatch::build
    button $w.buttons.undo -text [::NodePatch::tr "撤回上次" "Undo Last"] -width 12 -command ::NodePatch::undoLast
    grid $w.buttons.select $w.buttons.preview $w.buttons.build $w.buttons.undo -padx 4 -pady 4
    checkbutton $w.buttons.debug -text "Debug" -variable ::NodePatch::cfg(debug); grid $w.buttons.debug -row 1 -column 0 -sticky w -padx 4
    label $w.status -text $ui(status) -anchor w -justify left -wraplength 600 -padx 12 -pady 10; pack $w.status -fill x
    button $w.close -text [::NodePatch::tr "关闭" "Close"] -width 12 -command ::NodePatch::close; pack $w.close -pady {0 12}
    catch {::HWFlow::registerWindow $w}; catch {::HWFlow::applyWindowStyle $w}; return $w
}

proc ::NodePatch::run {} { return [::NodePatch::runAction] }
proc ::NodePatch::Open {} {return [::NodePatch::runAction]}
proc ::NodePatch::Close {} {return [::NodePatch::close]}
proc ::NodePatch::SelectCornerNodes {} {return [::NodePatch::selectNodes]}
proc ::NodePatch::Preview {} {return [::NodePatch::preview]}
proc ::NodePatch::Build {} {return [::NodePatch::build]}
