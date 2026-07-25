set hybridCoreTclDir [file join [file dirname [file dirname [file dirname [file normalize [info script]]]]] hybrid_core tcl]
if {![namespace exists ::HybridCore]} {
    source -encoding utf-8 [file join $hybridCoreTclDir init.tcl]
} else {
    # Reload the incremental importer when this module script is run again in
    # an existing HyperMesh session, so importer fixes do not require restart.
    source -encoding utf-8 [file join $hybridCoreTclDir incremental_import.tcl]
}
unset hybridCoreTclDir

proc ::RB2W::runPythonRecognition {compIds {progressStart 10.0} {progressEnd 60.0}} {
    variable MODULE_DIR
    set workspace [::HybridCore::createTaskWorkspace shell_washer_hole_rbe2]
    set taskDir [dict get $workspace task_dir]
    set runId [dict get $workspace run_id]
    set compCount [llength $compIds]
    ::HybridCore::progressUpdate $progressStart "Shell Washer-Hole RIGIDS" "Exporting $compCount selected components and existing RIGIDS..." 1
    set paths [::RB2W::exportHybridInputs $taskDir $runId $compIds]
    ::HybridCore::clearTaskOutputs $taskDir
    set resultPath [file join $taskDir result.hmwfr]
    ::HybridCore::setProgressRange [expr {$progressStart+0.10*($progressEnd-$progressStart)}] $progressEnd "Shell Washer-Hole RIGIDS" "Python batch free-edge, hole and washer analysis for $compCount components"
    ::HybridCore::runPythonEntry [file join $MODULE_DIR python main.py] [list \
        --request [dict get $paths request] --mesh [dict get $paths manifest] \
        --existing [dict get $paths existing] --delta [dict get $paths delta] --output $resultPath \
        --tcl-output $resultPath --log [file join $taskDir operation.log]] $taskDir
    set payload [::HybridCore::loadBinaryResult $resultPath shell_washer_hole_rbe2 $runId]
    ::HybridCore::progressUpdate $progressEnd "Shell Washer-Hole RIGIDS" "Candidates loaded for $compCount components" 1
    return [dict create payload $payload task_dir $taskDir run_id $runId]
}

proc ::RB2W::runPythonUnusedRBE2Analysis {{progressStart 5.0} {progressEnd 95.0}} {
    variable MODULE_DIR
    set workspace [::HybridCore::createTaskWorkspace shell_washer_hole_rbe2]
    set taskDir [dict get $workspace task_dir]
    set runId [dict get $workspace run_id]

    ::HybridCore::progressUpdate $progressStart \
        [::HWFlow::txt "检测未使用 RBE2" "Find Unused RBE2"] \
        [::HWFlow::txt "正在导出全模型 FEM..." "Exporting the full model FEM..."] 1
    set paths [::RB2W::exportUnusedRBE2Inputs $taskDir $runId]
    ::HybridCore::clearTaskOutputs $taskDir
    set resultPath [file join $taskDir result.hmwfr]

    ::HybridCore::setProgressRange 35.0 $progressEnd \
        [::HWFlow::txt "正在分析 RBE2 中心节点连接关系" "Analyzing RBE2 center-node connectivity"] \
        [::HWFlow::txt "Python 正在扫描全模型 FEM" "Python is scanning the full-model FEM"]
    ::HybridCore::runPythonEntry [file join $MODULE_DIR python unused_rbe2_detector.py] [list \
        --request [dict get $paths request] --mesh [dict get $paths mesh] \
        --output $resultPath --tcl-output $resultPath \
        --log [file join $taskDir operation.log]] $taskDir
    set payload [::HybridCore::loadBinaryResult $resultPath shell_washer_hole_rbe2 $runId]
    ::HybridCore::progressUpdate $progressEnd \
        [::HWFlow::txt "未使用 RBE2 分析完成" "Unused RBE2 analysis finished"] \
        [::HWFlow::txt "正在准备 Delete 面板..." "Preparing the Delete panel..."] 1
    return [dict create payload $payload task_dir $taskDir run_id $runId]
}
