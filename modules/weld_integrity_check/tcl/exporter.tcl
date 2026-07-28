proc ::WeldIntegrityCheck::optistructExportTemplate {} {
    set candidates {}
    if {![catch {set templatesDir [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]}] &&
        [string trim $templatesDir] ne ""} {
        lappend candidates [file join $templatesDir feoutput optistruct optistruct]
    }
    if {![catch {set executableDir [hm_info -appinfo EXECUTABLEDIR]}] &&
        [string trim $executableDir] ne ""} {
        lappend candidates [file join $executableDir .. .. .. templates feoutput optistruct optistruct]
    }
    foreach candidate $candidates {
        set normalized [file normalize $candidate]
        if {[file isfile $normalized]} { return $normalized }
    }
    error [::WeldIntegrityCheck::txt \
        "找不到 HyperMesh OptiStruct FEM 导出模板。" \
        "Could not locate the HyperMesh OptiStruct FEM export template."]
}

proc ::WeldIntegrityCheck::componentElementIds {componentId} {
    if {[llength [info commands ::HWFlow::getCompEntityIds]] > 0} {
        return [::HWFlow::getCompEntityIds $componentId elems elems]
    }
    set ids {}
    catch {*clearmark elems 2}
    if {![catch {*createmark elems 2 "by comp id" $componentId}]} {
        catch {set ids [hm_getmark elems 2]}
    }
    catch {*clearmark elems 2}
    return [lsort -integer -unique $ids]
}

proc ::WeldIntegrityCheck::exportInput {componentIds} {
    variable taskDir; variable ui; variable cfg; variable taskId
    set inputDir [file join $taskDir input]
    set outputPath [file join $inputDir selected_components.fem]
    set manifestPath [file join $inputDir mesh_manifest.json]
    set exportTemplate [::WeldIntegrityCheck::optistructExportTemplate]
    set componentRows {}
    set elementCount 0

    # Only component membership is queried through Tcl. HyperMesh performs the
    # mesh serialization natively; Python reads connectivity and coordinates.
    foreach componentId $componentIds {
        set elementIds [::WeldIntegrityCheck::componentElementIds $componentId]
        if {[llength $elementIds] == 0} { continue }
        set name [::HWFlow::componentName $componentId]
        if {$name eq ""} { set name "COMP_$componentId" }
        incr elementCount [llength $elementIds]
        lappend componentRows "    {\"component_id\": $componentId, \"component_name\": [::HybridCore::jsonString $name], \"entity_type\": \"shell\", \"element_ids\": [::HybridCore::jsonIntArray $elementIds]}"
    }
    if {[llength $componentRows] < 2} {
        error [::WeldIntegrityCheck::txt \
            "选择范围内至少需要两个包含单元的 Component。" \
            "At least two selected components must contain elements."]
    }

    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    set exportStarted [clock milliseconds]
    set code [catch {
        eval *createmark elems 1 [list "by component id"] $componentIds
        eval *createmark nodes 1 [list "by component id"] $componentIds
        ::HWFlow::runHyperMeshIo export \
            [list *feoutput_select $exportTemplate $outputPath 1 0 0] $outputPath
    } err opts]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    if {$code} { return -options $opts $err }
    if {![file isfile $outputPath] || [file size $outputPath] == 0} {
        error "HyperMesh did not create the selected-component FEM export: $outputPath"
    }

    set componentJson [join $componentRows ",\n"]
    set manifest "{\n  \"schema_version\": \"1.0\",\n  \"format\": \"hm_weld_integrity_fem\",\n  \"run_id\": [::HybridCore::jsonString $taskId],\n  \"fem_path\": \"selected_components.fem\",\n  \"fem_size\": [file size $outputPath],\n  \"components\": \[\n$componentJson\n  \]\n}\n"
    ::HybridCore::writeTextFile $manifestPath $manifest

    set settings "{\n  \"max_search_distance\": $cfg(max_search_distance),\n  \"min_contact_length\": $cfg(min_contact_length),\n  \"min_continuous_nodes\": $cfg(min_continuous_nodes),\n  \"prefer_free_edges\": [::HybridCore::jsonBool $cfg(prefer_free_edges)],\n  \"ignore_shared_nodes\": [::HybridCore::jsonBool $cfg(ignore_shared_nodes)],\n  \"selected_component_ids\": [::HybridCore::jsonIntArray $componentIds],\n  \"excluded_component_ids\": [::HybridCore::jsonIntArray $ui(excludedCompIds)]\n}\n"
    ::HybridCore::writeTextFile [file join $inputDir settings.json] $settings

    set exportMs [expr {[clock milliseconds] - $exportStarted}]
    ::WeldIntegrityCheck::log INFO "native FEM exported components=[llength $componentRows] mapped_elements=$elementCount bytes=[file size $outputPath] export_ms=$exportMs"
    return [dict create components [llength $componentRows] elements $elementCount bytes [file size $outputPath] export_ms $exportMs]
}
