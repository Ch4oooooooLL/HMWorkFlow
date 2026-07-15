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
    set elemIds [::MeshSeamWeld::uniq $elemIds]; set allNodes [concat $sourceNodes $candidates]; set erows {}
    foreach eid $elemIds { set nodes [::MeshSeamWeld::elemNodes $eid]; if {[llength $nodes] ni {3 4}} { continue }; set allNodes [concat $allNodes $nodes]; set type [expr {[llength $nodes]==3 ? "CTRIA3" : "CQUAD4"}]; lappend erows "    {\"element_id\": $eid, \"component_id\": 1, \"element_type\": \"$type\", \"node_ids\": [::HybridCore::jsonIntArray $nodes]}" }
    set nrows {}; foreach nid [lsort -integer -unique $allNodes] { set xyz [::MeshSeamWeld::nodeXYZ $nid]; lappend nrows "    \[$nid, [lindex $xyz 0], [lindex $xyz 1], [lindex $xyz 2]\]" }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"components\": \[{\"component_id\": 1, \"component_name\": \"SEAM_PATH\", \"mesh_class\": \"SHELL\"}\],\n  \"nodes\": \[\n[join $nrows ,\n]\n  \],\n  \"elements\": \[\n[join $erows ,\n]\n  \]\n}\n"
    return [::HybridCore::writeTextFile [file join $dir mesh.json] $json]
}
proc ::MeshSeamWeld::exportHybridInputs {dir runId mode sourceNodes candidates closedLoop} {
    set existing [::HybridCore::writeTextFile [file join $dir existing_entities.json] "{\n  \"schema_version\": \"1.0\"\n}\n"]
    return [dict create request [::MeshSeamWeld::writeHybridPathRequest $dir $runId $mode $sourceNodes $candidates $closedLoop] mesh [::MeshSeamWeld::writeHybridPathMesh $dir $mode $sourceNodes $candidates] existing $existing]
}
