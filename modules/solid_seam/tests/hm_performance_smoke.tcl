# Imports a fixture only into a new hmbatch process.
set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
file mkdir [file join $root temp solid_seam_refactor]
set channel [open [file join $root temp solid_seam_refactor performance_native.log] w]
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
    set timings {}; set ::queryCount 0; set ::edgeCount 0
    proc countQuery {args} { incr ::queryCount }
    proc countEdges {args} { incr ::edgeCount }
    trace add execution hm_getvalue enter countQuery
    trace add execution *findedges enter countEdges
    for {set repeat 0} {$repeat < 7} {incr repeat} {
        set start [clock microseconds]
        set plans [::SolidSeam::prepareAutoGroup $comps]
        lappend timings [expr {[clock microseconds]-$start}]
    }
    trace remove execution hm_getvalue enter countQuery
    trace remove execution *findedges enter countEdges
    puts $channel "PREPARE median_us=[::SolidSeam::median $timings] query_count=$::queryCount findedges_count=$::edgeCount repeats=7"
    set baseline [file join $root temp solid_seam_refactor performance_plans.txt]
    if {[file exists $baseline]} {
        set input [open $baseline r]; set previous [read $input]; close $input
        if {$previous ne $plans} { error "Candidate plans changed from baseline" }
        puts $channel "CANDIDATES_EXACT_MATCH=1"
    } else {
        set output [open $baseline w]; puts -nonewline $output $plans; close $output
    }
    set creationStart [clock microseconds]
    puts $channel $::SolidSeam::autoGroupSummary
    if {[llength $plans] != 3} { error "Expected exactly three pairs, got [llength $plans]" }
    if {$before ne [lsort -integer [hm_entitylist elems id all]]} { error "Preparation changed model" }
    foreach plan $plans {
        set row [lindex [dict get $plan candidates] 0]
        puts $channel "PAIR [dict get $row source_component_id] -> [dict get $row target_component_id] [dict get $row joint_type]"
        if {![::SolidSeam::executeSelectionPlan $plan]} { error "Realization failed" }
    }
    puts $channel "CREATE us=[expr {[clock microseconds]-$creationStart}]"
    puts $channel PASS
} err opts]
if {$rc} { puts $channel "FAIL $err\n[dict get $opts -errorinfo]" }
close $channel
catch {hm_exit}
