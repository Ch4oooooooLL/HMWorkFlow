# ============================================================================
# Audit probe 3: selector semantics debug + tria collapse + deleted-id query.
# Results -> runtime/audit_lmo_micro_<VERSION>.log
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_lmo_micro_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -encoding ascii -translation lf

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc try {key script} {
    if {[catch {uplevel 1 $script} result options]} {
        P $key "ERROR:$result"
    } else {
        P $key $result
    }
}
proc node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}

P "AUDIT_VERSION" $version

# ---------- 1. Selector semantics on a fresh pair of quads ----------
*collectorcreateonly components AUDIT_M1 "" 1
*currentcollector component AUDIT_M1
set n1 [node 40 0 0]
set n2 [node 41 0 0]
set n3 [node 42 0 0]
set n4 [node 41 10 0]
set n5 [node 40 10 0]
set n6 [node 42 10 0]
set q1 [quad [list $n1 $n2 $n4 $n5]]
set q2 [quad [list $n2 $n3 $n6 $n4]]
P "M1_Q1_NODES" [hm_getvalue elems id=$q1 dataname=nodes]
P "M1_Q2_NODES" [hm_getvalue elems id=$q2 dataname=nodes]
P "M1_NODE_IDS" "$n1 $n2 $n3 $n4 $n5 $n6"

proc markCount {key selector args} {
    catch {*clearmark elems 2}
    if {[catch {eval *createmark elems 2 [list $selector] $args} err]} {
        P $key "ERROR:$err"
    } else {
        P $key [join [hm_getmark elems 2] { }]
    }
}
markCount M1_SEL_BY_NODE_ID "by node id" $n2 $n4
markCount M1_SEL_BY_NODES "by nodes" $n2 $n4
markCount M1_SEL_BY_ALL_NODES "by all nodes" $n2 $n4
markCount M1_SEL_BY_NODE "by node" $n2 $n4
markCount M1_SEL_BY_COMP "by comp" AUDIT_M1
markCount M1_SEL_BY_COMP_ID "by comp id" AUDIT_M1

# ---------- 2. Tria via quad split, then collapse its short edge ----------
set s1 [node 60 0 0]
set s2 [node 70 0 0]
set s3 [node 65 10 0]
set s4 [node 55 10 0]
set sq [quad [list $s1 $s2 $s3 $s4]]
catch {*clearmark elems 1}
*createmark elems 1 $sq
try {M2_SPLIT} {*splitelements 2 1}
catch {*clearmark elems 1}
*createmark elems 1 all
set trias {}
foreach eid [hm_getmark elems 1] {
    if {[llength [hm_getvalue elems id=$eid dataname=nodes]] == 3} { lappend trias $eid }
}
P "M2_TRIAS" [join $trias { }]
# short edge of quad (60,0)-(65,10) diag split: trias {s1,s2,s3} and {s1,s3,s4}
# short edge in tria {s1,s2,s3}: s1-s2 (10 units) is the longest...
# collapse edge s1-s3 in first tria
set t1 [lindex $trias 0]
set tNodes [hm_getvalue elems id=$t1 dataname=nodes]
P "M2_TRIA1_NODES" $tNodes
set a [lindex $tNodes 0]
set b [lindex $tNodes 1]
P "M2_NODES_BEFORE" [expr {[llength [hm_getmark nodes 1]]}]
catch {*clearmark nodes 1}
*createmark nodes 1 all
set nodesBefore [llength [hm_getmark nodes 1]]
hm_answernext yes
try {M2_COLLAPSE} {*replacenodes $a $b 1 1}
P "M2_COLLAPSE_NODES" "${nodesBefore}/[llength [hm_getmark nodes 1]]"
catch {*clearmark elems 1}
*createmark elems 1 all
P "M2_COLLAPSE_ELEMS" [llength [hm_getmark elems 1]]
try {M2_TRIA1_NODES_AFTER} {hm_getvalue elems id=$t1 dataname=nodes}
try {M2_A_ID} {hm_getvalue nodes id=$a dataname=id}
try {M2_B_ID} {hm_getvalue nodes id=$b dataname=id}
try {M2_A_COORDS} {hm_nodevalue $a}
try {M2_B_COORDS} {hm_nodevalue $b}

# ---------- 3. Queries on nonexistent ids (no deletion) ----------
try {M3_NEVER_NODE_ID} {hm_getvalue nodes id=999999 dataname=id}
try {M3_NEVER_NODEVALUE} {hm_nodevalue 999999}
try {M3_NEVER_ELEM_NODES} {hm_getvalue elems id=999999 dataname=nodes}
try {M3_NEVER_ELEM_ID} {hm_getvalue elems id=999999 dataname=id}
catch {*clearmark elems 2}
try {M3_MARK_BY_NEVER_NODE} {eval *createmark elems 2 "by node id" 999999}
P "M3_MARK_BY_NEVER_NODE_COUNT" [llength [hm_getmark elems 2]]

# ---------- 4. *deletemark nodes on a lone node (crash isolation) ----------
P "M4_BEFORE" 1
set lone [node 55 55 0]
catch {*clearmark nodes 1}
*createmark nodes 1 $lone
P "M4_MARKED" 1
set m4Code [catch {*deletemark nodes 1} m4Err]
P "M4_DELETED_CODE" $m4Code
P "M4_DELETED_ERR" $m4Err
try {M4_QUERY_DELETED_ID} {hm_getvalue nodes id=$lone dataname=id}
P "M4_QUERY_DELETED_DONE" 1
try {M4_QUERY_DELETED_NODEVALUE} {hm_nodevalue $lone}
P "M4_QUERY_DELETED_NODEVALUE_DONE" 1

close $channel
exit 0
