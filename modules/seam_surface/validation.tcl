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
    set afterComponent [::hmtoolkit::seam::entity::component_surfaces $componentId]
    set created [::hmtoolkit::seam::entity::diff_ids $beforeComponent $afterComponent]
    if {[llength $created] == 0 && [llength $beforeAll] > 0} {
        set globalCreated [::hmtoolkit::seam::entity::diff_ids $beforeAll [::hmtoolkit::seam::entity::snapshot_ids surfs]]
        foreach surfId $globalCreated {
            if {[string equal [::hmtoolkit::seam::entity::surface_component $surfId] $componentId]} { lappend created $surfId }
        }
    }
    set created [lsort -integer -unique $created]
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
