proc ::MeshSeamWeld::autoJsonSettings {} {
    variable cfg
    set rows {}
    foreach key {search_distance min_seam_length min_path_nodes parallel_angle_max perpendicular_angle_min max_distance_variation_ratio existing_path_search_width max_target_path_offset max_node_move max_node_move_ratio max_weld_tria_ratio max_new_failed_elements existing_weld_search_distance auto_accept_confidence review_confidence execution_batch_size weld_mesh_size} { lappend rows "    \"$key\": [::HybridCore::jsonNumber $cfg($key)]" }
    foreach key {allow_target_node_move allow_local_split prefer_quad_weld allow_weld_end_tria quality_guard_enabled} { lappend rows "    \"$key\": [::HybridCore::jsonBool $cfg($key)]" }
    return [join $rows ",\n"]
}

proc ::MeshSeamWeld::writeExistingSeamContext {path} {
    variable cfg
    set rows {}
    if {$cfg(exclude_existing_welds)} {
        foreach componentId [::HybridCore::allComponentIds] {
            set name [::MeshSeamWeld::componentExportName $componentId]
            if {![string match -nocase "SEAM_T*" $name]} { continue }
            foreach elementId [::MeshSeamWeld::componentElementIds $componentId] {
                set center ""
                foreach dataname {center centroid} { if {![catch {set center [hm_getvalue elems id=$elementId dataname=$dataname]}] && [llength $center] >= 3} { break } }
                if {[llength $center] < 3} { continue }
                lappend rows "    {\"element_id\": $elementId, \"component_id\": $componentId, \"component_name\": [::HybridCore::jsonString $name], \"center\": \[[::HybridCore::jsonNumber [lindex $center 0]], [::HybridCore::jsonNumber [lindex $center 1]], [::HybridCore::jsonNumber [lindex $center 2]]\]}"
            }
        }
    }
    return [::HybridCore::writeTextFile $path "{\n  \"schema_version\": \"1.0\",\n  \"seams\": \[\n[join $rows ,\n]\n  \]\n}\n"]
}

proc ::MeshSeamWeld::writeAutoRequest {path runId mode componentIds {acceptedIds {}} {typeOverrides {}} {swapIds {}}} {
    set extra ""
    if {$mode eq "auto_plan"} {
        set overrideRows {}
        foreach id [lsort [dict keys $typeOverrides]] { lappend overrideRows "    [::HybridCore::jsonString $id]: [::HybridCore::jsonString [dict get $typeOverrides $id]]" }
        set overrideJson [join $overrideRows ",\n"]
        set extra ",\n  \"accepted_candidate_ids\": [::HybridCore::jsonStringArray $acceptedIds],\n  \"candidate_type_overrides\": {\n$overrideJson\n  },\n  \"candidate_swap_ids\": [::HybridCore::jsonStringArray $swapIds],\n[::HybridCore::incrementalModelStateJson]"
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"mesh_seam_weld\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": [::HybridCore::jsonIntArray $componentIds],\n  \"settings\": {\n    \"mode\": \"$mode\",\n[::MeshSeamWeld::autoJsonSettings]\n  }$extra,\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile $path $json]
}

proc ::MeshSeamWeld::runAutoPython {taskDir runId mode manifest existing componentIds {acceptedIds {}} {typeOverrides {}} {swapIds {}}} {
    variable MODULE_DIR
    set inputDir [file join $taskDir input]; set outputDir [file join $taskDir output]
    set request [::MeshSeamWeld::writeAutoRequest [file join $inputDir request.json] $runId $mode $componentIds $acceptedIds $typeOverrides $swapIds]
    set result [file join $outputDir result.hmwfr]
    catch {file delete -force $result}
    ::HybridCore::runPythonEntry [file join $MODULE_DIR python main.py] [list --request $request --mesh $manifest --existing $existing --output $result --tcl-output $result --log [file join $outputDir operation.log]] $taskDir
    return [::HybridCore::loadBinaryResult $result mesh_seam_weld $runId]
}

proc ::MeshSeamWeld::writeAutoReviewState {taskDir review} {
    set overrideRows {}
    foreach id [lsort [dict keys [dict get $review type_overrides]]] { lappend overrideRows "    [::HybridCore::jsonString $id]: [::HybridCore::jsonString [dict get [dict get $review type_overrides] $id]]" }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"accepted_candidate_ids\": [::HybridCore::jsonStringArray [dict get $review accepted_ids]],\n  \"candidate_type_overrides\": {\n[join $overrideRows ,\n]\n  },\n  \"candidate_swap_ids\": [::HybridCore::jsonStringArray [dict get $review swap_ids]]\n}\n"
    ::HybridCore::writeTextFile [file join $taskDir state review_state.json] $json
}

proc ::MeshSeamWeld::writeAutoExecutionReport {taskDir execution} {
    set resultRows {}
    foreach result [dict get $execution results] {
        set extra ""
        if {[dict exists $result created_elements]} { append extra ", \"created_elements\": [dict get $result created_elements]" }
        if {[dict exists $result error]} { append extra ", \"error\": [::HybridCore::jsonString [dict get $result error]]" }
        lappend resultRows "    {\"candidate_id\": [::HybridCore::jsonString [dict get $result candidate_id]], \"status\": [::HybridCore::jsonString [dict get $result status]]$extra}"
    }
    set performanceRows {}
    dict for {key value} [dict get $execution performance] { lappend performanceRows "    [::HybridCore::jsonString $key]: [::HybridCore::jsonNumber $value]" }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"summary\": {\"created_element_count\": [dict get $execution created], \"succeeded_count\": [dict get $execution succeeded], \"rolled_back_count\": [dict get $execution rolled_back], \"moved_node_count\": [dict get $execution moved_nodes]},\n  \"performance\": {\n[join $performanceRows ,\n]\n  },\n  \"results\": \[\n[join $resultRows ,\n]\n  \]\n}\n"
    ::HybridCore::writeTextFile [file join $taskDir output execution_report.json] $json
}

proc ::MeshSeamWeld::runAutoWorkflow {{preselectedComponents {}}} {
    variable cfg; variable MODULE_DIR
    if {[llength [info commands ::MeshSeamWeld::exportInternalComponentFemBundle]] == 0} {
        ::HWFlow::sourceUtf8 [file join $MODULE_DIR tcl exporter.tcl]
    }
    if {!$cfg(fast_auto_enabled)} { tk_messageBox -icon warning -message [::HWFlow::txt "自动壳焊缝功能已被配置关闭。" "Automatic shell seam is disabled by configuration."]; return }
    if {[llength [info commands ::HWFlow::requireEngineeringContext]] > 0 && [catch {::HWFlow::requireEngineeringContext} preflightError]} {
        tk_messageBox -icon warning -title "HMWorkFlow Preflight" -message $preflightError
        return
    }
    set componentIds $preselectedComponents
    if {[llength $componentIds] < 2} { set componentIds [::MeshSeamWeld::pickComponents] }
    if {[llength $componentIds] < 2} { return }
    set workspace [::HybridCore::createTaskWorkspace mesh_seam_weld]; set taskDir [dict get $workspace task_dir]; set runId [dict get $workspace run_id]
    foreach child {input output state} { file mkdir [file join $taskDir $child] }
    set first [lindex $componentIds 0]; set rest [lrange $componentIds 1 end]
    set bundle [::MeshSeamWeld::exportInternalComponentFemBundle [file join $taskDir input] $runId $first $rest]
    set existing [::MeshSeamWeld::writeExistingSeamContext [file join $taskDir input existing_seams.json]]
    set detected [::MeshSeamWeld::runAutoPython $taskDir $runId auto_detect [dict get $bundle manifest] $existing $componentIds]
    set candidates [dict get $detected candidates]
    if {![llength $candidates]} { tk_messageBox -icon info -message [::HWFlow::txt "未识别到候选焊缝。" "No seam candidates were detected."]; return }
    set review [::MeshSeamWeld::showAutoReview $candidates]
    ::MeshSeamWeld::writeAutoReviewState $taskDir $review
    if {[dict get $review fallback] eq "MANUAL"} { set cfg(run_mode) LEGACY_MANUAL; ::MeshSeamWeld::saveState; after idle ::MeshSeamWeld::runAction; return }
    if {[dict get $review fallback] eq "GEOMETRY"} {
        set loader [file join [file dirname $MODULE_DIR] seam_surface.tcl]
        if {![namespace exists ::SeamSurf] && [file isfile $loader]} { ::HWFlow::sourceUtf8 $loader }
        if {[llength [info commands ::SeamSurf::run]]} { after idle ::SeamSurf::run }
        return
    }
    set accepted [dict get $review accepted_ids]
    if {![llength $accepted]} { return }
    set planned [::MeshSeamWeld::runAutoPython $taskDir $runId auto_plan [dict get $bundle manifest] $existing $componentIds $accepted [dict get $review type_overrides] [dict get $review swap_ids]]
    set plans [dict get $planned candidates]; set ready 0
    foreach plan $plans { if {[dict get $plan status] eq "READY"} { incr ready } }
    if {!$ready} { tk_messageBox -icon warning -message [::HWFlow::txt "已接受项均需人工处理，模型未修改。任务目录：$taskDir" "All accepted candidates require manual handling; the model was not modified. Task: $taskDir"]; return }
    set answer [tk_messageBox -type yesno -icon question -message [::HWFlow::txt "创建计划中有 $ready 项可直接创建。是否应用？" "$ready creation plans are ready. Apply them now?"]]
    if {$answer ne "yes"} { return }
    if {[catch {set execution [::MeshSeamWeld::executeAutoPlans $taskDir $plans]} err]} { tk_messageBox -icon error -message [::HWFlow::txt "自动壳焊缝失败并已回滚：$err\n任务目录：$taskDir" "Automatic shell seam failed and was rolled back: $err\nTask: $taskDir"]; return }
    ::MeshSeamWeld::writeAutoExecutionReport $taskDir $execution
    set created [dict get $execution created]; set succeeded [dict get $execution succeeded]; set rolledBack [dict get $execution rolled_back]; set moved [dict get $execution moved_nodes]
    set icon [expr {$rolledBack ? "warning" : "info"}]
    tk_messageBox -icon $icon -message [::HWFlow::txt "自动壳焊缝完成：成功 $succeeded 项，回滚 $rolledBack 项，移动 $moved 个节点，创建 $created 个壳单元。\n任务目录：$taskDir" "Automatic shell seam finished: $succeeded succeeded, $rolledBack rolled back, $moved nodes moved, $created shell elements created.\nTask: $taskDir"]
}

proc ::MeshSeamWeld::openAutoCandidate {pairData} {
    set ids [list [dict get [dict get $pairData component_a] id] [dict get [dict get $pairData component_b] id]]
    ::MeshSeamWeld::runAutoWorkflow $ids
}
