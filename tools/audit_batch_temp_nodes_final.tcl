# Final confirmation probe for modules/batch_temp_nodes.tcl.
#
# Uses the module's exact marking idiom (eval [linsert ...]) so the
# "by id only" keyword is never word-split, marks 1-4 only, flushes every
# line, and logs verbatim error text plus entity-existence checks.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_batch_temp_nodes_final.tcl
#
# Results: runtime/audit_batch_temp_nodes_fin_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_temp_nodes_fin_${version}.log"]
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
    catch {*clearmark nodes 3}
    *createmark nodes 3 all
    return [llength [hm_getmark nodes 3]]
}
proc markByIdOnly {markId ids} {
    catch {*clearmark nodes $markId}
    eval [linsert $ids 0 *createmark nodes $markId "by id only"]
}

# --- F0b: mark id range validity (1..9) ------------------------------------
foreach m {1 2 3 4 5 6 7 8 9} {
    set err ""
    if {[catch {*createmark nodes $m all} e]} { set err $e }
    P "F0B_MARK_${m}_ERR" $err
}

# --- F1: *createnode return values and the -1 trick ------------------------
set r1 [*createnode 1 1 1 0 0 0]
set r2 [*createnode 2 2 2 0 0 0]
P "F1_RET_1" $r1
P "F1_RET_2" $r2
catch {*clearmark nodes 1}
catch {*createmark nodes 1 -1}
set neg1 ""
catch {set neg1 [hm_getmark nodes 1]}
P "F1_NEG1_IDS" [join $neg1 { }]
P "F1_LATEST" [hm_latestentityid nodes]

# --- F2: module-exact delete sequence on free nodes ------------------------
P "F2_START" 1
markByIdOnly 2 [list $r1 $r2]
set m2 ""
catch {set m2 [hm_getmark nodes 2]}
P "F2_MARK_IDS" [join $m2 { }]
P "F2_COUNT_BEFORE" [nodeCount]
set f2 ""
if {[catch {*deletemark nodes 2} e]} { set f2 $e }
P "F2_DELETE_ERR" $f2
P "F2_COUNT_AFTER" [nodeCount]
P "F2_NODE_R1_EXISTS" [nodeExists $r1]
P "F2_NODE_R2_EXISTS" [nodeExists $r2]

# --- F3: second deletemark attempt on same mark (determinism) --------------
set f3 ""
if {[catch {*deletemark nodes 2} e]} { set f3 $e }
P "F3_DELETE_AGAIN_ERR" $f3
P "F3_NODE_R1_EXISTS" [nodeExists $r1]

# --- F4: node attached to an element (quad4, proven pattern) ---------------
set q1 [*createnode 10 0 0 0 0 0]
set q2 [*createnode 10 10 0 0 0 0]
set q3 [*createnode 0 10 0 0 0 0]
set q4 [*createnode 0 0 0 0 0 0]
markByIdOnly 1 [list $q1 $q2 $q3 $q4]
set f4e ""
if {[catch {*createelement 104 1 1 1} e]} { set f4e $e }
P "F4_ELEM_CREATE_ERR" $f4e
set elemIds ""
catch {set elemIds [hm_getvalue elems mark=1 dataname=id]}
P "F4_ELEM_IDS" [join $elemIds { }]
markByIdOnly 2 [list $q1]
set f4 ""
if {[catch {*deletemark nodes 2} e]} { set f4 $e }
P "F4_DELETE_ATTACHED_ERR" $f4
P "F4_NODE_Q1_EXISTS" [nodeExists $q1]
catch {*clearmark elems 1}
*createmark elems 1 all
P "F4_ELEMS_REMAINING" [join [hm_getmark elems 1] { }]

# --- F5: node component placement (raw errors this time) -------------------
if {[catch {*collectorcreateonly components AUDIT_COMP_C "" 3} e]} {
    P "F5_COMPCREATE_ERR" $e
}
if {[catch {*currentcollector component AUDIT_COMP_C} e]} {
    P "F5_CURCOLL_ERR" $e
}
set curColl ""
catch {set curColl [hm_getcurrentcollector comps]}
P "F5_GETCURCOLLOR" $curColl
set cn [*createnode 50 50 50 0 0 0]
set cn ""
catch {set cn [hm_latestentityid nodes]}
P "F5_NODE_ID" $cn
foreach dn {comp collector.id component.id comp.id comps} {
    set val ""
    set err ""
    if {[catch {set val [hm_getvalue nodes id=$cn dataname=$dn]} e]} { set err $e }
    P "F5_DN_${dn}_VAL" $val
    P "F5_DN_${dn}_ERR" $err
}

# --- F6: *numbersmark on populated mark (module's call) --------------------
catch {*clearmark nodes 1}
eval [linsert [list $r1 $r2] 0 *createmark nodes 1 "by id only"]
set f6 ""
if {[catch {*numbersmark nodes 1 1} e]} { set f6 $e }
P "F6_NUMBERSMARK_ERR" $f6
if {[catch {*numbersmark nodes 1 0} e]} { P "F6_NUMBERSMARK_OFF_ERR" $e } else { P "F6_NUMBERSMARK_OFF_OK" 1 }

# --- F7: *deleteidrange discovery (candidate alternative) ------------------
set f7 ""
if {[catch {*deleteidrange} e]} { set f7 $e }
P "F7_DELETEIDRANGE_NOARG_ERR" $f7
set f7b ""
if {[catch {*deleteidrange nodes 1 1} e]} { set f7b $e }
P "F7_DELETEIDRANGE_NODES_ERR" $f7b
P "F7_NODE_R1_EXISTS" [nodeExists $r1]

# --- F8: *nodesandelemsclear signature discovery ---------------------------
set f8 ""
if {[catch {*nodesandelemsclear} e]} { set f8 $e }
P "F8_NODESANDELEMSCLEAR_ERR" $f8
P "F8_COUNT_AFTER" [nodeCount]

# --- F9: module end-to-end -------------------------------------------------
P "F9_START" 1
set srcErr ""
if {[catch {source -encoding utf-8 [file join $root modules batch_temp_nodes.tcl]} e]} {
    set srcErr $e
}
P "F9_SOURCE_ERR" $srcErr
set parsed [::BatchTempNodes::parseCoordinates "0, 0, 0\n5, 5, 5\n1e2, -1e-2, 3.5"]
P "F9_PARSE_COUNT" [llength [dict get $parsed points]]
set created ""
set cErr ""
if {[catch {set created [::BatchTempNodes::createNodes [dict get $parsed points]]} e]} {
    set cErr $e
}
P "F9_CREATE_ERR" $cErr
P "F9_CREATED" [join $created { }]
P "F9_COUNT_AFTER_CREATE" [nodeCount]
set dErr ""
if {[catch {::BatchTempNodes::deleteNodes $created} e]} { set dErr $e }
P "F9_DELETE_ERR" $dErr
P "F9_COUNT_AFTER_DELETE" [nodeCount]
foreach nid $created {
    P "F9_NODE_${nid}_EXISTS" [nodeExists $nid]
}

close $channel
exit 0
