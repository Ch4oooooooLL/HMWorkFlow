proc ::AutoHoleRBE2::hybridComponentName {componentId} {
    if {![catch {set value [hm_getvalue comps id=$componentId dataname=name]}] && $value ne ""} { return $value }
    return "COMP_$componentId"
}

proc ::AutoHoleRBE2::writeHybridRequest {taskDir runId} {
    variable cfg; variable ui
    set settings [list]
    foreach key {featureAngleDeg loopNormalTolDeg cylFitTol loopRadiusTol minWallNodes minLoopNodes minRadius maxRadius innerNormalMaxDot eps} {
        lappend settings "    [::HybridCore::jsonString $key]: [::HybridCore::jsonNumber $cfg($key)]"
    }
    lappend settings "    \"requireInnerNormal\": [::HybridCore::jsonBool $cfg(requireInnerNormal)]"
    lappend settings "    \"rigidType\": [::HybridCore::jsonString $cfg(rigidType)]"
    lappend settings "    \"dof\": [::HybridCore::jsonString $cfg(dof)]"
    lappend settings "    \"outputComponentName\": [::HybridCore::jsonString $cfg(resultCompName)]"
    set modelState [::HybridCore::incrementalModelStateJson]
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"auto_hole_rbe2\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": [::HybridCore::jsonIntArray $ui(selectedComps)],\n  \"settings\": {\n[join $settings ,\n]\n  },\n$modelState,\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $taskDir request.json] $json]
}

proc ::AutoHoleRBE2::collectHybridSurfaceFaces {} {
    variable cfg; variable ui; variable stat
    set components $ui(selectedComps)
    if {[llength $components] == 0} { error "No solid components selected" }

    # Surface-only mode deliberately avoids materializing every source-solid
    # element ID merely for a count; *findfaces validates the selected scope.
    set stat(sourceElems) [::HWFlow::txt "未扫描（仅表面）" "not scanned (surface-only)"]

    # ^faces is a disposable transfer component.  Always rebuild it so the
    # entire component can be exported directly without per-face filtering.
    ::AutoHoleRBE2::deleteComponentByName $cfg(faceCompName)

    ::AutoHoleRBE2::message [::HWFlow::txt "正在生成自由面并直接导出 FEM..." "Generating free faces for direct FEM export..."]
    ::AutoHoleRBE2::clearMarks
    eval *createmark comps 1 $components
    set findFacesStarted [clock milliseconds]
    if {[catch {*findfaces components 1} faceErr]} {
        error "Failed to create free faces: $faceErr"
    }
    ::HybridCore::log INFO "surface generation milliseconds=[expr {[clock milliseconds]-$findFacesStarted}]"
    set faceCompId [::AutoHoleRBE2::componentIdByName $cfg(faceCompName)]
    if {$faceCompId eq ""} { error "The free-face component $cfg(faceCompName) was not created" }

    catch {*clearmark elems 2}
    *createmark elems 2 "by component id" $faceCompId
    set stat(freeFaces) [llength [hm_getmark elems 2]]
    catch {*clearmark elems 2}
    set stat(validFaces) $stat(freeFaces)
    if {$stat(validFaces) == 0} { error "No generated free-face elements were collected" }

    ::AutoHoleRBE2::clearMarks
    return [dict create \
        face_component_id $faceCompId \
        face_count $stat(freeFaces) \
        source_component_id [lindex $components 0]]
}

proc ::AutoHoleRBE2::surfaceFemExportTemplate {} {
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

proc ::AutoHoleRBE2::surfaceExportNodeId {nodeId} {
    foreach entityType {nodes node} {
        if {![catch {set solverInfo [hm_getsolverid $entityType $nodeId -byid]}] &&
            [llength $solverInfo] > 0} {
            set solverId [lindex $solverInfo 0]
            if {[string is integer -strict $solverId] && $solverId > 0} { return $solverId }
        }
    }
    return $nodeId
}

proc ::AutoHoleRBE2::prepareSurfaceFacesForFemExport {faceComponentId} {
    # *findfaces creates genuine tria3/quad4 shell configurations, but their
    # solver element type can remain the temporary visualization type.  The
    # OptiStruct output template silently omits those elements.  Map only the
    # disposable ^faces elements to the standard shell type before export.
    catch {*clearmark elems 1}
    *createmark elems 1 "by component id" $faceComponentId
    set markedCount [llength [hm_getmark elems 1]]
    if {$markedCount == 0} { error "Generated free-face component contains no elements" }

    # HyperMesh 2019 requires numeric config/type pairs.  For the OptiStruct
    # profile, type 1 is CTRIA3 for config 2 and CQUAD4 for config 104.
    *elementtype 2 1
    *elementtype 104 1
    if {[catch {*elementsettypes 1} typeErr]} {
        error "Failed to map generated free faces to CTRIA3/CQUAD4: $typeErr"
    }
    ::HybridCore::log INFO "prepared generated face element types count=$markedCount"
    return $markedCount
}

proc ::AutoHoleRBE2::exportHybridSurfaceFem {taskDir runId surfaceData} {
    variable cfg; variable ui
    set femPath [file join $taskDir surface_faces.fem]
    set manifestPath [file join $taskDir surface_faces_manifest.json]
    set faceCount [dict get $surfaceData face_count]
    if {$faceCount == 0} {
        error "No generated free faces are available for FEM export"
    }

    set template [::AutoHoleRBE2::surfaceFemExportTemplate]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    set code [catch {
        set faceComponentId [dict get $surfaceData face_component_id]
        ::AutoHoleRBE2::prepareSurfaceFacesForFemExport $faceComponentId
        *createmark elems 1 "by component id" $faceComponentId
        *createmark nodes 1 "by component id" $faceComponentId
        set nodeCount [llength [hm_getmark nodes 1]]
        if {$nodeCount == 0} { error "Generated free faces have no connected nodes" }
        ::HWFlow::runHyperMeshIo export \
            [list *feoutput_select $template $femPath 1 0 0] $femPath
    } err opts]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    if {$code} { return -options $opts $err }
    if {![file isfile $femPath] || [file size $femPath] == 0} {
        error "HyperMesh did not create the generated free-face FEM export"
    }

    set normalized [file normalize $femPath]
    if {![info exists ::HybridCore::workerFileFingerprints]} {
        set ::HybridCore::workerFileFingerprints [dict create]
    }
    dict set ::HybridCore::workerFileFingerprints $normalized \
        "auto-hole-surface-fem-v1:[file size $normalized]:[clock clicks -milliseconds]"

    set sourceComponentId [dict get $surfaceData source_component_id]
    set manifest "{\n  \"schema_version\": \"1.0\",\n  \"format\": \"hm_surface_faces_fem\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"fem_path\": \"surface_faces.fem\",\n  \"source_component_id\": $sourceComponentId,\n  \"source_component_name\": [::HybridCore::jsonString [::AutoHoleRBE2::hybridComponentName $sourceComponentId]]\n}\n"
    ::HybridCore::writeTextFile $manifestPath $manifest
    ::HybridCore::log INFO "native surface FEM export faces=$faceCount nodes=$nodeCount bytes=[file size $femPath]"
    return $manifestPath
}

proc ::AutoHoleRBE2::writeHybridExisting {taskDir} {
    variable cfg
    set rows {}
    set componentId [::AutoHoleRBE2::componentIdByName $cfg(resultCompName)]
    if {$componentId ne ""} {
        foreach elementId [::AutoHoleRBE2::getElemsByComp $componentId] {
            if {![::AutoHoleRBE2::elemLooksLikeRBE2 $elementId]} { continue }
            set center [::AutoHoleRBE2::rigidCenterNode $elementId]
            set nodes [::AutoHoleRBE2::uniq [::AutoHoleRBE2::elemNodes $elementId]]
            set dependent {}
            foreach nodeId $nodes {
                if {$nodeId != $center} {
                    lappend dependent [::AutoHoleRBE2::surfaceExportNodeId $nodeId]
                }
            }
            set solverCenter [::AutoHoleRBE2::surfaceExportNodeId $center]
            lappend rows "    {\"element_id\": $elementId, \"independent_node_id\": $solverCenter, \"dependent_node_ids\": [::HybridCore::jsonIntArray [lsort -integer -unique $dependent]], \"component_id\": $componentId}"
        }
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"rbe2\": \[\n[join $rows ,\n]\n  \]\n}\n"
    return [::HybridCore::writeTextFile [file join $taskDir existing_entities.json] $json]
}

proc ::AutoHoleRBE2::exportHybridInputs {taskDir runId} {
    set surfaceData [::AutoHoleRBE2::collectHybridSurfaceFaces]
    set request [::AutoHoleRBE2::writeHybridRequest $taskDir $runId]
    set mesh [::AutoHoleRBE2::exportHybridSurfaceFem $taskDir $runId $surfaceData]
    set existing [::AutoHoleRBE2::writeHybridExisting $taskDir]
    return [dict create request $request mesh $mesh existing $existing]
}
