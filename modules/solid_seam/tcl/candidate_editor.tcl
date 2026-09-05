proc ::SolidSeam::candidateIndexById {candidateId} {
    variable candidateRows
    for {set i 0} {$i < [llength $candidateRows]} {incr i} {
        if {[dict get [lindex $candidateRows $i] candidate_id] eq $candidateId} { return $i }
    }
    return -1
}

proc ::SolidSeam::updateCandidate {candidateId field value} {
    variable candidateRows
    set index [::SolidSeam::candidateIndexById $candidateId]
    if {$index < 0} { error "Unknown candidate: $candidateId" }
    set row [lindex $candidateRows $index]
    dict set row $field $value
    set row [::SolidSeam::finalizeCandidateDiagnostics $row]
    set candidateRows [lreplace $candidateRows $index $index $row]
    ::SolidSeam::log INFO "candidate updated $field=$value" $candidateId
    catch {::SolidSeam::refreshCandidateList}
    return $row
}

proc ::SolidSeam::acceptHighConfidence {} {
    variable candidateRows
    foreach row $candidateRows {
        if {[dict get $row confidence_level] eq "HIGH" && [dict get $row duplicate_state] ne "CONFIRMED" && [llength [dict get $row warnings]] == 0} {
            ::SolidSeam::updateCandidate [dict get $row candidate_id] status ACCEPTED
        }
    }
}

proc ::SolidSeam::acceptAllCandidates {} {
    variable candidateRows
    set updatedRows {}
    set changed 0
    foreach row $candidateRows {
        # CREATED and FAILED are terminal realization results. All review,
        # pending, rejected, and auto-accepted detection rows may be accepted.
        if {[dict get $row status] ni {CREATED FAILED}} {
            dict set row status ACCEPTED
            incr changed
        }
        lappend updatedRows $row
    }
    set candidateRows $updatedRows
    ::SolidSeam::log INFO "accepted all candidates count=$changed"
    catch {::SolidSeam::refreshCandidateList}
}

proc ::SolidSeam::rejectAll {} {
    variable candidateRows
    foreach row $candidateRows { if {[dict get $row status] ni {CREATED FAILED}} { ::SolidSeam::updateCandidate [dict get $row candidate_id] status REJECTED } }
}

proc ::SolidSeam::reverseSelectedCandidate {} {
    set row [::SolidSeam::selectedCandidate]
    if {$row eq ""} { return }
    ::SolidSeam::updateCandidate [dict get $row candidate_id] node_ids [lreverse [dict get $row node_ids]]
    ::SolidSeam::previewSelectedCandidate
}
