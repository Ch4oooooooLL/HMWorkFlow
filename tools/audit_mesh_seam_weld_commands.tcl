# Audit probe for modules/mesh_seam_weld native HyperMesh commands (part 1).
#
# Verifies existence and functional behavior of the query/mark/quality/imprint/
# findedges/history commands used by the module, on the installed HyperMesh
# build.  Run headless with:
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_mesh_seam_weld_commands.tcl
#
# Results are written to runtime/audit_mesh_seam_weld_commands_<version>.log
# as KEY=VALUE lines (ASCII only; hmbatch has no stdout channel).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_mesh_seam_weld_commands_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

proc exists {name} {
    expr {[info commands $name] ne ""}
}

P "status" "STARTED"
P "version" $version
P "executable" [info nameofexecutable]

# --- 1. Command existence --------------------------------------------------
P "SECTION_1_STARTED" 1
foreach name {
    *imprint_nodelist *imprintnodelist *findedges *automesh *automesh_mc
    *storemeshtodatabase *rejectmesh *ameshclearsurface *surfacemode
    *linearsurfacebetweennodes *set_meshfaceparams *set_meshedgeparams
    *feoutput_select *feoutputwithdata *feinputwithdata2
    *createlistpanel *createlistbypathpanel *displaycollectorsallbymark
    *numbersmark *numbersclear *undohistorystate *startnotehistorystate
    *endnotehistorystate *movemark *renamecollector *createentity
    *collectorcreateonly *setvalue *currentcollector *translatemark
    *createvector *writefile *readfile *createstringarray *deletemark
    *createmark *clearmark *createlist *clearlist *createelement *createnode
    *interactiveremeshelems *defaultremeshelems *remeshelems
    *interactiveremeshsurf *defaultremeshsurf
    hm_getclosestnode hm_latestentityid hm_nodevalue hm_nodelist hm_createmark
    hm_getelementsqualityinfo hm_answernext hm_getlist hm_getmark hm_getvalue
    hm_info hm_redraw hm_viewfit
} {
    P "EXISTS $name" [expr {[info commands $name] ne ""}]
}

# --- 2. Fixture: planar target (z=0, x/y in {0,10,20,30}), vertical wall
P "SECTION_2_STARTED" 1
#        sharing the x=20 line, and a floating source path at z=10 ----------
namespace eval ::MSWA {}
proc ::MSWA::component {name color} {
    *collectorcreateonly components $name "" $color
    set id [hm_getvalue comps name=$name dataname=id]
    *currentcollector component $name
    return $id
}
proc ::MSWA::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc ::MSWA::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}

set compTarget [::MSWA::component MSWA_TARGET 11]
array set tn {}
foreach x {0 10 20 30} {
    foreach y {0 10 20 30} {
        set tn($x,$y) [::MSWA::node $x $y 0]
    }
}
set targetElems {}
foreach x0 {0 10 20} x1 {10 20 30} {
    foreach y0 {0 10 20} y1 {10 20 30} {
        lappend targetElems [::MSWA::quad [list \
            $tn($x0,$y0) $tn($x1,$y0) $tn($x1,$y1) $tn($x0,$y1)]]
    }
}
set compWall [::MSWA::component MSWA_WALL 22]
set wallBottom [list $tn(20,0) $tn(20,10) $tn(20,20) $tn(20,30)]
set wallElems {}
foreach y0 {0 10 20} y1 {10 20 30} {
    set wb0 [::MSWA::node 20 $y0 -10]
    set wb1 [::MSWA::node 20 $y1 -10]
    lappend wallElems [::MSWA::quad [list $tn(20,$y0) $tn(20,$y1) $wb1 $wb0]]
}
set compSource [::MSWA::component MSWA_SOURCE 33]
set sourceNodes {}
foreach xyz {{5 5 10} {25 5 10} {25 25 10} {5 25 10}} {
    lappend sourceNodes [::MSWA::node {*}$xyz]
}
catch {*clearmark nodes 1}
*createmark nodes 1 all
catch {*clearmark elems 1}
*createmark elems 1 all
P "FIXTURE_TOTAL_NODES" [llength [hm_getmark nodes 1]]
P "FIXTURE_TOTAL_ELEMS" [llength [hm_getmark elems 1]]
P "FIXTURE_SOURCE_NODES" [join $sourceNodes { }]
P "FIXTURE_TARGET_ELEMS" [join $targetElems { }]

# --- 3. Query function semantics -------------------------------------------
P "SECTION_3_STARTED" 1
set probeNode $tn(0,0)
if {[catch {set nv [hm_nodevalue $probeNode]} nvErr]} {
    P "NODEVALUE_ERROR" $nvErr
} else {
    P "NODEVALUE_RAW" $nv
    P "NODEVALUE_LEN" [llength $nv]
    P "NODEVALUE_INDEX0" [lindex $nv 0]
    P "NODEVALUE_LRANGE0_2" [lrange $nv 0 2]
}
if {[catch {set nl [hm_nodelist [lindex $targetElems 0]]} nlErr]} {
    P "NODELIST_1ARG_ERROR" $nlErr
} else {
    P "NODELIST_1ARG" $nl
}
if {[catch {set closest [hm_getclosestnode 15.0 15.0 0.0]} cErr]} {
    P "CLOSEST_3ARG_ERROR" $cErr
} else {
    P "CLOSEST_3ARG" $closest
}
# 5-arg exclusion semantics: mark 1 holds the four source nodes (z=10).
# Query point is exactly source node 0; without exclusion it would return it.
catch {*clearmark nodes 1}
eval *createmark nodes 1 $sourceNodes
foreach {tag args} {
    "CLOSEST_MARK1_SRC"  {15.0 15.0 10.0 1 1}
    "CLOSEST_MARK1_SRC_F2" {15.0 15.0 10.0 1 2}
} {
    set label $tag
    if {[catch {set c [eval hm_getclosestnode $args]} cErr]} {
        P "${label}_ERROR" $cErr
    } else {
        P "${label}" $c
        P "${label}_IS_SOURCE" [expr {[lsearch -exact $sourceNodes $c] >= 0}]
    }
}
catch {*clearmark nodes 1}
catch {*clearmark nodes 2}
# mark 2 = wall nodes; mark 1 = empty.  Query near a wall node.
eval *createmark nodes 2 $wallBottom
if {[catch {set c [hm_getclosestnode 20.0 10.0 0.0 2 1]} cErr]} {
    P "CLOSEST_MARK2_WALL_ERROR" $cErr
} else {
    P "CLOSEST_MARK2_WALL" $c
    P "CLOSEST_MARK2_WALL_IS_WALL" [expr {[lsearch -exact $wallBottom $c] >= 0}]
}
catch {*clearmark nodes 1}
catch {*clearmark nodes 2}

foreach {type label} {nodes NODES elems ELEMS comps COMPS} {
    if {[catch {set id [hm_latestentityid $type]} idErr]} {
        P "LATEST_${label}_ERROR" $idErr
    } else {
        P "LATEST_${label}" $id
    }
}

# hm_createmark with a node-id selector (module's adjacentElementsForNodes path)
catch {*clearmark elems 2}
if {[catch {eval hm_createmark elems 2 [list "by node id"] [list $tn(10,10)]} mErr]} {
    P "HM_CREATEMARK_ERROR" $mErr
} else {
    set m {}
    catch {set m [hm_getmark elems 2]}
    P "HM_CREATEMARK_ELEMS_BY_NODEID" [join $m { }]
}
catch {*clearmark elems 2}

# --- 4. hm_getclosestnode semantics (dedicated small fixture) ---------------
P "SECTION_4_STARTED" 1
# Nodes: a=(10,0,0) b=(12,0,0) c=(20,0,0).  Query (11,0,0): closest = b (12).
# With mark 1 = {a c}: if the mark is an EXCLUSION set the result is b; if it
# is a SEARCH set the result is a or c; with no mark args the result is b.
namespace eval ::MSWB {}
proc ::MSWB::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
set na [::MSWB::node 10 0 0]
set nb [::MSWB::node 12 0 0]
set nc [::MSWB::node 20 0 0]
catch {*clearmark nodes 1}
catch {*clearmark nodes 2}
foreach {tag args} {
    "CLS_NOMARK"    {11.0 0.0 0.0}
    "CLS_F0"        {11.0 0.0 0.0 1 0}
    "CLS_F1"        {11.0 0.0 0.0 1 1}
    "CLS_F2"        {11.0 0.0 0.0 1 2}
    "CLS_MARK2_F1"  {11.0 0.0 0.0 2 1}
} {
    eval *createmark nodes 1 $na $nc
    eval *createmark nodes 2 $na $nb
    if {[catch {set c [eval hm_getclosestnode $args]} cErr]} {
        P "${tag}_ERROR" $cErr
    } else {
        set cname UNKNOWN
        if {$c == $na} { set cname "a(10)" }
        if {$c == $nb} { set cname "b(12)" }
        if {$c == $nc} { set cname "c(20)" }
        P "${tag}" "$c ($cname)"
    }
    catch {*clearmark nodes 1}
    catch {*clearmark nodes 2}
}

# --- 5. Imprint nodelist: both spellings, both target entity types ---------
P "SECTION_5_STARTED" 1
# The fixture is rebuilt for every case: a successful imprint remeshes the
# target patch (retiring the element IDs), which would otherwise poison the
# next case.
set options "remain 3 to_dest_component 0 remesh_layers 2 remesh_mode 2 angle 30.000000 create_joint_elems 0 close_node_list 0"
proc ::MSWA::buildFixture {} {
    variable tn
    variable targetElems
    variable wallElems
    variable sourceNodes
    array unset tn
    set targetElems {}
    set wallElems {}
    set sourceNodes {}
    array set tn {}
    foreach x {0 10 20 30} {
        foreach y {0 10 20 30} {
            set tn($x,$y) [::MSWA::node $x $y 0]
        }
    }
    foreach x0 {0 10 20} x1 {10 20 30} {
        foreach y0 {0 10 20} y1 {10 20 30} {
            lappend targetElems [::MSWA::quad [list \
                $tn($x0,$y0) $tn($x1,$y0) $tn($x1,$y1) $tn($x0,$y1)]]
        }
    }
    foreach y0 {0 10 20} y1 {10 20 30} {
        set wb0 [::MSWA::node 20 $y0 -10]
        set wb1 [::MSWA::node 20 $y1 -10]
        lappend wallElems [::MSWA::quad [list $tn(20,$y0) $tn(20,$y1) $wb1 $wb0]]
    }
    foreach xyz {{5 5 10} {25 5 10} {25 25 10} {5 25 10}} {
        lappend sourceNodes [::MSWA::node {*}$xyz]
    }
    return [list [lsort -integer $targetElems] [lsort -integer $wallElems] [lsort -integer $sourceNodes]]
}
proc ::MSWA::runImprintCase {tag spelling entityType options} {
    if {[catch {::MSWA::buildFixture} bErr]} {
        P "${tag}_FIXTURE_ERROR" $bErr
        return
    }
    variable targetElems
    variable sourceNodes
    set preMax 0
    catch {set preMax [hm_latestentityid nodes]}
    catch {*clearlist nodes 1}
    catch {*clearlist nodes 2}
    catch {*clearmark elems 2}
    catch {*clearmark elements 2}
    catch {*clearmark comps 2}
    catch {*clearmark components 2}
    if {[catch {eval *createlist nodes 1 $sourceNodes} lErr]} {
        P "${tag}_PREP_ERROR" $lErr
        return
    }
    if {[catch {eval *createmark $entityType 2 $targetElems} mErr]} {
        P "${tag}_PREP_MARK_ERROR" $mErr
        return
    }
    if {[catch {$spelling 1 $entityType 2 $options} iErr]} {
        P "${tag}_ERROR" $iErr
        return
    }
    P "${tag}_OK" 1
    set list2 {}
    catch {set list2 [hm_getlist nodes 2]}
    P "${tag}_LIST2_COUNT" [llength $list2]
    P "${tag}_LIST2" [join $list2 { }]
    set newCount 0
    foreach nid $list2 {
        if {[string is integer -strict $nid] && $nid > $preMax} {
            incr newCount
        }
    }
    P "${tag}_LIST2_NEW_NODES" $newCount
    set retired 0
    foreach eid $targetElems {
        if {[catch {set en [hm_getvalue elems id=$eid dataname=nodes]}]} {
            incr retired
        }
    }
    P "${tag}_RETIRED_TARGET_ELEMS" $retired
}
foreach spelling {*imprint_nodelist *imprintnodelist} {
    foreach entityType {elements elems} {
        ::MSWA::runImprintCase "IMPRINT $spelling $entityType" $spelling $entityType $options
    }
}
# Component-target variant
proc ::MSWA::runImprintCompCase {tag spelling entityType options compId} {
    if {[catch {::MSWA::buildFixture} bErr]} {
        P "${tag}_FIXTURE_ERROR" $bErr
        return
    }
    variable sourceNodes
    catch {*clearlist nodes 1}
    catch {*clearlist nodes 2}
    catch {*clearmark comps 2}
    catch {*clearmark components 2}
    if {[catch {eval *createlist nodes 1 $sourceNodes} lErr]} {
        P "${tag}_PREP_ERROR" $lErr
        return
    }
    if {[catch {eval *createmark $entityType 2 $compId} mErr]} {
        P "${tag}_PREP_MARK_ERROR" $mErr
        return
    }
    if {[catch {$spelling 1 $entityType 2 $options} iErr]} {
        P "${tag}_ERROR" $iErr
        return
    }
    P "${tag}_OK" 1
    set list2 {}
    catch {set list2 [hm_getlist nodes 2]}
    P "${tag}_LIST2_COUNT" [llength $list2]
    P "${tag}_LIST2" [join $list2 { }]
}
foreach spelling {*imprint_nodelist *imprintnodelist} {
    foreach entityType {components comps} {
        ::MSWA::runImprintCompCase "IMPRINT $spelling $entityType" $spelling $entityType $options $compTarget
    }
}
catch {*clearlist nodes 1}
catch {*clearlist nodes 2}

# --- 6. Find edges + collector rename/move ---------------------------------
P "SECTION_6_STARTED" 1
catch {*clearmark comps 1}
eval *createmark comps 1 $compWall
if {[catch {*findedges comps 1 0} fErr]} {
    P "FINDEDGES_ERROR" $fErr
} else {
    P "FINDEDGES_OK" 1
    set edgeCompId ""
    catch {set edgeCompId [hm_getvalue comps name=^edges dataname=id]}
    P "FINDEDGES_EDGES_COMP_ID" $edgeCompId
    catch {*clearmark elems 1}
    if {[catch {*createmark elems 1 "by comp" $edgeCompId} mErr]} {
        P "FINDEDGES_MARK_ERROR" $mErr
    } else {
        set edgeElems {}
        catch {set edgeElems [hm_getmark elems 1]}
        P "FINDEDGES_EDGE_ELEM_COUNT" [llength $edgeElems]
        set config0 ""
        if {[llength $edgeElems] > 0} {
            catch {set config0 [hm_getvalue elems id=[lindex $edgeElems 0] dataname=config]}
        }
        P "FINDEDGES_EDGE_ELEM_CONFIG" $config0
    }
    # rename the ^edges component, then move elements with *movemark
    if {$edgeCompId ne "" && [catch {*renamecollector comps ^edges MSWA_TMP_EDGES} rErr]} {
        P "RENAMECOLLECTOR_ERROR" $rErr
    } else {
        P "RENAMECOLLECTOR_OK" 1
        if {[catch {*movemark elems 1 $compTarget} mvErr]} {
            P "MOVEMARK_ERROR" $mvErr
        } else {
            P "MOVEMARK_OK" 1
            catch {*clearmark elems 1}
            *createmark elems 1 "by comp" $compTarget
            P "MOVEMARK_TARGET_ELEMS_AFTER" [llength [hm_getmark elems 1]]
        }
        if {[catch {*renamecollector comps MSWA_TMP_EDGES ^edges} r2Err]} {
            P "RENAMECOLLECTOR_RESTORE_ERROR" $r2Err
        } else {
            P "RENAMECOLLECTOR_RESTORE_OK" 1
        }
    }
}
catch {*clearmark comps 1}
catch {*clearmark elems 1}

# --- 7. Undo history transaction -------------------------------------------
P "SECTION_7_STARTED" 1
if {[catch {*startnotehistorystate {MSWA audit transaction}} hErr]} {
    P "HISTORY_START_ERROR" $hErr
} else {
    P "HISTORY_START_OK" 1
    set beforeCount 0
    catch {
        *createmark nodes 1 all
        set beforeCount [llength [hm_getmark nodes 1]]
    }
    ::MSWA::node 99 99 99
    set afterCount 0
    catch {
        *createmark nodes 1 all
        set afterCount [llength [hm_getmark nodes 1]]
    }
    P "HISTORY_NODES_BEFORE_AFTER" "$beforeCount/$afterCount"
    if {[catch {*endnotehistorystate {MSWA audit transaction}} eErr]} {
        P "HISTORY_END_ERROR" $eErr
    } else {
        P "HISTORY_END_OK" 1
        if {[catch {*undohistorystate 1} uErr]} {
            P "HISTORY_UNDO_ERROR" $uErr
        } else {
            P "HISTORY_UNDO_OK" 1
            set finalCount 0
            catch {
                *createmark nodes 1 all
                set finalCount [llength [hm_getmark nodes 1]]
            }
            P "HISTORY_NODES_AFTER_UNDO" $finalCount
        }
    }
}

# --- 8. Numbers / display / misc -------------------------------------------
P "SECTION_8_STARTED" 1
catch {*clearmark nodes 1}
eval *createmark nodes 1 $sourceNodes
if {[catch {*numbersmark nodes 1 1} nErr]} {
    P "NUMBERSMARK_ERROR" $nErr
} else {
    P "NUMBERSMARK_OK" 1
}
if {[catch {*numbersclear} nErr]} {
    P "NUMBERS_CLEAR_ERROR" $nErr
} else {
    P "NUMBERS_CLEAR_OK" 1
}
catch {*clearmark comps 1}
eval *createmark comps 1 $compTarget $compWall
if {[catch {*displaycollectorsallbymark 1 off 1 1} dErr]} {
    P "DISPLAY_OFF_ERROR" $dErr
} else {
    P "DISPLAY_OFF_OK" 1
}
if {[catch {*displaycollectorsallbymark 1 on 1 1} dErr]} {
    P "DISPLAY_ON_ERROR" $dErr
} else {
    P "DISPLAY_ON_OK" 1
}
catch {*clearmark comps 1}
catch {*clearmark nodes 1}

# --- 9. createentity / collectorcreateonly / setvalue -----------------------
P "SECTION_9_STARTED" 1
if {[catch {*createentity comps includeid=0 name=MSWA_CREATED} ceErr]} {
    P "CREATEENTITY_ERROR" $ceErr
} else {
    P "CREATEENTITY_OK" 1
    set createdId ""
    catch {set createdId [hm_getvalue comps name=MSWA_CREATED dataname=id]}
    P "CREATEENTITY_ID" $createdId
    if {$createdId ne "" && [catch {*setvalue comps id=$createdId color=7} svErr]} {
        P "SETVALUE_COLOR_ERROR" $svErr
    } else {
        P "SETVALUE_COLOR_OK" 1
    }
}
if {[catch {*collectorcreateonly comps MSWA_CCONLY "" 5} ccErr]} {
    P "COLLECTORCREATEONLY_ERROR" $ccErr
} else {
    P "COLLECTORCREATEONLY_OK" 1
}
if {[catch {*currentcollector component MSWA_CCONLY} curErr]} {
    P "CURRENTCOLLECTOR_ERROR" $curErr
} else {
    P "CURRENTCOLLECTOR_OK" 1
}

# --- 10. createmark selector coverage used by the module --------------------
P "SECTION_10_STARTED" 1
foreach {tag selector} {
    "SEL_ALL"            {all}
    "SEL_DISPLAYED"      {displayed}
    "SEL_BY_ID_ONLY"     {by id only 1}
    "SEL_BY_NAME_ONLY"   {by name only MSWA_TARGET}
    "SEL_LAST_NODE"      {-1}
} {
    set entity comps
    set markId 2
    if {$tag eq "SEL_LAST_NODE"} {
        set entity nodes
    }
    catch {*clearmark $entity 2}
    if {[catch {eval *createmark $entity 2 $selector} sErr]} {
        P "MARK ${tag}_ERROR" $sErr
    } else {
        set m {}
        catch {set m [hm_getmark $entity 2]}
        P "MARK ${tag}_COUNT" [llength $m]
    }
    catch {*clearmark $entity 2}
}

# --- 11. Native quality check (LAST: without loaded criteria the quality
P "SECTION_11_STARTED" 1
#         check aborts the batch session, so criteria are loaded first) ------
set executableDir ""
catch {set executableDir [hm_info -appinfo EXECUTABLEDIR]}
set criteriaPath ""
foreach candidate [list \
    [file join $executableDir .. .. .. hm batchmesh general_8mm.criteria] \
    [file join $executableDir .. .. batchmesh general_8mm.criteria]] {
    set normalized [file normalize $candidate]
    if {[file isfile $normalized]} { set criteriaPath $normalized; break }
}
P "CRITERIA_RESOLVED" $criteriaPath
if {$criteriaPath ne ""} {
    if {[catch {*readqualitycriteria [file nativename $criteriaPath]} rcErr]} {
        P "READQUALITYCRITERIA_ERROR" $rcErr
    } else {
        P "READQUALITYCRITERIA_OK" 1
    }
}
# A deliberately collapsed quad (four collinear nodes) must fail quality.
# Rebuild the target patch first: the imprint tests remeshed/retired it.
::MSWA::buildFixture
set targetElems $::MSWA::targetElems
set badNodeA [::MSWA::node 40 0 0]
set badNodeB [::MSWA::node 50 0 0]
set badNodeC [::MSWA::node 60 0 0]
set badNodeD [::MSWA::node 70 0 0]
set badElem [::MSWA::quad [list $badNodeA $badNodeB $badNodeC $badNodeD]]
catch {*clearmark elems 1}
eval *createmark elems 1 [concat $targetElems [list $badElem]]
if {[catch {set q1 [hm_getelementsqualityinfo 1]} qErr]} {
    P "QINFO_1ARG_ERROR" $qErr
} else {
    P "QINFO_1ARG_RAW" $q1
}
catch {*clearmark elems 2}
if {[catch {set q3 [hm_getelementsqualityinfo 1 1 2]} qErr]} {
    P "QINFO_3ARG_ERROR" $qErr
} else {
    P "QINFO_3ARG_RAW" $q3
    set failed {}
    catch {set failed [hm_getmark elems 2]}
    P "QINFO_3ARG_MARK2" [join $failed { }]
    P "QINFO_3ARG_MARK2_HAS_BAD" [expr {[lsearch -exact $failed $badElem] >= 0}]
}
catch {*clearmark elems 1}
catch {*clearmark elems 2}

P "status" "DONE"
close $channel
exit 0
