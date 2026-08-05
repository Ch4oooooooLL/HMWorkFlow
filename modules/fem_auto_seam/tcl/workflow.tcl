proc ::FemAutoSeam::jsonSettings {} {
    variable cfg
    set rows {}
    foreach key {search_distance min_seam_length parallel_angle_max perpendicular_angle_min max_distance_variation_ratio near_edge_distance small_hole_diameter max_weld_tria_ratio max_new_failed_elements existing_weld_search_distance auto_accept_confidence review_confidence optimization_layers optimization_iterations} {
        lappend rows "    \"$key\": [::HybridCore::jsonNumber $cfg($key)]"
    }
    lappend rows "    \"optimize_neighborhood\": true"
    foreach key {criteria_path param_path} { lappend rows "    \"$key\": [::HybridCore::jsonString [::FemAutoSeam::effectiveSpecificationPath $key]]" }
    return [join $rows ,\n]
}

proc ::FemAutoSeam::writeRequest {path runId mode componentIds {acceptedIds {}}} {
    set extra ""
    if {$mode eq "plan"} {
        set extra ",\n  \"accepted_candidate_ids\": [::HybridCore::jsonStringArray $acceptedIds],\n[::HybridCore::incrementalModelStateJson]"
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"fem_auto_seam\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": [::HybridCore::jsonIntArray $componentIds],\n  \"settings\": {\n    \"mode\": \"$mode\",\n[::FemAutoSeam::jsonSettings]\n  }$extra,\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile $path $json]
}

proc ::FemAutoSeam::currentModelPath {} {
    # HM2019 hmbatch can terminate natively when hm_getfilename is queried
    # immediately after *writefile.  The immutable backup path and run ID are
    # authoritative; an optional source filename is therefore left blank.
    return ""
}

proc ::FemAutoSeam::createOriginalModelBackup {taskDir runId componentIds} {
    set backup [file join $taskDir before.hm]
    ::FemAutoSeam::saveAutoSnapshot $backup
    return $backup
}

proc ::FemAutoSeam::pathWithinTask {path taskDir} {
    set child [string trimright [string map {\\ /} [file normalize $path]] /]
    set parent [string trimright [string map {\\ /} [file normalize $taskDir]] /]
    if {$child eq $parent} { return 0 }
    return [expr {[string first "${parent}/" "${child}/"] == 0}]
}

proc ::FemAutoSeam::validateBackendTransfer {taskDir result} {
    if {![dict exists $result transfer status] || [dict get $result transfer status] ne "READY_FOR_HYPERMESH_IMPORT"} {
        error "Python result is not ready for HyperMesh import"
    }
    if {![dict exists $result artifacts]} { error "Python result contains no artifact manifest" }
    set artifacts [dict get $result artifacts]
    foreach key {backend_result_fem backend_result_manifest combined_delta_fem delta_manifest creation_plan optimization_report transfer_manifest} {
        if {![dict exists $artifacts $key path]} { error "Python result is missing artifact '$key'" }
        set path [file normalize [dict get $artifacts $key path]]
        if {![::FemAutoSeam::pathWithinTask $path $taskDir]} { error "Python artifact is outside the task workspace: $path" }
        if {![file isfile $path] || [file size $path] == 0} { error "Python artifact is missing or empty: $path" }
        if {[dict exists $artifacts $key bytes] && [file size $path] != [dict get $artifacts $key bytes]} {
            error "Python artifact size changed after creation: $path"
        }
    }
    foreach plan [dict get $result candidates] {
        if {[dict get $plan status] ne "READY"} { continue }
        if {![dict exists $plan delta_fem]} { error "ready candidate [dict get $plan candidate_id] has no delta FEM" }
        set delta [file normalize [dict get $plan delta_fem]]
        if {![::FemAutoSeam::pathWithinTask $delta $taskDir] || ![file isfile $delta] || [file size $delta] == 0} {
            error "candidate delta FEM is invalid: $delta"
        }
    }
    return $artifacts
}

proc ::FemAutoSeam::completedComponentIds {selected plans execution} {
    set successful [dict create]
    foreach row [dict get $execution results] {
        if {[dict get $row status] eq "CREATED"} { dict set successful [dict get $row candidate_id] 1 }
    }
    set ids $selected
    foreach plan $plans {
        if {![dict exists $successful [dict get $plan candidate_id]]} { continue }
        if {[dict exists $plan output_component_id]} { lappend ids [dict get $plan output_component_id] }
    }
    return [lsort -integer -unique $ids]
}

proc ::FemAutoSeam::writeCompletionManifest {taskDir runId backup inputBundle planned review execution finalBundle} {
    set finalFem ""; set finalManifest ""
    if {$finalBundle ne ""} {
        set finalFem [dict get $finalBundle fem]
        set finalManifest [dict get $finalBundle manifest]
    }
    set imported {}
    foreach plan [dict get $planned candidates] {
        if {[dict get $plan status] eq "READY" && [dict exists $plan delta_fem]} {
            lappend imported [dict get $plan delta_fem]
        }
    }
    set transfer [dict get $planned transfer]
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"fem_auto_seam\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"status\": \"COMPLETED\",\n  \"original_model_backup\": [::HybridCore::jsonString $backup],\n  \"input_fem\": [::HybridCore::jsonString [dict get $inputBundle fem]],\n  \"input_manifest\": [::HybridCore::jsonString [dict get $inputBundle manifest]],\n  \"backend_transfer_manifest\": [::HybridCore::jsonString [dict get $transfer manifest]],\n  \"backend_result_fem\": [::HybridCore::jsonString [dict get [dict get $planned artifacts] backend_result_fem path]],\n  \"imported_delta_fems\": [::HybridCore::jsonStringArray $imported],\n  \"review_state\": [::HybridCore::jsonString [file join $taskDir state review_state.json]],\n  \"execution_report\": [::HybridCore::jsonString [file join $taskDir output execution_report.json]],\n  \"completed_fem\": [::HybridCore::jsonString $finalFem],\n  \"completed_fem_manifest\": [::HybridCore::jsonString $finalManifest],\n  \"summary\": {\"accepted\": [llength [dict get $review accepted_ids]], \"succeeded\": [dict get $execution succeeded], \"rolled_back\": [dict get $execution rolled_back], \"created_shells\": [dict get $execution created], \"moved_nodes\": [dict get $execution moved_nodes]}\n}\n"
    set path [file join $taskDir output completion_manifest.json]
    ::HybridCore::writeTextFile $path $json
    return $path
}

proc ::FemAutoSeam::runPython {taskDir runId mode manifest existing componentIds {acceptedIds {}}} {
    variable MODULE_DIR
    set request [::FemAutoSeam::writeRequest [file join $taskDir input request.json] $runId $mode $componentIds $acceptedIds]
    set result [file join $taskDir output result.hmwfr]
    catch {file delete -force $result}
    ::HybridCore::runPythonEntry [file join $MODULE_DIR python main.py] \
        [list --request $request --mesh $manifest --existing $existing --output $result --tcl-output $result --log [file join $taskDir output operation.log]] $taskDir
    return [::HybridCore::loadBinaryResult $result fem_auto_seam $runId]
}

proc ::FemAutoSeam::writeReviewState {taskDir review} {
    set decisions {}
    if {[dict exists $review decisions]} {
        foreach id [lsort [dict keys [dict get $review decisions]]] {
            lappend decisions "    [::HybridCore::jsonString $id]: [::HybridCore::jsonString [dict get [dict get $review decisions] $id]]"
        }
    }
    ::HybridCore::writeTextFile [file join $taskDir state review_state.json] \
        "{\n  \"schema_version\": \"1.0\",\n  \"accepted_candidate_ids\": [::HybridCore::jsonStringArray [dict get $review accepted_ids]],\n  \"candidate_decisions\": {\n[join $decisions ,\n]\n  }\n}\n"
}

proc ::FemAutoSeam::writeExecutionReport {taskDir execution} {
    set rows {}
    foreach result [dict get $execution results] {
        set extra ""
        foreach key {source_component_id target_component_id output_component_id created_elements deleted_mother_elements created_mother_elements created_weld_elements created_nodes moved_nodes} {
            if {[dict exists $result $key]} { append extra ", \"$key\": [dict get $result $key]" }
        }
        if {[dict exists $result candidate_type]} { append extra ", \"candidate_type\": [::HybridCore::jsonString [dict get $result candidate_type]]" }
        if {[dict exists $result confidence]} { append extra ", \"confidence\": [::HybridCore::jsonNumber [dict get $result confidence]]" }
        if {[dict exists $result delta_fem]} { append extra ", \"delta_fem\": [::HybridCore::jsonString [dict get $result delta_fem]]" }
        if {[dict exists $result error]} { append extra ", \"error\": [::HybridCore::jsonString [dict get $result error]]" }
        lappend rows "    {\"candidate_id\": [::HybridCore::jsonString [dict get $result candidate_id]], \"status\": [::HybridCore::jsonString [dict get $result status]]$extra}"
    }
    ::HybridCore::writeTextFile [file join $taskDir output execution_report.json] \
        "{\n  \"schema_version\": \"1.0\",\n  \"summary\": {\"created\": [dict get $execution created], \"succeeded\": [dict get $execution succeeded], \"rolled_back\": [dict get $execution rolled_back], \"moved_nodes\": [dict get $execution moved_nodes]},\n  \"results\": \[\n[join $rows ,\n]\n  \]\n}\n"
}

proc ::FemAutoSeam::workflowProgressOpen {message} {
    variable workflowProgressOpened
    set workflowProgressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        catch {set workflowProgressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "FEM 自动焊缝" "FEM Automatic Seam"] $message 0]}
    }
    return $workflowProgressOpened
}

proc ::FemAutoSeam::workflowProgressUpdate {percent message {detail ""}} {
    variable workflowProgressOpened
    if {[info exists workflowProgressOpened] && $workflowProgressOpened &&
        [llength [info commands ::HWFlow::progressUpdate]] > 0} {
        catch {::HWFlow::progressUpdate $percent $message $detail 1}
    }
}

proc ::FemAutoSeam::workflowProgressClose {message {percent 100.0}} {
    variable workflowProgressOpened
    if {[info exists workflowProgressOpened] && $workflowProgressOpened &&
        [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose $message $percent}
    }
    set workflowProgressOpened 0
}

proc ::FemAutoSeam::runWorkflowLegacy {} {
    variable cfg
    set componentIds [::FemAutoSeam::pickComponents]
    if {[llength $componentIds] < 2} {
        tk_messageBox -icon info -message [::HWFlow::txt "至少需要选择两个壳网格 Component。" "Select at least two shell components."]
        return
    }
    ::FemAutoSeam::workflowProgressOpen [::HWFlow::txt "正在准备任务..." "Preparing the task..."]
    ::FemAutoSeam::workflowProgressUpdate 2.0 [::HWFlow::txt "正在加载质量标准" "Loading quality criteria"]
    # The native post-import quality guard always runs, even when Python-side
    # neighborhood optimization is disabled.  Therefore criteria must always
    # be initialized before any candidate is applied.
    set criteriaPath [::FemAutoSeam::effectiveSpecificationPath criteria_path]
    if {[catch {uplevel #0 [list *readqualitycriteria $criteriaPath]} error]} {
        ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "质量标准加载失败" "Quality criteria loading failed"] 100.0
        tk_messageBox -icon error -message [::HWFlow::txt "HyperMesh 读取 criteria 失败：$error" "HyperMesh could not read criteria: $error"]
        return
    }
    set workspace [::HybridCore::createTaskWorkspace fem_auto_seam]
    set taskDir [dict get $workspace task_dir]; set runId [dict get $workspace run_id]
    foreach child {input output state} { file mkdir [file join $taskDir $child] }
    if {[catch {
        ::FemAutoSeam::workflowProgressUpdate 6.0 [::HWFlow::txt "正在备份原始模型" "Backing up the original model"]
        set originalBackup [::FemAutoSeam::createOriginalModelBackup $taskDir $runId $componentIds]
        ::FemAutoSeam::workflowProgressUpdate 13.0 [::HWFlow::txt "正在导出所选 Component" "Exporting selected Components"] [::HWFlow::txt "共 [llength $componentIds] 个 Component" "[llength $componentIds] Components"]
        set bundle [::FemAutoSeam::exportFemBundle [file join $taskDir input] $runId $componentIds]
        set existing [::FemAutoSeam::writeExistingSeams [file join $taskDir input existing_seams.json]]
        ::FemAutoSeam::workflowProgressUpdate 22.0 [::HWFlow::txt "Python 正在后台检测焊缝" "Python is detecting welds in the background"] [::HWFlow::txt "大型模型可能需要一些时间" "Large models may take some time"]
        set detected [::FemAutoSeam::runPython $taskDir $runId detect [dict get $bundle manifest] $existing $componentIds]
        ::FemAutoSeam::workflowProgressUpdate 48.0 [::HWFlow::txt "正在载入候选结果" "Loading candidate results"]
    } error]} {
        ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "检测失败" "Detection failed"] 100.0
        catch {::HybridCore::finalizeTaskWorkspace $taskDir FAILED}
        tk_messageBox -icon error -message [::HWFlow::txt "FEM 自动焊缝检测失败：$error\n任务目录：$taskDir" "FEM automatic seam detection failed: $error\nTask: $taskDir"]
        return
    }
    set candidates [dict get $detected candidates]
    if {![llength $candidates]} {
        ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "检测完成，未发现候选" "Detection finished; no candidates found"] 100.0
        catch {::HybridCore::finalizeTaskWorkspace $taskDir COMPLETE}
        tk_messageBox -icon info -message [::HWFlow::txt "未检测到焊缝候选。\n任务目录：$taskDir" "No seam candidates were detected.\nTask: $taskDir"]
        return
    }
    ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "检测完成，进入候选复核" "Detection finished; opening candidate review"] 50.0
    set review [::FemAutoSeam::showAutoReview $candidates]
    ::FemAutoSeam::writeReviewState $taskDir $review
    set accepted [dict get $review accepted_ids]
    if {![llength $accepted]} { catch {::HybridCore::finalizeTaskWorkspace $taskDir CANCELLED}; return }
    ::FemAutoSeam::workflowProgressOpen [::HWFlow::txt "正在生成焊缝创建计划..." "Building weld creation plans..."]
    ::FemAutoSeam::workflowProgressUpdate 54.0 [::HWFlow::txt "Python 正在后台生成拆分与连接计划" "Python is building split and connection plans"] [::HWFlow::txt "已接受 [llength $accepted] 个候选" "[llength $accepted] candidates accepted"]
    if {[catch {set planned [::FemAutoSeam::runPython $taskDir $runId plan [dict get $bundle manifest] $existing $componentIds $accepted]} error]} {
        ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "创建计划生成失败" "Creation planning failed"] 100.0
        catch {::HybridCore::finalizeTaskWorkspace $taskDir FAILED}
        tk_messageBox -icon error -message [::HWFlow::txt "创建计划生成失败：$error\n任务目录：$taskDir" "Creation planning failed: $error\nTask: $taskDir"]
        return
    }
    ::FemAutoSeam::workflowProgressUpdate 68.0 [::HWFlow::txt "正在校验后台 FEM" "Validating backend FEM artifacts"]
    if {[catch {::FemAutoSeam::validateBackendTransfer $taskDir $planned} error]} {
        ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "后台 FEM 校验失败" "Backend FEM validation failed"] 100.0
        catch {::HybridCore::finalizeTaskWorkspace $taskDir FAILED}
        tk_messageBox -icon error -message [::HWFlow::txt "后台 FEM 传输校验失败：$error" "Backend FEM transfer validation failed: $error"]
        return
    }
    set plans [dict get $planned candidates]
    set ready 0; foreach plan $plans { if {[dict get $plan status] eq "READY"} { incr ready } }
    if {!$ready} {
        ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "没有可应用的候选" "No applicable candidates"] 100.0
        catch {::HybridCore::finalizeTaskWorkspace $taskDir COMPLETE}
        tk_messageBox -icon warning -message [::HWFlow::txt "没有可自动应用的候选，模型未修改。" "No candidate can be applied automatically; the model was not modified."]
        return
    }
    if {[tk_messageBox -type yesno -icon question -message [::HWFlow::txt "应用 $ready 个 FEM 自动焊缝创建计划？" "Apply $ready FEM automatic seam plans?"]] ne "yes"} { ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "用户取消" "Cancelled by user"] 100.0; catch {::HybridCore::finalizeTaskWorkspace $taskDir CANCELLED}; return }
    ::FemAutoSeam::workflowProgressUpdate 70.0 [::HWFlow::txt "正在逐项导入焊缝 FEM" "Importing weld FEM candidates"]
    if {[catch {set execution [::FemAutoSeam::executeAutoPlans $taskDir $plans $originalBackup 70.0 93.0]} error]} {
        ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "应用失败并已回滚" "Application failed and was rolled back"] 100.0
        catch {::HybridCore::finalizeTaskWorkspace $taskDir FAILED}
        tk_messageBox -icon error -message [::HWFlow::txt "应用失败并已回滚：$error\n任务目录：$taskDir" "Application failed and was rolled back: $error\nTask: $taskDir"]
        return
    }
    ::FemAutoSeam::writeExecutionReport $taskDir $execution
    set finalBundle ""
    if {$cfg(export_completed_fem) && [dict get $execution succeeded] > 0} {
        if {[catch {
            ::FemAutoSeam::workflowProgressUpdate 96.0 [::HWFlow::txt "正在导出完成态 FEM" "Exporting the completed FEM"]
            set finalComponents [::FemAutoSeam::completedComponentIds $componentIds $plans $execution]
            set finalBundle [::FemAutoSeam::exportFemBundle [file join $taskDir output] $runId $finalComponents completed_model]
        } exportError]} {
            tk_messageBox -icon warning -message [::HWFlow::txt "焊缝已创建，但最终 FEM 导出失败：$exportError" "Welds were created, but final FEM export failed: $exportError"]
        }
    }
    set completion [::FemAutoSeam::writeCompletionManifest $taskDir $runId $originalBackup $bundle $planned $review $execution $finalBundle]
    ::HybridCore::finalizeTaskWorkspace $taskDir COMPLETE
    ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "FEM 自动焊缝处理完成" "FEM Automatic Seam finished"] 100.0
    if {[dict get $execution succeeded] > 0} {
        ::FemAutoSeam::registerUndoSnapshot [dict get $execution snapshot] [::HWFlow::txt "最近一次 FEM 自动焊缝批次" "the latest FEM automatic seam batch"]
    }
    tk_messageBox -icon [expr {[dict get $execution rolled_back] ? "warning" : "info"}] -message [::HWFlow::txt \
        "FEM 自动焊缝完成：成功 [dict get $execution succeeded]，回滚 [dict get $execution rolled_back]，移动节点 [dict get $execution moved_nodes]，创建壳单元 [dict get $execution created]。\n任务目录：$taskDir" \
        "FEM automatic seam complete: [dict get $execution succeeded] succeeded, [dict get $execution rolled_back] rolled back, [dict get $execution moved_nodes] nodes moved, [dict get $execution created] shells created.\nTask: $taskDir"]
}

proc ::FemAutoSeam::automaticCandidateIds {candidates} {
    variable cfg
    set result {}
    foreach candidate $candidates {
        if {[::FemAutoSeam::autoCandidateValue $candidate auto_eligible 0] &&
            [::FemAutoSeam::autoCandidateValue $candidate confidence 0.0] >= $cfg(auto_accept_confidence)} {
            lappend result [dict get $candidate candidate_id]
        }
    }
    return $result
}

proc ::FemAutoSeam::pendingCandidatesAfterExecution {candidates execution} {
    set completed [dict create]
    foreach row [dict get $execution results] {
        if {[dict get $row status] eq "CREATED"} {
            dict set completed [dict get $row candidate_id] 1
        }
    }
    set pending {}
    foreach candidate $candidates {
        if {![dict exists $completed [dict get $candidate candidate_id]]} {
            lappend pending $candidate
        }
    }
    return $pending
}

proc ::FemAutoSeam::emptyExecution {backup} {
    return [dict create created 0 succeeded 0 rolled_back 0 moved_nodes 0 results {} snapshot $backup performance {}]
}

proc ::FemAutoSeam::cleanupTaskWorkspace {taskDir} {
    set taskDir [file normalize $taskDir]
    # createTaskWorkspace keeps operation.log open for the lifetime of the
    # task. On Windows that handle prevents deletion and previously converted
    # a successful weld batch into a false export failure followed by rollback.
    if {[llength [info commands ::HybridCore::closeLog]] > 0} {
        catch {::HybridCore::closeLog}
    }
    for {set attempt 0} {$attempt < 4} {incr attempt} {
        set failures {}
        set entries [lsort -unique [concat \
            [glob -nocomplain -directory $taskDir *] \
            [glob -nocomplain -directory $taskDir .*]]]
        foreach entry $entries {
            set name [file tail $entry]
            if {$name in {. .. before.hm result.fem}} { continue }
            if {![::FemAutoSeam::pathWithinTask $entry $taskDir]} {
                error "refusing to clean an artifact outside the FEM automatic seam task: $entry"
            }
            if {[catch {file delete -force $entry} deleteError]} {
                lappend failures "$name: $deleteError"
            }
        }
        if {![llength $failures]} { break }
        after 75
    }
    set remaining {}
    foreach entry [concat [glob -nocomplain -directory $taskDir *] [glob -nocomplain -directory $taskDir .*]] {
        set name [file tail $entry]
        if {$name ni {. ..}} { lappend remaining $name }
    }
    set remaining [lsort -unique $remaining]
    if {$remaining ne [list before.hm result.fem]} {
        error "task cleanup incomplete; retained={$remaining}; delete_errors={$failures}"
    }
    return $remaining
}

proc ::FemAutoSeam::exportFinalResult {taskDir runId componentIds} {
    set bundle [::FemAutoSeam::exportFemBundle $taskDir $runId $componentIds result]
    if {[dict exists $bundle manifest]} { catch {file delete -force [dict get $bundle manifest]} }
    return [dict get $bundle fem]
}

proc ::FemAutoSeam::runWorkflow {} {
    set componentIds [::FemAutoSeam::pickComponents]
    if {[llength $componentIds] < 2} {
        tk_messageBox -icon info -message [::HWFlow::txt "至少需要选择两个壳网格 Component。" "Select at least two shell components."]
        return
    }
    ::FemAutoSeam::workflowProgressOpen [::HWFlow::txt "正在准备任务..." "Preparing the task..."]
    ::FemAutoSeam::workflowProgressUpdate 2.0 [::HWFlow::txt "正在加载质量标准" "Loading quality criteria"]
    set criteriaPath [::FemAutoSeam::effectiveSpecificationPath criteria_path]
    if {[catch {uplevel #0 [list *readqualitycriteria $criteriaPath]} error]} {
        ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "质量标准加载失败" "Quality criteria loading failed"]
        tk_messageBox -icon error -message [::HWFlow::txt "HyperMesh 读取 criteria 失败：$error" "HyperMesh could not read criteria: $error"]
        return
    }

    set workspace [::HybridCore::createTaskWorkspace fem_auto_seam]
    set taskDir [dict get $workspace task_dir]
    set runId [dict get $workspace run_id]
    foreach child {input output state} { file mkdir [file join $taskDir $child] }
    set originalBackup ""
    if {[catch {
        ::FemAutoSeam::workflowProgressUpdate 6.0 [::HWFlow::txt "正在备份原始模型" "Backing up the original model"]
        set originalBackup [::FemAutoSeam::createOriginalModelBackup $taskDir $runId $componentIds]
        ::FemAutoSeam::workflowProgressUpdate 13.0 [::HWFlow::txt "正在导出所选 Component" "Exporting selected Components"] "[llength $componentIds] Components"
        set bundle [::FemAutoSeam::exportFemBundle [file join $taskDir input] $runId $componentIds]
        set existing [::FemAutoSeam::writeExistingSeams [file join $taskDir input existing_seams.json]]
        ::FemAutoSeam::workflowProgressUpdate 22.0 [::HWFlow::txt "Python 正在后台检测焊缝" "Python is detecting welds in the background"] [::HWFlow::txt "大型模型可能需要一些时间" "Large models may take some time"]
        set detected [::FemAutoSeam::runPython $taskDir $runId detect [dict get $bundle manifest] $existing $componentIds]
    } error]} {
        ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "检测失败" "Detection failed"]
        catch {::HybridCore::finalizeTaskWorkspace $taskDir FAILED}
        catch {::FemAutoSeam::cleanupTaskWorkspace $taskDir}
        tk_messageBox -icon error -message [::HWFlow::txt "FEM 自动焊缝检测失败：$error\n已保留任务前备份：$originalBackup" "FEM automatic seam detection failed: $error\nPre-task backup retained: $originalBackup"]
        return
    }

    set candidates [dict get $detected candidates]
    set automaticIds [::FemAutoSeam::automaticCandidateIds $candidates]
    set execution [::FemAutoSeam::emptyExecution $originalBackup]
    set plans {}
    if {[llength $automaticIds]} {
        ::FemAutoSeam::workflowProgressUpdate 50.0 [::HWFlow::txt "Python 正在生成拆分、连接与局部优化计划" "Python is planning splits, connections, and local optimization"] "[llength $automaticIds] automatic candidates"
        if {[catch {
            set planned [::FemAutoSeam::runPython $taskDir $runId plan [dict get $bundle manifest] $existing $componentIds $automaticIds]
            ::FemAutoSeam::validateBackendTransfer $taskDir $planned
            set plans [dict get $planned candidates]
            ::FemAutoSeam::workflowProgressUpdate 70.0 [::HWFlow::txt "正在导入自动创建结果" "Importing automatic weld results"]
            set execution [::FemAutoSeam::executeAutoPlans $taskDir $plans $originalBackup 70.0 92.0]
        } error]} {
            ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "自动创建失败并已回滚" "Automatic creation failed and was rolled back"]
            catch {::FemAutoSeam::restoreAutoSnapshot $originalBackup}
            catch {::HybridCore::finalizeTaskWorkspace $taskDir FAILED}
            catch {::FemAutoSeam::cleanupTaskWorkspace $taskDir}
            tk_messageBox -icon error -message [::HWFlow::txt "自动创建失败并已回滚：$error\n已保留任务前备份：$originalBackup" "Automatic creation failed and was rolled back: $error\nPre-task backup retained: $originalBackup"]
            return
        }
    }

    if {[catch {
        ::FemAutoSeam::workflowProgressUpdate 95.0 [::HWFlow::txt "正在导出任务后结果 FEM" "Exporting the post-task result FEM"]
        set finalComponents [::FemAutoSeam::completedComponentIds $componentIds $plans $execution]
        set resultFem [::FemAutoSeam::exportFinalResult $taskDir $runId $finalComponents]
    } error]} {
        catch {::FemAutoSeam::restoreAutoSnapshot $originalBackup}
        ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "结果导出失败并已回滚" "Result export failed and was rolled back"]
        catch {::HybridCore::finalizeTaskWorkspace $taskDir FAILED}
        catch {::FemAutoSeam::cleanupTaskWorkspace $taskDir}
        tk_messageBox -icon error -message [::HWFlow::txt "结果 FEM 导出失败，模型已回滚：$error" "Result FEM export failed and the model was rolled back: $error"]
        return
    }

    # Export is the end of the model transaction. Cleanup cannot invalidate a
    # successfully created/imported model and must never trigger model rollback.
    ::HybridCore::finalizeTaskWorkspace $taskDir COMPLETE
    set cleanupWarning ""
    if {[catch {::FemAutoSeam::cleanupTaskWorkspace $taskDir} cleanupWarning]} {
        # Keep the successful result and report cleanup separately. Rewriting
        # task.meta here would itself recreate a third file after partial cleanup.
    }

    ::FemAutoSeam::workflowProgressClose [::HWFlow::txt "FEM 自动焊缝处理完成" "FEM Automatic Seam finished"]
    if {[dict get $execution succeeded] > 0} {
        ::FemAutoSeam::registerUndoSnapshot $originalBackup [::HWFlow::txt "最近一次 FEM 自动焊缝批次" "the latest FEM automatic seam batch"]
    }
    set pending [::FemAutoSeam::pendingCandidatesAfterExecution $candidates $execution]
    tk_messageBox -icon [expr {[dict get $execution rolled_back] ? "warning" : "info"}] -message [::HWFlow::txt \
        "FEM 自动焊缝完成：成功 [dict get $execution succeeded]，回滚 [dict get $execution rolled_back]，移动节点 [dict get $execution moved_nodes]，创建壳单元 [dict get $execution created]，待人工处理 [llength $pending]。\n结果：$resultFem" \
        "FEM automatic seam complete: [dict get $execution succeeded] succeeded, [dict get $execution rolled_back] rolled back, [dict get $execution moved_nodes] nodes moved, [dict get $execution created] shells created, [llength $pending] pending manual items.\nResult: $resultFem"]
    if {$cleanupWarning ne ""} {
        tk_messageBox -icon warning -message [::HWFlow::txt \
            "焊缝和结果 FEM 已成功创建，但部分过程文件暂时被占用：$cleanupWarning\n模型不会因此回滚。" \
            "The welds and result FEM were created successfully, but some temporary files are still locked: $cleanupWarning\nThe model was not rolled back."]
    }
    ::FemAutoSeam::showPendingReview $pending
}
