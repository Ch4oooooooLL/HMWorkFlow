namespace eval ::hmtoolkit::seam::candidate {}

proc ::hmtoolkit::seam::candidate::distance {a b} {
    set dx [expr {[lindex $a 0]-[lindex $b 0]}]
    set dy [expr {[lindex $a 1]-[lindex $b 1]}]
    set dz [expr {[lindex $a 2]-[lindex $b 2]}]
    return [expr {sqrt($dx*$dx+$dy*$dy+$dz*$dz)}]
}

proc ::hmtoolkit::seam::candidate::line_points {lineId} {
    if {![catch {set values [hm_getcoordinatesofpointsonline $lineId {0.0 0.5 1.0}]}] && [llength $values] == 3} {
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

proc ::hmtoolkit::seam::candidate::line_near_surfaces {lineId surfIds tolerance} {
    set maximum 0.0
    foreach point [::hmtoolkit::seam::candidate::line_points $lineId] {
        set best ""
        foreach surfId $surfIds {
            set value [::hmtoolkit::seam::candidate::nearest_surface_distance $surfId $point]
            if {$value ne "" && ($best eq "" || $value < $best)} { set best $value }
        }
        if {$best eq "" || $best > $tolerance} { return [list 0 ""] }
        if {$best > $maximum} { set maximum $best }
    }
    return [list 1 $maximum]
}

proc ::hmtoolkit::seam::candidate::vector {a b} {
    return [list [expr {[lindex $b 0]-[lindex $a 0]}] [expr {[lindex $b 1]-[lindex $a 1]}] [expr {[lindex $b 2]-[lindex $a 2]}]]
}

proc ::hmtoolkit::seam::candidate::cross {a b} {
    return [list \
        [expr {[lindex $a 1]*[lindex $b 2]-[lindex $a 2]*[lindex $b 1]}] \
        [expr {[lindex $a 2]*[lindex $b 0]-[lindex $a 0]*[lindex $b 2]}] \
        [expr {[lindex $a 0]*[lindex $b 1]-[lindex $a 1]*[lindex $b 0]}]]
}

proc ::hmtoolkit::seam::candidate::norm {v} {
    return [expr {sqrt([lindex $v 0]*[lindex $v 0]+[lindex $v 1]*[lindex $v 1]+[lindex $v 2]*[lindex $v 2])}]
}

proc ::hmtoolkit::seam::candidate::surface_normal {surfId} {
    set lines [::hmtoolkit::seam::entity::surface_lines [list $surfId]]
    set points {}
    foreach lineId $lines {
        if {![catch {set samples [::hmtoolkit::seam::candidate::line_points $lineId]}]} {
            lappend points [lindex $samples 0] [lindex $samples end]
        }
    }
    if {[llength $points] < 3} { return "" }
    set origin [lindex $points 0]
    for {set i 1} {$i < [llength $points]-1} {incr i} {
        set a [::hmtoolkit::seam::candidate::vector $origin [lindex $points $i]]
        set b [::hmtoolkit::seam::candidate::vector $origin [lindex $points [expr {$i+1}]]]
        set n [::hmtoolkit::seam::candidate::cross $a $b]
        set length [::hmtoolkit::seam::candidate::norm $n]
        if {$length > 1.0e-9} {
            return [list [expr {[lindex $n 0]/$length}] [expr {[lindex $n 1]/$length}] [expr {[lindex $n 2]/$length}]]
        }
    }
    return ""
}

proc ::hmtoolkit::seam::candidate::normal_angle {a b} {
    if {$a eq "" || $b eq ""} { return "" }
    set dot [expr {abs([lindex $a 0]*[lindex $b 0]+[lindex $a 1]*[lindex $b 1]+[lindex $a 2]*[lindex $b 2])}]
    if {$dot > 1.0} { set dot 1.0 }
    return [expr {acos($dot)*180.0/acos(-1.0)}]
}

proc ::hmtoolkit::seam::candidate::line_length {lineId} {
    if {![catch {set value [hm_linelength $lineId]}] && [string is double -strict $value]} { return [expr {double($value)}] }
    set p [::hmtoolkit::seam::candidate::line_points $lineId]
    return [::hmtoolkit::seam::candidate::distance [lindex $p 0] [lindex $p end]]
}

proc ::hmtoolkit::seam::candidate::line_bbox {lineIds} {
    set points {}
    foreach lineId $lineIds {
        if {![catch {set samples [::hmtoolkit::seam::candidate::line_points $lineId]}]} { set points [concat $points $samples] }
    }
    if {[llength $points] == 0} { return "" }
    set first [lindex $points 0]
    set minimum $first; set maximum $first
    foreach point [lrange $points 1 end] {
        for {set axis 0} {$axis < 3} {incr axis} {
            if {[lindex $point $axis] < [lindex $minimum $axis]} { lset minimum $axis [lindex $point $axis] }
            if {[lindex $point $axis] > [lindex $maximum $axis]} { lset maximum $axis [lindex $point $axis] }
        }
    }
    return [dict create min $minimum max $maximum]
}

proc ::hmtoolkit::seam::candidate::bbox_overlap_ratio {a b tolerance} {
    if {$a eq "" || $b eq ""} { return 0.0 }
    set scores {}
    for {set axis 0} {$axis < 3} {incr axis} {
        set amin [lindex [dict get $a min] $axis]; set amax [lindex [dict get $a max] $axis]
        set bmin [lindex [dict get $b min] $axis]; set bmax [lindex [dict get $b max] $axis]
        set spanA [expr {$amax-$amin}]; set spanB [expr {$bmax-$bmin}]
        set basis [expr {min($spanA,$spanB)}]
        if {$basis <= $tolerance} { continue }
        set overlap [expr {min($amax,$bmax)-max($amin,$bmin)}]
        lappend scores [::hmtoolkit::seam::classifier::clamp [expr {($overlap+$tolerance)/($basis+$tolerance)}]]
    }
    if {[llength $scores] == 0} { return 0.0 }
    set total 0.0
    foreach score $scores { set total [expr {$total+$score}] }
    return [expr {$total/double([llength $scores])}]
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

proc ::hmtoolkit::seam::candidate::extract_pair {sourceSurf targetSurf sourceComponents targetComponents candidateId} {
    set tolerance [::hmtoolkit::seam::config::get distance_tolerance]
    set sourceSurfs [list $sourceSurf]
    set targetSurfs [list $targetSurf]
    set sourceLines [::hmtoolkit::seam::entity::surface_lines $sourceSurfs]
    set targetLines [::hmtoolkit::seam::entity::surface_lines $targetSurfs]
    set nearSource {}; set nearTarget {}; set minDistance ""
    foreach lineId $sourceLines {
        set near [::hmtoolkit::seam::candidate::line_near_surfaces $lineId $targetSurfs $tolerance]
        if {[lindex $near 0]} { lappend nearSource $lineId; set d [lindex $near 1]; if {$minDistance eq "" || $d<$minDistance} {set minDistance $d} }
    }
    foreach lineId $targetLines {
        set near [::hmtoolkit::seam::candidate::line_near_surfaces $lineId $sourceSurfs $tolerance]
        if {[lindex $near 0]} { lappend nearTarget $lineId; set d [lindex $near 1]; if {$minDistance eq "" || $d<$minDistance} {set minDistance $d} }
    }
    if {[llength $nearSource] == 0 && [llength $nearTarget] == 0} { return "" }
    set seamLines $nearSource
    if {[llength $seamLines] == 0} { set seamLines $nearTarget }
    set topology [::hmtoolkit::seam::candidate::path_topology $seamLines ::hmtoolkit::seam::candidate::line_points]
    set length 0.0
    foreach lineId $seamLines { set length [expr {$length+[::hmtoolkit::seam::candidate::line_length $lineId]}] }
    set normalA [::hmtoolkit::seam::candidate::surface_normal $sourceSurf]
    set normalB [::hmtoolkit::seam::candidate::surface_normal $targetSurf]
    set angle [::hmtoolkit::seam::candidate::normal_angle $normalA $normalB]
    set overlap [::hmtoolkit::seam::candidate::bbox_overlap_ratio \
        [::hmtoolkit::seam::candidate::line_bbox $nearSource] \
        [::hmtoolkit::seam::candidate::line_bbox $nearTarget] $tolerance]
    set sourceComp [::hmtoolkit::seam::entity::surface_component $sourceSurf]
    set targetComp [::hmtoolkit::seam::entity::surface_component $targetSurf]
    if {$sourceComp ne ""} { set sourceComponents [list $sourceComp] }
    if {$targetComp ne ""} { set targetComponents [list $targetComp] }
    set candidate [dict create candidate_id $candidateId joint_type UNKNOWN strategy REVIEW \
        source_components $sourceComponents target_components $targetComponents source_surfs $sourceSurfs target_surfs $targetSurfs \
        seam_lines $seamLines paired_target_lines $nearTarget angle $angle min_distance $minDistance overlap_ratio $overlap \
        seam_length $length path_topology $topology confidence 0.0 reasons {} warnings {}]
    return [::hmtoolkit::seam::classifier::classify $candidate]
}

proc ::hmtoolkit::seam::candidate::extract {sourceSurfs targetSurfs {sourceComponents {}} {targetComponents {}}} {
    set candidates {}
    set index 0
    foreach sourceSurf [lsort -integer -unique $sourceSurfs] {
        foreach targetSurf [lsort -integer -unique $targetSurfs] {
            if {$sourceSurf == $targetSurf} { continue }
            incr index
            set id [format "SEAM_%04d" $index]
            set candidate [::hmtoolkit::seam::candidate::extract_pair \
                $sourceSurf $targetSurf $sourceComponents $targetComponents $id]
            if {$candidate ne ""} { lappend candidates $candidate }
        }
    }
    return $candidates
}
