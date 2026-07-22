namespace eval ::hmtoolkit::seam::classifier {}

proc ::hmtoolkit::seam::classifier::clamp {value} {
    if {$value < 0.0} { return 0.0 }
    if {$value > 1.0} { return 1.0 }
    return $value
}

proc ::hmtoolkit::seam::classifier::classify {candidate} {
    set parallelMax [::hmtoolkit::seam::config::get angle_parallel_max]
    set perpendicularMin [::hmtoolkit::seam::config::get angle_perpendicular_min]
    set distanceTolerance [::hmtoolkit::seam::config::get distance_tolerance]
    set minLength [::hmtoolkit::seam::config::get min_seam_length]
    set angle [dict get $candidate angle]
    set distance [dict get $candidate min_distance]
    set length [dict get $candidate seam_length]
    set overlap [dict get $candidate overlap_ratio]
    set topology [dict get $candidate path_topology]
    set sourceLines [dict get $candidate seam_lines]
    set targetLines [dict get $candidate paired_target_lines]
    set reasons {}; set warnings {}; set joint UNKNOWN; set strategy REVIEW

    set angleScore 0.0
    if {$angle ne ""} {
        if {$angle <= $parallelMax} {
            set angleScore [::hmtoolkit::seam::classifier::clamp [expr {1.0-$angle/$parallelMax}]]
            if {[llength $sourceLines] > 0 && [llength $targetLines] > 0 && $overlap > 0.2} {
                set joint LAP_JOINT; set strategy L_SURF
                lappend reasons "Surface boundary planes are approximately parallel and their nearby edges overlap in projection."
            } else {
                lappend warnings "Parallel surfaces do not have enough measurable boundary overlap for lap classification."
            }
        } elseif {$angle >= $perpendicularMin} {
            set angleScore [::hmtoolkit::seam::classifier::clamp [expr {($angle-$perpendicularMin)/(90.0-$perpendicularMin)}]]
            if {[llength $sourceLines] > 0 && [llength $targetLines] > 0} {
                set joint CORNER_JOINT
                lappend reasons "Both surfaces terminate with nearby edges at an approximately perpendicular angle."
            } elseif {[llength $sourceLines] > 0 || [llength $targetLines] > 0} {
                set joint T_JOINT
                lappend reasons "One free-edge set projects to an approximately perpendicular target surface."
            }
        } else {
            lappend warnings "Surface angle is outside the configured parallel and perpendicular bands."
        }
    } else {
        lappend warnings "A stable surface normal could not be derived from boundary geometry."
    }

    set distanceScore 0.0
    if {$distance ne ""} {
        set distanceScore [::hmtoolkit::seam::classifier::clamp [expr {1.0-$distance/double($distanceTolerance)}]]
        lappend reasons "Candidate edges are within the configured distance tolerance."
    }
    set lengthScore [::hmtoolkit::seam::classifier::clamp [expr {$length/double($minLength)}]]
    if {$length < $minLength} { lappend warnings "Candidate seam is shorter than the configured minimum length." }

    set pathScore 0.0
    switch -- [dict get $topology kind] {
        PATH {
            set pathScore 1.0
            if {$joint eq "T_JOINT"} { set strategy T_PATH }
            if {$joint eq "CORNER_JOINT"} { set strategy CONNECT }
            lappend reasons "Candidate lines form one unbranched path."
        }
        LIST {
            set pathScore 0.7
            if {$joint eq "T_JOINT"} { set strategy T_LIST }
            if {$joint eq "CORNER_JOINT"} { set strategy L_LIST }
            lappend reasons "Candidate lines form multiple independent paths."
        }
        BRANCH {
            set pathScore 0.2; set strategy REVIEW
            lappend warnings "Candidate path contains a branch and requires review."
        }
    }
    if {$joint eq "LAP_JOINT" && [dict get $topology kind] eq "LIST"} { set strategy L_LIST }

    # Topology and measurable proximity receive the largest weights in v1.
    # Overlap/thickness hooks remain explicit and can be enriched without changing the API.
    set overlapScore [::hmtoolkit::seam::classifier::clamp $overlap]
    if {$joint ne "LAP_JOINT"} { set overlapScore 1.0 }
    set confidence [expr {0.25*$angleScore + 0.25*$distanceScore + 0.20*$overlapScore + 0.20*$pathScore + 0.10*$lengthScore}]
    if {$joint eq "UNKNOWN" || $strategy eq "REVIEW"} { set confidence [expr {min($confidence,0.59)}] }
    dict set candidate joint_type $joint
    dict set candidate strategy $strategy
    dict set candidate confidence [format %.3f $confidence]
    dict set candidate reasons $reasons
    dict set candidate warnings $warnings
    return $candidate
}

proc ::hmtoolkit::seam::classifier::decision {candidate} {
    set confidence [dict get $candidate confidence]
    if {[dict get $candidate strategy] eq "REVIEW"} { return REVIEW }
    if {$confidence >= [::hmtoolkit::seam::config::get auto_accept_confidence]} { return ACCEPT }
    if {$confidence >= [::hmtoolkit::seam::config::get review_confidence]} { return REVIEW }
    return REJECT
}
