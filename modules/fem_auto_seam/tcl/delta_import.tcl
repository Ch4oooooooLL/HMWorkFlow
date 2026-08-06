proc ::FemAutoSeam::saveAutoSnapshot {path} {
    file mkdir [file dirname $path]
    if {[file exists $path]} { file delete -force $path }
    catch {hm_answernext yes}
    if {[catch {uplevel #0 [list *writefile [file nativename $path] 1]} err opts]} { return -options $opts $err }
    if {![file isfile $path] || [file size $path] == 0} { error "HyperMesh did not create a valid auto-seam snapshot" }
    return $path
}

proc ::FemAutoSeam::restoreAutoSnapshot {path} {
    if {![file isfile $path]} { error "auto-seam recovery snapshot is missing: $path" }
    catch {hm_answernext yes}
    uplevel #0 [list *readfile [file nativename $path] 0]
    catch {::HWFlow::refreshBrowser}
}

proc ::FemAutoSeam::applyAutoDelta {taskDir plans} {
    set delta [file join $taskDir output delta.fem]
    if {![file isfile $delta]} { error "planned delta FEM is missing: $delta" }
    set expected {}
    foreach plan $plans {
        if {[dict get $plan status] ne "READY"} { continue }
        foreach element [dict get $plan weld_elements] {
            if {![dict exists $element element_id]} { error "creation plan has no allocated element ID" }
            lappend expected [dict get $element element_id]
        }
    }
    if {![llength $expected]} { return 0 }
    set occupied [::HybridCore::existingEntityIds {elems elements} $expected]
    if {[llength $occupied]} { error "planned element IDs are already occupied: $occupied" }
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    set reader "#optistruct/optistruct"
    ::HWFlow::runHyperMeshIo import [list *feinputwithdata2 $reader [file nativename $delta] 0 0 0 0 0 1 2 1 0]
    set missing {}
    foreach elementId $expected {
        if {[llength [::HybridCore::existingEntityIds {elems elements} [list $elementId]]] == 0} { lappend missing $elementId }
    }
    if {[llength $missing]} { error "incremental weld verification failed; missing elements: $missing" }
    catch {::HWFlow::refreshBrowser}
    return [llength $expected]
}

proc ::FemAutoSeam::validateAutoPlanReferences {plan} {
    foreach move [dict get $plan move_nodes] {
        set nodeId [dict get $move node_id]
        if {[llength [::HybridCore::existingEntityIds {nodes} [list $nodeId]]] == 0} { error "planned GRID $nodeId no longer exists" }
        set actual [::HybridCore::nodeCoordinates $nodeId]
        if {![::HybridCore::coordinatesMatch $actual [dict get $move from] 1.0e-8]} { error "planned GRID $nodeId coordinates changed: actual={$actual} planned={[dict get $move from]}" }
    }
    foreach elementId [concat [dict get $plan read_elements] [dict get $plan delete_element_ids]] {
        if {[llength [::HybridCore::existingEntityIds {elems elements} [list $elementId]]] == 0} { error "planned shell element $elementId no longer exists" }
    }
    if {[dict exists $plan original_connectivity]} {
        dict for {elementId expected} [dict get $plan original_connectivity] {
            set actual [::FemAutoSeam::elemNodes $elementId]
            if {$actual ne $expected} { error "mother shell $elementId connectivity changed: actual={$actual} planned={$expected}" }
        }
    }
}

proc ::FemAutoSeam::deleteAutoPlanMotherElements {plan} {
    set ids [dict get $plan delete_element_ids]
    if {![llength $ids]} { return 0 }
    catch {*clearmark elems 1}; eval *createmark elems 1 $ids; *deletemark elems 1
    set remaining [::HybridCore::existingEntityIds {elems elements} $ids]
    if {[llength $remaining]} { error "mother shell deletion is incomplete: $remaining" }
    return [llength $ids]
}

proc ::FemAutoSeam::applyAutoPlanMoves {plan} {
    array set blockNodes {}
    array set blockVector {}
    foreach move [dict get $plan move_nodes] {
        set from [dict get $move from]; set to [dict get $move to]
        set dx [expr {double([lindex $to 0])-double([lindex $from 0])}]
        set dy [expr {double([lindex $to 1])-double([lindex $from 1])}]
        set dz [expr {double([lindex $to 2])-double([lindex $from 2])}]
        set key "[format %.10g $dx],[format %.10g $dy],[format %.10g $dz]"
        lappend blockNodes($key) [dict get $move node_id]
        set blockVector($key) [list $dx $dy $dz]
    }
    foreach key [lsort [array names blockNodes]] {
        set vector $blockVector($key); set dx [lindex $vector 0]; set dy [lindex $vector 1]; set dz [lindex $vector 2]
        set distance [expr {sqrt($dx*$dx+$dy*$dy+$dz*$dz)}]
        if {$distance <= 1.0e-12} { continue }
        catch {*clearmark nodes 1}; eval *createmark nodes 1 $blockNodes($key)
        *createvector 1 [expr {$dx/$distance}] [expr {$dy/$distance}] [expr {$dz/$distance}]
        *translatemark nodes 1 1 $distance
    }
    foreach move [dict get $plan move_nodes] {
        set actual [::HybridCore::nodeCoordinates [dict get $move node_id]]
        if {![::HybridCore::coordinatesMatch $actual [dict get $move to] 1.0e-7]} { error "GRID [dict get $move node_id] did not reach its planned coordinate" }
    }
    return [llength [dict get $plan move_nodes]]
}

proc ::FemAutoSeam::autoMissingEntityIds {entityTypes ids} {
    set missing {}
    foreach id [lsort -integer -unique $ids] {
        if {[llength [::HybridCore::existingEntityIds $entityTypes [list $id]]] == 0} {
            lappend missing $id
        }
    }
    return $missing
}

proc ::FemAutoSeam::writeAutoPlanRepairDelta {plan path missingNodes missingElements} {
    set missingNodeSet [dict create]
    foreach id $missingNodes { dict set missingNodeSet $id 1 }
    set missingElementSet [dict create]
    foreach id $missingElements { dict set missingElementSet $id 1 }
    set lines [list "\$ HMWF_AUTO_SHELL_SEAM_REPAIR_V1" "BEGIN BULK"]
    foreach node [dict get $plan new_nodes] {
        set nodeId [dict get $node node_id]
        if {![dict exists $missingNodeSet $nodeId]} { continue }
        set xyz [dict get $node coordinates]
        lappend lines [format "GRID,%s,,%.12g,%.12g,%.12g" $nodeId [lindex $xyz 0] [lindex $xyz 1] [lindex $xyz 2]]
    }
    set byComponent [dict create]
    foreach element [concat [dict get $plan replacement_elements] [dict get $plan weld_elements]] {
        set elementId [dict get $element element_id]
        if {![dict exists $missingElementSet $elementId]} { continue }
        dict lappend byComponent [dict get $element component_id] $element
    }
    dict for {componentId elements} $byComponent {
        if {$componentId == [dict get $plan output_component_id]} {
            set safeName [string map [list {"} {}] [dict get $plan output_component_name]]
            lappend lines "\$HMNAME COMP $componentId \"$safeName\""
        }
        lappend lines "\$HMCOMP ID $componentId"
        foreach element $elements {
            set propertyId [dict get $element property_id]
            set propertyField [expr {$propertyId > 0 ? $propertyId : ""}]
            lappend lines "[dict get $element element_type],[dict get $element element_id],$propertyField,[join [dict get $element node_ids] ,]"
        }
    }
    lappend lines "ENDDATA" ""
    ::HybridCore::writeTextFile $path [join $lines \n]
    return $path
}

proc ::FemAutoSeam::autoPlanImportFailureDetail {plan missingNodes missingElements delta repairDelta} {
    set missingNodeSet [dict create]
    foreach id $missingNodes { dict set missingNodeSet $id 1 }
    set missingElementSet [dict create]
    foreach id $missingElements { dict set missingElementSet $id 1 }
    set rows {}
    foreach role {replacement_elements weld_elements} {
        foreach element [dict get $plan $role] {
            set elementId [dict get $element element_id]
            if {![dict exists $missingElementSet $elementId]} { continue }
            set absentRefs {}
            foreach nodeId [dict get $element node_ids] {
                if {[llength [::HybridCore::existingEntityIds {nodes} [list $nodeId]]] == 0} { lappend absentRefs $nodeId }
            }
            lappend rows "id=$elementId role=$role card=[dict get $element element_type] component=[dict get $element component_id] nodes={[dict get $element node_ids]} missing_nodes={$absentRefs}"
        }
    }
    return "candidate=[dict get $plan candidate_id] fem={$delta} repair_fem={$repairDelta} missing_grids={$missingNodes} missing_elements={$missingElements} details={[join $rows {; }]}"
}

proc ::FemAutoSeam::applyAutoPlanDelta {plan} {
    if {![dict exists $plan delta_fem]} { error "candidate delta path is absent from creation plan" }
    set delta [dict get $plan delta_fem]
    if {![file isfile $delta]} { error "candidate delta FEM is missing: $delta" }
    set expectedNodes {}
    foreach node [dict get $plan new_nodes] { lappend expectedNodes [dict get $node node_id] }
    set expected {}
    foreach element [concat [dict get $plan replacement_elements] [dict get $plan weld_elements]] { lappend expected [dict get $element element_id] }
    set externalNodes {}
    set newNodeSet [dict create]
    foreach nodeId $expectedNodes { dict set newNodeSet $nodeId 1 }
    foreach element [concat [dict get $plan replacement_elements] [dict get $plan weld_elements]] {
        foreach nodeId [dict get $element node_ids] {
            if {![dict exists $newNodeSet $nodeId]} { lappend externalNodes $nodeId }
        }
    }
    set missingExternal [::FemAutoSeam::autoMissingEntityIds {nodes} $externalNodes]
    if {[llength $missingExternal]} {
        error "candidate delta references GRID IDs that are absent before import: candidate=[dict get $plan candidate_id] grids={$missingExternal} fem={$delta}"
    }
    set occupiedNodes [::HybridCore::existingEntityIds {nodes} $expectedNodes]
    if {[llength $occupiedNodes]} { error "candidate GRID IDs are already occupied: $occupiedNodes" }
    set occupied [::HybridCore::existingEntityIds {elems elements} $expected]
    if {[llength $occupied]} { error "candidate element IDs are already occupied: $occupied" }
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    ::HWFlow::runHyperMeshIo import [list *feinputwithdata2 "#optistruct/optistruct" [file nativename $delta] 0 0 0 0 0 1 2 1 0]
    set missingNodes [::FemAutoSeam::autoMissingEntityIds {nodes} $expectedNodes]
    set missing [::FemAutoSeam::autoMissingEntityIds {elems elements} $expected]
    set repairDelta ""
    if {[llength $missingNodes] || [llength $missing]} {
        # HM2019 can occasionally finish a large incremental read without
        # materializing every valid card. Retry only the absent cards so an
        # isolated reader hiccup does not roll back an otherwise valid batch.
        set repairDelta "[file rootname $delta].repair.fem"
        ::FemAutoSeam::writeAutoPlanRepairDelta $plan $repairDelta $missingNodes $missing
        *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
        ::HWFlow::runHyperMeshIo import [list *feinputwithdata2 "#optistruct/optistruct" [file nativename $repairDelta] 0 0 0 0 0 1 2 1 0]
        set missingNodes [::FemAutoSeam::autoMissingEntityIds {nodes} $expectedNodes]
        set missing [::FemAutoSeam::autoMissingEntityIds {elems elements} $expected]
    }
    if {[llength $missingNodes] || [llength $missing]} {
        error "candidate delta import remained incomplete after focused retry: [::FemAutoSeam::autoPlanImportFailureDetail $plan $missingNodes $missing $delta $repairDelta]"
    }
    # HM2019's OptiStruct incremental reader does not consistently preserve
    # $HMCOMP boundaries when one delta contains replacement shells for more
    # than one existing component plus a new SEAM component.  Re-organize the
    # imported IDs from the auditable plan instead of trusting import order.
    set byComponent [dict create]
    foreach element [concat [dict get $plan replacement_elements] [dict get $plan weld_elements]] {
        set componentId [dict get $element component_id]
        set ids {}
        if {[dict exists $byComponent $componentId]} { set ids [dict get $byComponent $componentId] }
        lappend ids [dict get $element element_id]
        dict set byComponent $componentId $ids
    }
    dict for {componentId ids} $byComponent {
        set componentName [::HybridCore::componentName $componentId]
        if {$componentName eq ""} { error "planned component $componentId is missing after delta import" }
        ::HybridCore::moveIdsToComponent {elems elements} $ids $componentName
    }
    foreach node [dict get $plan new_nodes] {
        set nodeId [dict get $node node_id]
        if {[llength [::HybridCore::existingEntityIds {nodes} [list $nodeId]]] == 0} { error "candidate delta import is missing GRID $nodeId" }
        if {![::HybridCore::coordinatesMatch [::HybridCore::nodeCoordinates $nodeId] [dict get $node coordinates] 1.0e-7]} { error "imported GRID $nodeId coordinates mismatch" }
    }
    return [llength $expected]
}

