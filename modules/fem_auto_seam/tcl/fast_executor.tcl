proc ::FemAutoSeam::executionRecord {plan status {createdElements 0} {movedNodes 0} {error ""}} {
    set row [dict create candidate_id [dict get $plan candidate_id] status $status]
    foreach key {candidate_type confidence source_component_id target_component_id output_component_id delta_fem} {
        if {[dict exists $plan $key]} { dict set row $key [dict get $plan $key] }
    }
    dict set row created_elements $createdElements
    dict set row moved_nodes $movedNodes
    dict set row deleted_mother_elements [llength [dict get $plan delete_element_ids]]
    dict set row created_mother_elements [llength [dict get $plan replacement_elements]]
    dict set row created_weld_elements [llength [dict get $plan weld_elements]]
    dict set row created_nodes [llength [dict get $plan new_nodes]]
    if {$error ne ""} { dict set row error $error }
    return $row
}

proc ::FemAutoSeam::executeAutoPlans {taskDir plans {taskSnapshot ""} {progressStart 70.0} {progressEnd 93.0}} {
    set taskStarted [clock milliseconds]
    set snapshotMs 0; set nodeMoveMs 0; set deleteMs 0; set importMs 0; set qualityMs 0; set rollbackMs 0
    if {$taskSnapshot eq ""} {
        set taskSnapshot [file join $taskDir state before_auto_shell_seam.hm]
        set phaseStarted [clock milliseconds]
        ::FemAutoSeam::saveAutoSnapshot $taskSnapshot
        incr snapshotMs [expr {[clock milliseconds]-$phaseStarted}]
    } elseif {![file isfile $taskSnapshot] || [file size $taskSnapshot] == 0} {
        error "original model backup is missing or empty: $taskSnapshot"
    }
    set checkpointDir [file join $taskDir state checkpoints]; file mkdir $checkpointDir
    set created 0; set succeeded 0; set rolledBack 0; set moved 0; set index 0; set results {}
    set readyTotal 0
    foreach plan $plans { if {[dict get $plan status] eq "READY"} { incr readyTotal } }
    foreach plan $plans {
        if {[dict get $plan status] ne "READY"} { continue }
        if {[file exists [file join $taskDir state cancel.flag]]} { lappend results [::FemAutoSeam::executionRecord $plan CANCELLED]; break }
        incr index
        set candidateId [dict get $plan candidate_id]
        set candidatePercent [expr {$readyTotal > 0 ? $progressStart + ($progressEnd-$progressStart)*($index-1)/double($readyTotal) : $progressStart}]
        ::FemAutoSeam::workflowProgressUpdate $candidatePercent \
            [::HWFlow::txt "正在应用候选 $index/$readyTotal" "Applying candidate $index/$readyTotal"] \
            "$candidateId | [dict get $plan candidate_type]"
        set checkpoint [file join $checkpointDir [format {%04d_%s_before.hm} $index $candidateId]]
        set planMoved 0
        if {[catch {
            set phaseStarted [clock milliseconds]; ::FemAutoSeam::saveAutoSnapshot $checkpoint; incr snapshotMs [expr {[clock milliseconds]-$phaseStarted}]
            ::FemAutoSeam::validateAutoPlanReferences $plan
            set phaseStarted [clock milliseconds]; set baseline [::FemAutoSeam::autoNativeQualityFailures [dict get $plan read_elements]]; incr qualityMs [expr {[clock milliseconds]-$phaseStarted}]
            if {[file exists [file join $taskDir state cancel.flag]]} { error "cancel requested before candidate mutation" }
            set phaseStarted [clock milliseconds]; set planMoved [::FemAutoSeam::applyAutoPlanMoves $plan]; incr nodeMoveMs [expr {[clock milliseconds]-$phaseStarted}]
            set phaseStarted [clock milliseconds]; ::FemAutoSeam::deleteAutoPlanMotherElements $plan; incr deleteMs [expr {[clock milliseconds]-$phaseStarted}]
            set phaseStarted [clock milliseconds]; set imported [::FemAutoSeam::applyAutoPlanDelta $plan]; incr importMs [expr {[clock milliseconds]-$phaseStarted}]
            set phaseStarted [clock milliseconds]; set verified [::FemAutoSeam::validateAutoCreatedElements [list $plan] $baseline]; incr qualityMs [expr {[clock milliseconds]-$phaseStarted}]
            if {$imported != $verified} { error "created/verified weld count mismatch ($imported/$verified)" }
        } candidateError candidateOptions]} {
            set phaseStarted [clock milliseconds]
            if {[catch {::FemAutoSeam::restoreAutoSnapshot $checkpoint} restoreError]} {
                catch {::FemAutoSeam::restoreAutoSnapshot $taskSnapshot}
                error "$candidateId failed: $candidateError; checkpoint restore failed: $restoreError"
            }
            incr rollbackMs [expr {[clock milliseconds]-$phaseStarted}]
            incr rolledBack; lappend results [::FemAutoSeam::executionRecord $plan ROLLED_BACK 0 $planMoved $candidateError]
            if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
                catch {::HWFlow::progressAppend "$candidateId ROLLED_BACK: $candidateError" 1}
            }
            if {[file exists [file join $taskDir state cancel.flag]]} { break }
            continue
        }
        incr moved $planMoved; incr created $verified; incr succeeded; lappend results [::FemAutoSeam::executionRecord $plan CREATED $verified $planMoved]
        ::FemAutoSeam::workflowProgressUpdate \
            [expr {$progressStart + ($progressEnd-$progressStart)*$index/double(max($readyTotal,1))}] \
            [::HWFlow::txt "候选 $index/$readyTotal 已完成" "Candidate $index/$readyTotal completed"] \
            "$candidateId | created=$verified"
    }
    catch {::HWFlow::refreshBrowser}
    set totalMs [expr {[clock milliseconds]-$taskStarted}]
    set performance [dict create snapshot_seconds [expr {$snapshotMs/1000.0}] node_move_seconds [expr {$nodeMoveMs/1000.0}] delete_seconds [expr {$deleteMs/1000.0}] import_seconds [expr {$importMs/1000.0}] hm_quality_seconds [expr {$qualityMs/1000.0}] rollback_seconds [expr {$rollbackMs/1000.0}] total_seconds [expr {$totalMs/1000.0}]]
    return [dict create created $created succeeded $succeeded rolled_back $rolledBack moved_nodes $moved results $results snapshot $taskSnapshot performance $performance]
}

