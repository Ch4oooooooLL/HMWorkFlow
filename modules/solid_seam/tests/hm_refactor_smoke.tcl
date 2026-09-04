# Run only in a NEW hmbatch process: imports the fixture into that process.
set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
set report [file join $root temp solid_seam_refactor native_[hm_info -appinfo VERSION].log]
file mkdir [file dirname $report]
set channel [open $report w]
fconfigure $channel -encoding utf-8 -buffering line
set rc [catch {
    source -encoding utf-8 [file join $root modules workflow_common.tcl]
    source -encoding utf-8 [file join $root modules solid_seam_connector.tcl]
    proc ::SolidSeam::message {icon text} { puts $::channel "MESSAGE $icon $text" }
    set executableDir [hm_info -appinfo EXECUTABLEDIR]
    *templatefileset [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
    set femPath [file join $root examples AutoShellSeamBackend test_fem combined_all_cases.fem]
    *feinputpreserveincludefiles
    *createstringarray 10 "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "
    *feinputwithdata2 "#optistruct\\optistruct" $femPath 0 0 0 0 0 1 10 1 0
    # Audit the actual native call boundary: no model-wide element selection,
    # and no temporary element marks left when entering realization.
    proc auditCreateMark {command operation} {
        lassign $command name entity slot
        set args [lrange $command 3 end]
        if {$entity in {elems elements} && $args eq {all}} { error "Unexpected all-element selection" }
        if {$entity in {elems elements} && [lindex $args 0] eq "by comp id"} { error "Unexpected component-wide element selection" }
    }
    trace add execution *createmark enter auditCreateMark
    proc auditCreateSeam {command operation} {
        puts $::channel "INPUT_LIST [hm_getlist nodes 1]"
        foreach slot {1 2} {
            if {[llength [hm_getmark elems $slot]]} { error "Element mark $slot leaked into realization" }
        }
    }
    trace add execution *CE_ConnectorCreateByListAndRealizeWithDetails enter auditCreateSeam
    set source [hm_getvalue comps name="F03_CASE_03_CURVED_T__BASE_T2" dataname=id]
    set target [hm_getvalue comps name="F03_CASE_03_CURVED_T__CURVED_WEB_T1" dataname=id]
    set settings [dict create search_distance 15 max_search_distance 15 min_weld_length 20 gap_jump_limit 5 default_width 6 default_spacing 6]
    set start [clock milliseconds]
    set candidates [::SolidSeam::autoDetectSeams $source $target $settings]
    puts $channel "DETECTION candidates=[llength $candidates] ms=[expr {[clock milliseconds]-$start}]"
    if {[llength $candidates] == 0} { error "No candidates" }
    set nodes [dict get [lindex $candidates 0] node_ids]
    set inferred [::SolidSeam::sourceComponentForNodes $nodes $target]
    if {$inferred != $source} { error "Wrong source: $inferred expected $source" }
    puts $channel "OWNERSHIP source=$source target=$target ordered_nodes=$nodes"
    foreach side {POSITIVE NEGATIVE BOTH} {
        set ::SolidSeam::ui(side_mode) $side
        set candidate [::SolidSeam::applyCreationSettings [lindex $candidates 0]]
        set result [::SolidSeam::createOneCandidate $candidate]
        set connector [dict get $result connector_id]
        set actual 1
        catch {set actual [hm_ce_detailget $connector int ce_penta_side_option]}
        set expected [dict get {POSITIVE 1 NEGATIVE 2 BOTH 3} $side]
        if {$actual != $expected} { error "Side ignored: $side actual=$actual expected=$expected" }
        set grade [dict get $result validation grade]
        if {$grade eq "FAIL"} { error "Realization failed: $result" }
        puts $channel "REALIZATION side=$side stored_side=$actual grade=$grade penta=[llength [dict get $result penta_ids]] applied=[dict get $result applied_parameters]"
    }
    if {[::SolidSeam::sourceComponentForNodes $nodes $target] != $source} { error "Existing weld changed node ownership" }
    foreach {type sourceName targetName} {
        L F07_CASE_07_PATCH__SMALL_PATCH_T1 F07_CASE_07_PATCH__LARGE_PATCH_TARGET_T2
        B F09_CASE_09_NEAR_FREE_EDGES_REVIEW__EDGE_PLATE_A_T1 F09_CASE_09_NEAR_FREE_EDGES_REVIEW__EDGE_PLATE_B_T1
    } {
        set source [hm_getvalue comps name=$sourceName dataname=id]
        set target [hm_getvalue comps name=$targetName dataname=id]
        set candidates [::SolidSeam::autoDetectSeams $source $target $settings]
        if {[llength $candidates] == 0} { error "No $type candidates" }
        set ::SolidSeam::ui(weld_type) $type
        set ::SolidSeam::ui(side_mode) POSITIVE
        set result [::SolidSeam::createOneCandidate [::SolidSeam::applyCreationSettings [lindex $candidates 0]]]
        if {[dict get $result validation grade] eq "FAIL"} { error "$type realization failed" }
        puts $channel "TYPE $type grade=[dict get $result validation grade] penta=[llength [dict get $result penta_ids]]"
    }
    set source [hm_getvalue comps name="F07_CASE_07_PATCH__SMALL_PATCH_T1" dataname=id]
    set target [hm_getvalue comps name="F07_CASE_07_PATCH__LARGE_PATCH_TARGET_T2" dataname=id]
    *createmark comps 1 $target
    *findedges comps 1 0
    set keptEdges [::SolidSeam::nativeComponentIdByName ^edges]
    set keptElements [::SolidSeam::componentElementIds $keptEdges]
    set graph [::SolidSeam::freeBoundaryGraph $source]
    if {[::SolidSeam::nativeComponentIdByName ^edges] != $keptEdges ||
        [::SolidSeam::componentElementIds $keptEdges] ne $keptElements} { error "Existing ^edges collector was modified" }
    set seed [lindex [lsort -integer [dict keys $graph]] 0]
    set paths [::SolidSeam::closedBoundariesForSeed $seed $source]
    if {[llength $paths] != 1} { error "Expected one patch boundary" }
    set path [lindex $paths 0]
    set internalSeed ""
    foreach node [::SolidSeam::componentNodeIds $source] {
        if {![dict exists $graph $node]} { set internalSeed $node; break }
    }
    if {$internalSeed eq "" || [llength [::SolidSeam::closedBoundariesForSeed $internalSeed $source]] != 1} {
        error "Interior seed did not find the source boundary"
    }
    puts $channel "INTERIOR_SEED=$internalSeed; existing_edges_preserved=1"
    set ::SolidSeam::ui(weld_type) L
    set candidate [::SolidSeam::applyCreationSettings [dict create candidate_id CLOSED_TEST \
        source_component_id $source target_component_id $target node_ids $path \
        status ACCEPTED duplicate_state NONE is_closed 0]]
    set openResult [::SolidSeam::createOneCandidate $candidate]
    dict set candidate is_closed 1
    set closedResult [::SolidSeam::createOneCandidate $candidate]
    set openCount [llength [dict get $openResult penta_ids]]
    set closedCount [llength [dict get $closedResult penta_ids]]
    if {[llength [dict get $closedResult connector_ids]] != 2} { error "Closed boundary must use two native arcs" }
    # Cap suppression and native spacing rounding can leave total element
    # counts unchanged. Check that generated PENTAs cover the closing edge.
    set firstArc [hm_ce_info [lindex [dict get $closedResult connector_ids] 0] location]
    set secondArc [hm_ce_info [lindex [dict get $closedResult connector_ids] 1] location]
    if {[::SolidSeam::nodeDistance [lindex $firstArc 0] [lindex $secondArc end]] > 1.0e-6 ||
        [::SolidSeam::nodeDistance [lindex $firstArc end] [lindex $secondArc 0]] > 1.0e-6} {
        error "Native connector arcs do not close at both shared endpoints"
    }
    puts $channel "NATIVE_ARCS_CLOSED=1"
    puts $channel "LOOP_PATH $path"
    puts $channel "CLOSED seed=$seed nodes=[llength $path] open_penta=$openCount closed_penta=$closedCount grade=[dict get $closedResult validation grade]"
    # Actual single-input batch integration, with its own result workspace.
    ::SolidSeam::newRun
    ::SolidSeam::createFromNodes [list $seed] [list $source $target]
    foreach slot {1 2} {
        if {[llength [hm_getmark elems $slot]]} { error "Elements still selected after batch" }
    }
    puts $channel "SINGLE_INPUT $::SolidSeam::lastResultSummary; element_marks_empty=1"
    foreach {expected sourceName targetName} {
        T_JOINT F01_CASE_01_STRAIGHT_T__WEB_T1 F01_CASE_01_STRAIGHT_T__BASE_T2
        L_JOINT F07_CASE_07_PATCH__SMALL_PATCH_T1 F07_CASE_07_PATCH__LARGE_PATCH_TARGET_T2
        BUTT_JOINT F09_CASE_09_NEAR_FREE_EDGES_REVIEW__EDGE_PLATE_A_T1 F09_CASE_09_NEAR_FREE_EDGES_REVIEW__EDGE_PLATE_B_T1
    } {
        if {$expected eq "L_JOINT"} { set expected LAP_JOINT }
        set source [hm_getvalue comps name=$sourceName dataname=id]
        set target [hm_getvalue comps name=$targetName dataname=id]
        set start [clock milliseconds]
        set settings [::SolidSeam::automaticSettings $source $target]
        set rows [::SolidSeam::autoDetectSeams $source $target $settings]
        if {[llength $rows] == 0} { error "Auto found no $expected seams" }
        foreach candidate $rows {
            if {[dict get $candidate joint_type] ne $expected} { error "Auto misclassified $expected: $candidate" }
        }
        set candidate [lindex $rows 0]
        puts $channel "AUTO $expected candidates=[llength $rows] detect_ms=[expr {[clock milliseconds]-$start}] width=[dict get $candidate weld_width] spacing=[dict get $candidate line_spacing] tol=[dict get $candidate realization_tolerance]"
        set result [::SolidSeam::createOneCandidate $candidate]
        if {[dict get $result validation grade] eq "FAIL"} { error "Auto realization failed" }
        puts $channel "AUTO_REALIZED $expected [dict get $result validation grade]"
    }
    # Native batch preparation must leave the model unchanged and retain each
    # pair's own inferred parameters until all groups have been realized.
    # Reload this isolated fixture so earlier smoke realizations do not occupy
    # the same locations as the batch under test.
    hm_answernext yes
    *deletemodel
    *feinputpreserveincludefiles
    *createstringarray 10 "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "
    *feinputwithdata2 "#optistruct\\optistruct" $femPath 0 0 0 0 0 1 10 1 0
    set ::SolidSeam::ui(input_type) AUTO
    set pairs {}
    foreach {sourceName targetName} {
        F01_CASE_01_STRAIGHT_T__WEB_T1 F01_CASE_01_STRAIGHT_T__BASE_T2
        F07_CASE_07_PATCH__SMALL_PATCH_T1 F07_CASE_07_PATCH__LARGE_PATCH_TARGET_T2
        F09_CASE_09_NEAR_FREE_EDGES_REVIEW__EDGE_PLATE_A_T1 F09_CASE_09_NEAR_FREE_EDGES_REVIEW__EDGE_PLATE_B_T1
    } {
        lappend pairs [dict create node_ids {} component_ids [list \
            [hm_getvalue comps name=$sourceName dataname=id] [hm_getvalue comps name=$targetName dataname=id]]]
    }
    set before [lsort -integer [hm_entitylist elems id all]]
    set plans [::SolidSeam::prepareSelectionPairs $pairs]
    if {$before ne [lsort -integer [hm_entitylist elems id all]]} { error "Preparation changed model elements" }
    if {[llength $plans] != 3} { error "Batch lost a group" }
    foreach plan $plans {
        if {[dict exists $plan error]} { error "Batch preparation failed: $plan" }
        if {![::SolidSeam::executeSelectionPlan $plan]} { error "Native batch group failed: $plan" }
        puts $channel "BATCH_PAIR [dict get $plan pair_index] $::SolidSeam::lastResultSummary"
    }
    foreach slot {1 2} {
        if {[llength [hm_getmark elems $slot]]} { error "Batch leaked element marks" }
    }
    puts $channel "BATCH_PREPARE_NO_MODEL_CHANGE=1; BATCH_AUTO_ALL_THREE_PAIRS=1"
    # Re-import the fixture and remove one source boundary quad, producing
    # the user's missing-element notch. Only this isolated process is edited.
    hm_answernext yes
    *deletemodel
    *feinputpreserveincludefiles
    *createstringarray 10 "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "
    *feinputwithdata2 "#optistruct\\optistruct" $femPath 0 0 0 0 0 1 10 1 0
    set source [hm_getvalue comps name="F01_CASE_01_STRAIGHT_T__WEB_T1" dataname=id]
    set target [hm_getvalue comps name="F01_CASE_01_STRAIGHT_T__BASE_T2" dataname=id]
    set settings [::SolidSeam::automaticSettings $source $target]
    set original [::SolidSeam::autoDetectSeams $source $target $settings]
    set edge [dict get [lindex $original 0] node_ids]
    set a [lindex $edge 3]; set b [lindex $edge 4]
    set removed ""
    foreach elem [::SolidSeam::componentElementIds $source] {
        set enodes [::SolidSeam::elementNodes $elem]
        if {$a in $enodes && $b in $enodes} { set removed $elem; break }
    }
    if {$removed eq ""} { error "No boundary quad available for notch fixture" }
    *createmark elems 1 $removed
    *deletemark elems 1
    ::SolidSeam::clearInputSelection
    foreach automatic {0 1} {
        dict set settings automatic $automatic
        set start [clock milliseconds]
        set rows [::SolidSeam::autoDetectSeams $source $target $settings]
        if {[llength $rows] != 2} { error "Notch did not split seam: $rows" }
        foreach row $rows {
            set path [dict get $row node_ids]
            foreach n $path { if {$n ni $edge} { error "Notch recess retained node $n" } }
            if {$a in $path && $b in $path} { error "Weld bridged missing element" }
        }
        puts $channel "NOTCH automatic=$automatic removed_elem=$removed paths=[llength $rows] detect_ms=[expr {[clock milliseconds]-$start}] no_recess_or_bridge=1"
    }
} err opts]
if {$rc} { puts $channel "FAIL $err\n[dict get $opts -errorinfo]" } else { puts $channel PASS }
close $channel
exit $rc
