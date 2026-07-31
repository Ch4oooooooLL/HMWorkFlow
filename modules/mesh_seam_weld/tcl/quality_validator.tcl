proc ::MeshSeamWeld::autoNativeQualityFailures {elementIds} {
    if {![llength $elementIds]} { return {} }
    if {[llength [info commands hm_getelementsqualityinfo]] == 0} { error "HyperMesh native quality command is unavailable" }
    catch {*clearmark elems 1}; catch {*clearmark elems 2}; eval *createmark elems 1 $elementIds
    if {[catch {hm_getelementsqualityinfo 1 1 2} qualityErr]} { error "HyperMesh native quality check failed: $qualityErr" }
    set failed {}; catch {set failed [hm_getmark elems 2]}; return [lsort -integer -unique $failed]
}

proc ::MeshSeamWeld::validateAutoCreatedElements {plans {baselineFailed {}}} {
    set verified 0
    set createdIds {}
    foreach plan $plans {
        if {[dict get $plan status] ne "READY"} { continue }
        foreach expected [concat [dict get $plan replacement_elements] [dict get $plan weld_elements]] {
            set elementId [dict get $expected element_id]
            set actual [::MeshSeamWeld::elemNodes $elementId]
            if {[lsort -integer $actual] ne [lsort -integer [dict get $expected node_ids]]} { error "weld element $elementId connectivity mismatch" }
            if {[llength $actual] ni {3 4}} { error "weld element $elementId is not a supported first-order shell" }
            set expectedComponent ""
            if {[dict exists $expected component_id]} { set expectedComponent [dict get $expected component_id] } elseif {[dict exists $plan output_component_id]} { set expectedComponent [dict get $plan output_component_id] }
            if {$expectedComponent ne ""} {
                set actualComponent ""; catch {set actualComponent [hm_getvalue elems id=$elementId dataname=collector.id]}
                if {$actualComponent ne "" && $actualComponent != $expectedComponent} { error "shell element $elementId component mismatch" }
            }
            if {[dict exists $expected property_id] && [dict get $expected property_id] > 0} {
                set actualProperty ""; catch {set actualProperty [hm_getvalue elems id=$elementId dataname=property.id]}
                if {$actualProperty ne "" && $actualProperty != [dict get $expected property_id]} { error "replacement shell $elementId property mismatch" }
            }
            lappend createdIds $elementId
            incr verified
        }
    }
    set scope $createdIds
    foreach plan $plans {
        if {[dict get $plan status] eq "READY"} {
            foreach elementId [dict get $plan read_elements] { if {$elementId ni [dict get $plan delete_element_ids]} { lappend scope $elementId } }
        }
    }
    set failed [::MeshSeamWeld::autoNativeQualityFailures [lsort -integer -unique $scope]]
    set newFailed {}
    foreach elementId $failed { if {$elementId ni $baselineFailed} { lappend newFailed $elementId } }
    set maxAllowed 0
    foreach plan $plans { if {[dict exists $plan max_new_failed_elements] && [dict get $plan max_new_failed_elements] > $maxAllowed} { set maxAllowed [dict get $plan max_new_failed_elements] } }
    if {[llength $newFailed] > $maxAllowed} { error "HyperMesh native quality check found [llength $newFailed] new failed elements (allowed $maxAllowed): $newFailed" }
    return $verified
}
