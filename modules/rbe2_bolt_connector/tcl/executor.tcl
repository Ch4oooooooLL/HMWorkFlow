proc ::RB2Bolt::executePythonPlans {payload {progressStart 65.0} {progressEnd 96.0}} {
    variable P
    set created 0; set skipped 0; set existing 0
    ::RB2Bolt::beginBulkCreate
    set plans [dict get $payload candidates]; set total [llength $plans]; set index 0
    foreach row $plans {
        incr index
        if {$total>0} { ::HybridCore::progressUpdate [expr {$progressStart+($progressEnd-$progressStart)*$index/double($total)}] "RBE2 Bolt Connector" "Creating connector $index/$total; created=$created existing=$existing failed=$skipped" [expr {$index==$total}] }
        if {[dict get $row recommended_action] ne "CREATE"} { incr existing; continue }
        set n1 [dict get $row node_1]; set n2 [dict get $row node_2]; set dia [dict get $row diameter]; set comp [dict get $row component_name]
        if {$P(dryRun)} { continue }
        set rc 0
        set code [catch {
            foreach nid [list $n1 $n2] {
                if {[catch {set value [hm_getvalue nodes id=$nid dataname=id]}] || $value eq ""} { error "center node $nid no longer exists" }
            }
            if {$n1 == $n2} { error "coincident center node IDs" }
            if {$P(propName) eq ""} { set prop [::RB2Bolt::ensureBoltProperty $P(elemType) $dia] } else { set prop $P(propName) }
            set rc [::RB2Bolt::createBeamBetween $n1 $n2 $P(elemType) $comp $prop]
        } err]
        if {$code} { ::HybridCore::log ERROR "candidate=[dict get $row candidate_id] create_failed=$err"; set rc 0 }
        if {$rc>0} { incr created } elseif {$rc<0} { incr existing } else { incr skipped }
    }
    catch {::RB2Bolt::endBulkCreate}
    return [dict create created $created skipped $skipped skipped_existing $existing pair_count [llength $plans]]
}
