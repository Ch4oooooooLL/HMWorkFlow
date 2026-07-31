proc ::MeshSeamWeld::executeAutoPlans {taskDir plans} {
    set taskStarted [clock milliseconds]
    set snapshotMs 0; set nodeMoveMs 0; set deleteMs 0; set importMs 0; set qualityMs 0; set rollbackMs 0
    set taskSnapshot [file join $taskDir state before_auto_shell_seam.hm]
    set phaseStarted [clock milliseconds]
    ::MeshSeamWeld::saveAutoSnapshot $taskSnapshot
    incr snapshotMs [expr {[clock milliseconds]-$phaseStarted}]
    set checkpointDir [file join $taskDir state checkpoints]; file mkdir $checkpointDir
    set created 0; set succeeded 0; set rolledBack 0; set moved 0; set index 0; set results {}
    foreach plan $plans {
        if {[dict get $plan status] ne "READY"} { continue }
        if {[file exists [file join $taskDir state cancel.flag]]} { lappend results [dict create candidate_id [dict get $plan candidate_id] status CANCELLED]; break }
        incr index
        set candidateId [dict get $plan candidate_id]
        set checkpoint [file join $checkpointDir [format {%04d_%s_before.hm} $index $candidateId]]
        set planMoved 0
        if {[catch {
            set phaseStarted [clock milliseconds]; ::MeshSeamWeld::saveAutoSnapshot $checkpoint; incr snapshotMs [expr {[clock milliseconds]-$phaseStarted}]
            ::MeshSeamWeld::validateAutoPlanReferences $plan
            set phaseStarted [clock milliseconds]; set baseline [::MeshSeamWeld::autoNativeQualityFailures [dict get $plan read_elements]]; incr qualityMs [expr {[clock milliseconds]-$phaseStarted}]
            if {[file exists [file join $taskDir state cancel.flag]]} { error "cancel requested before candidate mutation" }
            set phaseStarted [clock milliseconds]; set planMoved [::MeshSeamWeld::applyAutoPlanMoves $plan]; incr nodeMoveMs [expr {[clock milliseconds]-$phaseStarted}]
            set phaseStarted [clock milliseconds]; ::MeshSeamWeld::deleteAutoPlanMotherElements $plan; incr deleteMs [expr {[clock milliseconds]-$phaseStarted}]
            set phaseStarted [clock milliseconds]; set imported [::MeshSeamWeld::applyAutoPlanDelta $plan]; incr importMs [expr {[clock milliseconds]-$phaseStarted}]
            set phaseStarted [clock milliseconds]; set verified [::MeshSeamWeld::validateAutoCreatedElements [list $plan] $baseline]; incr qualityMs [expr {[clock milliseconds]-$phaseStarted}]
            if {$imported != $verified} { error "created/verified weld count mismatch ($imported/$verified)" }
        } candidateError candidateOptions]} {
            set phaseStarted [clock milliseconds]
            if {[catch {::MeshSeamWeld::restoreAutoSnapshot $checkpoint} restoreError]} {
                catch {::MeshSeamWeld::restoreAutoSnapshot $taskSnapshot}
                error "$candidateId failed: $candidateError; checkpoint restore failed: $restoreError"
            }
            incr rollbackMs [expr {[clock milliseconds]-$phaseStarted}]
            incr rolledBack; lappend results [dict create candidate_id $candidateId status ROLLED_BACK error $candidateError]
            if {[file exists [file join $taskDir state cancel.flag]]} { break }
            continue
        }
        incr moved $planMoved; incr created $verified; incr succeeded; lappend results [dict create candidate_id $candidateId status CREATED created_elements $verified]
    }
    catch {::HWFlow::refreshBrowser}
    set totalMs [expr {[clock milliseconds]-$taskStarted}]
    set performance [dict create snapshot_seconds [expr {$snapshotMs/1000.0}] node_move_seconds [expr {$nodeMoveMs/1000.0}] delete_seconds [expr {$deleteMs/1000.0}] import_seconds [expr {$importMs/1000.0}] hm_quality_seconds [expr {$qualityMs/1000.0}] rollback_seconds [expr {$rollbackMs/1000.0}] total_seconds [expr {$totalMs/1000.0}]]
    return [dict create created $created succeeded $succeeded rolled_back $rolledBack moved_nodes $moved results $results snapshot $taskSnapshot performance $performance]
}
