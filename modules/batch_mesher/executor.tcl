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

proc ::BatchMesher::buildHmbatchCommand {executable scriptPath} {
    # Altair's documented batch examples suppress command-file generation and
    # the user-profile dialog.  The worker loads its OptiStruct profile itself,
    # so allowing that dialog can block HM2022 before the Tcl script starts.
    return [list [file nativename $executable] \
        -nocommand -nouserprofiledialog -tcl [file nativename $scriptPath]]
}

proc ::BatchMesher::runProbeProcess {arguments stdoutPath stderrPath timeoutMs {workingDirectory ""}} {
    set pipeline [concat [list |] $arguments [list 2> $stderrPath]]
    set previousDirectory [pwd]
    set markerExisted [info exists ::env(HMWORKFLOW_BATCH_WORKER)]
    if {$markerExisted} { set previousMarker $::env(HMWORKFLOW_BATCH_WORKER) }
    set ::env(HMWORKFLOW_BATCH_WORKER) 1
    set openCode [catch {
        if {$workingDirectory ne ""} { cd $workingDirectory }
        set channel [open $pipeline r]
    } err opts]
    if {$markerExisted} {
        set ::env(HMWORKFLOW_BATCH_WORKER) $previousMarker
    } else {
        unset ::env(HMWORKFLOW_BATCH_WORKER)
    }
    set restoreCode [catch {cd $previousDirectory} restoreError restoreOptions]
    if {$openCode} { return -options $opts $err }
    if {$restoreCode} {
        catch {close $channel}
        return -options $restoreOptions $restoreError
    }
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

proc ::BatchMesher::probeHmbatchExecutable {executable probeDir {criteria ""} {param ""}} {
    variable runtime
    file mkdir $probeDir
    set script [file join $probeDir hmbatch_preflight.tcl]
    set result [file join $probeDir hmbatch_preflight_result.tcl]
    set stdout [file join $probeDir hmbatch_preflight_stdout.log]
    set stderr [file join $probeDir hmbatch_preflight_stderr.log]
    set criteria [string trim $criteria]
    set param [string trim $param]
    set scriptLines [list \
        [list set resultPath [file nativename $result]] \
        [list set criteriaPath [expr {$criteria eq "" ? "" : [file nativename $criteria]}]] \
        [list set paramPath [expr {$param eq "" ? "" : [file nativename $param]}]] \
        {set version ""} \
        {catch {set version [string trim [hm_info -appinfo VERSION]]}} \
        {set executable [info nameofexecutable]} \
        {set specValidation skipped} \
        {set specError ""} \
        {set specErrorInfo ""} \
        {if {$criteriaPath ne "" || $paramPath ne ""} {
            set specCode [catch {
                if {$criteriaPath eq "" || $paramPath eq ""} { error "Both criteria and param paths are required" }
                if {![file isfile $criteriaPath] || ![file readable $criteriaPath]} { error "Criteria file is not readable: $criteriaPath" }
                if {![file isfile $paramPath] || ![file readable $paramPath]} { error "Parameter file is not readable: $paramPath" }
                set templatesDir [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]
                set template [file normalize [file join $templatesDir feoutput optistruct optistruct]]
                if {![file isfile $template]} { error "OptiStruct template is missing: $template" }
                *templatefileset [file nativename $template]
                catch {hm_answernext yes}
                *deletemodel
                *createentity comps name=HMWORKFLOW_SPEC_PREFLIGHT
                *currentcollector comps HMWORKFLOW_SPEC_PREFLIGHT
                set elementSize 8.0
                set paramChannel [open $paramPath r]
                set paramText [read $paramChannel]
                close $paramChannel
                if {[regexp -nocase -line {^[ \t]*element_size(?:[ \t]+|[ \t]*=[ \t]*)([0-9]+(?:[.][0-9]*)?(?:[eE][+-]?[0-9]+)?)} $paramText -> parsedSize] &&
                    [string is double -strict $parsedSize] && $parsedSize > 0} {
                    set elementSize [expr {double($parsedSize)}]
                }
                set planeSize [expr {max(200.0, $elementSize * 25.0)}]
                *surfacemode 4
                *createplane 1 0.0 0.0 1.0 0.0 0.0 0.0
                *surfaceplane 1 $planeSize
                *createmark surfs 1 all
                if {[llength [hm_getmark surfs 1]] == 0} { error "Could not create the specification preflight surface" }
                set release ""
                if {[regexp {(20[0-9][0-9])} $version -> year]} { set release $year }
                if {$release eq "" && [regexp {^19([.]|$)} $version]} { set release 2019 }
                if {$release eq "" && [regexp {^22([.]|$)} $version]} { set release 2022 }
                if {$release ni {2019 2022}} { error "Unsupported HyperMesh release for specification preflight: $version" }
                if {$release eq "2019"} {
                    # HM2019's standalone BatchMesher uses the legacy API.  It
                    # accepts cleanup/holes specifications that *hm_batchmesh2
                    # in the same release can incorrectly reject.
                    set legacyCriteria [string map {\\ /} [file normalize $criteriaPath]]
                    set legacyParam [string map {\\ /} [file normalize $paramPath]]
                    *readqualitycriteria $legacyCriteria
                    *hm_batchmesh 1 $legacyCriteria $legacyParam
                    set selectedApi hm_batchmesh
                } else {
                    *readqualitycriteria [file nativename $criteriaPath]
                    *hm_batchmesh2 surfs 1 1 0 [file nativename $criteriaPath] [file nativename $paramPath]
                    set selectedApi hm_batchmesh2
                }
                *createmark elems 1 all
                if {[llength [hm_getmark elems 1]] == 0} { error "Specification trial mesh created no elements" }
                set specValidation passed
            } specResult specOptions]
            if {$specCode} {
                set specValidation failed
                set specError $specResult
                if {[dict exists $specOptions -errorinfo]} { set specErrorInfo [dict get $specOptions -errorinfo] }
            }
        }} \
        {set payload [dict create version $version executable $executable working_directory [pwd] batchmesh [expr {[llength [info commands *hm_batchmesh]] > 0}] batchmesh2 [expr {[llength [info commands *hm_batchmesh2]] > 0}] selected_api [expr {[info exists selectedApi] ? $selectedApi : ""}] spec_validation $specValidation spec_error $specError spec_error_info $specErrorInfo]} \
        {set ch [open $resultPath w]} \
        {fconfigure $ch -encoding utf-8 -translation lf} \
        {puts -nonewline $ch $payload} \
        {close $ch}]
    set scriptText [join $scriptLines "\n"]
    ::HWFlow::writeTextFile $script $scriptText
    set command [::BatchMesher::buildHmbatchCommand $executable $script]
    ::BatchMesher::log INFO "hmbatch preflight command=$command working_directory=$probeDir"
    if {[catch {
        set probeOutput [::BatchMesher::runProbeProcess $command $stdout $stderr 90000 $probeDir]
    } probeError probeOptions]} {
        error "HMBATCH_PREFLIGHT_FAILED: $probeError; command=$command; stdout=$stdout; stderr=$stderr"
    }
    if {![file isfile $result] || [file size $result] == 0} {
        error "HMBATCH_PREFLIGHT_NO_RESULT: hmbatch exited without sourcing Tcl; command=$command; stdout=$stdout; stderr=$stderr"
    }
    set payload [string trim [::HWFlow::readTextFile $result]]
    if {$payload eq "" || [catch {dict size $payload}]} {
        error "HMBATCH_PREFLIGHT_INVALID_RESULT: $result"
    }
    set version [dict get $payload version]
    set year [::BatchMesher::supportedHyperMeshYear $version]
    if {$year ni {2019 2022}} {
        error "HMBATCH_PREFLIGHT_UNSUPPORTED_VERSION: $version; result=$result"
    }
    set requiredApi [expr {$year == 2019 ? "batchmesh" : "batchmesh2"}]
    if {![dict exists $payload $requiredApi] || ![dict get $payload $requiredApi]} {
        error "HMBATCH_PREFLIGHT_API_MISSING: *hm_$requiredApi; version=$version; result=$result"
    }
    if {[dict exists $payload spec_validation] && [dict get $payload spec_validation] eq "failed"} {
        set nativeOutput [string trim [::HWFlow::readTextFile $stdout]]
        set nativeError [string trim [::HWFlow::readTextFile $stderr]]
        if {$nativeError ne ""} { append nativeOutput "\n" $nativeError }
        if {[string length $nativeOutput] > 3000} {
            set nativeOutput [string range $nativeOutput end-2999 end]
        }
        error "HMBATCH_PREFLIGHT_SPEC_INVALID: [dict get $payload spec_error]; criteria=$criteria; param=$param; details=[dict get $payload spec_error_info]; native_output=$nativeOutput; result=$result; stdout=$stdout; stderr=$stderr"
    }
    set runtime(validated_hmbatch_path) [file normalize $executable]
    set runtime(validated_hmbatch_mtime) [file mtime $executable]
    set runtime(validated_hmbatch_version) $version
    set runtime(validated_hmbatch_executable) [dict get $payload executable]
    if {$criteria ne "" && $param ne ""} {
        set runtime(validated_criteria_path) [file normalize $criteria]
        set runtime(validated_criteria_mtime) [file mtime $criteria]
        set runtime(validated_criteria_size) [file size $criteria]
        set runtime(validated_param_path) [file normalize $param]
        set runtime(validated_param_mtime) [file mtime $param]
        set runtime(validated_param_size) [file size $param]
    } else {
        set runtime(validated_criteria_path) ""
        set runtime(validated_param_path) ""
    }
    ::BatchMesher::log INFO "hmbatch preflight passed version=$version executable=[dict get $payload executable] working_directory=[dict get $payload working_directory]"
    return $payload
}

proc ::BatchMesher::hmbatchPreflightCurrent {executable criteria param} {
    variable runtime
    set normalized [file normalize $executable]
    set normalizedCriteria [file normalize $criteria]
    set normalizedParam [file normalize $param]
    return [expr {
        $runtime(validated_hmbatch_path) ne "" &&
        [string equal -nocase $runtime(validated_hmbatch_path) $normalized] &&
        $runtime(validated_hmbatch_mtime) == [file mtime $normalized] &&
        $runtime(validated_hmbatch_version) ne "" &&
        $runtime(validated_criteria_path) ne "" &&
        [string equal -nocase $runtime(validated_criteria_path) $normalizedCriteria] &&
        $runtime(validated_criteria_mtime) == [file mtime $normalizedCriteria] &&
        $runtime(validated_criteria_size) == [file size $normalizedCriteria] &&
        $runtime(validated_param_path) ne "" &&
        [string equal -nocase $runtime(validated_param_path) $normalizedParam] &&
        $runtime(validated_param_mtime) == [file mtime $normalizedParam] &&
        $runtime(validated_param_size) == [file size $normalizedParam]
    }]
}

proc ::BatchMesher::testHmbatchStartup {} {
    variable runtime
    set config [::BatchMesher::validateRunConfig]
    set executable [dict get $config hmbatch]
    set criteria [dict get $config criteria]
    set param [dict get $config param]
    if {$runtime(running)} { error [::BatchMesher::txt "任务正在运行，不能启动探针。" "Tasks are running; the probe cannot start."] }
    ::BatchMesher::createRunWorkspace
    set probeDir $runtime(run_dir)
    ::BatchMesher::log INFO "hmbatch startup probe executable=$executable"
    if {[catch {set payload [::BatchMesher::probeHmbatchExecutable $executable $runtime(run_dir) $criteria $param]} err opts]} {
        catch {::HybridCore::finalizeTaskWorkspace $probeDir FAILED}
        set runtime(run_dir) ""
        error [::BatchMesher::txt "hmbatch 真实启动测试失败：$err" "Real hmbatch startup test failed: $err"]
    }
    catch {::HybridCore::finalizeTaskWorkspace $probeDir SUCCESS}
    set runtime(run_dir) ""
    return $payload
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

# Use the native contract for the running release. HM2019's standalone
# BatchMesher uses *hm_batchmesh; HM2022 uses *hm_batchmesh2. No generated
# parameters are passed, so the user's criteria/param and washer rules remain.
proc ::BatchMesher::runBatchMesherNative {surfaceIds criteriaPath paramPath {release ""}} {
    if {$release eq ""} { set release [::BatchMesher::supportedHyperMeshYear [::BatchMesher::hmVersion]] }
    ::BatchMesher::markSurfaces 1 $surfaceIds
    if {$release eq "2019"} {
        if {[llength [info commands *hm_batchmesh]] == 0} { error "HyperMesh command *hm_batchmesh is unavailable" }
        set legacyCriteria [string map {\\ /} [file normalize $criteriaPath]]
        set legacyParam [string map {\\ /} [file normalize $paramPath]]
        uplevel #0 [list *readqualitycriteria $legacyCriteria]
        set api *hm_batchmesh
        set command [list *hm_batchmesh 1 $legacyCriteria $legacyParam]
    } else {
        if {[llength [info commands *hm_batchmesh2]] == 0} { error "HyperMesh command *hm_batchmesh2 is unavailable" }
        set api *hm_batchmesh2
        set command [list *hm_batchmesh2 surfs 1 1 0 [file nativename $criteriaPath] [file nativename $paramPath]]
    }
    set code [catch {uplevel #0 $command} result opts]
    catch {*clearmark surfs 1}
    if {$code} {
        set detail $result
        if {[dict exists $opts -errorinfo]} { append detail "\n" [dict get $opts -errorinfo] }
        return -options $opts "$api failed; surfaces=[llength $surfaceIds]; criteria=$criteriaPath; param=$paramPath; Tcl error=$detail"
    }
    return $result
}

proc ::BatchMesher::runBatchMesher {surfaceIds criteriaPath paramPath} {
    return [::BatchMesher::runBatchMesherNative $surfaceIds $criteriaPath $paramPath]
}
proc ::BatchMesher::runBatchMesher2019 {surfaceIds criteriaPath paramPath} {
    return [::BatchMesher::runBatchMesherNative $surfaceIds $criteriaPath $paramPath 2019]
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
    ::HWFlow::progressOpen [::BatchMesher::ctxt "BatchMesher 自动网格划分" "BatchMesher Automatic Meshing"] [::BatchMesher::ctxt "正在顺序执行连通域任务" "Running connectivity-group tasks sequentially"] 1
    set total [llength $runtime(tasks)]
    set fatalCode 0
    set fatalError ""
    for {set i 0} {$i < $total} {incr i} {
        if {$runtime(stop_after_current) || [::HWFlow::progressCancelled]} { ::BatchMesher::cancelPendingTasks $i; break }
        set task [lindex $runtime(tasks) $i]
        if {[dict get $task status] eq "completed"} { continue }
        set pct [expr {100.0 * double($i) / double($total)}]
        ::HWFlow::progressUpdate $pct [::BatchMesher::ctxt "正在执行 [dict get $task task_id] / [dict get $task group_id]" "Running [dict get $task task_id] / [dict get $task group_id]"] \
            [::BatchMesher::ctxt "Surfaces：[dict get $task surface_count]；当前原生命令运行期间无法安全中断。" "Surfaces: [dict get $task surface_count]; the active native command cannot be interrupted safely."] 1
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
    ::HWFlow::progressFinish [::BatchMesher::ctxt "任务调度结束。报告：$runtime(run_dir)" "Scheduling finished. Report: $runtime(run_dir)"] 100
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
