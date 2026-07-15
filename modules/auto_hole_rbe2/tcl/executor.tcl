proc ::AutoHoleRBE2::hybridNodeExists {nodeId} {
    return [expr {![catch {set value [hm_getvalue nodes id=$nodeId dataname=id]}] && $value ne ""}]
}

proc ::AutoHoleRBE2::executePythonCandidates {payload} {
    variable cfg; variable stat
    set created 0; set skipped 0; set failed 0; set resultCompReady 0
    set candidates [dict get $payload candidates]
    set candidateTotal [llength $candidates]; set candidateIndex 0
    foreach candidate $candidates {
        incr candidateIndex
        if {$candidateTotal > 0} {
            set pct [expr {70.0+25.0*$candidateIndex/double($candidateTotal)}]
            ::HybridCore::progressUpdate $pct "Solid Through-Hole RIGIDS" "Creating candidate $candidateIndex/$candidateTotal; created=$created skipped=$skipped failed=$failed" [expr {$candidateIndex==$candidateTotal}]
        }
        set candidateId [dict get $candidate candidate_id]
        if {[dict get $candidate recommended_action] ne "CREATE"} {
            incr skipped
            ::HybridCore::log INFO "candidate=$candidateId skipped existing=[dict get $candidate existing_rbe2_id]"
            continue
        }
        set wallNodes [dict get $candidate wall_node_ids]
        set missing {}
        foreach nodeId $wallNodes { if {![::AutoHoleRBE2::hybridNodeExists $nodeId]} { lappend missing $nodeId } }
        if {[llength $missing] > 0} {
            incr failed
            ::HybridCore::log ERROR "candidate=$candidateId missing_nodes=$missing"
            continue
        }
        set code [catch {
            if {!$resultCompReady} {
                ::AutoHoleRBE2::ensureComponent $cfg(resultCompName)
                set resultCompReady 1
            }
            set info [::AutoHoleRBE2::createRBE2 $wallNodes [dict get $candidate center]]
            set elementId [lindex $info 1]
            ::AutoHoleRBE2::rememberCreatedRBE2 $wallNodes $elementId
            set actual [::AutoHoleRBE2::rbe2DependentNodeKey $elementId]
            set expected [::HWFlow::nodeSetKey $wallNodes]
            if {$actual ne $expected} { error "created RBE2 dependent-node validation failed: expected=$expected actual=$actual" }
        } err]
        if {$code} {
            incr failed
            ::HybridCore::log ERROR "candidate=$candidateId create_failed=$err"
        } else {
            incr created
            ::HybridCore::log INFO "candidate=$candidateId created element=$elementId"
        }
    }
    set stat(created) $created
    set stat(skippedExisting) $skipped
    if {$created > 0 || $skipped > 0} { ::AutoHoleRBE2::refreshComponentBrowser $cfg(resultCompName) }
    return [dict create created $created skipped $skipped failed $failed]
}
