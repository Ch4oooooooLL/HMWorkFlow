proc ::SolidSeam::entityExists {entityType entityId} {
    return [expr {![catch {set value [hm_getvalue $entityType id=$entityId dataname=id]}] && $value ne ""}]
}

proc ::SolidSeam::validateBeforeCreate {candidate} {
    set errors {}
    foreach field {source_component_id target_component_id node_ids candidate_id status suggested_realization duplicate_state} {
        if {![dict exists $candidate $field]} { lappend errors "missing $field" }
    }
    if {[llength $errors] > 0} { return $errors }
    set source [dict get $candidate source_component_id]; set target [dict get $candidate target_component_id]
    if {$source == $target} { lappend errors "source and target are identical" }
    if {![::SolidSeam::entityExists comps $source]} { lappend errors "source component no longer exists" }
    if {![::SolidSeam::entityExists comps $target]} { lappend errors "target component no longer exists" }
    set nodes [dict get $candidate node_ids]
    if {[llength $nodes] < 2} { lappend errors "node list contains fewer than two nodes" }
    if {[llength [lsort -integer -unique $nodes]] != [llength $nodes]} { lappend errors "node list contains duplicate nodes" }
    foreach nodeId $nodes { if {![::SolidSeam::entityExists nodes $nodeId]} { lappend errors "node $nodeId no longer exists" } }
    if {[dict get $candidate status] ni {ACCEPTED PENDING}} { lappend errors "candidate status is [dict get $candidate status]" }
    if {[dict get $candidate duplicate_state] eq "CONFIRMED"} { lappend errors "confirmed duplicate" }
    if {[catch {::SolidSeam::loadRealizationProfile [dict get $candidate suggested_realization]} profileErr]} { lappend errors $profileErr }
    return $errors
}

proc ::SolidSeam::validateAfterCreate {candidate result} {
    set warnings {}; set failures {}
    set state UNKNOWN; set pentaIds {}; set rbe3Ids {}
    if {[dict exists $result connector_state]} { set state [string toupper [dict get $result connector_state]] }
    if {[dict exists $result penta_ids]} { set pentaIds [dict get $result penta_ids] }
    if {[dict exists $result rbe3_ids]} { set rbe3Ids [dict get $result rbe3_ids] }
    if {$state ne "REALIZED"} { lappend failures "connector_state=$state" }
    if {[llength $pentaIds] == 0} { lappend failures "no PENTA elements generated" }
    if {[llength $rbe3Ids] < 2} { lappend warnings "fewer than two RBE3 elements reported" }
    if {[dict exists $result linked_component_ids]} {
        set expected [lsort -integer [list [dict get $candidate source_component_id] [dict get $candidate target_component_id]]]
        set actual [lsort -integer -unique [dict get $result linked_component_ids]]
        if {$actual ne $expected} { lappend failures "connector links unexpected components: $actual; expected $expected" }
    } else {
        lappend warnings "command profile did not report linked_component_ids"
    }
    # Profile-specific quality commands may return quality_warnings/failures.
    if {[dict exists $result quality_warnings]} { set warnings [concat $warnings [dict get $result quality_warnings]] }
    if {[dict exists $result quality_failures]} { set failures [concat $failures [dict get $result quality_failures]] }
    set grade [expr {[llength $failures] > 0 ? "FAIL" : ([llength $warnings] > 0 ? "PASS_WITH_WARNING" : "PASS")}]
    return [dict create grade $grade connector_state $state penta_count [llength $pentaIds] rbe3_count [llength $rbe3Ids] warnings $warnings failures $failures]
}
