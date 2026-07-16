proc ::RB2Bolt::maxEntityId {entityTypes} {
    return [::HybridCore::maxEntityId $entityTypes]
}

proc ::RB2Bolt::entityNameRegistryJson {entityTypes} {
    return [::HybridCore::entityNameRegistryJson $entityTypes]
}

proc ::RB2Bolt::writeHybridRequest {dir runId} {
    variable P
    set rows {}
    foreach key {axisMode gapTol offsetTol minGroupSize minBeamLength planeAbsTol planeFlatRatio radialAbsTol radialRelTol elemType compPrefix propName dryRun} {
        if {$key in {axisMode elemType compPrefix propName}} { set v [::HybridCore::jsonString $P($key)] } elseif {$key eq "dryRun"} { set v [::HybridCore::jsonBool $P($key)] } else { set v [::HybridCore::jsonNumber $P($key)] }
        lappend rows "    [::HybridCore::jsonString $key]: $v"
    }
    set modelState [::HybridCore::incrementalModelStateJson]
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"rbe2_bolt_connector\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": \[\],\n  \"settings\": {\n[join $rows ,\n]\n  },\n$modelState,\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $dir request.json] $json]
}

proc ::RB2Bolt::appendFemRBE2 {linesVar eid ordered} {
    upvar 1 $linesVar lines
    set first [lrange [lrange $ordered 1 end] 0 3]
    lappend lines "RBE2,$eid,[lindex $ordered 0],123456,[join $first ,]"
    set remaining [lrange $ordered 5 end]
    while {[llength $remaining] > 0} {
        set chunk [lrange $remaining 0 6]
        lappend lines "+,[join $chunk ,]"
        set remaining [lrange $remaining 7 end]
    }
}

proc ::RB2Bolt::writeSelectionFem {dir elemIds} {
    set lines [list "$ HMWF_RBE2_SELECTION_FEM_V1" "BEGIN BULK"]
    set allNodes {}
    set rigidRows {}
    set centerIds {}
    foreach eid $elemIds {
        if {![::RB2Bolt::isRigidLink $eid]} { continue }
        set inode ""; catch {set inode [hm_getvalue elems id=$eid dataname=independentnode.id]}
        if {$inode eq ""} { error "FEM_EXPORT_FAILED stage=read_rbe2 element=$eid detail=missing_independent_node" }
        set nodes {}; catch {set nodes [hm_getvalue elems id=$eid dataname=nodes]}
        set ordered [list $inode]
        foreach nid $nodes { if {$nid != $inode} { lappend ordered $nid } }
        if {[llength $ordered] < 3} { error "FEM_EXPORT_FAILED stage=read_rbe2 element=$eid detail=fewer_than_two_dependents" }
        lappend rigidRows [list $eid $ordered]
        lappend centerIds $inode
        set allNodes [concat $allNodes $ordered]
    }
    if {[llength $rigidRows] == 0} { error "FEM_EXPORT_FAILED stage=collect detail=no_valid_rbe2" }

    array set centerSet {}
    foreach nid $centerIds { set centerSet($nid) 1 }
    set beamRows {}
    set oneD [::RB2Bolt::markOneDElementCandidates 2]
    if {[lindex $oneD 0]} {
        set elems [lindex $oneD 1]
    } else {
        catch {*clearmark elems 2}; set elems {}
        if {![catch {*createmark elems 2 all}]} { catch {set elems [hm_getmark elems 2]} }
        catch {*clearmark elems 2}
    }
    foreach eid $elems {
        if {![::RB2Bolt::elemLooksLike1DConnector $eid CBEAM]} { continue }
        set nodes {}; catch {set nodes [hm_getvalue elems id=$eid dataname=nodes]}
        if {[llength $nodes] != 2} { continue }
        set n1 [lindex $nodes 0]; set n2 [lindex $nodes 1]
        if {[info exists centerSet($n1)] && [info exists centerSet($n2)]} {
            lappend beamRows [list $eid $n1 $n2]
        }
    }

    set uniqueNodes [lsort -integer -unique $allNodes]
    if {[catch {set coordinateMap [::HybridCore::readNodeCoordinatesBulk $uniqueNodes [list ::RB2Bolt::nodeXYZ]]} err]} {
        error "FEM_EXPORT_FAILED stage=read_grid_bulk detail=$err"
    }
    foreach nid $uniqueNodes {
        set xyz [dict get $coordinateMap $nid]
        lappend lines "GRID,$nid,,[lindex $xyz 0],[lindex $xyz 1],[lindex $xyz 2]"
    }
    foreach row $rigidRows { ::RB2Bolt::appendFemRBE2 lines [lindex $row 0] [lindex $row 1] }
    foreach row $beamRows { lappend lines "CBEAM,[lindex $row 0],0,[lindex $row 1],[lindex $row 2],0.0,1.0,0.0" }
    lappend lines ENDDATA ""
    set path [file join $dir selection.fem]
    ::HybridCore::writeTextFile $path [join $lines \n]
    return $path
}

proc ::RB2Bolt::exportHybridInputs {dir runId elemIds} {
    return [dict create request [::RB2Bolt::writeHybridRequest $dir $runId] mesh [::RB2Bolt::writeSelectionFem $dir $elemIds] delta [file join $dir bolt_import.fem]]
}
