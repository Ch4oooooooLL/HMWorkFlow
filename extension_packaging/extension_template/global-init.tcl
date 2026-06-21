# HMWorkflow Extension Tcl wrapper template.
# The pack script regenerates the distributable global-init.tcl from
# extension_packaging/extension_tools.json.

namespace eval ::HMWorkflowExt {
    variable EXT_ROOT [file normalize [file dirname [info script]]]
    variable TOOL_ROOT [file normalize [file join $EXT_ROOT payload]]
}

proc ::HMWorkflowExt::run {toolKey} {
    tk_messageBox -icon info -title "HM WorkFlow" -message "This is a template. Run extension_packaging/pack_hmworkflow_extension.py to generate a distributable extension."
}

proc ::HMWorkflowExt::about {} {
    tk_messageBox -icon info -title "HM WorkFlow" -message "HM WorkFlow Extension template"
}
