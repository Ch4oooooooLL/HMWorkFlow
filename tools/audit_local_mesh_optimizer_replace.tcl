# ============================================================================
# Audit probe 2: *replacenodes semantics + deleted/nonexistent id queries.
# Run with hmbatch (2019 or 2022). Results -> runtime/audit_lmo_replace_<VERSION>.log
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_lmo_replace_${version}.log"]
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
proc countElems {} {
    catch {*clearmark elems 1}
    *createmark elems 1 all
    return [llength [hm_getmark elems 1]]
}
proc countNodes {} {
    catch {*clearmark nodes 1}
    *createmark nodes 1 all
    return [llength [hm_getmark nodes 1]]
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
proc tria {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 105 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}
# dump connectivity of every element that touches any of the given nodes
proc dumpOwners {prefix nodeList} {
    catch {*clearmark elems 2}
    if {[catch {eval *createmark elems 2 "by node id" $nodeList} err]} {
        P "${prefix}_MARK_ERR" $err
        return
    }
    set ids [hm_getmark elems 2]
    P "${prefix}_OWNER_COUNT" [llength $ids]
    foreach eid $ids {
        try "${prefix}_OWNER_${eid}" {hm_getvalue elems id=$eid dataname=nodes}
    }
}

P "AUDIT_VERSION" $version

# ---------- Fixture A: two quads sharing edge (n2,n4) ----------
*collectorcreateonly components AUDIT_R1 "" 1
*currentcollector component AUDIT_R1
set n1 [node 40 0 0]
set n2 [node 41 0 0]
set n3 [node 42 0 0]
set n4 [node 41 10 0]
set n5 [node 40 10 0]
set n6 [node 42 10 0]
set q1 [quad [list $n1 $n2 $n4 $n5]]
set q2 [quad [list $n2 $n3 $n6 $n4]]
P "FIXA_NODES_BEFORE" [countNodes]
P "FIXA_ELEMS_BEFORE" [countElems]
dumpOwners FIXA_BEFORE [list $n2 $n4]

# ---------- *replacenodes n2 n4 1 1 (module's call) ----------
hm_answernext yes
try {REPLACE_11_OK} {*replacenodes $n2 $n4 1 1}
P "REPLACE_11_NODES" [countNodes]
P "REPLACE_11_ELEMS" [countElems]
try {REPLACE_11_N2_ID} {hm_getvalue nodes id=$n2 dataname=id}
try {REPLACE_11_N4_ID} {hm_getvalue nodes id=$n4 dataname=id}
try {REPLACE_11_N2_COORDS} {hm_nodevalue $n2}
try {REPLACE_11_N4_COORDS} {hm_nodevalue $n4}
dumpOwners REPLACE_11_AFTER [list $n2 $n4]

# ---------- Fixture B: fresh pair, mode 0 ----------
set m1 [node 50 0 0]
set m2 [node 51 0 0]
set m3 [node 52 0 0]
set m4 [node 51 10 0]
set m5 [node 50 10 0]
set m6 [node 52 10 0]
quad [list $m1 $m2 $m4 $m5]
quad [list $m2 $m3 $m6 $m4]
P "FIXB_NODES_BEFORE" [countNodes]
P "FIXB_ELEMS_BEFORE" [countElems]
hm_answernext yes
try {REPLACE_01_OK} {*replacenodes $m2 $m4 0 1}
P "REPLACE_01_NODES" [countNodes]
P "REPLACE_01_ELEMS" [countElems]
try {REPLACE_01_M2_ID} {hm_getvalue nodes id=$m2 dataname=id}
try {REPLACE_01_M4_ID} {hm_getvalue nodes id=$m4 dataname=id}
try {REPLACE_01_M2_COORDS} {hm_nodevalue $m2}
try {REPLACE_01_M4_COORDS} {hm_nodevalue $m4}
dumpOwners REPLACE_01_AFTER [list $m2 $m4]

# ---------- Fixture C: fresh pair, mode 1 location 0 ----------
set k1 [node 60 0 0]
set k2 [node 61 0 0]
set k3 [node 62 0 0]
set k4 [node 61 10 0]
set k5 [node 60 10 0]
set k6 [node 62 10 0]
quad [list $k1 $k2 $k4 $k5]
quad [list $k2 $k3 $k6 $k4]
hm_answernext yes
try {REPLACE_10_OK} {*replacenodes $k2 $k4 1 0}
P "REPLACE_10_NODES" [countNodes]
P "REPLACE_10_ELEMS" [countElems]
try {REPLACE_10_K2_ID} {hm_getvalue nodes id=$k2 dataname=id}
try {REPLACE_10_K4_ID} {hm_getvalue nodes id=$k4 dataname=id}
try {REPLACE_10_K2_COORDS} {hm_nodevalue $k2}
try {REPLACE_10_K4_COORDS} {hm_nodevalue $k4}
dumpOwners REPLACE_10_AFTER [list $k2 $k4]

# ---------- Fixture D: tria short-edge collapse ----------
set t1 [node 70 0 0]
set t2 [node 70.5 0 0]
set t3 [node 70 10 0]
set tq [tria [list $t1 $t2 $t3]]
P "FIXD_TRIA_OK" [expr {$tq ne ""}]
P "FIXD_NODES_BEFORE" [countNodes]
P "FIXD_ELEMS_BEFORE" [countElems]
hm_answernext yes
try {REPLACE_TRIA_OK} {*replacenodes $t1 $t2 1 1}
P "REPLACE_TRIA_NODES" [countNodes]
P "REPLACE_TRIA_ELEMS" [countElems]
try {REPLACE_TRIA_T1_ID} {hm_getvalue nodes id=$t1 dataname=id}
try {REPLACE_TRIA_T2_ID} {hm_getvalue nodes id=$t2 dataname=id}
try {REPLACE_TRIA_T1_COORDS} {hm_nodevalue $t1}
try {REPLACE_TRIA_T2_COORDS} {hm_nodevalue $t2}
dumpOwners REPLACE_TRIA_AFTER [list $t1 $t2]
try {REPLACE_TRIA_TQ_NODES} {hm_getvalue elems id=$tq dataname=nodes}

# ---------- Nonexistent id queries (no deletion involved) ----------
try {NEVEREXISTED_NODE_ID} {hm_getvalue nodes id=999999 dataname=id}
try {NEVEREXISTED_NODE_X} {hm_getvalue nodes id=999999 dataname=x}
try {NEVEREXISTED_NODEVALUE} {hm_nodevalue 999999}
try {NEVEREXISTED_ELEM_NODES} {hm_getvalue elems id=999999 dataname=nodes}
try {NEVEREXISTED_ELEM_ID} {hm_getvalue elems id=999999 dataname=id}
# mark by a nonexistent node id
catch {*clearmark elems 2}
try {MARK_BY_NEVEREXISTED_NODE} {eval *createmark elems 2 "by node id" 999999}
P "MARK_BY_NEVEREXISTED_NODE_COUNT" [llength [hm_getmark elems 2]]

close $channel
exit 0
