if {![namespace exists ::HybridCore]} { source [file join [file dirname [file dirname [file dirname [file normalize [info script]]]]] hybrid_core tcl init.tcl] }
proc ::MeshSeamWeld::runPythonPathStage {mode sourceNodes candidateNodes closedLoop {progressStart 10.0} {progressEnd 60.0}} {
    variable MODULE_DIR
    set ws [::HybridCore::createTaskWorkspace mesh_seam_weld]; set dir [dict get $ws task_dir]; set runId [dict get $ws run_id]
    ::HybridCore::progressUpdate $progressStart "Mesh Seam Weld" "Exporting $mode path data..." 1
    set paths [::MeshSeamWeld::exportHybridInputs $dir $runId $mode $sourceNodes $candidateNodes $closedLoop]; ::HybridCore::clearTaskOutputs $dir
    ::HybridCore::setProgressRange [expr {$progressStart+0.12*($progressEnd-$progressStart)}] $progressEnd "Mesh Seam Weld" "Python $mode path analysis"
    ::HybridCore::runPythonEntry [file join $MODULE_DIR python main.py] [list --request [dict get $paths request] --mesh [dict get $paths mesh] --existing [dict get $paths existing] --output [file join $dir result.json] --tcl-output [file join $dir result.tcl] --log [file join $dir operation.log]] $dir
    set payload [::HybridCore::loadResultSidecar [file join $dir result.tcl] ::MeshSeamWeld::pythonResult mesh_seam_weld $runId]
    ::HybridCore::progressUpdate $progressEnd "Mesh Seam Weld" "Python $mode path result loaded" 1
    return [dict create payload $payload task_dir $dir run_id $runId]
}
