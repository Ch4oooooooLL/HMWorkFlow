# Imports a fixture only into a new hmbatch process.
set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
file mkdir [file join $root temp solid_seam_refactor]
set channel [open [file join $root temp solid_seam_refactor auto_group_native.log] w]
fconfigure $channel -encoding utf-8 -buffering line
set rc [catch {
    source -encoding utf-8 [file join $root modules workflow_common.tcl]
    source -encoding utf-8 [file join $root modules solid_seam_connector.tcl]
    proc ::SolidSeam::message {icon text} { puts $::channel "$icon $text" }
    set executableDir [hm_info -appinfo EXECUTABLEDIR]
    *templatefileset [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
    set femPath [file join $root examples AutoShellSeamBackend test_fem combined_all_cases.fem]
    *feinputpreserveincludefiles
    *createstringarray 10 "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "
    *feinputwithdata2 "#optistruct\\optistruct" $femPath 0 0 0 0 0 1 10 1 0
    set comps {}
    foreach name {
        F01_CASE_01_STRAIGHT_T__WEB_T1 F01_CASE_01_STRAIGHT_T__BASE_T2
        F07_CASE_07_PATCH__SMALL_PATCH_T1 F07_CASE_07_PATCH__LARGE_PATCH_TARGET_T2
        F09_CASE_09_NEAR_FREE_EDGES_REVIEW__EDGE_PLATE_A_T1 F09_CASE_09_NEAR_FREE_EDGES_REVIEW__EDGE_PLATE_B_T1
    } { lappend comps [hm_getvalue comps name=$name dataname=id] }
    set ::SolidSeam::ui(input_type) AUTO_GROUP
    set before [lsort -integer [hm_entitylist elems id all]]
    set plans [::SolidSeam::prepareAutoGroup $comps]
    puts $channel $::SolidSeam::autoGroupSummary
    if {[llength $plans] != 3} { error "Expected exactly three pairs, got [llength $plans]" }
    if {$before ne [lsort -integer [hm_entitylist elems id all]]} { error "Preparation changed model" }
    foreach plan $plans {
        set row [lindex [dict get $plan candidates] 0]
        puts $channel "PAIR [dict get $row source_component_id] -> [dict get $row target_component_id] [dict get $row joint_type]"
        if {![::SolidSeam::executeSelectionPlan $plan]} { error "Realization failed" }
    }
    puts $channel PASS
} err opts]
if {$rc} { puts $channel "FAIL $err\n[dict get $opts -errorinfo]" }
close $channel
catch {hm_exit}
