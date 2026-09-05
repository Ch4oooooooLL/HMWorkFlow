# Same seed semantics as MeshSeamWeld::pathsFromNativeFreeEdgeGraphs:
# boundary seed -> its loop; interior seed -> all component free-edge loops.
# Work on source topology only. Distances must never close an open boundary.
proc ::SolidSeam::freeBoundaryGraph {componentId} {
    variable detectionCacheActive; variable detectionReadCache
    variable groupRecognitionActive; variable groupRecognitionComponents; variable groupReadCache
    set key [list freeGraph $componentId]
    set groupCache [expr {[info exists groupRecognitionActive] && $groupRecognitionActive &&
        [info exists groupRecognitionComponents] && $componentId in $groupRecognitionComponents}]
    if {$groupCache && [info exists groupReadCache($key)]} { return $groupReadCache($key) }
    set cache [expr {[info exists detectionCacheActive] && $detectionCacheActive}]
    if {$cache && [info exists detectionReadCache($key)]} { return $detectionReadCache($key) }
    set result [::SolidSeam::freeBoundaryGraphImpl $componentId]
    if {$groupCache} { set groupReadCache($key) $result }
    if {$cache} { set detectionReadCache($key) $result }
    return $result
}

proc ::SolidSeam::freeBoundaryGraphImpl {componentId} {
    set native [::SolidSeam::nativeBoundaryData $componentId edges 1]
    if {$native ne ""} {
        set edges [dict get $native edges]
    } else {
        # Compatibility fallback for profiles without native free edges.
        # Only shell faces have free boundaries; a closed solid surface does
        # not acquire a fictitious seam by sorting all of its surface nodes.
        set counts [dict create]
        foreach elementId [::SolidSeam::componentElementIds $componentId] {
            set config [::SolidSeam::elementConfig $elementId]
            if {$config ni {103 104 106 108}} { continue }
            set nodes [::SolidSeam::elementNodes $elementId]
            if {$config == 106} {
                set order {0 3 1 4 2 5}
            } elseif {$config == 108} {
                set order {0 4 1 5 2 6 3 7}
            } else { set order {} }
            if {$order ne ""} {
                set ring {}
                foreach index $order { lappend ring [lindex $nodes $index] }
                set nodes $ring
            }
            for {set i 0} {$i < [llength $nodes]} {incr i} {
                set a [lindex $nodes $i]
                set b [lindex $nodes [expr {($i + 1) % [llength $nodes]}]]
                if {$a eq "" || $b eq "" || $a == $b} { continue }
                dict incr counts [lsort -integer [list $a $b]]
            }
        }
        set edges {}
        dict for {edge count} $counts { if {$count == 1} { lappend edges $edge } }
    }
    set graph [dict create]
    foreach edge $edges {
        lassign $edge a b
        dict lappend graph $a $b
        dict lappend graph $b $a
    }
    dict for {node neighbors} $graph { dict set graph $node [lsort -integer -unique $neighbors] }
    return $graph
}

proc ::SolidSeam::closedPathsForSeed {seed graph} {
    set seen [dict create]; set loops {}
    foreach start [lsort -integer [dict keys $graph]] {
        if {[dict exists $seen $start]} { continue }
        set queue [list $start]; set region {}; set closed 1
        dict set seen $start 1
        for {set i 0} {$i < [llength $queue]} {incr i} {
            set node [lindex $queue $i]
            lappend region $node
            set neighbors [dict get $graph $node]
            if {[llength $neighbors] != 2} { set closed 0 }
            foreach neighbor $neighbors {
                if {![dict exists $seen $neighbor]} {
                    dict set seen $neighbor 1
                    lappend queue $neighbor
                }
            }
        }
        set containsSeed [expr {[lsearch -exact $region $seed] >= 0}]
        if {!$closed || [llength $region] < 3} {
            if {$containsSeed} {
                error [::SolidSeam::txt "节点 $seed 所在自由边界开口或分叉，不能生成闭环。" "Node $seed lies on an open or branched free boundary."]
            }
            continue
        }
        if {[dict exists $graph $seed] && !$containsSeed} { continue }
        if {$containsSeed} { set start $seed }
        set path [list $start]; set previous $start
        set current [lindex [dict get $graph $start] 0]
        while {$current != $start} {
            lappend path $current
            set neighbors [dict get $graph $current]
            set next [lindex $neighbors 0]
            if {$next == $previous} { set next [lindex $neighbors 1] }
            set previous $current; set current $next
        }
        lappend loops $path
    }
    if {[llength $loops] == 0} {
        error [::SolidSeam::txt "节点 $seed 的源组件上没有可用的闭合自由边界。" "The source component of node $seed has no usable closed free boundary."]
    }
    return $loops
}

proc ::SolidSeam::closedBoundariesForSeed {seed componentId} {
    set paths [::SolidSeam::closedPathsForSeed $seed [::SolidSeam::freeBoundaryGraph $componentId]]
    ::SolidSeam::log INFO "single-node seed=$seed source=$componentId closed_boundaries=[llength $paths]"
    return $paths
}
