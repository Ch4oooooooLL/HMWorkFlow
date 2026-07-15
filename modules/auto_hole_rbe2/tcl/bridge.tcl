if {![namespace exists ::HybridCore]} {
    source [file join [file dirname [file dirname [file dirname [file normalize [info script]]]]] hybrid_core tcl init.tcl]
}

proc ::AutoHoleRBE2::runPythonRecognition {} {
    variable MODULE_DIR
    set workspace [::HybridCore::createTaskWorkspace auto_hole_rbe2]
    set taskDir [dict get $workspace task_dir]
    set runId [dict get $workspace run_id]
    ::HybridCore::progressUpdate 5.0 "Solid Through-Hole RIGIDS" "Exporting selected solid mesh..." 1
    set paths [::AutoHoleRBE2::exportHybridInputs $taskDir $runId]
    ::HybridCore::clearTaskOutputs $taskDir
    set entry [file join $MODULE_DIR python main.py]
    ::HybridCore::setProgressRange 18.0 68.0 "Solid Through-Hole RIGIDS" "Python surface segmentation and hole evaluation"
    ::HybridCore::runPythonEntry $entry [list \
        --request [dict get $paths request] \
        --mesh [dict get $paths mesh] \
        --existing [dict get $paths existing] \
        --output [file join $taskDir result.json] \
        --tcl-output [file join $taskDir result.tcl] \
        --log [file join $taskDir operation.log]] $taskDir
    set payload [::HybridCore::loadResultSidecar \
        [file join $taskDir result.tcl] ::AutoHoleRBE2::pythonResult \
        auto_hole_rbe2 $runId]
    ::HybridCore::progressUpdate 70.0 "Solid Through-Hole RIGIDS" "Python candidates loaded; validating model entities..." 1
    ::HybridCore::log INFO "result loaded candidates=[llength [dict get $payload candidates]]"
    return [dict create payload $payload task_dir $taskDir run_id $runId]
}
