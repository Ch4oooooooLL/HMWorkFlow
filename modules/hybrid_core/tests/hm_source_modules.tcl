set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
foreach module {
    auto_hole_rbe2.tcl
    shell_washer_hole_rbe2.tcl
    rbe2_bolt_connector.tcl
    mesh_seam_weld.tcl
} {
    set path [file join $root modules $module]
    if {[catch {source $path} err opts]} {
        error "SOURCE_FAILED $module: $err\n[dict get $opts -errorinfo]"
    }
}
set out [open [file join $root runtime hm_source_modules.ok] w]
puts $out "HyperMesh 2019 source validation passed"
close $out
