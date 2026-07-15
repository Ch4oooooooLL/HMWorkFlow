if {![namespace exists ::HybridCore]} {
    source [file join [file dirname [file dirname [file dirname [file normalize [info script]]]]] hybrid_core tcl init.tcl]
}

proc ::RB2W::runPythonRecognition {compId {progressStart 10.0} {progressEnd 60.0}} {
    variable MODULE_DIR
    set workspace [::HybridCore::createTaskWorkspace shell_washer_hole_rbe2]
    set taskDir [dict get $workspace task_dir]
    set runId [dict get $workspace run_id]
    ::HybridCore::progressUpdate $progressStart "Shell Washer-Hole RIGIDS" "Exporting component $compId mesh and existing RIGIDS..." 1
    set paths [::RB2W::exportHybridInputs $taskDir $runId $compId]
    ::HybridCore::clearTaskOutputs $taskDir
    ::HybridCore::setProgressRange [expr {$progressStart+0.10*($progressEnd-$progressStart)}] $progressEnd "Shell Washer-Hole RIGIDS" "Python free-edge, hole and washer analysis for component $compId"
    ::HybridCore::runPythonEntry [file join $MODULE_DIR python main.py] [list \
        --request [dict get $paths request] --mesh [dict get $paths mesh] \
        --existing [dict get $paths existing] --output [file join $taskDir result.json] \
        --tcl-output [file join $taskDir result.tcl] --log [file join $taskDir operation.log]] $taskDir
    set payload [::HybridCore::loadResultSidecar [file join $taskDir result.tcl] ::RB2W::pythonResult shell_washer_hole_rbe2 $runId]
    ::HybridCore::progressUpdate $progressEnd "Shell Washer-Hole RIGIDS" "Candidates loaded for component $compId" 1
    return [dict create payload $payload task_dir $taskDir run_id $runId]
}
