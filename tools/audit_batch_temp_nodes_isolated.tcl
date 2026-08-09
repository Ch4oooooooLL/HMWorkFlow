# Minimal isolated probe: does *deletemark nodes actually delete, and what is
# the verbatim error? Also isolates the bad-id mark call and *numbersmark on
# empty mark. Every step is flushed before/after so the log file maps 1:1 to
# the console error stream. Run once per installed HyperMesh:
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_batch_temp_nodes_isolated.tcl
#
# Results: runtime/audit_batch_temp_nodes_iso_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_temp_nodes_iso_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
    flush $channel
}
proc RAW {key value} {
    P $key [string map [list "\n" { } "\r" { }] $value]
}
proc nodeExists {id} {
    set v ""
    catch {set v [hm_getvalue nodes id=$id dataname=id]}
    return $v
}
proc nodeCount {} {
    catch {*clearmark nodes 9}
    *createmark nodes 9 all
    return [llength [hm_getmark nodes 9]]
}

# --- T1: *createmark with nonexistent id, isolated -------------------------
set t1 ""
if {[catch {eval *createmark nodes 2 "by id only" 999999} e]} { set t1 $e }
P "T1_BADID_MARK_ERR" $t1
set t1ids ""
catch {set t1ids [hm_getmark nodes 2]}
P "T1_BADID_MARK_IDS" [join $t1ids { }]

# --- T2: *numbersmark on an empty mark, isolated ---------------------------
set t2 ""
if {[catch {*numbersmark nodes 1 1} e]} { set t2 $e }
P "T2_NUMBERSMARK_EMPTY_ERR" $t2

# --- T3: *createmark nodes 1 -1 with nodes present -------------------------
set na [*createnode 1 1 1 0 0 0]
set nb [*createnode 2 2 2 0 0 0]
P "T3_RET_A" $na
P "T3_RET_B" $nb
set t3 ""
if {[catch {*createmark nodes 1 -1} e]} { set t3 $e }
P "T3_NEG1_ERR" $t3
set t3ids ""
catch {set t3ids [hm_getmark nodes 1]}
P "T3_NEG1_IDS" [join $t3ids { }]
P "T3_NODE_A_EXISTS" [nodeExists $na]
P "T3_NODE_B_EXISTS" [nodeExists $nb]

# --- T4: *deletemark nodes 2, mark by id only, isolated --------------------
catch {*clearmark nodes 2}
set t4m ""
if {[catch {eval *createmark nodes 2 "by id only" $na $nb} e]} { set t4m $e }
P "T4_MARK_ERR" $t4m
set t4ids ""
catch {set t4ids [hm_getmark nodes 2]}
P "T4_MARK_IDS" [join $t4ids { }]
P "T4_COUNT_BEFORE" [nodeCount]
set t4 ""
if {[catch {*deletemark nodes 2} e]} { set t4 $e }
P "T4_DELETE_ERR" $t4
P "T4_COUNT_AFTER" [nodeCount]
P "T4_NODE_A_EXISTS" [nodeExists $na]
P "T4_NODE_B_EXISTS" [nodeExists $nb]

# --- T5: second deletemark attempt on the same mark (determinism) ----------
set t5 ""
if {[catch {*deletemark nodes 2} e]} { set t5 $e }
P "T5_DELETE_AGAIN_ERR" $t5
P "T5_COUNT_AFTER" [nodeCount]
P "T5_NODE_A_EXISTS" [nodeExists $na]

# --- T6: *deletemark on mark 1 "all" ---------------------------------------
catch {*clearmark nodes 1}
*createmark nodes 1 all
set t6 ""
if {[catch {*deletemark nodes 1} e]} { set t6 $e }
P "T6_DELETE_ALL_ERR" $t6
P "T6_COUNT_AFTER" [nodeCount]
P "T6_NODE_A_EXISTS" [nodeExists $na]
P "T6_NODE_B_EXISTS" [nodeExists $nb]

# --- T7: delete a node attached to an element (quad, proven pattern) -------
set c1 [*createnode 10 0 0 0 0 0]
set c2 [*createnode 10 10 0 0 0 0]
set c3 [*createnode 0 10 0 0 0 0]
set c4 [*createnode 0 0 0 0 0 0]
catch {*clearmark nodes 1}
eval *createmark nodes 1 "by id only" $c1 $c2 $c3 $c4
set t7e ""
if {[catch {*createelement 104 1 1 1} e]} { set t7e $e }
P "T7_ELEM_CREATE_ERR" $t7e
P "T7_ELEM_EXISTS" [hm_getvalue elems mark=1 dataname=id]
catch {*clearmark nodes 2}
eval *createmark nodes 2 "by id only" $c1
set t7 ""
if {[catch {*deletemark nodes 2} e]} { set t7 $e }
P "T7_DELETE_ATTACHED_ERR" $t7
P "T7_NODE_C1_EXISTS" [nodeExists $c1]
P "T7_ELEM_STILL_EXISTS" [hm_getvalue elems mark=1 dataname=id]

# --- T8: module end-to-end again, with flush markers -----------------------
P "T8_START" 1
set mErr ""
if {[catch {
    source -encoding utf-8 [file join $root modules batch_temp_nodes.tcl]
} e]} { set mErr $e }
P "T8_SOURCE_ERR" $mErr
set parsed [::BatchTempNodes::parseCoordinates "0, 0, 0\n5, 5, 5"]
set created ""
set cErr ""
if {[catch {set created [::BatchTempNodes::createNodes [dict get $parsed points]]} e]} {
    set cErr $e
}
P "T8_CREATE_ERR" $cErr
P "T8_CREATED_IDS" [join $created { }]
P "T8_COUNT_AFTER_CREATE" [nodeCount]
set dErr ""
if {[catch {::BatchTempNodes::deleteNodes $created} e]} { set dErr $e }
P "T8_DELETE_ERR" $dErr
P "T8_COUNT_AFTER_DELETE" [nodeCount]
foreach nid $created {
    P "T8_NODE_${nid}_EXISTS" [nodeExists $nid]
}

close $channel
exit 0
