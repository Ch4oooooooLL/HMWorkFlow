namespace eval ::hmtoolkit::seam::candidate {}

proc ::hmtoolkit::seam::candidate::distance {a b} {
    set dx [expr {[lindex $a 0]-[lindex $b 0]}]
    set dy [expr {[lindex $a 1]-[lindex $b 1]}]
    set dz [expr {[lindex $a 2]-[lindex $b 2]}]
    return [expr {sqrt($dx*$dx+$dy*$dy+$dz*$dz)}]
}

proc ::hmtoolkit::seam::candidate::line_points {lineId} {
    # Ruled correspondence must follow the complete curve, not just its ends
    # and midpoint.  The denser samples also make the pre-trim projection
    # reference discriminate between nearby curved boundary fragments.
    set parameters {0.0 0.125 0.25 0.375 0.5 0.625 0.75 0.875 1.0}
    if {![catch {set values [hm_getcoordinatesofpointsonline $lineId $parameters]}] && \
        [llength $values] == [llength $parameters]} {
        set result {}
        foreach value $values { lappend result [lrange $value 0 2] }
        return $result
    }
    error "Unable to read coordinates for line $lineId"
}

proc ::hmtoolkit::seam::candidate::nearest_surface_distance {surfId point} {
    foreach {x y z} $point {}
    if {![catch {set result [hm_findclosestpointonsurface $x $y $z $surfId]}] && [llength $result] >= 4} {
        return [expr {double([lindex $result 3])}]
    }
    if {![catch {set result [hm_getcoordinatesfromnearestsurface $x $y $z [list $surfId]]}] && [llength $result] >= 3} {
        return [::hmtoolkit::seam::candidate::distance $point [lrange $result 0 2]]
    }
    return ""
}

proc ::hmtoolkit::seam::candidate::line_length {lineId} {
    if {![catch {set value [hm_linelength $lineId]}] && [string is double -strict $value]} { return [expr {double($value)}] }
    set p [::hmtoolkit::seam::candidate::line_points $lineId]
    return [::hmtoolkit::seam::candidate::distance [lindex $p 0] [lindex $p end]]
}

proc ::hmtoolkit::seam::candidate::point_to_segment_distance {point a b} {
    set vx [expr {[lindex $b 0]-[lindex $a 0]}]
    set vy [expr {[lindex $b 1]-[lindex $a 1]}]
    set vz [expr {[lindex $b 2]-[lindex $a 2]}]
    set wx [expr {[lindex $point 0]-[lindex $a 0]}]
    set wy [expr {[lindex $point 1]-[lindex $a 1]}]
    set wz [expr {[lindex $point 2]-[lindex $a 2]}]
    set denominator [expr {$vx*$vx+$vy*$vy+$vz*$vz}]
    set fraction [expr {$denominator <= 1.0e-24 ? 0.0 : \
        max(0.0,min(1.0,($wx*$vx+$wy*$vy+$wz*$vz)/double($denominator)))}]
    set closest [list \
        [expr {[lindex $a 0]+$fraction*$vx}] \
        [expr {[lindex $a 1]+$fraction*$vy}] \
        [expr {[lindex $a 2]+$fraction*$vz}]]
    return [::hmtoolkit::seam::candidate::distance $point $closest]
}

proc ::hmtoolkit::seam::candidate::point_to_polyline_distance {point polyline} {
    if {[llength $polyline] < 2} { error "A reference polyline needs at least two points" }
    set best ""
    for {set index 1} {$index < [llength $polyline]} {incr index} {
        set distance [::hmtoolkit::seam::candidate::point_to_segment_distance \
            $point [lindex $polyline [expr {$index-1}]] [lindex $polyline $index]]
        if {$best eq "" || $distance < $best} { set best $distance }
    }
    return $best
}

# Return the closest distance and arc-length position of a point on a sampled
# reference polyline. The position lets disconnected trim fragments from
# several target surfaces be put into the same order as the source path.
proc ::hmtoolkit::seam::candidate::point_to_polyline_position {point polyline} {
    if {[llength $polyline] < 2} { error "A reference polyline needs at least two points" }
    set bestDistance ""
    set bestPosition 0.0
    set traversed 0.0
    for {set index 1} {$index < [llength $polyline]} {incr index} {
        set a [lindex $polyline [expr {$index-1}]]
        set b [lindex $polyline $index]
        set vx [expr {[lindex $b 0]-[lindex $a 0]}]
        set vy [expr {[lindex $b 1]-[lindex $a 1]}]
        set vz [expr {[lindex $b 2]-[lindex $a 2]}]
        set wx [expr {[lindex $point 0]-[lindex $a 0]}]
        set wy [expr {[lindex $point 1]-[lindex $a 1]}]
        set wz [expr {[lindex $point 2]-[lindex $a 2]}]
        set lengthSquared [expr {$vx*$vx+$vy*$vy+$vz*$vz}]
        set segmentLength [expr {sqrt($lengthSquared)}]
        set fraction [expr {$lengthSquared <= 1.0e-24 ? 0.0 : \
            max(0.0,min(1.0,($wx*$vx+$wy*$vy+$wz*$vz)/double($lengthSquared)))}]
        set closest [list \
            [expr {[lindex $a 0]+$fraction*$vx}] \
            [expr {[lindex $a 1]+$fraction*$vy}] \
            [expr {[lindex $a 2]+$fraction*$vz}]]
        set currentDistance [::hmtoolkit::seam::candidate::distance $point $closest]
        if {$bestDistance eq "" || $currentDistance < $bestDistance} {
            set bestDistance $currentDistance
            set bestPosition [expr {$traversed+$fraction*$segmentLength}]
        }
        set traversed [expr {$traversed+$segmentLength}]
    }
    return [list $bestDistance $bestPosition]
}

proc ::hmtoolkit::seam::candidate::node_for_point {point nodes tolerance} {
    for {set i 0} {$i < [llength $nodes]} {incr i} {
        if {[::hmtoolkit::seam::candidate::distance $point [lindex $nodes $i]] <= $tolerance} { return $i }
    }
    return -1
}

proc ::hmtoolkit::seam::candidate::path_topology {lineIds endpointProvider {tolerance ""}} {
    if {$tolerance eq ""} { set tolerance [::hmtoolkit::seam::config::get endpoint_merge_tolerance] }
    set nodes {}
    set edges {}
    foreach lineId $lineIds {
        set points [uplevel #0 [list $endpointProvider $lineId]]
        if {[llength $points] < 2} { continue }
        set pair {}
        foreach point [list [lindex $points 0] [lindex $points end]] {
            set node [::hmtoolkit::seam::candidate::node_for_point $point $nodes $tolerance]
            if {$node < 0} { lappend nodes $point; set node [expr {[llength $nodes]-1}] }
            lappend pair $node
        }
        lappend edges [list $lineId [lindex $pair 0] [lindex $pair 1]]
    }
    array set degree {}
    array set adjacency {}
    foreach edge $edges {
        set a [lindex $edge 1]; set b [lindex $edge 2]
        if {![info exists degree($a)]} { set degree($a) 0; set adjacency($a) {} }
        if {![info exists degree($b)]} { set degree($b) 0; set adjacency($b) {} }
        incr degree($a); incr degree($b)
        lappend adjacency($a) $b; lappend adjacency($b) $a
    }
    set components 0
    array set visited {}
    foreach node [array names degree] {
        if {[info exists visited($node)]} { continue }
        incr components
        set queue [list $node]
        while {[llength $queue] > 0} {
            set current [lindex $queue 0]; set queue [lrange $queue 1 end]
            if {[info exists visited($current)]} { continue }
            set visited($current) 1
            foreach next $adjacency($current) { if {![info exists visited($next)]} { lappend queue $next } }
        }
    }
    set ends 0; set branches 0; set closed 0
    foreach node [array names degree] {
        if {$degree($node) == 1} { incr ends }
        if {$degree($node) > 2} { incr branches }
    }
    if {[array size degree] > 0 && $ends == 0 && $branches == 0} { set closed 1 }
    set kind PATH
    if {$branches > 0} { set kind BRANCH } elseif {$components > 1} { set kind LIST }
    return [dict create kind $kind components $components end_nodes $ends branch_nodes $branches closed $closed]
}

# Return -1, 0 or 1 using a stable geometric ordering.  A coordinate-based
# start point makes the result independent of mark/selection order.
proc ::hmtoolkit::seam::candidate::compare_points {a b} {
    for {set axis 0} {$axis < 3} {incr axis} {
        set av [expr {double([lindex $a $axis])}]
        set bv [expr {double([lindex $b $axis])}]
        if {$av < $bv} { return -1 }
        if {$av > $bv} { return 1 }
    }
    return 0
}

proc ::hmtoolkit::seam::candidate::canonical_node {nodeIds nodes} {
    set selected [lindex $nodeIds 0]
    foreach nodeId [lrange $nodeIds 1 end] {
        if {[::hmtoolkit::seam::candidate::compare_points \
            [lindex $nodes $nodeId] [lindex $nodes $selected]] < 0} {
            set selected $nodeId
        }
    }
    return $selected
}

# Convert an arbitrary list of geometry line IDs into one continuous path.
# The returned line order follows the returned point order.  HyperMesh uses
# the order of *createlist lines when constructing a ruled surface, so passing
# mark order through unchanged can connect non-neighbouring segments and twist
# the result.
proc ::hmtoolkit::seam::candidate::ordered_line_path {lineIds endpointProvider {tolerance ""}} {
    if {$tolerance eq ""} { set tolerance [::hmtoolkit::seam::config::get endpoint_merge_tolerance] }
    if {[llength $lineIds] == 0} { error "A line path must not be empty" }
    if {[llength [lsort -integer -unique $lineIds]] != [llength $lineIds]} {
        error "A line path must not contain duplicate lines"
    }

    set nodes {}
    set edges {}
    array set incident {}
    array set degree {}
    foreach lineId $lineIds {
        set samples [uplevel #0 [list $endpointProvider $lineId]]
        if {[llength $samples] < 2} { error "Line $lineId has no readable endpoints" }
        set pair {}
        foreach point [list [lindex $samples 0] [lindex $samples end]] {
            set nodeId [::hmtoolkit::seam::candidate::node_for_point $point $nodes $tolerance]
            if {$nodeId < 0} {
                lappend nodes $point
                set nodeId [expr {[llength $nodes]-1}]
            }
            lappend pair $nodeId
        }
        set a [lindex $pair 0]
        set b [lindex $pair 1]
        if {$a == $b} { error "Line $lineId has coincident endpoints within the merge tolerance" }
        set edgeIndex [llength $edges]
        lappend edges [list $lineId $a $b]
        foreach nodeId [list $a $b] {
            if {![info exists incident($nodeId)]} {
                set incident($nodeId) {}
                set degree($nodeId) 0
            }
            lappend incident($nodeId) $edgeIndex
            incr degree($nodeId)
            if {$degree($nodeId) > 2} { error "Line path is branched at a shared endpoint" }
        }
    }

    set ends {}
    foreach nodeId [array names degree] {
        if {$degree($nodeId) == 1} { lappend ends $nodeId }
    }
    if {[llength $ends] == 2} {
        set closed 0
        set start [::hmtoolkit::seam::candidate::canonical_node $ends $nodes]
    } elseif {[llength $ends] == 0} {
        set closed 1
        set start [::hmtoolkit::seam::candidate::canonical_node [array names degree] $nodes]
    } else {
        error "Lines contain disconnected paths or incomplete endpoint pairs"
    }

    set current $start
    set orderedLines {}
    set orderedNodeIds [list $start]
    array set used {}
    while {[llength $orderedLines] < [llength $edges]} {
        set choices {}
        foreach edgeIndex $incident($current) {
            if {![info exists used($edgeIndex)]} { lappend choices $edgeIndex }
        }
        if {[llength $choices] == 0} { break }
        set chosen [lindex $choices 0]
        # A closed path has two choices only for its first edge.  Pick the
        # geometrically canonical direction so shuffled input is deterministic.
        if {[llength $choices] > 1} {
            foreach edgeIndex [lrange $choices 1 end] {
                set edge [lindex $edges $edgeIndex]
                set other [expr {[lindex $edge 1] == $current ? [lindex $edge 2] : [lindex $edge 1]}]
                set selectedEdge [lindex $edges $chosen]
                set selectedOther [expr {[lindex $selectedEdge 1] == $current ? [lindex $selectedEdge 2] : [lindex $selectedEdge 1]}]
                set comparison [::hmtoolkit::seam::candidate::compare_points \
                    [lindex $nodes $other] [lindex $nodes $selectedOther]]
                if {$comparison < 0 || ($comparison == 0 && [lindex $edge 0] < [lindex $selectedEdge 0])} {
                    set chosen $edgeIndex
                }
            }
        }
        set used($chosen) 1
        set edge [lindex $edges $chosen]
        lappend orderedLines [lindex $edge 0]
        set current [expr {[lindex $edge 1] == $current ? [lindex $edge 2] : [lindex $edge 1]}]
        lappend orderedNodeIds $current
    }
    if {[llength $orderedLines] != [llength $edges]} {
        error "Lines contain disconnected paths"
    }
    if {$closed && $current != $start} { error "Closed line path traversal did not return to its start" }

    set orderedPoints {}
    foreach nodeId $orderedNodeIds { lappend orderedPoints [lindex $nodes $nodeId] }
    return [dict create lines $orderedLines points $orderedPoints closed $closed]
}

proc ::hmtoolkit::seam::candidate::reverse_line_path {path} {
    dict set path lines [lreverse [dict get $path lines]]
    dict set path points [lreverse [dict get $path points]]
    return $path
}

proc ::hmtoolkit::seam::candidate::closed_line_path_variant {path start reverse} {
    set sourceLines [dict get $path lines]
    set sourcePoints [lrange [dict get $path points] 0 end-1]
    set count [llength $sourceLines]
    set lines {}
    set points {}
    for {set offset 0} {$offset < $count} {incr offset} {
        if {$reverse} {
            set pointIndex [expr {($start-$offset+$count)%$count}]
            set lineIndex [expr {($start-$offset-1+$count)%$count}]
        } else {
            set pointIndex [expr {($start+$offset)%$count}]
            set lineIndex $pointIndex
        }
        lappend points [lindex $sourcePoints $pointIndex]
        lappend lines [lindex $sourceLines $lineIndex]
    }
    lappend points [lindex $points 0]
    return [dict create lines $lines points $points closed 1]
}

proc ::hmtoolkit::seam::candidate::detailed_path_points {path endpointProvider} {
    set result {}
    set pathPoints [dict get $path points]
    set index 0
    foreach lineId [dict get $path lines] {
        set samples [uplevel #0 [list $endpointProvider $lineId]]
        if {[llength $samples] < 2} { error "Line $lineId has no readable samples" }
        set expectedStart [lindex $pathPoints $index]
        if {[::hmtoolkit::seam::candidate::distance [lindex $samples end] $expectedStart] < \
            [::hmtoolkit::seam::candidate::distance [lindex $samples 0] $expectedStart]} {
            set samples [lreverse $samples]
        }
        if {[llength $result] > 0} { set samples [lrange $samples 1 end] }
        set result [concat $result $samples]
        incr index
    }
    return $result
}

proc ::hmtoolkit::seam::candidate::resample_polyline {points count} {
    if {[llength $points] < 2} { error "A path needs at least two sample points" }
    set clean [list [lindex $points 0]]
    foreach point [lrange $points 1 end] {
        if {[::hmtoolkit::seam::candidate::distance [lindex $clean end] $point] > 1.0e-12} {
            lappend clean $point
        }
    }
    if {[llength $clean] < 2} { error "A path has zero sampled length" }
    set cumulative {0.0}
    set total 0.0
    for {set index 1} {$index < [llength $clean]} {incr index} {
        set total [expr {$total+[::hmtoolkit::seam::candidate::distance \
            [lindex $clean [expr {$index-1}]] [lindex $clean $index]]}]
        lappend cumulative $total
    }
    set output {}
    set segment 0
    for {set sample 0} {$sample < $count} {incr sample} {
        set target [expr {$total*$sample/double($count-1)}]
        while {$segment < [expr {[llength $clean]-2}] && \
            [lindex $cumulative [expr {$segment+1}]] < $target} { incr segment }
        set startDistance [lindex $cumulative $segment]
        set endDistance [lindex $cumulative [expr {$segment+1}]]
        set fraction [expr {($target-$startDistance)/max(1.0e-12,$endDistance-$startDistance)}]
        set a [lindex $clean $segment]
        set b [lindex $clean [expr {$segment+1}]]
        lappend output [list \
            [expr {[lindex $a 0]+$fraction*([lindex $b 0]-[lindex $a 0])}] \
            [expr {[lindex $a 1]+$fraction*([lindex $b 1]-[lindex $a 1])}] \
            [expr {[lindex $a 2]+$fraction*([lindex $b 2]-[lindex $a 2])}]]
    }
    return $output
}

proc ::hmtoolkit::seam::candidate::path_alignment_score {firstPath secondPath endpointProvider} {
    set count [expr {max(9,2*max([llength [dict get $firstPath lines]], \
        [llength [dict get $secondPath lines]])+1)}]
    set firstSamples [::hmtoolkit::seam::candidate::resample_polyline \
        [::hmtoolkit::seam::candidate::detailed_path_points $firstPath $endpointProvider] $count]
    set secondSamples [::hmtoolkit::seam::candidate::resample_polyline \
        [::hmtoolkit::seam::candidate::detailed_path_points $secondPath $endpointProvider] $count]
    set total 0.0
    set maximum 0.0
    for {set index 0} {$index < $count} {incr index} {
        set distance [::hmtoolkit::seam::candidate::distance \
            [lindex $firstSamples $index] [lindex $secondSamples $index]]
        set total [expr {$total+$distance}]
        if {$distance > $maximum} { set maximum $distance }
    }
    return [expr {$total/double($count)+$maximum}]
}

# Order both paths and make their start/end correspondence agree.  This is the
# final preparation step before *linearsurfacebetweenlines.
proc ::hmtoolkit::seam::candidate::organize_ruled_surface_lines {first second {endpointProvider ::hmtoolkit::seam::candidate::line_points} {firstTolerance ""} {secondTolerance ""}} {
    if {$secondTolerance eq ""} { set secondTolerance $firstTolerance }
    set firstPath [::hmtoolkit::seam::candidate::ordered_line_path $first $endpointProvider $firstTolerance]
    set secondPath [::hmtoolkit::seam::candidate::ordered_line_path $second $endpointProvider $secondTolerance]
    if {[dict get $firstPath closed] != [dict get $secondPath closed]} {
        error "Both edge groups must either be open paths or closed paths"
    }

    # Compare correspondence along the complete path, not only at its ends.
    # End-only matching is ambiguous for curved or differently segmented paths
    # and can select a direction that creates a twisted ruled surface.
    if {![dict get $firstPath closed]} {
        set same [::hmtoolkit::seam::candidate::path_alignment_score \
            $firstPath $secondPath $endpointProvider]
        set reversedPath [::hmtoolkit::seam::candidate::reverse_line_path $secondPath]
        set reversed [::hmtoolkit::seam::candidate::path_alignment_score \
            $firstPath $reversedPath $endpointProvider]
        if {$reversed < $same} {
            set secondPath $reversedPath
        }
    } else {
        # A closed path has neither a natural start nor a natural direction.
        # Try every cyclic start in both directions and keep the correspondence
        # with the shortest cross-path connections.
        set bestPath ""
        set bestScore ""
        set count [llength [dict get $secondPath lines]]
        for {set start 0} {$start < $count} {incr start} {
            foreach reverse {0 1} {
                set variant [::hmtoolkit::seam::candidate::closed_line_path_variant \
                    $secondPath $start $reverse]
                set score [::hmtoolkit::seam::candidate::path_alignment_score \
                    $firstPath $variant $endpointProvider]
                if {$bestScore eq "" || $score < $bestScore} {
                    set bestScore $score
                    set bestPath $variant
                }
            }
        }
        set secondPath $bestPath
    }
    return [dict create first_lines [dict get $firstPath lines] second_lines [dict get $secondPath lines]]
}

# Partition lines by coincident endpoints. The trim command can create extra
# boundary fragments as well as the projected path; connected components let
# the ruled workflow evaluate those results without trusting new-id order.
proc ::hmtoolkit::seam::candidate::connected_line_groups {lineIds endpointProvider {tolerance ""}} {
    if {$tolerance eq ""} { set tolerance [::hmtoolkit::seam::config::get endpoint_merge_tolerance] }
    set nodes {}
    array set nodeLines {}
    array set lineNodes {}
    foreach lineId [lsort -integer -unique $lineIds] {
        set samples [uplevel #0 [list $endpointProvider $lineId]]
        if {[llength $samples] < 2} { continue }
        foreach point [list [lindex $samples 0] [lindex $samples end]] {
            set nodeId [::hmtoolkit::seam::candidate::node_for_point $point $nodes $tolerance]
            if {$nodeId < 0} { lappend nodes $point; set nodeId [expr {[llength $nodes]-1}] }
            lappend lineNodes($lineId) $nodeId
            lappend nodeLines($nodeId) $lineId
        }
    }
    set groups {}
    array set visited {}
    foreach seed [lsort -integer [array names lineNodes]] {
        if {[info exists visited($seed)]} { continue }
        set queue [list $seed]
        set group {}
        while {[llength $queue] > 0} {
            set lineId [lindex $queue 0]
            set queue [lrange $queue 1 end]
            if {[info exists visited($lineId)]} { continue }
            set visited($lineId) 1
            lappend group $lineId
            foreach nodeId $lineNodes($lineId) {
                foreach neighbour $nodeLines($nodeId) {
                    if {![info exists visited($neighbour)]} { lappend queue $neighbour }
                }
            }
        }
        lappend groups [lsort -integer -unique $group]
    }
    return $groups
}

proc ::hmtoolkit::seam::candidate::point_to_line_group_distance {point lineIds} {
    foreach {x y z} $point {}
    set best ""
    foreach lineId $lineIds {
        if {![catch {set value [hm_findclosestpointonline $x $y $z $lineId]}] &&
            [llength $value] >= 4 && [string is double -strict [lindex $value 3]]} {
            set distance [expr {double([lindex $value 3])}]
        } else {
            set samples [::hmtoolkit::seam::candidate::line_points $lineId]
            set distance ""
            foreach sample $samples {
                set current [::hmtoolkit::seam::candidate::distance $point $sample]
                if {$distance eq "" || $current < $distance} { set distance $current }
            }
        }
        if {$distance ne "" && ($best eq "" || $distance < $best)} { set best $distance }
    }
    if {$best eq ""} { error "Unable to measure distance to candidate line group" }
    return $best
}

proc ::hmtoolkit::seam::candidate::line_group_match_score {sourceLines candidateLines} {
    set total 0.0
    set count 0
    foreach pair [list [list $sourceLines $candidateLines] [list $candidateLines $sourceLines]] {
        foreach lineId [lindex $pair 0] {
            foreach point [::hmtoolkit::seam::candidate::line_points $lineId] {
                set total [expr {$total + [::hmtoolkit::seam::candidate::point_to_line_group_distance \
                    $point [lindex $pair 1]]}]
                incr count
            }
        }
    }
    set sourceLength 0.0
    foreach lineId $sourceLines { set sourceLength [expr {$sourceLength + [::hmtoolkit::seam::candidate::line_length $lineId]}] }
    set candidateLength 0.0
    foreach lineId $candidateLines { set candidateLength [expr {$candidateLength + [::hmtoolkit::seam::candidate::line_length $lineId]}] }
    set lengthPenalty [expr {abs($sourceLength-$candidateLength) / max(1.0,$sourceLength) * max(1.0,$sourceLength*0.1)}]
    return [expr {$total/max(1,$count) + $lengthPenalty}]
}

# Capture where the selected source path is expected to land on the selected
# target surfaces before Project/Split changes their topology. This reference
# is used only by T List to identify the second Connect Edges input; it does not
# change the existing projection operation.
proc ::hmtoolkit::seam::candidate::project_line_samples_to_surfaces {sourceLines targetSurfs} {
    set projected {}
    if {[catch {
        set sourcePath [::hmtoolkit::seam::candidate::ordered_line_path \
            $sourceLines ::hmtoolkit::seam::candidate::line_points]
        set samples [::hmtoolkit::seam::candidate::detailed_path_points \
            $sourcePath ::hmtoolkit::seam::candidate::line_points]
    }]} { return {} }
    foreach point $samples {
            lassign $point x y z
            set best ""
            if {![catch {
                set value [hm_getcoordinatesfromnearestsurface $x $y $z $targetSurfs]
            }] && [llength $value] >= 3} {
                set best [lrange $value 0 2]
            } else {
                set bestDistance ""
                foreach surfId $targetSurfs {
                    if {[catch {set value [hm_findclosestpointonsurface $x $y $z $surfId]}] || \
                        [llength $value] < 4} { continue }
                    set distance [expr {double([lindex $value 3])}]
                    if {$bestDistance eq "" || $distance < $bestDistance} {
                        set bestDistance $distance
                        set best [lrange $value 0 2]
                    }
                }
            }
            if {$best ne ""} { lappend projected $best }
    }
    return $projected
}

# A missing or collapsed reference cannot safely distinguish the new trim
# path from another edge in the same split-surface boundary graph.  Keep the
# original sequence (including the closing point of a loop), remove only
# consecutive duplicates, and reject unreadable/collapsed references.
proc ::hmtoolkit::seam::candidate::validated_projection_reference {points} {
    set clean {}
    foreach point $points {
        if {[llength $point] < 3} { error "A projected reference point is incomplete" }
        set xyz [lrange $point 0 2]
        foreach value $xyz {
            if {![string is double -strict $value]} {
                error "A projected reference point is not numeric"
            }
        }
        if {[llength $clean] == 0 || \
            [::hmtoolkit::seam::candidate::distance [lindex $clean end] $xyz] > 1.0e-9} {
            lappend clean $xyz
        }
    }
    if {[llength $clean] < 2} {
        error "Fewer than two distinct target-surface projection points were captured"
    }
    return $clean
}

# HyperMesh can accept an ordered list whose projected pieces lie on several
# adjacent target surfaces even when those pieces do not share topology. This
# mirrors manual Connect Edges selection: retain only lines that travel along
# the projected reference, then sort them by their arc-length position.
proc ::hmtoolkit::seam::candidate::order_trim_fragments_along_reference {lineIds referencePoints} {
    set referencePoints [::hmtoolkit::seam::candidate::validated_projection_reference $referencePoints]
    set rows {}
    set bestScore ""
    foreach lineId [lsort -integer -unique $lineIds] {
        set samples [::hmtoolkit::seam::candidate::line_points $lineId]
        set totalDistance 0.0
        set maximumDistance 0.0
        set minimumPosition ""
        set maximumPosition ""
        foreach point $samples {
            lassign [::hmtoolkit::seam::candidate::point_to_polyline_position \
                $point $referencePoints] currentDistance currentPosition
            set totalDistance [expr {$totalDistance+$currentDistance}]
            if {$currentDistance > $maximumDistance} { set maximumDistance $currentDistance }
            if {$minimumPosition eq "" || $currentPosition < $minimumPosition} {
                set minimumPosition $currentPosition
            }
            if {$maximumPosition eq "" || $currentPosition > $maximumPosition} {
                set maximumPosition $currentPosition
            }
        }
        set lineLength [::hmtoolkit::seam::candidate::line_length $lineId]
        set span [expr {$maximumPosition-$minimumPosition}]
        set coverage [expr {$span/max(1.0e-9,$lineLength)}]
        # Boundary fragments that merely cross the projected path have almost
        # no travel along it and must not enter the ruled list.
        if {$coverage < 0.2} { continue }
        set score [expr {$totalDistance/max(1,[llength $samples])+$maximumDistance}]
        set center [expr {0.5*($minimumPosition+$maximumPosition)}]
        lappend rows [list $center $score $lineId]
        if {$bestScore eq "" || $score < $bestScore} { set bestScore $score }
    }
    if {[llength $rows] == 0} {
        error "No trim fragments travel along the projected source path"
    }
    set allowed [expr {2.0*[::hmtoolkit::seam::config::get projected_path_merge_tolerance]}]
    set ordered {}
    foreach row [lsort -real -index 0 $rows] {
        if {[lindex $row 1] <= $bestScore+$allowed} {
            lappend ordered [lindex $row 2]
        }
    }
    if {[llength $ordered] == 0} { error "No projected trim fragments passed geometric filtering" }
    return $ordered
}

proc ::hmtoolkit::seam::candidate::projected_reference_match_score {sourceLines referencePoints candidateLines {enforceCoverage 1} {mergeTolerance ""}} {
    if {$mergeTolerance eq ""} {
        set mergeTolerance [::hmtoolkit::seam::config::get projected_path_merge_tolerance]
    }
    set total 0.0
    set maximum 0.0
    foreach point $referencePoints {
        set distance [::hmtoolkit::seam::candidate::point_to_line_group_distance \
            $point $candidateLines]
        set total [expr {$total+$distance}]
        if {$distance > $maximum} { set maximum $distance }
    }
    set allowed [expr {2.0*[::hmtoolkit::seam::config::get projected_path_merge_tolerance]}]
    if {$enforceCoverage && $maximum > $allowed} {
        error "Candidate path misses an expected target-surface projection point by $maximum (allowed $allowed)"
    }
    set candidatePath [::hmtoolkit::seam::candidate::ordered_line_path \
        $candidateLines ::hmtoolkit::seam::candidate::line_points \
        $mergeTolerance]
    set candidateSamples [::hmtoolkit::seam::candidate::detailed_path_points \
        $candidatePath ::hmtoolkit::seam::candidate::line_points]
    set reverseMaximum 0.0
    foreach point $candidateSamples {
        set distance [::hmtoolkit::seam::candidate::point_to_polyline_distance \
            $point $referencePoints]
        if {$distance > $reverseMaximum} { set reverseMaximum $distance }
    }
    if {$enforceCoverage && $reverseMaximum > $allowed} {
        error "Candidate path contains a non-projected segment $reverseMaximum away from the expected trim path (allowed $allowed)"
    }
    set sourceLength 0.0
    foreach lineId $sourceLines {
        set sourceLength [expr {$sourceLength+[::hmtoolkit::seam::candidate::line_length $lineId]}]
    }
    set candidateLength 0.0
    foreach lineId $candidateLines {
        set candidateLength [expr {$candidateLength+[::hmtoolkit::seam::candidate::line_length $lineId]}]
    }
    set lengthPenalty [expr {0.1*abs($sourceLength-$candidateLength)}]
    return [expr {$total/max(1,[llength $referencePoints])+$maximum+$reverseMaximum+$lengthPenalty}]
}

# Enumerate unbranched routes through a split-surface edge graph.  A trim
# creates complete fragment boundaries, so the real projected edge can sit
# inside one connected graph with degree-3 junctions.  Treating the entire
# graph as one candidate rejects every valid T_LIST trim.  Enumerating simple
# routes between terminal/branch nodes lets geometric coverage scoring select
# the projected route without trusting entity IDs or boundary ordering.
proc ::hmtoolkit::seam::candidate::_collect_simple_routes {current goal adjacencyName edgeNodesName visitedName path limit outputName} {
    upvar 1 $adjacencyName adjacency $edgeNodesName edgeNodes $visitedName visited $outputName output
    if {[llength $output] >= $limit} { return }
    if {$current == $goal} {
        if {[llength $path] > 0} { lappend output $path }
        return
    }
    set visited($current) 1
    foreach lineId $adjacency($current) {
        lassign $edgeNodes($lineId) a b
        set next [expr {$a == $current ? $b : $a}]
        if {[info exists visited($next)]} { continue }
        ::hmtoolkit::seam::candidate::_collect_simple_routes $next $goal \
            adjacency edgeNodes visited [concat $path [list $lineId]] $limit output
        if {[llength $output] >= $limit} { break }
    }
    unset visited($current)
}

proc ::hmtoolkit::seam::candidate::simple_paths_from_lines {lineIds endpointProvider {tolerance ""} {limit 256}} {
    if {$tolerance eq ""} { set tolerance [::hmtoolkit::seam::config::get projected_path_merge_tolerance] }
    set nodes {}
    array set edgeNodes {}
    array set adjacency {}
    array set degree {}
    foreach lineId [lsort -integer -unique $lineIds] {
        set points [uplevel #0 [list $endpointProvider $lineId]]
        if {[llength $points] < 2} { continue }
        set pair {}
        foreach point [list [lindex $points 0] [lindex $points end]] {
            set nodeId [::hmtoolkit::seam::candidate::node_for_point $point $nodes $tolerance]
            if {$nodeId < 0} { lappend nodes $point; set nodeId [expr {[llength $nodes]-1}] }
            lappend pair $nodeId
        }
        lassign $pair a b
        set edgeNodes($lineId) [list $a $b]
        foreach nodeId [list $a $b] {
            if {![info exists adjacency($nodeId)]} { set adjacency($nodeId) {}; set degree($nodeId) 0 }
            lappend adjacency($nodeId) $lineId
            incr degree($nodeId)
        }
    }
    set critical {}
    foreach nodeId [array names degree] {
        if {$degree($nodeId) != 2} { lappend critical $nodeId }
    }
    if {[llength $critical] < 2} {
        set topology [::hmtoolkit::seam::candidate::path_topology $lineIds $endpointProvider $tolerance]
        if {[dict get $topology kind] eq "PATH" && [dict get $topology branch_nodes] == 0} {
            return [list [lsort -integer -unique $lineIds]]
        }
        return {}
    }
    set routes {}
    for {set i 0} {$i < [llength $critical]} {incr i} {
        for {set j [expr {$i+1}]} {$j < [llength $critical]} {incr j} {
            array set visited {}
            ::hmtoolkit::seam::candidate::_collect_simple_routes \
                [lindex $critical $i] [lindex $critical $j] adjacency edgeNodes visited {} $limit routes
            if {[llength $routes] >= $limit} { break }
        }
        if {[llength $routes] >= $limit} { break }
    }
    set unique {}
    array set seen {}
    foreach route $routes {
        set key [join [lsort -integer -unique $route] ,]
        if {$key eq "" || [info exists seen($key)]} { continue }
        set seen($key) 1
        lappend unique $route
    }
    return $unique
}

# Select the unbranched new line component whose sampled geometry best covers
# the selected source path. Ambiguous equal-score matches are rejected rather
# than allowing a ruled surface to attach to a split perimeter fragment.
proc ::hmtoolkit::seam::candidate::select_projected_trim_path {sourceLines newLines {referencePoints {}} {selectionMode STRICT} {mergeTolerance ""}} {
    set ranked {}
    set selectionMode [string toupper $selectionMode]
    if {$selectionMode ni {STRICT BEST}} { error "Unknown trim-path selection mode $selectionMode" }
    if {$mergeTolerance eq ""} {
        set mergeTolerance [::hmtoolkit::seam::config::get projected_path_merge_tolerance]
    }
    array set seen {}
    foreach group [::hmtoolkit::seam::candidate::connected_line_groups \
        $newLines ::hmtoolkit::seam::candidate::line_points $mergeTolerance] {
        set topology [::hmtoolkit::seam::candidate::path_topology \
            $group ::hmtoolkit::seam::candidate::line_points $mergeTolerance]
        if {[dict get $topology kind] eq "PATH" && [dict get $topology branch_nodes] == 0} {
            set candidates [list $group]
        } else {
            set candidates [::hmtoolkit::seam::candidate::simple_paths_from_lines \
                $group ::hmtoolkit::seam::candidate::line_points $mergeTolerance]
        }
        foreach candidate $candidates {
            set key [join [lsort -integer -unique $candidate] ,]
            if {$key eq "" || [info exists seen($key)]} { continue }
            set seen($key) 1
            if {[llength $referencePoints] > 0} {
                if {[catch {set score [::hmtoolkit::seam::candidate::projected_reference_match_score \
                    $sourceLines $referencePoints $candidate \
                    [expr {$selectionMode eq "STRICT"}] $mergeTolerance]}]} { continue }
            } else {
                if {[catch {set score [::hmtoolkit::seam::candidate::line_group_match_score \
                    $sourceLines $candidate]}]} { continue }
            }
            # Do not rank a geometrically close path that cannot be supplied
            # to ruled with the source path. This is especially important for
            # a closed split boundary next to an open source path.
            if {[catch {
                ::hmtoolkit::seam::candidate::organize_ruled_surface_lines \
                    $sourceLines $candidate ::hmtoolkit::seam::candidate::line_points \
                    [::hmtoolkit::seam::config::get endpoint_merge_tolerance] $mergeTolerance
            }]} { continue }
            lappend ranked [list $score $candidate]
        }
    }
    if {[llength $ranked] == 0} { error "No unbranched projected trim path was found" }
    set ranked [lsort -real -index 0 $ranked]
    set ambiguityTolerance [::hmtoolkit::seam::config::get projected_path_ambiguity_tolerance]
    if {$selectionMode eq "STRICT" && [llength $ranked] > 1 && \
        abs([lindex [lindex $ranked 1] 0]-[lindex [lindex $ranked 0] 0]) <= $ambiguityTolerance} {
        error "Projected trim path is ambiguous"
    }
    return [lindex [lindex $ranked 0] 1]
}
