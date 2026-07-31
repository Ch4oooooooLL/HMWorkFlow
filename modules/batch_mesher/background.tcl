proc ::BatchMesher::optistructExportTemplate {} {
    set candidates {}
    if {![catch {set templatesDir [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]}] && [string trim $templatesDir] ne ""} {
        lappend candidates [file join $templatesDir feoutput optistruct optistruct]
    }
    if {![catch {set executableDir [hm_info -appinfo EXECUTABLEDIR]}] && [string trim $executableDir] ne ""} {
        lappend candidates [file join $executableDir .. .. .. templates feoutput optistruct optistruct]
    }
    foreach candidate $candidates {
        set normalized [file normalize $candidate]
        if {[file isfile $normalized]} { return $normalized }
    }
    error [::BatchMesher::txt "找不到当前 HyperMesh 的 OptiStruct FEM 导出模板。" "Could not locate the OptiStruct FEM export template for the current HyperMesh installation."]
}

proc ::BatchMesher::backgroundProcessAlive {{requestedPid ""}} {
    variable runtime
    set processId $requestedPid
    if {$processId eq ""} { set processId $runtime(background_pid) }
    if {![string is integer -strict $processId] || $processId <= 0} { return 0 }
    if {$::tcl_platform(platform) eq "windows"} {
        if {[catch {set output [exec tasklist.exe /FI "PID eq $processId" /NH]}]} { return 0 }
        # Keep square brackets in a braced Tcl value. In a double-quoted
        # expression, [^0-9] is parsed as command substitution before regexp
        # sees it ("invalid command name ^0-9").
        set processPattern [format {(^|[^0-9])%s([^0-9]|$)} $processId]
        return [expr {[regexp -- $processPattern $output] ? 1 : 0}]
    }
    return [expr {![catch {exec kill -0 $processId}]}]
}

proc ::BatchMesher::writeBackgroundLauncher {workerConfig {launcherDir ""} {workerPath ""}} {
    variable runtime
    variable MODULE_DIR
    if {$launcherDir eq ""} { set launcherDir $runtime(run_dir) }
    if {$workerPath eq ""} { set workerPath [file join $MODULE_DIR background_worker.tcl] }
    file mkdir $launcherDir
    set launcher [file join $launcherDir background_launcher.tcl]
    set worker $workerPath
    # The wrapper must report even syntax/source failures that happen before
    # background_worker.tcl can initialize its own logger.
    set wrapperBody {
set __bm_launch_code [catch {source $__bm_worker} __bm_launch_error __bm_launch_options]
if {$__bm_launch_code} {
    set __bm_detail $__bm_launch_error
    if {[dict exists $__bm_launch_options -errorinfo]} { append __bm_detail "\n" [dict get $__bm_launch_options -errorinfo] }
    set __bm_log [file join [dict get $::BatchMesherWorkerConfig run_dir] launcher_error.log]
    set __bm_ch [open $__bm_log w]
    fconfigure $__bm_ch -encoding utf-8 -translation lf
    puts $__bm_ch $__bm_detail
    close $__bm_ch
    set __bm_state [dict create schema_version 1 overall_status failed current_index -1 \
        total [llength [dict get $::BatchMesherWorkerConfig tasks]] \
        message "Background worker could not be loaded: $__bm_detail" updated_ms [clock milliseconds] \
        tasks [dict get $::BatchMesherWorkerConfig tasks] result_fem [dict get $::BatchMesherWorkerConfig result_fem]]
    set __bm_state_path [dict get $::BatchMesherWorkerConfig state_path]
    set __bm_ch [open $__bm_state_path w]
    fconfigure $__bm_ch -encoding utf-8 -translation lf
    puts -nonewline $__bm_ch $__bm_state
    close $__bm_ch
    return
}
}
    set text [join [list \
        [list set ::BatchMesherWorkerConfig $workerConfig] \
        [list set __bm_worker [file nativename $worker]] \
        $wrapperBody] "\n"]
    ::HWFlow::writeTextFile $launcher $text
    return $launcher
}

proc ::BatchMesher::writeRunCmdMonitor {} {
    variable runtime
    set script [file join $runtime(run_dir) monitor_batchmesher.cmd]
    set statusNative [file nativename $runtime(background_monitor_status_path)]
    set doneNative [file nativename $runtime(background_monitor_done_path)]
    set lines [list \
        {@echo off} \
        {chcp 65001 >nul} \
        {title HMWorkFlow BatchMesher Monitor} \
        "set \"STATUS=$statusNative\"" \
        "set \"DONE=$doneNative\"" \
        {:watch} \
        {cls} \
        {echo ============================================================} \
        {echo  HMWorkFlow BatchMesher - consolidated process monitor} \
        {echo  Closing this window does not stop background workers.} \
        {echo ============================================================} \
        {if exist "%STATUS%" (type "%STATUS%") else (echo Waiting for status...)} \
        {if exist "%DONE%" goto finished} \
        {timeout /t 2 /nobreak >nul} \
        {goto watch} \
        {:finished} \
        {cls} \
        {if exist "%STATUS%" type "%STATUS%"} \
        {echo ------------------------------------------------------------} \
        {echo BatchMesher finished. This window will close automatically.} \
        {timeout /t 3 /nobreak >nul} \
        {exit /b 0}]
    ::HWFlow::writeTextFile $script [join $lines "\n"]
    return $script
}

proc ::BatchMesher::openRunCmdMonitor {} {
    set script [::BatchMesher::writeRunCmdMonitor]
    exec cmd.exe /d /c start "" [file nativename $script] &
    return $script
}

proc ::BatchMesher::writeRunMonitorStatus {{message ""}} {
    variable runtime
    variable ui
    if {$runtime(background_monitor_status_path) eq ""} { return }
    set completed 0; set failed 0; set running 0; set pending 0; set skipped 0
    foreach task $runtime(tasks) {
        switch -- [dict get $task status] {
            completed { incr completed }
            failed { incr failed }
            running { incr running }
            pending { incr pending }
            default { incr skipped }
        }
    }
    set lines [list \
        "Updated: [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]" \
        "Phase: $runtime(background_phase)" \
        "Active HyperMesh PIDs: $runtime(background_pid)" \
        "Worker pool: active=[dict size $runtime(background_active)] target=$ui(PARALLEL_WORKERS) queued=[llength $runtime(background_pending)]" \
        "Tasks: completed=$completed failed=$failed running=$running pending=$pending skipped/cancelled=$skipped" \
        "Message: $message" \
        "Run directory: [file nativename $runtime(run_dir)]"]
    ::HWFlow::writeTextFile $runtime(background_monitor_status_path) [join $lines "\n"]
}

proc ::BatchMesher::tasksForBackground {taskIds} {
    variable runtime
    if {[llength $taskIds] == 0} { return $runtime(tasks) }
    array set wanted {}
    foreach taskId $taskIds { set wanted($taskId) 1 }
    set selected {}
    foreach task $runtime(tasks) {
        if {[info exists wanted([dict get $task task_id])]} {
            dict set task status pending
            dict set task elapsed_seconds ""
            dict set task started_at ""
            dict set task ended_at ""
            dict set task error_message ""
            dict set task warning_message ""
            dict set task packaging_status pending
            dict set task packaging_error ""
            dict set task log_path ""
            lappend selected $task
        }
    }
    return $selected
}

proc ::BatchMesher::startBackgroundRun {{taskIds {}}} {
    variable runtime
    variable ui
    if {$runtime(running)} { error [::BatchMesher::txt "已有 BatchMesher 后台任务正在运行。" "A BatchMesher background run is already active."] }
    ::BatchMesher::requireSupportedHyperMesh
    set runConfig [::BatchMesher::validateRunConfig]
    ::BatchMesher::verifyAnalysisFresh
    if {[llength $runtime(tasks)] == 0} { error [::BatchMesher::txt "没有可运行任务。" "There are no runnable tasks."] }
    if {[llength [::BatchMesher::modelPath]] == 0} { error [::BatchMesher::txt "当前模型尚未保存，请先保存模型。" "The current model is unsaved; save it first."] }
    ::BatchMesher::saveCurrentPreset
    ::BatchMesher::createRunWorkspace
    set backgroundTasks [::BatchMesher::tasksForBackground $taskIds]
    if {[llength $backgroundTasks] == 0} { error [::BatchMesher::txt "没有匹配的后台任务。" "No matching background tasks were found."] }
    set runtime(background_task_ids) {}
    foreach backgroundTask $backgroundTasks { lappend runtime(background_task_ids) [dict get $backgroundTask task_id] }
    if {[llength $taskIds] == 0} {
        set runtime(tasks) $backgroundTasks
    } else {
        foreach retryTask $backgroundTasks {
            for {set i 0} {$i < [llength $runtime(tasks)]} {incr i} {
                if {[dict get [lindex $runtime(tasks) $i] task_id] eq [dict get $retryTask task_id]} {
                    ::BatchMesher::replaceTask $i $retryTask
                    break
                }
            }
        }
    }
    # The snapshot is the immutable input for hmbatch. Saving is the only
    # intentional synchronous model operation in this workflow.
    set snapshot [::BatchMesher::saveBackup]
    set exportTemplate [::BatchMesher::optistructExportTemplate]
    set runtime(background_state_path) [file join $runtime(run_dir) background.state]
    set runtime(result_fem_path) [file join $runtime(run_dir) batchmesh_result.fem]
    set runtime(import_status) pending
    set runtime(imported_result_paths) {}
    set runtime(background_pending) $backgroundTasks
    set runtime(background_active) [dict create]
    set runtime(background_outputs) {}
    set runtime(background_phase) meshing
    set runtime(background_merge_pid) ""
    set runtime(background_merge_launcher_pid) ""
    set runtime(background_merge_dir) ""
    set runtime(background_merge_stdout) ""
    set runtime(background_merge_stderr) ""
    set runtime(background_merge_state_path) ""
    set runtime(background_snapshot) $snapshot
    set runtime(background_executable) [dict get $runConfig hmbatch]
    set runtime(background_criteria) [dict get $runConfig criteria]
    set runtime(background_param) [dict get $runConfig param]
    set runtime(background_criteria_mtime) [file mtime $runtime(background_criteria)]
    set runtime(background_criteria_size) [file size $runtime(background_criteria)]
    set runtime(background_param_mtime) [file mtime $runtime(background_param)]
    set runtime(background_param_size) [file size $runtime(background_param)]
    set runtime(background_export_template) $exportTemplate
    set runtime(background_release) $ui(HYPERMESH_VERSION)
    set runtime(background_monitor_status_path) [file join $runtime(run_dir) monitor_status.txt]
    set runtime(background_monitor_done_path) [file join $runtime(run_dir) monitor.done]
    if {[file exists $runtime(background_monitor_done_path)]} { file delete -force $runtime(background_monitor_done_path) }
    set runtime(background_pid) ""
    set runtime(background_started_ms) [clock milliseconds]
    set runtime(running) 1
    set runtime(stop_after_current) 0
    ::BatchMesher::launchAvailableWorkers
    if {[dict size $runtime(background_active)] == 0} {
        set runtime(running) 0
        set runtime(run_error) "No hmbatch task worker could be started"
        set runtime(run_finished_ms) [clock milliseconds]
        ::BatchMesher::writeRunReport 1
        catch {::HybridCore::finalizeTaskWorkspace $runtime(run_dir) FAILED}
        error [::BatchMesher::txt "没有任何连通域 hmbatch 进程能够启动；请查看各 worker 目录日志。" "No connectivity-group hmbatch worker could be started; inspect each worker directory log."]
    }
    ::BatchMesher::writeRunMonitorStatus "Parallel workers started"
    if {$::tcl_platform(platform) eq "windows" && $ui(SHOW_CMD_WINDOW)} {
        if {[catch {::BatchMesher::openRunCmdMonitor} monitorError]} {
            ::BatchMesher::log WARN "Background workers are running but the consolidated CMD monitor could not be opened: $monitorError"
        }
    }
    ::BatchMesher::writeRunReport 0
    ::HWFlow::progressOpen [::BatchMesher::txt "BatchMesher 后台网格划分" "BatchMesher background meshing"] \
        [::BatchMesher::txt "独立连通域 hmbatch 已并行启动，当前 HyperMesh 可继续响应。" "Independent connectivity-group hmbatch workers are running in parallel; this HyperMesh session remains responsive."] 1
    set ui(status_text) [::BatchMesher::txt "并行 hmbatch 正在运行，PID：$runtime(background_pid)" "Parallel hmbatch workers are running, PIDs: $runtime(background_pid)"]
    ::BatchMesher::refreshUi
    set runtime(background_after) [after $ui(BACKGROUND_POLL_MS) ::BatchMesher::pollBackgroundRunSafely]
    return $runtime(run_dir)
}

proc ::BatchMesher::readBackgroundState {{path ""}} {
    variable runtime
    if {$path eq ""} { set path $runtime(background_state_path) }
    if {$path eq "" || ![file isfile $path]} { return "" }
    if {[catch {set state [string trim [::HWFlow::readTextFile $path]]}]} { return "" }
    if {$state eq "" || [catch {dict size $state}]} { return "" }
    return $state
}

proc ::BatchMesher::setTaskFailed {taskId message} {
    variable runtime
    for {set index 0} {$index < [llength $runtime(tasks)]} {incr index} {
        set task [lindex $runtime(tasks) $index]
        if {[dict get $task task_id] ne $taskId} { continue }
        dict set task status failed
        dict set task ended_at [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}]
        dict set task error_message $message
        ::BatchMesher::replaceTask $index $task
        return
    }
}

proc ::BatchMesher::updateBackgroundPids {} {
    variable runtime
    set pids {}
    dict for {taskId job} $runtime(background_active) {
        set processId [dict get $job actual_pid]
        if {$processId eq ""} { set processId [dict get $job launcher_pid] }
        lappend pids $processId
    }
    if {$runtime(background_merge_pid) ne ""} { lappend pids $runtime(background_merge_pid) }
    set runtime(background_pid) $pids
}

proc ::BatchMesher::launchTaskWorker {task} {
    variable runtime
    variable ui
    set taskId [dict get $task task_id]
    set workerDir [file join $runtime(run_dir) workers $taskId]
    file mkdir $workerDir
    set statePath [file join $workerDir background.state]
    set resultPath [file join $workerDir task_result.fem]
    set modelPath [file join $workerDir task_result.hm]
    set stdoutPath [file join $workerDir hmbatch_stdout.log]
    set stderrPath [file join $workerDir hmbatch_stderr.log]
    set workerConfig [dict create run_dir $workerDir model $runtime(background_snapshot) \
        criteria $runtime(background_criteria) param $runtime(background_param) tasks [list $task] \
        continue_after_failure 1 state_path $statePath result_fem $resultPath \
        output_model $modelPath main_release $runtime(background_release) \
        criteria_mtime $runtime(background_criteria_mtime) criteria_size $runtime(background_criteria_size) \
        param_mtime $runtime(background_param_mtime) param_size $runtime(background_param_size) \
        export_template $runtime(background_export_template) run_log [file join $workerDir hmbatch_worker.log]]
    set launcher [::BatchMesher::writeBackgroundLauncher $workerConfig $workerDir]
    set command [list [file nativename $runtime(background_executable)] -tcl [file nativename $launcher]]
    set launchCode [catch {set pids [exec {*}$command >$stdoutPath 2>$stderrPath &]} launchError]
    set processId [expr {$launchCode || [llength $pids] == 0 ? "" : [lindex $pids 0]}]
    if {$launchCode || ![string is integer -strict $processId] || $processId <= 0} {
        if {!$launchCode} { set launchError "direct hmbatch launch returned no valid PID: $pids" }
        ::BatchMesher::setTaskFailed $taskId "Could not start hmbatch worker: $launchError"
        ::BatchMesher::log ERROR "$taskId worker launch failed: $launchError"
        return 0
    }
    set job [dict create task_id $taskId pid $processId launcher_pid $processId actual_pid "" \
        worker_release "" \
        state_path $statePath result_fem $resultPath result_model $modelPath \
        stdout $stdoutPath stderr $stderrPath worker_dir $workerDir started_ms [clock milliseconds]]
    dict set runtime(background_active) $taskId $job
    ::BatchMesher::log INFO "$taskId independent worker started pid=$processId launcher=$launcher"
    return 1
}

proc ::BatchMesher::launchAvailableWorkers {} {
    variable runtime
    variable ui
    set maximum $ui(PARALLEL_WORKERS)
    while {!$runtime(stop_after_current) && [llength $runtime(background_pending)] > 0 && [dict size $runtime(background_active)] < $maximum} {
        set task [lindex $runtime(background_pending) 0]
        set runtime(background_pending) [lrange $runtime(background_pending) 1 end]
        set launched [::BatchMesher::launchTaskWorker $task]
        if {!$launched && !$ui(CONTINUE_AFTER_FAILURE)} { set runtime(stop_after_current) 1 }
    }
    if {$runtime(stop_after_current) && [llength $runtime(background_pending)] > 0} {
        foreach pendingTask $runtime(background_pending) {
            set taskId [dict get $pendingTask task_id]
            for {set index 0} {$index < [llength $runtime(tasks)]} {incr index} {
                set task [lindex $runtime(tasks) $index]
                if {[dict get $task task_id] ne $taskId} { continue }
                dict set task status skipped
                dict set task error_message "Skipped because further worker launches were stopped"
                ::BatchMesher::replaceTask $index $task
                break
            }
        }
        set runtime(background_pending) {}
    }
    ::BatchMesher::updateBackgroundPids
}

proc ::BatchMesher::releaseWorkerAndRefill {taskId} {
    variable runtime
    variable ui
    if {[dict exists $runtime(background_active) $taskId]} {
        dict unset runtime(background_active) $taskId
    }
    set before [dict size $runtime(background_active)]
    # Refill immediately instead of waiting for every other worker's tasklist
    # probe to finish. This keeps the pool at the configured capacity whenever
    # pending connectivity groups remain.
    ::BatchMesher::launchAvailableWorkers
    set after [dict size $runtime(background_active)]
    ::BatchMesher::log INFO \
        "worker pool slot released task=$taskId active_before_refill=$before active_after_refill=$after target=$ui(PARALLEL_WORKERS) pending=[llength $runtime(background_pending)]"
}

proc ::BatchMesher::mergeWorkerRecords {records} {
    variable runtime
    foreach record $records {
        if {[dict get $record status] eq "running" && [dict exists $record started_ms]} {
            dict set record elapsed_seconds [format %.1f [expr {([clock milliseconds]-[dict get $record started_ms])/1000.0}]]
        }
        set taskId [dict get $record task_id]
        for {set i 0} {$i < [llength $runtime(tasks)]} {incr i} {
            if {[dict get [lindex $runtime(tasks) $i] task_id] eq $taskId} {
                ::BatchMesher::replaceTask $i $record
                break
            }
        }
    }
}

proc ::BatchMesher::backgroundStatusDetail {state} {
    set completed 0; set failed 0; set running 0; set waiting 0; set skipped 0
    foreach task [dict get $state tasks] {
        switch -- [dict get $task status] {
            completed { incr completed }
            failed { incr failed }
            running { incr running }
            skipped - cancelled { incr skipped }
            default { incr waiting }
        }
    }
    return [::BatchMesher::txt \
        "完成：$completed；失败：$failed；运行中：$running；等待：$waiting；跳过/取消：$skipped" \
        "Completed: $completed; failed: $failed; running: $running; waiting: $waiting; skipped/cancelled: $skipped"]
}

proc ::BatchMesher::writeAggregateState {overall message} {
    variable runtime
    set terminal 0
    foreach task $runtime(tasks) { if {[dict get $task status] in {completed failed cancelled skipped}} { incr terminal } }
    set state [dict create schema_version 2 overall_status $overall current_index $terminal \
        total [llength $runtime(tasks)] message $message updated_ms [clock milliseconds] \
        tasks $runtime(tasks) result_fem $runtime(result_fem_path)]
    set temporary "$runtime(background_state_path).tmp"
    ::HWFlow::writeTextFile $temporary $state
    file rename -force $temporary $runtime(background_state_path)
    return $state
}

proc ::BatchMesher::startMergeWorker {} {
    variable runtime
    variable ui
    set completedJobs $runtime(background_outputs)
    if {[llength $completedJobs] == 0} {
        set state [::BatchMesher::writeAggregateState failed "No successful task FEM is available for merge"]
        ::BatchMesher::finishBackgroundRun $state
        return
    }
    set mergeDir [file join $runtime(run_dir) merge]
    file mkdir $mergeDir
    set runtime(background_merge_state_path) [file join $mergeDir merge.state]
    set stdoutPath [file join $mergeDir hmbatch_stdout.log]
    set stderrPath [file join $mergeDir hmbatch_stderr.log]
    set inputs {}
    # A worker HM is a full model snapshot with only the pre-existing elements
    # removed.  Merging a second such snapshot can terminate HM2019 before Tcl
    # can report an error.  Aggregate the independently validated FEM payloads
    # in a blank hmbatch model instead; worker HMs remain recovery artifacts.
    set mergeMode fem
    foreach job $completedJobs {
        lappend inputs [dict get $job result_fem]
    }
    set mergeConfig [dict create run_dir $mergeDir tasks $runtime(tasks) inputs $inputs merge_mode $mergeMode \
        main_release $runtime(background_release) merged_model [file join $mergeDir merged_result.hm] \
        state_path $runtime(background_merge_state_path) result_fem $runtime(result_fem_path) \
        export_template $runtime(background_export_template) run_log [file join $mergeDir hmbatch_merge.log]]
    set mergeWorker [file join $::BatchMesher::MODULE_DIR background_merge_worker.tcl]
    set launcher [::BatchMesher::writeBackgroundLauncher $mergeConfig $mergeDir $mergeWorker]
    set command [list [file nativename $runtime(background_executable)] -tcl [file nativename $launcher]]
    set code [catch {set pids [exec {*}$command >$stdoutPath 2>$stderrPath &]} launchError]
    set processId [expr {$code || [llength $pids] == 0 ? "" : [lindex $pids 0]}]
    if {$code || ![string is integer -strict $processId] || $processId <= 0} {
        if {!$code} { set launchError "merge hmbatch returned no valid PID: $pids" }
        set state [::BatchMesher::writeAggregateState failed "Could not start FEM merge worker: $launchError"]
        ::BatchMesher::finishBackgroundRun $state "Could not start FEM merge worker: $launchError"
        return
    }
    set runtime(background_phase) merging
    set runtime(background_merge_pid) $processId
    set runtime(background_merge_launcher_pid) $processId
    set runtime(background_merge_dir) $mergeDir
    set runtime(background_merge_stdout) $stdoutPath
    set runtime(background_merge_stderr) $stderrPath
    set runtime(background_started_ms) [clock milliseconds]
    ::BatchMesher::updateBackgroundPids
    ::BatchMesher::log INFO "result merge worker started launcher_pid=$processId mode=$mergeMode inputs=[llength $inputs]"
}

proc ::BatchMesher::finishBackgroundRun {state {forcedError ""}} {
    variable runtime
    variable ui
    if {$runtime(background_after) ne ""} { catch {after cancel $runtime(background_after)} }
    set runtime(background_after) ""
    set runtime(background_pid) ""
    set runtime(background_active) [dict create]
    set runtime(background_pending) {}
    set runtime(background_merge_pid) ""
    set runtime(background_merge_launcher_pid) ""
    set runtime(background_phase) finished
    set runtime(running) 0
    set runtime(run_finished_ms) [clock milliseconds]
    if {$state ne "" && [dict exists $state tasks]} { ::BatchMesher::mergeWorkerRecords [dict get $state tasks] }
    set overall failed
    set message $forcedError
    if {$state ne ""} {
        set overall [dict get $state overall_status]
        set message [dict get $state message]
    }
    if {$forcedError ne ""} { set runtime(run_error) $forcedError }
    set outputValid [expr {$runtime(result_fem_path) ne "" && [file isfile $runtime(result_fem_path)] && [file size $runtime(result_fem_path)] > 0}]
    set importSource [::BatchMesher::wholeResultImportPath]
    set importAvailable [expr {$importSource ne ""}]
    set failedTasks 0
    set cancelledTasks 0
    foreach task $runtime(tasks) {
        if {[dict get $task status] eq "failed"} { incr failedTasks }
        if {[dict get $task status] in {cancelled skipped}} { incr cancelledTasks }
    }
    ::BatchMesher::writeRunReport 1
    set workspaceStatus SUCCESS
    if {$overall eq "cancelled" || $cancelledTasks > 0} { set workspaceStatus CANCELLED }
    if {$overall eq "failed" || $failedTasks > 0 || $forcedError ne ""} { set workspaceStatus FAILED }
    catch {::HybridCore::finalizeTaskWorkspace $runtime(run_dir) $workspaceStatus}
    set detail [expr {$state eq "" ? "" : [::BatchMesher::backgroundStatusDetail $state]}]
    if {$importAvailable} {
        set archiveNote ""
        if {!$outputValid} {
            set archiveNote [::BatchMesher::txt "；最终 FEM 归档失败，但原生 FE 合并结果有效" "; final FEM archive failed, but the native merged FE result is valid"]
        }
        set ui(status_text) [::BatchMesher::txt \
            "后台划分和结果合并已结束。$detail$archiveNote。正在自动导入完整结果……" \
            "Background meshing and result merge finished. $detail$archiveNote. Automatically importing the complete result..."]
        ::HWFlow::progressFinish $ui(status_text) 100
    } else {
        set diagnostic ""
        if {$runtime(background_merge_dir) ne ""} {
            set diagnostic [::BatchMesher::txt \
                "；合并日志：[file nativename [file join $runtime(background_merge_dir) hmbatch_merge.log]]；stderr：[file nativename $runtime(background_merge_stderr)]" \
                "; merge log: [file nativename [file join $runtime(background_merge_dir) hmbatch_merge.log]]; stderr: [file nativename $runtime(background_merge_stderr)]"]
        }
        set ui(status_text) [::BatchMesher::txt "后台划分结束，但完整 FEM 或原生合并模型无效：$message$diagnostic" "Background meshing ended without a valid complete FEM or native merged model: $message$diagnostic"]
        ::HWFlow::progressFinish $ui(status_text) 100
    }
    ::BatchMesher::refreshUi
    catch {::BatchMesher::writeRunMonitorStatus $ui(status_text)}
    if {$runtime(background_monitor_done_path) ne ""} {
        catch {::HWFlow::writeTextFile $runtime(background_monitor_done_path) "finished"}
    }
    set completionIcon info
    if {!$importAvailable} { set completionIcon error } elseif {!$outputValid || $failedTasks > 0 || $cancelledTasks > 0} { set completionIcon warning }
    if {$importAvailable} {
        after 100 ::BatchMesher::autoImportBackgroundResult
    } else {
        catch {tk_messageBox -icon $completionIcon -title [::BatchMesher::txt "BatchMesher 后台任务结束" "BatchMesher background run finished"] -message $ui(status_text)}
    }
}

proc ::BatchMesher::pollBackgroundRun {} {
    variable runtime
    variable ui
    if {!$runtime(running)} { return }
    if {[::HWFlow::progressCancelled]} {
        ::BatchMesher::terminateBackgroundRun
        return
    }
    if {$runtime(background_phase) eq "merging"} {
        set state [::BatchMesher::readBackgroundState $runtime(background_merge_state_path)]
        if {$state ne "" && [dict exists $state worker_pid]} {
            set runtime(background_merge_pid) [dict get $state worker_pid]
            ::BatchMesher::updateBackgroundPids
        }
        if {$state ne "" && [dict get $state overall_status] in {completed failed cancelled}} {
            ::BatchMesher::finishBackgroundRun $state
            return
        }
        if {![::BatchMesher::backgroundProcessAlive $runtime(background_merge_pid)] && \
            [clock milliseconds] - $runtime(background_started_ms) >= 10000} {
            set aggregate [::BatchMesher::writeAggregateState failed "FEM merge hmbatch exited before producing a final state"]
            ::BatchMesher::finishBackgroundRun $aggregate "FEM merge hmbatch exited before producing a final state"
            return
        }
        set detail [::BatchMesher::backgroundStatusDetail [dict create tasks $runtime(tasks)]]
        set ui(status_text) [::BatchMesher::txt "网格任务已结束，正在合并最终 FEM……" "Meshing tasks finished; merging the final FEM..."]
        ::BatchMesher::writeRunMonitorStatus $ui(status_text)
        ::HWFlow::progressUpdate 99 $ui(status_text) $detail 1
        ::BatchMesher::refreshUi
        set runtime(background_after) [after $ui(BACKGROUND_POLL_MS) ::BatchMesher::pollBackgroundRunSafely]
        return
    }

    set now [clock milliseconds]
    set sawFailure 0
    # Iterate over a stable key snapshot so a completed slot can be removed and
    # refilled immediately while this polling pass is still in progress.
    foreach taskId [dict keys $runtime(background_active)] {
        if {![dict exists $runtime(background_active) $taskId]} { continue }
        set job [dict get $runtime(background_active) $taskId]
        set state [::BatchMesher::readBackgroundState [dict get $job state_path]]
        set finished 0
        if {$state ne ""} {
            if {[dict exists $state worker_pid]} {
                dict set job actual_pid [dict get $state worker_pid]
                dict set job pid [dict get $state worker_pid]
            }
            if {[dict exists $state hypermesh_release] && [dict get $state hypermesh_release] ne ""} {
                dict set job worker_release [dict get $state hypermesh_release]
            }
            if {[dict exists $state tasks]} { ::BatchMesher::mergeWorkerRecords [dict get $state tasks] }
            set overall [dict get $state overall_status]
            if {$overall in {completed failed cancelled}} {
                set finished 1
                set outputValid [expr {[file isfile [dict get $job result_fem]] && [file size [dict get $job result_fem]] > 0}]
                if {$overall eq "completed" && $outputValid} {
                    lappend runtime(background_outputs) $job
                } else {
                    set currentTask ""
                    foreach candidate $runtime(tasks) { if {[dict get $candidate task_id] eq $taskId} { set currentTask $candidate; break } }
                    if {$currentTask ne "" && [dict get $currentTask status] eq "completed"} {
                        # Packaging is a separate stage. Never rewrite a task
                        # that created mesh elements as a meshing failure.
                        dict set currentTask packaging_status failed
                        set packagingError [dict get $currentTask packaging_error]
                        if {$packagingError eq ""} {
                            set packagingError "Task FEM is missing or empty: [dict get $job result_fem]"
                        }
                        dict set currentTask packaging_error $packagingError
                        for {set taskIndex 0} {$taskIndex < [llength $runtime(tasks)]} {incr taskIndex} {
                            if {[dict get [lindex $runtime(tasks) $taskIndex] task_id] eq $taskId} {
                                ::BatchMesher::replaceTask $taskIndex $currentTask
                                break
                            }
                        }
                        ::BatchMesher::log ERROR "$taskId mesh completed but result packaging failed: $packagingError"
                    } else {
                        set sawFailure 1
                        ::BatchMesher::setTaskFailed $taskId [dict get $state message]
                    }
                }
            }
        }
        if {$finished} {
            if {$sawFailure && !$ui(CONTINUE_AFTER_FAILURE)} { set runtime(stop_after_current) 1 }
            ::BatchMesher::releaseWorkerAndRefill $taskId
            continue
        }
        set alive [::BatchMesher::backgroundProcessAlive [dict get $job launcher_pid]]
        if {[dict get $job actual_pid] ne ""} { set alive [::BatchMesher::backgroundProcessAlive [dict get $job actual_pid]] }
        if {!$alive && $now - [dict get $job started_ms] >= 10000} {
            set sawFailure 1
            ::BatchMesher::setTaskFailed $taskId "hmbatch exited before producing a terminal state; inspect [dict get $job stderr] and [dict get $job stdout]"
            if {!$ui(CONTINUE_AFTER_FAILURE)} { set runtime(stop_after_current) 1 }
            ::BatchMesher::releaseWorkerAndRefill $taskId
            continue
        }
        dict set runtime(background_active) $taskId $job
    }
    if {$sawFailure && !$ui(CONTINUE_AFTER_FAILURE)} { set runtime(stop_after_current) 1 }
    # Also repair any deficit left by a transient launch failure or by a prior
    # polling callback before calculating progress.
    ::BatchMesher::launchAvailableWorkers
    set aggregate [::BatchMesher::writeAggregateState running "Parallel connectivity-group meshing is running"]
    set terminal [dict get $aggregate current_index]
    set total [dict get $aggregate total]
    set pct [expr {$total > 0 ? min(98.0, 98.0 * double($terminal) / double($total)) : 0}]
    set detail [::BatchMesher::backgroundStatusDetail $aggregate]
    set activeCount [dict size $runtime(background_active)]
    set ui(status_text) [::BatchMesher::txt "并行划分中：活动 $activeCount；$detail" "Parallel meshing: active $activeCount; $detail"]
    ::BatchMesher::writeRunMonitorStatus $ui(status_text)
    ::HWFlow::progressUpdate $pct $ui(status_text) $detail 1
    ::BatchMesher::refreshUi
    if {$activeCount == 0 && [llength $runtime(background_pending)] == 0} {
        ::BatchMesher::startMergeWorker
        if {!$runtime(running)} { return }
    }
    set runtime(background_after) [after $ui(BACKGROUND_POLL_MS) ::BatchMesher::pollBackgroundRunSafely]
}

proc ::BatchMesher::pollBackgroundRunSafely {} {
    variable runtime
    variable ui
    if {!$runtime(running)} { return }
    if {[catch {::BatchMesher::pollBackgroundRun} errorMessage errorOptions]} {
        set detail $errorMessage
        if {[dict exists $errorOptions -errorinfo]} { append detail "\n" [dict get $errorOptions -errorinfo] }
        ::BatchMesher::log ERROR "background progress monitor error=$detail"
        set ui(status_text) [::BatchMesher::txt \
            "进度监控暂时出错，后台 hmbatch 不受影响；2 秒后自动重试。错误：$errorMessage" \
            "The progress monitor encountered an error; background hmbatch is unaffected. Retrying in 2 seconds. Error: $errorMessage"]
        catch {::BatchMesher::refreshUi}
        if {$runtime(running)} { set runtime(background_after) [after 2000 ::BatchMesher::pollBackgroundRunSafely] }
    }
}

proc ::BatchMesher::stopLaunchingWorkers {} {
    variable runtime
    variable ui
    if {!$runtime(running) || $runtime(background_phase) ne "meshing"} { return 0 }
    set runtime(stop_after_current) 1
    ::BatchMesher::launchAvailableWorkers
    set ui(status_text) [::BatchMesher::txt "已停止启动后续任务；当前并行任务会继续完成。" "No further tasks will be launched; currently active parallel tasks will finish."]
    ::BatchMesher::refreshUi
    return 1
}

proc ::BatchMesher::terminateBackgroundRun {} {
    variable runtime
    if {!$runtime(running)} { return 0 }
    set pids {}
    dict for {taskId job} $runtime(background_active) {
        foreach key {launcher_pid actual_pid} {
            set processId [dict get $job $key]
            if {$processId ne ""} { lappend pids $processId }
        }
    }
    foreach processId [list $runtime(background_merge_launcher_pid) $runtime(background_merge_pid)] {
        if {$processId ne ""} { lappend pids $processId }
    }
    set pids [lsort -unique $pids]
    set terminated 0
    foreach processId $pids {
        ::BatchMesher::log WARN "terminating background hmbatch process tree pid=$processId"
        if {[::HybridCore::terminateProcessTree $processId]} { incr terminated }
    }
    for {set index 0} {$index < [llength $runtime(tasks)]} {incr index} {
        set task [lindex $runtime(tasks) $index]
        if {[dict get $task status] in {pending running}} {
            dict set task status cancelled
            dict set task error_message "Cancelled by user; background process tree was terminated"
            ::BatchMesher::replaceTask $index $task
        }
    }
    set state [dict create overall_status cancelled current_index -1 total [llength $runtime(tasks)] \
        message "Cancelled by user; process trees=$pids terminated=$terminated" tasks $runtime(tasks)]
    ::BatchMesher::finishBackgroundRun $state
    return $terminated
}

proc ::BatchMesher::retryBackgroundTask {taskId} {
    variable runtime
    if {$runtime(import_status) eq "pending" && $runtime(result_fem_path) ne "" && [file isfile $runtime(result_fem_path)]} {
        error [::BatchMesher::txt "请先导入或另行保存当前结果 FEM，再重试失败任务。" "Import or separately preserve the current result FEM before retrying a failed task."]
    }
    set found 0
    foreach task $runtime(tasks) {
        if {[dict get $task task_id] eq $taskId && [dict get $task status] in {failed cancelled skipped}} { set found 1; break }
    }
    if {!$found} { error [::BatchMesher::txt "请选择失败、取消或跳过的任务。" "Select a failed, cancelled, or skipped task."] }
    return [::BatchMesher::startBackgroundRun [list $taskId]]
}

proc ::BatchMesher::wholeResultImportPath {} {
    variable runtime
    set path ""
    if {$runtime(background_merge_dir) ne ""} {
        set path [file join $runtime(background_merge_dir) merged_result.hm]
    }
    if {$path ne "" && [file isfile $path] && [file size $path] > 0} { return [file normalize $path] }
    return ""
}

proc ::BatchMesher::modelEntityIds {entityType} {
    catch {*clearmark $entityType 2}
    if {[catch {*createmark $entityType 2 all}] || [catch {set ids [hm_getmark $entityType 2]}]} {
        catch {*clearmark $entityType 2}
        return {}
    }
    catch {*clearmark $entityType 2}
    return [lsort -integer -unique $ids]
}

proc ::BatchMesher::idDifference {after before} {
    array set old {}
    foreach id $before { set old($id) 1 }
    set result {}
    foreach id $after { if {![info exists old($id)]} { lappend result $id } }
    return $result
}

proc ::BatchMesher::captureImportEntityState {} {
    set state [dict create]
    foreach entityType {elems nodes comps props mats} {
        dict set state $entityType [::BatchMesher::modelEntityIds $entityType]
    }
    return $state
}

proc ::BatchMesher::importEntityDelta {before} {
    set delta [dict create]
    foreach entityType {elems nodes comps props mats} {
        dict set delta $entityType [::BatchMesher::idDifference \
            [::BatchMesher::modelEntityIds $entityType] [dict get $before $entityType]]
    }
    return $delta
}

proc ::BatchMesher::rollbackImportDelta {delta} {
    if {[llength [info commands ::HybridCore::cleanupIncrementalEntities]] > 0} {
        ::HybridCore::cleanupIncrementalEntities [dict get $delta elems] [dict get $delta nodes] \
            [dict get $delta comps] [dict get $delta props] [dict get $delta mats]
        return
    }
    foreach entityType {elems nodes comps props mats} {
        set ids [dict get $delta $entityType]
        if {[llength $ids] == 0} { continue }
        catch {*clearmark $entityType 1}
        if {![catch {uplevel #0 [linsert $ids 0 *createmark $entityType 1]}]} { catch {*deletemark $entityType 1} }
        catch {*clearmark $entityType 1}
    }
}

proc ::BatchMesher::importWholeResult {path} {
    set before [::BatchMesher::captureImportEntityState]
    # The worker/result HM may retain source geometry metadata. Import FE only;
    # this is the native *mergefile contract and avoids geometry duplication.
    set command [list *mergefile [file nativename $path] 0 1]
    set code [catch {::HWFlow::runHyperMeshIo import $command} errorMessage errorOptions]
    set delta [::BatchMesher::importEntityDelta $before]
    if {$code || [llength [dict get $delta elems]] == 0} {
        ::BatchMesher::rollbackImportDelta $delta
        if {$code} { return -options $errorOptions "complete result import failed: path=$path error=$errorMessage" }
        return -code error "complete result import failed: path=$path error=HyperMesh returned without creating new elements"
    }
    return $delta
}

proc ::BatchMesher::importWholeFemResult {path} {
    set before [::BatchMesher::captureImportEntityState]
    # Use the translator defaults, matching a normal manual OptiStruct import.
    # Passing multiple property-assignment modes together caused HM2019 to
    # accept GRID cards while silently omitting element cards.
    set command [list *feinputwithdata2 "#optistruct/optistruct" \
        [file nativename $path] 0 0 0 0 0 1 0 1 0]
    set code [catch {::HWFlow::runHyperMeshIo import $command} errorMessage errorOptions]
    set delta [::BatchMesher::importEntityDelta $before]
    if {$code || [llength [dict get $delta elems]] == 0} {
        ::BatchMesher::rollbackImportDelta $delta
        if {$code} { return -options $errorOptions "complete FEM fallback import failed: path=$path error=$errorMessage" }
        return -code error "complete FEM fallback import failed: path=$path error=HyperMesh returned without creating new elements"
    }
    return $delta
}

proc ::BatchMesher::autoImportBackgroundResult {} {
    variable runtime
    variable ui
    if {$runtime(import_status) eq "imported"} { return }
    if {[catch {::BatchMesher::importBackgroundResult 1} errorMessage errorOptions]} {
        set runtime(import_status) failed
        set ui(status_text) [::BatchMesher::txt \
            "完整结果自动导入失败：$errorMessage。最终 FEM 和原生合并模型均已保留，可查看日志后手动重试。" \
            "Automatic complete-result import failed: $errorMessage. The final FEM and native merged model were retained for manual retry."]
        ::BatchMesher::log ERROR $ui(status_text)
        ::BatchMesher::writeRunReport 1
        ::BatchMesher::refreshUi
        catch {tk_messageBox -icon error -title [::BatchMesher::txt "自动导入失败" "Automatic import failed"] -message $ui(status_text)}
    }
}

proc ::BatchMesher::importBackgroundResult {{automatic 0}} {
    variable runtime
    variable ui
    if {$runtime(running)} { error [::BatchMesher::txt "后台划分仍在运行，不能导入。" "Background meshing is still running; import is unavailable."] }
    if {$runtime(import_status) eq "imported"} { error [::BatchMesher::txt "该完整结果已经导入。" "This complete result has already been imported."] }
    set path [::BatchMesher::wholeResultImportPath]
    if {$path eq ""} { error [::BatchMesher::txt "没有有效的 BatchMesher 完整结果可导入。" "No valid complete BatchMesher result is available for import."] }
    set failed 0
    set successful 0
    foreach task $runtime(tasks) {
        if {[lsearch -exact $runtime(background_task_ids) [dict get $task task_id]] < 0} { continue }
        if {[dict get $task status] eq "failed"} { incr failed }
        if {[dict get $task status] eq "completed"} { incr successful }
    }
    if {!$automatic} {
        set prompt [::BatchMesher::txt \
            "将一次性导入已经合并的完整网格结果。HyperMesh 会重编号冲突实体，当前模型不会被替换。是否继续？" \
            "Import the already-merged complete mesh result in one operation. HyperMesh will renumber conflicting entities and will not replace the current model. Continue?"]
        if {[tk_messageBox -icon question -type yesno -default no -title [::BatchMesher::txt "导入完整 BatchMesher 结果" "Import complete BatchMesher result"] -message $prompt] ne "yes"} { return 0 }
    }
    set runtime(import_status) importing
    if {[catch {set delta [::BatchMesher::importWholeResult $path]} importError importOptions]} {
        ::BatchMesher::log WARN "native complete result import failed path=$path error=$importError"
        set femPath $runtime(result_fem_path)
        if {$femPath eq "" || ![file isfile $femPath] || [file size $femPath] == 0} {
            set runtime(import_status) failed
            return -options $importOptions $importError
        }
        if {[catch {set delta [::BatchMesher::importWholeFemResult $femPath]} femError femOptions]} {
            set runtime(import_status) failed
            ::BatchMesher::log ERROR "native and complete FEM imports failed native_error=$importError fem_error=$femError"
            error [::BatchMesher::txt \
                "原生合并模型和最终 FEM 均导入失败。原生错误：$importError；FEM 错误：$femError" \
                "Both the native merged model and final FEM import failed. Native error: $importError; FEM error: $femError"]
        }
        set path $femPath
        ::BatchMesher::log INFO "complete FEM fallback import succeeded path=$femPath"
    }
    set imported [llength [dict get $delta elems]]
    set runtime(import_status) imported
    set archiveText [::BatchMesher::txt "最终 FEM 已保留" "final FEM retained"]
    if {$runtime(result_fem_path) eq "" || ![file isfile $runtime(result_fem_path)] || [file size $runtime(result_fem_path)] == 0} {
        set archiveText [::BatchMesher::txt "最终 FEM 归档失败，原生合并模型已保留" "final FEM archive failed; native merged model retained"]
    }
    set ui(status_text) [::BatchMesher::txt \
        "已一次性导入完整网格结果：$imported 个单元；网格失败任务：$failed；$archiveText。" \
        "Imported the complete mesh result in one operation: $imported elements; failed meshing tasks: $failed; $archiveText."]
    ::BatchMesher::log INFO "complete result import finished path=$path elements=$imported mesh_failures=$failed"
    ::BatchMesher::writeRunReport 1
    catch {::HWFlow::refreshBrowser}
    ::BatchMesher::refreshUi
    set icon [expr {$failed > 0 ? "warning" : "info"}]
    catch {tk_messageBox -icon $icon -title [::BatchMesher::txt "完整结果导入完成" "Complete result import finished"] -message $ui(status_text)}
    return $imported
}
