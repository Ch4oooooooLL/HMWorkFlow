if {![namespace exists ::HybridCore]} { source [file join [file dirname [file dirname [file dirname [file normalize [info script]]]]] hybrid_core tcl init.tcl] }
proc ::RB2Bolt::runPythonPlanning {elemIds {progressStart 10.0} {progressEnd 65.0}} {
    variable MODULE_DIR
    set ws [::HybridCore::createTaskWorkspace rbe2_bolt_connector]; set dir [dict get $ws task_dir]; set runId [dict get $ws run_id]
    ::HybridCore::progressUpdate $progressStart "RBE2 Bolt Connector" "Exporting selected RBE2 data to FEM..." 1
    set paths [::RB2Bolt::exportHybridInputs $dir $runId $elemIds]; ::HybridCore::clearTaskOutputs $dir
    set resultPath [file join $dir result.hmwfr]
    ::HybridCore::setProgressRange [expr {$progressStart+0.12*($progressEnd-$progressStart)}] $progressEnd "RBE2 Bolt Connector" "Python RBE2 analysis, grouping and pair planning"
    ::HybridCore::runPythonEntry [file join $MODULE_DIR python main.py] [list --request [dict get $paths request] --mesh [dict get $paths mesh] --delta [dict get $paths delta] --output $resultPath --tcl-output $resultPath --log [file join $dir operation.log]] $dir
    set payload [::HybridCore::loadBinaryResult $resultPath rbe2_bolt_connector $runId]
    ::HybridCore::progressUpdate $progressEnd "RBE2 Bolt Connector" "Incremental FEM generated; preparing same-session import..." 1
    return [dict create payload $payload task_dir $dir run_id $runId]
}
