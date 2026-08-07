namespace eval ::hmtoolkit::seam::temp {
    variable scopes
    array set scopes {}
}

proc ::hmtoolkit::seam::temp::new_scope {} {
    variable scopes
    variable ::hmtoolkit::seam::runtime
    incr runtime(temp_counter)
    set token "[clock clicks]_$runtime(temp_counter)"
    set scopes($token) [dict create components {} surfs {} solids {} lines {} points {}]
    return $token
}

proc ::hmtoolkit::seam::temp::unique_name {} {
    variable ::hmtoolkit::seam::runtime
    incr runtime(temp_counter)
    return "__HMWF_SEAM_TMP_[clock seconds]_$runtime(temp_counter)"
}

proc ::hmtoolkit::seam::temp::register_entity {token entityType ids} {
    variable scopes
    if {![info exists scopes($token)]} { error "Unknown seam temporary scope: $token" }
    set entityType [::hmtoolkit::seam::entity::normalize_type $entityType]
    if {$entityType eq "comps"} { set entityType components }
    dict set scopes($token) $entityType [concat [dict get $scopes($token) $entityType] $ids]
}

proc ::hmtoolkit::seam::temp::create_component {token} {
    set name [::hmtoolkit::seam::temp::unique_name]
    if {[::HWFlow::componentIdByName $name] ne ""} { error "Temporary component collision: $name" }
    # -history external: the seam transaction owns the undo/redo block; nested
    # history states from component creation are not a supported contract.
    set id [::HWFlow::createComponent $name "" external]
    if {$id eq ""} { error "Unable to create temporary component $name" }
    ::hmtoolkit::seam::temp::register_entity $token components [list $id]
    ::hmtoolkit::seam::native::set_current_component_checked $name $id
    return [list $name $id]
}

proc ::hmtoolkit::seam::temp::delete_ids {entityType ids} {
    if {[llength $ids] == 0} { return }
    set entityType [::hmtoolkit::seam::entity::normalize_type $entityType]
    set existing {}
    foreach id [lsort -integer -unique $ids] {
        if {[::hmtoolkit::seam::entity::exists $entityType $id]} { lappend existing $id }
    }
    if {[llength $existing] == 0} { return }
    ::hmtoolkit::seam::entity::mark $entityType 1 $existing
    switch -- $entityType {
        solids { *deletesolidswithelems 1 1 1 }
        default { *deletemark $entityType 1 }
    }
}

proc ::hmtoolkit::seam::temp::cleanup {token} {
    variable scopes
    if {![info exists scopes($token)]} { return }
    set record $scopes($token)
    foreach type {points lines surfs solids} {
        catch {::hmtoolkit::seam::temp::delete_ids $type [dict get $record $type]}
    }
    foreach compId [dict get $record components] {
        if {[::hmtoolkit::seam::entity::exists comps $compId]} {
            catch {::hmtoolkit::seam::temp::delete_ids comps [list $compId]}
        }
    }
    unset scopes($token)
    ::hmtoolkit::seam::log::write INFO "Temporary scope cleaned: $token"
}

