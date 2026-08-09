# Audit probe for modules/batch_temp_nodes.tcl native HyperMesh commands.
#
# Covers, per installed HyperMesh build:
#   1. Existence of every native command the module calls, plus candidate
#      alternatives (*createtempnode, *deletelist, *deleteentity, hm_undo,
#      *numbersclear, hm_createmark, hm_markclear).
#   2. *createnode semantics: 6-arg vs 3-arg call, return value, coordinates,
#      scientific notation, current-component placement, and the "-1 mark"
#      last-created trick.
#   3. Mark/delete semantics: *createmark "by id only" vs plain id list,
#      nonexistent id behavior, *deletemark, *clearmark on empty mark,
#      *numbersmark on/off.
#   4. End-to-end: source the real module and run
#      ::BatchTempNodes::parseCoordinates / createNodes / deleteNodes
#      exactly as the module executes them.
#
# Run headless (one launch per version):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_temp_nodes_core.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_temp_nodes_core.tcl
#
# hmbatch has no stdout channel: results go to
# runtime/audit_batch_temp_nodes_<version>.log as KEY=VALUE (ASCII only).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_temp_nodes_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

proc has {name} {
    expr {[info commands $name] ne ""}
}

# --- 1. Command existence --------------------------------------------------
foreach name {
    *createnode *createmark *deletemark *clearmark *numbersmark
    hm_latestentityid hm_redraw
    *createtempnode *deletelist *deleteentity *nodecreate *createnodelist
    *numbersclear hm_undo hm_createmark hm_markclear
} {
    P "EXISTS $name" [has $name]
}
P "NODE_COMMANDS" [join [lsort [info commands *node*]] { }]
P "DELETE_COMMANDS" [join [lsort [info commands *delete*]] { }]
P "UNDO_COMMANDS" [join [lsort [info commands *undo*]] { }]

# --- 2. Baseline -----------------------------------------------------------
catch {*clearmark nodes 1}
*createmark nodes 1 all
P "NODES_BEFORE" [llength [hm_getmark nodes 1]]
set latestBefore ""
catch {set latestBefore [hm_latestentityid nodes]}
P "LATEST_BEFORE" $latestBefore

# --- 3. *createnode semantics ----------------------------------------------
# 3a. 6-arg call (the module's exact form): return value vs actual id.
set ret6 ""
set err6 ""
if {[catch {set ret6 [*createnode 10.0 20.5 -30.25 0 0 0]} e]} { set err6 $e }
P "CREATENODE_6ARGS_RET" $ret6
P "CREATENODE_6ARGS_ERR" $err6
catch {*clearmark nodes 1}
set neg1Err ""
if {[catch {*createmark nodes 1 -1} e]} { set neg1Err $e }
P "CREATEMARK_NEG1_ERR" $neg1Err
set neg1Ids ""
catch {set neg1Ids [hm_getmark nodes 1]}
P "CREATEMARK_NEG1_IDS" [join $neg1Ids { }]
set latestAfter1 ""
catch {set latestAfter1 [hm_latestentityid nodes]}
P "LATEST_AFTER_1" $latestAfter1
catch {*clearmark nodes 1}
*createmark nodes 1 all
P "NODES_AFTER_1" [llength [hm_getmark nodes 1]]
# coordinates of the node we just created (via mark of latest)
set coords ""
catch {
    *createmark nodes 1 -1
    set coords [hm_getvalue nodes mark=1 dataname=coordinates]
}
P "CREATENODE_COORDS" [join $coords { }]

# 3b. 3-arg call (is the trailing 0 0 0 required?)
set ret3 ""
set err3 ""
if {[catch {set ret3 [*createnode 1.0 2.0 3.0]} e]} { set err3 $e }
P "CREATENODE_3ARGS_RET" $ret3
P "CREATENODE_3ARGS_ERR" $err3

# 3c. scientific notation / big negative (module accepts these inputs)
set retSci ""
set errSci ""
if {[catch {set retSci [*createnode 1e-3 -2.5E2 0.0 0 0 0]} e]} { set errSci $e }
P "CREATENODE_SCI_RET" $retSci
P "CREATENODE_SCI_ERR" $errSci

# 3d. current-component placement
set compErr ""
if {[catch {*collectorcreateonly components AUDIT_COMP_A "" 1} e]} { set compErr $e }
P "COMPCREATE_A_ERR" $compErr
set curErr ""
if {[catch {*currentcollector component AUDIT_COMP_A} e]} { set curErr $e }
P "CURCOLL_A_ERR" $curErr
catch {set ccRet [*createnode 5.0 5.0 5.0 0 0 0]}
set ccNode ""
catch {set ccNode [hm_latestentityid nodes]}
set compId ""
catch {set compId [hm_getvalue nodes id=$ccNode dataname=component.id]}
set compName ""
catch {set compName [hm_getcollectorname comps $compId]}
P "CURCOMP_NODE_ID" $ccNode
P "CURCOMP_NODE_COMPID" $compId
P "CURCOMP_NODE_COMPNAME" $compName

# --- 4. Mark / delete semantics --------------------------------------------
# Fresh pair of nodes to delete.
set delA [*createnode 100.0 0.0 0.0 0 0 0]
set delB [*createnode 200.0 0.0 0.0 0 0 0]
set delIds {}
foreach nid [list $delA $delB] {
    if {$nid ne "" && $nid > 0} { lappend delIds $nid }
}
# If *createnode returned nothing under hmbatch, fall back to latest ids.
if {[llength $delIds] < 2} {
    foreach nid [list $delA $delB] {
        set latest ""
        catch {set latest [hm_latestentityid nodes]}
        if {$latest ne "" && $latest > 0} { lappend delIds $latest }
        catch {*clearmark nodes 1}
        *createmark nodes 1 -1
        set neg ""
        catch {set neg [lindex [hm_getmark nodes 1] 0]}
        if {$neg ne "" && $neg > 0} { lappend delIds $neg }
    }
}
P "DELETE_TEST_IDS" [join $delIds { }]

# 4a. *createmark with "by id only"
catch {*clearmark nodes 2}
set markErr ""
if {[catch {eval [linsert $delIds 0 *createmark nodes 2 "by id only"]} e]} { set markErr $e }
P "CREATEMARK_BYIDONLY_ERR" $markErr
set markIds ""
catch {set markIds [hm_getmark nodes 2]}
P "CREATEMARK_BYIDONLY_COUNT" [llength $markIds]
P "CREATEMARK_BYIDONLY_IDS" [join [lsort $markIds] { }]

# 4b. *createmark with plain id list
catch {*clearmark nodes 3}
set markErr3 ""
if {[catch {eval [linsert $delIds 0 *createmark nodes 3]} e]} { set markErr3 $e }
P "CREATEMARK_PLAIN_ERR" $markErr3
set markIds3 ""
catch {set markIds3 [hm_getmark nodes 3]}
P "CREATEMARK_PLAIN_COUNT" [llength $markIds3]

# 4c. nonexistent id: does the mark call error or silently skip?
catch {*clearmark nodes 4}
set markErrBad ""
if {[catch {eval *createmark nodes 4 "by id only" 999999} e]} { set markErrBad $e }
P "CREATEMARK_BADID_ERR" $markErrBad
set markBad ""
catch {set markBad [hm_getmark nodes 4]}
P "CREATEMARK_BADID_COUNT" [llength $markBad]

# 4d. *numbersmark on / off
set numErrOn ""
catch {*clearmark nodes 1}
eval [linsert $delIds 0 *createmark nodes 1 "by id only"]
if {[catch {*numbersmark nodes 1 1} e]} { set numErrOn $e }
P "NUMBERSMARK_ON_ERR" $numErrOn
set numErrOff ""
catch {*clearmark nodes 1}
eval [linsert $delIds 0 *createmark nodes 1 "by id only"]
if {[catch {*numbersmark nodes 1 0} e]} { set numErrOff $e }
P "NUMBERSMARK_OFF_ERR" $numErrOff

# 4e. *deletemark: delete the pair, then confirm they are gone
catch {*clearmark nodes 2}
eval [linsert $delIds 0 *createmark nodes 2 "by id only"]
set delErr ""
if {[catch {*deletemark nodes 2} e]} { set delErr $e }
P "DELETEMARK_ERR" $delErr
catch {*clearmark nodes 2}
eval [linsert $delIds 0 *createmark nodes 2 "by id only"]
set remaining ""
catch {set remaining [hm_getmark nodes 2]}
P "DELETED_IDS_REMAINING" [join $remaining { }]
catch {*clearmark nodes 1}
*createmark nodes 1 all
P "NODES_AFTER_DELETE" [llength [hm_getmark nodes 1]]

# 4f. *clearmark empties a mark; no error on an already-empty mark
catch {*clearmark nodes 1}
eval [linsert $delIds 0 *createmark nodes 1 "by id only"]
set clearErr ""
if {[catch {*clearmark nodes 1} e]} { set clearErr $e }
P "CLEARMARK_ERR" $clearErr
set afterClear -1
catch {set afterClear [llength [hm_getmark nodes 1]]}
P "CLEARMARK_EMPTIES" $afterClear
set clearEmptyErr ""
if {[catch {*clearmark nodes 2} e]} { set clearEmptyErr $e }
P "CLEARMARK_EMPTY_ERR" $clearEmptyErr

# --- 5. hm_redraw ----------------------------------------------------------
set redrawErr ""
if {[catch {hm_redraw} e]} { set redrawErr $e }
P "REDRAW_ERR" $redrawErr

# --- 6. Alternatives -------------------------------------------------------
if {[has *createtempnode]} {
    set tmpRet ""
    set tmpErr ""
    if {[catch {set tmpRet [*createtempnode 77 88 99]} e]} { set tmpErr $e }
    P "CREATETEMPNODE_RET" $tmpRet
    P "CREATETEMPNODE_ERR" $tmpErr
    catch {*clearmark nodes 1}
    *createmark nodes 1 all
    P "NODES_TOTAL_AFTER_TEMP" [llength [hm_getmark nodes 1]]
}
if {[has *deleteentity]} {
    set deErr ""
    if {[catch {*deleteentity nodes 888888} e]} { set deErr $e }
    P "DELETEENTITY_ERR" $deErr
}

# --- 7. End-to-end: source the real module and run its procs ---------------
set moduleFile [file join $root modules batch_temp_nodes.tcl]
set srcErr ""
if {[catch {source -encoding utf-8 $moduleFile} e]} { set srcErr $e }
P "MODULE_SOURCE_ERR" $srcErr

set parsed [::BatchTempNodes::parseCoordinates "0, 0, 0\n100, 25.5, -10\n1e-3, -2.5E2, 0.5"]
P "PARSE_POINTS" [join [dict get $parsed points] { | }]
P "PARSE_ERRORS" [llength [dict get $parsed errors]]

catch {*clearmark nodes 1}
*createmark nodes 1 all
set beforeModule [llength [hm_getmark nodes 1]]
set created ""
set createErr ""
if {[catch {set created [::BatchTempNodes::createNodes [dict get $parsed points]]} e]} {
    set createErr $e
}
P "MODULE_CREATE_ERR" $createErr
P "MODULE_CREATED" [join $created { }]
catch {*clearmark nodes 1}
*createmark nodes 1 all
set afterCreate [llength [hm_getmark nodes 1]]
P "NODES_BEFORE_MODULE" $beforeModule
P "NODES_AFTER_MODULE_CREATE" $afterCreate

# undo via the module's deleteNodes (exact sequence the module runs)
set delErr2 ""
if {[catch {::BatchTempNodes::deleteNodes $created} e]} { set delErr2 $e }
P "MODULE_DELETE_ERR" $delErr2
catch {*clearmark nodes 1}
*createmark nodes 1 all
P "NODES_AFTER_MODULE_DELETE" [llength [hm_getmark nodes 1]]

# undo again on an already-deleted batch (stale ids) - module clears the list,
# so simulate a stale-id delete directly
set staleErr ""
if {[catch {::BatchTempNodes::deleteNodes $created} e]} { set staleErr $e }
P "MODULE_STALE_DELETE_ERR" $staleErr

close $channel
exit 0
