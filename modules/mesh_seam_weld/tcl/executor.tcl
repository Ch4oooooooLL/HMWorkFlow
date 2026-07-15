proc ::MeshSeamWeld::processWeldPathPython {sourceNodes targetComps closedLoop {progressOpened 0} {pathIndex 1} {pathTotal 1}} {
    set base [expr {10.0+80.0*($pathIndex-1)/double($pathTotal)}]; set span [expr {80.0/double($pathTotal)}]
    set sourceRun [::MeshSeamWeld::runPythonPathStage source $sourceNodes {} $closedLoop $base [expr {$base+0.25*$span}]]
    set sourceCandidate [lindex [dict get [dict get $sourceRun payload] candidates] 0]
    set sourceNodes [dict get $sourceCandidate path_node_ids]; ::HybridCore::closeLog
    set sourceCompIds [::MeshSeamWeld::componentIdsFromNodes $sourceNodes]; set related [::MeshSeamWeld::uniq [concat $sourceCompIds $targetComps]]; set seamComp [::MeshSeamWeld::seamComponentForRelatedComps $related]
    ::HybridCore::progressUpdate [expr {$base+0.30*$span}] "Mesh Seam Weld" "Imprinting path $pathIndex/$pathTotal into target mesh..." 1
    set beforeNode ""; catch {set beforeNode [hm_latestentityid nodes]}; ::MeshSeamWeld::runImprintNodeList $sourceNodes $targetComps $closedLoop
    set imprintNodes [::MeshSeamWeld::targetCandidatesAfterImprint $sourceNodes $targetComps $beforeNode]
    set targetRun [::MeshSeamWeld::runPythonPathStage target $sourceNodes $imprintNodes $closedLoop [expr {$base+0.52*$span}] [expr {$base+0.72*$span}]]
    set targetCandidate [lindex [dict get [dict get $targetRun payload] candidates] 0]; set targetNodes [dict get $targetCandidate target_node_ids]; ::HybridCore::closeLog
    ::HybridCore::progressUpdate [expr {$base+0.78*$span}] "Mesh Seam Weld" "Creating ruled weld mesh for path $pathIndex/$pathTotal..." 1
    set weldElems [::MeshSeamWeld::createRuledMeshBetweenNodePaths $sourceNodes $targetNodes $seamComp $closedLoop]
    if {[llength $weldElems]==0} { error "automesh did not create weld elements" }
    ::HybridCore::progressUpdate [expr {$base+$span}] "Mesh Seam Weld" "Path $pathIndex/$pathTotal complete; weld elements=[llength $weldElems]" 1
    return [list sourceNodes $sourceNodes sourceCompIds $sourceCompIds seamCompName $seamComp imprintNodes $imprintNodes targetNodes $targetNodes weldElems $weldElems]
}
