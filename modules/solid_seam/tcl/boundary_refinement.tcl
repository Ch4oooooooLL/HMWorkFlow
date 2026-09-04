# Small local vector operations shared by boundary and side classification.
proc ::SolidSeam::vsub {a b} { set r {}; foreach x $a y $b { lappend r [expr {$x-$y}] }; return $r }
proc ::SolidSeam::vdot {a b} { set r 0.0; foreach x $a y $b { set r [expr {$r+$x*$y}] }; return $r }
proc ::SolidSeam::vunit {a} {
    set length [expr {sqrt([::SolidSeam::vdot $a $a])}]
    if {$length < 1.0e-12} { return {0 0 0} }
    set r {}; foreach x $a { lappend r [expr {$x/$length}] }; return $r
}

# Exclude a bounded local inward excursion that returns to the same edge.
# Keep both mouth nodes as endpoints; never replace the notch with a chord.
# Each mouth examines at most 24 boundary edges, independent of model size.
proc ::SolidSeam::excludeBoundaryNotches {records component mesh} {
    set result {}
    foreach record $records {
        set nodes [dict get $record node_ids]; set count [llength $nodes]
        set closed [dict get $record is_closed]
        if {$count < 6} { lappend result $record; continue }
        set xyz {}; foreach node $nodes { lappend xyz [::SolidSeam::nodeXYZ $node] }
        set blocked [dict create]
        for {set i 0} {$i < $count} {incr i} {
            if {!$closed && ($i == 0 || $i >= $count-2)} { continue }
            if {[dict exists $blocked $i]} { continue }
            set p [lindex $xyz $i]
            set incoming [::SolidSeam::vunit [::SolidSeam::vsub $p [lindex $xyz [expr {($i-1+$count)%$count}]]]]
            set first [::SolidSeam::vunit [::SolidSeam::vsub [lindex $xyz [expr {($i+1)%$count}]] $p]]
            if {[::SolidSeam::vdot $incoming $first] > 0.7071} { continue }
            set patch [::SolidSeam::localShellPatch [lindex $nodes $i] $component]
            if {![llength $patch]} { continue }
            set normal [dict get [lindex $patch 0] normal]
            set inward {0 0 0}
            foreach item $patch {
                set delta [::SolidSeam::vsub [dict get $item center] $p]
                set along [::SolidSeam::vdot $delta $incoming]
                set part {}; foreach x $delta t $incoming { lappend part [expr {$x-$along*$t}] }
                set sum {}; foreach x $inward y $part { lappend sum [expr {$x+$y}] }; set inward $sum
            }
            set inward [::SolidSeam::vunit $inward]
            if {[::SolidSeam::vdot $first $inward] < 0.5} { continue }
            set depth 0.0
            set limit [expr {min(24,$count-2)}]
            for {set step 1} {$step <= $limit} {incr step} {
                if {!$closed && $i+$step >= $count-1} { break }
                set j [expr {($i+$step)%$count}]
                if {[dict exists $blocked $j]} { break }
                set delta [::SolidSeam::vsub [lindex $xyz $j] $p]
                # A folded/warped plate is not a missing-element pocket in
                # this local shell plane. Leave uncertain geometry intact.
                if {abs([::SolidSeam::vdot $delta $normal]) > 0.1*$mesh} { break }
                set height [::SolidSeam::vdot $delta $inward]
                set distance [expr {sqrt([::SolidSeam::vdot $delta $delta])}]
                if {$height < -0.1*$mesh || $height > 4*$mesh || $distance > 8*$mesh} { break }
                set depth [expr {max($depth,$height)}]
                if {$step < 3 || $depth < 0.35*$mesh || abs($height) > 0.1*$mesh} { continue }
                set chord [::SolidSeam::vunit $delta]
                set outgoing [::SolidSeam::vunit [::SolidSeam::vsub [lindex $xyz [expr {($j+1)%$count}]] [lindex $xyz $j]]]
                if {[::SolidSeam::vdot $incoming $outgoing] < 0.94 || [::SolidSeam::vdot $incoming $chord] < 0.94} { continue }
                for {set k 0} {$k < $step} {incr k} { dict set blocked [expr {($i+$k)%$count}] 1 }
                break
            }
        }
        if {![dict size $blocked]} { lappend result $record; continue }
        # Walk once starting immediately after a removed edge on closed loops.
        set start 0
        if {$closed} { set start [expr {([lindex [dict keys $blocked] 0]+1)%$count}] }
        set path {}
        for {set k 0} {$k < $count} {incr k} {
            set i [expr {($start+$k)%$count}]
            lappend path [lindex $nodes $i]
            if {[dict exists $blocked $i] || (!$closed && $i == $count-1)} {
                if {[llength $path] >= 2} { lappend result [dict create node_ids $path is_closed 0] }
                set path {}
            }
        }
        if {[llength $path] >= 2} { lappend result [dict create node_ids $path is_closed 0] }
    }
    return $result
}
