# Mesh-post weld integrity review module for HyperMesh 2019.
if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] workflow_common.tcl]
}
if {![namespace exists ::HybridCore]} {
    source [file join [file dirname [file normalize [info script]]] hybrid_core tcl init.tcl]
}

namespace eval ::WeldIntegrityCheck {
    variable VERSION "1.0"
    variable ROOT_DIR [file dirname [file dirname [file normalize [info script]]]]
    variable MODULE_DIR [file join [file dirname [file normalize [info script]]] weld_integrity_check]
    variable taskDir ""
    variable taskId ""
    variable resultData {}
    variable pairRows {}
    variable filteredRows {}
    variable currentPairId ""
    variable currentRegionIndex 0
    variable originalVisibleCompIds {}
    variable displayCaptured 0
    variable isolated 0
    variable logChannel ""
    variable logPath ""
    variable pairStates
    array set pairStates {}
    variable cfg
    array set cfg {
        max_search_distance 5.0
        min_contact_length 20.0
        min_continuous_nodes 3
        prefer_free_edges 1
        ignore_shared_nodes 1
        auto_isolate_next 1
    }
    variable ui
    array set ui {
        accepted 0 selectedCompIds {} excludedCompIds {}
        selectedText "No components selected" excludedText "No excluded components"
        shell_shell 1 shell_solid 0 solid_solid 0
        filterText "" statusFilter pending summaryText "" detailText ""
    }
}

foreach fileName {core.tcl exporter.tcl review.tcl ui.tcl} {
    source [file join $::WeldIntegrityCheck::MODULE_DIR tcl $fileName]
}
