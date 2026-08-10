namespace eval ::hmtoolkit::seam {
    variable VERSION "2.0"
    variable MODULE_DIR [file dirname [file normalize [info script]]]
    variable config
    array set config {
        endpoint_merge_tolerance  0.1
        projected_path_merge_tolerance 0.5
        projected_path_ambiguity_tolerance 1.0e-6
        stitch_tolerance          0.2
        cleanup_tolerance         0.2
        min_seam_length           5.0
        point_spacing             7.0
        area_tolerance            1.0e-6
        volume_tolerance          1.0e-6
        geometry_offset_distance  50.0
        extend_offset_distance    12.0
        extend_offset_type        2
        extend_connect_trim_mode  1
        extend_connect_distance   0.0
        t_surface_trim_mode       1
        connect_extend_distance   50.0
        connect_min_angle_to_target 15.0
        connect_max_angle_edge_to_surf 30.0
        connect_guide_angle       30.0
        lap_connect_distance      5.0
        lap_result_envelope_tolerance 0.5
        lap_boolean_opcode        8
        replace_point_projection_distance -1.0
        diagnostic_preserve_failed_geometry 0
        topology_connection_required 1
        private_history_api       1
        internal_mark_slot        0
        thickness_override        0.0
    }
    variable config_notes
    array set config_notes {
        area_tolerance "minimum accepted seam-surface area"
        cleanup_tolerance "temporary cleanup tolerance used by topology merge"
        connect_extend_distance "T Surface extension distance"
        connect_guide_angle "guide-edge angle for surface extension"
        connect_max_angle_edge_to_surf "maximum edge-to-surface angle for extension"
        connect_min_angle_to_target "minimum source-to-target surface angle"
        diagnostic_preserve_failed_geometry "1 keeps failed transaction geometry for diagnosis"
        endpoint_merge_tolerance "endpoint equality tolerance for selected line paths"
        extend_connect_distance "distance field for EXTEND mode 3; baseline is 0"
        extend_connect_trim_mode "trim EXTEND result; documented values 0 or 1"
        extend_offset_distance "temporary target offset used by EXTEND"
        extend_offset_type "documented offset mode; baseline 2 removes degenerations"
        geometry_offset_distance "temporary solid offset used by Lap Surface"
        internal_mark_slot "0 auto-detects; local dual-version fallback is mark 3"
        lap_boolean_opcode "8 union baseline; 14 intersection is an advanced alternative"
        lap_connect_distance "Lap Surface connection distance"
        lap_result_envelope_tolerance "allowed bbox expansion when filtering Lap Surface results"
        min_seam_length "minimum accepted selected edge-path length"
        point_spacing "target spacing for distributed geometry points"
        private_history_api "1 enables optional hm_private_frwk history integration"
        projected_path_ambiguity_tolerance "score difference treated as ambiguous in T List matching"
        projected_path_merge_tolerance "near-endpoint tolerance for T List projected paths"
        replace_point_projection_distance "-1 selects nearest edge; positive value limits distance"
        stitch_tolerance "surface topology equivalence/stitch tolerance"
        t_surface_trim_mode "trim T Surface extension; documented values 0 or 1"
        thickness_override "positive value overrides detected thickness; 0 uses automatic flow"
        topology_connection_required "1 rolls back geometrically detached seam surfaces"
        volume_tolerance "minimum temporary solid volume in Lap Surface"
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
    variable ::hmtoolkit::seam::config_notes
    set rows [list \
        "# Geometry seam defaults (HyperMesh 2019 / 2022.2 baseline)." \
        "# distance/angle/tolerance units follow the model unit system." \
        "# lap_boolean_opcode: 8=Union, 14=Intersection. Union is the reviewed" \
        "# default matching the legacy L_SURF behavior; 14 is untested on the" \
        "# project baseline." \
        "# t_surface_trim_mode: legal values 0/1; 1 trims the extended T Surface." \
        "# extend_offset_type follows *offset_surfaces_and_modify; the dual-version baseline is 2." \
        "# extend_connect_trim_mode is 0/1; extend_connect_distance is used by extend mode 3." \
        "# replace_point_projection_distance: -1 uses the verified nearest-edge behavior." \
        "# projected_path_merge_tolerance joins near endpoints while identifying T List trim paths." \
        "# connect_extend_distance is the T Surface extend/search distance." \
        "# topology_connection_required=0 downgrades equivalence failures to" \
        "# warnings and keeps the created geometry (diagnostic mode)." \
        "# private_history_api=0 disables the private hm_private_frwk call." \
        "key|value|note"]
    foreach key [lsort [array names config]] {
        set note [expr {[info exists config_notes($key)] ? $config_notes($key) : "geometry seam setting"}]
        lappend rows "$key|$config($key)|$note"
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
