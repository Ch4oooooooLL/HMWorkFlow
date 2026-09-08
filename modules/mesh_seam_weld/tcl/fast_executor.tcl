proc ::MeshSeamWeld::verifyAutoCandidateRollback {plan} {
    set expectedElements {}
    foreach element [concat [dict get $plan replacement_elements] [dict get $plan weld_elements]] {
        lappend expectedElements [dict get $element element_id]
    }
    set surviving [::HybridCore::existingEntityIds {elems elements} $expectedElements]
    if {[llength $surviving]} { return "weld elements still present: $surviving" }
    set expectedNodes {}
    foreach node [dict get $plan new_nodes] { lappend expectedNodes [dict get $node node_id] }
    set survivingNodes [::HybridCore::existingEntityIds {nodes} $expectedNodes]
    if {[llength $survivingNodes]} { return "created GRID nodes still present: $survivingNodes" }
    set mothers [dict get $plan delete_element_ids]
    if {[llength $mothers]} {
        set missing [list]
        foreach elementId $mothers {
            if {[llength [::HybridCore::existingEntityIds {elems elements} [list $elementId]]] == 0} { lappend missing $elementId }
        }
        if {[llength $missing]} { return "mother shells were not restored: $missing" }
    }
    foreach move [lrange [dict get $plan move_nodes] 0 4] {
        set nodeId [dict get $move node_id]
        if {[catch {::HybridCore::coordinatesMatch \
            [::HybridCore::nodeCoordinates $nodeId] [dict get $move from] 1.0e-7} matched] || !$matched} {
            return "GRID $nodeId was not translated back to its planned position"
        }
    }
    return ""
}

proc ::MeshSeamWeld::executeAutoPlans {taskDir plans} {
    set taskStarted [clock milliseconds]
    set historyMs 0; set nodeMoveMs 0; set deleteMs 0; set importMs 0; set qualityMs 0; set rollbackMs 0
    ::MeshSeamWeld::enableNativeUndo
    set undoBefore [::MeshSeamWeld::nativeUndoActions]
    set created 0; set succeeded 0; set rolledBack 0; set moved 0; set index 0; set results {}
    set weldElementIds {}
    foreach plan $plans {
        if {[dict get $plan status] ne "READY"} { continue }
        if {[file exists [file join $taskDir state cancel.flag]]} { lappend results [dict create candidate_id [dict get $plan candidate_id] status CANCELLED]; break }
        incr index
        set candidateId [dict get $plan candidate_id]
        set historyName "Auto shell seam candidate $candidateId"
        set planMoved 0
        if {[catch {
            set phaseStarted [clock milliseconds]; *startnotehistorystate $historyName; incr historyMs [expr {[clock milliseconds]-$phaseStarted}]
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
            if {[catch {*endnotehistorystate $historyName} endError]} {
                catch {*endnotehistorystate $historyName}
            }
            # Only undo while this candidate really is the newest native undo
            # entry; otherwise the pop would roll back an earlier candidate.
            set actions [::MeshSeamWeld::nativeUndoActions]
            if {[lindex $actions 0] ne $historyName} {
                set rollbackError "undo stack top is [lindex $actions 0], expected $historyName"
            } elseif {[catch {*undohistorystate 1} undoError]} {
                set rollbackError "native undo failed: $undoError"
            } else {
                set rollbackError [::MeshSeamWeld::verifyAutoCandidateRollback $plan]
            }
            incr rollbackMs [expr {[clock milliseconds]-$phaseStarted}]
            if {$rollbackError ne ""} {
                error "$candidateId failed: $candidateError; native rollback failed: $rollbackError"
            }
            incr rolledBack; lappend results [dict create candidate_id $candidateId status ROLLED_BACK error $candidateError]
            if {[file exists [file join $taskDir state cancel.flag]]} { break }
            continue
        }
        if {[catch {*endnotehistorystate $historyName} endError endOptions]} {
            # Retry once before treating the commit as a failure, mirroring
            # the geometry seam transaction handling.
            if {[catch {*endnotehistorystate $historyName} endError endOptions]} {
                set actions [::MeshSeamWeld::nativeUndoActions]
                if {[lindex $actions 0] eq $historyName} {
                    catch {*undohistorystate 1}
                    error "$candidateId was created but could not be committed as a native undo action: $endError"
                }
                ::HybridCore::log ERROR "auto shell seam history commit failed candidate=$candidateId error=$endError"
            }
        }
        incr moved $planMoved; incr created $verified; incr succeeded
        foreach element [dict get $plan weld_elements] { lappend weldElementIds [dict get $element element_id] }
        lappend results [dict create candidate_id $candidateId status CREATED created_elements $verified]
    }
    catch {::HWFlow::refreshBrowser}
    set totalMs [expr {[clock milliseconds]-$taskStarted}]
    set performance [dict create history_seconds [expr {$historyMs/1000.0}] node_move_seconds [expr {$nodeMoveMs/1000.0}] delete_seconds [expr {$deleteMs/1000.0}] import_seconds [expr {$importMs/1000.0}] hm_quality_seconds [expr {$qualityMs/1000.0}] rollback_seconds [expr {$rollbackMs/1000.0}] total_seconds [expr {$totalMs/1000.0}]]
    set undoLabelsAfter [list]
    if {$succeeded > 0} {
        if {[catch {set undoLabelsAfter [::MeshSeamWeld::newUndoLabels $undoBefore [::MeshSeamWeld::nativeUndoActions]]} undoLabelErr]} {
            ::HybridCore::log ERROR "auto shell seam undo registration unavailable error=$undoLabelErr"
        }
    }
    return [dict create created $created succeeded $succeeded rolled_back $rolledBack moved_nodes $moved results $results undo_labels $undoLabelsAfter check_element_ids [lrange [lsort -integer -unique $weldElementIds] 0 4] performance $performance]
}
