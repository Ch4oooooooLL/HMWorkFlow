# ============================================================================
# Geometry Seam module loader - HyperMesh 2019 Tcl/Tk
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

set ::hmtoolkit_seam_dir [file join [file dirname [file normalize [info script]]] "seam_surface"]
foreach ::hmtoolkit_seam_file {
    config.tcl
    log.tcl
    entity.tcl
    temp.tcl
    state.tcl
    validation.tcl
    candidate.tcl
    classifier.tcl
    executor.tcl
    selector.tcl
    legacy.tcl
    ui.tcl
    main.tcl
} {
    ::HWFlow::sourceUtf8 [file join $::hmtoolkit_seam_dir $::hmtoolkit_seam_file]
}
unset ::hmtoolkit_seam_file
unset ::hmtoolkit_seam_dir
