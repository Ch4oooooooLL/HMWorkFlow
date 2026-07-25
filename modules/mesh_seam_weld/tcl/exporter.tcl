proc ::MeshSeamWeld::writeHybridPathRequest {dir runId mode sourceNodes candidates closedLoop} {
    variable cfg
    if {$mode eq "source"} { set selected $sourceNodes } else { set selected {} }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"mesh_seam_weld\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": \[1\],\n  \"settings\": {\"mode\": [::HybridCore::jsonString $mode], \"closed_loop\": [::HybridCore::jsonBool $closedLoop], \"selected_node_ids\": [::HybridCore::jsonIntArray $selected], \"source_node_ids\": [::HybridCore::jsonIntArray $sourceNodes], \"candidate_node_ids\": [::HybridCore::jsonIntArray $candidates], \"weld_mesh_size\": [::HybridCore::jsonNumber $cfg(weld_mesh_size)], \"mesh_path_param\": [::HybridCore::jsonNumber $cfg(mesh_path_param)]},\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $dir request.json] $json]
}
proc ::MeshSeamWeld::writeHybridPathMesh {dir mode sourceNodes candidates} {
    set elemIds {}
    if {$mode eq "source"} { foreach nid $sourceNodes { set elemIds [concat $elemIds [::MeshSeamWeld::nodeElementIds $nid]] } }
    if {$mode eq "target"} { set elemIds [::MeshSeamWeld::adjacentElementsForNodes $candidates] }
    set elemIds [::MeshSeamWeld::uniq $elemIds]; set allNodes [concat $sourceNodes $candidates]; set elementRecords {}
    foreach eid $elemIds { set nodes [::MeshSeamWeld::elemNodes $eid]; if {[llength $nodes] ni {3 4}} { continue }; set allNodes [concat $allNodes $nodes]; set type [expr {[llength $nodes]==3 ? "CTRIA3" : "CQUAD4"}]; lappend elementRecords [dict create element_id $eid component_id 1 element_type $type node_ids $nodes] }
    set uniqueNodes [lsort -integer -unique $allNodes]
    set coordinateMap [::HybridCore::readNodeCoordinatesBulk $uniqueNodes [list ::MeshSeamWeld::nodeXYZ]]
    set nodeRecords {}; foreach nid $uniqueNodes { set xyz [dict get $coordinateMap $nid]; lappend nodeRecords [list $nid [lindex $xyz 0] [lindex $xyz 1] [lindex $xyz 2]] }
    set componentRecords [list [dict create component_id 1 component_name SEAM_PATH mesh_class SHELL]]
    return [::HybridCore::writeBinaryMesh [file join $dir mesh.hmwf] \
        $componentRecords $nodeRecords $elementRecords]
}
proc ::MeshSeamWeld::exportHybridInputs {dir runId mode sourceNodes candidates closedLoop} {
    set existing [::HybridCore::writeTextFile [file join $dir existing_entities.json] "{\n  \"schema_version\": \"1.0\"\n}\n"]
    return [dict create request [::MeshSeamWeld::writeHybridPathRequest $dir $runId $mode $sourceNodes $candidates $closedLoop] mesh [::MeshSeamWeld::writeHybridPathMesh $dir $mode $sourceNodes $candidates] existing $existing]
}

proc ::MeshSeamWeld::componentExportName {componentId} {
    foreach dataname {name collector.name} {
        if {![catch {set value [hm_getvalue comps id=$componentId dataname=$dataname]}] &&
            [string trim $value] ne ""} {
            return $value
        }
    }
    return "COMP_$componentId"
}

proc ::MeshSeamWeld::writeComponentPlanRequest {dir runId selectedNodes sourceComponentIds targetComponentIds} {
    variable cfg
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"mesh_seam_weld\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": [::HybridCore::jsonIntArray $sourceComponentIds],\n  \"settings\": {\"mode\": \"component_plan\", \"selected_node_ids\": [::HybridCore::jsonIntArray $selectedNodes], \"source_component_ids\": [::HybridCore::jsonIntArray $sourceComponentIds], \"target_component_ids\": [::HybridCore::jsonIntArray $targetComponentIds], \"weld_mesh_size\": [::HybridCore::jsonNumber $cfg(weld_mesh_size)], \"patch_expand_layers\": [::HybridCore::jsonNumber $cfg(patch_expand_layers)]},\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $dir request.json] $json]
}

proc ::MeshSeamWeld::writeComponentPlanMesh {dir sourceComponentIds targetComponentIds} {
    set componentIds [lsort -integer -unique [concat $sourceComponentIds $targetComponentIds]]
    set componentRecords {}
    set elementRecords {}
    set allNodeIds {}
    foreach componentId $componentIds {
        lappend componentRecords [dict create component_id $componentId \
            component_name [::MeshSeamWeld::componentExportName $componentId] mesh_class SHELL]
        foreach elementId [::MeshSeamWeld::componentElementIds $componentId] {
            set nodeIds [::MeshSeamWeld::elemNodes $elementId]
            if {[llength $nodeIds] ni {3 4}} { continue }
            set elementType [expr {[llength $nodeIds] == 3 ? "CTRIA3" : "CQUAD4"}]
            lappend elementRecords [dict create element_id $elementId component_id $componentId \
                element_type $elementType node_ids $nodeIds]
            set allNodeIds [concat $allNodeIds $nodeIds]
        }
    }
    set allNodeIds [lsort -integer -unique $allNodeIds]
    set coordinateMap [::HybridCore::readNodeCoordinatesBulk $allNodeIds \
        [list ::MeshSeamWeld::nodeXYZ]]
    set nodeRecords {}
    foreach nodeId $allNodeIds {
        set xyz [dict get $coordinateMap $nodeId]
        lappend nodeRecords [list $nodeId [lindex $xyz 0] [lindex $xyz 1] [lindex $xyz 2]]
    }
    return [::HybridCore::writeBinaryMesh [file join $dir mesh.hmwf] \
        $componentRecords $nodeRecords $elementRecords]
}

proc ::MeshSeamWeld::exportComponentPlanInputs {dir runId selectedNodes sourceComponentIds targetComponentIds} {
    set existing [::HybridCore::writeTextFile [file join $dir existing_entities.json] \
        "{\n  \"schema_version\": \"1.0\"\n}\n"]
    return [dict create \
        request [::MeshSeamWeld::writeComponentPlanRequest $dir $runId $selectedNodes $sourceComponentIds $targetComponentIds] \
        mesh [::MeshSeamWeld::writeComponentPlanMesh $dir $sourceComponentIds $targetComponentIds] \
        existing $existing]
}

proc ::MeshSeamWeld::writeInternalComponentPlanRequest {dir runId selectedNode sourceComponentId targetComponentIds} {
    variable cfg
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"mesh_seam_weld\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": [::HybridCore::jsonIntArray [list $sourceComponentId]],\n  \"settings\": {\"mode\": \"internal_component_plan\", \"selected_node_ids\": [::HybridCore::jsonIntArray [list $selectedNode]], \"source_component_ids\": [::HybridCore::jsonIntArray [list $sourceComponentId]], \"target_component_ids\": [::HybridCore::jsonIntArray $targetComponentIds], \"weld_mesh_size\": [::HybridCore::jsonNumber $cfg(weld_mesh_size)], \"patch_expand_layers\": [::HybridCore::jsonNumber $cfg(patch_expand_layers)]},\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $dir request.json] $json]
}

proc ::MeshSeamWeld::optistructExportTemplate {} {
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
    error [::HWFlow::txt \
        "找不到 HyperMesh OptiStruct FEM 导出模板。" \
        "Could not locate the HyperMesh OptiStruct FEM export template."]
}

proc ::MeshSeamWeld::exportInternalComponentFemBundle {dir runId sourceComponentId targetComponentIds} {
    set componentIds [lsort -integer -unique [concat [list $sourceComponentId] $targetComponentIds]]
    set outputPath [file join $dir selected_components.fem]
    set exportTemplate [::MeshSeamWeld::optistructExportTemplate]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    set code [catch {
        eval *createmark elems 1 [list "by component id"] $componentIds
        eval *createmark nodes 1 [list "by component id"] $componentIds
        set elemCount [llength [hm_getmark elems 1]]
        set nodeCount [llength [hm_getmark nodes 1]]
        if {$elemCount == 0 || $nodeCount == 0} {
            error "Selected source/target components have no exportable shell mesh."
        }
        ::HWFlow::runHyperMeshIo export \
            [list *feoutput_select $exportTemplate $outputPath 1 0 0] $outputPath
    } err opts]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    if {$code} { return -options $opts $err }
    if {![file isfile $outputPath] || [file size $outputPath] == 0} {
        error "HyperMesh did not create the selected component FEM export: $outputPath"
    }
    # The task path is unique and was just written by HyperMesh.  Register a
    # cheap identity so the persistent-worker bridge does not reread and hash
    # a multi-megabyte FEM on Tcl's single thread before Python starts.
    set normalized [file normalize $outputPath]
    if {![info exists ::HybridCore::workerFileFingerprints]} {
        set ::HybridCore::workerFileFingerprints [dict create]
    }
    dict set ::HybridCore::workerFileFingerprints $normalized \
        "mesh-fem-v1:[file size $normalized]:[clock clicks -milliseconds]"
    set componentEntries {}
    foreach componentId $componentIds {
        set role [expr {$componentId == $sourceComponentId ? "source" : "target"}]
        set elementIds [::MeshSeamWeld::componentElementIds $componentId]
        lappend componentEntries "    {\"component_id\": $componentId, \"component_name\": [::HybridCore::jsonString [::MeshSeamWeld::componentExportName $componentId]], \"role\": \"$role\", \"element_ids\": [::HybridCore::jsonIntArray $elementIds]}"
    }
    set manifestPath [file join $dir selected_components_manifest.json]
    set componentJson [join $componentEntries ",\n"]
    set manifest "{\n  \"schema_version\": \"1.0\",\n  \"format\": \"hm_selected_components_fem\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"fem_path\": \"selected_components.fem\",\n  \"fem_size\": [file size $outputPath],\n  \"components\": \[\n$componentJson\n  \]\n}\n"
    ::HybridCore::writeTextFile $manifestPath $manifest
    return [dict create manifest $manifestPath fem $outputPath]
}

proc ::MeshSeamWeld::exportInternalComponentPlanInputs {dir runId selectedNode sourceComponentId targetComponentIds} {
    set request [::MeshSeamWeld::writeInternalComponentPlanRequest \
        $dir $runId $selectedNode $sourceComponentId $targetComponentIds]
    set exportStarted [clock milliseconds]
    set bundle [::MeshSeamWeld::exportInternalComponentFemBundle \
        $dir $runId $sourceComponentId $targetComponentIds]
    set mesh [dict get $bundle manifest]
    set fem [dict get $bundle fem]
    set exportMs [expr {[clock milliseconds] - $exportStarted}]
    ::HybridCore::log INFO "PERF mesh_seam_weld native_fem_export source_component=$sourceComponentId target_components=[llength $targetComponentIds] bytes=[file size $fem] export_ms=$exportMs"
    set existing [::HybridCore::writeTextFile [file join $dir existing_entities.json] \
        "{\n  \"schema_version\": \"1.0\"\n}\n"]
    return [dict create request $request mesh $mesh existing $existing export_ms $exportMs]
}
