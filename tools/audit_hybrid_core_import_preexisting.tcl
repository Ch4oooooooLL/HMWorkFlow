# Probe: does $HMCOMP ID assignment work when the target component exists in
# the model BEFORE the import (vs created in-file via $HMNAME COMP)?
#
# The production smoke test (2026-07-18 log) verified a RIGIDS import where the
# target component pre-existed; the probe decks with in-file-created components
# landed in misc1. This test isolates that variable.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version ""
catch {set version [string trim [hm_info -appinfo VERSION]]}
if {$version eq ""} { set version "unknown" }
set fileVersion [regsub -all {[^a-zA-Z0-9]} $version _]
set reportPath [file join $outputDir "audit_hybrid_core_import_preexisting_${fileVersion}.log"]
set ::auditChannel [open $reportPath w]

proc P {key value} {
    variable ::auditChannel
    puts $::auditChannel "${key}=${value}"
    flush $::auditChannel
}
proc R {label script} {
    if {[catch {uplevel 1 $script} value options]} {
        P $label "ERROR:[string map [list \n { } \r {}] $value]"
    } else {
        P $label [string map [list \n { } \r {}] $value]
    }
}
proc wipeModel {label} {
    catch {hm_answernext yes}
    R ${label} {*deletemodel}
    catch {hm_answernext all}
}

P "audit_start" [clock format [clock seconds]]
P "hm_version" $version

set ::auditDeck [file join $outputDir audit_preexisting_deck.fem]
set channel [open $::auditDeck w]
puts $channel "BEGIN BULK"
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,901,,10.,10.,0."
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,902,,0.,0.,0."
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,903,,20.,0.,0."
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,904,,0.,20.,0."
puts $channel "RBE2,910,901,123456,902,903,904"
puts $channel "ENDDATA"
puts $channel ""
close $channel

proc check {label} {
    R ${label}_import {*feinputwithdata2 "#optistruct/optistruct" $::auditDeck 0 0 0 0 0 1 2 1 0}
    catch {*clearmark comps 2}
    R ${label}_comps_mark {*createmark comps 2 all}
    set ids ""
    R ${label}_comps_ids {set ids [hm_getmark comps 2]}
    set names {}
    foreach id $ids {
        set name ""
        catch {set name [hm_getvalue comps id=$id dataname=name]}
        lappend names "$id=$name"
    }
    P "${label}_comp_list" [join $names { | }]
    R ${label}_elem_comp {hm_getvalue elems id=910 dataname=collector.id}
}

# Test 1: comp 900 pre-exists; deck has $HMCOMP ID 900 only (no $HMNAME line)
wipeModel clean_1
R comp_pre_1 {*collectorcreateonly components audit_preexisting "" 5}
R comp_pre_1_id {hm_getvalue comps name=audit_preexisting dataname=id}
R current_comp_1 {*currentcollector component audit_preexisting}
check preexisting

# Test 2: comp 900 pre-exists; deck also has $HMNAME COMP 900 line
set ::auditDeck2 [file join $outputDir audit_preexisting_deck2.fem]
set channel [open $::auditDeck2 w]
puts $channel "BEGIN BULK"
puts $channel "\$HMNAME COMP 900 \"audit_rigid_comp\""
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,901,,10.,10.,0."
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,902,,0.,0.,0."
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,903,,20.,0.,0."
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,904,,0.,20.,0."
puts $channel "RBE2,910,901,123456,902,903,904"
puts $channel "ENDDATA"
puts $channel ""
close $channel
wipeModel clean_2
R comp_pre_2 {*collectorcreateonly components audit_preexisting "" 5}
R current_comp_2 {*currentcollector component audit_preexisting}
R import_2 {*feinputwithdata2 "#optistruct/optistruct" $::auditDeck2 0 0 0 0 0 1 2 1 0}
catch {*clearmark comps 2}
R comps2_mark {*createmark comps 2 all}
set ids2 ""
R comps2_ids {set ids2 [hm_getmark comps 2]}
set names2 {}
foreach id $ids2 {
    set name ""
    catch {set name [hm_getvalue comps id=$id dataname=name]}
    lappend names2 "$id=$name"
}
P "hname_comp_list" [join $names2 { | }]
R hname_elem_comp {hm_getvalue elems id=910 dataname=collector.id}

# Test 3: pre-existing comp but NO $HMCOMP ID lines in deck (assign to current)
set ::auditDeck3 [file join $outputDir audit_preexisting_deck3.fem]
set channel [open $::auditDeck3 w]
puts $channel "BEGIN BULK"
puts $channel "GRID,901,,10.,10.,0."
puts $channel "GRID,902,,0.,0.,0."
puts $channel "GRID,903,,20.,0.,0."
puts $channel "GRID,904,,0.,20.,0."
puts $channel "RBE2,910,901,123456,902,903,904"
puts $channel "ENDDATA"
puts $channel ""
close $channel
wipeModel clean_3
R comp_pre_3 {*collectorcreateonly components audit_current "" 6}
R current_comp_3 {*currentcollector component audit_current}
R import_3 {*feinputwithdata2 "#optistruct/optistruct" $::auditDeck3 0 0 0 0 0 1 2 1 0}
catch {*clearmark comps 2}
R comps3_mark {*createmark comps 2 all}
set ids3 ""
R comps3_ids {set ids3 [hm_getmark comps 2]}
set names3 {}
foreach id $ids3 {
    set name ""
    catch {set name [hm_getvalue comps id=$id dataname=name]}
    lappend names3 "$id=$name"
}
P "nocomment_comp_list" [join $names3 { | }]
R nocomment_elem_comp {hm_getvalue elems id=910 dataname=collector.id}

P "audit_done" 1
close $::auditChannel
exit 0
