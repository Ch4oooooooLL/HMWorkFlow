namespace eval ::hmtoolkit::seam {
    variable VERSION "2.0"
    variable MODULE_DIR [file dirname [file normalize [info script]]]
    variable config
    array set config {
        distance_tolerance        1.0
        endpoint_merge_tolerance  0.1
        stitch_tolerance          0.2
        cleanup_tolerance         0.2
        min_seam_length           5.0
        point_spacing             7.0
        area_tolerance            1.0e-6
        volume_tolerance          1.0e-6
        geometry_offset_distance  50.0
        extend_offset_distance    12.0
        t_surface_trim_mode       1
        connect_min_angle_to_target 15.0
        connect_max_angle_edge_to_surf 30.0
        connect_guide_angle       30.0
        lap_connect_distance      5.0
        lap_boolean_opcode        8
        diagnostic_preserve_failed_geometry 0
        topology_connection_required 1
        private_history_api       1
        thickness_override        0.0
    }
    variable runtime
    array set runtime {
        candidates {}
        log_file ""
        temp_counter 0
        status ""
        prompt_value ""
        prompt_ok 0
        active_strategy ""
    }
}

namespace eval ::hmtoolkit::seam::config {}

proc ::hmtoolkit::seam::config::path {} {
    return [::file join [::HWFlow::configDir] "seam_rules.txt"]
}

proc ::hmtoolkit::seam::config::default_text {} {
    variable ::hmtoolkit::seam::config
    set rows [list \
        "# Geometry seam defaults (HyperMesh 2019 / 2022.2 baseline)." \
        "# distance/angle/tolerance units follow the model unit system." \
        "# lap_boolean_opcode: 8=Union, 14=Intersection. Union is the reviewed" \
        "# default matching the legacy L_SURF behavior; 14 is untested on the" \
        "# project baseline." \
        "# t_surface_trim_mode: legal values 0/1; 1 matches the legacy T Path /" \
        "# T List flow on the project baseline." \
        "# topology_connection_required=0 downgrades equivalence failures to" \
        "# warnings and keeps the created geometry (diagnostic mode)." \
        "# private_history_api=0 disables the private hm_private_frwk call." \
        "key|value|note"]
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
