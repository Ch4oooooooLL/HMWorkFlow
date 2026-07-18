proc ::HybridCore::sanitizeModuleName {moduleName} {
    if {![regexp {^[a-z][a-z0-9_]*$} $moduleName]} {
        error "Invalid hybrid module name: $moduleName"
    }
    return $moduleName
}

proc ::HybridCore::newRunId {} {
    set milliseconds [clock clicks -milliseconds]
    set suffix [expr {$milliseconds % 10000}]
    return "[clock format [clock seconds] -format {%Y%m%d_%H%M%S}]_[pid]_[format %04d $suffix]"
}

proc ::HybridCore::createTaskWorkspace {moduleName} {
    variable TASK_ROOT
    variable currentRunId
    variable currentTaskDir
    set moduleName [::HybridCore::sanitizeModuleName $moduleName]
    set base [file join $TASK_ROOT $moduleName]
    file mkdir $base
    for {set attempt 0} {$attempt < 100} {incr attempt} {
        set runId [::HybridCore::newRunId]
        if {$attempt > 0} { append runId "_$attempt" }
        set taskDir [file join $base $runId]
        if {![file exists $taskDir]} {
            file mkdir $taskDir
            set currentRunId $runId
            set currentTaskDir $taskDir
            set taskToken [::HybridCore::newTaskToken]
            ::HybridCore::writeTaskMetadata $taskDir RUNNING $taskToken
            ::HybridCore::openLog [file join $taskDir operation.log]
            ::HybridCore::log INFO "workspace created module=$moduleName run_id=$runId task_token=$taskToken"
            return [dict create module $moduleName run_id $runId task_dir $taskDir task_token $taskToken]
        }
    }
    error "Could not create a unique task workspace for $moduleName"
}

proc ::HybridCore::taskFile {taskDir fileName} {
    if {[file tail $fileName] ne $fileName || $fileName in {. ..}} {
        error "Invalid task file name: $fileName"
    }
    return [file join $taskDir $fileName]
}

proc ::HybridCore::clearTaskOutputs {taskDir} {
    foreach fileName {result.json result.tcl result.hmwfr python_stdout.log python_stderr.log comparison.json} {
        set path [::HybridCore::taskFile $taskDir $fileName]
        if {[file exists $path]} { file delete -force $path }
    }
}
