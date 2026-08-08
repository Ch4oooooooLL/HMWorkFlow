# Pure-Tcl seam auto detection for the solid seam module.
#
# Replaces the Python detection pipeline in the main flow: the user picks two
# components, this file finds the junction node chain between them, classifies
# the joint (T / LAP / BUTT / ANGLED), and derives realization parameters
# (mesh size, thickness, width/spacing default 6, adaptive tolerance).
#
# Only HyperMesh mark slots 1/2/3 are used (both 2019 and 2022 accept only
# those).  All geometry queries use hm_getvalue on nodes/elems.

namespace eval ::SolidSeam {}

# ---------------------------------------------------------------------------
# Node helpers
# ---------------------------------------------------------------------------
proc ::SolidSeam::componentNodeIds {componentId} {
    catch {*clearmark nodes 1}
    *createmark nodes 1 "by comp id" $componentId
    return [hm_getmark nodes 1]
}

proc ::SolidSeam::nodeXYZ {nodeId} {
    set x [hm_getvalue nodes id=$nodeId dataname=x]
    set y [hm_getvalue nodes id=$nodeId dataname=y]
    set z [hm_getvalue nodes id=$nodeId dataname=z]
    return [list $x $y $z]
}

proc ::SolidSeam::nodeDistance {p q} {
    set dx [expr {[lindex $p 0] - [lindex $q 0]}]
    set dy [expr {[lindex $p 1] - [lindex $q 1]}]
    set dz [expr {[lindex $p 2] - [lindex $q 2]}]
    return [expr {sqrt($dx * $dx + $dy * $dy + $dz * $dz)}]
}

# Median of a numeric list (ties rounded down like the Python version).
proc ::SolidSeam::median {values} {
    if {[llength $values] == 0} { return 0.0 }
    set sorted [lsort -real $values]
    set mid [expr {[llength $sorted] / 2}]
    return [lindex $sorted $mid]
}

proc ::SolidSeam::clamp {value lower upper} {
    return [expr {$value < $lower ? $lower : ($value > $upper ? $upper : $value)}]
}

# ---------------------------------------------------------------------------
# Element topology helpers
# ---------------------------------------------------------------------------
proc ::SolidSeam::componentElementIds {componentId} {
    catch {*clearmark elems 1}
    *createmark elems 1 "by comp id" $componentId
    return [hm_getmark elems 1]
}

proc ::SolidSeam::elementConfig {elementId} {
    set config {}
    catch {set config [hm_getvalue elems id=$elementId dataname=config]}
    return [string trim $config]
}

proc ::SolidSeam::elementNodes {elementId} {
    set nodes {}
    for {set i 1} {$i <= 20} {incr i} {
        set rc [catch {set n [hm_getvalue elems id=$elementId dataname=node$i]}]
        set n [string trim $n]
        if {$rc || $n eq "" || $n eq "0"} { break }
        lappend nodes $n
    }
    return $nodes
}

# Is the component made of solid (3D) elements?  Config ids: 105 tetra4,
# 106 hex8, 107 penta6, 108 pyramid5, 205 tetra10, 206 penta15, 207 hex20,
# 208 hex8 (Nastran template numbering).
proc ::SolidSeam::componentIsSolid {componentId} {
    foreach elementId [::SolidSeam::componentElementIds $componentId] {
        if {[::SolidSeam::elementConfig $elementId] in {105 106 107 108 205 206 207 208}} {
            return 1
        }
    }
    return 0
}

# Face node sets of an element: shells contribute their single face, solids
# contribute each boundary face (hex8: 6 quads, penta6: 2 tri + 3 quad,
# tetra4: 4 tri, pyramid5: 1 quad + 4 tri).  Order follows the element
# node numbering so faces are canonical (sorted key) and counted.
proc ::SolidSeam::elementFaces {elementId} {
    set nodes [::SolidSeam::elementNodes $elementId]
    set config [::SolidSeam::elementConfig $elementId]
    set faces {}
    switch -- $config {
        103 - 104 { ;# tri3 / quad4 shell: single face from the node ring
            lappend faces $nodes
        }
        108 { ;# pyramid5: base quad nodes 1-4 + 4 tri side faces (apex node 5)
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 3]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 2] [lindex $nodes 3] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 3] [lindex $nodes 0] [lindex $nodes 4]]
        }
        105 { ;# tetra4: 4 triangular faces
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 2]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 3]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 2] [lindex $nodes 3]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 3]]
        }
        106 - 208 { ;# hex8: 6 quad faces (208 = Nastran hex8 numbering)
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 3]]
            lappend faces [list [lindex $nodes 4] [lindex $nodes 5] [lindex $nodes 6] [lindex $nodes 7]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 5] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 6] [lindex $nodes 5]]
            lappend faces [list [lindex $nodes 2] [lindex $nodes 3] [lindex $nodes 7] [lindex $nodes 6]]
            lappend faces [list [lindex $nodes 3] [lindex $nodes 0] [lindex $nodes 4] [lindex $nodes 7]]
        }
        107 { ;# penta6: 2 tri + 3 quad
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 2]]
            lappend faces [list [lindex $nodes 3] [lindex $nodes 4] [lindex $nodes 5]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 4] [lindex $nodes 3]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 5] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 2] [lindex $nodes 0] [lindex $nodes 3] [lindex $nodes 5]]
        }
        default {
            ;# unsupported config: fall back to the node list as a single face
            lappend faces $nodes
        }
    }
    return $faces
}

# Face key: sorted node ids joined by a separator (order independent).
proc ::SolidSeam::faceKey {face} {
    return [join [lsort -integer $face] {,}]
}

# Boundary (free edge) node ids of a component.
# - shells: nodes on edges used by exactly one element (free edges)
# - solids: nodes on the edges of the outer surface that are not shared with
#   a second element.  An edge of a solid element belongs to two of its own
#   faces, so free edges of the body are counted exactly twice while interior
#   edges are counted by two elements (four face incidences).
proc ::SolidSeam::boundaryNodesOfComponent {componentId} {
    set elementIds [::SolidSeam::componentElementIds $componentId]
    set solid [::SolidSeam::componentIsSolid $componentId]
    array set edgeCount {}
    foreach elementId $elementIds {
        set nodes [::SolidSeam::elementNodes $elementId]
        if {$solid} {
            # count face edges of the solid surface
            foreach face [::SolidSeam::elementFaces $elementId] {
                set n [llength $face]
                for {set i 0} {$i < $n} {incr i} {
                    set a [lindex $face $i]
                    set b [lindex $face [expr {($i + 1) % $n}]]
                    set key [expr {$a < $b ? "$a,$b" : "$b,$a"}]
                    incr edgeCount($key)
                }
            }
        } else {
            # shell: edges from the ordered node ring
            set n [llength $nodes]
            for {set i 0} {$i < $n} {incr i} {
                set a [lindex $nodes $i]
                set b [lindex $nodes [expr {($i + 1) % $n}]]
                set key [expr {$a < $b ? "$a,$b" : "$b,$a"}]
                incr edgeCount($key)
            }
        }
    }
    set boundary {}
    set limit [expr {$solid ? 2 : 1}]
    foreach key [array names edgeCount] {
        if {$edgeCount($key) == $limit} {
            foreach nodeId [split $key ,] { lappend boundary $nodeId }
        }
    }
    return [lsort -integer -unique $boundary]
}

# For a solid component: the face(s) of the outer surface that face the
# target component (minimum face-centroid to target-node distance).  Returns
# the node ids of the outline of the facing region: all outer faces whose
# centroid is within a small multiple of the closest gap are collected, and
# their shared outline (edges used by exactly one of these faces) forms the
# weld boundary.
proc ::SolidSeam::solidFacingBoundaryNodes {componentId targetComponentId} {
    set targetNodes [::SolidSeam::componentNodeIds $targetComponentId]
    array set targetXYZ {}
    foreach nodeId $targetNodes {
        set targetXYZ($nodeId) [::SolidSeam::nodeXYZ $nodeId]
    }
    set elementIds [::SolidSeam::componentElementIds $componentId]
    # count face usage to find the outer surface (used exactly once).  Keep
    # the first ring order seen for each face key: the outline and edge
    # lengths below use the real element edges, while the sorted key alone
    # would turn quad diagonals into pseudo edges and leak interior rows
    # into the outline.
    array set faceCount {}
    array set faceRing {}
    array set faceOwner {}
    foreach elementId $elementIds {
        foreach face [::SolidSeam::elementFaces $elementId] {
            set key [::SolidSeam::faceKey $face]
            incr faceCount($key)
            if {![info exists faceRing($key)]} {
                set faceRing($key) $face
                set faceOwner($key) $elementId
            }
        }
    }
    set outerFaces {}
    foreach key [array names faceCount] {
        if {$faceCount($key) == 1} { lappend outerFaces $faceRing($key) }
    }
    if {[llength $outerFaces] == 0} { return {} }
    # element centroids: the outward direction of a face is face-centroid
    # minus its owning element centroid (the ring winding is not reliably
    # outward across element types/configs)
    array set elementCentroid {}
    foreach elementId $elementIds {
        set sx 0.0; set sy 0.0; set sz 0.0
        set n 0
        foreach nodeId [::SolidSeam::elementNodes $elementId] {
            set p [::SolidSeam::nodeXYZ $nodeId]
            set sx [expr {$sx + [lindex $p 0]}]
            set sy [expr {$sy + [lindex $p 1]}]
            set sz [expr {$sz + [lindex $p 2]}]
            incr n
        }
        if {$n > 0} { set elementCentroid($elementId) [list [expr {$sx / $n}] [expr {$sy / $n}] [expr {$sz / $n}]] }
    }
    # mesh pitch from the outer face edges (median edge length); the
    # facing-layer bands below are scaled with it so a curved contact face
    # (whose gap to the target varies along the arc) keeps its whole outline
    # while side faces stay excluded
    set edgeLengths {}
    foreach face $outerFaces {
        set n [llength $face]
        for {set i 0} {$i < $n} {incr i} {
            set a [lindex $face $i]
            set b [lindex $face [expr {($i + 1) % $n}]]
            set d [::SolidSeam::nodeDistance [::SolidSeam::nodeXYZ $a] [::SolidSeam::nodeXYZ $b]]
            if {$d > 1.0e-8} { lappend edgeLengths $d }
        }
    }
    set pitch [::SolidSeam::median $edgeLengths]
    if {$pitch <= 0.0} { set pitch 10.0 }
    # For every outer face: its centroid distance to the nearest target node,
    # the unit direction from the face centroid to that node (the face's own
    # view of the target), and the outward unit normal of the face.  The
    # direction is per-face, not global: a side face's nearest target node
    # lies in the contact plane, so the direction to it is nearly
    # perpendicular to the side normal and the facing test below excludes
    # the side face no matter how the source/target centroids are offset
    # from each other.
    set faceDistances {}
    foreach face $outerFaces {
        set cx 0.0; set cy 0.0; set cz 0.0
        foreach nodeId $face {
            set p [::SolidSeam::nodeXYZ $nodeId]
            set cx [expr {$cx + [lindex $p 0]}]
            set cy [expr {$cy + [lindex $p 1]}]
            set cz [expr {$cz + [lindex $p 2]}]
        }
        set n [llength $face]
        set centroid [list [expr {$cx / $n}] [expr {$cy / $n}] [expr {$cz / $n}]]
        set nearest 1.0e12
        set tx 0.0; set ty 0.0; set tz 0.0
        foreach targetNode $targetNodes {
            set p $targetXYZ($targetNode)
            set d [::SolidSeam::nodeDistance $centroid $p]
            if {$d < $nearest} {
                set nearest $d
                set tx [lindex $p 0]; set ty [lindex $p 1]; set tz [lindex $p 2]
            }
        }
        set dx [expr {$tx - [lindex $centroid 0]}]
        set dy [expr {$ty - [lindex $centroid 1]}]
        set dz [expr {$tz - [lindex $centroid 2]}]
        set dlen [expr {sqrt($dx * $dx + $dy * $dy + $dz * $dz)}]
        if {$dlen > 1.0e-12} {
            set dx [expr {$dx / $dlen}]; set dy [expr {$dy / $dlen}]; set dz [expr {$dz / $dlen}]
        } else {
            set dx 0.0; set dy 0.0; set dz 0.0
        }
        set owner [expr {$faceOwner([::SolidSeam::faceKey $face])}]
        set ec $elementCentroid($owner)
        set ox [expr {[lindex $centroid 0] - [lindex $ec 0]}]
        set oy [expr {[lindex $centroid 1] - [lindex $ec 1]}]
        set oz [expr {[lindex $centroid 2] - [lindex $ec 2]}]
        set olen [expr {sqrt($ox * $ox + $oy * $oy + $oz * $oz)}]
        if {$olen > 1.0e-12} {
            set ox [expr {$ox / $olen}]; set oy [expr {$oy / $olen}]; set oz [expr {$oz / $olen}]
        } else {
            set ox 0.0; set oy 0.0; set oz 0.0
        }
        lappend faceDistances [list $nearest $face $dx $dy $dz $ox $oy $oz]
    }
    set sortedFaces [lsort -real -index 0 $faceDistances]
    set minDistance [lindex [lindex $sortedFaces 0] 0]
    # Only the closest outer surface layer faces the target (the user's
    # manual node list follows the single contact face).  A band of half a
    # mesh pitch would also pull in side faces whose corners come close to
    # the target, so keep the band tight: faces within 0.3 pitch of the
    # closest one (a curved contact face's own centroid distances vary less
    # than that along the arc, e.g. 3.0-5.3 mm on a 10 mm mesh).  In
    # addition the face must point at the target: dot(outward, direction to
    # the face's own nearest target node) above 0.25.  A contact face angled
    # up to ~75 deg still qualifies while perpendicular side faces (dot ~ 0)
    # do not.
    set faceBand [expr {max(0.01, 0.3 * $pitch)}]
    set facingFaces {}
    foreach item $sortedFaces {
        set dist [lindex $item 0]
        if {$dist > $minDistance + $faceBand} { break }
        set face [lindex $item 1]
        set dot [expr {[lindex $item 2] * [lindex $item 5] + [lindex $item 3] * [lindex $item 6] + [lindex $item 4] * [lindex $item 7]}]
        if {$dot > 0.25} { lappend facingFaces $face }
    }
    if {[llength $facingFaces] == 0} { return {} }
    # outline of the facing region: edges used by exactly one facing face
    array set edgeCount {}
    foreach face $facingFaces {
        set n [llength $face]
        for {set i 0} {$i < $n} {incr i} {
            set a [lindex $face $i]
            set b [lindex $face [expr {($i + 1) % $n}]]
            set key [expr {$a < $b ? "$a,$b" : "$b,$a"}]
            incr edgeCount($key)
        }
    }
    set boundary {}
    foreach key [array names edgeCount] {
        if {$edgeCount($key) == 1} {
            foreach nodeId [split $key ,] { lappend boundary $nodeId }
        }
    }
    set boundary [lsort -integer -unique $boundary]
    # The facing layer may contain a middle row that is farther from the
    # target (e.g. a plate whose contact edge runs along its two outer rows
    # while the centre row overhangs the gap).  Keep only the nodes on the
    # closest contact band so the weld follows the actual contact edge.
    set nodeDistances {}
    foreach nodeId $boundary {
        set p [::SolidSeam::nodeXYZ $nodeId]
        set nearest 1.0e12
        foreach targetNode $targetNodes {
            set d [::SolidSeam::nodeDistance $p $targetXYZ($targetNode)]
            if {$d < $nearest} { set nearest $d }
        }
        lappend nodeDistances [list $nearest $nodeId]
    }
    set sortedNodes [lsort -real -index 0 $nodeDistances]
    set minNodeDistance [lindex [lindex $sortedNodes 0] 0]
    # the band scales with the mesh pitch: on a curved seam the contact
    # edge's own gap varies along the arc (3.0-5.3 mm on the F03 case) while
    # the next row is a full pitch away, so 0.35 pitch keeps the whole
    # contact edge without pulling in the farther row
    set nodeBand [expr {max(1.0, 0.35 * $pitch)}]
    set kept {}
    foreach item $sortedNodes {
        if {[lindex $item 0] <= $minNodeDistance + $nodeBand} {
            lappend kept [lindex $item 1]
        }
    }
    return $kept
}

# ---------------------------------------------------------------------------
# Junction detection: nodes of compA that lie within searchDistance of a node
# of compB, with the closest partner recorded.  The node list always comes
# from the FIRST component (compA = source); a mutual-nearest filter then
# keeps only the junction layer: for a thick solid the far face is also
# within the search distance, so a node is kept only when it is also the
# nearest compA node of its matched compB node (within 1.5x, tolerating
# different mesh densities).  Without this the far face nodes produce
# twisted chains and wrong weld locations.
# ---------------------------------------------------------------------------
proc ::SolidSeam::detectJunctionNodes {sourceComponentId targetComponentId searchDistance} {
    # Only boundary nodes of the FIRST component are weld candidates: shells
    # use their free-edge nodes; solids use the boundary of the outer face
    # that faces the target component.  Interior nodes can never be weld
    # locations and would only distort the chain.
    set sourceNodes [::SolidSeam::boundaryNodesOfComponent $sourceComponentId]
    if {[::SolidSeam::componentIsSolid $sourceComponentId]} {
        set facingNodes [::SolidSeam::solidFacingBoundaryNodes $sourceComponentId $targetComponentId]
        if {[llength $facingNodes] > 0} {
            set sourceNodes $facingNodes
        }
    }
    set targetNodes [::SolidSeam::componentNodeIds $targetComponentId]
    array set sourceXYZ {}
    foreach nodeId $sourceNodes {
        set sourceXYZ($nodeId) [::SolidSeam::nodeXYZ $nodeId]
    }
    array set targetXYZ {}
    foreach nodeId $targetNodes {
        set targetXYZ($nodeId) [::SolidSeam::nodeXYZ $nodeId]
    }

    # nearest compB node for every compA node inside the search distance
    set pairs {}
    foreach sourceNode $sourceNodes {
        set p $sourceXYZ($sourceNode)
        set bestDistance $searchDistance
        set bestTarget 0
        foreach targetNode $targetNodes {
            set d [::SolidSeam::nodeDistance $p $targetXYZ($targetNode)]
            if {$d < $bestDistance} {
                set bestDistance $d
                set bestTarget $targetNode
            }
        }
        if {$bestTarget != 0} {
            lappend pairs [list $sourceNode $bestTarget $bestDistance]
        }
    }
    if {[llength $pairs] == 0} { return {} }

    # nearest compA distance of every matched compB node (computed once).
    # A compB node may itself be a compA node (identical ids across comps),
    # so exclude self-distance: use the pair distance as the reference and
    # keep the pair only if it is not much farther than the closest other
    # compA node of the compB partner.
    set result {}
    foreach pair $pairs {
        set s [lindex $pair 0]
        set t [lindex $pair 1]
        set d [lindex $pair 2]
        set bestOther 1.0e12
        foreach sourceNode $sourceNodes {
            if {$sourceNode == $s} { continue }
            set dd [::SolidSeam::nodeDistance $sourceXYZ($sourceNode) $targetXYZ($t)]
            if {$dd < $bestOther} { set bestOther $dd }
        }
        set reference [expr {$d < $bestOther ? $d : $bestOther}]
        if {$d <= 1.5 * $reference + 0.01} {
            lappend result $pair
        }
    }

    # closest-layer filter: keep only the edge(s) at the minimum gap.  The
    # search distance may cover several parallel edges of the source face
    # (e.g. a plate edge plus an inner row); the weld belongs on the row that
    # is actually closest to the target, like the user's manual node list.
    # A curved seam's gap to the target varies along the arc (3.0-5.3 mm on
    # the F03 case) while the next row is a full mesh pitch away (13 mm), so
    # split by the largest distance gap: keep the near side of the biggest
    # jump.  A fallback 1.5x floor guards against a single outlier creating
    # a tiny gap.
    set sortedPairs [lsort -real -index 2 $result]
    set firstDistance [lindex [lindex $sortedPairs 0] 2]
    set splitDistance [expr {$firstDistance * 1.5 + 0.5}]
    set biggestGap 0.0
    for {set i 0} {$i < [llength $sortedPairs] - 1} {incr i} {
        set gap [expr {[lindex [lindex $sortedPairs [expr {$i + 1}]] 2] - [lindex [lindex $sortedPairs $i] 2]}]
        if {$gap > $biggestGap} {
            set biggestGap $gap
            set splitDistance [expr {0.5 * ([lindex [lindex $sortedPairs [expr {$i + 1}]] 2] + [lindex [lindex $sortedPairs $i] 2])}]
        }
    }
    # A real layer boundary must be a jump of at least half a mesh pitch.
    # The seam's own gap variation along a curved edge is smaller than that
    # (F03: 3.0-5.3 mm within one layer, 13 mm to the next row), so when the
    # biggest gap is sub-pitch the whole set is one layer and nothing is cut.
    set meshPitch [::SolidSeam::median [::SolidSeam::chainSpacings [::SolidSeam::pairSourceIds $result]]]
    if {$meshPitch <= 0.0} { set meshPitch 10.0 }
    if {$biggestGap < 0.5 * $meshPitch} {
        set splitDistance 1.0e12
    }
    set closest {}
    foreach pair $result {
        if {[lindex $pair 2] <= $splitDistance} { lappend closest $pair }
    }
    return $closest
}

# Median spacing between consecutive nodes of a chain (used by the layer
# filter to distinguish intra-arc variation from a real layer jump).
proc ::SolidSeam::pairSourceIds {pairs} {
    set ids {}
    foreach pair $pairs { lappend ids [lindex $pair 0] }
    return $ids
}

proc ::SolidSeam::chainSpacings {nodeIds} {
    array set coords {}
    foreach nodeId $nodeIds {
        set coords($nodeId) [::SolidSeam::nodeXYZ $nodeId]
    }
    set spacings {}
    for {set i 0} {$i < [llength $nodeIds] - 1} {incr i} {
        set d [::SolidSeam::nodeDistance $coords([lindex $nodeIds $i]) $coords([lindex $nodeIds [expr {$i + 1}]])]
        if {$d > 1.0e-8} { lappend spacings $d }
    }
    return $spacings
}

# ---------------------------------------------------------------------------
# Chain building: order the junction source nodes into a continuous path.
# Each chain is a list of node ids ordered head-to-tail; a new chain starts
# when the nearest unvisited node is farther than gapJumpLimit.  Once a chain
# has two nodes its direction is known, so extension prefers candidates that
# continue straight ahead (smallest turn) over merely closest ones; this
# keeps parallel rows of a solid face from zig-zagging into each other.
# ---------------------------------------------------------------------------
proc ::SolidSeam::buildChains {nodeIds gapJumpLimit} {
    array set coords {}
    foreach nodeId $nodeIds {
        set coords($nodeId) [::SolidSeam::nodeXYZ $nodeId]
    }
    set unvisited [lsort -integer -unique $nodeIds]
    set chains {}
    while {[llength $unvisited] > 0} {
        set chain [list [lindex $unvisited 0]]
        set unvisited [lrange $unvisited 1 end]
        set extended 1
        while {$extended} {
            set extended 0
            set tail [lindex $chain end]
            set head [lindex $chain 0]
            # The distance gate is the gap limit alone; the turn penalty only
            # ranks candidates below it.  Mixing the two (score > gap rejects
            # a 90 deg step even though the step is within the limit) used to
            # split a ring-shaped seam into several stub chains.
            set bestTail 0; set bestTailScore 1.0e12
            set bestHead 0; set bestHeadScore 1.0e12
            # chain direction (tail extension): vector from the previous node
            # to the tail, if the chain is long enough
            set tailDir {}
            if {[llength $chain] >= 2} {
                set prev [lindex $chain end-1]
                set tailDir [list \
                    [expr {[lindex $coords($tail) 0] - [lindex $coords($prev) 0]}] \
                    [expr {[lindex $coords($tail) 1] - [lindex $coords($prev) 1]}] \
                    [expr {[lindex $coords($tail) 2] - [lindex $coords($prev) 2]}]]
            }
            set headDir {}
            if {[llength $chain] >= 2} {
                set next [lindex $chain 1]
                set headDir [list \
                    [expr {[lindex $coords($head) 0] - [lindex $coords($next) 0]}] \
                    [expr {[lindex $coords($head) 1] - [lindex $coords($next) 1]}] \
                    [expr {[lindex $coords($head) 2] - [lindex $coords($next) 2]}]]
            }
            foreach candidate $unvisited {
                set dTail [::SolidSeam::nodeDistance $coords($tail) $coords($candidate)]
                set dHead [::SolidSeam::nodeDistance $coords($head) $coords($candidate)]
                # score: distance, plus a straightness penalty when a
                # direction is known (turn > 60deg adds 0.5 * gap)
                if {$dTail <= $gapJumpLimit} {
                    set score $dTail
                    if {$tailDir ne ""} {
                        set v [list \
                            [expr {[lindex $coords($candidate) 0] - [lindex $coords($tail) 0]}] \
                            [expr {[lindex $coords($candidate) 1] - [lindex $coords($tail) 1]}] \
                            [expr {[lindex $coords($candidate) 2] - [lindex $coords($tail) 2]}]]
                        set turn [::SolidSeam::angleBetween $tailDir $v]
                        if {$turn > 60.0} { set score [expr {$dTail + 0.5 * $gapJumpLimit}] }
                    }
                    if {$score < $bestTailScore} {
                        set bestTailScore $score
                        set bestTail $candidate
                    }
                }
                if {$dHead <= $gapJumpLimit} {
                    set score $dHead
                    if {$headDir ne ""} {
                        set v [list \
                            [expr {[lindex $coords($candidate) 0] - [lindex $coords($head) 0]}] \
                            [expr {[lindex $coords($candidate) 1] - [lindex $coords($head) 1]}] \
                            [expr {[lindex $coords($candidate) 2] - [lindex $coords($head) 2]}]]
                        set turn [::SolidSeam::angleBetween $headDir $v]
                        if {$turn > 60.0} { set score [expr {$dHead + 0.5 * $gapJumpLimit}] }
                    }
                    if {$score < $bestHeadScore} {
                        set bestHeadScore $score
                        set bestHead $candidate
                    }
                }
            }
            if {$bestTail != 0 && $bestTailScore <= $bestHeadScore} {
                lappend chain $bestTail
                set unvisited [lsearch -all -inline -not -exact $unvisited $bestTail]
                set extended 1
            } elseif {$bestHead != 0} {
                set chain [linsert $chain 0 $bestHead]
                set unvisited [lsearch -all -inline -not -exact $unvisited $bestHead]
                set extended 1
            }
        }
        lappend chains $chain
    }
    return $chains
}

# Angle in degrees between two 3D vectors.
proc ::SolidSeam::angleBetween {a b} {
    set dot [expr {[lindex $a 0] * [lindex $b 0] + [lindex $a 1] * [lindex $b 1] + [lindex $a 2] * [lindex $b 2]}]
    set lenA [expr {sqrt([lindex $a 0] * [lindex $a 0] + [lindex $a 1] * [lindex $a 1] + [lindex $a 2] * [lindex $a 2])}]
    set lenB [expr {sqrt([lindex $b 0] * [lindex $b 0] + [lindex $b 1] * [lindex $b 1] + [lindex $b 2] * [lindex $b 2])}]
    if {$lenA <= 1.0e-12 || $lenB <= 1.0e-12} { return 0.0 }
    set cosine [::SolidSeam::clamp [expr {$dot / ($lenA * $lenB)}] -1.0 1.0]
    return [expr {acos($cosine) * 180.0 / 3.141592653589793}]
}

# ---------------------------------------------------------------------------
# Unit normals of the elements of a component (element face normals from the
# first three nodes, averaged and aligned).
# ---------------------------------------------------------------------------
proc ::SolidSeam::componentAverageNormal {componentId} {
    catch {*clearmark elems 1}
    *createmark elems 1 "by comp id" $componentId
    set elementIds [hm_getmark elems 1]
    set normals {}
    foreach elementId $elementIds {
        catch {
            set n1 [hm_getvalue elems id=$elementId dataname=node1]
            set n2 [hm_getvalue elems id=$elementId dataname=node2]
            set n3 [hm_getvalue elems id=$elementId dataname=node3]
            set p1 [::SolidSeam::nodeXYZ $n1]
            set p2 [::SolidSeam::nodeXYZ $n2]
            set p3 [::SolidSeam::nodeXYZ $n3]
            set ux [expr {[lindex $p2 0] - [lindex $p1 0]}]
            set uy [expr {[lindex $p2 1] - [lindex $p1 1]}]
            set uz [expr {[lindex $p2 2] - [lindex $p1 2]}]
            set vx [expr {[lindex $p3 0] - [lindex $p1 0]}]
            set vy [expr {[lindex $p3 1] - [lindex $p1 1]}]
            set vz [expr {[lindex $p3 2] - [lindex $p1 2]}]
            set nx [expr {$uy * $vz - $uz * $vy}]
            set ny [expr {$uz * $vx - $ux * $vz}]
            set nz [expr {$ux * $vy - $uy * $vx}]
            set len [expr {sqrt($nx * $nx + $ny * $ny + $nz * $nz)}]
            if {$len > 1.0e-12} { lappend normals [list [expr {$nx / $len}] [expr {$ny / $len}] [expr {$nz / $len}]] }
        }
    }
    if {[llength $normals] == 0} { return {0 0 0} }
    set reference [lindex $normals 0]
    set sumX 0.0; set sumY 0.0; set sumZ 0.0
    foreach normal $normals {
        set dot [expr {[lindex $normal 0] * [lindex $reference 0] + [lindex $normal 1] * [lindex $reference 1] + [lindex $normal 2] * [lindex $reference 2]}]
        set factor [expr {$dot >= 0.0 ? 1.0 : -1.0}]
        set sumX [expr {$sumX + $factor * [lindex $normal 0]}]
        set sumY [expr {$sumY + $factor * [lindex $normal 1]}]
        set sumZ [expr {$sumZ + $factor * [lindex $normal 2]}]
    }
    set len [expr {sqrt($sumX * $sumX + $sumY * $sumY + $sumZ * $sumZ)}]
    if {$len < 1.0e-12} { return {0 0 0} }
    return [list [expr {$sumX / $len}] [expr {$sumY / $len}] [expr {$sumZ / $len}]]
}

proc ::SolidSeam::angleDeg {a b} {
    set dot [expr {[lindex $a 0] * [lindex $b 0] + [lindex $a 1] * [lindex $b 1] + [lindex $a 2] * [lindex $b 2]}]
    set dot [::SolidSeam::clamp $dot -1.0 1.0]
    set radians [expr {acos($dot)}]
    return [expr {$radians * 180.0 / 3.141592653589793}]
}

# ---------------------------------------------------------------------------
# Joint classification (mirrors the legacy Python joint_classifier rules):
#   perpendicular (normal vs normal ~90deg) -> T_JOINT  -> PENTA_MIG_T
#   parallel with high boundary ratio        -> BUTT_JOINT -> PENTA_MIG_B
#   parallel otherwise                       -> LAP_JOINT -> PENTA_MIG_L
#   angled (<=40deg)                         -> ANGLED_JOINT -> PENTA_MIG
#   otherwise                                -> UNKNOWN -> PENTA_MIG
# ---------------------------------------------------------------------------
proc ::SolidSeam::classifyJoint {sourceNormal targetNormal} {
    if {$sourceNormal eq {0 0 0} || $targetNormal eq {0 0 0}} {
        return [dict create joint_type UNKNOWN realization PENTA_MIG confidence 0.3]
    }
    set rawAngle [::SolidSeam::angleDeg $sourceNormal $targetNormal]
    set closest [expr {$rawAngle <= 90.0 ? $rawAngle : 180.0 - $rawAngle}]
    set perpendicular [expr {abs($closest - 90.0)}]
    if {$perpendicular <= 20.0} {
        return [dict create joint_type T_JOINT realization PENTA_MIG_T confidence 0.95]
    } elseif {$closest <= 20.0} {
        return [dict create joint_type LAP_JOINT realization PENTA_MIG_L confidence 0.85]
    } elseif {$closest <= 40.0} {
        return [dict create joint_type ANGLED_JOINT realization PENTA_MIG confidence 0.65]
    }
    return [dict create joint_type UNKNOWN realization PENTA_MIG confidence 0.4]
}

# ---------------------------------------------------------------------------
# Parameter derivation:
#   mesh_size  = median spacing of the chain nodes
#   width      = 6.0 by default, clamped into [0.25, 0.8] * mesh_size so the
#                weld section stays compatible with the local mesh
#   spacing    = 6.0 by default, clamped into [0.5*mesh, 0.65*width, 1.15*width]
#   tolerance  = max(gap + 1.25*width, 1.5*mesh_size, 6.0) so the native
#                realization search always covers the joint
# ---------------------------------------------------------------------------
proc ::SolidSeam::deriveParameters {chainNodeIds pairs defaultWidth defaultSpacing} {
    array set coords {}
    foreach nodeId $chainNodeIds {
        set coords($nodeId) [::SolidSeam::nodeXYZ $nodeId]
    }
    set segments {}
    for {set i 0} {$i < [llength $chainNodeIds] - 1} {incr i} {
        set d [::SolidSeam::nodeDistance $coords([lindex $chainNodeIds $i]) $coords([lindex $chainNodeIds [expr {$i + 1}]])]
        if {$d > 1.0e-8} { lappend segments $d }
    }
    set meshSize [::SolidSeam::median $segments]
    if {$meshSize <= 0.0} { set meshSize 10.0 }

    set maximumGap 0.0
    foreach pair $pairs {
        set gap [lindex $pair 2]
        if {$gap > $maximumGap} { set maximumGap $gap }
    }

    set width [::SolidSeam::clamp $defaultWidth [expr {0.25 * $meshSize}] [expr {0.8 * $meshSize}]]
    set spacing [::SolidSeam::clamp $defaultSpacing [expr {0.5 * $meshSize}] [expr {1.15 * $width}]]
    if {$spacing < [expr {0.65 * $width}]} { set spacing [expr {0.65 * $width}] }
    set tolerance [expr {max($maximumGap + 1.25 * $width, 1.5 * $meshSize, 6.0)}]

    return [dict create \
        mesh_size [format %.6f $meshSize] \
        maximum_gap [format %.6f $maximumGap] \
        weld_width [format %.6f $width] \
        line_spacing [format %.6f $spacing] \
        realization_tolerance [format %.6f $tolerance] \
        source_thickness [format %.6f $meshSize] \
        side_mode POSITIVE \
        right_angled false \
        orientation_reversed false \
        parameter_strategy ADAPTIVE_GEOMETRY_TCL_V1]
}

# ---------------------------------------------------------------------------
# Public entry: detect all seam candidates between two components.
# Returns a list of candidate dicts compatible with the existing
# createOneCandidate / validateBeforeCreate / validateAfterCreate flow.
# ---------------------------------------------------------------------------
proc ::SolidSeam::autoDetectSeams {sourceComponentId targetComponentId settings} {
    set searchDistance [dict get $settings search_distance]
    set maxSearchDistance [dict get $settings max_search_distance]
    set minWeldLength [dict get $settings min_weld_length]
    set gapJumpLimit [dict get $settings gap_jump_limit]
    set defaultWidth [dict get $settings default_width]
    set defaultSpacing [dict get $settings default_spacing]
    set sourceName ""
    catch {set sourceName [hm_getvalue comps id=$sourceComponentId dataname=name]}
    set targetName ""
    catch {set targetName [hm_getvalue comps id=$targetComponentId dataname=name]}

    # The weld node list always comes from the FIRST selected component (the
    # user's manual 1D connector seam flow picks the weld nodes on one side
    # and links both components).  detectJunctionNodes already restricts the
    # source to its boundary nodes: free-edge nodes for shells, the boundary
    # of the outer face that faces the target for solids.
    set pairs [::SolidSeam::detectJunctionNodes $sourceComponentId $targetComponentId $searchDistance]
    set sourceNodeIds {}
    foreach pair $pairs {
        if {[lsearch -exact $sourceNodeIds [lindex $pair 0]] < 0} { lappend sourceNodeIds [lindex $pair 0] }
    }
    if {[llength $sourceNodeIds] == 0} { return {} }

    # Estimate the local node spacing from the junction nodes themselves so
    # the chain gap limit is always >= the mesh pitch: with a 10 mm mesh the
    # default gap_jump_limit of 5 would otherwise split every chain into
    # single-node pieces.
    set spacingValues {}
    for {set i 0} {$i < [llength $sourceNodeIds]} {incr i} {
        set p [::SolidSeam::nodeXYZ [lindex $sourceNodeIds $i]]
        set nearest 1.0e12
        for {set j 0} {$j < [llength $sourceNodeIds]} {incr j} {
            if {$j == $i} { continue }
            set d [::SolidSeam::nodeDistance $p [::SolidSeam::nodeXYZ [lindex $sourceNodeIds $j]]]
            if {$d < $nearest} { set nearest $d }
        }
        if {$nearest < 1.0e11} { lappend spacingValues $nearest }
    }
    set localSpacing [::SolidSeam::median $spacingValues]
    if {$localSpacing <= 0.0} { set localSpacing 10.0 }
    set chainGap [expr {max($gapJumpLimit, 1.5 * $localSpacing)}]

    set chains [::SolidSeam::buildChains $sourceNodeIds $chainGap]
    set sourceNormal [::SolidSeam::componentAverageNormal $sourceComponentId]
    set targetNormal [::SolidSeam::componentAverageNormal $targetComponentId]

    set candidates {}
    set index 0
    foreach chainNodeIds $chains {
        incr index
        if {[llength $chainNodeIds] < 2} { continue }
        set parameters [::SolidSeam::deriveParameters $chainNodeIds $pairs $defaultWidth $defaultSpacing]
        if {[dict get $parameters mesh_size] <= 0.0} { continue }
        set chainLength 0.0
        for {set i 0} {$i < [llength $chainNodeIds] - 1} {incr i} {
            set p [::SolidSeam::nodeXYZ [lindex $chainNodeIds $i]]
            set q [::SolidSeam::nodeXYZ [lindex $chainNodeIds [expr {$i + 1}]]]
            set chainLength [expr {$chainLength + [::SolidSeam::nodeDistance $p $q]}]
        }
        if {$chainLength < $minWeldLength} { continue }
        set classification [::SolidSeam::classifyJoint $sourceNormal $targetNormal]
        set candidateId "AUTO_${sourceComponentId}_${targetComponentId}_${index}"
        set candidate [dict create \
            candidate_id $candidateId \
            source_component_id $sourceComponentId \
            target_component_id $targetComponentId \
            source_component_name $sourceName \
            target_component_name $targetName \
            node_ids $chainNodeIds \
            status PENDING \
            suggested_realization [dict get $classification realization] \
            joint_type [dict get $classification joint_type] \
            confidence [dict get $classification confidence] \
            confidence_level [expr {[dict get $classification confidence] >= 0.8 ? "HIGH" : "MEDIUM"}] \
            duplicate_state NONE \
            warnings {} \
            chain_length [format %.3f $chainLength] \
        ]
        set candidate [dict merge $candidate $parameters]
        lappend candidates $candidate
    }
    return $candidates
}
