# Headless capability probe.  Active-selector behavior itself must be tested
# in an interactive panel; this script verifies the installed 2019 runtime
# supplies the native commands used by the adapter and its documented fallback.
set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
set outputDir [file join $root runtime tasks quick_selector]
file mkdir $outputDir
set reportPath [file join $outputDir hm2019_api_probe.txt]

set required {*appendmark *createlistbypathpanel hm_entitycanselectby hm_getcurrentmenu hm_getpanelitems}
set missing {}
foreach command $required {
    if {[llength [info commands $command]] == 0} { lappend missing $command }
}
source -encoding utf-8 [file join $root modules shortcut_manager.tcl]
::HWShortcut::ensureActionProviders
set expectedActions {hm.selection.by_attached hm.selection.by_face hm.selection.by_path_mode}
set registeredActions [::HWShortcut::actionKeys]
if {$registeredActions ne $expectedActions} {
    lappend missing "action_registry:$registeredActions"
}
set ch [open $reportPath w]
fconfigure $ch -encoding utf-8 -translation lf
puts $ch "version=[hm_info -appinfo VERSION]"
puts $ch "required=$required"
puts $ch "missing=$missing"
puts $ch "registered_actions=$registeredActions"
puts $ch "status=[expr {[llength $missing] == 0 ? {PASS} : {FAIL}}]"
close $ch
if {[llength $missing] > 0} { error "Missing HyperMesh 2019 Quick Selector APIs: $missing" }
exit 0
