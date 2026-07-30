# ============================================================================
# BatchMesher automatic surface meshing - HyperMesh 2019 Tcl/Tk
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}
if {![namespace exists ::HybridCore]} {
    ::HWFlow::sourceUtf8 [file join [file dirname [file normalize [info script]]] hybrid_core tcl init.tcl]
}

namespace eval ::BatchMesher {}
set ::BatchMesher::MODULE_DIR [file join [file dirname [file normalize [info script]]] "batch_mesher"]
foreach batchMesherFile {
    config.tcl
    selection.tcl
    connectivity.tcl
    logging.tcl
    executor.tcl
    ui.tcl
    main.tcl
} {
    source -encoding utf-8 [file join $::BatchMesher::MODULE_DIR $batchMesherFile]
}
unset batchMesherFile
