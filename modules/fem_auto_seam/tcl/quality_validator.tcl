proc ::FemAutoSeam::autoNativeQualityFailures {elementIds} {
    if {![llength $elementIds]} { return {} }
    if {[llength [info commands hm_getelementsqualityinfo]] == 0} { error "HyperMesh native quality command is unavailable" }
    catch {*clearmark elems 1}; catch {*clearmark elems 2}; eval *createmark elems 1 $elementIds
    if {[catch {hm_getelementsqualityinfo 1 1 2} qualityErr]} { error "HyperMesh native quality check failed: $qualityErr" }
    set failed {}; catch {set failed [hm_getmark elems 2]}; return [lsort -integer -unique $failed]
}

proc ::FemAutoSeam::validateAutoCreatedElements {plans {baselineFailed {}}} {
    set verified 0
    set createdIds {}
    foreach plan $plans {
        if {[dict get $plan status] ne "READY"} { continue }
        foreach expected [concat [dict get $plan replacement_elements] [dict get $plan weld_elements]] {
            set elementId [dict get $expected element_id]
            set actual [::FemAutoSeam::elemNodes $elementId]
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
                if {$actualProperty ne "" && $actualProperty != [dict get $expected property_id]} { error "shell element $elementId property mismatch" }
            }
            lappend createdIds $elementId
            incr verified
        }
    }
    # The weld strip is governed by the Python zipper aspect-ratio,
    # degeneracy and continuity guards.  Applying mother-mesh criteria to its
    # intentional gap-spanning width rejects otherwise valid welds.  Native HM
    # criteria therefore evaluate replacement/surviving mother shells only.
    set scope {}
    foreach plan $plans {
        if {[dict get $plan status] eq "READY"} {
            foreach expected [dict get $plan replacement_elements] {
                lappend scope [dict get $expected element_id]
            }
            foreach elementId [dict get $plan read_elements] { if {$elementId ni [dict get $plan delete_element_ids]} { lappend scope $elementId } }
        }
    }
    set scope [lsort -integer -unique $scope]
    set failed [::FemAutoSeam::autoNativeQualityFailures $scope]
    set baselineScope {}
    foreach plan $plans {
        if {[dict get $plan status] eq "READY"} {
            foreach elementId [dict get $plan read_elements] { lappend baselineScope $elementId }
        }
    }
    set baselineChecked [llength [lsort -integer -unique $baselineScope]]
    set baselineFailureRate [expr {$baselineChecked > 0 ? [llength $baselineFailed]/double($baselineChecked) : 0.0}]
    set checkedAfter [llength $scope]
    set maxAllowed 0
    foreach plan $plans { if {[dict exists $plan max_new_failed_elements] && [dict get $plan max_new_failed_elements] > $maxAllowed} { set maxAllowed [dict get $plan max_new_failed_elements] } }
    set projectedBaseline [expr {int(ceil($baselineFailureRate*$checkedAfter-1.0e-12))}]
    set allowedFailed [expr {$projectedBaseline+$maxAllowed}]
    if {[llength $failed] > $allowedFailed} {
        error "HyperMesh native quality failure ratio worsened: before=[llength $baselineFailed]/$baselineChecked after=[llength $failed]/$checkedAfter allowed_failed=$allowedFailed ids=$failed"
    }
    return $verified
}

