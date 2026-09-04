# Exact nearest-neighbour queries on a balanced 3D k-d tree. Coordinates are
# fetched once at construction, not in the source x target inner loop.
proc ::SolidSeam::spatialIndex {nodeIds} {
    set points {}
    foreach id [lsort -integer -unique $nodeIds] {
        lappend points [concat [::SolidSeam::nodeXYZ $id] [list $id]]
    }
    return [::SolidSeam::spatialTree $points 0]
}
proc ::SolidSeam::spatialTree {points axis} {
    if {[llength $points] == 0} { return {} }
    set sorted [lsort -real -index $axis $points]
    set middle [expr {[llength $sorted] / 2}]
    set next [expr {($axis + 1) % 3}]
    return [list [lindex $sorted $middle] $axis \
        [::SolidSeam::spatialTree [lrange $sorted 0 [expr {$middle - 1}]] $next] \
        [::SolidSeam::spatialTree [lrange $sorted [expr {$middle + 1}] end] $next]]
}
proc ::SolidSeam::nearestNode {tree point {radius 1.0e100} {exclude ""}} {
    set bestId ""
    set bestSquared [expr {$radius * $radius}]
    ::SolidSeam::spatialVisit $tree $point $exclude bestId bestSquared
    return [list $bestId [expr {sqrt($bestSquared)}]]
}
proc ::SolidSeam::spatialVisit {tree query exclude idVar distanceVar} {
    upvar 1 $idVar bestId $distanceVar bestSquared
    if {$tree eq ""} { return }
    lassign $tree point axis left right
    set id [lindex $point 3]
    set dx [expr {[lindex $query 0] - [lindex $point 0]}]
    set dy [expr {[lindex $query 1] - [lindex $point 1]}]
    set dz [expr {[lindex $query 2] - [lindex $point 2]}]
    set squared [expr {$dx*$dx + $dy*$dy + $dz*$dz}]
    if {$id ne $exclude && ($squared < $bestSquared || ($squared == $bestSquared && ($bestId eq "" || $id < $bestId)))} {
        set bestId $id
        set bestSquared $squared
    }
    set delta [expr {[lindex $query $axis] - [lindex $point $axis]}]
    if {$delta < 0} { set near $left; set far $right } else { set near $right; set far $left }
    ::SolidSeam::spatialVisit $near $query $exclude bestId bestSquared
    if {$delta*$delta <= $bestSquared} {
        ::SolidSeam::spatialVisit $far $query $exclude bestId bestSquared
    }
}
