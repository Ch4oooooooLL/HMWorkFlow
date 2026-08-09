# Audit probe for the auto_hole_rbe2 module's HyperMesh native command usage.
# Covers: *findfaces, ^faces naming, *elementtype/*elementsettypes,
# *feoutput_select, *createnode, *rigidlink, *rbe3, *createmark -1,
# component create/rename/display commands, id-pool accessors, hm_info,
# block/suppress commands, and an alternative-command surface scan.
#
# Run headless:
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_auto_hole_rbe2_commands.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe"     -nocommand -nouserprofiledialog -tcl tools/audit_auto_hole_rbe2_commands.tcl
#
# Result: runtime/audit_auto_hole_rbe2_<version>.log  (KEY=VALUE, ASCII only)

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_auto_hole_rbe2_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc TRY {label script} {
    # run a script, record ok/error
    set code [catch {uplevel 1 $script} result opts]
    if {$code} {
        P "$label" "ERROR: $result"
    } else {
        P "$label" "OK: $result"
    }
}

P "VERSION" $version
P "TCL_PATCHLEVEL" [info patchlevel]

# ---------------------------------------------------------------- command surface
set moduleCommands {
    *clearmark *createmark *deletemark *clearmarkall
    *findfaces *elementtype *elementsettypes *feoutput_select
    *createnode *rigidlink *rbe3 *createarray *createdoublearray
    *createentity *collectorcreateonly *currentcollector *setvalue
    *marksuppressactive *marksuppressoutput
    *displaycollector *displaycollectorsbymark *displaycollectorsallbymark *displaycollectorwithfilter
    *setoption *startnotehistorystate *endnotehistorystate
    hm_getmark hm_getvalue hm_getidpools hm_getinternalid hm_getsolverid
    hm_entityinfo hm_nodevalue hm_nodelist hm_latestentityid
    hm_blockredraw hm_blockmessages hm_blockerrormessages hm_blockbrowserupdate
    hm_commandfilestate hmbr_signals hwbrowsermanager hm_redraw hm_usermessage
    hm_info
}
foreach name $moduleCommands {
    P "EXISTS $name" [expr {[llength [info commands $name]] > 0 ? 1 : 0}]
}

# alternative-command surface scan (official hole/cylinder/rigid detection?)
set altHits {}
foreach pattern {*findholes* *findhole* *hole* *cyl* *detect* *edgesfind* *rigid* *createidpool* *nodeidpool*} {
    foreach cmd [lsort [info commands $pattern]] {
        if {[lsearch -exact $altHits $cmd] < 0} { lappend altHits $cmd }
    }
}
P "ALT_COMMANDS" [join $altHits { }]

# ---------------------------------------------------------------- fixture: ring of hexas with a through hole
# 5x5x3 node grid (x,y in 0..40 step 10, z in 0..20 step 10), cells i,j in 0..3, k in 0..1.
# Center 2x2 cells per layer (i,j in 1..2) are omitted -> through hole.
namespace eval ::Audit {}
array set ::Audit::nid {}
proc ::Audit::hexa8 {n1 n2 n3 n4 n5 n6 n7 n8} {
    catch {*createmark nodes 1}
    eval *createlist nodes 1 [list $n1 $n2 $n3 $n4 $n5 $n6 $n7 $n8]
    *createelement 205 1 1 1
    catch {*clearmark nodes 1}
}

set nextId 1
for {set k 0} {$k < 3} {incr k} {
    for {set j 0} {$j < 5} {incr j} {
        for {set i 0} {$i < 5} {incr i} {
            set ::Audit::nid($i,$j,$k) $nextId
            incr nextId
            *createnode [expr {10*$i}] [expr {10*$j}] [expr {10*$k}] 0 0 0
        }
    }
}
catch {*createmark comps 2}
*collectorcreateonly comps AUDIT_SOLID "" 2
set solidComp [hm_getvalue comps name=AUDIT_SOLID dataname=id]
*currentcollector comps AUDIT_SOLID

set hexaCount 0
for {set k 0} {$k < 2} {incr k} {
    for {set j 0} {$j < 4} {incr j} {
        for {set i 0} {$i < 4} {incr i} {
            if {$i >= 1 && $i <= 2 && $j >= 1 && $j <= 2} { continue }
            ::Audit::hexa8 \
                $::Audit::nid($i,$j,$k) $::Audit::nid([expr {$i+1}],$j,$k) \
                $::Audit::nid([expr {$i+1}],[expr {$j+1}],$k) $::Audit::nid($i,[expr {$j+1}],$k) \
                $::Audit::nid($i,$j,[expr {$k+1}]) $::Audit::nid([expr {$i+1}],$j,[expr {$k+1}]) \
                $::Audit::nid([expr {$i+1}],[expr {$j+1}],[expr {$k+1}]) $::Audit::nid($i,[expr {$j+1}],[expr {$k+1}])
            incr hexaCount
        }
    }
}
catch {*clearmark elems 2}
*createmark elems 2 "by comp id" $solidComp
P "FIXTURE_HEXAS" [llength [hm_getmark elems 2]]
P "FIXTURE_NODES" [llength [array names ::Audit::nid]]
catch {*clearmark elems 2}

# ---------------------------------------------------------------- *findfaces
catch {*clearmark comps 1}
eval *createmark comps 1 [list $solidComp]
TRY "FINDFACES" {*findfaces components 1}

catch {*clearmark comps 1}
*createmark comps 1 all
set compIds [hm_getmark comps 1]
set compNames {}
foreach cid $compIds {
    lappend compNames "$cid:[hm_getvalue comps id=$cid dataname=name]"
}
P "COMPS_AFTER_FINDFACES" [join $compNames { }]

set facesCompId ""
catch {set facesCompId [hm_getvalue comps name=^faces dataname=id]}
P "FACES_COMP_^FACES" $facesCompId
if {$facesCompId eq ""} {
    catch {set facesCompId [hm_getvalue comps name=faces dataname=id]}
    P "FACES_COMP_plain_faces" $facesCompId
}

set faceElems {}
if {$facesCompId ne ""} {
    catch {*clearmark elems 1}
    *createmark elems 1 "by component id" $facesCompId
    set faceElems [hm_getmark elems 1]
    P "FACES_COUNT" [llength $faceElems]
    set configs {}
    foreach eid $faceElems {
        set c [hm_getvalue elems id=$eid dataname=config]
        if {[lsearch -exact $configs $c] < 0} { lappend configs $c }
    }
    P "FACES_CONFIGS" [join [lsort $configs] { }]
}

# ---------------------------------------------------------------- element type mapping (module exact sequence)
# The module runs inside interactive HM where a solver profile (e.g.
# OptiStruct) is loaded; hmbatch starts with template "none", so load the
# OptiStruct template first to mirror the module's runtime environment.
set executableDir [hm_info -appinfo EXECUTABLEDIR]
set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
P "TEMPLATE_EXISTS" [expr {[file isfile $templatePath] ? 1 : 0}]
TRY "TEMPLATE_SET" {*templatefileset $templatePath}
P "TEMPLATE_NOW" [string trim [hm_info templatetype]]
if {[llength $faceElems] > 0} {
    set sampleElem [lindex $faceElems 0]
    TRY "ELEMENTTYPE_BEFORE_TYPENAME" {hm_getvalue elems id=$sampleElem dataname=typename}
    catch {*clearmark elems 1}
    *createmark elems 1 "by component id" $facesCompId
    TRY "ELEMENTTYPE_2_1" {*elementtype 2 1}
    TRY "ELEMENTTYPE_104_1" {*elementtype 104 1}
    TRY "ELEMENTSETTYPES_1" {*elementsettypes 1}
    P "ELEMENTTYPE_AFTER_TYPENAME" [hm_getvalue elems id=$sampleElem dataname=typename]
    P "ELEMENTTYPE_AFTER_CONFIG" [hm_getvalue elems id=$sampleElem dataname=config]
    catch {*clearmark elems 1}
}

# ---------------------------------------------------------------- *feoutput_select (module exact call)
if {[llength $faceElems] > 0} {
    TRY "HM_INFO_SPECIFIEDPATH_TEMPLATES_DIR" {hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR}
    TRY "HM_INFO_SPECIFIEDPATH_RAW" {hm_info -appinfo SPECIFIEDPATH}
    set femPath [file join $outputDir "audit_auto_hole_rbe2_faces_${version}.fem"]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    *createmark elems 1 "by component id" $facesCompId
    *createmark nodes 1 "by component id" $facesCompId
    P "FE_OUTPUT_MARKED_NODES" [llength [hm_getmark nodes 1]]
    TRY "FE_OUTPUT_SELECT" {*feoutput_select $templatePath $femPath 1 0 0}
    if {[file isfile $femPath]} {
        set fd [open $femPath r]
        set content [read $fd]
        close $fd
        P "FEM_BYTES" [string length $content]
        set gridCount [regexp -all {^GRID} $content]
        set cquadCount [regexp -all {CQUAD4} $content]
        set ctriaCount [regexp -all {CTRIA3} $content]
        P "FEM_GRID_LINES" $gridCount
        P "FEM_CQUAD4" $cquadCount
        P "FEM_CTRIA3" $ctriaCount
    } else {
        P "FEM_FILE" "MISSING"
    }
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
}

# ---------------------------------------------------------------- *createnode + *rigidlink (RBE2)
# ring of 8 nodes around the hole at z=0
set wallNodes [list \
    $::Audit::nid(1,1,0) $::Audit::nid(1,2,0) $::Audit::nid(1,3,0) $::Audit::nid(2,1,0) \
    $::Audit::nid(2,3,0) $::Audit::nid(3,1,0) $::Audit::nid(3,2,0) $::Audit::nid(3,3,0)]
P "WALL_NODES" [join $wallNodes { }]
catch {*clearmark nodes 1}
eval *createmark nodes 1 $wallNodes
set actualMark [lsort -integer [hm_getmark nodes 1]]
P "MARK_NODES_SET" [expr {[join $actualMark ,] eq [join [lsort -integer $wallNodes] ,] ? 1 : 0}]
catch {*clearmark nodes 1}

set beforeNode [hm_latestentityid nodes]
TRY "CREATENODE" {*createnode 20 20 5 0 0 0}
set centerNode [hm_latestentityid nodes]
P "CENTER_NODE" $centerNode
P "CENTER_NODE_XYZ" [hm_getvalue nodes id=$centerNode dataname=coordinates]

catch {*clearmark nodes 2}
eval *createmark nodes 2 $wallNodes
set beforeElem [hm_latestentityid elems]
TRY "RIGIDLINK" {*rigidlink $centerNode 2 123456}
set rbe2Elem [hm_latestentityid elems]
P "RBE2_ELEM" $rbe2Elem
P "RBE2_IS_NEW" [expr {$rbe2Elem ne "" && $rbe2Elem != $beforeElem ? 1 : 0}]
if {$rbe2Elem ne "" && $rbe2Elem != $beforeElem} {
    P "RBE2_CONFIG" [hm_getvalue elems id=$rbe2Elem dataname=config]
    foreach dn {typename solverkeyword solvername cardimage nodes independentnode.id dependentnode.id dependentnodesmax dependentnodes} {
        TRY "RBE2_DATANAME $dn" {hm_getvalue elems id=$rbe2Elem dataname=$dn}
    }
    P "RBE2_INDEP_IS_CENTER" [expr {[hm_getvalue elems id=$rbe2Elem dataname=independentnode.id] == $centerNode ? 1 : 0}]
    set rbe2Nodes [hm_getvalue elems id=$rbe2Elem dataname=nodes]
    set depNodes {}
    foreach n $rbe2Nodes {
        if {$n != $centerNode} { lappend depNodes $n }
    }
    P "RBE2_DEP_SET_OK" [expr {[join [lsort -integer $depNodes] ,] eq [join [lsort -integer $wallNodes] ,] ? 1 : 0}]
    catch {*clearmark elems 1}
    *createmark elems 1 -1
    P "MARK_MINUS1_ELEMS" [join [hm_getmark elems 1] { }]
    catch {*clearmark elems 1}
}
catch {*clearmark nodes 2}

# ---------------------------------------------------------------- RBE3 (module exact call with arrays)
set count [llength $wallNodes]
set dofs {}; set weights {}
foreach n $wallNodes { lappend dofs 123456; lappend weights 1.0 }
catch {*clearmark nodes 2}
eval *createmark nodes 2 $wallNodes
TRY "CREATEARRAY" {eval *createarray $count $dofs}
TRY "CREATEDOUBLEARRAY" {eval *createdoublearray $count $weights}
set beforeElem [hm_latestentityid elems]
TRY "RBE3" {*rbe3 2 1 $count 1 $count $centerNode 123456 1.0}
set rbe3Elem [hm_latestentityid elems]
P "RBE3_ELEM" $rbe3Elem
P "RBE3_IS_NEW" [expr {$rbe3Elem ne "" && $rbe3Elem != $beforeElem ? 1 : 0}]
if {$rbe3Elem ne "" && $rbe3Elem != $beforeElem} {
    P "RBE3_CONFIG" [hm_getvalue elems id=$rbe3Elem dataname=config]
    P "RBE3_TYPENAME" [hm_getvalue elems id=$rbe3Elem dataname=typename]
    set rbe3Nodes [hm_getvalue elems id=$rbe3Elem dataname=nodes]
    P "RBE3_NODES" [join $rbe3Nodes { }]
    P "RBE3_REF_NODE" [hm_getvalue elems id=$rbe3Elem dataname=independentnode.id]
}
catch {*clearmark nodes 2}
catch {*clearmark elems 2}

# ---------------------------------------------------------------- component management commands
set probeComp ""
TRY "CREATEENTITY_COMPS_INCLUDEID" {*createentity comps includeid=0 name=AUDIT_E1}
set probeComp [hm_getvalue comps name=AUDIT_E1 dataname=id]
P "COMP_E1_ID" $probeComp
TRY "CREATEENTITY_COMPONENTS_INCLUDEID" {*createentity components includeid=0 name=AUDIT_E2}
TRY "COLLECTORCREATEONLY_COMPS" {*collectorcreateonly comps AUDIT_E3 "" 12}
TRY "COLLECTORCREATEONLY_COMPONENTS" {*collectorcreateonly components AUDIT_E4 "" 13}
TRY "CURRENTCOLLECTOR_COMPONENT" {*currentcollector component AUDIT_SOLID}
TRY "CURRENTCOLLECTOR_COMPONENTS" {*currentcollector components AUDIT_SOLID}
TRY "CURRENTCOLLECTOR_COMPS" {*currentcollector comps AUDIT_SOLID}
TRY "SETVALUE_COLOR" {*setvalue comps id=$solidComp color=5}
TRY "ENTITYINFO_BYNAME_FLAG" {hm_entityinfo id comps AUDIT_SOLID -byname}
TRY "ENTITYINFO_BYNAME_NOFLAG" {hm_entityinfo id comps AUDIT_SOLID}
TRY "ENTITYINFO_BYNAME_COMPONENTS" {hm_entityinfo id components AUDIT_SOLID -byname}
TRY "ENTITYINFO_BYNAME_COMPONENT" {hm_entityinfo id component AUDIT_SOLID -byname}
TRY "GETVALUE_BY_NAME" {hm_getvalue comps name=AUDIT_SOLID dataname=id}
TRY "CREATEMARK_BY_NAME" {*createmark comps 2 "by name" AUDIT_SOLID}
TRY "CREATEMARK_BY_NAME_ONLY" {*createmark comps 2 "by name only" AUDIT_SOLID}
TRY "CREATEMARK_ELEMS_BY_COMP_ID" {*createmark elems 2 "by comp id" $solidComp}
TRY "MARKS_SUPPRESS_ACTIVE" {*marksuppressactive comps 2 0}
TRY "MARKS_SUPPRESS_OUTPUT" {*marksuppressoutput comps 2 0}
TRY "DISPLAY_COLLECTORS_BY_MARK" {*displaycollectorsbymark comps 2 on 1 1}
TRY "DISPLAY_COLLECTORS_ALL_BY_MARK" {*displaycollectorsallbymark 2 on 1 1}
TRY "DISPLAY_COLLECTOR_COMPS" {*displaycollector comps on AUDIT_SOLID 1 1}
TRY "DISPLAY_COLLECTOR_COMPONENT" {*displaycollector component on AUDIT_SOLID 1 1}
TRY "DISPLAY_COLLECTOR_WITH_FILTER_COMPS" {*displaycollectorwithfilter comps on AUDIT_SOLID 1 1}
TRY "DISPLAY_COLLECTOR_WITH_FILTER_COMPONENT" {*displaycollectorwithfilter component on AUDIT_SOLID 1 1}
TRY "SETOPTION_BLOCK_REDRAW" {*setoption block_redraw=1}
TRY "SETOPTION_BLOCK_MESSAGES" {*setoption block_messages=1}
TRY "SETOPTION_UNBLOCK" {*setoption block_redraw=0}
TRY "HISTORY_START" {*startnotehistorystate "AUDIT PROBE"}
TRY "HISTORY_END" {*endnotehistorystate "AUDIT PROBE"}
TRY "HM_BLOCKBROWSERUPDATE" {hm_blockbrowserupdate 1}
TRY "HM_BLOCKBROWSERUPDATE_0" {hm_blockbrowserupdate 0}
TRY "HM_COMMANDFILESTATE_0" {hm_commandfilestate 0}
TRY "HM_COMMANDFILESTATE_1" {hm_commandfilestate 1}
TRY "HM_BLOCKREDRAW" {hm_blockredraw 1}
TRY "HM_BLOCKMESSAGES" {hm_blockmessages 1}
TRY "HM_BLOCKERRORMESSAGES" {hm_blockerrormessages 1}
TRY "HM_UNBLOCK" {hm_blockredraw 0}
TRY "HMBR_SIGNALS_BUFFER_STOP" {hmbr_signals buffer stop}
TRY "HMBR_SIGNALS_BUFFER_START" {hmbr_signals buffer start}
TRY "HWBROWSERMANAGER_FLUSH" {hwbrowsermanager view flush true}
TRY "HM_REDRAW" {hm_redraw}
TRY "HM_USERMESSAGE" {hm_usermessage "audit probe"}
TRY "HM_NODEVALUE" {hm_nodevalue $centerNode}
TRY "HM_NODELIST" {hm_nodelist [lindex $faceElems 0]}
TRY "HM_GETIDPOOLS" {hm_getidpools nodes name}
TRY "HM_GETINTERNALID_NOPOOL" {hm_getinternalid NOSUCHPOOL 5 -bypoolname}
TRY "HM_GETSOLVERID_BYID" {hm_getsolverid nodes $centerNode -byid}
TRY "HM_GETSOLVERID_NOFLAG" {hm_getsolverid nodes $centerNode}
TRY "HM_LATESTENTITYID_NODES" {hm_latestentityid nodes}
TRY "HM_GETMARK_COMP" {hm_getmark comps 2}
TRY "DELETEMARK" {*deletemark comps 2}
TRY "CLEARMARKALL_1" {*clearmarkall 1}
TRY "CLEARMARKALL_2" {*clearmarkall 2}

# ---------------------------------------------------------------- cleanup
foreach name {AUDIT_E1 AUDIT_E2 AUDIT_E3 AUDIT_E4 AUDIT_SOLID ^faces} {
    catch {*createmark comps 2 "by name only" $name}
    set ids [hm_getmark comps 2]
    if {[llength $ids] > 0} {
        catch {*deletemark comps 2}
        P "CLEANUP_DELETED $name" [join $ids { }]
    }
    catch {*clearmark comps 2}
}
catch {*clearmarkall 1}
catch {*clearmarkall 2}

P "STATUS" "DONE"
close $channel
exit 0
