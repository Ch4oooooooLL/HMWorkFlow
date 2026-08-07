namespace eval ::hmtoolkit::seam::validation {}

proc ::hmtoolkit::seam::validation::failure {code message} {
    return [dict create success 0 error_code $code message $message warnings {}]
}

proc ::hmtoolkit::seam::validation::require_ids {data key entityType {count ""}} {
    if {![dict exists $data $key]} { error "Missing input field: $key" }
    set ids [dict get $data $key]
    if {[llength $ids] == 0} { error "$key must not be empty" }
    if {$count ne "" && [llength $ids] != $count} { error "$key requires exactly $count entities" }
    foreach id $ids {
        if {![::hmtoolkit::seam::entity::exists $entityType $id]} { error "$entityType entity $id does not exist" }
    }
    return $ids
}

proc ::hmtoolkit::seam::validation::surface_area {surfId} {
    foreach command [list [list hm_getareaofsurface surfs $surfId] [list hm_getvalue surfs id=$surfId dataname=area]] {
        if {![catch {set value [eval $command]}] && [string is double -strict $value]} { return [expr {double($value)}] }
    }
    return ""
}

proc ::hmtoolkit::seam::validation::created_surfaces {before expectedComponent} {
    set after [::hmtoolkit::seam::entity::snapshot_ids surfs]
    set created [::hmtoolkit::seam::entity::diff_ids $before $after]
    ::hmtoolkit::seam::validation::surface_ids $created $expectedComponent
    return $created
}

proc ::hmtoolkit::seam::validation::created_surfaces_in_component {before componentId} {
    set after [::hmtoolkit::seam::entity::component_surfaces $componentId]
    set created [::hmtoolkit::seam::entity::diff_ids $before $after]
    ::hmtoolkit::seam::validation::surface_ids $created $componentId
    return $created
}

proc ::hmtoolkit::seam::validation::created_surfaces_for_component {beforeComponent beforeAll componentId} {
    # Global diff first: if the kernel created surfaces, they must be reported
    # even when the current component was wrong and they landed elsewhere.
    # This separates the three failure classes:
    #   A. no new surface at all (distance/angles/topology)
    #   B. new surfaces in the wrong component (current collector problem)
    #   C. created correctly, later validation steps may still fail
    set globalCreated [::hmtoolkit::seam::entity::diff_ids \
        $beforeAll [::hmtoolkit::seam::entity::snapshot_ids surfs]]
    if {[llength $globalCreated] > 0} {
        set correctOwner {}
        set wrongOwner {}
        foreach surfId $globalCreated {
            set owner [::hmtoolkit::seam::entity::surface_component $surfId]
            if {$owner ne "" && $owner == $componentId} {
                lappend correctOwner $surfId
            } else {
                lappend wrongOwner [list $surfId $owner]
            }
        }
        set correctOwner [lsort -integer -unique $correctOwner]
        if {[llength $correctOwner] == 0} {
            error "New surfaces were created, but none is in the expected seam component $componentId. New surface/owner pairs: $wrongOwner"
        }
        ::hmtoolkit::seam::validation::surface_ids $correctOwner $componentId
        set ownerReport {}
        foreach surfId $correctOwner {
            lappend ownerReport [list $surfId \
                [::hmtoolkit::seam::entity::surface_component $surfId] \
                [::hmtoolkit::seam::validation::surface_area $surfId]]
        }
        ::hmtoolkit::seam::log::write INFO \
            "Created surfaces (id owner area): $ownerReport"
        return $correctOwner
    }
    # No global new surfaces: kernels that modify in place (some advanced
    # option combinations) can still add surfaces inside the component scope.
    set afterComponent [::hmtoolkit::seam::entity::component_surfaces $componentId]
    set created [::hmtoolkit::seam::entity::diff_ids $beforeComponent $afterComponent]
    set created [lsort -integer -unique $created]
    if {[llength $created] == 0} {
        error "Native surface command completed but created no new surface. Check extension distance, angles and topology."
    }
    ::hmtoolkit::seam::validation::surface_ids $created $componentId
    return $created
}

proc ::hmtoolkit::seam::validation::surface_ids {created expectedComponent} {
    if {[llength $created] == 0} { error "No seam surface was created" }
    set tolerance [::hmtoolkit::seam::config::get area_tolerance]
    foreach surfId $created {
        set area [::hmtoolkit::seam::validation::surface_area $surfId]
        if {$area ne "" && $area <= $tolerance} { error "Created surface $surfId has zero or near-zero area" }
        if {$expectedComponent ne ""} {
            set actual [::hmtoolkit::seam::entity::surface_component $surfId]
            if {$actual ne "" && $actual != $expectedComponent} { error "Created surface $surfId is outside the seam component" }
        }
    }
    return 1
}

proc ::hmtoolkit::seam::validation::original_surfaces_exist {surfIds} {
    foreach surfId $surfIds {
        if {![::hmtoolkit::seam::entity::exists surfs $surfId]} { error "Original surface $surfId no longer exists" }
    }
    return 1
}
