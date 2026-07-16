proc ::MeshSeamWeld::processWeldPathPython {sourceNodes targetComps closedLoop {progressOpened 0} {pathIndex 1} {pathTotal 1}} {
    set base [expr {10.0+80.0*($pathIndex-1)/double($pathTotal)}]; set span [expr {80.0/double($pathTotal)}]
    set sourceRun [::MeshSeamWeld::runPythonPathStage source $sourceNodes {} $closedLoop $base [expr {$base+0.25*$span}]]
    set sourceCandidate [lindex [dict get [dict get $sourceRun payload] candidates] 0]
    set sourceNodes [dict get $sourceCandidate path_node_ids]; ::HybridCore::closeLog
    set sourceCompIds [::MeshSeamWeld::componentIdsFromNodes $sourceNodes]; set related [::MeshSeamWeld::uniq [concat $sourceCompIds $targetComps]]; set seamComp [::MeshSeamWeld::seamComponentForRelatedComps $related]
    ::HybridCore::progressUpdate [expr {$base+0.30*$span}] "Mesh Seam Weld" "Imprinting path $pathIndex/$pathTotal into target mesh..." 1
    ::MeshSeamWeld::runImprintNodeList $sourceNodes $targetComps $closedLoop
    set imprintNodes [::MeshSeamWeld::targetCandidatesAfterImprint $sourceNodes $targetComps {}]
    set targetRun [::MeshSeamWeld::runPythonPathStage target $sourceNodes $imprintNodes $closedLoop [expr {$base+0.52*$span}] [expr {$base+0.72*$span}]]
    set targetCandidate [lindex [dict get [dict get $targetRun payload] candidates] 0]; set targetNodes [dict get $targetCandidate target_node_ids]; ::HybridCore::closeLog
    ::HybridCore::progressUpdate [expr {$base+0.78*$span}] "Mesh Seam Weld" "Creating ruled weld mesh for path $pathIndex/$pathTotal..." 1
    set weldElems [::MeshSeamWeld::createRuledMeshBetweenNodePaths $sourceNodes $targetNodes $seamComp $closedLoop]
    if {[llength $weldElems]==0} { error "automesh did not create weld elements" }
    ::HybridCore::progressUpdate [expr {$base+$span}] "Mesh Seam Weld" "Path $pathIndex/$pathTotal complete; weld elements=[llength $weldElems]" 1
    return [list sourceNodes $sourceNodes sourceCompIds $sourceCompIds seamCompName $seamComp imprintNodes $imprintNodes targetNodes $targetNodes weldElems $weldElems]
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
    if {$reportProgress} {
        set percent [expr {10.0 + 80.0 * ($pathIndex - 1) / double(max(1, $pathTotal))}]
        ::HybridCore::progressUpdate $percent "Mesh Seam Weld" "Imprinting path $pathIndex/$pathTotal..." 1
    }

    set imprintStarted [clock milliseconds]
    ::MeshSeamWeld::runImprintNodeList $sourceNodes $targetComps $imprintClosedLoop $targetElemIds
    set imprintNodes [::MeshSeamWeld::targetCandidatesAfterImprint $sourceNodes $targetComps {}]
    set imprintMs [expr {[clock milliseconds] - $imprintStarted}]

    set targetStarted [clock milliseconds]
    set targetNodes [::MeshSeamWeld::targetPathNodesAfterImprint $sourceNodes $imprintNodes]
    set targetNodes [::MeshSeamWeld::alignTargetPathNodes $sourceNodes $targetNodes $closedLoop]
    if {![::MeshSeamWeld::targetPathIsContinuous $targetNodes $targetComps $closedLoop]} {
        error [::HWFlow::txt \
            "imprint 后的目标节点不能在所选目标 component 上形成连续路径，已取消该闭环。" \
            "The imprinted target nodes do not form a continuous path on the selected target components; the loop was cancelled."]
    }
    set targetMs [expr {[clock milliseconds] - $targetStarted}]

    set meshStarted [clock milliseconds]
    set weldElems [::MeshSeamWeld::createRuledMeshBetweenNodePaths \
        $sourceNodes $targetNodes $seamComp $closedLoop]
    if {[llength $weldElems] == 0} {
        error [::HWFlow::txt \
            "automesh 没有创建焊缝单元。" \
            "Automesh did not create weld elements."]
    }
    set meshMs [expr {[clock milliseconds] - $meshStarted}]
    set totalMs [expr {[clock milliseconds] - $totalStarted}]
    ::HybridCore::log INFO "PERF mesh_seam_weld path=$pathIndex/$pathTotal nodes=[llength $sourceNodes] closed_loop=$closedLoop imprint_closed_loop=$imprintClosedLoop local_target_elems=[llength $targetElemIds] imprint_ms=$imprintMs target_match_ms=$targetMs automesh_ms=$meshMs total_ms=$totalMs"

    if {$reportProgress || $pathIndex == $pathTotal} {
        set percent [expr {10.0 + 80.0 * $pathIndex / double(max(1, $pathTotal))}]
        ::HybridCore::progressUpdate $percent "Mesh Seam Weld" "Path $pathIndex/$pathTotal complete" 1
    }
    return [list sourceNodes $sourceNodes sourceCompIds $sourceCompIds seamCompName $seamComp imprintNodes $imprintNodes targetNodes $targetNodes weldElems $weldElems timings [list imprint_ms $imprintMs target_match_ms $targetMs automesh_ms $meshMs total_ms $totalMs]]
}
