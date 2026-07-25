# Solid seam connector module loader. Sourcing this file must not open a UI.
namespace eval ::SolidSeam {
    variable MODULE_DIR [file join [file dirname [file normalize [info script]]] solid_seam]
}
if {![namespace exists ::HybridCore]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] hybrid_core tcl init.tcl]
}
foreach _solidSeamFile {
    logger.tcl component_selector.tcl mesh_exporter.tcl
    python_bridge.tcl realization_profiles.tcl realization_validator.tcl
    candidate_editor.tcl candidate_viewer.tcl seam_creator.tcl ui.tcl main.tcl
} {
    source -encoding utf-8 [file join $::SolidSeam::MODULE_DIR tcl $_solidSeamFile]
}
unset _solidSeamFile
