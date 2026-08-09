# ============================================================================
# Audit probe 4: definitive *replacenodes semantics with connectivity dumps.
# Results -> runtime/audit_lmo_replace2_<VERSION>.log
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_lmo_replace2_${version}.log"]
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
proc allElems {} {
    catch {*clearmark elems 1}
    *createmark elems 1 all
    return [hm_getmark elems 1]
}
proc dumpAllElems {prefix} {
    foreach eid [allElems] {
        try "${prefix}_E${eid}" {hm_getvalue elems id=$eid dataname=nodes}
    }
}

P "AUDIT_VERSION" $version

*collectorcreateonly components AUDIT_R2 "" 1
*currentcollector component AUDIT_R2

# ---- Fixture: two quads sharing edge (n2,n4); collapse n2->n4, mode 1 loc 1
set n1 [node 40 0 0]
set n2 [node 41 0 0]
set n3 [node 42 0 0]
set n4 [node 41 10 0]
set n5 [node 40 10 0]
set n6 [node 42 10 0]
set q1 [quad [list $n1 $n2 $n4 $n5]]
set q2 [quad [list $n2 $n3 $n6 $n4]]
P "R2_IDS" "$n1 $n2 $n3 $n4 $n5 $n6 / q1=$q1 q2=$q2"
dumpAllElems R2_BEFORE
catch {*clearmark elems 2}
*createmark elems 2 "by node id" $n2 $n4
P "R2_BEFORE_MARK_BY_NODE_ID" [join [hm_getmark elems 2] { }]
hm_answernext yes
try {R2_COLLAPSE} {*replacenodes $n2 $n4 1 1}
P "R2_AFTER_ELEMS" [join [allElems] { }]
P "R2_AFTER_NODES" [llength [hm_getmark nodes 1]]
catch {*clearmark nodes 1}
*createmark nodes 1 all
P "R2_AFTER_NODE_COUNT" [llength [hm_getmark nodes 1]]
dumpAllElems R2_AFTER
catch {*clearmark elems 2}
*createmark elems 2 "by node id" $n2 $n4
P "R2_AFTER_MARK_BY_NODE_ID" [join [hm_getmark elems 2] { }]
catch {*clearmark elems 2}
*createmark elems 2 "by all nodes" $n2 $n4
P "R2_AFTER_MARK_BY_ALL_NODES" [join [hm_getmark elems 2] { }]
try {R2_N2_COORDS} {hm_nodevalue $n2}
try {R2_N4_COORDS} {hm_nodevalue $n4}

# ---- Fixture: tria collapse (short edge), dump all connectivities
set s1 [node 60 0 0]
set s2 [node 60.5 0 0]
set s3 [node 60 10 0]
set s4 [node 70 0 0]
set sq1 [quad [list $s1 $s2 $s4 $s3]]
catch {*clearmark elems 1}
*createmark elems 1 $sq1
try {R2_SPLIT} {*splitelements 2 1}
set trias {}
foreach eid [allElems] {
    if {[llength [hm_getvalue elems id=$eid dataname=nodes]] == 3} { lappend trias $eid }
}
P "R2_TRIAS" [join $trias { }]
dumpAllElems R2_TRIA_BEFORE
set t1 [lindex $trias 0]
set tNodes [hm_getvalue elems id=$t1 dataname=nodes]
P "R2_TRIA1_NODES" $tNodes
set a [lindex $tNodes 0]
set b [lindex $tNodes 1]
hm_answernext yes
try {R2_TRIA_COLLAPSE} {*replacenodes $a $b 1 1}
P "R2_TRIA_AFTER_ELEMS" [join [allElems] { }]
dumpAllElems R2_TRIA_AFTER
catch {*clearmark nodes 1}
*createmark nodes 1 all
P "R2_TRIA_AFTER_NODE_COUNT" [llength [hm_getmark nodes 1]]
try {R2_TRIA_A_ID} {hm_getvalue nodes id=$a dataname=id}
try {R2_TRIA_B_ID} {hm_getvalue nodes id=$b dataname=id}
try {R2_TRIA_A_COORDS} {hm_nodevalue $a}
try {R2_TRIA_B_COORDS} {hm_nodevalue $b}
# query the deleted tria
try {R2_TRIA1_AFTER_QUERY} {hm_getvalue elems id=$t1 dataname=nodes}
# mark by surviving nodes - which elements still hold them
catch {*clearmark elems 2}
*createmark elems 2 "by node id" $a $b
P "R2_TRIA_AFTER_MARK_BY_NODE_ID" [join [hm_getmark elems 2] { }]

# ---- MARK ARG STYLE: does eval + single-list-arg behave like multi-arg?
# Fixture: fresh two quads sharing nodes 2,4 (module uses eval + single list arg)
set w1 [node 20 0 0]
set w2 [node 21 0 0]
set w3 [node 22 0 0]
set w4 [node 21 10 0]
set w5 [node 20 10 0]
set w6 [node 22 10 0]
quad [list $w1 $w2 $w4 $w5]
quad [list $w2 $w3 $w6 $w4]
set ids [list $w2 $w4]
P "MARKSTYLE_IDS" [join $ids { }]
proc markTry {key script} {
    catch {*clearmark elems 2}
    set code [catch {uplevel 1 $script} err]
    P "MARKSTYLE_${key}_CODE" $code
    if {$code} {
        P "MARKSTYLE_${key}_ERR" $err
    } else {
        P "MARKSTYLE_${key}_MARK" [join [hm_getmark elems 2] { }]
    }
}
markTry DIRECT {*createmark elems 2 "by node id" $w2 $w4}
markTry EVAL_LISTARG {eval *createmark elems 2 [list "by node id"] $ids}
markTry EVAL_MULTIARG {eval *createmark elems 2 "by node id" $w2 $w4}
markTry EVAL_BRACED_SEL_LISTARG {eval *createmark elems 2 {"by node id"} $ids}
markTry EVAL_ALLNODES_LISTARG {eval *createmark elems 2 [list "by all nodes"] $ids}

close $channel
exit 0
