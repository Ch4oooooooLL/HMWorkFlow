# ============================================================================
# Audit probe for modules/rbe2_bolt_connector.tcl HyperMesh native commands.
#
# Verifies on the real machine:
#   A. existence of every *command / hm_ command the module calls (plus
#      candidate better alternatives)
#   B. FEM import path used by the module (*feinputwithdata2 + string array,
#      reader spelling "#optistruct/optistruct" vs "#optistruct\optistruct",
#      ID preservation)
#   C. RBE2 data access (hm_getvalue dataname=config/typename/cardimage/
#      independentnode.id/nodes/collector.id/...)
#   D. mark selectors used for RBE2 / 1D candidate filtering
#   E. material/property/beam-section creation chain
#   F. *attributeupdateentity beam-section link + *syncpropertybeamsectionvalues
#   G. *createvector + *barelementcreatewithoffsets (full and short syntax)
#   H. entity-ref *setvalue (node1={nodes id}, materialid={mats id},
#      propertyid={props id}), *replacenodes, *createpoint, *createnode, *rigid
#   I. *propertyupdate / *marksuppressactive / display / browser / option cmds
#   J. batch alternatives (*createelement via list+mark, *nodemodify, ...)
#
# Run headless (no stdout channel under hmbatch):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand \
#       -nouserprofiledialog -tcl tools/audit_rbe2_bolt_connector.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand \
#       -nouserprofiledialog -tcl tools/audit_rbe2_bolt_connector.tcl
# Results: runtime/audit_rbe2_bolt_connector_<version>.log  (KEY=VALUE, ASCII)
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_rbe2_bolt_connector_${version}.log"]
set ch [open $reportPath w]
fconfigure $ch -translation lf

proc P {key value} {
    variable ch
    regsub -all {[\r\n]} $value { } value
    puts $ch "${key}=${value}"
    flush $ch
}

proc TRY {prefix script} {
    if {[catch {uplevel 1 $script} result options]} {
        P "${prefix}_RC" 1
        P "${prefix}_ERR" $result
    } else {
        P "${prefix}_RC" 0
        P "${prefix}_VAL" [string trim $result]
    }
}

proc EXISTS {name} {
    set pat [string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} $name]
    P "EXISTS_$name" [expr {[llength [info commands $pat]] > 0}]
}

proc keySan {s} {
    regsub -all {[" ]} $s {_} s
    return $s
}

proc markIds {etype markId} {
    catch {*clearmark $etype $markId}
    return [hm_getmark $etype $markId]
}

P "VERSION" $version
P "TEMPLATE_BEFORE" [string trim [hm_info templatetype]]

# ------------------------- A. command existence ----------------------------
set usedCommands {
    *clearmark *createmark *setvalue *createentity *setoption *currentcollector
    *propertyupdate *collectorcreateonly *barelementcreatewithoffsets
    *feinputwithdata2 *deletemark *syncpropertybeamsectionvalues *marktousermark
    *endnotehistorystate *displaycollectorwithfilter *displaycollector
    *createvector *startnotehistorystate *replacenodes *marksuppressoutput
    *marksuppressactive *displaycollectorsbymark *displaycollectorsallbymark
    *createstringarray *createpoint *createnode *createdoublearray
    *beamsectionsetdatastandard *beamsectionsetdataroot
    *beamsectioncreatestandardsolver *attributeupdateentity
    hm_getvalue hm_getmark hm_latestentityid hm_usermessage hm_redraw
    hm_commandfilestate hm_blockredraw hm_blockmessages hm_blockerrormessages
    hm_entityinfo hm_callpanel hm_pushpanel hm_setpanelproc hm_markclear
    hm_blockbrowserupdate hm_getcurrentcollector hm_getoption hm_info
}
foreach name $usedCommands { EXISTS $name }

# candidate better alternatives
set alternativeCommands {
    *createelement *createlist *rigid *equivalence *elementcreate *barcreate
    *nodecreate *createnodes *nodemodify *nodesmerge *feinput *feinputwithdata
    *elementtype *setdefaults *propertycreate *movemark *renamecollector
    *collectorcreate *duplicatemark *appendmark *isolateentitybymark
    *showentity *displaycollectorall *elementrecreate *springos
    hm_getentityvalue hm_attributeidfromname hm_attributelist hm_entitymaxid
    hm_entityincollector hm_nodelist hm_getlist hm_createmark
}
foreach name $alternativeCommands { EXISTS $name }

# ------------------------- B. template + fixture FEM import ----------------
set executableDir [hm_info -appinfo EXECUTABLEDIR]
set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
P "TEMPLATE_PATH" $templatePath
P "TEMPLATE_EXISTS" [file isfile $templatePath]
catch {*templatefileset $templatePath} tErr
P "TEMPLATE_NOW" [string trim [hm_info templatetype]]

# fixture A: reader with FORWARD slash, module-style 2-option string array
set femA [file join $outputDir audit_rbe2_fixture_a.fem]
set fa [open $femA w]
puts $fa {BEGIN BULK}
puts $fa {$HMNAME MAT 5001 "AUDIT_STEEL"}
puts $fa {MAT1,5001,210000.0,,0.3,7.85E-9}
puts $fa {$HMNAME PROP 4001 "AUDIT_PBAR"}
puts $fa {PBAR,4001,5001,78.5,,490.6,490.6,,981.7}
puts $fa {$HMNAME COMP 2001 "AUDIT_RBE2_COMP"}
puts $fa {$HMNAME COMP 3001 "AUDIT_BEAM_COMP"}
puts $fa {GRID,1001,,0.0,0.0,0.0}
puts $fa {GRID,1002,,10.0,0.0,0.0}
puts $fa {GRID,1003,,10.0,10.0,0.0}
puts $fa {GRID,1004,,0.0,10.0,0.0}
puts $fa {GRID,1011,,0.0,0.0,20.0}
puts $fa {GRID,1012,,10.0,0.0,20.0}
puts $fa {GRID,1013,,10.0,10.0,20.0}
puts $fa {GRID,1014,,0.0,10.0,20.0}
puts $fa {RBE2,2001,1001,123456,1002,1003,1004}
puts $fa {RBE2,2002,1011,123456,1012,1013,1014}
puts $fa {CBEAM,3001,4001,1001,1011,0.0,1.0,0.0}
puts $fa {ENDDATA}
puts $fa {}
close $fa

# fixture B: reader with BACK slash, diag-style 10-option string array
set femB [file join $outputDir audit_rbe2_fixture_b.fem]
set fb [open $femB w]
puts $fb {BEGIN BULK}
puts $fb {GRID,1101,,0.0,0.0,40.0}
puts $fb {GRID,1102,,10.0,0.0,40.0}
puts $fb {GRID,1103,,10.0,10.0,40.0}
puts $fb {GRID,1104,,0.0,10.0,40.0}
puts $fb {GRID,1111,,0.0,0.0,60.0}
puts $fb {GRID,1112,,10.0,0.0,60.0}
puts $fb {GRID,1113,,10.0,10.0,60.0}
puts $fb {GRID,1114,,0.0,10.0,60.0}
puts $fb {RBE2,2101,1101,123456,1102,1103,1104}
puts $fb {RBE2,2102,1111,123456,1112,1113,1114}
puts $fb {CBEAM,3101,0,1101,1111,0.0,1.0,0.0}
puts $fb {ENDDATA}
puts $fb {}
close $fb

*feinputpreserveincludefiles
catch {*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "} saErr
P "STRINGARRAY2_ERR" $saErr
TRY IMPORT_A [list *feinputwithdata2 "#optistruct/optistruct" $femA 0 0 0 0 0 1 2 1 0]

# fixture B reader with backslash (diag_c01 proven spelling)
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
TRY IMPORT_B [list *feinputwithdata2 "#optistruct\\optistruct" $femB 0 0 0 0 0 1 10 1 0]

P "NODES_TOTAL" [llength [markIds nodes 1]]
P "ELEMS_TOTAL" [llength [markIds elems 1]]
P "COMPS_TOTAL" [llength [markIds comps 1]]
P "MATS_TOTAL" [llength [markIds mats 1]]
P "PROPS_TOTAL" [llength [markIds props 1]]

# ID preservation checks (the module relies on explicit IDs surviving import)
foreach {etype id} {nodes 1001 nodes 1011 nodes 1101 elems 2001 elems 2002 elems 2101 elems 3001 elems 3101 mats 5001 props 4001 comps 2001 comps 3001} {
    TRY "IDCHECK_${etype}_${id}" [list hm_getvalue $etype id=$id dataname=id]
}

# ------------------------- C. RBE2 data access -----------------------------
foreach dn {config typename cardimage solverkeyword independentnode.id nodes collector.id property.id name} {
    TRY "RBE2_2001_$dn" [list hm_getvalue elems id=2001 dataname=$dn]
}
foreach dn {node1.id node2.id} {
    TRY "BEAM_3001_$dn" [list hm_getvalue elems id=3001 dataname=$dn]
}
foreach dn {x y z coordinates id} {
    TRY "NODE_1001_$dn" [list hm_getvalue nodes id=1001 dataname=$dn]
}
# property.id readback on the imported CBEAM with PBAR 4001
TRY "BEAM_3001_property.id" [list hm_getvalue elems id=3001 dataname=property.id]

# ------------------------- D. mark selectors -------------------------------
foreach selector [list {"by config" 55} {"by element config" 55} {"by elem config" 55} \
                      {"by configuration" 55} {"by card image" RBE2} {"by cardimage" RBE2} \
                      {"by type" RBE2} {"by dimension" 1} {"by element dimension" 1} \
                      {"by elem dimension" 1}] {
    catch {*clearmark elems 1}
    set sk [keySan [join $selector _]]
    set rc [catch {eval *createmark elems 1 $selector} selErr]
    P "MARK_elems_1_${sk}_RC" $rc
    if {!$rc} { P "MARK_elems_1_${sk}_IDS" [lsort -integer [hm_getmark elems 1]] }
}
# numeric id mark and by-id-only
catch {*clearmark elems 1}
TRY MARK_elems_ids [list *createmark elems 1 2001 2002]
P "MARK_elems_ids_GOT" [lsort -integer [hm_getmark elems 1]]
catch {*clearmark elems 1}
TRY MARK_elems_byidonly [list *createmark elems 1 "by id only" 2001 3001]
P "MARK_elems_byidonly_GOT" [lsort -integer [hm_getmark elems 1]]
# comp selectors
catch {*clearmark comps 1}
TRY MARK_comps_bynameonly [list *createmark comps 1 "by name only" AUDIT_BEAM_COMP]
P "MARK_comps_bynameonly_GOT" [hm_getmark comps 1]
catch {*clearmark comps 1}
TRY MARK_comps_byname [list *createmark comps 1 "by name" AUDIT_BEAM_COMP]
P "MARK_comps_byname_GOT" [hm_getmark comps 1]
catch {*clearmark elems 1}
TRY MARK_elems_bycompid [list *createmark elems 1 "by comp id" 2001]
P "MARK_elems_bycompid_GOT" [lsort -integer [hm_getmark elems 1]]
# props/mats all marks (used by allComponentIds pattern)
catch {*clearmark comps 1}
TRY MARK_comps_all [list *createmark comps 1 all]
P "MARK_comps_all_GOT" [llength [hm_getmark comps 1]]
# beamsects mark + delete path (used by allBeamSectionIds)
catch {*clearmark beamsects 1}
TRY MARK_beamsects_all [list *createmark beamsects 1 all]
P "MARK_beamsects_all_GOT" [llength [hm_getmark beamsects 1]]
# single-id prop mark (linkBeamSectionToProperty)
TRY MARK_props_single [list *createmark props 1 4001]
P "MARK_props_single_GOT" [hm_getmark props 1]

# ------------------------- E. entity creation chain ------------------------
# component creation (module path: *createentity comps -> *collectorcreateonly)
TRY CREATE_COMP [list *createentity comps includeid=0 name=AUDIT_COMP_NEW]
TRY GET_COMP_ID [list hm_getvalue comps name=AUDIT_COMP_NEW dataname=id]
set newCompId ""
catch {set newCompId [hm_getvalue comps name=AUDIT_COMP_NEW dataname=id]}
TRY CREATE_COMP_FALLBACK [list *collectorcreateonly comps AUDIT_COMP_NEW2 "" 3]
TRY GET_COMP_ID2 [list hm_getvalue comps name=AUDIT_COMP_NEW2 dataname=id]
TRY SETVALUE_COMP_COLOR [list *setvalue comps id=$newCompId color=5]
TRY SETVALUE_COMP_NAME [list *setvalue comps id=$newCompId name=AUDIT_COMP_NEW]
# material creation + card fields
TRY CREATE_MAT [list *createentity mats cardimage=MAT1 includeid=0 name=audit_steel]
set matId ""
catch {set matId [hm_getvalue mats name=audit_steel dataname=id]}
P "MAT_ID" $matId
TRY SETVALUE_MAT_CARDIMAGE [list *setvalue mats id=$matId cardimage=MAT1]
foreach fld {E Nu Rho 1 3 4} {
    set val 210000.0
    if {$fld eq "Nu" || $fld eq "3"} {set val 0.30}
    if {$fld eq "Rho" || $fld eq "4"} {set val 7.85e-9}
    TRY "SETVALUE_MAT_$fld" [list *setvalue mats id=$matId "$fld=$val"]
}
# property creation + fields
TRY CREATE_PROP_PBEAM [list *createentity props cardimage=PBEAM includeid=0 name=AUDIT_PBEAM]
set propId ""
catch {set propId [hm_getvalue props name=AUDIT_PBEAM dataname=id]}
P "PROP_ID" $propId
TRY SETVALUE_PROP_CARDIMAGE [list *setvalue props id=$propId cardimage=PBEAM]
TRY SETVALUE_PROP_MATREF_ENTITY [list *setvalue props id=$propId STATUS=1 "materialid={mats $matId}"]
TRY SETVALUE_PROP_MATREF_ID [list *setvalue props id=$propId STATUS=1 "materialid=$matId"]
foreach fld {A A(A) Area I1 I1(A) I1A J J(A) JA K1 K1(A) NSM NSM(A)} {
    set v 100.0
    if {[string match -nocase "J*" $fld]} {set v 200.0}
    if {[string match -nocase "K1*" $fld]} {set v 1.0}
    TRY "SETVALUE_PROP_$fld" [list *setvalue props id=$propId STATUS=1 "$fld=$v"]
}
TRY PROP_MAT_READBACK [list hm_getvalue props id=$propId dataname=materialid]

# ------------------------- F. beam section chain ---------------------------
TRY SECTION_CREATE [list *beamsectioncreatestandardsolver 11 0 HMCirc 0]
TRY SECTION_LATEST [list hm_latestentityid beamsects]
set sectId ""
catch {set sectId [hm_latestentityid beamsects]}
P "SECTION_ID" $sectId
if {$sectId ne "" && $sectId != 0} {
    TRY SECTION_SETNAME [list *setvalue beamsects id=$sectId name=AUDIT_CIRC]
    foreach dn {name id setid collector.id collectorid collector} {
        TRY "SECTION_$dn" [list hm_getvalue beamsects id=$sectId dataname=$dn]
    }
    set collId ""
    foreach dn {setid collector.id collectorid collector} {
        catch {set collId [hm_getvalue beamsects id=$sectId dataname=$dn]}
        if {[string is integer -strict $collId] && $collId > 0} {break}
        set collId ""
    }
    P "SECTION_COLLECTOR_ID" $collId
    set radius 5.0
    TRY SECTION_DATAROOT [list *beamsectionsetdataroot $sectId $collId 0 2 7 1 0 1.0 1.0 0 0 0 0]
    TRY SECTION_DOUBLEARRAY [list *createdoublearray 3 $radius [expr {$radius/1000.0}] [expr {$radius*1000.0}]]
    TRY SECTION_DATASET [list *beamsectionsetdatastandard 1 3 $sectId 11 0 HMCirc]
}
# attribute link: 3179 = PBAR section attr, 3186 = PBEAM section attr (per module)
TRY ATTR_LINK_PBAR [list *attributeupdateentity properties 4001 3179 1 2 0 beamsects $sectId]
TRY ATTR_LINK_PBEAM [list *attributeupdateentity properties $propId 3186 1 2 0 beamsects $sectId]
# attribute list dump to validate hardcoded ids (look for section entries)
if {[llength [info commands hm_attributelist]] > 0} {
    set attrList ""
    catch {set attrList [hm_attributelist properties]}
    P "ATTRLIST_COUNT" [llength $attrList]
    set sectionAttrs {}
    foreach a $attrList {
        if {[string match -nocase "*section*" $a]} {lappend sectionAttrs $a}
    }
    P "ATTRLIST_SECTION_ENTRIES" [join $sectionAttrs { }]
}
# sync property beam section values
catch {*clearmark props 1}
TRY SYNC_MARK [list *createmark props 1 $propId]
TRY SYNC_PROP [list *syncpropertybeamsectionvalues 1]
foreach dn {A I1 I2 I12 J} {
    TRY "PBEAM_AFTERSYNC_$dn" [list hm_getvalue props id=$propId dataname=$dn]
}

# ------------------------- G. 1D element creation --------------------------
TRY CREATE_VECTOR [list *createvector 1 0.0 0.0 1.0]
set before [hm_latestentityid elems]
TRY BAR_FULL_PROP0 [list *barelementcreatewithoffsets 1001 1011 1 0 1 0 0 0 0 0 0 0 0 0 0 0]
set eFull [hm_latestentityid elems]
if {$eFull eq $before} {set eFull ""}
P "BAR_FULL_PROP0_ELEM" $eFull
if {$eFull ne ""} {
    foreach dn {config typename cardimage nodes property.id collector.id} {
        TRY "BAR_FULL_$dn" [list hm_getvalue elems id=$eFull dataname=$dn]
    }
}
set before [hm_latestentityid elems]
TRY BAR_SHORT_PROPNAME [list *barelementcreatewithoffsets 1002 1012 1 0 1 0 0 AUDIT_PBAR]
set eShort [hm_latestentityid elems]
if {$eShort eq $before} {set eShort ""}
P "BAR_SHORT_PROPNAME_ELEM" $eShort
if {$eShort ne ""} {
    foreach dn {config typename cardimage nodes property.id} {
        TRY "BAR_SHORT_$dn" [list hm_getvalue elems id=$eShort dataname=$dn]
    }
}
# empty-string property argument (module tries 0 and "" as candidates)
set before [hm_latestentityid elems]
TRY BAR_SHORT_PROPEMPTY [list *barelementcreatewithoffsets 1003 1013 1 0 1 0 0 ""]
set eEmpty [hm_latestentityid elems]
if {$eEmpty eq $before} {set eEmpty ""}
P "BAR_SHORT_PROPEMPTY_ELEM" $eEmpty
if {$eEmpty ne ""} { TRY BAR_SHORT_PROPEMPTY_PID [list hm_getvalue elems id=$eEmpty dataname=property.id] }

# ------------------------- H. setvalue refs / node ops ---------------------
# entity-valued node refs (forceBeamEndpointNodes)
if {$eShort ne ""} {
    set ref1 [format "{nodes %s}" 1002]
    set ref2 [format "{nodes %s}" 1012]
    TRY SETVALUE_NODEREF [list *setvalue elems id=$eShort node1=$ref1 node2=$ref2]
    TRY SETVALUE_NODEREF_READ [list hm_getvalue elems id=$eShort dataname=nodes]
    TRY SETVALUE_NODEID [list *setvalue elems id=$eShort node1=1002 node2=1012]
}
# *replacenodes positional form (replaceOneNode: src tgt 1 0)
TRY CREATENODE_6ARG [list *createnode 50.0 50.0 50.0 0 0 0]
set srcId [lindex [markIds nodes 1] end]
TRY CREATENODE_3ARG [list *createnode 50.0 50.0 50.0]
set tgtId [lindex [markIds nodes 1] end]
P "REPLACE_SRC_TGT" "$srcId $tgtId"
TRY REPLACENODES [list *replacenodes $srcId $tgtId 1 0]
TRY SRC_EXISTS [list hm_getvalue nodes id=$srcId dataname=id]
TRY TGT_EXISTS [list hm_getvalue nodes id=$tgtId dataname=id]
# *createpoint
TRY CREATE_POINT [list *createpoint 60.0 60.0 60.0 0]
TRY POINT_LATEST [list hm_latestentityid points]
# *rigid as RBE2 creator (candidate alternative / verification helper)
TRY CREATENODE_R1 [list *createnode 70.0 0.0 0.0 0 0 0]
set r1 [lindex [markIds nodes 1] end]
TRY CREATENODE_R2 [list *createnode 70.0 10.0 0.0 0 0 0]
set r2 [lindex [markIds nodes 1] end]
TRY CREATENODE_R3 [list *createnode 70.0 10.0 10.0 0 0 0]
set r3 [lindex [markIds nodes 1] end]
TRY CREATENODE_R4 [list *createnode 70.0 0.0 10.0 0 0 0]
set r4 [lindex [markIds nodes 1] end]
TRY RIGID_CREATE [list *rigid $r1 $r2 $r3 $r4]
set rbe2New [lindex [lsort -integer [markIds elems 1]] end]
P "RIGID_NEW_ELEM" $rbe2New
if {$rbe2New ne ""} {
    TRY RIGID_CONFIG [list hm_getvalue elems id=$rbe2New dataname=config]
    TRY RIGID_INDEP [list hm_getvalue elems id=$rbe2New dataname=independentnode.id]
}

# ------------------------- I. property assignment --------------------------
# module path: *createmark elems 1 ids + *propertyupdate elems 1 name
catch {*clearmark elems 1}
TRY PROPUPDATE_ELEMS [list *propertyupdate elems 1 AUDIT_PBAR]
catch {*clearmark comps 1}
TRY PROPUPDATE_COMPS [list *propertyupdate comps 1 AUDIT_PBAR]
# component property ref via setvalue (assignPropertyToComponent)
TRY SETVALUE_COMP_PROPREF [list *setvalue comps id=$newCompId STATUS=1 "propertyid={props 4001}"]
TRY SETVALUE_COMP_PROPID [list *setvalue comps id=$newCompId STATUS=1 "propertyid=4001"]
TRY COMP_PROP_READ [list hm_getvalue comps id=$newCompId dataname=property.id]
catch {*clearmark elems 1}
TRY PROPUPDATE_BYNAME [list *propertyupdate elems 1 AUDIT_PBEAM]

# ------------------------- J. mark/display/browser/option cmds -------------
catch {*clearmark comps 2}
TRY MARKSUPPRESSACTIVE [list *marksuppressactive comps 2 0]
TRY MARKSUPPRESSOUTPUT [list *marksuppressoutput comps 2 0]
catch {*clearmark comps 2}
TRY DISPLAYCOLLECTORSBYMARK [list *displaycollectorsbymark comps 2 on 1 1]
TRY DISPLAYCOLLECTORSALLBYMARK [list *displaycollectorsallbymark 2 on 1 1]
TRY DISPLAYCOLLECTOR [list *displaycollector component on AUDIT_BEAM_COMP 1 1]
TRY DISPLAYCOLLECTORWITHTABLE [list *displaycollectorwithfilter component on AUDIT_BEAM_COMP 1 1]
TRY MARKTOUSERMARK [list *marktousermark elems 1]
TRY MARKSECOND [list *clearmark elems 2]
TRY MARKCLEAR_HM [list hm_markclear elems 1]
TRY CURRENTCOLLECTOR [list *currentcollector component AUDIT_BEAM_COMP]
TRY CURRENTCOLLECTOR_HM [list hm_getcurrentcollector comps]
TRY SETOPTION_NAMEVAL [list *setoption block_redraw=1]
TRY SETOPTION_SPACE [list *setoption block_redraw 1]
TRY SETOPTION_MSGS [list *setoption block_messages=1]
TRY GETOPTION [list hm_getoption block_redraw]
TRY BLOCKREDRAW [list hm_blockredraw 1]
TRY BLOCKMESSAGES [list hm_blockmessages 1]
TRY BLOCKERRORMESSAGES [list hm_blockerrormessages 1]
TRY BLOCKBROWSERUPDATE [list hm_blockbrowserupdate 1]
TRY COMMANDFILESTATE [list hm_commandfilestate 0]
TRY HISTORY_START [list *startnotehistorystate "AUDIT_HIST"]
TRY HISTORY_END [list *endnotehistorystate "AUDIT_HIST"]
TRY REDRAW [list hm_redraw]
TRY USERMESSAGE [list hm_usermessage "AUDIT_USER_MSG"]
TRY ENTITYINFO [list hm_entityinfo id comps AUDIT_BEAM_COMP -byname]
TRY LATESTENTITYID [list hm_latestentityid elems]
TRY DELETEMARK [list *deletemark comps 2]
# panel commands: existence only (no functional call in batch to avoid modal hang)
P "PANELS_SKIPPED_BATCH" 1

# ------------------------- K. batch creation alternatives ------------------
# *createelement via list+mark (bar config 1 = BAR2), official bulk path
catch {*clearmark nodes 1}
catch {*createlist nodes 1}
TRY CREATEELM_LIST [list *createlist nodes 1 1001 1011]
TRY CREATEELM_MARK [list *createmark nodes 1 1001 1011]
set before [hm_latestentityid elems]
TRY CREATEELM_BAR [list *createelement 1 1 1]
set eAlt [hm_latestentityid elems]
if {$eAlt eq $before} {set eAlt ""}
P "CREATEELM_BAR_ELEM" $eAlt
if {$eAlt ne ""} {
    TRY CREATEELM_CONFIG [list hm_getvalue elems id=$eAlt dataname=config]
    TRY CREATEELM_NODES [list hm_getvalue elems id=$eAlt dataname=nodes]
}
# *nodemodify as replacenodes alternative (existence verified above; probe args)
catch {*clearmark nodes 1}
set probeNodes [markIds nodes 1]
if {[llength $probeNodes] >= 1} {
    set pn1 [lindex $probeNodes 0]
    TRY NODEMODIFY [list *nodemodify $pn1 x=0.0 y=0.0 z=0.0]
}
# hm_getentityvalue as hm_getvalue alternative
TRY GETENTITYVALUE [list hm_getentityvalue elems 2001 config]

close $ch
catch {puts "audit probe done: $reportPath"}
exit 0
