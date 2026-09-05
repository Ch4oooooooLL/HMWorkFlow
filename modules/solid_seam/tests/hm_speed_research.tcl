# Research only: run in a fresh hmbatch process, never source in a user model.
# hmbatch.exe -nocommand -nouserprofiledialog -tcl <absolute script path>
set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
file mkdir [file join $root temp solid_seam_speed]
set channel [open [file join $root temp solid_seam_speed research.log] w]
fconfigure $channel -encoding utf-8 -buffering line
proc report {text} { puts $::channel $text }
proc fingerprints {plans} {
    set result {}
    foreach plan $plans {
        if {[dict exists $plan error]} { error [dict get $plan error] }
        foreach row [dict get $plan candidates] { lappend result [::SolidSeam::candidateFingerprint $row] }
    }
    return $result
}
proc measure {label script} {
    set values {}
    for {set i 0} {$i < 9} {incr i} {
        set start [clock microseconds]
        uplevel 1 $script
        lappend values [expr {[clock microseconds]-$start}]
    }
    report "$label median_us=[::SolidSeam::median $values] samples_us=$values"
}
set rc [catch {
    source -encoding utf-8 [file join $root modules workflow_common.tcl]
    source -encoding utf-8 [file join $root modules solid_seam_connector.tcl]
    proc ::SolidSeam::message {icon text} { report "$icon $text" }
    report "EXECUTABLE=[hm_info -appinfo EXECUTABLEDIR] VERSION=[hm_info -appinfo VERSION] TCL=[info patchlevel]"
    foreach cmd {hm_entityrecorder hm_getboundingbox hm_blockbrowserupdate hm_blockredraw} {
        report "API $cmd present=[expr {[llength [info commands $cmd]]>0}]"
    }
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
    report "MODEL nodes=[llength [hm_entitylist nodes id all]] elems=[llength [hm_entitylist elems id all]]"
    set ::SolidSeam::ui(input_type) AUTO_GROUP
    measure GROUP {set plans [::SolidSeam::prepareAutoGroup $comps]}
    set groupReference [fingerprints $plans]
    rename ::SolidSeam::groupComponentBounds ::SolidSeam::researchOriginalBounds
    proc ::SolidSeam::groupComponentBounds {component} {
        *createmark comps 1 $component
        set bounds [hm_getboundingbox comps 1 1 0 0]
        *clearmark comps 1
        return [list [lrange $bounds 0 2] [lrange $bounds 3 5]]
    }
    measure GROUP_NATIVE_BOUNDS_EXPERIMENT {set nativePlans [::SolidSeam::prepareAutoGroup $comps]}
    rename ::SolidSeam::groupComponentBounds {}
    rename ::SolidSeam::researchOriginalBounds ::SolidSeam::groupComponentBounds
    if {$groupReference ne [fingerprints $nativePlans]} { error "Native bounds fingerprints changed" }
    report "GROUP_NATIVE_BOUNDS_FINGERPRINTS_MATCH=1"
    set selections {}
    foreach plan $plans {
        set row [lindex [dict get $plan candidates] 0]
        lappend selections [dict create node_ids {} component_ids [list [dict get $row source_component_id] [dict get $row target_component_id]]]
    }
    set ::SolidSeam::ui(input_type) AUTO
    measure AUTO {set autoPlans [::SolidSeam::prepareSelectionPairs $selections]}
    set reference [fingerprints $autoPlans]
    measure AUTO_CACHE_EXPERIMENT {
        ::SolidSeam::beginGroupRecognitionCache $comps
        set autoPlans [::SolidSeam::prepareSelectionPairs $selections]
        ::SolidSeam::endGroupRecognitionCache
    }
    if {$reference ne [fingerprints $autoPlans]} { error "Auto cache fingerprints changed" }
    report "AUTO_CACHE_FINGERPRINTS_MATCH=1"
    set ids [lreverse [lrange [hm_entitylist nodes id all] 0 255]]
    measure XYZ_SCALAR {
        set scalar {}
        foreach axis {x y z} {
            set values {}
            foreach id $ids { lappend values [hm_getvalue nodes id=$id dataname=$axis] }
            lappend scalar $values
        }
    }
    measure XYZ_BATCH {
        set batch {}
        foreach axis {x y z} { lappend batch [hm_getvalue nodes "user_ids=$ids" dataname=$axis] }
    }
    # Numeric comparison permits equivalent numeric formatting, checks ordering.
    foreach a [concat {*}$scalar] b [concat {*}$batch] {
        if {$a != $b} { error "Batch query value/order differs" }
    }
    if {[llength [concat {*}$scalar]] != [llength [concat {*}$batch]]} { error "Batch query length differs" }
    report "XYZ_BATCH_MATCH=1 nodes=[llength $ids]"
    measure BOUNDS_TCL {
        set oldBounds {}
        foreach comp $comps { lappend oldBounds [concat {*}[::SolidSeam::groupComponentBounds $comp]] }
    }
    measure BOUNDS_NATIVE {
        set nativeBounds {}
        foreach comp $comps {
            *createmark comps 1 $comp
            lappend nativeBounds [hm_getboundingbox comps 1 1 0 0]
        }
        *clearmark comps 1
    }
    foreach a [concat {*}$oldBounds] b [concat {*}$nativeBounds] {
        if {abs($a-$b)>1.0e-8} { error "Bounds differ" }
    }
    report "BOUNDS_MATCH=1"
    set ::nativeTimes {}; set ::nativeStart 0
    proc nativeEnter {args} { set ::nativeStart [clock microseconds] }
    proc nativeLeave {args} { lappend ::nativeTimes [expr {[clock microseconds]-$::nativeStart}] }
    trace add execution *CE_ConnectorCreateByListAndRealizeWithDetails enter nativeEnter
    trace add execution *CE_ConnectorCreateByListAndRealizeWithDetails leave nativeLeave
    set createStart [clock microseconds]
    namespace eval ::SolidSeamCommandProfile { variable recorderShadow 1 }
    foreach plan $plans {
        set before [hm_entitylist elems id all]
        set ok [::SolidSeam::executeSelectionPlan $plan]
        if {!$ok} { error "Creation failed" }
        set delta [lsort -integer [::SolidSeamCommandProfile::newIds $before [hm_entitylist elems id all]]]
        report "RECORDER_SHADOW_MATCH pair=[dict get $plan pair_index] elements=[llength $delta]"
    }
    report "CREATE_WITH_AUDIT_US=[expr {[clock microseconds]-$createStart}] NATIVE_CALLS_US=$::nativeTimes"
    report PASS
} err opts]
catch {hm_entityrecorder elems off}
catch {::SolidSeam::endGroupRecognitionCache}
if {$rc} { report "FAIL $err\n[dict get $opts -errorinfo]" }
close $channel
catch {hm_exit}
