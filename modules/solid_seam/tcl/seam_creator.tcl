proc ::SolidSeam::writeRealizationResult {results} {
    variable runtimeDir; variable runId
    set rows {}
    foreach result $results {
        lappend rows "    {\"candidate_id\": [::SolidSeam::jsonString [dict get $result candidate_id]], \"status\": [::SolidSeam::jsonString [dict get $result status]], \"grade\": [::SolidSeam::jsonString [dict get $result grade]], \"message\": [::SolidSeam::jsonString [dict get $result message]]}"
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"run_id\": [::SolidSeam::jsonString $runId],\n  \"results\": \[\n[join $rows ,\n]\n  \]\n}\n"
    ::HWFlow::writeTextFile [file join $runtimeDir realization_result.json] $json
}

proc ::SolidSeam::createOneCandidate {candidate} {
    set candidateId [dict get $candidate candidate_id]
    set errors [::SolidSeam::validateBeforeCreate $candidate]
    if {[llength $errors] > 0} { error [join $errors "; "] }
    set profile [::SolidSeam::loadRealizationProfile [dict get $candidate suggested_realization]]
    catch {*clearmark nodes 1}; catch {*clearmark connectors 1}; catch {*clearmark elems 1}
    set parameterSummary ""
    foreach field {parameter_strategy mesh_size source_thickness line_spacing weld_width realization_tolerance side_mode right_angled orientation_reversed} {
        if {[dict exists $candidate $field]} { append parameterSummary " $field=[dict get $candidate $field]" }
    }
    ::SolidSeam::log INFO "realization start profile=[dict get $profile profile_name] nodes=[dict get $candidate node_ids]$parameterSummary" $candidateId
    set result [::SolidSeamCommandProfile::realize $candidate $profile]
    set validation [::SolidSeam::validateAfterCreate $candidate $result]
    dict set result validation $validation
    ::SolidSeam::log INFO "realization complete grade=[dict get $validation grade] state=[dict get $validation connector_state]" $candidateId
    return $result
}

proc ::SolidSeam::createAcceptedCandidates {} {
    variable candidateRows; variable cancelled
    set accepted {}
    foreach row $candidateRows { if {[dict get $row status] eq "ACCEPTED"} { lappend accepted $row } }
    if {[llength $accepted] == 0} { ::SolidSeam::message warning [::SolidSeam::txt "没有已接受候选。" "No accepted candidates."]; return }
    set results {}; set cancelled 0; set index 0
    foreach candidate $accepted {
        incr index
        if {$cancelled} {
            ::SolidSeam::updateCandidate [dict get $candidate candidate_id] status SKIPPED_BY_USER
            lappend results [dict create candidate_id [dict get $candidate candidate_id] status SKIPPED_BY_USER grade FAIL message "stopped by user"]
            continue
        }
        set candidateId [dict get $candidate candidate_id]
        if {[catch {set created [::SolidSeam::createOneCandidate $candidate]} err opts]} {
            ::SolidSeam::updateCandidate $candidateId status FAILED
            ::SolidSeam::log ERROR "realization failed: $err" $candidateId
            lappend results [dict create candidate_id $candidateId status FAILED grade FAIL message $err]
            catch {*clearmark nodes 1}; catch {*clearmark connectors 1}; catch {*clearmark elems 1}
            continue
        }
        set validation [dict get $created validation]
        set grade [dict get $validation grade]
        ::SolidSeam::updateCandidate $candidateId status [expr {$grade eq "FAIL" ? "FAILED" : "CREATED"}]
        lappend results [dict create candidate_id $candidateId status [expr {$grade eq "FAIL" ? "FAILED" : "CREATED"}] grade $grade message "connector_state=[dict get $validation connector_state]; penta=[dict get $validation penta_count]; rbe3=[dict get $validation rbe3_count]"]
    }
    catch {*clearmarkall 1}
    catch {*clearmarkall 2}
    catch {hm_markclear components 1}
    catch {hm_markclear components 2}
    ::SolidSeam::writeRealizationResult $results
    ::SolidSeam::message info [::SolidSeam::txt "创建批次完成：总计 [llength $results]，详见 operation.log 与 realization_result.json。" "Creation batch complete: [llength $results] items. See operation.log and realization_result.json."]
}
