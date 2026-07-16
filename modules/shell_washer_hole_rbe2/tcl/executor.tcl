proc ::RB2W::hybridNodeExists {nid} { return [expr {![catch {set v [hm_getvalue nodes id=$nid dataname=id]}] && $v ne ""}] }

proc ::RB2W::executePythonCandidatesLegacy {compId payload {progressStart 60.0} {progressEnd 95.0}} {
    variable BATCH_ORGANIZE_RBE2
    set created 0; set skipped 0; set failed 0; set organized 0; set outComp ""; set made {}
    ::RB2W::initExistingRBE2IndexForSource $compId [::RB2W::sourceOutputBaseName $compId]
    set candidates [dict get $payload candidates]; set total [llength $candidates]; set index 0
    foreach row $candidates {
        incr index
        if {$total>0} { ::HybridCore::progressUpdate [expr {$progressStart+($progressEnd-$progressStart)*$index/double($total)}] "Shell Washer-Hole RIGIDS" "Component $compId candidate $index/$total; created=$created skipped=$skipped failed=$failed" [expr {$index==$total}] }
        if {[dict get $row recommended_action] ne "CREATE"} { incr skipped; continue }
        set dep [dict get $row dependent_node_ids]; set missing {}
        foreach nid $dep { if {![::RB2W::hybridNodeExists $nid]} { lappend missing $nid } }
        if {[llength $missing] > 0} { incr failed; ::HybridCore::log ERROR "candidate=[dict get $row candidate_id] missing_nodes=$missing"; continue }
        set existing [::RB2W::existingRBE2ForDepNodes $dep]
        if {[lindex $existing 0]} { incr skipped; continue }
        set code [catch {
            if {$outComp eq ""} { set outComp [::RB2W::ensureOutputComponent $compId] }
            set cnode [::RB2W::createCenterNode [dict get $row center] $outComp]
            set elems [::RB2W::createRigidLink $cnode $dep $outComp]
            ::RB2W::rememberRBE2ForDepNodes $dep $elems
            set actual [::RB2W::rbe2DependentNodeKey [lindex $elems 0] 1]
            set expected [::HWFlow::nodeSetKey $dep]
            if {$actual ne $expected} { error "dependent-node validation failed expected=$expected actual=$actual" }
            set made [concat $made $elems]
        } err]
        if {$code} { incr failed; ::HybridCore::log ERROR "candidate=[dict get $row candidate_id] create_failed=$err" } else { incr created }
    }
    if {$BATCH_ORGANIZE_RBE2 && [llength $made] > 0} { set organized [::RB2W::organizeCreatedRBE2Elements $made $outComp] }
    return [list $created [expr {$skipped+$failed}] [llength [dict get $payload candidates]] $organized]
}

proc ::RB2W::executePythonCandidates {compId payload {progressStart 60.0} {progressEnd 95.0}} {
    set summary [dict get $payload summary]
    set total [llength [dict get $payload candidates]]
    set planned [dict get $summary planned_create_count]
    if {[catch {
        set imported [::HybridCore::importRigidDelta "Shell Washer-Hole RIGIDS" $summary \
            [list ::RB2W::rigidCenterNode] [list ::RB2W::getElemNodes] $progressStart $progressEnd]
    } importError]} {
        ::HybridCore::log WARN "incremental RIGIDS import failed; using legacy Tcl creation: $importError"
        return [::RB2W::executePythonCandidatesLegacy $compId $payload $progressStart $progressEnd]
    }
    set created [dict get $imported created]
    return [list $created [expr {$total-$planned}] $total $created]
}
