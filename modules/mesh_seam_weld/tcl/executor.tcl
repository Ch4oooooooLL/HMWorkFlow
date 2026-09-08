proc ::MeshSeamWeld::patchBoundaryEdges {elemIds} {
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
        if {$ownerCount > 2} { error "Native patch contains a non-manifold edge: $edge." }
        if {$ownerCount == 1} { lappend boundary $edge }
    }
    return $boundary
}

proc ::MeshSeamWeld::patchBoundaryNodeCoordinates {nodeIds} {
    set coords [dict create]
    if {[catch {set coords [::HybridCore::readNodeCoordinatesBulk $nodeIds \
            [list ::MeshSeamWeld::nodeXYZ]]}]} {
        set coords [dict create]
    }
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

proc ::MeshSeamWeld::pointOnBoundarySegment {coords segA segB nodeId} {
    foreach id [list $segA $segB $nodeId] {
        if {![dict exists $coords $id]} { return 0 }
    }
    set pa [dict get $coords $segA]
    set pb [dict get $coords $segB]
    set ax [lindex $pa 0]; set ay [lindex $pa 1]; set az [lindex $pa 2]
    set bx [lindex $pb 0]; set by [lindex $pb 1]; set bz [lindex $pb 2]
    set length [expr {sqrt(($bx-$ax)*($bx-$ax) + ($by-$ay)*($by-$ay) + ($bz-$az)*($bz-$az))}]
    set distance [::MeshSeamWeld::pointSegmentDistance $pa $pb [dict get $coords $nodeId]]
    return [expr {$distance <= 1.0e-3 * $length + 1.0e-9}]
}

# Walk the after-remesh boundary graph from $fromNode to $toNode.  Every
# intermediate node must lie on the straight segment between them, so an
# in-place subdivision of the original edge is accepted while any sideways
# reconnection of the boundary fails.
proc ::MeshSeamWeld::boundaryEdgeChainPreserved {fromNode toNode afterAdjName coords} {
    upvar 1 $afterAdjName afterAdj
    if {![info exists afterAdj($fromNode)]} { return 0 }
    set previous $fromNode
    set current ""
    foreach neighbor $afterAdj($fromNode) {
        if {$neighbor eq $toNode} { set current $toNode; break }
        if {[::MeshSeamWeld::pointOnBoundarySegment $coords $fromNode $toNode $neighbor]} {
            set current $neighbor
            break
        }
    }
    set visited [dict create]
    set guard 0
    while {$current ne $toNode} {
        if {$current eq "" || [dict exists $visited $current] || [incr guard] > 100000} {
            return 0
        }
        dict set visited $current 1
        set next ""
        if {[info exists afterAdj($current)]} {
            foreach neighbor $afterAdj($current) {
                if {$neighbor eq $previous} { continue }
                if {$neighbor eq $toNode} { set next $toNode; break }
                if {[::MeshSeamWeld::pointOnBoundarySegment $coords $fromNode $toNode $neighbor]} {
                    set next $neighbor
                    break
                }
            }
        }
        set previous $current
        set current $next
    }
    return 1
}

proc ::MeshSeamWeld::afterEdgeOnOriginalBoundary {a b boundaryBefore coords} {
    if {$a eq $b} { return 0 }
    foreach edge $boundaryBefore {
        lassign $edge c d
        if {$c eq $d} { continue }
        if {[::MeshSeamWeld::pointOnBoundarySegment $coords $c $d $a] &&
            [::MeshSeamWeld::pointOnBoundarySegment $coords $c $d $b]} { return 1 }
    }
    return 0
}

# Relaxed attachment validation used instead of the exact boundary-edge-set
# equality when strict_patch_boundary_check is off.  The remesher legitimately
# subdivides a long boundary edge by inserting nodes on it while both fixed
# endpoints stay, which the exact comparison rejected.  The attachment counts
# as changed when an original boundary edge is neither preserved nor replaced
# by a collinear subdivided chain, or a new boundary edge leaves the original
# attachment polyline.  Unreadable coordinates fail closed.
proc ::MeshSeamWeld::patchBoundaryAttachmentChanged {boundaryBefore boundaryAfter} {
    array set afterAdj {}
    foreach edge $boundaryAfter {
        lassign $edge a b
        if {$a eq $b} { return 1 }
        lappend afterAdj($a) $b
        lappend afterAdj($b) $a
    }
    set nodeIds {}
    foreach edge [concat $boundaryBefore $boundaryAfter] {
        foreach nodeId $edge { lappend nodeIds $nodeId }
    }
    set nodeIds [lsort -integer -unique $nodeIds]
    if {[llength $nodeIds] == 0} { return 0 }
    set coords [::MeshSeamWeld::patchBoundaryNodeCoordinates $nodeIds]
    if {[dict size $coords] == 0} { return 1 }

    foreach edge $boundaryBefore {
        lassign $edge a b
        if {$a eq $b} { continue }
        if {[info exists afterAdj($a)] && [lsearch -exact $afterAdj($a) $b] >= 0} { continue }
        if {![::MeshSeamWeld::boundaryEdgeChainPreserved $a $b afterAdj $coords]} {
            return 1
        }
    }
    foreach edge $boundaryAfter {
        lassign $edge a b
        if {[::MeshSeamWeld::afterEdgeOnOriginalBoundary $a $b $boundaryBefore $coords]} {
            continue
        }
        return 1
    }
    return 0
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
        set outputCompId [::MeshSeamWeld::ensureOutputComponent $seamComp 11]
        if {$outputCompId eq ""} { error "Cannot resolve native patch output component." }
        # Create Patch writes its joint elements to the current component.
        *currentcollector component $seamComp
        set beforeOutputElems [::MeshSeamWeld::componentElementIds $outputCompId]
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
    set meshStarted [clock milliseconds]
    if {[catch {
        set boundaryBefore [::MeshSeamWeld::patchBoundaryEdges $patchElems]
        if {[llength $boundaryBefore] == 0} { error "Native patch has no boundary." }
        set fixedNodes [::MeshSeamWeld::uniq [concat {*}$boundaryBefore]]
        foreach sourceNode $sourceNodes {
            if {[lsearch -exact $fixedNodes $sourceNode] < 0} {
                error "Native patch misses source boundary node $sourceNode."
            }
        }
        set targetNodes {}
        foreach nodeId $fixedNodes {
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
        set boundaryAfter [::MeshSeamWeld::patchBoundaryEdges $weldElems]
        if {[info exists cfg(strict_patch_boundary_check)] && $cfg(strict_patch_boundary_check)} {
            if {[lsort $boundaryBefore] ne [lsort $boundaryAfter]} {
                error "Native patch remesh changed its attachment edges."
            }
        } elseif {[::MeshSeamWeld::patchBoundaryAttachmentChanged \
                $boundaryBefore $boundaryAfter]} {
            error "Native patch remesh moved the patch attachment boundary."
        }
    } meshErr]} {
        ::MeshSeamWeld::stageError AUTOMESH $meshErr
    }
    set meshMs [expr {[clock milliseconds] - $meshStarted}]
    set totalMs [expr {[clock milliseconds] - $totalStarted}]
    set boundaryCheckMode relaxed
    if {[info exists cfg(strict_patch_boundary_check)] && $cfg(strict_patch_boundary_check)} {
        set boundaryCheckMode strict
    }
    ::HybridCore::log INFO \
        "PERF mesh_seam_weld creation_mode=native_imprint_patch path=$pathIndex/$pathTotal component=$seamComp source_nodes=[llength $sourceNodes] patch_elements=[llength $patchElems] weld_elements=[llength $weldElems] mesh_type=mixed mesh_size=$cfg(weld_mesh_size) boundary_check=$boundaryCheckMode imprint_ms=$imprintMs mesh_create_ms=$meshMs total_ms=$totalMs"

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
