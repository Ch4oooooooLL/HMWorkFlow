proc ::RB2Bolt::writeHybridRequest {dir runId} {
    variable P
    set rows {}
    foreach key {axisMode gapTol offsetTol minGroupSize minBeamLength planeAbsTol planeFlatRatio radialAbsTol radialRelTol elemType compPrefix propName dryRun} {
        if {$key in {axisMode elemType compPrefix propName}} { set v [::HybridCore::jsonString $P($key)] } elseif {$key eq "dryRun"} { set v [::HybridCore::jsonBool $P($key)] } else { set v [::HybridCore::jsonNumber $P($key)] }
        lappend rows "    [::HybridCore::jsonString $key]: $v"
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"rbe2_bolt_connector\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": \[1\],\n  \"settings\": {\n[join $rows ,\n]\n  },\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $dir request.json] $json]
}
proc ::RB2Bolt::writeHybridMesh {dir elemIds} {
    set elementRecords {}; set allNodes {}
    foreach eid $elemIds {
        if {![::RB2Bolt::isRigidLink $eid]} { continue }
        set inode ""; catch {set inode [hm_getvalue elems id=$eid dataname=independentnode.id]}; if {$inode eq ""} { continue }
        set nodes {}; catch {set nodes [hm_getvalue elems id=$eid dataname=nodes]}; set ordered [list $inode]
        foreach n $nodes { if {$n != $inode} { lappend ordered $n } }
        if {[llength $ordered] < 3} { continue }; set allNodes [concat $allNodes $ordered]
        lappend elementRecords [dict create element_id $eid component_id 1 element_type RBE2 node_ids $ordered]
    }
    set uniqueNodes [lsort -integer -unique $allNodes]
    set coordinateMap [::HybridCore::readNodeCoordinatesBulk $uniqueNodes [list ::RB2Bolt::nodeXYZ]]
    set nodeRecords {}; foreach nid $uniqueNodes { set xyz [dict get $coordinateMap $nid]; lappend nodeRecords [list $nid [lindex $xyz 0] [lindex $xyz 1] [lindex $xyz 2]] }
    set componentRecords [list [dict create component_id 1 component_name RBE2_SELECTION mesh_class RIGID]]
    return [::HybridCore::writeBinaryMesh [file join $dir mesh.hmwf] \
        $componentRecords $nodeRecords $elementRecords]
}
proc ::RB2Bolt::writeHybridExisting {dir} {
    variable P
    catch {*clearmark elems 2}; set elems {}; if {![catch {*createmark elems 2 all}]} { catch {set elems [hm_getmark elems 2]} }; catch {*clearmark elems 2}
    set rows {}
    foreach eid $elems {
        set nodes {}; if {[catch {set nodes [hm_getvalue elems id=$eid dataname=nodes]}] || [llength $nodes] != 2} { continue }
        if {![::RB2Bolt::elemLooksLike1DConnector $eid $P(elemType)]} { continue }
        lappend rows "    {\"element_id\": $eid, \"node_1\": [lindex $nodes 0], \"node_2\": [lindex $nodes 1]}"
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"beam_segments\": \[\n[join $rows ,\n]\n  \]\n}\n"
    return [::HybridCore::writeTextFile [file join $dir existing_entities.json] $json]
}
proc ::RB2Bolt::exportHybridInputs {dir runId elemIds} { return [dict create request [::RB2Bolt::writeHybridRequest $dir $runId] mesh [::RB2Bolt::writeHybridMesh $dir $elemIds] existing [::RB2Bolt::writeHybridExisting $dir]] }
