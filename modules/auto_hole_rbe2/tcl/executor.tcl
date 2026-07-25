proc ::AutoHoleRBE2::executePythonCandidatesLegacy {payload} {
    variable cfg
    ::AutoHoleRBE2::beginBulkCreate
    set code [catch {set result [::AutoHoleRBE2::executePythonCandidatesBulk $payload]} err opts]
    ::AutoHoleRBE2::endBulkCreate $cfg(resultCompName)
    if {$code} { return -options $opts $err }
    return $result
}

proc ::AutoHoleRBE2::executePythonCandidates {payload} {
    # Python only identifies and groups the wall-node sets.  HyperMesh/Tcl is
    # the authoritative creator so node IDs never cross an import/renumbering
    # boundary before *rigidlink is called.
    return [::AutoHoleRBE2::executePythonCandidatesLegacy $payload]
}

proc ::AutoHoleRBE2::resolveCandidateWallNodes {solverNodeIds} {
    set poolNames {}
    foreach entityType {nodes node} {
        if {![catch {set names [hm_getidpools $entityType name]}]} {
            set poolNames [concat $poolNames $names]
        }
    }
    set poolNames [lsort -unique $poolNames]
    set result {}
    foreach solverId [::AutoHoleRBE2::uniq $solverNodeIds] {
        set internalId ""
        foreach poolName $poolNames {
            if {[catch {set candidate [hm_getinternalid $poolName $solverId -bypoolname]}]} {
                continue
            }
            if {$candidate ne "" && $candidate != 0} {
                set internalId $candidate
                break
            }
        }
        if {$internalId eq "" && [::AutoHoleRBE2::hybridNodeExists $solverId]} {
            set internalId $solverId
        }
        if {$internalId eq ""} {
            error "Cannot resolve FEM solver node ID $solverId to a HyperMesh node"
        }
        lappend result $internalId
    }
    return $result
}

proc ::AutoHoleRBE2::executePythonCandidatesBulk {payload} {
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
        set wallNodes [::AutoHoleRBE2::resolveCandidateWallNodes [dict get $candidate wall_node_ids]]
        set centerNode ""; set elementId ""
        set code [catch {
            if {!$resultCompReady} {
                ::AutoHoleRBE2::ensureComponent $cfg(resultCompName) 0
                set resultCompReady 1
            }
            set info [::AutoHoleRBE2::createRBE2 $wallNodes [dict get $candidate center]]
            set centerNode [lindex $info 0]
            set elementId [lindex $info 1]
            ::AutoHoleRBE2::rememberCreatedRBE2 $wallNodes $elementId
        } err]
        if {$code} {
            ::AutoHoleRBE2::cleanupFailedRBE2 $centerNode $elementId
            incr failed
            ::HybridCore::log ERROR "candidate=$candidateId create_failed=$err"
        } else {
            incr created
            ::HybridCore::log INFO "candidate=$candidateId created element=$elementId"
        }
    }
    set stat(created) $created
    set stat(skippedExisting) $skipped
    return [dict create created $created skipped $skipped failed $failed]
}
