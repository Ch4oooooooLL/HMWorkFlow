proc ::SolidSeam::optistructExportTemplate {} {
    set candidates {}
    if {![catch {set path [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]}] && [string trim $path] ne ""} {
        lappend candidates [file join $path feoutput optistruct optistruct]
    }
    if {![catch {set path [hm_info -appinfo EXECUTABLEDIR]}] && [string trim $path] ne ""} {
        lappend candidates [file join $path .. .. .. templates feoutput optistruct optistruct]
    }
    foreach candidate $candidates {
        set normalized [file normalize $candidate]
        if {[file isfile $normalized]} { return $normalized }
    }
    error [::SolidSeam::txt "找不到 HyperMesh OptiStruct FEM 导出模板。" "Could not locate the HyperMesh OptiStruct FEM export template."]
}

proc ::SolidSeam::exportSelectedFem {} {
    variable runtimeDir; variable selectedComponentIds
    set paths {}; set template [::SolidSeam::optistructExportTemplate]
    foreach componentId $selectedComponentIds {
        set path [file join $runtimeDir "component_${componentId}.fem"]
        catch {*clearmark elems 1}; catch {*clearmark nodes 1}
        set code [catch {
            *createmark elems 1 "by comp id" $componentId
            *createmark nodes 1 "by comp id" $componentId
            if {[llength [hm_getmark elems 1]] == 0 || [llength [hm_getmark nodes 1]] == 0} {
                error [::SolidSeam::txt "Component $componentId 中没有可导出的网格。" "Component $componentId contains no exportable mesh."]
            }
            ::HWFlow::runHyperMeshIo export \
                [list *feoutput_select $template $path 1 0 0] $path
        } err opts]
        catch {*clearmark elems 1}; catch {*clearmark nodes 1}
        if {$code} { return -options $opts $err }
        if {![file isfile $path] || [file size $path] == 0} { error "HyperMesh did not create component_${componentId}.fem" }
        lappend paths $path
        ::SolidSeam::log INFO "fem exported component=$componentId bytes=[file size $path]"
    }
    if {[llength $paths] != [llength $selectedComponentIds]} {
        error [::SolidSeam::txt "部分 Components 未能导出为 FEM。" "Some selected components were not exported to FEM."]
    }
    return $paths
}

proc ::SolidSeam::writeRequest {} {
    variable runtimeDir; variable runId; variable selectedComponentIds
    variable primaryComponentIds; variable secondaryComponentIds; variable ui
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
    set json "{\n  \"schema_version\": \"1.0\",\n  \"run_id\": [::SolidSeam::jsonString $runId],\n  \"selected_component_ids\": [::SolidSeam::jsonIntArray $selectedComponentIds],\n  \"primary_component_ids\": [::SolidSeam::jsonIntArray $primaryComponentIds],\n  \"secondary_component_ids\": [::SolidSeam::jsonIntArray $secondaryComponentIds],\n  \"settings\": {\n$settings\n  }\n}\n"
    set path [file join $runtimeDir request.json]
    ::HWFlow::writeTextFile $path $json
    return $path
}
