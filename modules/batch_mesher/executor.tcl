proc ::BatchMesher::hmVersion {} {
    set version ""
    catch {set version [string trim [hm_info -appinfo VERSION]]}
    return $version
}

proc ::BatchMesher::supportedHyperMeshYear {version} {
    if {[llength [info commands ::HWFlow::hyperWorksYear]] > 0} {
        return [::HWFlow::hyperWorksYear $version]
    }
    if {[regexp {(20[0-9][0-9])} $version -> year]} { return $year }
    if {[regexp {^22([.]|$)} $version]} { return 2022 }
    if {[regexp {^19([.]|$)} $version]} { return 2019 }
    if {[regexp {(^|[^0-9])(19|22)([.][0-9]+)*([^0-9]|$)} $version -> before release patch after]} {
        return [expr {$release eq "19" ? 2019 : 2022}]
    }
    return ""
}

proc ::BatchMesher::requireSupportedHyperMesh {} {
    variable ui
    set version [::BatchMesher::hmVersion]
    if {$version eq ""} { error [::BatchMesher::txt "无法读取 HyperMesh 版本。" "Could not read the HyperMesh version."] }
    set year [::BatchMesher::supportedHyperMeshYear $version]
    if {$year ni {2019 2022}} { error [::BatchMesher::txt "本功能仅支持 HyperMesh 2019 或 2022；当前版本：$version" "This feature supports HyperMesh 2019 or 2022 only; current version: $version"] }
    set ui(HYPERMESH_VERSION) $year
    return $version
}

# Compatibility alias retained for callers from the original HM2019-only module.
proc ::BatchMesher::requireHm2019 {} { return [::BatchMesher::requireSupportedHyperMesh] }

proc ::BatchMesher::runProbeProcess {arguments stdoutPath stderrPath timeoutMs} {
    set pipeline [concat [list |] $arguments [list 2> $stderrPath]]
    if {[catch {set channel [open $pipeline r]} err opts]} { return -options $opts $err }
    fconfigure $channel -blocking 0 -encoding utf-8
    set output ""
    set started [clock milliseconds]
    set timedOut 0
    while {1} {
        append output [read $channel]
        if {[eof $channel]} { break }
        if {[clock milliseconds] - $started >= $timeoutMs} { set timedOut 1; break }
        catch {update idletasks}
        after 100
    }
    if {$timedOut} {
        set pids [pid $channel]
        if {$::tcl_platform(platform) eq "windows"} {
            foreach processId $pids { catch {exec taskkill.exe /PID $processId /T /F} }
        }
        catch {close $channel}
        ::HWFlow::writeTextFile $stdoutPath $output
        error "hmbatch startup probe timed out after [expr {$timeoutMs / 1000}] seconds"
    }
    set closeCode [catch {close $channel} closeError closeOptions]
    ::HWFlow::writeTextFile $stdoutPath $output
    if {$closeCode} { return -options $closeOptions $closeError }
    return $output
}

proc ::BatchMesher::testHmbatchStartup {} {
    variable runtime
    set executable [::BatchMesher::validateHmbatch 1]
    if {$runtime(running)} { error [::BatchMesher::txt "任务正在运行，不能启动探针。" "Tasks are running; the probe cannot start."] }
    ::BatchMesher::createRunWorkspace
    set probeDir $runtime(run_dir)
    set script [file join $runtime(run_dir) hmbatch_probe.tcl]
    set result [file join $runtime(run_dir) hmbatch_probe_result.txt]
    set stdout [file join $runtime(run_dir) hmbatch_probe_stdout.log]
    set stderr [file join $runtime(run_dir) hmbatch_probe_stderr.log]
    set scriptText [join [list \
        "set ch \[open [list [file nativename $result]] w\]" \
        {set version ""} \
        {catch {set version [hm_info -appinfo VERSION]}} \
        {puts $ch $version} \
        {close $ch} \
        {exit}] "\n"]
    ::HWFlow::writeTextFile $script $scriptText
    ::BatchMesher::log INFO "hmbatch startup probe executable=$executable"
    if {[catch {::BatchMesher::runProbeProcess [list [file nativename $executable] -tcl [file nativename $script]] $stdout $stderr 60000} err opts]} {
        catch {::HybridCore::finalizeTaskWorkspace $probeDir FAILED}
        set runtime(run_dir) ""
        error [::BatchMesher::txt "hmbatch 测试启动失败：$err；日志：$stderr" "hmbatch startup probe failed: $err; log: $stderr"]
    }
    if {![file isfile $result]} {
        catch {::HybridCore::finalizeTaskWorkspace $probeDir FAILED}
        set runtime(run_dir) ""
        error [::BatchMesher::txt "hmbatch 已退出但未生成探针结果；请查看日志：$stderr" "hmbatch exited without a probe result; see: $stderr"]
    }
    set version [string trim [::HWFlow::readTextFile $result]]
    set year [::BatchMesher::supportedHyperMeshYear $version]
    if {$year ni {2019 2022}} {
        catch {::HybridCore::finalizeTaskWorkspace $probeDir FAILED}
        set runtime(run_dir) ""
        error [::BatchMesher::txt "所选 hmbatch 不是受支持的 HyperMesh 2019/2022：$version" "The selected hmbatch is not a supported HyperMesh 2019/2022 executable: $version"]
    }
    catch {::HybridCore::finalizeTaskWorkspace $probeDir SUCCESS}
    set runtime(run_dir) ""
    return $version
}

proc ::BatchMesher::saveBackup {} {
    variable runtime
    set path [file join $runtime(run_dir) model_before_batchmesh.hm]
    if {[file exists $path]} { file delete -force $path }
    catch {hm_answernext yes}
    if {[catch {uplevel #0 [list *writefile [file nativename $path] 1]} err opts]} {
        return -options $opts [::BatchMesher::txt "自动备份失败：$err" "Automatic backup failed: $err"]
    }
    if {![file isfile $path] || [file size $path] == 0} { error [::BatchMesher::txt "HyperMesh 未生成有效备份文件。" "HyperMesh did not create a valid backup file."] }
    ::BatchMesher::log INFO "model backup=$path"
    return $path
}

# Official documented command contract: entity_type, mark_id, string_array=1,
# number_of_strings=0, criteria_file, param_file.  No generated parameters are
# passed, so the user's criteria/param (including washer rules) remain in force.
proc ::BatchMesher::runBatchMesherNative {surfaceIds criteriaPath paramPath} {
    if {[llength [info commands *hm_batchmesh2]] == 0} { error "HyperMesh command *hm_batchmesh2 is unavailable" }
    ::BatchMesher::markSurfaces 1 $surfaceIds
    set command [list *hm_batchmesh2 surfs 1 1 0 [file nativename $criteriaPath] [file nativename $paramPath]]
    set code [catch {uplevel #0 $command} result opts]
    catch {*clearmark surfs 1}
    if {$code} {
        set detail $result
        if {[dict exists $opts -errorinfo]} { append detail "\n" [dict get $opts -errorinfo] }
        return -options $opts "*hm_batchmesh2 failed; surfaces=[llength $surfaceIds]; criteria=$criteriaPath; param=$paramPath; Tcl error=$detail"
    }
    return $result
}

proc ::BatchMesher::runBatchMesher {surfaceIds criteriaPath paramPath} {
    return [::BatchMesher::runBatchMesherNative $surfaceIds $criteriaPath $paramPath]
}
proc ::BatchMesher::runBatchMesher2019 {surfaceIds criteriaPath paramPath} {
    return [::BatchMesher::runBatchMesherNative $surfaceIds $criteriaPath $paramPath]
}

proc ::BatchMesher::replaceTask {index task} {
    variable runtime
    set runtime(tasks) [lreplace $runtime(tasks) $index $index $task]
    catch {::BatchMesher::refreshUi}
}

proc ::BatchMesher::executeTaskAt {index config} {
    variable runtime
    set task [lindex $runtime(tasks) $index]
    set ids [dict get $task surface_ids]
    set groupId [dict get $task group_id]
    set taskId [dict get $task task_id]
    set startedMs [clock milliseconds]
    dict set task status running
    dict set task started_at [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}]
    dict set task ended_at ""
    dict set task error_message ""
    ::BatchMesher::replaceTask $index $task
    set logPath [::BatchMesher::taskLog $task INFO "started surfaces=[llength $ids] criteria=[dict get $config criteria] param=[dict get $config param]"]
    dict set task log_path $logPath
    set code [catch {
        set existing [::BatchMesher::existingSurfaceIds $ids]
        if {[llength $existing] != [llength $ids]} {
            error "MODEL_STATE_STALE task=$taskId group=$groupId expected_surfaces=[llength $ids] existing_surfaces=[llength $existing]"
        }
        ::BatchMesher::runBatchMesherNative $ids [dict get $config criteria] [dict get $config param]
    } err opts]
    set endedMs [clock milliseconds]
    dict set task ended_at [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}]
    dict set task elapsed_seconds [format %.3f [expr {($endedMs-$startedMs)/1000.0}]]
    if {$code} {
        set detail $err
        if {[dict exists $opts -errorinfo]} { append detail "\n" [dict get $opts -errorinfo] }
        dict set task status failed
        dict set task error_message $detail
        ::BatchMesher::taskLog $task ERROR "failed surfaces=[llength $ids] Tcl_error=$detail; suggestion=verify the HyperMesh release, criteria/param compatibility, license and surface topology"
    } else {
        dict set task status completed
        ::BatchMesher::taskLog $task INFO "completed elapsed_seconds=[dict get $task elapsed_seconds]"
    }
    ::BatchMesher::replaceTask $index $task
    ::BatchMesher::writeRunReport 0
    if {$code} { return -options $opts $err }
    return $task
}

proc ::BatchMesher::cancelPendingTasks {fromIndex} {
    variable runtime
    set count [llength $runtime(tasks)]
    for {set i $fromIndex} {$i < $count} {incr i} {
        set task [lindex $runtime(tasks) $i]
        if {[dict get $task status] eq "pending"} { dict set task status cancelled; ::BatchMesher::replaceTask $i $task }
    }
}

proc ::BatchMesher::requestStop {} {
    variable runtime
    if {$runtime(running) && $runtime(background_pid) ne "" && [llength [info commands ::BatchMesher::terminateBackgroundRun]] > 0} {
        return [::BatchMesher::terminateBackgroundRun]
    }
    set runtime(stop_after_current) 1
    catch {::HWFlow::progressRequestCancel}
    ::BatchMesher::log WARN "stop requested; the active in-session BatchMesher command cannot be interrupted safely"
}

proc ::BatchMesher::runTasks {} {
    variable runtime
    variable ui
    ::BatchMesher::requireSupportedHyperMesh
    set config [::BatchMesher::validateRunConfig]
    ::BatchMesher::verifyAnalysisFresh
    if {[llength $runtime(tasks)] == 0} { error [::BatchMesher::txt "没有可运行任务；请恢复至少一个被排除的连通域。" "No runnable tasks; restore at least one excluded group."] }
    if {[llength [::BatchMesher::modelPath]] == 0} { error [::BatchMesher::txt "当前模型尚未保存，请先保存模型。" "The current model is unsaved; save it first."] }
    ::BatchMesher::saveCurrentPreset
    ::BatchMesher::createRunWorkspace
    set runtime(stop_after_current) 0
    ::BatchMesher::writeRunReport 0
    if {$ui(AUTO_BACKUP) && [catch {::BatchMesher::saveBackup} backupError backupOptions]} {
        set runtime(run_finished_ms) [clock milliseconds]
        set runtime(run_error) $backupError
        ::BatchMesher::log ERROR $backupError
        ::BatchMesher::writeRunReport 1
        catch {::HybridCore::finalizeTaskWorkspace $runtime(run_dir) FAILED}
        return -options $backupOptions $backupError
    }
    foreach warning [dict get $config warnings] { ::BatchMesher::log WARN $warning }
    set runtime(running) 1
    ::HWFlow::progressOpen [::BatchMesher::txt "BatchMesher 自动网格划分" "BatchMesher Automatic Meshing"] [::BatchMesher::txt "正在顺序执行连通域任务" "Running connectivity-group tasks sequentially"] 1
    set total [llength $runtime(tasks)]
    set fatalCode 0
    set fatalError ""
    for {set i 0} {$i < $total} {incr i} {
        if {$runtime(stop_after_current) || [::HWFlow::progressCancelled]} { ::BatchMesher::cancelPendingTasks $i; break }
        set task [lindex $runtime(tasks) $i]
        if {[dict get $task status] eq "completed"} { continue }
        set pct [expr {100.0 * double($i) / double($total)}]
        ::HWFlow::progressUpdate $pct [::BatchMesher::txt "正在执行 [dict get $task task_id] / [dict get $task group_id]" "Running [dict get $task task_id] / [dict get $task group_id]"] \
            [::BatchMesher::txt "Surfaces：[dict get $task surface_count]；当前原生命令运行期间无法安全中断。" "Surfaces: [dict get $task surface_count]; the active native command cannot be interrupted safely."] 1
        set code [catch {::BatchMesher::executeTaskAt $i $config} err opts]
        if {$code && ([string match "MODEL_STATE_STALE*" $err] || !$ui(CONTINUE_AFTER_FAILURE))} {
            set fatalCode 1
            set fatalError $err
            ::BatchMesher::cancelPendingTasks [expr {$i+1}]
            break
        }
    }
    set runtime(running) 0
    set runtime(run_finished_ms) [clock milliseconds]
    ::BatchMesher::writeRunReport 1
    set workspaceStatus SUCCESS
    foreach finishedTask $runtime(tasks) {
        if {[dict get $finishedTask status] eq "failed"} { set workspaceStatus FAILED; break }
        if {[dict get $finishedTask status] eq "cancelled"} { set workspaceStatus CANCELLED }
    }
    catch {::HybridCore::finalizeTaskWorkspace $runtime(run_dir) $workspaceStatus}
    ::HWFlow::progressFinish [::BatchMesher::txt "任务调度结束。报告：$runtime(run_dir)" "Scheduling finished. Report: $runtime(run_dir)"] 100
    set ui(status_text) [::BatchMesher::txt "运行结束；报告：$runtime(run_dir)" "Run finished; report: $runtime(run_dir)"]
    ::BatchMesher::refreshUi
    if {$fatalCode} { error $fatalError }
    return $runtime(tasks)
}

proc ::BatchMesher::retryTask {taskId} {
    variable runtime
    if {$runtime(running)} { error [::BatchMesher::txt "任务正在运行。" "Tasks are currently running."] }
    ::BatchMesher::requireSupportedHyperMesh
    set config [::BatchMesher::validateRunConfig]
    ::BatchMesher::verifyAnalysisFresh
    set index -1
    for {set i 0} {$i < [llength $runtime(tasks)]} {incr i} {
        set task [lindex $runtime(tasks) $i]
        if {[dict get $task task_id] eq $taskId && [dict get $task status] in {failed cancelled}} { set index $i; break }
    }
    if {$index < 0} { error [::BatchMesher::txt "请选择失败或已取消的任务。" "Select a failed or cancelled task."] }
    if {$runtime(run_dir) eq ""} { ::BatchMesher::createRunWorkspace }
    ::HybridCore::openLog [file join $runtime(run_dir) run.log]
    set runtime(running) 1
    set code [catch {::BatchMesher::executeTaskAt $index $config} err opts]
    set runtime(running) 0
    set runtime(run_finished_ms) [clock milliseconds]
    ::BatchMesher::writeRunReport 1
    catch {::HybridCore::finalizeTaskWorkspace $runtime(run_dir) [expr {$code ? "FAILED" : "SUCCESS"}]}
    if {$code} { return -options $opts $err }
    return [lindex $runtime(tasks) $index]
}
