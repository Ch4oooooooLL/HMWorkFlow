proc ::AutoHoleRBE2::hybridElementType {elementId} {
    set config [string toupper [string trim [::AutoHoleRBE2::elemConfig $elementId]]]
    switch -- $config {
        204 - TETRA4 - CTETRA { return CTETRA }
        205 - PYRA5 - CPYRA { return CPYRA }
        206 - PENTA6 - CPENTA { return CPENTA }
        208 - HEXA8 - CHEXA { return CHEXA }
    }
    error "Unsupported solid element config '$config' for element $elementId"
}

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
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"auto_hole_rbe2\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": [::HybridCore::jsonIntArray $ui(selectedComps)],\n  \"settings\": {\n[join $settings ,\n]\n  },\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $taskDir request.json] $json]
}

proc ::AutoHoleRBE2::writeHybridMesh {taskDir} {
    variable ui
    set componentRows {}; set elementRows {}; set allNodes {}
    foreach componentId $ui(selectedComps) {
        lappend componentRows "    {\"component_id\": $componentId, \"component_name\": [::HybridCore::jsonString [::AutoHoleRBE2::hybridComponentName $componentId]], \"mesh_class\": \"SOLID\"}"
        foreach elementId [::AutoHoleRBE2::getElemsByComp $componentId] {
            set nodes [::AutoHoleRBE2::elemNodes $elementId]
            set allNodes [concat $allNodes $nodes]
            lappend elementRows "    {\"element_id\": $elementId, \"component_id\": $componentId, \"element_type\": [::HybridCore::jsonString [::AutoHoleRBE2::hybridElementType $elementId]], \"node_ids\": [::HybridCore::jsonIntArray $nodes]}"
        }
    }
    set nodeRows {}
    foreach nodeId [lsort -integer -unique $allNodes] {
        set xyz [::AutoHoleRBE2::nodeXYZ $nodeId]
        lappend nodeRows "    \[$nodeId, [lindex $xyz 0], [lindex $xyz 1], [lindex $xyz 2]\]"
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"components\": \[\n[join $componentRows ,\n]\n  \],\n  \"nodes\": \[\n[join $nodeRows ,\n]\n  \],\n  \"elements\": \[\n[join $elementRows ,\n]\n  \]\n}\n"
    ::HybridCore::log INFO "mesh export components=[llength $componentRows] elements=[llength $elementRows] nodes=[llength $nodeRows]"
    return [::HybridCore::writeTextFile [file join $taskDir mesh.json] $json]
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
            foreach nodeId $nodes { if {$nodeId != $center} { lappend dependent $nodeId } }
            lappend rows "    {\"element_id\": $elementId, \"independent_node_id\": $center, \"dependent_node_ids\": [::HybridCore::jsonIntArray [lsort -integer -unique $dependent]], \"component_id\": $componentId}"
        }
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"rbe2\": \[\n[join $rows ,\n]\n  \]\n}\n"
    return [::HybridCore::writeTextFile [file join $taskDir existing_entities.json] $json]
}

proc ::AutoHoleRBE2::exportHybridInputs {taskDir runId} {
    set request [::AutoHoleRBE2::writeHybridRequest $taskDir $runId]
    set mesh [::AutoHoleRBE2::writeHybridMesh $taskDir]
    set existing [::AutoHoleRBE2::writeHybridExisting $taskDir]
    return [dict create request $request mesh $mesh existing $existing]
}
