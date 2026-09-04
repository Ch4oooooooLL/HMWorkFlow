# Bounded, deterministic mesh sampling for the initial search radius. Detailed
# parameters and classification are computed per detected seam afterwards.
proc ::SolidSeam::sampleEvenly {items limit} {
    set count [llength $items]
    if {$count <= $limit} { return $items }
    set result {}
    for {set i 0} {$i < $limit} {incr i} {
        lappend result [lindex $items [expr {$i * ($count - 1) / ($limit - 1)}]]
    }
    return $result
}

# Linear graph walks keep disconnected nearby edges separate and retain
# closure; nearest-distance chain sorting would be quadratic and ambiguous.
proc ::SolidSeam::automaticBoundaryPaths {nodes graph {splitBranches 0}} {
    set members [dict create]; set adjacency [dict create]; set starts {}
    foreach node $nodes { dict set members $node 1 }
    foreach node $nodes {
        set neighbors {}
        if {![dict exists $graph $node]} { error "Auto weld node $node is not on the source free boundary" }
        foreach neighbor [dict get $graph $node] {
            if {[dict exists $members $neighbor]} { lappend neighbors $neighbor }
        }
        if {!$splitBranches && [llength $neighbors] > 2} { error "Auto encountered a branched source boundary at node $node" }
        dict set adjacency $node $neighbors
        if {[llength $neighbors] < 2} { lappend starts $node }
    }
    if {$splitBranches} { return [::SolidSeam::boundaryEdgePaths $adjacency] }
    set visited [dict create]; set paths {}
    foreach start [concat [lsort -integer $starts] [lsort -integer $nodes]] {
        if {[dict exists $visited $start]} { continue }
        set path {}; set previous ""; set current $start; set closed 0
        while {![dict exists $visited $current]} {
            dict set visited $current 1
            lappend path $current
            set next ""
            foreach neighbor [dict get $adjacency $current] {
                if {$neighbor != $previous} { set next $neighbor; break }
            }
            if {$next eq ""} { break }
            if {$next == $start} { set closed [expr {[llength $path] >= 3}]; break }
            set previous $current; set current $next
        }
        if {[llength $path] >= 2} { lappend paths [dict create node_ids $path is_closed $closed] }
    }
    return $paths
}

# Track edges, not visited nodes: junction nodes belong to several independent
# paths. Stop at a junction rather than guessing which branch continues a seam.
proc ::SolidSeam::boundaryEdgePaths {graph} {
    set starts {}; set visited {}; set paths {}
    dict for {node neighbors} $graph {
        if {[llength $neighbors] != 2} { lappend starts $node }
    }
    foreach start [concat [lsort -integer $starts] [lsort -integer [dict keys $graph]]] {
        foreach neighbor [dict get $graph $start] {
            set edge [lsort -integer [list $start $neighbor]]
            if {[dict exists $visited $edge]} { continue }
            set path [list $start]; set previous $start; set current $neighbor; set closed 0
            while {1} {
                dict set visited [lsort -integer [list $previous $current]] 1
                if {$current == $start} { set closed 1; break }
                lappend path $current
                set neighbors [dict get $graph $current]
                if {[llength $neighbors] != 2} { break }
                set next [lindex $neighbors 0]
                if {$next == $previous} { set next [lindex $neighbors 1] }
                if {[dict exists $visited [lsort -integer [list $current $next]]]} { break }
                set previous $current; set current $next
            }
            if {[llength $path] >= 2} { lappend paths [dict create node_ids $path is_closed $closed] }
        }
    }
    return $paths
}

# The global closest-layer histogram can mistake the middle of one curved
# edge for a second layer. Restore only existing, in-range boundary edges
# between retained anchors, with a consistent direction along their chord.
proc ::SolidSeam::retainBoundaryInteriors {component pairs closest} {
    set selected {}; set available {}; set restored 0
    foreach pair $closest { dict set selected [lindex $pair 0] 1 }
    foreach pair $pairs { dict set available [lindex $pair 0] 1 }
    set graph [::SolidSeam::freeBoundaryGraph $component]
    set paths [::SolidSeam::automaticBoundaryPaths [dict keys $available] $graph 1]
    foreach record $paths {
        set nodes [dict get $record node_ids]
        if {[dict get $record is_closed]} {
            # Start at an anchor so the wraparound interval is inspected too.
            set first -1; set i 0
            foreach node $nodes {
                if {[dict exists $selected $node]} { set first $i; break }
                incr i
            }
            if {$first < 0} { continue }
            set nodes [concat [lrange $nodes $first end] [lrange $nodes 0 [expr {$first-1}]]]
            lappend nodes [lindex $nodes 0]
        }
        set previous -1; set index -1
        foreach node $nodes {
            incr index
            if {![dict exists $selected $node]} { continue }
            if {$previous >= 0 && $index > $previous+1} {
                set chord [::SolidSeam::vunit [::SolidSeam::vsub [::SolidSeam::nodeXYZ $node] \
                    [::SolidSeam::nodeXYZ [lindex $nodes $previous]]]]
                set smooth 1
                # Include adjacent edge directions: never continue around an
                # end corner, up a notch wall, or onto the opposite boundary.
                for {set k [expr {max(0,$previous-1)}]} {$k < min([llength $nodes]-1,$index+1)} {incr k} {
                    set tangent [::SolidSeam::vunit [::SolidSeam::vsub \
                        [::SolidSeam::nodeXYZ [lindex $nodes [expr {$k+1}]]] [::SolidSeam::nodeXYZ [lindex $nodes $k]]]]
                    if {[::SolidSeam::vdot $chord $tangent] < 0.5} { set smooth 0; break }
                }
                if {$smooth} {
                    foreach interior [lrange $nodes [expr {$previous+1}] [expr {$index-1}]] {
                        dict set selected $interior 1; incr restored
                    }
                }
            }
            set previous $index
        }
    }
    if {$restored} { ::SolidSeam::log INFO "source=$component restored_open_edge_interior_nodes=$restored" }
    set result {}
    foreach pair $pairs { if {[dict exists $selected [lindex $pair 0]]} { lappend result $pair } }
    return $result
}

proc ::SolidSeam::componentMeshPitch {componentId} {
    set lengths {}
    foreach element [::SolidSeam::sampleEvenly [::SolidSeam::componentElementIds $componentId] 128] {
        foreach face [::SolidSeam::elementFaces $element] {
            # Corner triangle edges give a robust mesh scale without an
            # all-node nearest-neighbour sweep of the component.
            set corners [lrange $face 0 2]
            if {[llength $corners] < 3} { continue }
            foreach {i j} {0 1 1 2} {
                set d [::SolidSeam::nodeDistance [::SolidSeam::nodeXYZ [lindex $corners $i]] [::SolidSeam::nodeXYZ [lindex $corners $j]]]
                if {$d > 0} { lappend lengths $d }
            }
        }
    }
    set pitch [::SolidSeam::median $lengths]
    if {$pitch <= 0} { error "Component $componentId has no usable mesh scale for Auto" }
    return $pitch
}

proc ::SolidSeam::automaticSettings {source target} {
    set pitch [expr {max([::SolidSeam::componentMeshPitch $source], [::SolidSeam::componentMeshPitch $target])}]
    set radius [expr {1.5 * $pitch}]
    return [dict create automatic 1 search_distance $radius max_search_distance $radius \
        min_weld_length 0.0 gap_jump_limit 0.0 default_width [expr {0.6*$pitch}] default_spacing [expr {0.6*$pitch}]]
}

# Shared incident-shell query: normals, material support and notch filtering
# reuse one cache entry. The cache is cleared at each detection boundary.
proc ::SolidSeam::localShellPatch {node component} {
    variable autoNormalCache
    set key "patch,$component,$node"
    if {[info exists autoNormalCache($key)]} { return $autoNormalCache($key) }
    set patch {}
    foreach element [lsort -integer [::SolidSeam::queryMarkedIds elems 1 "by node id" $node]] {
        if {[::SolidSeam::elementConfig $element] ni {103 104 106 108}} { continue }
        if {[hm_getvalue elems id=$element dataname=component] != $component} { continue }
        set elementKey "elementPatch,$component,$element"
        if {![info exists autoNormalCache($elementKey)]} {
            set all [::SolidSeam::elementNodes $element]
            set normal [::SolidSeam::faceUnitNormal [lrange $all 0 2]]
            if {[::SolidSeam::vdot $normal $normal] < 0.25} { continue }
            set corners [expr {[::SolidSeam::elementConfig $element] in {103 106} ? 3 : 4}]
            set center {0 0 0}
            foreach n [lrange $all 0 [expr {$corners-1}]] {
                set sum {}; foreach x $center y [::SolidSeam::nodeXYZ $n] { lappend sum [expr {$x+$y/double($corners)}] }; set center $sum
            }
            set autoNormalCache($elementKey) [dict create normal $normal center $center]
        }
        lappend patch $autoNormalCache($elementKey)
    }
    set autoNormalCache($key) $patch
    return $patch
}
proc ::SolidSeam::localShellNormal {node component} {
    set patch [::SolidSeam::localShellPatch $node $component]
    if {![llength $patch]} { return {} }
    return [dict get [lindex $patch 0] normal]
}

# Native L negative is the near-parallel side. For T, choose a side only
# when the target material clearly supports one side of the source edge.
# Interior T and coplanar B geometry cannot specify design intent: no vote.
proc ::SolidSeam::automaticSideVote {type sourceNormal targetNormal sourcePoint sourcePatch targetPatch mesh} {
    if {$type eq "L"} { return NEGATIVE }
    if {$type ne "T" || ![llength $sourcePatch] || ![llength $targetPatch]} { return UNKNOWN }
    set projection [::SolidSeam::vdot $sourceNormal $targetNormal]
    set axis {}; foreach s $sourceNormal t $targetNormal { lappend axis [expr {$s-$projection*$t}] }
    set axis [::SolidSeam::vunit $axis]
    # Outside the native near-right-angle band, positive is the obtuse side.
    set angle [::SolidSeam::angleDeg $sourceNormal $targetNormal]
    if {$angle < 88.0 || $angle > 92.0} {
        set inward [::SolidSeam::vsub [dict get [lindex $sourcePatch 0] center] $sourcePoint]
        if {[::SolidSeam::vdot $axis $inward] > 0} {
            set reversed {}; foreach v $axis { lappend reversed [expr {-$v}] }; set axis $reversed
        }
    }
    set positive 0.0; set negative 0.0
    foreach item $targetPatch {
        set d [::SolidSeam::vdot $axis [::SolidSeam::vsub [dict get $item center] $sourcePoint]]
        set positive [expr {max($positive,$d)}]; set negative [expr {max($negative,-$d)}]
    }
    if {$positive > 0.1*$mesh && $positive > 3*$negative} { return POSITIVE }
    if {$negative > 0.1*$mesh && $negative > 3*$positive} { return NEGATIVE }
    return UNKNOWN
}

proc ::SolidSeam::automaticJointVote {sourceNormal targetNormal delta meshSize} {
    if {[llength $sourceNormal] != 3 || [llength $targetNormal] != 3} { return NATIVE }
    set angle [::SolidSeam::angleDeg $sourceNormal $targetNormal]
    set angle [expr {min($angle, 180.0-$angle)}]
    if {$angle >= 70.0} { return T }
    if {$angle > 20.0} { return NATIVE }
    # Parallel shells: coplanar edge-to-edge joins are B; normal separation
    # indicates overlapping plates (L), even on nonmatching meshes.
    set separation 0.0
    foreach n $sourceNormal d $delta { set separation [expr {$separation+$n*$d}] }
    if {abs($separation) <= 1.0e-6*$meshSize} { return B }
    return L
}

proc ::SolidSeam::applyAutomaticParameters {candidate pairs} {
    set mesh [dict get $candidate mesh_size]
    set gap [dict get $candidate maximum_gap]
    set votes [dict create T 0 B 0 L 0 NATIVE 0]
    set sideVotes [dict create POSITIVE 0 NEGATIVE 0 UNKNOWN 0]
    set samples [::SolidSeam::sampleEvenly $pairs 32]
    foreach pair $samples {
        lassign $pair sourceNode targetNode distance
        set sourceNormal [::SolidSeam::localShellNormal $sourceNode [dict get $candidate source_component_id]]
        set targetNormal [::SolidSeam::localShellNormal $targetNode [dict get $candidate target_component_id]]
        set delta {}
        foreach a [::SolidSeam::nodeXYZ $sourceNode] b [::SolidSeam::nodeXYZ $targetNode] { lappend delta [expr {$b-$a}] }
        set type [::SolidSeam::automaticJointVote $sourceNormal $targetNormal $delta $mesh]
        dict incr votes $type
        set side [::SolidSeam::automaticSideVote $type $sourceNormal $targetNormal [::SolidSeam::nodeXYZ $sourceNode] \
            [::SolidSeam::localShellPatch $sourceNode [dict get $candidate source_component_id]] \
            [::SolidSeam::localShellPatch $targetNode [dict get $candidate target_component_id]] $mesh]
        dict incr sideVotes $side
    }
    set best NATIVE; set count 0
    dict for {type number} $votes {
        if {$number > $count} { set best $type; set count $number }
    }
    set confidence [expr {[llength $samples] ? double($count)/[llength $samples] : 0.0}]
    if {$confidence < 0.8 || $best eq "NATIVE"} {
        dict set candidate suggested_realization PENTA_MIG
        dict set candidate joint_type AUTO_NATIVE
        dict set candidate confidence_level NATIVE
    } else {
        dict set candidate suggested_realization PENTA_MIG_$best
        dict set candidate joint_type [dict get {T T_JOINT B BUTT_JOINT L LAP_JOINT} $best]
        dict set candidate confidence_level HIGH
    }
    variable ui
    set side $ui(side_mode)
    set strategy FALLBACK_SELECTION
    set sideConfidence 0.0
    if {$side eq "BOTH"} {
        set strategy EXPLICIT_BOTH
    } else {
        foreach choice {POSITIVE NEGATIVE} {
            set fraction [expr {[llength $samples] ? double([dict get $sideVotes $choice])/[llength $samples] : 0.0}]
            if {$fraction >= 0.8 && $confidence >= 0.8 && $best ne "NATIVE"} {
                set side $choice; set strategy LOCAL_GEOMETRY; set sideConfidence $fraction
            }
        }
    }
    dict set candidate side_mode $side
    dict set candidate side_strategy $strategy
    dict set candidate side_confidence $sideConfidence
    dict set candidate side_votes $sideVotes
    dict set candidate confidence $confidence
    dict set candidate classification_votes $votes
    dict set candidate weld_width [expr {0.6*$mesh}]
    dict set candidate line_spacing [expr {0.6*$mesh}]
    dict set candidate realization_tolerance [expr {max(1.5*$mesh, $gap+$mesh)}]
    dict unset candidate source_thickness
    dict set candidate parameter_strategy AUTO_GEOMETRY_V1
    return $candidate
}
