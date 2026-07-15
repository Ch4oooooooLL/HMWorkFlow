proc ::WeldIntegrityCheck::elementType {nodeIds} {
    switch -- [llength $nodeIds] { 3 { return CTRIA3 } 4 { return CQUAD4 } default { return "" } }
}

proc ::WeldIntegrityCheck::exportInput {componentIds} {
    variable taskDir; variable ui; variable cfg
    set inputDir [file join $taskDir input]
    set componentRows {}; set elementLines [list "element_id,component_id,element_type,node_ids"]; set allNodes {}; set shellCount 0; set shellComponentCount 0
    foreach componentId $componentIds {
        set name [::HWFlow::componentName $componentId]
        if {$name eq ""} { set name "COMP_$componentId" }
        set componentShellCount 0
        catch {*clearmark elems 1}
        if {[catch {eval *createmark elems 1 "by comp id" $componentId} markErr]} {
            ::WeldIntegrityCheck::log WARN "component element mark failed component=$componentId error=$markErr"
            continue
        }
        foreach elementId [hm_getmark elems 1] {
            if {[catch {set nodeIds [hm_getvalue elems id=$elementId dataname=nodes]}]} { continue }
            set type [::WeldIntegrityCheck::elementType $nodeIds]
            if {$type eq ""} { continue }
            incr shellCount; incr componentShellCount; set allNodes [concat $allNodes $nodeIds]
            lappend elementLines "$elementId,$componentId,$type,\"[join $nodeIds { }]\""
        }
        if {$componentShellCount > 0} {
            incr shellComponentCount
            lappend componentRows "  {\"id\": $componentId, \"name\": [::HybridCore::jsonString $name], \"entity_type\": \"shell\"}"
        }
    }
    if {$shellComponentCount < 2} { error [::WeldIntegrityCheck::txt "选择范围内至少需要两个包含有效 Shell 单元的 Component。" "At least two selected components must contain valid shell elements."] }
    ::HybridCore::writeTextFile [file join $inputDir components.json] "\[\n[join $componentRows ,\n]\n\]\n"
    set nodeLines [list "node_id,x,y,z"]
    foreach nodeId [lsort -integer -unique $allNodes] {
        if {[catch {set x [hm_getvalue nodes id=$nodeId dataname=x]}] || [catch {set y [hm_getvalue nodes id=$nodeId dataname=y]}] || [catch {set z [hm_getvalue nodes id=$nodeId dataname=z]}]} { continue }
        lappend nodeLines "$nodeId,$x,$y,$z"
    }
    ::HybridCore::writeTextFile [file join $inputDir nodes.csv] "[join $nodeLines \n]\n"
    ::HybridCore::writeTextFile [file join $inputDir elements.csv] "[join $elementLines \n]\n"
    # HM2019 installations differ in their free-edge command surface. The
    # stable shell connectivity is exported and Python derives incidence==1.
    ::HybridCore::writeTextFile [file join $inputDir free_edges.csv] "component_id,node_1,node_2,owner_element\n"
    set settings "{\n  \"max_search_distance\": $cfg(max_search_distance),\n  \"min_contact_length\": $cfg(min_contact_length),\n  \"min_continuous_nodes\": $cfg(min_continuous_nodes),\n  \"prefer_free_edges\": [::HybridCore::jsonBool $cfg(prefer_free_edges)],\n  \"ignore_shared_nodes\": [::HybridCore::jsonBool $cfg(ignore_shared_nodes)],\n  \"selected_component_ids\": [::HybridCore::jsonIntArray $componentIds],\n  \"excluded_component_ids\": [::HybridCore::jsonIntArray $ui(excludedCompIds)]\n}\n"
    ::HybridCore::writeTextFile [file join $inputDir settings.json] $settings
    ::WeldIntegrityCheck::log INFO "exported components=[llength $componentRows] shell_elements=$shellCount nodes=[expr {[llength $nodeLines]-1}]"
    return [dict create components [llength $componentRows] elements $shellCount nodes [expr {[llength $nodeLines]-1}]]
}
