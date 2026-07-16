proc ::RB2Bolt::incrementalImportError {stage incrementalFem reader detail expected detected} {
    return "INCREMENTAL_IMPORT_FAILED stage=$stage incremental_fem=[file nativename $incrementalFem] reader=$reader expected_element_ids={$expected} detected_element_ids={$detected} detail={$detail} hint={Run one manual OptiStruct Solver Deck import in HM2019 and compare command.tcl import_reader/options. The source selection FEM and incremental FEM are retained in the task workspace.}"
}

proc ::RB2Bolt::existingExpectedElements {expectedIds} {
    set found {}
    foreach eid $expectedIds {
        set value ""
        if {![catch {set value [hm_getvalue elems id=$eid dataname=id]}] && $value ne "" && $value != 0} {
            lappend found $eid
        }
    }
    return [lsort -integer -unique $found]
}

proc ::RB2Bolt::verifyImportedSegments {segments incrementalFem reader} {
    set expected_element_ids {}
    foreach row $segments { lappend expected_element_ids [dict get $row element_id] }
    set detected [::RB2Bolt::existingExpectedElements $expected_element_ids]
    set missing {}
    set wrong {}
    foreach row $segments {
        set eid [dict get $row element_id]
        if {$eid ni $detected} { lappend missing $eid; continue }
        set actual {}
        catch {set actual [hm_getvalue elems id=$eid dataname=nodes]}
        set expected [lsort -integer [list [dict get $row node_1] [dict get $row node_2]]]
        if {[llength $actual] != 2 || [lsort -integer $actual] ne $expected} {
            lappend wrong "$eid:expected=$expected,actual=$actual"
        }
    }
    if {[llength $missing] > 0 || [llength $wrong] > 0} {
        error [::RB2Bolt::incrementalImportError verify $incrementalFem $reader "missing={$missing}; endpoint_mismatch={$wrong}" $expected_element_ids $detected]
    }
    return [llength $detected]
}

proc ::RB2Bolt::importIncrementalFem {payload {progressStart 65.0} {progressEnd 96.0}} {
    variable P
    set summary [dict get $payload summary]
    set incrementalFem [dict get $summary incremental_fem]
    set segments [dict get $summary expected_segments]
    set expected_element_ids [dict get $summary created_element_ids]
    set pairCount [dict get $summary pair_count]
    set existing [expr {$pairCount - [dict get $summary planned_create_count]}]
    if {$P(dryRun) || [llength $expected_element_ids] == 0} {
        return [dict create created 0 skipped 0 skipped_existing $existing pair_count $pairCount incremental_fem $incrementalFem]
    }
    if {![file isfile $incrementalFem]} {
        error [::RB2Bolt::incrementalImportError preflight $incrementalFem "#optistruct/optistruct" "incremental FEM does not exist" $expected_element_ids {}]
    }
    set occupied [::RB2Bolt::existingExpectedElements $expected_element_ids]
    if {[llength $occupied] > 0} {
        error [::RB2Bolt::incrementalImportError preflight $incrementalFem "#optistruct/optistruct" "generated element IDs already exist before import" $expected_element_ids $occupied]
    }
    foreach row $segments {
        foreach key {node_1 node_2} {
            set nid [dict get $row $key]
            set value ""
            if {[catch {set value [hm_getvalue nodes id=$nid dataname=id]} err] || $value eq ""} {
                error [::RB2Bolt::incrementalImportError preflight $incrementalFem "#optistruct/optistruct" "endpoint GRID $nid is missing in current model; hm_error=$err" $expected_element_ids {}]
            }
        }
    }

    set reader "#optistruct/optistruct"
    set importCommand "*feinputwithdata2 $reader <incremental_fem> 0 0 0 0 0 1 2 1 0"
    ::HybridCore::progressUpdate $progressStart "RBE2 Bolt Connector" "Importing incremental FEM into the current HyperMesh session..." 1
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    set code [catch {
        *feinputwithdata2 $reader [file nativename $incrementalFem] 0 0 0 0 0 1 2 1 0
    } importError importOptions]
    if {$code} {
        set detected [::RB2Bolt::existingExpectedElements $expected_element_ids]
        set detail "command={$importCommand}; hm_error={$importError}; error_options={$importOptions}"
        error [::RB2Bolt::incrementalImportError import $incrementalFem $reader $detail $expected_element_ids $detected]
    }
    set created [::RB2Bolt::verifyImportedSegments $segments $incrementalFem $reader]
    ::HybridCore::progressUpdate $progressEnd "RBE2 Bolt Connector" "Incremental FEM import verified: $created connectors." 1
    return [dict create created $created skipped 0 skipped_existing $existing pair_count $pairCount incremental_fem $incrementalFem]
}

# Compatibility entry point retained for callers and smoke tests.
proc ::RB2Bolt::executePythonPlans {payload {progressStart 65.0} {progressEnd 96.0}} {
    return [::RB2Bolt::importIncrementalFem $payload $progressStart $progressEnd]
}
