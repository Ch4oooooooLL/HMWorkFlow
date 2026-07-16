if {![namespace exists ::HybridCore]} { source [file join [file dirname [file dirname [file dirname [file normalize [info script]]]]] hybrid_core tcl init.tcl] }
proc ::MeshSeamWeld::runPythonPathStage {mode sourceNodes candidateNodes closedLoop {progressStart 10.0} {progressEnd 60.0}} {
    variable MODULE_DIR
    set ws [::HybridCore::createTaskWorkspace mesh_seam_weld]; set dir [dict get $ws task_dir]; set runId [dict get $ws run_id]
    ::HybridCore::progressUpdate $progressStart "Mesh Seam Weld" "Exporting $mode path data..." 1
    set paths [::MeshSeamWeld::exportHybridInputs $dir $runId $mode $sourceNodes $candidateNodes $closedLoop]; ::HybridCore::clearTaskOutputs $dir
    set resultPath [file join $dir result.hmwfr]
    ::HybridCore::setProgressRange [expr {$progressStart+0.12*($progressEnd-$progressStart)}] $progressEnd "Mesh Seam Weld" "Python $mode path analysis"
    ::HybridCore::runPythonEntry [file join $MODULE_DIR python main.py] [list --request [dict get $paths request] --mesh [dict get $paths mesh] --existing [dict get $paths existing] --output $resultPath --tcl-output $resultPath --log [file join $dir operation.log]] $dir
    set payload [::HybridCore::loadBinaryResult $resultPath mesh_seam_weld $runId]
    ::HybridCore::progressUpdate $progressEnd "Mesh Seam Weld" "Python $mode path result loaded" 1
    return [dict create payload $payload task_dir $dir run_id $runId]
}

proc ::MeshSeamWeld::runPythonComponentPlan {selectedNodes sourceComponentIds targetComponentIds {progressStart 2.0} {progressEnd 12.0}} {
    variable MODULE_DIR
    set ws [::HybridCore::createTaskWorkspace mesh_seam_weld]
    set dir [dict get $ws task_dir]
    set runId [dict get $ws run_id]
    ::HybridCore::progressUpdate $progressStart "Mesh Seam Weld" "Exporting selected component mesh snapshot..." 1
    set paths [::MeshSeamWeld::exportComponentPlanInputs \
        $dir $runId $selectedNodes $sourceComponentIds $targetComponentIds]
    ::HybridCore::clearTaskOutputs $dir
    set resultPath [file join $dir result.hmwfr]
    ::HybridCore::setProgressRange [expr {$progressStart + 1.0}] $progressEnd \
        "Mesh Seam Weld" "Python is planning component weld paths"
    ::HybridCore::runPythonEntry [file join $MODULE_DIR python main.py] \
        [list --request [dict get $paths request] --mesh [dict get $paths mesh] \
            --existing [dict get $paths existing] --output $resultPath \
            --tcl-output $resultPath --log [file join $dir operation.log]] $dir
    set payload [::HybridCore::loadBinaryResult $resultPath mesh_seam_weld $runId]
    ::HybridCore::progressUpdate $progressEnd "Mesh Seam Weld" "Binary component weld plan loaded" 1
    return [dict create payload $payload task_dir $dir run_id $runId]
}

proc ::MeshSeamWeld::runPythonInternalComponentPlan {selectedNode sourceComponentId {progressStart 2.0} {progressEnd 12.0}} {
    variable MODULE_DIR
    set ws [::HybridCore::createTaskWorkspace mesh_seam_weld]
    set dir [dict get $ws task_dir]
    set runId [dict get $ws run_id]
    ::HybridCore::progressUpdate $progressStart "Mesh Seam Weld" \
        "Native FEM export of the internal-node source component..." 1
    set paths [::MeshSeamWeld::exportInternalComponentPlanInputs \
        $dir $runId $selectedNode $sourceComponentId]
    ::HybridCore::clearTaskOutputs $dir
    set resultPath [file join $dir result.hmwfr]
    ::HybridCore::setProgressRange [expr {$progressStart + 1.0}] $progressEnd \
        "Mesh Seam Weld" "Python is finding all closed boundaries"
    ::HybridCore::runPythonEntry [file join $MODULE_DIR python main.py] \
        [list --request [dict get $paths request] --mesh [dict get $paths mesh] \
            --existing [dict get $paths existing] --output $resultPath \
            --tcl-output $resultPath --log [file join $dir operation.log]] $dir
    set payload [::HybridCore::loadBinaryResult $resultPath mesh_seam_weld $runId]
    if {[dict exists $payload performance]} {
        set perf [dict get $payload performance]
        ::HybridCore::log INFO "PERF mesh_seam_weld python_fem read_seconds=[dict get $perf read_seconds] detect_seconds=[dict get $perf detect_seconds]"
    }
    ::HybridCore::progressUpdate $progressEnd "Mesh Seam Weld" \
        "All internal-node component boundaries loaded" 1
    return [dict create payload $payload task_dir $dir run_id $runId]
}
