proc writeStage2Report {path lines} {
    file mkdir [file dirname $path]
    set channel [open $path w]
    foreach line $lines { puts $channel $line }
    close $channel
}

set required {
    HMWF_REPO_ROOT HMWF_STAGE2_TASK_DIR HMWF_STAGE2_INPUT_FEM
    HMWF_STAGE2_RESULT HMWF_STAGE2_RUN_ID HMWF_STAGE2_CRITERIA HMWF_STAGE2_REPORT
}
foreach name $required {
    if {![info exists ::env($name)] || $::env($name) eq ""} { error "$name is required" }
}
set root [file normalize $::env(HMWF_REPO_ROOT)]
set taskDir [file normalize $::env(HMWF_STAGE2_TASK_DIR)]
set reportPath [file normalize $::env(HMWF_STAGE2_REPORT)]
set lines {}

set code [catch {
    source -encoding utf-8 [file join $root modules fem_auto_seam.tcl]
    foreach child {input output state} { file mkdir [file join $taskDir $child] }
    ::HybridCore::openLog [file join $taskDir operation.log]
    ::HybridCore::log INFO "HM2019 end-to-end validation log remains open until task cleanup"
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    ::HWFlow::runHyperMeshIo import [list *feinputwithdata2 "#optistruct/optistruct" [file normalize $::env(HMWF_STAGE2_INPUT_FEM)] 0 0 0 0 0 1 2 1 0]
    *createmark comps 1 all
    set inputComponentIds [lsort -integer -unique [hm_getmark comps 1]]
    *readqualitycriteria [file normalize $::env(HMWF_STAGE2_CRITERIA)]
    set result [::HybridCore::loadBinaryResult [file normalize $::env(HMWF_STAGE2_RESULT)] fem_auto_seam $::env(HMWF_STAGE2_RUN_ID)]
    ::FemAutoSeam::validateBackendTransfer $taskDir $result
    set plans [dict get $result candidates]
    if {![llength $plans]} { error "production result contains no plans" }
    set componentIds $inputComponentIds
    set acceptedIds {}
    foreach plan $plans {
        foreach key {source_component_id target_component_id} {
            if {[dict exists $plan $key]} { lappend componentIds [dict get $plan $key] }
        }
        if {[dict get $plan status] eq "READY"} { lappend acceptedIds [dict get $plan candidate_id] }
    }
    set componentIds [lsort -integer -unique $componentIds]
    set backup [::FemAutoSeam::createOriginalModelBackup $taskDir $::env(HMWF_STAGE2_RUN_ID) $componentIds]
    set backendResultFem [dict get [dict get $result artifacts] backend_result_fem path]
    set execution [::FemAutoSeam::executeAutoPlans $taskDir $plans $backendResultFem $backup]
    if {[dict get $execution succeeded] < 1 || [dict get $execution rolled_back] != 0} {
        error "unexpected execution summary: $execution"
    }
    set expectedCreated 0
    foreach plan $plans {
        if {[dict get $plan status] ne "READY"} { continue }
        incr expectedCreated [llength [concat [dict get $plan replacement_elements] [dict get $plan weld_elements]]]
        # Mother shells are intentionally replaced again by native automesh;
        # only the weld IDs/connectivity remain stable after the batch.
        foreach element [dict get $plan weld_elements] {
            set elementId [dict get $element element_id]
            if {[llength [::HybridCore::existingEntityIds {elems elements} [list $elementId]]] != 1} {
                error "created element is missing: $elementId"
            }
        }
    }
    if {$expectedCreated != [dict get $execution created]} {
        error "created count mismatch: expected=$expectedCreated actual=[dict get $execution created]"
    }
    set finalComponents [::FemAutoSeam::completedComponentIds $componentIds $plans $execution]
    set resultFem [::FemAutoSeam::exportFinalResult $taskDir $::env(HMWF_STAGE2_RUN_ID) $finalComponents]
    foreach artifact [list $backup $resultFem] {
        if {![file isfile $artifact] || [file size $artifact] == 0} { error "end-to-end artifact is missing or empty: $artifact" }
    }
    set retained [::FemAutoSeam::cleanupTaskWorkspace $taskDir]
    if {$retained ne [list before.hm result.fem]} { error "unexpected final task files: $retained" }
    lappend lines "status=PASS"
    lappend lines "succeeded=[dict get $execution succeeded]"
    lappend lines "created=[dict get $execution created]"
    lappend lines "remeshed_elements=[dict get $execution remeshed_elements]"
    lappend lines "rolled_back=[dict get $execution rolled_back]"
    lappend lines "backup_hm=$backup"
    lappend lines "result_fem=$resultFem"
    lappend lines "retained_files=[join $retained ,]"
} errorMessage errorOptions]

if {$code} {
    lappend lines "status=FAIL"
    lappend lines "error=$errorMessage"
    if {[dict exists $errorOptions -errorinfo]} {
        lappend lines "error_info=[string map {\n { | }} [dict get $errorOptions -errorinfo]]"
    }
    writeStage2Report $reportPath $lines
    return -options $errorOptions $errorMessage
}
writeStage2Report $reportPath $lines
