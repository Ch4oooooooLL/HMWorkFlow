# Stable, side-effect-free diagnostics for Auto and AutoGroup.

proc ::SolidSeam::candidateCanonicalText {candidate} {
    set fields {source_component_id target_component_id node_ids is_closed suggested_realization joint_type side_mode line_spacing weld_width realization_tolerance}
    set rows {solid-seam-candidate-v1}
    foreach field $fields {
        set value ""
        if {[dict exists $candidate $field]} { set value [dict get $candidate $field] }
        if {$field in {line_spacing weld_width realization_tolerance} && [string is double -strict $value]} {
            set value [format %.9g $value]
        }
        lappend rows "$field=[list $value]"
    }
    return [join $rows "\n"]
}

proc ::SolidSeam::candidateFingerprint {candidate} {
    set canonical [::SolidSeam::candidateCanonicalText $candidate]
    if {[llength [info commands ::HybridCore::workerContentFingerprint]]} {
        return [string map {mesh-v1: seam-candidate-v1:} [::HybridCore::workerContentFingerprint $canonical]]
    }
    # Tcl 8.5 fallback for isolated/offline loading.
    set fnv 2166136261; set djb 5381
    foreach character [split $canonical ""] {
        scan $character %c codepoint
        set fnv [expr {(($fnv ^ $codepoint) * 16777619) & 0xffffffff}]
        set djb [expr {(($djb * 33) ^ $codepoint) & 0xffffffff}]
    }
    return "seam-candidate-v1:[string length $canonical]:[format %08x $fnv]:[format %08x $djb]"
}

proc ::SolidSeam::finalizeCandidateDiagnostics {candidate} {
    dict set candidate candidate_fingerprint [::SolidSeam::candidateFingerprint $candidate]
    return $candidate
}

proc ::SolidSeam::shadowSub {a b} {
    return [list [expr {[lindex $a 0]-[lindex $b 0]}] [expr {[lindex $a 1]-[lindex $b 1]}] [expr {[lindex $a 2]-[lindex $b 2]}]]
}
proc ::SolidSeam::shadowDot {a b} {
    return [expr {[lindex $a 0]*[lindex $b 0]+[lindex $a 1]*[lindex $b 1]+[lindex $a 2]*[lindex $b 2]}]
}
proc ::SolidSeam::shadowAddScaled {a b scale} {
    return [list [expr {[lindex $a 0]+$scale*[lindex $b 0]}] [expr {[lindex $a 1]+$scale*[lindex $b 1]}] [expr {[lindex $a 2]+$scale*[lindex $b 2]}]]
}

# Closest-point regions from Real-Time Collision Detection; degenerate
# triangles fall back to their three edges.
proc ::SolidSeam::pointTriangleDistance {point a b c} {
    set ab [::SolidSeam::shadowSub $b $a]; set ac [::SolidSeam::shadowSub $c $a]
    set cross [list \
        [expr {[lindex $ab 1]*[lindex $ac 2]-[lindex $ab 2]*[lindex $ac 1]}] \
        [expr {[lindex $ab 2]*[lindex $ac 0]-[lindex $ab 0]*[lindex $ac 2]}] \
        [expr {[lindex $ab 0]*[lindex $ac 1]-[lindex $ab 1]*[lindex $ac 0]}]]
    if {[::SolidSeam::shadowDot $cross $cross] <= 1.0e-24} {
        return [expr {min([::SolidSeam::pointSegmentDistance $point $a $b], [::SolidSeam::pointSegmentDistance $point $b $c], [::SolidSeam::pointSegmentDistance $point $c $a])}]
    }
    set ap [::SolidSeam::shadowSub $point $a]
    set d1 [::SolidSeam::shadowDot $ab $ap]; set d2 [::SolidSeam::shadowDot $ac $ap]
    if {$d1 <= 0.0 && $d2 <= 0.0} { return [::SolidSeam::nodeDistance $point $a] }
    set bp [::SolidSeam::shadowSub $point $b]
    set d3 [::SolidSeam::shadowDot $ab $bp]; set d4 [::SolidSeam::shadowDot $ac $bp]
    if {$d3 >= 0.0 && $d4 <= $d3} { return [::SolidSeam::nodeDistance $point $b] }
    set vc [expr {$d1*$d4-$d3*$d2}]
    if {$vc <= 0.0 && $d1 >= 0.0 && $d3 <= 0.0} {
        return [::SolidSeam::nodeDistance $point [::SolidSeam::shadowAddScaled $a $ab [expr {1.0*$d1/($d1-$d3)}]]]
    }
    set cp [::SolidSeam::shadowSub $point $c]
    set d5 [::SolidSeam::shadowDot $ab $cp]; set d6 [::SolidSeam::shadowDot $ac $cp]
    if {$d6 >= 0.0 && $d5 <= $d6} { return [::SolidSeam::nodeDistance $point $c] }
    set vb [expr {$d5*$d2-$d1*$d6}]
    if {$vb <= 0.0 && $d2 >= 0.0 && $d6 <= 0.0} {
        return [::SolidSeam::nodeDistance $point [::SolidSeam::shadowAddScaled $a $ac [expr {1.0*$d2/($d2-$d6)}]]]
    }
    set va [expr {$d3*$d6-$d5*$d4}]
    if {$va <= 0.0 && $d4-$d3 >= 0.0 && $d5-$d6 >= 0.0} {
        set bc [::SolidSeam::shadowSub $c $b]
        return [::SolidSeam::nodeDistance $point [::SolidSeam::shadowAddScaled $b $bc [expr {1.0*($d4-$d3)/(($d4-$d3)+($d5-$d6))}]]]
    }
    set denominator [expr {1.0/($va+$vb+$vc)}]
    set closest [::SolidSeam::shadowAddScaled [::SolidSeam::shadowAddScaled $a $ab [expr {$vb*$denominator}]] $ac [expr {$vc*$denominator}]]
    return [::SolidSeam::nodeDistance $point $closest]
}

proc ::SolidSeam::pointSegmentDistance {point a b} {
    set ab [::SolidSeam::shadowSub $b $a]
    set denominator [::SolidSeam::shadowDot $ab $ab]
    if {$denominator <= 1.0e-24} { return [::SolidSeam::nodeDistance $point $a] }
    set t [expr {max(0.0,min(1.0,1.0*[::SolidSeam::shadowDot [::SolidSeam::shadowSub $point $a] $ab]/$denominator))}]
    return [::SolidSeam::nodeDistance $point [::SolidSeam::shadowAddScaled $a $ab $t]]
}

proc ::SolidSeam::shadowTriangleRecord {a b c} {
    set low {}; set high {}; set center {}
    for {set axis 0} {$axis < 3} {incr axis} {
        set av [lindex $a $axis]; set bv [lindex $b $axis]; set cv [lindex $c $axis]
        lappend low [expr {min($av,$bv,$cv)}]; lappend high [expr {max($av,$bv,$cv)}]
        lappend center [expr {($av+$bv+$cv)/3.0}]
    }
    return [concat $center [list $a $b $c [list $low $high]]]
}

proc ::SolidSeam::shadowTrianglesFromRing {ring interleaved} {
    set count [llength $ring]
    if {$interleaved && $count in {6 8}} {
        set corners {}
        for {set i 0} {$i < $count} {incr i 2} { lappend corners [lindex $ring $i] }
    } elseif {$count == 6} {
        set corners [lrange $ring 0 2]
    } elseif {$count == 8} {
        set corners [lrange $ring 0 3]
    } else { set corners $ring }
    if {[llength $corners] < 3} { return {} }
    set origin [::SolidSeam::nodeXYZ [lindex $corners 0]]; set triangles {}
    for {set i 1} {$i < [llength $corners]-1} {incr i} {
        lappend triangles [::SolidSeam::shadowTriangleRecord $origin \
            [::SolidSeam::nodeXYZ [lindex $corners $i]] [::SolidSeam::nodeXYZ [lindex $corners [expr {$i+1}]]]]
    }
    return $triangles
}

proc ::SolidSeam::shadowTargetTriangles {componentId} {
    set triangles {}
    if {[::SolidSeam::componentIsSolid $componentId]} {
        set native [::SolidSeam::nativeBoundaryData $componentId faces]
        if {$native ne "" && [llength [dict get $native faces]]} {
            foreach face [dict get $native faces] { set triangles [concat $triangles [::SolidSeam::shadowTrianglesFromRing $face 0]] }
            return $triangles
        }
        array set counts {}; array set rings {}
        foreach element [::SolidSeam::componentElementIds $componentId] {
            foreach face [::SolidSeam::elementFaces $element] {
                set key [::SolidSeam::faceKey $face]; incr counts($key); set rings($key) $face
            }
        }
        foreach key [array names counts] {
            if {$counts($key) == 1} { set triangles [concat $triangles [::SolidSeam::shadowTrianglesFromRing $rings($key) 1]] }
        }
    } else {
        foreach element [::SolidSeam::componentElementIds $componentId] {
            foreach face [::SolidSeam::elementFaces $element] { set triangles [concat $triangles [::SolidSeam::shadowTrianglesFromRing $face 0]] }
        }
    }
    return $triangles
}

proc ::SolidSeam::shadowBBoxForTriangles {triangles} {
    set low {Inf Inf Inf}; set high {-Inf -Inf -Inf}
    foreach triangle $triangles {
        lassign [lindex $triangle 6] tLow tHigh
        for {set axis 0} {$axis < 3} {incr axis} {
            lset low $axis [expr {min([lindex $low $axis],[lindex $tLow $axis])}]
            lset high $axis [expr {max([lindex $high $axis],[lindex $tHigh $axis])}]
        }
    }
    return [list $low $high]
}

proc ::SolidSeam::shadowBuildBVH {triangles} {
    if {![llength $triangles]} { return {} }
    set bbox [::SolidSeam::shadowBBoxForTriangles $triangles]
    if {[llength $triangles] <= 8} { return [dict create bbox $bbox triangles $triangles] }
    lassign $bbox low high
    set axis 0; set width [expr {[lindex $high 0]-[lindex $low 0]}]
    for {set i 1} {$i < 3} {incr i} {
        set current [expr {[lindex $high $i]-[lindex $low $i]}]
        if {$current > $width} { set axis $i; set width $current }
    }
    set sorted [lsort -real -index $axis $triangles]; set middle [expr {[llength $sorted]/2}]
    return [dict create bbox $bbox left [::SolidSeam::shadowBuildBVH [lrange $sorted 0 [expr {$middle-1}]]] right [::SolidSeam::shadowBuildBVH [lrange $sorted $middle end]]]
}

proc ::SolidSeam::shadowPointBBoxSquared {point bbox} {
    lassign $bbox low high; set result 0.0
    for {set axis 0} {$axis < 3} {incr axis} {
        set value [lindex $point $axis]
        if {$value < [lindex $low $axis]} { set delta [expr {[lindex $low $axis]-$value}] 
        } elseif {$value > [lindex $high $axis]} { set delta [expr {$value-[lindex $high $axis]}]
        } else { set delta 0.0 }
        set result [expr {$result+$delta*$delta}]
    }
    return $result
}

proc ::SolidSeam::shadowNearestVisit {tree point bestVar} {
    upvar 1 $bestVar best
    if {$tree eq "" || [::SolidSeam::shadowPointBBoxSquared $point [dict get $tree bbox]] > $best*$best} { return }
    if {[dict exists $tree triangles]} {
        foreach triangle [dict get $tree triangles] {
            set distance [::SolidSeam::pointTriangleDistance $point [lindex $triangle 3] [lindex $triangle 4] [lindex $triangle 5]]
            if {$distance < $best} { set best $distance }
        }
        return
    }
    set left [dict get $tree left]; set right [dict get $tree right]
    if {[::SolidSeam::shadowPointBBoxSquared $point [dict get $right bbox]] < [::SolidSeam::shadowPointBBoxSquared $point [dict get $left bbox]]} {
        set swap $left; set left $right; set right $swap
    }
    ::SolidSeam::shadowNearestVisit $left $point best
    ::SolidSeam::shadowNearestVisit $right $point best
}

proc ::SolidSeam::shadowNearestFaceDistance {tree point} {
    set best 1.0e100
    ::SolidSeam::shadowNearestVisit $tree $point best
    return $best
}

proc ::SolidSeam::shadowQuantile {sortedValues fraction} {
    if {![llength $sortedValues]} { return 0.0 }
    set index [expr {int($fraction*([llength $sortedValues]-1))}]
    return [lindex $sortedValues $index]
}

proc ::SolidSeam::shadowFaceDistanceAudit {source target legacyRows radius} {
    set started [clock milliseconds]
    set triangles [::SolidSeam::shadowTargetTriangles $target]
    if {![llength $triangles]} { error "target component $target has no triangulatable faces" }
    set tree [::SolidSeam::shadowBuildBVH $triangles]
    if {[::SolidSeam::componentIsSolid $source]} {
        set sourceNodes [::SolidSeam::solidFacingBoundaryNodes $source $target]
    } else { set sourceNodes [::SolidSeam::boundaryNodesOfComponent $source] }
    set legacy [dict create]
    foreach row $legacyRows { foreach node [dict get $row node_ids] { dict set legacy $node 1 } }
    set within 0; set misses {}; set faceDistances {}
    set targetIndex [::SolidSeam::spatialIndex [::SolidSeam::surfaceNodeIdsOfComponent $target [::SolidSeam::componentIsSolid $target]]]
    set deltaRatios {}
    foreach node $sourceNodes {
        set point [::SolidSeam::nodeXYZ $node]
        set faceDistance [::SolidSeam::shadowNearestFaceDistance $tree $point]
        if {$faceDistance <= $radius} {
            incr within
            if {![dict exists $legacy $node]} { lappend misses $node }
        }
        lassign [::SolidSeam::nearestNode $targetIndex $point] nearest nodeDistance
        if {$nearest ne "" && $radius > 0.0} { lappend deltaRatios [expr {($nodeDistance-$faceDistance)/$radius}] }
    }
    set p50 0.0; set p90 0.0; set p95 0.0; set p99 0.0; set maximum 0.0
    if {[llength $deltaRatios]} {
        set sorted [lsort -real $deltaRatios]
        set p50 [::SolidSeam::shadowQuantile $sorted 0.50]
        set p90 [::SolidSeam::shadowQuantile $sorted 0.90]
        set p95 [::SolidSeam::shadowQuantile $sorted 0.95]
        set p99 [::SolidSeam::shadowQuantile $sorted 0.99]
        set maximum [lindex $sorted end]
    }
    return [dict create mode SHADOW_ONLY source_component_id $source target_component_id $target \
        source_boundary_nodes [llength $sourceNodes] target_triangles [llength $triangles] \
        legacy_nodes [dict size $legacy] face_within_radius $within potential_false_negatives [llength $misses] \
        potential_false_negative_nodes [lrange $misses 0 99] \
        node_face_delta_p50_ratio [format %.6f $p50] node_face_delta_p90_ratio [format %.6f $p90] \
        node_face_delta_p95_ratio [format %.6f $p95] node_face_delta_p99_ratio [format %.6f $p99] \
        node_face_delta_max_ratio [format %.6f $maximum] \
        elapsed_ms [expr {[clock milliseconds]-$started}]]
}
