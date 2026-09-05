proc ::SolidSeam::writeRealizationResult {results} {
    variable runtimeDir; variable runId
    set rows {}
    foreach result $results {
        set fingerprint ""
        if {[dict exists $result candidate_fingerprint]} { set fingerprint [dict get $result candidate_fingerprint] }
        lappend rows "    {\"candidate_id\": [::SolidSeam::jsonString [dict get $result candidate_id]], \"candidate_fingerprint\": [::SolidSeam::jsonString $fingerprint], \"status\": [::SolidSeam::jsonString [dict get $result status]], \"grade\": [::SolidSeam::jsonString [dict get $result grade]], \"message\": [::SolidSeam::jsonString [dict get $result message]]}"
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"run_id\": [::SolidSeam::jsonString $runId],\n  \"results\": \[\n[join $rows ,\n]\n  \]\n}\n"
    ::HWFlow::writeTextFile [file join $runtimeDir realization_result.json] $json
}

# Return the component ids selected for seam detection (primary list when the
# user picked multiple components, or primary+secondary when the second
# selection panel was used).
proc ::SolidSeam::selectedComponentsForDetection {} {
    variable selectedComponentIds; variable primaryComponentIds; variable secondaryComponentIds
    if {[llength $secondaryComponentIds] > 0} {
        return [concat $primaryComponentIds $secondaryComponentIds]
    }
    return $selectedComponentIds
}

# Pair up selected component ids for seam detection.  With exactly two
# components the single pair is returned; with more than two, every ordered
# combination is emitted so the user can review which pairs should be welded.
proc ::SolidSeam::componentPairs {componentIds} {
    set pairs {}
    for {set i 0} {$i < [llength $componentIds]} {incr i} {
        for {set j [expr {$i + 1}]} {$j < [llength $componentIds]} {incr j} {
            lappend pairs [list [lindex $componentIds $i] [lindex $componentIds $j]]
        }
    }
    return $pairs
}

proc ::SolidSeam::autoDetectAndCreate {componentIds {prepareOnly 0}} {
    variable ui; variable candidateRows; variable lastResultSummary
    set pairs [::SolidSeam::componentPairs $componentIds]
    if {[llength $pairs] == 0} {
        error [::SolidSeam::txt "请至少选择两个组件。" "Select at least two components."]
    }
    set settings [dict create \
        search_distance $ui(tolerance) \
        max_search_distance $ui(tolerance) \
        min_weld_length 0.0 \
        gap_jump_limit $ui(gap_jump_limit) \
        default_width $ui(default_width) \
        default_spacing $ui(default_spacing) \
    ]
    set candidateRows {}
    foreach pair $pairs {
        set source [lindex $pair 0]
        set target [lindex $pair 1]
        if {$ui(input_type) eq "AUTO"} {
            set pairSettings [::SolidSeam::automaticSettings $source $target]
        } else { set pairSettings $settings }
        set detected [::SolidSeam::autoDetectSeams $source $target $pairSettings]
        set timings {}
        if {[info exists ::SolidSeam::lastDetectionStages]} { set timings $::SolidSeam::lastDetectionStages }
        set shadow {}
        if {$ui(input_type) eq "AUTO" && [info exists ui(shadow_face_distance)] && $ui(shadow_face_distance)} {
            if {[catch {set shadow [::SolidSeam::shadowFaceDistanceAudit $source $target $detected [dict get $pairSettings search_distance]]} shadowError]} {
                ::SolidSeam::log WARN "shadow face-distance audit failed $source -> $target: $shadowError"
            } else {
                ::SolidSeam::log INFO "shadow face-distance $source -> $target: $shadow"
            }
        }
        ::SolidSeam::log INFO "auto detect pair $source -> $target candidates=[llength $detected] timings=$timings"
        foreach candidate $detected {
            if {$ui(input_type) eq "AUTO"} {
                # Auto already resolved side_mode, retaining BOTH or the manual
                # fallback where the geometry cannot select a unique side.
            } else { set candidate [::SolidSeam::applyCreationSettings $candidate] }
            dict set candidate recognition_timings $timings
            if {$shadow ne ""} { dict set candidate shadow_face_summary $shadow }
            dict set candidate status ACCEPTED
            set candidate [::SolidSeam::finalizeCandidateDiagnostics $candidate]
            lappend candidateRows $candidate
        }
    }
    if {[llength $candidateRows] == 0} {
        if {$ui(input_type) eq "AUTO"} {
            error [::SolidSeam::txt "Auto 在当前网格尺度的搜索范围内未找到焊缝。请检查组件，或切换 comps+comps 指定 tolerance。" "Auto found no seam within the mesh-scaled search range. Check components or use comps+comps to specify tolerance."]
        }
        error [::SolidSeam::txt "未识别到可创建的焊缝位置。请检查 tolerance 与组件选择。" "No weld location was detected. Check tolerance and the selected components."]
    }
    if {$prepareOnly} { return $candidateRows }
    ::SolidSeam::createAcceptedCandidates
}

proc ::SolidSeam::applyCreationSettings {candidate} {
    variable ui
    dict set candidate suggested_realization PENTA_MIG_$ui(weld_type)
    dict set candidate joint_type [dict get {T T_JOINT B BUTT_JOINT L LAP_JOINT} $ui(weld_type)]
    dict set candidate line_spacing $ui(default_spacing)
    dict set candidate weld_width $ui(default_width)
    dict set candidate realization_tolerance $ui(tolerance)
    dict set candidate side_mode $ui(side_mode)
    dict set candidate parameter_strategy USER_EXPLICIT
    return $candidate
}

proc ::SolidSeam::createFromNodes {nodeIds componentIds {prepareOnly 0}} {
    variable candidateRows
    set closed [expr {[llength $nodeIds] == 1}]
    if {$closed} {
        set paths [::SolidSeam::closedBoundariesForSeed [lindex $nodeIds 0] [lindex $componentIds 0]]
    } else { set paths [list $nodeIds] }
    set candidateRows {}; set index 0
    foreach path $paths {
        incr index
        set candidate [dict create candidate_id MANUAL_$index node_ids $path is_closed $closed \
            source_component_id [lindex $componentIds 0] target_component_id [lindex $componentIds 1] \
            status ACCEPTED duplicate_state NONE]
        set candidate [::SolidSeam::applyCreationSettings $candidate]
        lappend candidateRows [::SolidSeam::finalizeCandidateDiagnostics $candidate]
    }
    if {$prepareOnly} { return $candidateRows }
    ::SolidSeam::createAcceptedCandidates
}

proc ::SolidSeam::createOneCandidate {candidate} {
    set candidateId [dict get $candidate candidate_id]
    set errors [::SolidSeam::validateBeforeCreate $candidate]
    if {[llength $errors] > 0} { error [join $errors "; "] }
    set profile [::SolidSeam::loadRealizationProfile [dict get $candidate suggested_realization]]
    catch {*clearmark nodes 1}; catch {*clearmark connectors 1}; catch {*clearmark elems 1}
    set parameterSummary ""
    foreach field {candidate_fingerprint recognition_timings shadow_face_summary parameter_strategy side_strategy side_confidence side_votes mesh_size source_thickness line_spacing weld_width realization_tolerance side_mode right_angled orientation_reversed} {
        if {[dict exists $candidate $field]} { append parameterSummary " $field=[dict get $candidate $field]" }
    }
    ::SolidSeam::log INFO "realization start profile=[dict get $profile profile_name] nodes=[dict get $candidate node_ids]$parameterSummary" $candidateId
    set realizationStarted [clock milliseconds]
    set code [catch {::SolidSeamCommandProfile::realize $candidate $profile} result opts]
    set realizationMs [expr {[clock milliseconds]-$realizationStarted}]
    foreach slot {1 2} {
        foreach entity {elems nodes comps connectors} { catch {*clearmark $entity $slot} }
        catch {*clearlist nodes $slot}
    }
    if {$code} {
        ::SolidSeam::log ERROR "realization command failed elapsed_ms=$realizationMs error=$result" $candidateId
        return -options $opts $result
    }
    set validation [::SolidSeam::validateAfterCreate $candidate $result]
    dict set result validation $validation
    dict set result realization_ms $realizationMs
    ::SolidSeam::log INFO "realization complete elapsed_ms=$realizationMs grade=[dict get $validation grade] state=[dict get $validation connector_state]" $candidateId
    return $result
}

proc ::SolidSeam::createAcceptedCandidates {} {
    variable candidateRows; variable cancelled; variable lastResultSummary
    set accepted {}
    foreach row $candidateRows { if {[dict get $row status] eq "ACCEPTED"} { lappend accepted $row } }
    if {[llength $accepted] == 0} { ::SolidSeam::message warning [::SolidSeam::txt "没有已接受候选。" "No accepted candidates."]; return }
    set results {}; set cancelled 0; set index 0
    foreach candidate $accepted {
        incr index
        # Recompute at the creation boundary so candidate-viewer edits are
        # reflected in the audit identity written to logs/results.
        set candidate [::SolidSeam::finalizeCandidateDiagnostics $candidate]
        if {$cancelled} {
            ::SolidSeam::updateCandidate [dict get $candidate candidate_id] status SKIPPED_BY_USER
            lappend results [dict create candidate_id [dict get $candidate candidate_id] candidate_fingerprint [dict get $candidate candidate_fingerprint] status SKIPPED_BY_USER grade FAIL message "stopped by user"]
            continue
        }
        set candidateId [dict get $candidate candidate_id]
        if {$::SolidSeam::ui(input_type) eq "AUTO_GROUP"} {
            ::SolidSeam::log INFO "AutoGroup create seam $index/[llength $accepted]: $candidateId"
            catch {::HWFlow::progressPumpEvents 0}
        }
        if {[catch {set created [::SolidSeam::createOneCandidate $candidate]} err opts]} {
            ::SolidSeam::updateCandidate $candidateId status FAILED
            ::SolidSeam::log ERROR "realization failed: $err" $candidateId
            lappend results [dict create candidate_id $candidateId candidate_fingerprint [dict get $candidate candidate_fingerprint] status FAILED grade FAIL message $err]
            catch {*clearmark nodes 1}; catch {*clearmark connectors 1}; catch {*clearmark elems 1}
            continue
        }
        set validation [dict get $created validation]
        set grade [dict get $validation grade]
        ::SolidSeam::updateCandidate $candidateId status [expr {$grade eq "FAIL" ? "FAILED" : "CREATED"}]
        lappend results [dict create candidate_id $candidateId candidate_fingerprint [dict get $candidate candidate_fingerprint] status [expr {$grade eq "FAIL" ? "FAILED" : "CREATED"}] grade $grade message "connector_state=[dict get $validation connector_state]; penta=[dict get $validation penta_count]; rbe3=[dict get $validation rbe3_count]; realization_ms=[dict get $created realization_ms]"]
    }
    catch {*clearmarkall 1}
    catch {*clearmarkall 2}
    catch {hm_markclear components 1}
    catch {hm_markclear components 2}
    ::SolidSeam::writeRealizationResult $results
    set created 0; set failed 0
    foreach result $results {
        if {[dict get $result status] eq "CREATED"} { incr created }
        if {[dict get $result status] eq "FAILED"} { incr failed }
    }
    set lastResultSummary [::SolidSeam::txt "成功 $created，失败 $failed，总计 [llength $results]" "Created $created, failed $failed, total [llength $results]"]
    if {$failed > 0} { error "$lastResultSummary. See operation.log / realization_result.json." }
    return $results
}
