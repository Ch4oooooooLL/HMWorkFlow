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
    set timings {}; set ::queryCount 0; set ::queryFields {}; set ::edgeCount 0
    proc countQuery {command operation} {
        incr ::queryCount
        set field unknown
        foreach token $command {
            if {[string match "dataname=*" $token]} { set field [string range $token 9 end]; break }
        }
        dict incr ::queryFields $field
    }
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
    puts $channel "PREPARE median_us=[::SolidSeam::median $timings] query_count=$::queryCount findedges_count=$::edgeCount repeats=7 query_fields=$::queryFields"
    set originalSummary $::SolidSeam::autoGroupSummary
    set sharedComps {}
    foreach name {F05_CASE_05_MULTI_TARGET_SAME_EDGE__SHARED_SOURCE_WEB_T1 F05_CASE_05_MULTI_TARGET_SAME_EDGE__UPPER_TARGET_T2 F05_CASE_05_MULTI_TARGET_SAME_EDGE__LOWER_TARGET_T2} {
        lappend sharedComps [hm_getvalue comps name=$name dataname=id]
    }
    set ::sharedEdges 0
    proc countSharedEdges {args} { incr ::sharedEdges }
    trace add execution *findedges enter countSharedEdges
    set sharedPlans [::SolidSeam::prepareAutoGroup $sharedComps]
    trace remove execution *findedges enter countSharedEdges
    # Preserve the legacy output exactly, including the third target-target
    # candidate; accuracy changes are evaluated separately in shadow mode.
    if {[llength $sharedPlans] != 3} { error "Shared-source fixture legacy pair count changed: [llength $sharedPlans]" }
    puts $channel "SHARED_SOURCE pairs=[llength $sharedPlans] findedges=$::sharedEdges unique_components=[llength $sharedComps]"
    set ::SolidSeam::autoGroupSummary $originalSummary
    proc planFingerprints {inputPlans} {
        set result {}
        foreach plan $inputPlans {
            set rows {}
            foreach candidate [dict get $plan candidates] { lappend rows [::SolidSeam::candidateFingerprint $candidate] }
            lappend result [list [dict get $plan pair_index] $rows]
        }
        return $result
    }
    set fingerprints [planFingerprints $plans]
    set legacyBaseline [file join $root temp solid_seam_refactor performance_plans.txt]
    set baseline [file join $root temp solid_seam_refactor performance_candidate_fingerprints.txt]
    if {[file exists $baseline]} {
        set input [open $baseline r]; set previous [read $input]; close $input
    } elseif {[file exists $legacyBaseline]} {
        set input [open $legacyBaseline r]; set legacyPlans [read $input]; close $input
        set previous [planFingerprints $legacyPlans]
    } else { set previous $fingerprints }
    if {$previous ne $fingerprints} { error "Candidate fingerprints changed from baseline: old=$previous new=$fingerprints" }
    set output [open $baseline w]; puts -nonewline $output $fingerprints; close $output
    puts $channel "CANDIDATE_FINGERPRINTS_MATCH=1 values=$fingerprints"
    foreach plan $plans {
        if {![dict exists $plan recognition_timings]} { error "Missing staged recognition timings" }
        foreach row [dict get $plan candidates] {
            if {![dict exists $row candidate_fingerprint]} { error "Missing candidate fingerprint" }
        }
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
