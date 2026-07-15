proc ::SolidSeam::componentName {componentId} {
    if {[llength [info commands ::HWFlow::componentName]] > 0} { return [::HWFlow::componentName $componentId] }
    if {![catch {set value [hm_getvalue comps id=$componentId dataname=name]}]} { return $value }
    return "COMP_$componentId"
}

proc ::SolidSeam::elementTypeForExport {elementId} {
    set config [::SolidSeam::elementConfig $elementId]
    set elementType [::SolidSeam::elementTypeFromConfig $config]
    if {$elementType ne ""} { return $elementType }
    error "Unsupported HM element config '$config' for element $elementId"
}

proc ::SolidSeam::exportMeshData {classificationRows} {
    variable runtimeDir; variable selectedComponentIds
    set componentJson {}; set elementJson {}; set allNodes {}
    foreach row $classificationRows {
        set componentId [dict get $row component_id]
        lappend componentJson "    {\"component_id\": $componentId, \"component_name\": [::SolidSeam::jsonString [::SolidSeam::componentName $componentId]], \"mesh_class\": [::SolidSeam::jsonString [dict get $row mesh_class]]}"
        catch {*clearmark elems 1}
        eval *createmark elems 1 "by comp id" $componentId
        foreach elementId [hm_getmark elems 1] {
            set nodes [hm_getvalue elems id=$elementId dataname=nodes]
            set allNodes [concat $allNodes $nodes]
            lappend elementJson "    {\"element_id\": $elementId, \"component_id\": $componentId, \"element_type\": [::SolidSeam::jsonString [::SolidSeam::elementTypeForExport $elementId]], \"node_ids\": [::SolidSeam::jsonIntArray $nodes]}"
        }
    }
    set nodeJson {}
    foreach nodeId [lsort -integer -unique $allNodes] {
        set x [hm_getvalue nodes id=$nodeId dataname=x]; set y [hm_getvalue nodes id=$nodeId dataname=y]; set z [hm_getvalue nodes id=$nodeId dataname=z]
        lappend nodeJson "    {\"node_id\": $nodeId, \"xyz\": \[$x, $y, $z\]}"
    }
    # Existing connector export varies across HM profiles. Keep the contract
    # explicit and log the limitation until the target command file confirms
    # the connector datanames for this installation.
    ::SolidSeam::log WARNING "existing_connectors export is empty pending HM2019 dataname verification"
    set json "{\n  \"schema_version\": \"1.0\",\n  \"components\": \[\n[join $componentJson ,\n]\n  \],\n  \"nodes\": \[\n[join $nodeJson ,\n]\n  \],\n  \"elements\": \[\n[join $elementJson ,\n]\n  \],\n  \"existing_connectors\": \[\]\n}\n"
    set path [file join $runtimeDir mesh_data.json]
    ::HWFlow::writeTextFile $path $json
    ::SolidSeam::log INFO "mesh exported components=[llength $componentJson] elements=[llength $elementJson] nodes=[llength $nodeJson]"
    return $path
}

proc ::SolidSeam::writeRequest {} {
    variable runtimeDir; variable runId; variable mode; variable selectedComponentIds; variable solidComponentIds; variable shellComponentIds; variable ui
    set settings [join [list \
        "    \"search_distance\": $ui(search_distance)," \
        "    \"max_search_distance\": $ui(max_search_distance)," \
        "    \"min_weld_length\": $ui(min_weld_length)," \
        "    \"min_valid_ratio\": $ui(min_valid_ratio)," \
        "    \"feature_angle_deg\": $ui(feature_angle_deg)," \
        "    \"max_chain_turn_angle_deg\": $ui(max_chain_turn_angle_deg)," \
        "    \"gap_jump_limit\": $ui(gap_jump_limit)," \
        "    \"allow_closed_loop\": [::SolidSeam::jsonBool $ui(allow_closed_loop)]," \
        "    \"retain_short_candidates\": false," \
        "    \"detect_duplicates\": [::SolidSeam::jsonBool $ui(detect_duplicates)]," \
        "    \"high_confidence_threshold\": $ui(high_confidence_threshold)," \
        "    \"review_confidence_threshold\": $ui(review_confidence_threshold)" \
    ] "\n"]
    set json "{\n  \"schema_version\": \"1.0\",\n  \"run_id\": [::SolidSeam::jsonString $runId],\n  \"mode\": [::SolidSeam::jsonString $mode],\n  \"selected_component_ids\": [::SolidSeam::jsonIntArray $selectedComponentIds],\n  \"solid_component_ids\": [::SolidSeam::jsonIntArray $solidComponentIds],\n  \"shell_component_ids\": [::SolidSeam::jsonIntArray $shellComponentIds],\n  \"settings\": {\n$settings\n  }\n}\n"
    set path [file join $runtimeDir request.json]
    ::HWFlow::writeTextFile $path $json
    return $path
}
