proc ::RB2W::writeHybridRequest {taskDir runId compIds} {
    variable RIGID_TYPE
    variable RBE2_DOF
    set settings {}
    foreach key {MIN_HOLE_DIAMETER MAX_HOLE_DIAMETER CIRCULARITY_TOL ALLOW_OVAL_HOLES MAX_OVAL_AXIS_RATIO OVAL_RADIAL_FIT_TOL MIN_HOLE_EDGE_NODES MAX_HOLE_EDGE_NODES INNER_WASHER_NODE_LOOPS OUTER_RING_CIRCULARITY_TOL OUTER_OVAL_RADIAL_FIT_TOL OUTER_OVAL_AXIS_RATIO_TOL CENTER_OFFSET_TOL MIN_WASHER_WIDTH_ABS MIN_WASHER_WIDTH_RATIO WASHER_ELEM_COUNT_TOL MIN_OUTER_NODE_RATIO MAX_OUTER_NODE_RATIO} {
        upvar #0 ::RB2W::$key value
        if {$key eq "ALLOW_OVAL_HOLES"} { set encoded [::HybridCore::jsonBool $value] } else { set encoded [::HybridCore::jsonNumber $value] }
        lappend settings "    [::HybridCore::jsonString $key]: $encoded"
    }
    set outputRows {}
    foreach compId $compIds {
        set outputName [::RB2W::sanitizeNamePart [::RB2W::sourceOutputBaseName $compId] "AUTO_RBE2"]
        lappend outputRows "      [::HybridCore::jsonString $compId]: [::HybridCore::jsonString $outputName]"
    }
    lappend settings "    \"rigidType\": [::HybridCore::jsonString $RIGID_TYPE]"
    lappend settings "    \"dof\": [::HybridCore::jsonString $RBE2_DOF]"
    lappend settings "    \"outputComponentNames\": {\n[join $outputRows ,\n]\n    }"
    set modelState [::HybridCore::incrementalModelStateJson]
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"shell_washer_hole_rbe2\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": [::HybridCore::jsonIntArray $compIds],\n  \"settings\": {\n[join $settings ,\n]\n  },\n$modelState,\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $taskDir request.json] $json]
}

proc ::RB2W::exportElementSolverId {elementId} {
    foreach entityType {elems elements} {
        if {![catch {set solverInfo [hm_getsolverid $entityType $elementId -byid]}] &&
            [llength $solverInfo] > 0} {
            set solverId [lindex $solverInfo 0]
            if {[string is integer -strict $solverId] && $solverId > 0} { return $solverId }
        }
    }
    return $elementId
}

proc ::RB2W::exportSelectedComponentsFem {taskDir runId compIds} {
    set outputPath [file join $taskDir selected_components.fem]
    set exportTemplate [::RB2W::unusedRBE2ExportTemplate]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    set code [catch {
        eval *createmark elems 1 [list "by component id"] $compIds
        eval *createmark nodes 1 [list "by component id"] $compIds
        set elemCount [llength [hm_getmark elems 1]]
        set nodeCount [llength [hm_getmark nodes 1]]
        if {$elemCount == 0 || $nodeCount == 0} {
            error [::HWFlow::txt \
                "所选 Components 中没有可导出的网格。" \
                "The selected components contain no exportable mesh."]
        }
        ::HWFlow::runHyperMeshIo export \
            [list *feoutput_select $exportTemplate $outputPath 1 0 0] $outputPath
    } err opts]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    if {$code} { return -options $opts $err }
    if {![file isfile $outputPath] || [file size $outputPath] == 0} {
        error [::HWFlow::txt \
            "HyperMesh 未生成所选 Components 的 FEM 文件。" \
            "HyperMesh did not create the selected-component FEM export."]
    }

    set normalized [file normalize $outputPath]
    if {![info exists ::HybridCore::workerFileFingerprints]} {
        set ::HybridCore::workerFileFingerprints [dict create]
    }
    dict set ::HybridCore::workerFileFingerprints $normalized \
        "shell-rbe2-selected-fem-v1:[file size $normalized]:[clock clicks -milliseconds]"

    set componentRows {}
    foreach compId $compIds {
        set exportElemIds {}
        foreach elementId [::RB2W::getElemsByComp $compId] {
            lappend exportElemIds [::RB2W::exportElementSolverId $elementId]
        }
        lappend componentRows "    {\"component_id\": $compId, \"component_name\": [::HybridCore::jsonString [::RB2W::getComponentName $compId]], \"element_ids\": [::HybridCore::jsonIntArray [lsort -integer -unique $exportElemIds]]}"
    }
    set manifestPath [file join $taskDir selected_components_manifest.json]
    set manifest "{\n  \"schema_version\": \"1.0\",\n  \"format\": \"hm_selected_components_fem\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"fem_path\": \"selected_components.fem\",\n  \"fem_size\": [file size $outputPath],\n  \"components\": \[\n[join $componentRows ,\n]\n  \]\n}\n"
    ::HybridCore::writeTextFile $manifestPath $manifest
    ::HybridCore::log INFO "native FEM batch export components=[llength $compIds] elements=$elemCount nodes=$nodeCount bytes=[file size $outputPath]"
    return [dict create manifest $manifestPath fem $outputPath]
}

proc ::RB2W::writeHybridExisting {taskDir compIds} {
    set ids $compIds
    foreach compId $compIds {
        foreach name [::RB2W::outputComponentCandidatesForSource $compId] { set cid [::RB2W::componentIdByName $name]; if {$cid ne ""} { lappend ids $cid } }
    }
    set ids [::RB2W::uniq $ids]
    set found [::RB2W::rbe2CandidatesFromComponents $ids]
    if {[lindex $found 0]} { set elems [lindex $found 1] } else { set elems {}; foreach cid $ids { set elems [concat $elems [::RB2W::getElemsByComp $cid]] } }
    set rows {}
    foreach eid [::RB2W::uniq $elems] {
        if {![::RB2W::elemLooksLikeRBE2 $eid]} { continue }
        set center [::RB2W::rigidCenterNode $eid]; set dep {}
        foreach nid [::RB2W::getElemNodes $eid] { if {$center eq "" || $nid != $center} { lappend dep $nid } }
        if {[llength $dep] > 0} { lappend rows "    {\"element_id\": $eid, \"dependent_node_ids\": [::HybridCore::jsonIntArray [lsort -integer -unique $dep]]}" }
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"rbe2\": \[\n[join $rows ,\n]\n  \]\n}\n"
    return [::HybridCore::writeTextFile [file join $taskDir existing_entities.json] $json]
}

proc ::RB2W::exportHybridInputs {taskDir runId compIds} {
    set request [::RB2W::writeHybridRequest $taskDir $runId $compIds]
    set bundle [::RB2W::exportSelectedComponentsFem $taskDir $runId $compIds]
    return [dict create request $request manifest [dict get $bundle manifest] fem [dict get $bundle fem] existing [::RB2W::writeHybridExisting $taskDir $compIds] delta [file join $taskDir rigid_import.fem]]
}

proc ::RB2W::unusedRBE2ExportTemplate {} {
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

proc ::RB2W::writeUnusedRBE2Request {taskDir runId} {
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"shell_washer_hole_rbe2\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": \[\],\n  \"settings\": {\"mode\": \"find_unused_rbe2\"},\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $taskDir request.json] $json]
}

proc ::RB2W::exportWholeModelFem {taskDir} {
    set outputPath [file join $taskDir full_model.fem]
    set exportTemplate [::RB2W::unusedRBE2ExportTemplate]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    set code [catch {
        *createmark elems 1 all
        *createmark nodes 1 all
        set elemCount [llength [hm_getmark elems 1]]
        set nodeCount [llength [hm_getmark nodes 1]]
        if {$elemCount == 0 || $nodeCount == 0} {
            error [::HWFlow::txt "当前模型没有可导出的网格。" "The current model has no exportable mesh."]
        }
        ::HWFlow::runHyperMeshIo export \
            [list *feoutput_select $exportTemplate $outputPath 1 0 0] $outputPath
    } err opts]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    if {$code} { return -options $opts $err }
    if {![file isfile $outputPath] || [file size $outputPath] == 0} {
        error [::HWFlow::txt "HyperMesh 未生成全模型 FEM 文件。" "HyperMesh did not create the full-model FEM export."]
    }

    set normalized [file normalize $outputPath]
    if {![info exists ::HybridCore::workerFileFingerprints]} {
        set ::HybridCore::workerFileFingerprints [dict create]
    }
    dict set ::HybridCore::workerFileFingerprints $normalized \
        "unused-rbe2-fem-v1:[file size $normalized]:[clock clicks -milliseconds]"
    ::HybridCore::log INFO "full model FEM exported elements=$elemCount nodes=$nodeCount bytes=[file size $outputPath]"
    return $outputPath
}

proc ::RB2W::exportUnusedRBE2Inputs {taskDir runId} {
    return [dict create \
        request [::RB2W::writeUnusedRBE2Request $taskDir $runId] \
        mesh [::RB2W::exportWholeModelFem $taskDir]]
}
