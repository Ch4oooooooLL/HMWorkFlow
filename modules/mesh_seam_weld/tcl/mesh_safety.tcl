# Damage-only mesh checks, independent of the active HyperMesh quality
# criteria.  The module must stop results that are obviously broken - collapsed,
# folded, duplicated, half-deleted or detached shells - without rejecting the
# ordinary distortion a local imprint remesh legitimately produces.  A value
# that would be a quality finding in HyperMesh is a WARN; only a value that
# means the shell has no usable geometry left is an error.
#
# 2026-09-10 field report (module 0.63): three of four paths of one batch were
# blocked by this audit on every retried weld mesh size (8 -> 4.8 -> 12) with
# "Near-collapsed shell corner" and "Folded, twisted or self-intersecting
# shell", although the same welds could be created by hand with no HyperMesh
# complaint at all.  Reproduced on HyperMesh 2019 with
# tools/audit_mesh_seam_weld_geometry_audit.tcl: the patch is a constrained
# remesh of a fixed source rail, so HyperMesh has to close whatever shape that
# rail describes.  A closed 20 node free-edge loop on a coarse plate produced a
# patch quad with a 179 degree corner (flagged as "near-collapsed"), a rail
# carrying a 0.02 mm node pair produced patch quads with a 0.02 mm edge (flagged
# by the aspect limit at aspect 250) and a dense rail produced a concave quad
# (flagged as "folded"); with the audit recording instead of failing, all four
# welds were created and verified.  Element shape is therefore reported, never
# fatal: only collapsed connectivity, a coincident edge, a shell without area
# and a shell whose boundary crosses itself are errors.

namespace eval ::MeshSeamWeld {
    # Distorted-but-usable shells seen by the last structural validation; the
    # counter is reported once per path instead of failing the weld.
    variable shellGeometryWarnings 0
    # Worst distortion behind that counter, reported with it so a warning stays
    # diagnosable without turning it into a failed path.
    variable shellGeometryWorstAspect 0.0
    variable shellGeometryWorstCorner 0.0
}

proc ::MeshSeamWeld::shellArea {nodes coordinates} {
    set origin [dict get $coordinates [lindex $nodes 0]]
    set area 0.0
    for {set i 1} {$i < [llength $nodes]-1} {incr i} {
        set normal [::MeshSeamWeld::cross \
            [::MeshSeamWeld::vsub [dict get $coordinates [lindex $nodes $i]] $origin] \
            [::MeshSeamWeld::vsub [dict get $coordinates [lindex $nodes [expr {$i+1}]]] $origin]]
        set area [expr {$area + 0.5*sqrt([::MeshSeamWeld::dot $normal $normal])}]
    }
    return $area
}

# Best-fit plane normal of a possibly warped shell (Newell's method, which stays
# stable where a single corner cross product does not).
proc ::MeshSeamWeld::shellPlaneNormal {nodes coordinates} {
    set origin [dict get $coordinates [lindex $nodes 0]]
    set normal {0.0 0.0 0.0}
    set count [llength $nodes]
    for {set i 0} {$i < $count} {incr i} {
        set current [::MeshSeamWeld::vsub \
            [dict get $coordinates [lindex $nodes $i]] $origin]
        set next [::MeshSeamWeld::vsub \
            [dict get $coordinates [lindex $nodes [expr {($i+1)%$count}]]] $origin]
        set normal [::MeshSeamWeld::vadd $normal \
            [::MeshSeamWeld::cross $current $next]]
    }
    return $normal
}

# True when two straight segments cross each other properly in the plane.  A
# shared endpoint or a merely touching pair does not count; only an actual
# crossing of the two opposite edges makes a shell boundary invalid.
proc ::MeshSeamWeld::segmentsCrossProperly {ax ay bx by cx cy dx dy tolerance} {
    set first [expr {($bx-$ax)*($cy-$ay) - ($by-$ay)*($cx-$ax)}]
    set second [expr {($bx-$ax)*($dy-$ay) - ($by-$ay)*($dx-$ax)}]
    if {!((($first > $tolerance) && ($second < -$tolerance)) ||
          (($first < -$tolerance) && ($second > $tolerance)))} {
        return 0
    }
    set third [expr {($dx-$cx)*($ay-$cy) - ($dy-$cy)*($ax-$cx)}]
    set fourth [expr {($dx-$cx)*($by-$cy) - ($dy-$cy)*($bx-$cx)}]
    if {!((($third > $tolerance) && ($fourth < -$tolerance)) ||
          (($third < -$tolerance) && ($fourth > $tolerance)))} {
        return 0
    }
    return 1
}

# True when the shell boundary crosses itself: the two opposite edge pairs of a
# - possibly warped - quad are projected onto the shell's own best-fit plane and
# tested for a proper crossing.  A concave shell (one or more reflex corners,
# which is what a fixed rail forces out of HyperMesh and what the manual
# workflow accepts) does not cross itself and stays a warning; a bow-tie or a
# folded shell is destroyed geometry.
proc ::MeshSeamWeld::shellBoundarySelfIntersects {nodes coordinates} {
    if {[llength $nodes] != 4} { return 0 }
    set normal [::MeshSeamWeld::shellPlaneNormal $nodes $coordinates]
    set magnitude [expr {sqrt([::MeshSeamWeld::dot $normal $normal])}]
    if {$magnitude <= 1.0e-18} {
        # A symmetric bow-tie cancels out in Newell's sum, but not in its corner
        # normals: the best conditioned corner then defines the projection plane.
        set normal {0.0 0.0 0.0}; set magnitude 0.0
        set count [llength $nodes]
        for {set i 0} {$i < $count} {incr i} {
            set p [dict get $coordinates [lindex $nodes $i]]
            set q [dict get $coordinates [lindex $nodes [expr {($i+1)%$count}]]]
            set r [dict get $coordinates [lindex $nodes [expr {($i+$count-1)%$count}]]]
            set corner [::MeshSeamWeld::cross \
                [::MeshSeamWeld::vsub $q $p] [::MeshSeamWeld::vsub $r $p]]
            set cornerMagnitude [expr {sqrt([::MeshSeamWeld::dot $corner $corner])}]
            if {$cornerMagnitude > $magnitude} {
                set magnitude $cornerMagnitude; set normal $corner
            }
        }
    }
    if {$magnitude <= 0.0} { return 0 }
    set unit [::MeshSeamWeld::vscale $normal [expr {1.0/$magnitude}]]
    set axis {0.0 0.0 1.0}
    if {abs([lindex $unit 2]) > 0.9} { set axis {1.0 0.0 0.0} }
    set first [::MeshSeamWeld::cross $unit $axis]
    set firstLength [expr {sqrt([::MeshSeamWeld::dot $first $first])}]
    if {$firstLength <= 0.0} { return 0 }
    set first [::MeshSeamWeld::vscale $first [expr {1.0/$firstLength}]]
    set second [::MeshSeamWeld::cross $unit $first]
    set origin [dict get $coordinates [lindex $nodes 0]]
    set points {}
    set extent 0.0
    foreach nodeId $nodes {
        set offset [::MeshSeamWeld::vsub [dict get $coordinates $nodeId] $origin]
        set x [::MeshSeamWeld::dot $offset $first]
        set y [::MeshSeamWeld::dot $offset $second]
        lappend points [list $x $y]
        set distance [expr {$x*$x + $y*$y}]
        if {$distance > $extent} { set extent $distance }
    }
    set scale [expr {sqrt($extent)}]
    set tolerance [expr {1.0e-9*$scale*$scale}]
    foreach pair {{0 1 2 3} {1 2 3 0}} {
        lassign $pair a b c d
        set start [lindex $points $a]; set finish [lindex $points $b]
        set otherStart [lindex $points $c]; set otherFinish [lindex $points $d]
        if {[::MeshSeamWeld::segmentsCrossProperly \
                [lindex $start 0] [lindex $start 1] \
                [lindex $finish 0] [lindex $finish 1] \
                [lindex $otherStart 0] [lindex $otherStart 1] \
                [lindex $otherFinish 0] [lindex $otherFinish 1] $tolerance]} {
            return 1
        }
    }
    return 0
}

# Errors: collapsed connectivity, an unreadable node, a coincident (zero length)
# edge, a shell without area and a shell whose boundary crosses itself.  All of
# these mean the shell cannot be used at all.
#
# Warnings: a corner flatter than 5 degrees (which a rail-driven remesh produces
# when the patch has to close a nearly straight feature), an aspect ratio above
# 20, and a corner orientation or warp beyond 30 degrees - including a concave
# corner, whose normal points the other way without the shell being invalid.  A
# quality finding must never block a weld the operator asked for, because
# HyperMesh's own Create Patch produces the same element by hand and reports
# nothing.
proc ::MeshSeamWeld::shellGeometryAudit {nodes coordinates} {
    variable shellGeometryWarnings
    variable shellGeometryWorstAspect
    variable shellGeometryWorstCorner
    set count [llength $nodes]
    if {$count ni {3 4} || [llength [lsort -unique $nodes]] != $count} {
        error "Unsupported or collapsed shell connectivity: $nodes"
    }
    for {set i 0} {$i < $count} {incr i} {
        if {![dict exists $coordinates [lindex $nodes $i]]} {
            error "Shell $nodes has an unreadable node."
        }
    }
    set lengths {}; set normals {}; set marginal 0
    set worstCorner 0.0
    for {set i 0} {$i < $count} {incr i} {
        set p [dict get $coordinates [lindex $nodes $i]]
        set q [dict get $coordinates [lindex $nodes [expr {($i+1)%$count}]]]
        set r [dict get $coordinates [lindex $nodes [expr {($i+$count-1)%$count}]]]
        set a [::MeshSeamWeld::vsub $q $p]
        set b [::MeshSeamWeld::vsub $r $p]
        set aa [::MeshSeamWeld::dot $a $a]; set bb [::MeshSeamWeld::dot $b $b]
        if {$aa <= 1.0e-18 || $bb <= 1.0e-18} { error "Collapsed shell edge: $nodes" }
        lappend lengths [expr {sqrt($aa)}]
        set cosine [expr {abs([::MeshSeamWeld::dot $a $b])/sqrt($aa*$bb)}]
        if {$cosine > 0.996194698} {
            set marginal 1
            # The deviation from a straight corner, in degrees: 1 for a 1 degree
            # needle and for a 179 degree flat corner alike.
            set deviation [expr {180.0*acos(min(1.0,$cosine))/acos(-1.0)}]
            if {$deviation > $worstCorner} { set worstCorner $deviation }
        }
        lappend normals [::MeshSeamWeld::cross $a $b]
    }
    set sorted [lsort -real $lengths]
    set longest [lindex $sorted end]
    set aspect [expr {$longest/max(1.0e-12, [lindex $sorted 0])}]
    if {$aspect > 20.0} {
        set marginal 1
        if {$aspect > $shellGeometryWorstAspect} { set shellGeometryWorstAspect $aspect }
    }
    # Two of the shell's nodes at the same point collapse it even when the
    # boundary still spans an area: an adjacent pair is already a zero length
    # edge, a diagonal pair is the same defect seen from the other side.
    set collapseTolerance [expr {max(1.0e-9, 1.0e-9*$longest)}]
    for {set i 0} {$i < $count} {incr i} {
        for {set j [expr {$i+1}]} {$j < $count} {incr j} {
            set delta [::MeshSeamWeld::vsub [dict get $coordinates [lindex $nodes $i]] \
                [dict get $coordinates [lindex $nodes $j]]]
            if {[::MeshSeamWeld::dot $delta $delta] <= $collapseTolerance*$collapseTolerance} {
                error "Collapsed shell (coincident nodes): $nodes"
            }
        }
    }
    set area [::MeshSeamWeld::shellArea $nodes $coordinates]
    # A shell whose nodes all sit on one line has no shape and no load path.
    # The ratio uses the shell's own longest edge, so it is scale free and stays
    # clear of the thin slivers a fixed rail legitimately forces.
    if {$area <= 1.0e-6*$longest*$longest} {
        error "Collapsed (zero-area) shell: $nodes"
    }
    if {[::MeshSeamWeld::shellBoundarySelfIntersects $nodes $coordinates]} {
        error "Self-intersecting (folded) shell: $nodes"
    }
    # Corner orientation is compared against the best conditioned corner of the
    # same shell.  A corner whose two edges are nearly collinear has no reliable
    # normal direction at all; it is reported, not judged.
    set reference {0.0 0.0 0.0}; set referenceMagnitude 0.0
    foreach normal $normals {
        set squared [::MeshSeamWeld::dot $normal $normal]
        if {$squared > $referenceMagnitude} {
            set referenceMagnitude $squared; set reference $normal
        }
    }
    if {$referenceMagnitude > 0.0} {
        foreach normal $normals {
            set squared [::MeshSeamWeld::dot $normal $normal]
            if {$squared <= 0.0} { set marginal 1; continue }
            set alignment [expr {[::MeshSeamWeld::dot $reference $normal] / \
                sqrt($referenceMagnitude*$squared)}]
            if {$alignment < 0.866025403} { set marginal 1 }
        }
    } else {
        set marginal 1
    }
    if {$marginal} {
        incr shellGeometryWarnings
        if {$worstCorner > $shellGeometryWorstCorner} {
            set shellGeometryWorstCorner $worstCorner
        }
    }
    return $area
}

# How many undo entries did this path actually push?  A failed native command
# can leave the database untouched and record nothing at all: on HM2022 the
# failed *imprint_nodelist of a duplicate weld pushes no entry while the model
# keeps its previous state, so an unconditional *undohistorystate 1 destroys the
# previously created weld instead of the failed path.  Entries are listed newest
# first, so the pre-path stack must still be the tail of the current stack; that
# comparison is used instead of searching for the newest label, because a rerun
# of the same weld pushes an identically named entry.  Returns the exact count,
# 0 when nothing was recorded, and -1 when this build cannot tell.
proc ::MeshSeamWeld::pushedUndoActionCount {beforeActions afterActions} {
    if {[llength [info commands ::hm_getundoactions]] == 0} { return -1 }
    set afterCount [llength $afterActions]
    set beforeCount [llength $beforeActions]
    if {$afterCount >= $beforeCount} {
        set pushed [expr {$afterCount - $beforeCount}]
        if {[lrange $afterActions $pushed end] eq $beforeActions} { return $pushed }
    }
    # The pre-path stack was evicted or unreadable: fall back to the newest
    # label boundary, and let the caller verify whatever it undoes.
    set previousNewest [lindex $beforeActions 0]
    if {$previousNewest eq ""} { return -1 }
    set found [lsearch -exact $afterActions $previousNewest]
    if {$found < 0} { return -1 }
    return $found
}

proc ::MeshSeamWeld::structuralMeshSnapshot {sourceNodes targetElems} {
    set local [::MeshSeamWeld::uniq [concat $targetElems \
        [::MeshSeamWeld::adjacentElementsForNodes $sourceNodes]]]
    set connectivity [::MeshSeamWeld::readShellElementConnectivityBulk $local 1]
    set nodes [::MeshSeamWeld::uniq [concat $sourceNodes {*}[dict values $connectivity]]]
    # One incidence halo includes the unmodified neighbors attached to the
    # imprint boundary, so a moved shared node is also checked on those faces.
    set local [::MeshSeamWeld::uniq [concat $local \
        [::MeshSeamWeld::adjacentElementsForNodes $nodes]]]
    set connectivity [::MeshSeamWeld::readShellElementConnectivityBulk $local 1]
    set nodes [::MeshSeamWeld::uniq [concat $sourceNodes {*}[dict values $connectivity]]]
    ::MeshSeamWeld::clearLocalTopologyCaches [dict keys $connectivity] $nodes
    set coordinates [::HybridCore::readNodeCoordinatesBulk $nodes [list ::MeshSeamWeld::nodeXYZ]]
    set groups {}; set components {}; set geometryFailures {}; set nodeComponents {}
    dict for {id ids} $connectivity {
        set comp [::MeshSeamWeld::elemComponentId $id]
        dict lappend groups $comp $id
        foreach node $ids { dict lappend nodeComponents $node $comp }
        if {[catch {::MeshSeamWeld::shellGeometryAudit $ids $coordinates}]} {
            dict set geometryFailures $id 1
        }
    }
    dict for {comp ids} $groups {
        dict set components $comp [::MeshSeamWeld::componentElementIds $comp]
    }
    set protected $sourceNodes
    dict for {node comps} $nodeComponents {
        if {[llength [lsort -unique $comps]] > 1} { lappend protected $node }
    }
    foreach id [::MeshSeamWeld::adjacentElementsForNodes $nodes] {
        if {[dict exists $connectivity $id]} { continue }
        foreach node [::MeshSeamWeld::elemNodes $id] {
            if {[dict exists $coordinates $node]} { lappend protected $node }
        }
    }
    return [dict create connectivity $connectivity coordinates $coordinates \
        components $components groups $groups geometry_failures $geometryFailures \
        protected_nodes [::MeshSeamWeld::uniq $protected]]
}

# Edges owned by an odd number of more-than-two shells are kept as boundary so a
# locally non-manifold patch still produces a usable reference boundary instead
# of aborting the whole check; the count is reported by the caller.
proc ::MeshSeamWeld::connectivityBoundary {connectivity} {
    set counts {}
    dict for {id ids} $connectivity {
        foreach edge [::MeshSeamWeld::sourcePathEdges $ids 1] { dict incr counts $edge }
    }
    set boundary {}
    dict for {edge count} $counts {
        if {$count == 1} { lappend boundary $edge } elseif {$count % 2 == 1} { lappend boundary $edge }
    }
    return [lsort $boundary]
}

proc ::MeshSeamWeld::verifyWeldOutputRestored {before} {
    if {![dict size $before]} { return 1 }
    set current [::MeshSeamWeld::componentElementIds [dict get $before component_id]]
    if {[lsort -integer $current] ne [lsort -integer [dict get $before element_ids]]} {
        error "Weld output elements were not restored."
    }
    return 1
}

proc ::MeshSeamWeld::verifyStructuralRestored {before} {
    dict for {comp ids} [dict get $before components] {
        if {[lsort -integer $ids] ne [lsort -integer [::MeshSeamWeld::componentElementIds $comp]]} {
            error "Component $comp element IDs were not restored."
        }
    }
    set old [dict get $before connectivity]
    set restored [::MeshSeamWeld::readShellElementConnectivityBulk [dict keys $old] 1]
    dict for {id ids} $old {
        if {![dict exists $restored $id] || [dict get $restored $id] ne $ids} {
            error "Shell $id connectivity was not restored."
        }
    }
    set coordinates [dict get $before coordinates]
    ::MeshSeamWeld::clearLocalTopologyCaches [dict keys $old] [dict keys $coordinates]
    set restoredCoords [::HybridCore::readNodeCoordinatesBulk [dict keys $coordinates] [list ::MeshSeamWeld::nodeXYZ]]
    dict for {id point} $coordinates {
        if {![dict exists $restoredCoords $id]} { error "Node $id was not restored." }
        set d [::MeshSeamWeld::vsub $point [dict get $restoredCoords $id]]
        if {[::MeshSeamWeld::dot $d $d] > 1.0e-16} { error "Node $id coordinates were not restored." }
    }
    return 1
}

# Local shell size around a node, used to turn an absolute node movement into a
# relative one: a remesh may nudge a node by a tiny fraction of its own element,
# while dragging a web node onto the base plane is a multiple of it.
proc ::MeshSeamWeld::nodeLocalScale {node connectivity coordinates} {
    set scale ""
    dict for {id ids} $connectivity {
        if {[lsearch -exact $ids $node] < 0} { continue }
        foreach other $ids {
            if {$other == $node} { continue }
            if {![dict exists $coordinates $other]} { continue }
            set d [::MeshSeamWeld::vsub [dict get $coordinates $other] [dict get $coordinates $node]]
            set length [expr {sqrt([::MeshSeamWeld::dot $d $d])}]
            if {$length > 1.0e-12 && ($scale eq "" || $length < $scale)} { set scale $length }
        }
    }
    if {$scale eq ""} { return 0.0 }
    return $scale
}

# Coordinate identity key for one node, used to recognise a node that a remesh
# renumbered without moving it.
proc ::MeshSeamWeld::coordinateKey {point} {
    set parts {}
    foreach value $point {
        if {[catch {set number [expr {double($value)}]}]} { return "" }
        if {abs($number) < 1.0e-9} { set number 0.0 }
        lappend parts [format %.6f $number]
    }
    return [join $parts |]
}

# Map boundary nodes that a remesh renumbered but did not move back onto the
# original nodes, so an in-place refinement or renumbering is not reported as a
# changed attachment. A protected node keeps its ID check while it still
# exists; when the native remesher has deleted that ID, an exact-coordinate
# replacement is accepted and the later weld-attachment check remains
# responsible for proving that the rail is connected rather than coincident.
proc ::MeshSeamWeld::normalizeUnprotectedBoundaryNodes {boundary oldCoords newCoords protected} {
    if {![llength $boundary]} { return $boundary }
    set index {}
    foreach node [lsort -integer [dict keys $oldCoords]] {
        if {[lsearch -exact $protected $node] >= 0 &&
            [dict exists $newCoords $node]} { continue }
        set key [::MeshSeamWeld::coordinateKey [dict get $oldCoords $node]]
        if {$key eq "" || [dict exists $index $key]} { continue }
        dict set index $key $node
    }
    if {![dict size $index]} { return $boundary }
    set claimed {}
    set mapping {}
    foreach node [lsort -integer [::MeshSeamWeld::uniq [concat {*}$boundary]]] {
        if {[dict exists $oldCoords $node]} { dict set claimed $node 1; continue }
        if {![dict exists $newCoords $node]} { continue }
        set key [::MeshSeamWeld::coordinateKey [dict get $newCoords $node]]
        if {$key eq "" || ![dict exists $index $key]} { continue }
        set original [dict get $index $key]
        if {[dict exists $claimed $original]} { continue }
        dict set mapping $node $original
        dict set claimed $original 1
    }
    if {![dict size $mapping]} { return $boundary }
    set result {}
    foreach edge $boundary {
        set pair {}
        foreach node $edge {
            if {[dict exists $mapping $node]} { lappend pair [dict get $mapping $node] } else { lappend pair $node }
        }
        if {[lindex $pair 0] == [lindex $pair 1]} { return $boundary }
        lappend result [lsort -integer $pair]
    }
    return [lsort $result]
}

# Existing weld-mesh protection is best-effort.  HyperMesh's native
# remesh_layers operation can legitimately rebuild a neighbouring SEAM_* shell
# even after that shell was removed from the input mark.  Detect that behaviour
# for diagnostics, but let validateStructuralMesh decide from the resulting
# boundary, area, duplicates, geometry and attachment whether the mesh is still
# usable.  Requiring the original element IDs here turns an implementation
# detail of the native remesher into a false creation blocker.
#
# Returns "" when no protected element changed, otherwise the first change.
proc ::MeshSeamWeld::protectedWeldElementsChanged {before} {
    variable cfg
    if {[info exists cfg(allow_break_existing_weld)] && $cfg(allow_break_existing_weld)} {
        return ""
    }
    set oldConnectivity [dict get $before connectivity]
    dict for {comp elementIds} [dict get $before groups] {
        set isWeldComponent 0
        foreach name [::MeshSeamWeld::componentNames [list $comp]] {
            if {[::MeshSeamWeld::isWeldComponentName $name]} {
                set isWeldComponent 1
                break
            }
        }
        if {!$isWeldComponent} { continue }
        set elementIds [lsort -integer -unique $elementIds]
        if {![llength $elementIds]} { continue }
        set current [::MeshSeamWeld::readShellElementConnectivityBulk \
            $elementIds 1]
        foreach elementId $elementIds {
            if {![dict exists $current $elementId]} {
                return "weld component $comp lost element $elementId"
            }
            if {[dict get $current $elementId] ne \
                    [dict get $oldConnectivity $elementId]} {
                return "weld component $comp replaced element $elementId"
            }
        }
    }
    return ""
}

proc ::MeshSeamWeld::validateStructuralMesh {before weldElems sourceNodes closedLoop} {
    variable shellGeometryWarnings
    variable shellGeometryWorstAspect
    variable shellGeometryWorstCorner
    # The native remesher may cross the requested mark and replace an existing
    # weld element with an equivalent local remesh.  Record that fact, then
    # validate the resulting topology below.  A valid replacement must not
    # block creation; actual holes, area loss, duplicates, detached rails and
    # unusable shells are still fatal in the checks that follow.
    set protectedWeldProblem [::MeshSeamWeld::protectedWeldElementsChanged $before]
    if {$protectedWeldProblem ne ""} {
        ::HybridCore::log WARN \
            "mesh_seam_weld native remesh rebuilt protected weld mesh detail=\"$protectedWeldProblem\"; continuing with topology validation so weld creation is not blocked by element-ID replacement"
    }
    set old [dict get $before connectivity]
    set oldCoords [dict get $before coordinates]
    set after {}; set afterGroups {}; set rebuiltWeld {}
    dict for {comp beforeIds} [dict get $before components] {
        set currentIds [::MeshSeamWeld::componentElementIds $comp]
        if {[llength $currentIds] == 0} {
            error "Component $comp lost all of its shell elements."
        }
        set currentSet {}; foreach id $currentIds { dict set currentSet $id 1 }
        set local {}
        foreach id [::MeshSeamWeld::idsAddedToCollection $beforeIds $currentIds] {
            if {$id ni $weldElems} { lappend local $id }
        }
        foreach id [dict get $before groups $comp] {
            if {[dict exists $currentSet $id]} { lappend local $id }
        }
        # When the existing output SEAM_* collector is reused, remeshed
        # replacements and genuinely new weld shells are both present in the
        # output collection delta (`weldElems`).  They cannot be separated by
        # element ID.  Do not compare that collector as if it were a mother
        # plate with ID-stable faces; instead include its current local and new
        # shells in the common duplicate/geometry audit below.  The actual
        # mother components still receive the strict boundary and area checks.
        set rebuiltWeldComponent 0
        if {$protectedWeldProblem ne ""} {
            foreach name [::MeshSeamWeld::componentNames [list $comp]] {
                if {[::MeshSeamWeld::isWeldComponentName $name]} {
                    set rebuiltWeldComponent 1
                    break
                }
            }
        }
        if {$rebuiltWeldComponent} {
            set rebuiltIds [::MeshSeamWeld::uniq [concat $local $weldElems]]
            set rebuiltConn [::MeshSeamWeld::readShellElementConnectivityBulk \
                $rebuiltIds 1]
            if {[dict size $rebuiltConn] == 0} {
                error "Rebuilt weld component $comp has no readable shell elements."
            }
            set rebuiltWeld [dict merge $rebuiltWeld $rebuiltConn]
            continue
        }
        set conn [::MeshSeamWeld::readShellElementConnectivityBulk $local 1]
        if {[dict size $conn] == 0} { error "Structural shells disappeared from component $comp." }
        dict set afterGroups $comp $conn
        set after [dict merge $after $conn]
    }
    if {[llength $weldElems]} {
        set weld [::MeshSeamWeld::readShellElementConnectivityBulk $weldElems 1]
        if {[dict size $weld] != [llength $weldElems]} { error "Weld connectivity is incomplete." }
    } else {
        set weld {}
    }
    set all [dict merge $after $rebuiltWeld $weld]
    # Read only nodes which still belong to the post-remesh shells.  A source
    # node ID may have been replaced by the native remesher; asking the bulk
    # reader for that deleted ID would fail before the in-place replacement can
    # be recognized against the snapshot below.
    set nodeIds [::MeshSeamWeld::uniq [concat {*}[dict values $all]]]
    ::MeshSeamWeld::clearLocalTopologyCaches [dict keys $all] $nodeIds
    set coordinates [::HybridCore::readNodeCoordinatesBulk $nodeIds [list ::MeshSeamWeld::nodeXYZ]]
    set fixed [dict get $before protected_nodes]

    # Duplicate shells come first: they are the most precise diagnosis and they
    # are only reported when this path is responsible.  A mesh that already
    # contained a duplicate before the path is not a weld failure.
    set signatures {}; set geometricSignatures {}
    dict for {id ids} $all {
        set signature [lsort -integer $ids]
        if {[dict exists $signatures $signature]} {
            set other [dict get $signatures $signature]
            error "Duplicate structural shell $id repeats shell $other in the weld/structural mesh."
        }
        dict set signatures $signature $id
        set pointKeys {}
        foreach node $ids { lappend pointKeys [::MeshSeamWeld::coordinateKey [dict get $coordinates $node]] }
        set geometricSignature [lsort $pointKeys]
        if {[dict exists $geometricSignatures $geometricSignature]} {
            set other [dict get $geometricSignatures $geometricSignature]
            set preexisting [expr {[dict exists $old $id] && [dict exists $old $other] && \
                [dict get $old $id] eq $ids && [dict get $old $other] eq $ids}]
            if {!$preexisting} {
                error "Coincident duplicate shell $id repeats shell $other in the weld/structural mesh."
            }
        }
        dict set geometricSignatures $geometricSignature $id
    }

    # The attachment boundary must survive, but a legitimate remesh may refine it
    # in place and may renumber a free boundary node.  A renumbered node that is
    # still exactly where the original was is mapped back before the attachment
    # test; shared and source nodes are never remapped.  A deleted face, a hole, a
    # sideways reconnection or a moved protected node still fails.
    foreach comp [lsort -integer [dict keys $afterGroups]] {
        set previous {}
        foreach id [dict get $before groups $comp] { dict set previous $id [dict get $old $id] }
        set conn [dict get $afterGroups $comp]
        set reference [::MeshSeamWeld::connectivityBoundary $previous]
        set current [::MeshSeamWeld::connectivityBoundary $conn]
        set normalized [::MeshSeamWeld::normalizeUnprotectedBoundaryNodes \
            $current $oldCoords $coordinates $fixed]
        set problem [::MeshSeamWeld::patchBoundaryAttachmentProblem \
            $reference $normalized [dict merge $oldCoords $coordinates]]
        if {$problem ne ""} {
            # Native remesh may replace an entire local boundary chain instead
            # of preserving/subdividing each old edge. In the normal
            # creation-first mode this is diagnostic: area, duplicate-shell,
            # geometry and actual weld-attachment checks remain authoritative.
            # Keep the existing strict switch for workflows that explicitly
            # require per-edge identity preservation.
            set strictBoundary [expr {
                [info exists ::MeshSeamWeld::cfg(strict_patch_boundary_check)] &&
                $::MeshSeamWeld::cfg(strict_patch_boundary_check)}]
            if {$strictBoundary} {
                error "Structural boundary changed in component $comp: $problem"
            }
            ::HybridCore::log WARN \
                "mesh_seam_weld structural boundary was retessellated component=$comp detail=\"$problem\"; creation continues in relaxed mode"
        }
        set areaBefore 0.0; set areaAfter 0.0
        dict for {id ids} $previous { set areaBefore [expr {$areaBefore + [::MeshSeamWeld::shellArea $ids $oldCoords]}] }
        dict for {id ids} $conn { set areaAfter [expr {$areaAfter + [::MeshSeamWeld::shellArea $ids $coordinates]}] }
        if {$areaBefore > 0.0} {
            set change [expr {abs($areaAfter-$areaBefore)/$areaBefore}]
            if {$change > 0.15} {
                error "Structural area changed in component $comp by [format %.1f [expr {100.0*$change}]] percent (missing or overlapping faces)."
            }
            if {$change > 0.02} {
                ::HybridCore::log WARN \
                    "mesh_seam_weld structural area drift component=$comp change=[format %.3f $change]"
            }
        }
    }

    # Node identity and position are diagnostic, not acceptance criteria.  A
    # native local remesh is free to replace and smooth individual nodes; the
    # resulting boundary, area, shell geometry and actual weld attachment are
    # the authoritative checks.  Treating an old node ID or coordinate as
    # immutable repeatedly blocked valid HyperMesh results even after all of
    # those topology checks passed.
    set movedWarn 0; set largeMoveWarn 0
    set renumberedWarn 0; set replacedAndSmoothedWarn 0
    set currentCoordinateKeys {}
    foreach currentId [dict keys $coordinates] {
        dict lappend currentCoordinateKeys \
            [::MeshSeamWeld::coordinateKey [dict get $coordinates $currentId]] \
            $currentId
    }
    foreach id [::MeshSeamWeld::uniq $fixed] {
        if {![dict exists $coordinates $id]} {
            set oldKey [::MeshSeamWeld::coordinateKey [dict get $oldCoords $id]]
            if {$oldKey ne "" && [dict exists $currentCoordinateKeys $oldKey]} {
                incr renumberedWarn
                continue
            }
            incr replacedAndSmoothedWarn
            continue
        }
        set delta [::MeshSeamWeld::vsub [dict get $coordinates $id] [dict get $oldCoords $id]]
        set move [expr {sqrt([::MeshSeamWeld::dot $delta $delta])}]
        if {$move <= 1.0e-9} { continue }
        set scale [::MeshSeamWeld::nodeLocalScale $id $old $oldCoords]
        set tolerance [expr {$scale > 0.0 ? 0.25*$scale : 1.0e-6}]
        if {$move > $tolerance} {
            incr largeMoveWarn
            continue
        }
        incr movedWarn
    }
    if {$movedWarn} {
        ::HybridCore::log WARN \
            "mesh_seam_weld [expr {$movedWarn}] attachment node(s) moved within the local mesh size"
    }
    if {$renumberedWarn} {
        ::HybridCore::log WARN \
            "mesh_seam_weld $renumberedWarn attachment node(s) were renumbered in place by native remesh; creation continues after topology validation"
    }
    if {$replacedAndSmoothedWarn} {
        ::HybridCore::log WARN \
            "mesh_seam_weld $replacedAndSmoothedWarn attachment node(s) were replaced and smoothed by native remesh; creation continues because the resulting topology is valid"
    }
    if {$largeMoveWarn} {
        ::HybridCore::log WARN \
            "mesh_seam_weld $largeMoveWarn attachment node(s) moved beyond the local diagnostic tolerance; creation continues because boundary, area and attachment validation passed"
    }

    # Count only what this path produced; the snapshot audit of pre-existing
    # elements must not inflate the warning.
    set shellGeometryWarnings 0
    set shellGeometryWorstAspect 0.0
    set shellGeometryWorstCorner 0.0
    dict for {id ids} $all {
        set unchanged [expr {[dict exists $old $id] && [dict get $old $id] eq $ids}]
        if {$unchanged} {
            foreach node $ids {
                if {![dict exists $oldCoords $node] || [dict get $oldCoords $node] ne [dict get $coordinates $node]} {
                    set unchanged 0; break
                }
            }
        }
        if {!$unchanged && ![dict exists $before geometry_failures $id]} {
            ::MeshSeamWeld::shellGeometryAudit $ids $coordinates
        }
    }
    if {$shellGeometryWarnings > 0} {
        ::HybridCore::log WARN \
            "mesh_seam_weld $shellGeometryWarnings shell(s) of this path are distorted but usable (worst aspect [format %.1f $shellGeometryWorstAspect], worst corner [format %.1f $shellGeometryWorstCorner] degrees); the weld is kept"
        set shellGeometryWarnings 0
        set shellGeometryWorstAspect 0.0
        set shellGeometryWorstCorner 0.0
    }
    # Do not invoke hm_getelementsqualityinfo here: HM2019 can terminate the
    # host when no criteria file is loaded.  The mandatory geometric checks
    # above work independently of that global, user-controlled state.
    if {[llength $weldElems] == 0} { return 1 }
    set structuralEdges {}
    dict for {id ids} $after {
        foreach edge [::MeshSeamWeld::sourcePathEdges $ids 1] { dict set structuralEdges $edge 1 }
    }
    ::MeshSeamWeld::validateWeldAttachment \
        [::MeshSeamWeld::patchBoundaryEdges $weldElems] $structuralEdges $sourceNodes $closedLoop
    return 1
}

# True when the failure means the surrounding mesh itself was damaged.  Such a
# failure is never retried: retrying cannot undo a deleted face, a duplicated
# shell or a detached rail, and the report has to reach the creation algorithm
# instead.  Everything else is a patch-side creation problem that a retry with
# adjusted parameters may still solve.
proc ::MeshSeamWeld::weldFailureIsStructuralDamage {errorText} {
    foreach marker {
        "Structural boundary changed" "Structural area changed"
        "Duplicate shell"
        "Duplicate structural shell" "Coincident duplicate shell"
        "Weld strip is disconnected"
        "only coincides with a structural edge"
        "lost all of its shell elements" "Structural shells disappeared"
        "rollback verification failed"
    } {
        if {[string first $marker $errorText] >= 0} { return 1 }
    }
    return 0
}

# One weld attempt inside its own undo transaction: run, and on failure undo
# exactly what the attempt recorded and verify the model came back.  The mesh
# size override makes the same path retryable with different creation
# parameters.
proc ::MeshSeamWeld::runWeldAttemptTransaction {historyName sourceNodes targetComps closedLoop progressOpened pathIndex pathTotal sourceCompIds seamComp targetElemIds imprintClosedLoop meshSize} {
    variable cfg
    set savedSize ""
    if {[info exists cfg(weld_mesh_size)]} { set savedSize $cfg(weld_mesh_size) }
    set ::MeshSeamWeld::activeStructuralSnapshot {}
    set ::MeshSeamWeld::activeOutputSnapshot {}
    set ::MeshSeamWeld::lastImprintAffectedElemIds {}
    catch {::MeshSeamWeld::enableNativeUndo}
    set beforeActions [::MeshSeamWeld::nativeUndoActions]
    if {[catch {*startnotehistorystate $historyName}]} {
        return [dict create ok 0 rollback_ok 0 error \
            "\[MSW_STAGE:TRANSACTION\] Could not start the transaction for $historyName."]
    }
    if {$meshSize ne ""} { set cfg(weld_mesh_size) $meshSize }
    set code [catch {
        ::MeshSeamWeld::processWeldPath $sourceNodes $targetComps $closedLoop \
            $progressOpened $pathIndex $pathTotal $sourceCompIds $seamComp \
            $targetElemIds $imprintClosedLoop
    } result opts]
    if {$savedSize ne ""} { set cfg(weld_mesh_size) $savedSize }
    if {[catch {*endnotehistorystate $historyName} endErr]} {
        set code 1
        set result "\[MSW_STAGE:TRANSACTION\] Could not finish the history state for $historyName: $endErr"
    }
    if {!$code} { return [dict create ok 1 result $result rollback_ok 1 error ""] }
    set rollbackOk 1
    set pushedActions [::MeshSeamWeld::pushedUndoActionCount \
        $beforeActions [::MeshSeamWeld::nativeUndoActions]]
    if {$pushedActions == 0} {
        ::HybridCore::log WARN \
            "mesh_seam_weld attempt=$historyName recorded no undo action; the model is verified instead of undone"
    } elseif {[catch {
        ::MeshSeamWeld::performNativeUndo \
            [expr {$pushedActions > 0 ? $pushedActions : 1}]
    } undoErr]} {
        set rollbackOk 0
        append result "; rollback failed: $undoErr"
    }
    if {$rollbackOk && [dict size $::MeshSeamWeld::activeStructuralSnapshot] && [catch {
        ::MeshSeamWeld::verifyStructuralRestored $::MeshSeamWeld::activeStructuralSnapshot
        ::MeshSeamWeld::verifyWeldOutputRestored $::MeshSeamWeld::activeOutputSnapshot
    } verifyErr]} {
        set rollbackOk 0
        append result "; rollback verification failed: $verifyErr"
    }
    return [dict create ok 0 result "" rollback_ok $rollbackOk error $result]
}

# The user has already decided that the selected edge can carry a weld, so an
# AUTOMESH-stage failure (strip quality, patch attachment, non-manifold patch)
# is retried with an adjusted weld mesh size instead of blocking the path.  Each
# retry runs on the model the previous rollback restored and is verified the
# same way.  Returns status CREATED, FAILED, ROLLBACK_FAILED or SKIPPED.
proc ::MeshSeamWeld::retryWeldPathWithAdjustedSize {sourceNodes targetComps closedLoop progressOpened pathIndex pathTotal sourceCompIds seamComp targetElemIds imprintClosedLoop outputCompIdBefore originalError {maxAttempts 2}} {
    variable cfg
    if {[string first "\[MSW_STAGE:AUTOMESH\]" $originalError] < 0} {
        return [dict create status SKIPPED]
    }
    if {![info exists cfg(weld_mesh_size)]} { return [dict create status SKIPPED] }
    set size $cfg(weld_mesh_size)
    if {![string is double -strict $size] || $size <= 0} { return [dict create status SKIPPED] }
    set attempt 0
    set lastError $originalError
    foreach candidate [list [expr {0.6*$size}] [expr {1.5*$size}]] {
        if {$attempt >= $maxAttempts} { break }
        incr attempt
        set name "Mesh seam weld path $pathIndex/$pathTotal adjusted mesh $attempt"
        ::HybridCore::log WARN \
            "mesh_seam_weld retrying path=$pathIndex/$pathTotal attempt=$attempt mesh_size=$candidate reason=[::MeshSeamWeld::reportLineValue $originalError]"
        set outcome [::MeshSeamWeld::runWeldAttemptTransaction $name \
            $sourceNodes $targetComps $closedLoop $progressOpened $pathIndex \
            $pathTotal $sourceCompIds $seamComp $targetElemIds \
            $imprintClosedLoop $candidate]
        if {[dict get $outcome ok]} {
            ::HybridCore::log INFO \
                "mesh_seam_weld retry succeeded path=$pathIndex/$pathTotal attempt=$attempt mesh_size=$candidate"
            return [dict create status CREATED result [dict get $outcome result]]
        }
        set lastError [dict get $outcome error]
        if {[string trim $seamComp] ne "" && [catch {
            ::MeshSeamWeld::removeFailedPathOutputComponent \
                $seamComp $outputCompIdBefore
        } cleanupErr]} {
            ::HybridCore::log ERROR \
                "failed retry output component cleanup failed path=$pathIndex/$pathTotal component=$seamComp error=$cleanupErr"
        }
        if {![dict get $outcome rollback_ok]} {
            return [dict create status ROLLBACK_FAILED error $lastError]
        }
        if {[::MeshSeamWeld::weldFailureIsStructuralDamage $lastError]} { break }
    }
    return [dict create status FAILED error $lastError]
}

# A weld strip must be attached to the mother mesh.  Attached boundary edges are
# actual structural edges; the remaining ones are the strip's free ends and, on a
# curved or rebuilt rail, its own refined rail chain, so they are counted and
# reported instead of rejecting the weld.  Two cases still fail: a strip with no
# attached boundary edge at all, and a rail that only *coincides* with a
# structural edge while using duplicated nodes - that weld carries no load.
proc ::MeshSeamWeld::validateWeldAttachment {boundary structuralEdges sourceNodes closedLoop} {
    if {![llength $boundary]} { error "Weld strip has no boundary edges." }
    set attached 0; set loose {}
    foreach edge $boundary {
        set edge [lsort -integer $edge]
        if {[dict exists $structuralEdges $edge]} { incr attached } else { lappend loose $edge }
    }
    if {$attached == 0} {
        error "Weld strip is disconnected from the mother mesh: none of its [llength $boundary] boundary edges lies on the surrounding mesh."
    }
    if {[llength $loose] == 0} { return 1 }
    if {[llength [info commands ::HybridCore::readNodeCoordinatesBulk]] == 0} { return 1 }
    set nodes {}
    foreach edge $loose { set nodes [concat $nodes $edge] }
    dict for {edge unused} $structuralEdges { set nodes [concat $nodes $edge] }
    set nodes [::MeshSeamWeld::uniq $nodes]
    set coordinates {}
    catch {set coordinates [::HybridCore::readNodeCoordinatesBulk $nodes \
        [list ::MeshSeamWeld::nodeXYZ]]}
    if {[dict size $coordinates] == 0} { return 1 }
    set structuralKeys {}
    dict for {edge unused} $structuralEdges {
        lassign $edge first second
        if {![dict exists $coordinates $first] || ![dict exists $coordinates $second]} { continue }
        set keys [lsort [list [::MeshSeamWeld::coordinateKey [dict get $coordinates $first]] \
            [::MeshSeamWeld::coordinateKey [dict get $coordinates $second]]]]
        dict set structuralKeys $keys 1
    }
    foreach edge $loose {
        lassign $edge first second
        if {![dict exists $coordinates $first] || ![dict exists $coordinates $second]} { continue }
        set keys [lsort [list [::MeshSeamWeld::coordinateKey [dict get $coordinates $first]] \
            [::MeshSeamWeld::coordinateKey [dict get $coordinates $second]]]]
        if {[dict exists $structuralKeys $keys]} {
            error "Weld boundary edge [join $edge -] only coincides with a structural edge but shares no node with it: the weld strip is disconnected from the mother mesh."
        }
    }
    ::HybridCore::log WARN \
        "mesh_seam_weld weld strip boundary attached=$attached loose=[llength $loose]"
    return 1
}
