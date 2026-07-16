proc ::RB2W::hybridShellType {eid nodes} {
    set cfg ""; catch {set cfg [hm_getvalue elems id=$eid dataname=config]}
    set u [string toupper "$cfg"]
    if {[llength $nodes] == 3 || [regexp {TRIA|103} $u]} { return CTRIA3 }
    if {[llength $nodes] == 4 || [regexp {QUAD|104} $u]} { return CQUAD4 }
    error "Unsupported shell element $eid config=$cfg nodeCount=[llength $nodes]"
}

proc ::RB2W::writeHybridRequest {taskDir runId compId} {
    variable RIGID_TYPE
    variable RBE2_DOF
    set settings {}
    foreach key {MIN_HOLE_DIAMETER MAX_HOLE_DIAMETER CIRCULARITY_TOL ALLOW_OVAL_HOLES MAX_OVAL_AXIS_RATIO OVAL_RADIAL_FIT_TOL MIN_HOLE_EDGE_NODES MAX_HOLE_EDGE_NODES INNER_WASHER_NODE_LOOPS OUTER_RING_CIRCULARITY_TOL OUTER_OVAL_RADIAL_FIT_TOL OUTER_OVAL_AXIS_RATIO_TOL CENTER_OFFSET_TOL MIN_WASHER_WIDTH_ABS MIN_WASHER_WIDTH_RATIO WASHER_ELEM_COUNT_TOL MIN_OUTER_NODE_RATIO MAX_OUTER_NODE_RATIO} {
        upvar #0 ::RB2W::$key value
        if {$key eq "ALLOW_OVAL_HOLES"} { set encoded [::HybridCore::jsonBool $value] } else { set encoded [::HybridCore::jsonNumber $value] }
        lappend settings "    [::HybridCore::jsonString $key]: $encoded"
    }
    set outputName [::RB2W::sanitizeNamePart [::RB2W::sourceOutputBaseName $compId] "AUTO_RBE2"]
    lappend settings "    \"rigidType\": [::HybridCore::jsonString $RIGID_TYPE]"
    lappend settings "    \"dof\": [::HybridCore::jsonString $RBE2_DOF]"
    lappend settings "    \"outputComponentName\": [::HybridCore::jsonString $outputName]"
    set modelState [::HybridCore::incrementalModelStateJson]
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"shell_washer_hole_rbe2\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": \[$compId\],\n  \"settings\": {\n[join $settings ,\n]\n  },\n$modelState,\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $taskDir request.json] $json]
}

proc ::RB2W::writeHybridMesh {taskDir compId} {
    set elementRecords {}; set allNodes {}
    foreach eid [::RB2W::getElemsByComp $compId] {
        if {[::RB2W::elemLooksLikeRBE2 $eid]} { continue }
        set nodes [::RB2W::getElemNodes $eid]
        if {[llength $nodes] ni {3 4}} { continue }
        set allNodes [concat $allNodes $nodes]
        lappend elementRecords [dict create element_id $eid component_id $compId \
            element_type [::RB2W::hybridShellType $eid $nodes] node_ids $nodes]
    }
    set nodeRecords {}
    set uniqueNodes [lsort -integer -unique $allNodes]
    set coordinateMap [::HybridCore::readNodeCoordinatesBulk $uniqueNodes [list ::RB2W::getNodeXYZ]]
    foreach nid $uniqueNodes {
        set xyz [dict get $coordinateMap $nid]
        lappend nodeRecords [list $nid [lindex $xyz 0] [lindex $xyz 1] [lindex $xyz 2]]
    }
    set cname [::RB2W::getComponentName $compId]
    set componentRecords [list [dict create component_id $compId component_name $cname mesh_class SHELL]]
    ::HybridCore::log INFO "binary mesh export component=$compId elements=[llength $elementRecords] nodes=[llength $nodeRecords]"
    return [::HybridCore::writeBinaryMesh [file join $taskDir mesh.hmwf] \
        $componentRecords $nodeRecords $elementRecords]
}

proc ::RB2W::writeHybridExisting {taskDir compId} {
    set ids [list $compId]
    foreach name [::RB2W::outputComponentCandidatesForSource $compId] { set cid [::RB2W::componentIdByName $name]; if {$cid ne ""} { lappend ids $cid } }
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

proc ::RB2W::exportHybridInputs {taskDir runId compId} {
    return [dict create request [::RB2W::writeHybridRequest $taskDir $runId $compId] mesh [::RB2W::writeHybridMesh $taskDir $compId] existing [::RB2W::writeHybridExisting $taskDir $compId] delta [file join $taskDir rigid_import.fem]]
}
