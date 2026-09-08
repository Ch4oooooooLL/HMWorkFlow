# Native patch validation route. The caller owns the per-path history action.
proc ::MeshSeamWeld::patchBoundaryEdges {elemIds} {
    set counts {}
    set connectivity [::MeshSeamWeld::readShellElementConnectivityBulk $elemIds 1]
    foreach id $elemIds {
        if {![dict exists $connectivity $id]} { error "Cannot read patch element $id." }
        set nodes [dict get $connectivity $id]
        set n [llength $nodes]
        if {$n != 3 && $n != 4} { error "Patch contains a non-linear-shell element $id." }
        for {set i 0} {$i < $n} {incr i} {
            set edge [lsort -integer [list [lindex $nodes $i] [lindex $nodes [expr {($i+1)%$n}]]]]
            dict incr counts $edge
        }
    }
    set boundary {}
    dict for {edge count} $counts {
        if {$count > 2} { error "Patch contains a non-manifold edge: $edge." }
        if {$count == 1} { lappend boundary $edge }
    }
    return $boundary
}

proc ::MeshSeamWeld::processWeldPathNativePatch {sourceNodes targetComps closedLoop {progressOpened 0} {pathIndex 1} {pathTotal 1} {sourceCompIds {}} {seamComp ""} {targetElemIds {}} {imprintClosedLoop ""}} {
    variable cfg
    set started [clock milliseconds]
    if {$imprintClosedLoop eq ""} { set imprintClosedLoop $closedLoop }
    if {[llength $sourceCompIds] == 0} {
        set sourceCompIds [::MeshSeamWeld::componentIdsFromNodes $sourceNodes]
    }
    if {$seamComp eq ""} {
        set seamComp [::MeshSeamWeld::seamComponentForRelatedComps \
            [::MeshSeamWeld::uniq [concat $sourceCompIds $targetComps]]]
    }
    if {[catch {
        set compId [::MeshSeamWeld::ensureOutputComponent $seamComp 11]
        if {$compId eq ""} { error "Cannot resolve patch output component." }
        # ensureOutputComponent tolerates selector errors; this switch must succeed.
        *currentcollector component $seamComp
        set beforeElems [::MeshSeamWeld::componentElementIds $compId]
        ::MeshSeamWeld::runImprintNodeList $sourceNodes $targetComps $imprintClosedLoop $targetElemIds 1
        set patchElems [::MeshSeamWeld::idsAddedToCollection $beforeElems \
            [::MeshSeamWeld::componentElementIds $compId]]
        if {[llength $patchElems] == 0} { error "Native imprint did not create patch elements in $seamComp." }
    } err]} { ::MeshSeamWeld::stageError IMPRINT $err }
    set imprintMs [expr {[clock milliseconds]-$started}]
    if {$progressOpened} {
        ::HybridCore::progressUpdate [expr {10.0+80.0*($pathIndex-0.3)/max(1,$pathTotal)}] \
            "Mesh Seam Weld" "Optimizing native patch $pathIndex/$pathTotal (mixed)..." 1
    }
    set meshStarted [clock milliseconds]
    if {[catch {
        set boundary [::MeshSeamWeld::patchBoundaryEdges $patchElems]
        if {[llength $boundary] == 0} { error "Native patch has no boundary." }
        set fixedNodes [::MeshSeamWeld::uniq [concat {*}$boundary]]
        foreach node $sourceNodes {
            if {[lsearch -exact $fixedNodes $node] < 0} { error "Native patch misses source boundary node $node." }
        }
        set targetNodes {}
        foreach node $fixedNodes {
            if {[lsearch -exact $sourceNodes $node] < 0} { lappend targetNodes $node }
        }
        # Automesh by elements, mixed for mapped and free regions. Preserve
        # attachment boundaries and scope the remesh to this path's new patch.
        eval *createmark elems 1 $patchElems
        eval *createmark nodes 2 $fixedNodes
        *elementsaddnodesfixed 1 2
        *defaultremeshelems 1 $cfg(weld_mesh_size) 2 2 1 1 1 1 0 0 0 0 2 30
        ::MeshSeamWeld::clearLocalTopologyCaches $patchElems $fixedNodes
        set weldElems [::MeshSeamWeld::idsAddedToCollection $beforeElems \
            [::MeshSeamWeld::componentElementIds $compId]]
        if {[llength $weldElems] == 0} { error "Automesh produced no weld elements." }
        set afterBoundary [::MeshSeamWeld::patchBoundaryEdges $weldElems]
        if {[lsort $boundary] ne [lsort $afterBoundary]} {
            error "Automesh changed patch attachment edges."
        }
    } err]} { ::MeshSeamWeld::stageError AUTOMESH $err }
    set meshMs [expr {[clock milliseconds]-$meshStarted}]
    set totalMs [expr {[clock milliseconds]-$started}]
    ::HybridCore::log INFO "PERF mesh_seam_weld creation_mode=native_imprint_patch path=$pathIndex/$pathTotal component=$seamComp patch_elements=[llength $patchElems] weld_elements=[llength $weldElems] mesh_type=mixed mesh_size=$cfg(weld_mesh_size) imprint_ms=$imprintMs mesh_create_ms=$meshMs total_ms=$totalMs"
    return [list sourceNodes $sourceNodes sourceCompIds $sourceCompIds seamCompName $seamComp \
        imprintNodes $targetNodes targetNodes $targetNodes weldElems $weldElems \
        timings [list imprint_ms $imprintMs target_match_ms 0 mesh_create_ms $meshMs total_ms $totalMs]]
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
