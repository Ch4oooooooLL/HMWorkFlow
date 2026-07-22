namespace eval ::hmtoolkit::seam {
    variable VERSION "2.0"
    variable MODULE_DIR [file dirname [file normalize [info script]]]
    variable config
    array set config {
        angle_parallel_max        15.0
        angle_perpendicular_min   75.0
        distance_tolerance        1.0
        endpoint_merge_tolerance  0.1
        min_seam_length           5.0
        point_spacing             7.0
        area_tolerance            1.0e-6
        volume_tolerance          1.0e-6
        geometry_offset_distance  50.0
        extend_offset_distance    12.0
        auto_accept_confidence    0.85
        review_confidence         0.60
        auto_create_enabled       0
        thickness_override        0.0
        shortcut_selector_mode    PANEL
        shortcut_scope            COMPONENT_PAIR
    }
    variable runtime
    array set runtime {
        candidates {}
        log_file ""
        temp_counter 0
        selection_scope COMPONENT_PAIR
        forced_joint AUTO
        forced_strategy AUTO
        status ""
        context_data {}
        context_text "No incoming geometry"
        shortcut_panel_scope COMPONENT_PAIR
        prompt_value ""
        prompt_ok 0
    }
}

namespace eval ::hmtoolkit::seam::config {}

proc ::hmtoolkit::seam::config::path {} {
    return [::file join [::HWFlow::configDir] "seam_rules.txt"]
}

proc ::hmtoolkit::seam::config::default_text {} {
    variable ::hmtoolkit::seam::config
    set rows [list "# Geometry seam defaults (HyperMesh 2019)." "key|value|note"]
    foreach key [lsort [array names config]] {
        lappend rows "$key|$config($key)|geometry seam setting"
    }
    return [join $rows "\n"]
}

proc ::hmtoolkit::seam::config::load {} {
    variable ::hmtoolkit::seam::config
    set path [::hmtoolkit::seam::config::path]
    if {![::file exists $path]} {
        ::HWFlow::writeTextFile $path [::hmtoolkit::seam::config::default_text]
    }
    foreach raw [split [::HWFlow::readTextFile $path] "\n"] {
        set line [string trim $raw]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        set fields [split $line "|"]
        set key [string trim [lindex $fields 0]]
        if {$key eq "key" || ![info exists config($key)]} { continue }
        set config($key) [string trim [lindex $fields 1]]
    }
    return [array get config]
}

proc ::hmtoolkit::seam::config::get {key} {
    variable ::hmtoolkit::seam::config
    if {![info exists config($key)]} { error "Unknown geometry seam setting: $key" }
    return $config($key)
}

proc ::hmtoolkit::seam::config::set_value {key value} {
    variable ::hmtoolkit::seam::config
    if {![info exists config($key)]} { error "Unknown geometry seam setting: $key" }
    set config($key) $value
}

proc ::hmtoolkit::seam::config::save {} {
    ::HWFlow::writeTextFile [::hmtoolkit::seam::config::path] [::hmtoolkit::seam::config::default_text]
}
