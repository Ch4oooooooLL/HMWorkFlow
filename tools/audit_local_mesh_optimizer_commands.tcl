# ============================================================================
# Audit probe: Local Mesh Optimizer native command surface (read-only audit).
#
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_local_mesh_optimizer_commands.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_local_mesh_optimizer_commands.tcl
#
# Results are written to runtime/audit_local_mesh_optimizer_<VERSION>.log as
# KEY=VALUE lines (ASCII only). hmbatch has no stdout channel, so the script
# never puts to stdout; it exits 0 at the end.
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_local_mesh_optimizer_${version}.log"]
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

P "AUDIT_VERSION" $version
P "TCL_PATCHLEVEL" [info patchlevel]

# --- 1. Command existence ---------------------------------------------------
foreach cmd {
    *readqualitycriteria *splitelements *replacenodes *createvector *translatemark
    *writefile *readfile *numbersmark *createmark *clearmark *deletemark
    *createlist *createelement *collectorcreateonly *createnode *currentcollector
    hm_getelementsqualityinfo hm_getqualitysummary hm_getmark hm_getvalue
    hm_nodevalue hm_usermessage hm_viewfit hm_answernext hm_info
    *getqualitysummary *elementqualitysetup *elementqualityshutdown
    *elementqualitycollapseedge *checkelems *qualityindex *optimsmooth *nodemodify
    *movemarknodes *drawelems *remeshelems *automesh *undo *restore *undoall
} {
    P "EXISTS $cmd" [expr {[info commands $cmd] ne ""}]
}

# --- 2. hm_info keys used by the module -------------------------------------
try {HM_INFO_APPINFO_VERSION} {string trim [hm_info -appinfo VERSION]}
try {HM_INFO_APPINFO_ALTAIR_VERSION} {string trim [hm_info -appinfo ALTAIR_VERSION]}
try {HM_INFO_APPINFO_CURRENTFILE} {string trim [hm_info -appinfo CURRENTFILE]}
try {HM_INFO_CURRENTFILE} {string trim [hm_info currentfile]}

# --- 3. Fixture -------------------------------------------------------------
namespace eval ::Audit {}
proc ::Audit::component {name color} {
    *collectorcreateonly components $name "" $color
    *currentcollector component $name
    return [hm_getvalue comps name=$name dataname=id]
}
proc ::Audit::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc ::Audit::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}
proc ::Audit::countElems {} {
    catch {*clearmark elems 1}
    *createmark elems 1 all
    return [llength [hm_getmark elems 1]]
}
proc ::Audit::countNodes {} {
    catch {*clearmark nodes 1}
    *createmark nodes 1 all
    return [llength [hm_getmark nodes 1]]
}
proc ::Audit::splitProbe {key method n1 n2 n3 n4} {
    set q [::Audit::quad [list $n1 $n2 $n3 $n4]]
    set elemsBefore [::Audit::countElems]
    set nodesBefore [::Audit::countNodes]
    catch {*clearmark elems 1}
    *createmark elems 1 $q
    if {[catch {*splitelements $method 1} err]} {
        P $key "ERROR:$err"
        return
    }
    set elemsAfter [::Audit::countElems]
    set nodesAfter [::Audit::countNodes]
    # trias made from this quad: exactly 3 nodes, all inside the 4 quad nodes
    set quadNodes [list $n1 $n2 $n3 $n4]
    set sets {}
    catch {*clearmark elems 1}
    *createmark elems 1 all
    foreach eid [hm_getmark elems 1] {
        set nodes [hm_getvalue elems id=$eid dataname=nodes]
        if {[llength $nodes] == 3} {
            set inside 1
            foreach n $nodes {
                if {[lsearch -exact $quadNodes $n] < 0} { set inside 0 }
            }
            if {$inside} { lappend sets [lsort $nodes] }
        }
    }
    P "${key}_ELEMS" "${elemsBefore}/${elemsAfter}"
    P "${key}_NODES" "${nodesBefore}/${nodesAfter}"
    P $key [join [lsort $sets] {;}]
}
proc ::Audit::markProbe {key selector args} {
    catch {*clearmark elems 2}
    if {[catch {eval *createmark elems 2 [list $selector] $args} err]} {
        P $key "ERROR:$err"
    } else {
        P $key [llength [hm_getmark elems 2]]
    }
}

set comp1 [::Audit::component AUDIT_COMP1 1]
set comp2 [::Audit::component AUDIT_COMP2 2]
set comp3 [::Audit::component AUDIT_COMP3 3]
set comp4 [::Audit::component AUDIT_COMP4 4]

# Plate 1: 2x2 regular quads (10x10) -> all good under test.criteria
array set na {}
foreach x {0 10 20} {
    foreach y {0 10 20} {
        set na($x,$y) [::Audit::node $x $y 0]
    }
}
set goodQuads {}
*currentcollector component AUDIT_COMP1
foreach x0 {0 10} x1 {10 20} {
    foreach y0 {0 10} y1 {10 20} {
        lappend goodQuads [::Audit::quad [list $na($x0,$y0) $na($x1,$y0) $na($x1,$y1) $na($x0,$y1)]]
    }
}
# Plate 2: one narrow quad (0.5 x 10) -> fails min length (3.0) and aspect
*currentcollector component AUDIT_COMP2
set badElem [::Audit::quad [list \
    [::Audit::node 30 0 0] [::Audit::node 30.5 0 0] \
    [::Audit::node 30.5 10 0] [::Audit::node 30 10 0]]]

catch {*clearmark elems 1}
*createmark elems 1 all
P "FIXTURE_ELEMS" [llength [hm_getmark elems 1]]
P "FIXTURE_BAD_ELEM" $badElem

# --- 4. Criteria read + native quality check --------------------------------
set criteriaPath [file nativename [file join $root examples test.criteria]]
try {READQUALITYCRITERIA} [list *readqualitycriteria $criteriaPath]

catch {*clearmark elems 1}
catch {*clearmark elems 2}
catch {*clearmark elems 3}
*createmark elems 1 all
set qCode [catch {set qInfo [hm_getelementsqualityinfo 1 1 2]} qErr]
P "QCHECK_1112_OK" [expr {$qCode == 0}]
if {$qCode} {
    P "QCHECK_1112_ERR" $qErr
} else {
    P "QCHECK_1112_INFO" $qInfo
    P "QCHECK_1112_MARK1_COUNT" [llength [hm_getmark elems 1]]
    P "QCHECK_1112_MARK2_COUNT" [llength [hm_getmark elems 2]]
    P "QCHECK_1112_MARK3_COUNT" [llength [hm_getmark elems 3]]
    P "QCHECK_1112_BAD_IN_MARK1" [expr {$badElem in [hm_getmark elems 1]}]
    P "QCHECK_1112_BAD_IN_MARK2" [expr {$badElem in [hm_getmark elems 2]}]
    P "QCHECK_1112_BAD_IN_MARK3" [expr {$badElem in [hm_getmark elems 3]}]
}

catch {*clearmark elems 1}
catch {*clearmark elems 2}
catch {*clearmark elems 3}
*createmark elems 1 all
set qCode [catch {set qInfo [hm_getelementsqualityinfo 1 2 3]} qErr]
P "QCHECK_123_OK" [expr {$qCode == 0}]
if {$qCode} {
    P "QCHECK_123_ERR" $qErr
} else {
    P "QCHECK_123_INFO" $qInfo
    P "QCHECK_123_MARK1_COUNT" [llength [hm_getmark elems 1]]
    P "QCHECK_123_MARK2_COUNT" [llength [hm_getmark elems 2]]
    P "QCHECK_123_MARK3_COUNT" [llength [hm_getmark elems 3]]
    P "QCHECK_123_BAD_IN_MARK1" [expr {$badElem in [hm_getmark elems 1]}]
    P "QCHECK_123_BAD_IN_MARK2" [expr {$badElem in [hm_getmark elems 2]}]
    P "QCHECK_123_BAD_IN_MARK3" [expr {$badElem in [hm_getmark elems 3]}]
}

# criteria_check=0 variant (does 0 mean "no criteria" or is it invalid?)
catch {*clearmark elems 1}
catch {*clearmark elems 2}
catch {*clearmark elems 3}
*createmark elems 1 all
set qCode [catch {set qInfo [hm_getelementsqualityinfo 1 0 2]} qErr]
P "QCHECK_1102_OK" [expr {$qCode == 0}]
if {$qCode} { P "QCHECK_1102_ERR" $qErr } else { P "QCHECK_1102_INFO" $qInfo }

# good-only subset: 4 clean quads of comp1 -> 0 failures; interpret info[2] as QI
catch {*clearmark elems 1}
catch {*clearmark elems 2}
catch {*clearmark elems 3}
*createmark elems 1 "by comp id" $comp1
set qCode [catch {set qInfo [hm_getelementsqualityinfo 1 1 2]} qErr]
P "QCHECK_GOODONLY_OK" [expr {$qCode == 0}]
if {$qCode} {
    P "QCHECK_GOODONLY_ERR" $qErr
} else {
    P "QCHECK_GOODONLY_INFO" $qInfo
    P "QCHECK_GOODONLY_MARK2_COUNT" [llength [hm_getmark elems 2]]
}

# --- 5. Mark selectors used by the module -----------------------------------
::Audit::markProbe MARK_SELECTOR_BY_ALL_NODES "by all nodes" $na(0,0) $na(10,0)
::Audit::markProbe MARK_SELECTOR_BY_NODE_ID "by node id" $na(0,0) $na(10,0)
::Audit::markProbe MARK_SELECTOR_BY_NODES "by nodes" $na(0,0) $na(10,0)
::Audit::markProbe MARK_SELECTOR_BY_COMP_ID "by comp id" $comp2
::Audit::markProbe MARK_SELECTOR_BY_COMP "by comp" $comp2
::Audit::markProbe MARK_SELECTOR_DISPLAYED displayed
::Audit::markProbe MARK_SELECTOR_ALL all

# --- 6. Datanames -----------------------------------------------------------
try {ELEM_DATANAME_collectorid} {hm_getvalue elems id=$badElem dataname=collectorid}
try {ELEM_DATANAME_collector.id} {hm_getvalue elems id=$badElem dataname=collector.id}
try {ELEM_DATANAME_componentid} {hm_getvalue elems id=$badElem dataname=componentid}
try {ELEM_DATANAME_component.id} {hm_getvalue elems id=$badElem dataname=component.id}
try {ELEM_DATANAME_compid} {hm_getvalue elems id=$badElem dataname=compid}
try {ELEM_DATANAME_comp} {hm_getvalue elems id=$badElem dataname=comp}
try {ELEM_DATANAME_nodes} {hm_getvalue elems id=$badElem dataname=nodes}
try {ELEM_DATANAME_config} {hm_getvalue elems id=$badElem dataname=config}
try {NODE_DATANAME_id} {hm_getvalue nodes id=$na(0,0) dataname=id}
try {NODE_DATANAME_x} {hm_getvalue nodes id=$na(0,0) dataname=x}
try {NODEVALUE} {hm_nodevalue $na(0,0)}

# --- 6b. Decode hm_getelementsqualityinfo return tuple ----------------------
proc ::Audit::qcheck {key ids} {
    catch {*clearmark elems 1}
    catch {*clearmark elems 2}
    catch {*clearmark elems 3}
    eval *createmark elems 1 $ids
    if {[catch {set info [hm_getelementsqualityinfo 1 1 2]} err]} {
        P $key "ERROR:$err"
    } else {
        P $key $info
        P "${key}_MARK2_COUNT" [llength [hm_getmark elems 2]]
    }
}
::Audit::qcheck QDECODE_ONE_GOOD [list [lindex $goodQuads 0]]
::Audit::qcheck QDECODE_TWO_GOOD [list [lindex $goodQuads 0] [lindex $goodQuads 1]]
::Audit::qcheck QDECODE_GOOD_PLUS_BAD [list [lindex $goodQuads 0] $badElem]
::Audit::qcheck QDECODE_BAD_ONLY [list $badElem]

# --- 7. Display / answer commands -------------------------------------------
try {NUMBERSMARK} {*numbersmark elems 1 1}
try {USERMESSAGE} {hm_usermessage "audit probe"}
try {VIEWFIT} {hm_viewfit}
try {ANSWER_NEXT} {hm_answernext yes}

# --- 8. *splitelements methods 2 and 102 ------------------------------------
*currentcollector component AUDIT_COMP3
::Audit::splitProbe SPLIT_M2 2 \
    [::Audit::node 60 0 0] [::Audit::node 70 0 0] \
    [::Audit::node 65 10 0] [::Audit::node 55 10 0]
::Audit::splitProbe SPLIT_M102 102 \
    [::Audit::node 80 0 0] [::Audit::node 90 0 0] \
    [::Audit::node 85 10 0] [::Audit::node 75 10 0]

# --- 9. *replacenodes node pair merge ---------------------------------------
*currentcollector component AUDIT_COMP4
set cn1 [::Audit::node 40 0 0]
set cn2 [::Audit::node 41 0 0]
set cn3 [::Audit::node 42 0 0]
set cn4 [::Audit::node 41 10 0]
set cn5 [::Audit::node 40 10 0]
set cn6 [::Audit::node 42 10 0]
::Audit::quad [list $cn1 $cn2 $cn4 $cn5]
::Audit::quad [list $cn2 $cn3 $cn6 $cn4]
set elemsBefore [::Audit::countElems]
set nodesBefore [::Audit::countNodes]
hm_answernext yes
set rCode [catch {*replacenodes $cn2 $cn4 1 1} rErr]
P "REPLACE_OK" [expr {$rCode == 0}]
if {$rCode} {
    P "REPLACE_ERR" $rErr
} else {
    P "REPLACE_ELEMS_BEFORE_AFTER" "${elemsBefore}/[::Audit::countElems]"
    P "REPLACE_NODES_BEFORE_AFTER" "${nodesBefore}/[::Audit::countNodes]"
    # getvalue on a deleted node returns "" (no error) - use value, not catch
    if {[catch {hm_getvalue nodes id=$cn2 dataname=id} vA]} { set idA "ERR:$vA" } else { set idA $vA }
    if {[catch {hm_getvalue nodes id=$cn4 dataname=id} vB]} { set idB "ERR:$vB" } else { set idB $vB }
    P "REPLACE_NODE_A_ID" $idA
    P "REPLACE_NODE_B_ID" $idB
    try {REPLACE_NODE_B_COORDS} {hm_nodevalue $cn4}
    try {REPLACE_NODE_A_COORDS} {hm_nodevalue $cn2}
    # degenerate elements left behind? dump the two former quad elements
    catch {*clearmark elems 1}
    *createmark elems 1 "by all nodes" $cn2 $cn4
    set owners [hm_getmark elems 1]
    P "REPLACE_EDGE_OWNER_ELEMS" [join $owners { }]
    foreach eid $owners {
        try "REPLACE_OWNER_${eid}_NODES" {hm_getvalue elems id=$eid dataname=nodes}
    }
}

# --- 10. *createvector + *translatemark -------------------------------------
set tn [::Audit::node 50 0 0]
catch {*clearmark nodes 1}
*createmark nodes 1 $tn
set vCode [catch {*createvector 1 1 0 0} vErr]
P "CREATEVECTOR_OK" [expr {$vCode == 0}]
if {$vCode} {
    P "CREATEVECTOR_ERR" $vErr
} else {
    set tCode [catch {*translatemark nodes 1 1 3.0} tErr]
    P "TRANSLATEMARK_OK" [expr {$tCode == 0}]
    if {$tCode} {
        P "TRANSLATEMARK_ERR" $tErr
    } else {
        try {TRANSLATED_COORDS} {hm_nodevalue $tn}
    }
}

# --- 11. *writefile / *readfile snapshot semantics --------------------------
set fpath [file nativename [file join $outputDir "audit_lmo_model_${version}.hm"]]
file delete -force $fpath
set wCode [catch {*writefile $fpath 1} wErr]
P "WRITEFILE_OK" [expr {$wCode == 0}]
if {$wCode} {
    P "WRITEFILE_ERR" $wErr
} else {
    P "WRITEFILE_EXISTS" [file isfile $fpath]
    try {HMINFO_CURRENTFILE_AFTER_WRITE} {string trim [hm_info currentfile]}
    catch {*clearmark elems 1}
    *createmark elems 1 all
    set totalNow [llength [hm_getmark elems 1]]
    P "TOTAL_BEFORE_READFILE_TEST" $totalNow
    # delete one element, then read back
    catch {*clearmark elems 1}
    *createmark elems 1 $badElem
    *deletemark elems 1
    catch {*clearmark elems 1}
    *createmark elems 1 all
    P "TOTAL_AFTER_DELETE" [llength [hm_getmark elems 1]]
    hm_answernext yes
    set r0Code [catch {*readfile $fpath 0} r0Err]
    P "READFILE_0_OK" [expr {$r0Code == 0}]
    if {$r0Code} {
        P "READFILE_0_ERR" $r0Err
    } else {
        catch {*clearmark elems 1}
        *createmark elems 1 all
        P "TOTAL_AFTER_READFILE_0" [llength [hm_getmark elems 1]]
    }
    hm_answernext yes
    set r1Code [catch {*readfile $fpath 1} r1Err]
    P "READFILE_1_OK" [expr {$r1Code == 0}]
    if {$r1Code} {
        P "READFILE_1_ERR" $r1Err
    } else {
        catch {*clearmark elems 1}
        *createmark elems 1 all
        P "TOTAL_AFTER_READFILE_1" [llength [hm_getmark elems 1]]
    }
}

# --- 12. Deleted / nonexistent node query behavior (last: may crash) --------
set ghostNode [::Audit::node 55 55 0]
P "GHOST_STEP_CREATE" $ghostNode
P "GHOST_STEP_MARKED" 1
catch {*clearmark nodes 1}
*createmark nodes 1 $ghostNode
P "GHOST_STEP_DELETE" 1
*deletemark nodes 1
P "GHOST_STEP_DELETED" 1
try {GHOST_GETVALUE_ID} {hm_getvalue nodes id=$ghostNode dataname=id}
P "GHOST_STEP_AFTER_GETVALUE_ID" 1
try {GHOST_NODEVALUE} {hm_nodevalue $ghostNode}
P "GHOST_STEP_AFTER_NODEVALUE" 1
try {GHOST_GETVALUE_X} {hm_getvalue nodes id=$ghostNode dataname=x}
P "GHOST_STEP_AFTER_GETVALUE_X" 1
try {GHOST_NEVEREXISTED_ID} {hm_getvalue nodes id=999999 dataname=id}
P "GHOST_STEP_AFTER_NEVEREXISTED" 1
try {GHOST_NEVEREXISTED_NODEVALUE} {hm_nodevalue 999999}
P "GHOST_STEP_AFTER_NEVEREXISTED_NODEVALUE" 1

close $channel
exit 0
