proc ::MeshSeamWeld::patchBoundaryEdges {elemIds {allowTransientNonManifold 0} {phase pre-remesh}} {
    set counts [dict create]
    set connectivity [::MeshSeamWeld::readShellElementConnectivityBulk $elemIds 1]
    foreach elemId $elemIds {
        if {![dict exists $connectivity $elemId]} {
            error "Cannot read native patch element $elemId."
        }
        set nodes [dict get $connectivity $elemId]
        set count [llength $nodes]
        if {$count ni {3 4}} {
            error "Native patch contains a non-linear-shell element $elemId."
        }
        for {set index 0} {$index < $count} {incr index} {
            set edge [lsort -integer [list [lindex $nodes $index] \
                [lindex $nodes [expr {($index + 1) % $count}]]]]
            dict incr counts $edge
        }
    }
    set boundary {}
    dict for {edge ownerCount} $counts {
        if {$ownerCount > 2} {
            if {!$allowTransientNonManifold} {
                error "Native patch contains a non-manifold edge: $edge."
            }
            # Diagnostic callers may inspect an intermediate mod-2 boundary.
            # Production creation always passes 0, before and after remesh.
            ::HybridCore::log WARN \
                "mesh_seam_weld $phase native patch non-manifold edge=[join $edge -] owners=$ownerCount; tolerated by the relaxed patch check"
            if {$ownerCount % 2 == 1} { lappend boundary $edge }
            continue
        }
        if {$ownerCount == 1} { lappend boundary $edge }
    }
    return $boundary
}

# Collector cleanup utility.  It is not a substitute for transaction rollback.
proc ::MeshSeamWeld::removeCreatedWeldElements {outputCompId beforeOutputElems} {
    if {$outputCompId eq ""} { return 0 }
    set added [::MeshSeamWeld::idsAddedToCollection $beforeOutputElems \
        [::MeshSeamWeld::componentElementIds $outputCompId]]
    if {[llength $added] == 0} { return 0 }
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 $added} markErr]} {
        error "Could not mark failed-path weld elements: $markErr"
    }
    if {[catch {*deletemark elems 1} deleteErr]} {
        catch {*clearmark elems 1}
        error "Could not delete failed-path weld elements: $deleteErr"
    }
    catch {*clearmark elems 1}
    return [llength $added]
}

proc ::MeshSeamWeld::patchEdgeSet {elemIds} {
    set edges [dict create]
    set signatures [dict create]
    set connectivity [::MeshSeamWeld::readShellElementConnectivityBulk $elemIds 1]
    foreach elemId $elemIds {
        if {![dict exists $connectivity $elemId]} {
            error "Cannot read native patch element $elemId."
        }
        set nodes [dict get $connectivity $elemId]
        set count [llength $nodes]
        if {$count ni {3 4}} {
            error "Native patch contains a non-linear-shell element $elemId."
        }
        set signature [lsort -integer -unique $nodes]
        if {[llength $signature] != $count || [dict exists $signatures $signature]} {
            error "Native patch contains a degenerate or duplicate shell element $elemId."
        }
        dict set signatures $signature 1
        for {set index 0} {$index < $count} {incr index} {
            dict set edges [lsort -integer [list [lindex $nodes $index] \
                [lindex $nodes [expr {($index + 1) % $count}]]]] 1
        }
    }
    return $edges
}

proc ::MeshSeamWeld::sourcePathEdges {sourceNodes closedLoop} {
    set edges {}
    set count [llength $sourceNodes]
    set segmentCount [expr {$closedLoop ? $count : $count - 1}]
    for {set index 0} {$index < $segmentCount} {incr index} {
        set a [lindex $sourceNodes $index]
        set b [lindex $sourceNodes [expr {($index + 1) % $count}]]
        if {$a eq $b} { error "Source path contains a zero-length node segment at $a." }
        lappend edges [lsort -integer [list $a $b]]
    }
    return $edges
}

proc ::MeshSeamWeld::attachmentChainThroughNewNodes {fromNode toNode edgeSet sourceNodeName} {
    upvar 1 $sourceNodeName sourceNode
    array set adjacency {}
    dict for {edge unused} $edgeSet {
        lassign $edge a b
        lappend adjacency($a) $b
        lappend adjacency($b) $a
    }
    if {![info exists adjacency($fromNode)]} { return {} }
    set queue [list [list $fromNode [list $fromNode]]]
    set visited [dict create $fromNode 1]
    for {set head 0} {$head < [llength $queue]} {incr head} {
        lassign [lindex $queue $head] current path
        foreach neighbor $adjacency($current) {
            if {$neighbor eq $toNode} { return [concat $path [list $toNode]] }
            if {[info exists sourceNode($neighbor)] || [dict exists $visited $neighbor]} {
                continue
            }
            dict set visited $neighbor 1
            lappend queue [list $neighbor [concat $path [list $neighbor]]]
        }
    }
    return {}
}

# A closed source rail can be an embedded edge loop of the joint patch rather
# than part of its exterior boundary.  Accept that topology only when every
# ordered source segment is an actual edge of the new patch.  Copied,
# disconnected, partial, or reordered source rails therefore still fail.
proc ::MeshSeamWeld::sourceAttachmentProblem {sourceNodes closedLoop patchEdges} {
    set sourceEdges [::MeshSeamWeld::sourcePathEdges $sourceNodes $closedLoop]
    set subdividedEdges {}
    foreach edge $sourceEdges {
        if {![dict exists $patchEdges $edge]} { lappend subdividedEdges $edge }
    }
    if {[llength $subdividedEdges] == 0} { return "" }
    array set sourceNode {}
    foreach nodeId $sourceNodes { set sourceNode($nodeId) 1 }
    set allNodes $sourceNodes
    dict for {edge unused} $patchEdges { set allNodes [concat $allNodes $edge] }
    set coords [::MeshSeamWeld::patchBoundaryNodeCoordinates \
        [lsort -integer -unique $allNodes]]
    if {[dict size $coords] == 0} { return "source attachment coordinates are unreadable" }
    foreach edge $subdividedEdges {
        lassign $edge a b
        set chain [::MeshSeamWeld::attachmentChainThroughNewNodes \
            $a $b $patchEdges sourceNode]
        if {[llength $chain] < 3} {
            return "source attachment edge [join $edge -] is absent from the native patch"
        }
        lassign [dict get $coords $a] ax ay az
        lassign [dict get $coords $b] bx by bz
        set edgeLength [expr {sqrt(($bx-$ax)*($bx-$ax) + ($by-$ay)*($by-$ay) + ($bz-$az)*($bz-$az))}]
        set maxOffset [expr {max(1.0e-9, 0.25*$edgeLength)}]
        foreach nodeId [lrange $chain 1 end-1] {
            set ownDistance [::MeshSeamWeld::pointSegmentDistance \
                [dict get $coords $a] [dict get $coords $b] [dict get $coords $nodeId]]
            if {$ownDistance > $maxOffset || \
                ![::MeshSeamWeld::boundaryNodeBelongsToEdge \
                    $nodeId $a $b $sourceEdges $coords]} {
                return "inserted node $nodeId does not belong to source attachment edge [join $edge -]"
            }
        }
    }
    return ""
}

proc ::MeshSeamWeld::patchBoundaryNodeCoordinates {nodeIds {knownCoords {}}} {
    # Structural validation can compare a current boundary with a pre-remesh
    # boundary whose original node IDs no longer exist.  Seed the result with
    # its snapshot coordinates, then overwrite them with current coordinates.
    set coords $knownCoords
    set unresolved {}
    foreach nodeId $nodeIds {
        if {![dict exists $coords $nodeId]} { lappend unresolved $nodeId }
    }
    set current [dict create]
    if {[llength $unresolved] > 0 && [catch {
        set current [::HybridCore::readNodeCoordinatesBulk $unresolved \
            [list ::MeshSeamWeld::nodeXYZ]]
    }]} {
        set current [dict create]
    }
    set coords [dict merge $coords $current]
    foreach nodeId $nodeIds {
        if {[dict exists $coords $nodeId]} { continue }
        if {[catch {::MeshSeamWeld::nodeXYZ $nodeId} xyz]} { return [dict create] }
        dict set coords $nodeId $xyz
    }
    return $coords
}

proc ::MeshSeamWeld::pointSegmentDistance {segmentStart segmentEnd point} {
    lassign $segmentStart ax ay az
    lassign $segmentEnd bx by bz
    lassign $point px py pz
    set vx [expr {$bx - $ax}]; set vy [expr {$by - $ay}]; set vz [expr {$bz - $az}]
    set wx [expr {$px - $ax}]; set wy [expr {$py - $ay}]; set wz [expr {$pz - $az}]
    set vv [expr {$vx*$vx + $vy*$vy + $vz*$vz}]
    if {$vv <= 0.0} {
        return [expr {sqrt($wx*$wx + $wy*$wy + $wz*$wz)}]
    }
    set t [expr {($wx*$vx + $wy*$vy + $wz*$vz) / $vv}]
    if {$t < 0.0} { set t 0.0 } elseif {$t > 1.0} { set t 1.0 }
    set dx [expr {$wx - $t*$vx}]; set dy [expr {$wy - $t*$vy}]; set dz [expr {$wz - $t*$vz}]
    return [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
}

# Depth-first search for a simple after-remesh boundary chain from $fromNode
# to $toNode whose intermediate nodes are all new (absent from the original
# boundary).  Returns the chain node list including both endpoints, or {} when
# no such chain exists.
proc ::MeshSeamWeld::boundaryChainThroughNewNodes {fromNode toNode afterAdjName beforeNodeName} {
    upvar 1 $afterAdjName afterAdj
    upvar 1 $beforeNodeName beforeNode
    if {![info exists afterAdj($fromNode)]} { return {} }
    set stack [list [list $fromNode [list $fromNode]]]
    set visited [dict create $fromNode 1]
    while {[llength $stack] > 0} {
        set entry [lindex $stack end]
        set stack [lrange $stack 0 end-1]
        lassign $entry current path
        foreach neighbor $afterAdj($current) {
            if {$neighbor eq $toNode} { return [concat $path [list $toNode]] }
            if {[info exists beforeNode($neighbor)]} { continue }
            if {[dict exists $visited $neighbor]} { continue }
            dict set visited $neighbor 1
            lappend stack [list $neighbor [concat $path [list $neighbor]]]
        }
    }
    return {}
}

# An inserted boundary node is accepted when the original attachment edge it
# subdivides is still its closest original attachment edge.  Comparing against
# the closest edge instead of the chord of one edge keeps the test valid on
# curved rails, where the remesher inserts the node on the curve and therefore
# off the chord.  A node that ended up next to a different attachment edge (for
# example on the opposite rail) is rejected.  Unreadable coordinates fail
# closed.
proc ::MeshSeamWeld::boundaryNodeBelongsToEdge {nodeId a b boundaryBefore coords} {
    foreach id [list $nodeId $a $b] {
        if {![dict exists $coords $id]} { return 0 }
    }
    set own [::MeshSeamWeld::pointSegmentDistance [dict get $coords $a] \
        [dict get $coords $b] [dict get $coords $nodeId]]
    foreach edge $boundaryBefore {
        lassign $edge c d
        if {$c eq $d} { continue }
        if {($c eq $a && $d eq $b) || ($c eq $b && $d eq $a)} { continue }
        if {![dict exists $coords $c] || ![dict exists $coords $d]} { return 0 }
        set other [::MeshSeamWeld::pointSegmentDistance [dict get $coords $c] \
            [dict get $coords $d] [dict get $coords $nodeId]]
        if {$other < $own - (1.0e-3 * $own + 1.0e-9)} { return 0 }
    }
    return 1
}

# Attachment validation for the mixed remesh of the native patch, used instead
# of the exact boundary-edge-set equality when strict_patch_boundary_check is
# off.  The remesher legitimately subdivides a long boundary edge in place by
# inserting nodes while both fixed endpoints stay.  On a curved rail it places
# those nodes on the curve, so they are off the original chord by the chord's
# sagitta (measured 0.37 mm on a 16.9 mm chord at R=97, HM 2019/2022), which a
# chord-collinearity tolerance rejects.  The attachment is therefore validated
# topologically: every original boundary node must keep its boundary
# attachment, every original boundary edge must be preserved or replaced by a
# chain of newly inserted nodes, every inserted node must still belong to the
# original edge it subdivides, and no after-remesh boundary edge may lie
# outside the original attachment.  A lost attachment node, a sideways
# reconnection or unreadable coordinates fail closed.  Returns "" when the
# attachment is preserved, otherwise a short diagnostic.
proc ::MeshSeamWeld::patchBoundaryAttachmentProblem {boundaryBefore boundaryAfter {knownCoords {}}} {
    array set afterAdj {}
    array set afterEdge {}
    foreach edge $boundaryAfter {
        lassign $edge a b
        if {$a eq $b} { return "degenerate after-remesh boundary edge $a-$b" }
        lappend afterAdj($a) $b
        lappend afterAdj($b) $a
        set afterEdge([lsort -integer [list $a $b]]) 1
    }
    array set beforeNode {}
    set nodeIds {}
    foreach edge $boundaryBefore {
        foreach nodeId $edge {
            set beforeNode($nodeId) 1
            lappend nodeIds $nodeId
        }
    }
    foreach edge $boundaryAfter {
        foreach nodeId $edge { lappend nodeIds $nodeId }
    }
    set nodeIds [lsort -integer -unique $nodeIds]
    if {[llength $nodeIds] == 0} { return "" }
    set coords [::MeshSeamWeld::patchBoundaryNodeCoordinates $nodeIds $knownCoords]
    if {[dict size $coords] == 0} { return "boundary node coordinates are unreadable" }

    array set afterNode {}
    foreach edge $boundaryAfter {
        foreach nodeId $edge { set afterNode($nodeId) 1 }
    }
    foreach nodeId [lsort -integer [array names beforeNode]] {
        if {![info exists afterNode($nodeId)]} {
            return "original attachment node $nodeId lost its boundary attachment"
        }
    }

    array set covered {}
    foreach edge $boundaryBefore {
        lassign $edge a b
        if {$a eq $b} { continue }
        set key [lsort -integer [list $a $b]]
        if {[info exists afterEdge($key)]} {
            set covered($key) 1
            continue
        }
        set chain [::MeshSeamWeld::boundaryChainThroughNewNodes $a $b afterAdj beforeNode]
        if {[llength $chain] < 2} {
            return "attachment edge $a-$b was neither kept nor subdivided"
        }
        foreach nodeId [lrange $chain 1 end-1] {
            if {![::MeshSeamWeld::boundaryNodeBelongsToEdge $nodeId $a $b \
                    $boundaryBefore $coords]} {
                return "inserted node $nodeId does not belong to attachment edge $a-$b"
            }
        }
        for {set index 0} {$index < [llength $chain] - 1} {incr index} {
            set key [lsort -integer [list [lindex $chain $index] \
                [lindex $chain [expr {$index + 1}]]]]
            if {![info exists afterEdge($key)]} {
                return "subdivision chain of attachment edge $a-$b is not a boundary chain"
            }
            set covered($key) 1
        }
    }
    foreach key [lsort [array names afterEdge]] {
        if {![info exists covered($key)]} {
            return "after-remesh boundary edge [join $key -] is outside the original attachment"
        }
    }
    return ""
}

proc ::MeshSeamWeld::processWeldPathNativePatch {sourceNodes targetComps closedLoop {progressOpened 0} {pathIndex 1} {pathTotal 1} {sourceCompIds {}} {seamComp ""} {targetElemIds {}} {imprintClosedLoop ""}} {
    variable cfg
    set totalStarted [clock milliseconds]
    if {$imprintClosedLoop eq ""} { set imprintClosedLoop $closedLoop }
    if {[llength $sourceCompIds] == 0} {
        set sourceCompIds [::MeshSeamWeld::componentIdsFromNodes $sourceNodes]
    }
    if {$seamComp eq ""} {
        set seamComp [::MeshSeamWeld::seamComponentForRelatedComps \
            [::MeshSeamWeld::uniq [concat $sourceCompIds $targetComps]]]
    }

    set reportProgress [expr {$progressOpened &&
        [::MeshSeamWeld::shouldUpdatePathProgress $pathIndex $pathTotal]}]
    set pathBase [expr {10.0 + 80.0*($pathIndex - 1)/double(max(1,$pathTotal))}]
    set pathSpan [expr {80.0/double(max(1,$pathTotal))}]
    if {$reportProgress} {
        ::HybridCore::progressUpdate $pathBase "Mesh Seam Weld" \
            "Creating native imprint patch $pathIndex/$pathTotal..." 1
    }

    set imprintStarted [clock milliseconds]
    if {[catch {
        set structuralBefore [::MeshSeamWeld::structuralMeshSnapshot $sourceNodes $targetElemIds]
        set ::MeshSeamWeld::activeStructuralSnapshot $structuralBefore
        set outputCompId [::MeshSeamWeld::ensureOutputComponent $seamComp 11]
        if {$outputCompId eq ""} { error "Cannot resolve native patch output component." }
        # Create Patch writes its joint elements to the current component.
        *currentcollector component $seamComp
        set beforeOutputElems [::MeshSeamWeld::componentElementIds $outputCompId]
        set ::MeshSeamWeld::activeOutputSnapshot [dict create component_id $outputCompId element_ids $beforeOutputElems]
        ::MeshSeamWeld::runImprintNodeList $sourceNodes $targetComps \
            $imprintClosedLoop $targetElemIds 1
        set patchElems [::MeshSeamWeld::idsAddedToCollection $beforeOutputElems \
            [::MeshSeamWeld::componentElementIds $outputCompId]]
        if {[llength $patchElems] == 0} {
            error "Native imprint did not create patch elements in $seamComp."
        }
    } imprintErr]} {
        ::MeshSeamWeld::stageError IMPRINT $imprintErr
    }
    set imprintMs [expr {[clock milliseconds] - $imprintStarted}]

    if {$reportProgress} {
        ::HybridCore::progressUpdate [expr {$pathBase + 0.65*$pathSpan}] \
            "Mesh Seam Weld" \
            "Remeshing native patch $pathIndex/$pathTotal..." 1
    }
    set strictPatchBoundaryCheck [expr {
        [info exists cfg(strict_patch_boundary_check)] &&
        $cfg(strict_patch_boundary_check)}]
    set meshStarted [clock milliseconds]
    if {[catch {
        # Create Patch can contain a transient three-owner edge that the isolated
        # mixed remesh normalizes, and HM does not always normalize the native
        # topology.  The relaxed default (strict_patch_boundary_check off)
        # tolerates that with a WARN and extracts the mod-2 exterior, which is
        # the same topology the manual workflow accepts; strict mode rejects it.
        set transientNonManifold [expr {!$strictPatchBoundaryCheck}]
        set boundaryBefore [::MeshSeamWeld::patchBoundaryEdges $patchElems \
            $transientNonManifold pre-remesh]
        if {[llength $boundaryBefore] == 0} { error "Native patch has no boundary." }
        set boundaryNodes [::MeshSeamWeld::uniq [concat {*}$boundaryBefore]]
        set sourceAttachmentMode boundary
        set missingSourceBoundaryNodes {}
        foreach sourceNode $sourceNodes {
            if {[lsearch -exact $boundaryNodes $sourceNode] < 0} {
                lappend missingSourceBoundaryNodes $sourceNode
            }
        }
        # Create Patch may legitimately rebuild the source-side rail internally,
        # so a source rail that differs from the input node pairs is recorded as
        # a diagnostic instead of rejecting an otherwise sound native result.
        # The rail subdivision is still validated geometrically and reported.
        set sourceProblem ""
        set sourceAuditCode [catch {
            set sourceProblem [::MeshSeamWeld::sourceAttachmentProblem \
                $sourceNodes $closedLoop [::MeshSeamWeld::patchEdgeSet $patchElems]]
        } sourceAuditErr]
        if {$sourceAuditCode} {
            set sourceAttachmentMode native_rebuilt
            ::HybridCore::log WARN \
                "mesh_seam_weld native source rail audit unavailable path=$pathIndex/$pathTotal detail=$sourceAuditErr"
        } elseif {$sourceProblem ne ""} {
            set sourceAttachmentMode native_rebuilt
            ::HybridCore::log WARN \
                "mesh_seam_weld native source rail was rebuilt path=$pathIndex/$pathTotal detail=$sourceProblem"
        }
        if {[llength $missingSourceBoundaryNodes] > 0} {
            set sourceAttachmentMode native_rebuilt
        }
        # Fix both the exterior attachment and a valid embedded source rail.
        set fixedNodes [::MeshSeamWeld::uniq [concat $boundaryNodes $sourceNodes]]
        set targetNodes {}
        foreach nodeId $boundaryNodes {
            if {[lsearch -exact $sourceNodes $nodeId] < 0} { lappend targetNodes $nodeId }
        }
        if {[llength $targetNodes] < 2} {
            error "Native patch has fewer than two target-side boundary nodes."
        }

        # Remesh only the new patch and keep every attachment-boundary node
        # fixed.  Mixed mode supports both mapped strips and curved/free areas.
        eval *createmark elems 1 $patchElems
        eval *createmark nodes 2 $fixedNodes
        *elementsaddnodesfixed 1 2
        *defaultremeshelems 1 $cfg(weld_mesh_size) 2 2 1 1 1 1 0 0 0 0 2 30
        ::MeshSeamWeld::clearLocalTopologyCaches $patchElems $fixedNodes
        set weldElems [::MeshSeamWeld::idsAddedToCollection $beforeOutputElems \
            [::MeshSeamWeld::componentElementIds $outputCompId]]
        if {[llength $weldElems] == 0} { error "Native patch remesh produced no weld elements." }
        set boundaryAfter [::MeshSeamWeld::patchBoundaryEdges $weldElems \
            $transientNonManifold post-remesh]
        set remeshedSourceProblem ""
        set remeshedSourceAuditCode [catch {
            set remeshedSourceProblem [::MeshSeamWeld::sourceAttachmentProblem \
                $sourceNodes $closedLoop [::MeshSeamWeld::patchEdgeSet $weldElems]]
        } remeshedSourceAuditErr]
        if {$remeshedSourceAuditCode} {
            ::HybridCore::log WARN \
                "mesh_seam_weld remeshed source rail audit unavailable path=$pathIndex/$pathTotal detail=$remeshedSourceAuditErr"
        } elseif {$remeshedSourceProblem ne ""} {
            ::HybridCore::log WARN \
                "mesh_seam_weld remeshed source rail differs from input path=$pathIndex/$pathTotal detail=$remeshedSourceProblem"
        }
        if {$strictPatchBoundaryCheck} {
            if {[lsort $boundaryBefore] ne [lsort $boundaryAfter]} {
                error "Native patch remesh changed its attachment edges."
            }
        } else {
            set boundaryProblem [::MeshSeamWeld::patchBoundaryAttachmentProblem \
                $boundaryBefore $boundaryAfter]
            if {$boundaryProblem ne ""} {
                error "Native patch remesh moved the patch attachment boundary: $boundaryProblem (boundary_edges [llength $boundaryBefore] -> [llength $boundaryAfter])."
            }
        }
        ::MeshSeamWeld::validateStructuralMesh $structuralBefore $weldElems $sourceNodes $closedLoop
    } meshErr]} {
        # Imprint and weld creation are one transaction.  Deleting only the
        # weld cannot repair the mother mesh; the caller must undo both.
        ::MeshSeamWeld::stageError AUTOMESH $meshErr
    }
    set meshMs [expr {[clock milliseconds] - $meshStarted}]
    set totalMs [expr {[clock milliseconds] - $totalStarted}]
    set boundaryCheckMode [expr {$strictPatchBoundaryCheck ? "strict" : "relaxed"}]
    ::HybridCore::log INFO \
        "PERF mesh_seam_weld creation_mode=native_imprint_patch path=$pathIndex/$pathTotal component=$seamComp source_nodes=[llength $sourceNodes] patch_elements=[llength $patchElems] weld_elements=[llength $weldElems] mesh_type=mixed mesh_size=$cfg(weld_mesh_size) source_attachment=$sourceAttachmentMode boundary_check=$boundaryCheckMode imprint_ms=$imprintMs mesh_create_ms=$meshMs total_ms=$totalMs"

    if {$reportProgress || $pathIndex == $pathTotal} {
        ::HybridCore::progressUpdate \
            [expr {10.0 + 80.0*$pathIndex/double(max(1,$pathTotal))}] \
            "Mesh Seam Weld" "Path $pathIndex/$pathTotal complete" 1
    }
    return [list sourceNodes $sourceNodes sourceCompIds $sourceCompIds \
        seamCompName $seamComp imprintNodes $targetNodes targetNodes $targetNodes \
        weldElems $weldElems timings [list imprint_ms $imprintMs \
            target_match_ms 0 mesh_create_ms $meshMs total_ms $totalMs]]
}

proc ::MeshSeamWeld::shouldUpdatePathProgress {pathIndex pathTotal} {
    # Each path can take noticeable time in large models.  Report every path
    # so the UI does not appear to execute opaque groups of about 30 loops.
    return 1
}

proc ::MeshSeamWeld::processWeldPathTcl {sourceNodes targetComps closedLoop {progressOpened 0} {pathIndex 1} {pathTotal 1} {sourceCompIds {}} {seamComp ""} {targetElemIds {}} {imprintClosedLoop ""}} {
    set totalStarted [clock milliseconds]
    if {$imprintClosedLoop eq ""} { set imprintClosedLoop $closedLoop }
    if {[llength $sourceCompIds] == 0} {
        set sourceCompIds [::MeshSeamWeld::componentIdsFromNodes $sourceNodes]
    }
    if {$seamComp eq ""} {
        set related [::MeshSeamWeld::uniq [concat $sourceCompIds $targetComps]]
        set seamComp [::MeshSeamWeld::seamComponentForRelatedComps $related]
    }

    set reportProgress [expr {$progressOpened && [::MeshSeamWeld::shouldUpdatePathProgress $pathIndex $pathTotal]}]
    set pathBase [expr {10.0 + 80.0 * ($pathIndex - 1) / double(max(1, $pathTotal))}]
    set pathSpan [expr {80.0 / double(max(1, $pathTotal))}]
    if {$reportProgress} {
        ::HybridCore::progressUpdate $pathBase "Mesh Seam Weld" \
            "Imprinting path $pathIndex/$pathTotal..." 1
    }

    set imprintStarted [clock milliseconds]
    if {[catch {
        ::MeshSeamWeld::runImprintNodeList $sourceNodes $targetComps $imprintClosedLoop $targetElemIds
    } imprintErr]} {
        ::MeshSeamWeld::stageError IMPRINT $imprintErr
    }
    set imprintMs [expr {[clock milliseconds] - $imprintStarted}]

    if {$reportProgress} {
        ::HybridCore::progressUpdate [expr {$pathBase + 0.55*$pathSpan}] \
            "Mesh Seam Weld" \
            "Validating post-imprint nodes $pathIndex/$pathTotal..." 1
    }
    set targetStarted [clock milliseconds]
    if {[catch {
        set targetNodes [::MeshSeamWeld::targetNodesFromImprintList \
            $sourceNodes "" 0]
        set targetMatchMode native_imprint_list
        set nativeContinuous 0
        if {[llength $targetNodes] > 0} {
            set nativeContinuous [::MeshSeamWeld::targetPathIsContinuous \
                $targetNodes $targetComps $closedLoop]
        }
        # Even a complete, edge-continuous native list can be a neighboring
        # target row rather than the row produced below the source path.  Always
        # rebuild from the complete local post-imprint topology and use the
        # source coordinates as the global matching objective.  The native list
        # remains useful only as evidence/seeds for rebuilding that local scope.
        set currentTargetElems [::MeshSeamWeld::targetElementsAfterImprint \
            $targetComps $targetElemIds $sourceNodes $closedLoop]
        if {![catch {
            set recoveredTargetNodes [::MeshSeamWeld::targetNodesFromPostImprintTopology \
                $sourceNodes $targetComps $currentTargetElems $closedLoop]
        } recoveryErr]} {
            set targetNodes $recoveredTargetNodes
            set targetMatchMode post_imprint_topology
        } else {
            # Never stretch a full source path over a merely plausible native
            # fragment.  This used to create trapezoidal/fan-shaped strips with
            # a dense sliver at one end.
            error "The complete projected target path could not be reconstructed from post-imprint topology (native_count=[llength $targetNodes], native_continuous=$nativeContinuous): $recoveryErr"
        }
    } targetErr]} {
        ::MeshSeamWeld::stageError TARGET_MATCH $targetErr
    }
    if {[llength $targetNodes] < 2} {
        ::MeshSeamWeld::stageError TARGET_CONTINUITY [::HWFlow::txt \
            "imprint 后少于两个目标节点，无法形成任何可连接区段。" \
            "Fewer than two target nodes remain after imprint, so no connectable section can be formed."]
    }
    set targetNodes [::MeshSeamWeld::alignTargetPathNodes \
        $sourceNodes $targetNodes $closedLoop]
    set targetNodes [::MeshSeamWeld::refineEqualTargetPathCorrespondence \
        $sourceNodes $targetNodes $targetComps $closedLoop]
    set imprintNodes $targetNodes
    ::HybridCore::log INFO \
        "imprint target_match_mode=$targetMatchMode nodes=[llength $targetNodes] current_target_elements=[llength $currentTargetElems]"
    set targetMs [expr {[clock milliseconds] - $targetStarted}]

    if {$reportProgress} {
        ::HybridCore::progressUpdate [expr {$pathBase + 0.75*$pathSpan}] \
            "Mesh Seam Weld" \
            "Creating structured weld mesh $pathIndex/$pathTotal..." 1
    }
    set meshStarted [clock milliseconds]
    if {[catch {
        set weldElems [::MeshSeamWeld::createRuledMeshBetweenNodePaths \
            $sourceNodes $targetNodes $seamComp $closedLoop $targetComps]
    } meshErr]} {
        ::MeshSeamWeld::stageError AUTOMESH $meshErr
    }
    if {[llength $weldElems] == 0} {
        ::MeshSeamWeld::stageError AUTOMESH [::HWFlow::txt \
            "焊缝网格创建没有生成单元。" \
            "Weld mesh creation did not create elements."]
    }
    set meshMs [expr {[clock milliseconds] - $meshStarted}]
    set totalMs [expr {[clock milliseconds] - $totalStarted}]
    ::HybridCore::log INFO "PERF mesh_seam_weld path=$pathIndex/$pathTotal nodes=[llength $sourceNodes] closed_loop=$closedLoop imprint_closed_loop=$imprintClosedLoop local_target_elems=[llength $targetElemIds] imprint_scope=$::MeshSeamWeld::lastImprintTargetMode imprint_core_elems=$::MeshSeamWeld::lastImprintCoreElemCount shared_external_elems=$::MeshSeamWeld::lastImprintSharedNeighborElemCount imprint_target_elems=$::MeshSeamWeld::lastImprintTargetElemCount imprint_ms=$imprintMs target_match_ms=$targetMs mesh_create_ms=$meshMs total_ms=$totalMs"

    if {$reportProgress || $pathIndex == $pathTotal} {
        set percent [expr {10.0 + 80.0 * $pathIndex / double(max(1, $pathTotal))}]
        ::HybridCore::progressUpdate $percent "Mesh Seam Weld" "Path $pathIndex/$pathTotal complete" 1
    }
    return [list sourceNodes $sourceNodes sourceCompIds $sourceCompIds seamCompName $seamComp imprintNodes $imprintNodes targetNodes $targetNodes weldElems $weldElems timings [list imprint_ms $imprintMs target_match_ms $targetMs mesh_create_ms $meshMs total_ms $totalMs]]
}
