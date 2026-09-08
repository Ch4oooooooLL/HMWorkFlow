proc ::FemAutoSeam::reviewGroupHmascii {path groups} {
    set nextId [::HybridCore::maxEntityId {sets}]
    set rows [list "*filetype(ASCII)" "*version(19.02.0.70)" "BEGIN DATA" "BEGIN SETS"]
    set manifest {}
    foreach group $groups {
        set componentIds [lsort -integer -unique [dict get $group component_ids]]
        if {[llength $componentIds] < 2} { continue }
        incr nextId
        set prefix [expr {[string match "*FAILED*" [dict get $group set_name]] ? \
            "FEM_SEAM_FAILED" : "FEM_SEAM_REVIEW"}]
        set name "${prefix}_$nextId"
        # HM2019 uses the four-field HMASCII set form.  It remains accepted by
        # HM2022, while the newer five-field color form is rejected by 2019.
        lappend rows "*set($nextId,\"$name\",\"comps\",0)"
        foreach componentId $componentIds { lappend rows "*setid($componentId)" }
        lappend manifest [dict create set_id $nextId set_name $name component_ids $componentIds]
    }
    lappend rows "END SETS" "END DATA"
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel [join $rows \n]
    close $channel
    return $manifest
}

proc ::FemAutoSeam::setComponentIds {setId} {
    foreach dataName {ids entitylist componentlist} {
        set values ""
        if {![catch {set values [hm_getvalue sets id=$setId dataname=$dataName]}] && [llength $values]} {
            return [lsort -integer -unique $values]
        }
    }
    return {}
}

proc ::FemAutoSeam::importReviewGroupSets {taskDir groups} {
    if {![llength $groups]} { return [dict create created 0 sets {} path ""] }
    set path [file join $taskDir output potential_component_groups.hmascii]
    set expected [::FemAutoSeam::reviewGroupHmascii $path $groups]
    if {![llength $expected]} { return [dict create created 0 sets {} path $path] }
    foreach row $expected {
        set setId [dict get $row set_id]
        if {[::HybridCore::existingEntityIds {sets} [list $setId]] ne ""} {
            error "review set ID $setId became occupied before HMASCII import"
        }
        foreach componentId [dict get $row component_ids] {
            if {[::HybridCore::existingEntityIds {comps components} [list $componentId]] eq ""} {
                error "review group references missing component $componentId"
            }
        }
    }
    *createstringarray 1 ""
    set reader "#hmascii\\hmascii"
    if {[catch {
        ::HWFlow::runHyperMeshIo import [list *feinputwithdata2 $reader \
            [file nativename $path] 0 0 0 0 0 1 0 1 0]
    } importError importOptions]} {
        error "potential-group HMASCII incremental import failed: $importError; $importOptions"
    }
    foreach row $expected {
        set setId [dict get $row set_id]
        if {[::HybridCore::existingEntityIds {sets} [list $setId]] eq ""} {
            error "HMASCII import did not create review set $setId"
        }
        set actual [::FemAutoSeam::setComponentIds $setId]
        if {[llength $actual] && $actual ne [dict get $row component_ids]} {
            error "review set $setId component mismatch: expected={[dict get $row component_ids]} actual={$actual}"
        }
    }
    return [dict create created [llength $expected] sets $expected path $path]
}

proc ::FemAutoSeam::failedSeedsAsPotentialGroups {trusted execution} {
    set failed {}
    foreach row [dict get $execution results] {
        if {[dict get $row status] ne "CREATED"} { dict set failed [dict get $row candidate_id] 1 }
    }
    set groups {}
    set serial 0
    foreach seed $trusted {
        if {![dict exists $failed [dict get $seed candidate_id]]} { continue }
        incr serial
        lappend groups [dict create group_id "FAILED_$serial" \
            set_name [format "FEM_SEAM_FAILED_%04d" $serial] \
            component_ids [concat [list [dict get $seed source_component_id]] \
                [dict get $seed target_component_ids]] \
            candidate_ids [list [dict get $seed candidate_id]] \
            weld_types [list [dict get $seed weld_type]] \
            reasons [list "trusted seed failed in Mesh Seam Weld execution"]]
    }
    return $groups
}

# Recognition-only FEM workflow.  Python supplies existing-node seeds and
# potential component relations; Mesh Seam Weld exclusively owns creation.
proc ::FemAutoSeam::runWorkflow {} {
    set componentIds [::FemAutoSeam::pickComponents]
    if {[llength $componentIds] < 2} {
        tk_messageBox -icon info -message [::HWFlow::txt \
            "至少需要选择两个壳网格 Component。" \
            "Select at least two shell components."]
        return
    }
    if {[llength [info commands ::MeshSeamWeld::executeSeedJobs]] == 0} {
        tk_messageBox -icon error -message [::HWFlow::txt \
            "网格焊缝的种子执行接口尚未加载。" \
            "The Mesh Seam Weld seed executor is not loaded."]
        return
    }
    ::FemAutoSeam::workflowProgressOpen [::HWFlow::ctxt "正在识别焊缝..." "Detecting weld relations..."]
    set workspace [::HybridCore::createTaskWorkspace fem_auto_seam]
    set taskDir [dict get $workspace task_dir]
    set runId [dict get $workspace run_id]
    foreach child {input output state} { file mkdir [file join $taskDir $child] }
    set backup ""
    if {[catch {
        ::FemAutoSeam::workflowProgressUpdate 8.0 [::HWFlow::ctxt "正在导出所选壳网格" "Exporting selected shell meshes"]
        set bundle [::FemAutoSeam::exportFemBundle [file join $taskDir input] $runId $componentIds]
        set existing [::FemAutoSeam::writeExistingSeams [file join $taskDir input existing_seams.json]]
        ::FemAutoSeam::workflowProgressUpdate 25.0 [::HWFlow::ctxt "Python 正在识别 T 型与贴片焊缝" "Python is recognizing T and patch welds"]
        set detected [::FemAutoSeam::runPython $taskDir $runId detect \
            [dict get $bundle manifest] $existing $componentIds]
        set trusted [dict get $detected trusted_seeds]
        set potential [dict get $detected potential_groups]
        set backup [::FemAutoSeam::createOriginalModelBackup $taskDir $runId $componentIds]
        ::FemAutoSeam::workflowProgressUpdate 55.0 [::HWFlow::ctxt "正在按种子创建可信焊缝" "Creating trusted welds from seeds"] \
            "[llength $trusted] trusted seeds"
        set execution [::MeshSeamWeld::executeSeedJobs $trusted 1]
        set potential [concat $potential [::FemAutoSeam::failedSeedsAsPotentialGroups $trusted $execution]]
        ::FemAutoSeam::workflowProgressUpdate 90.0 [::HWFlow::ctxt "正在增量导入潜在组合 Set" "Incrementally importing potential-group sets"] \
            "[llength $potential] potential groups"
        set imported [::FemAutoSeam::importReviewGroupSets $taskDir $potential]
    } error options]} {
        if {$backup ne "" && [file isfile $backup]} { catch {::FemAutoSeam::restoreAutoSnapshot $backup} }
        ::FemAutoSeam::workflowProgressClose [::HWFlow::ctxt "任务失败并已回滚" "Task failed and was rolled back"]
        catch {::HybridCore::finalizeTaskWorkspace $taskDir FAILED}
        catch {::HybridCore::closeLog}
        tk_messageBox -icon error -message [::HWFlow::txt \
            "FEM 自动焊缝失败：$error\n诊断目录：$taskDir" \
            "FEM Automatic Seam failed: $error\nDiagnostics: $taskDir"]
        return
    }
    ::HybridCore::finalizeTaskWorkspace $taskDir COMPLETE
    catch {::HybridCore::closeLog}
    if {[dict get $execution succeeded] > 0 || [dict get $imported created] > 0} {
        ::FemAutoSeam::registerUndoSnapshot $backup [::HWFlow::txt \
            "最近一次 FEM 自动焊缝批次" "the latest FEM automatic seam batch"]
    }
    catch {::HWFlow::refreshBrowser}
    ::FemAutoSeam::workflowProgressClose [::HWFlow::ctxt "FEM 自动焊缝完成" "FEM Automatic Seam finished"]
    tk_messageBox -icon [expr {[dict get $execution failed] ? "warning" : "info"}] -message [::HWFlow::txt \
        "识别完成：可信种子 [llength $trusted]；创建成功 [dict get $execution succeeded]，失败 [dict get $execution failed]；潜在组合 Set [dict get $imported created]。\n潜在组合已按组保存在 FEM_SEAM_REVIEW_* / FEM_SEAM_FAILED_* Set 中，可删除 Set 或据此手动创建焊缝。" \
        "Recognition complete: [llength $trusted] trusted seeds; [dict get $execution succeeded] created and [dict get $execution failed] failed; [dict get $imported created] potential-group sets.\nPotential relations are stored as FEM_SEAM_REVIEW_* / FEM_SEAM_FAILED_* sets for deletion or manual weld creation."]
}
