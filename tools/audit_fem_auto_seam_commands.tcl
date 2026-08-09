# Audit probe for the fem_auto_seam module's HyperMesh native command usage.
# Verifies existence and on-machine semantics of every * / hm_ command the
# module issues, plus the official automesh chain it mirrors.
#
# Run headless with:
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_fem_auto_seam_commands.tcl
#
# Results are written to runtime/audit_fem_auto_seam_<version>.log as
# KEY=VALUE lines (plain ASCII only).  hmbatch has no stdout channel, so all
# reporting goes to the file.  exit 0 at the end regardless.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_fem_auto_seam_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc L {text} {
    variable channel
    puts $channel "$text"
}

# --- 1. Command existence -------------------------------------------------
L "SECTION=existence"
foreach name {
    *clearmark *createmark *createmarkpanel hm_getmark hm_getvalue
    *readfile *writefile *readqualitycriteria hm_answernext
    *feoutput_select *templatefileset *createstringarray *feinputwithdata2
    hm_info *displaycollectorsallbymark *numbersclear *numbersmark
    hm_redraw hm_viewfit
    *appendmark *elementsaddnodesfixed *setedgedensitylinkwithaspectratio
    *elementorder *featureangleset *setusefeatures *interactiveremeshelems
    *interactiveremeshsurf *set_meshfaceparams *automesh *storemeshtodatabase
    *rejectmesh *ameshclearsurface hm_getmeshfaceparams
    hm_getelementsqualityinfo
} {
    P "EXISTS $name" [expr {[info commands $name] ne ""}]
}

# --- 2. Fixture: two 12-quad plates in a T junction ------------------------
L "SECTION=fixture"
proc FXComp {name color} {
    *collectorcreateonly components $name "" $color
    set id [hm_getvalue comps name=$name dataname=id]
    *currentcollector component $name
    return $id
}
proc FXNode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc FXQuad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}
proc FXCount {type} {
    catch {*createmark $type 1 all}
    return [llength [hm_getmark $type 1]]
}

set compA [FXComp AUDIT_PLATE_A 1]
set compB [FXComp AUDIT_PLATE_B 2]
array set na {}
foreach x {0 10 20} {
    foreach y {0 10 20} {
        set na($x,$y) [FXNode $x $y 0]
    }
}
set elemsA {}
foreach x0 {0 10} x1 {10 20} {
    foreach y0 {0 10} y1 {10 20} {
        lappend elemsA [FXQuad [list $na($x0,$y0) $na($x1,$y0) $na($x1,$y1) $na($x0,$y1)]]
    }
}
array set nb {}
foreach y {0 10 20} {
    foreach z {10 20} {
        set nb($y,$z) [FXNode 20 $y $z]
    }
}
set elemsB {}
foreach y0 {0 10} y1 {10 20} {
    set q [FXQuad [list $nb($y0,10) $nb($y1,10) $nb($y1,20) $nb($y0,20)]]
    lappend elemsB $q
}
# Deliberately bad sliver quad in comp B (aspect ~1000, min length 0.01)
*currentcollector component AUDIT_PLATE_B
set bad0 [FXNode 30 0 0]
set bad1 [FXNode 40 0 0]
set bad2 [FXNode 40 0.01 0]
set bad3 [FXNode 30 0.01 0]
set sliver [FXQuad [list $bad0 $bad1 $bad2 $bad3]]
*currentcollector component AUDIT_PLATE_A
P "FIXTURE_NODES" [FXCount nodes]
P "FIXTURE_ELEMS" [FXCount elems]
P "FIXTURE_COMPS" [FXCount comps]
P "FIXTURE_ELEMS_A" [llength $elemsA]
P "FIXTURE_ELEMS_B" [llength $elemsB]

# --- 3. Mark / query semantics ---------------------------------------------
L "SECTION=marks"
# 3a. by component id (quoted option, module form)
catch {*clearmark elems 1}
set code [catch {eval *createmark elems 1 [list "by component id"] $compA} err]
P "MARK_BY_COMPONENT_ID_ERR" [expr {$code ? $err : "none"}]
P "MARK_BY_COMPONENT_ID_COUNT" [llength [hm_getmark elems 1]]
# 3b. by node id (quoted option, module form)
catch {*clearmark elems 2}
set code [catch {eval *createmark elems 2 [list "by node id"] [list $na(20,0) $na(20,10) $na(20,20)]} err]
P "MARK_BY_NODE_ID_ERR" [expr {$code ? $err : "none"}]
P "MARK_BY_NODE_ID_COUNT" [llength [hm_getmark elems 2]]
# 3c. by plain id list (module form in autoExpandElementPatch)
catch {*clearmark elements 1}
set code [catch {eval *createmark elements 1 [lrange $elemsA 0 3]} err]
P "MARK_BY_IDLIST_ERR" [expr {$code ? $err : "none"}]
P "MARK_BY_IDLIST_COUNT" [llength [hm_getmark elements 1]]
# 3d. appendmark expansion: "by adjacent" vs "adjacent" vs "by face"
foreach option {"by adjacent" adjacent} {
    catch {*clearmark elems 1}
    eval *createmark elems 1 [lrange $elemsA 0 1]
    set before [llength [hm_getmark elems 1]]
    set code [catch {*appendmark elems 1 $option} err]
    set after [llength [hm_getmark elems 1]]
    P "APPENDMARK $option ERR" [expr {$code ? $err : "none"}]
    P "APPENDMARK $option GROW" "$before->$after"
}
# 3e. hm_getvalue datanames used by the module
set sample [lindex $elemsA 0]
foreach dataName {nodes center collector.id collectorid component.id componentid property.id propertyid} {
    set value ""
    set code [catch {set value [hm_getvalue elems id=$sample dataname=$dataName]} err]
    P "GETVALUE elems $dataName ERR" [expr {$code ? $err : "none"}]
    P "GETVALUE elems $dataName VAL" [string map {" " ,} $value]
}
set compName ""
catch {set compName [hm_getvalue comps id=$compA dataname=name]}
P "GETVALUE comps name VAL" $compName
# 3f. displayed comp mark (GUI-only in batch)
catch {*clearmark comps 2}
set code [catch {*createmark comps 2 displayed} err]
P "MARK_DISPLAYED_ERR" [expr {$code ? $err : "none"}]
P "MARK_DISPLAYED_COUNT" [llength [hm_getmark comps 2]]

# --- 4. Quality check (hm_getelementsqualityinfo) ---------------------------
L "SECTION=quality"
catch {*clearmark elems 1}
*createmark elems 1 all
# official 1-arg form
set out ""
set code [catch {set out [hm_getelementsqualityinfo 1]} err]
P "QI_1ARG_ERR" [expr {$code ? $err : "none"}]
P "QI_1ARG_RETURN" [string map {" " ,} $out]
# module 3-arg form: hm_getelementsqualityinfo 1 1 2 -> failures in mark elems 2
catch {*clearmark elems 2}
set code [catch {hm_getelementsqualityinfo 1 1 2} err]
P "QI_3ARG_ERR" [expr {$code ? $err : "none"}]
set failed ""
catch {set failed [hm_getmark elems 2]}
P "QI_3ARG_MARK2_COUNT" [llength $failed]
P "QI_3ARG_MARK2_HAS_SLIVER" [expr {$failed ne "" && [lsearch -exact $failed $sliver] >= 0}]
# criteria load
set defaultCriteria [file join $root modules fem_auto_seam defaults fem_auto_seam_default.criteria]
set code [catch {*readqualitycriteria $defaultCriteria} err]
P "READQUALITYCRITERIA_ERR" [expr {$code ? $err : "none"}]
# re-check after criteria load (module order: criteria first, then QI)
catch {*clearmark elems 1}; *createmark elems 1 all
catch {*clearmark elems 2}
set code [catch {hm_getelementsqualityinfo 1 1 2} err]
P "QI_3ARG_AFTER_CRITERIA_ERR" [expr {$code ? $err : "none"}]
set failed ""
catch {set failed [hm_getmark elems 2]}
P "QI_3ARG_AFTER_CRITERIA_MARK2_COUNT" [llength $failed]
P "QI_3ARG_AFTER_CRITERIA_HAS_SLIVER" [expr {$failed ne "" && [lsearch -exact $failed $sliver] >= 0}]

# --- 5. Batch element automesh chain (module sequence) ----------------------
L "SECTION=automesh"
set totalBefore [FXCount elems]
catch {*clearmark elements 1}
eval *createmark elements 1 $elemsA
catch {*clearmark nodes 2}
eval *createmark nodes 2 [list $na(20,0) $na(20,10) $na(20,20)]
set code [catch {*elementsaddnodesfixed 1 2} err]
P "ELEMENTSADDNODESFIXED_ERR" [expr {$code ? $err : "none"}]
set code [catch {*setedgedensitylinkwithaspectratio -1} err]
P "SETEDGEDENSITYLINKASPECT_ERR" [expr {$code ? $err : "none"}]
set code [catch {*elementorder 1} err]
P "ELEMENTORDER_ERR" [expr {$code ? $err : "none"}]
set code [catch {*featureangleset 30} err]
P "FEATUREANGLESET_ERR" [expr {$code ? $err : "none"}]
set code [catch {*setusefeatures 3} err]
P "SETUSEFEATURES_ERR" [expr {$code ? $err : "none"}]
set code [catch {*interactiveremeshelems 1 4.0 2 2 1 1 2 30} err]
P "INTERACTIVEREMESHELEMS_ERR" [expr {$code ? $err : "none"}]
set totalAfterIRM [FXCount elems]
P "TOTAL_ELEMS_AFTER_INTERACTIVEREMESHELEMS" $totalAfterIRM
# per-face loop like the module: probe face indices 0..N
set faces 0
set firstFaceErr ""
for {set faceIndex 0} {$faceIndex < 30} {incr faceIndex} {
    set code [catch {*set_meshfaceparams $faceIndex 2 2 0 0 1 0.5 1 1} err]
    if {$code} {
        if {$firstFaceErr eq "" && $faces == 0} { set firstFaceErr $err }
        if {$faces > 0} { break }
        continue
    }
    set params ""
    set code2 [catch {set params [hm_getmeshfaceparams $faceIndex]} err2]
    P "GETMESHFACEPARAMS F$faceIndex ERR" [expr {$code2 ? $err2 : "none"}]
    P "GETMESHFACEPARAMS F$faceIndex VAL" [string map {" " ,} $params]
    set code3 [catch {*automesh $faceIndex 2 2} err3]
    if {$code3} {
        P "AUTOMESH F$faceIndex ERR" $err3
        if {$faces == 0} { break }
    } else {
        incr faces
    }
}
P "FACES_MESHED" $faces
set code [catch {*storemeshtodatabase 1} err]
P "STOREMESHTODATABASE_ERR" [expr {$code ? $err : "none"}]
set totalAfterStore [FXCount elems]
P "TOTAL_ELEMS_AFTER_STORE" $totalAfterStore
P "REPLACEMENT_HAPPENED" [expr {$totalAfterStore != $totalBefore}]
# capture whether new element ids exist beyond the original set
set newIds {}
catch {*createmark elems 1 all}
foreach eid [hm_getmark elems 1] {
    if {[lsearch -exact $elemsA $eid] < 0 && [lsearch -exact $elemsB $eid] < 0 && $eid != $sliver} { lappend newIds $eid }
}
P "NEW_ELEM_IDS_COUNT" [llength $newIds]
set code [catch {*ameshclearsurface} err]
P "AMESHCLEARSURFACE_ERR" [expr {$code ? $err : "none"}]
set code [catch {*featureangleset 60} err]
P "FEATUREANGLESET_RESTORE_ERR" [expr {$code ? $err : "none"}]
set code [catch {*setusefeatures 0} err]
P "SETUSEFEATURES_RESTORE_ERR" [expr {$code ? $err : "none"}]
# reject path: remesh again but reject before store; model must be unchanged
set totalBeforeReject [FXCount elems]
catch {*clearmark elements 1}
eval *createmark elements 1 [lrange $elemsA 0 5]
catch {*clearmark nodes 2}
eval *createmark nodes 2 [list $na(20,0) $na(20,10)]
set code [catch {*interactiveremeshelems 1 4.0 2 2 1 1 2 30} err]
P "IRM_REJECTPATH_ERR" [expr {$code ? $err : "none"}]
set faceOk 0
if {![catch {*set_meshfaceparams 0 2 2 0 0 1 0.5 1 1}]} {
    if {![catch {*automesh 0 2 2}]} { set faceOk 1 }
}
P "REJECTPATH_FACE_OK" $faceOk
set code [catch {*rejectmesh 0} err]
P "REJECTMESH_ERR" [expr {$code ? $err : "none"}]
catch {*ameshclearsurface}
set totalAfterReject [FXCount elems]
P "REJECT_KEPT_MODEL" [expr {$totalAfterReject == $totalBeforeReject}]

# --- 6. FEM export / import roundtrip ---------------------------------------
L "SECTION=femio"
set tplDir ""
set tpl1 ""
set code [catch {set tplDir [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]} err]
P "HM_INFO_TEMPLATES_DIR_ERR" [expr {$code ? $err : "none"}]
P "HM_INFO_TEMPLATES_DIR_VAL" [string map {\\ /} $tplDir]
set tpl1 [file join $tplDir feoutput optistruct optistruct]
P "TEMPLATE_CANDIDATE1_ISFILE" [expr {[file isfile $tpl1]}]
set exeDir ""
set tpl2 ""
set code [catch {set exeDir [hm_info -appinfo EXECUTABLEDIR]} err]
P "HM_INFO_EXECUTABLEDIR_ERR" [expr {$code ? $err : "none"}]
P "HM_INFO_EXECUTABLEDIR_VAL" [string map {\\ /} $exeDir]
set tpl2 [file join $exeDir .. .. .. templates feoutput optistruct optistruct]
P "TEMPLATE_CANDIDATE2_ISFILE" [expr {[file isfile $tpl2]}]
set template [expr {[file isfile $tpl1] ? $tpl1 : $tpl2}]
set exportPath [file join $outputDir audit_fem_auto_seam_export_${version}.fem]
catch {file delete -force $exportPath}
set code [catch {*templatefileset [file nativename $template]} err]
P "TEMPLATEFILESET_ERR" [expr {$code ? $err : "none"}]
catch {*clearmark elems 1}; *createmark elems 1 all
catch {*clearmark nodes 1}; *createmark nodes 1 all
set code [catch {*feoutput_select $template $exportPath 1 0 0} err]
P "FEOUTPUT_SELECT_ERR" [expr {$code ? $err : "none"}]
P "FEOUTPUT_SELECT_FILE_EXISTS" [expr {[file isfile $exportPath]}]
P "FEOUTPUT_SELECT_FILE_SIZE" [expr {[file isfile $exportPath] ? [file size $exportPath] : 0}]
# import the exported FEM back and compare counts
set nodesBefore [FXCount nodes]
set elemsBefore [FXCount elems]
set compsBefore [FXCount comps]
catch {*createmark comps 1 all}
foreach cid [hm_getmark comps 1] { catch {*deletemark comps 1} }
catch {*createmark nodes 1 all}
foreach nid [hm_getmark nodes 1] { catch {*deletemark nodes 1} }
catch {*createmark elems 1 all}
foreach eid [hm_getmark elems 1] { catch {*deletemark elems 1} }
P "CLEARED_NODES" [FXCount nodes]
set code [catch {
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    *feinputwithdata2 "#optistruct/optistruct" [file nativename $exportPath] 0 0 0 0 0 1 2 1 0
} err]
P "FEINPUTWITH_DATA2_ERR" [expr {$code ? $err : "none"}]
P "REIMPORT_NODES" [FXCount nodes]
P "REIMPORT_ELEMS" [FXCount elems]
P "REIMPORT_COMPS" [FXCount comps]

# --- 7. File > Open semantics (*readfile flag 0 vs 1, .fem and .hm) ----------
L "SECTION=readfile"
# current model is the reimported A+B fixture (2 comps, 25 elems incl sliver)
set r1 [FXCount comps]
# export current model as .fem, then delete everything, then readfile flag 0
set openFem [file join $outputDir audit_fem_auto_seam_open_${version}.fem]
catch {file delete -force $openFem}
catch {*clearmark elems 1}; *createmark elems 1 all
catch {*clearmark nodes 1}; *createmark nodes 1 all
set code [catch {*feoutput_select $template $openFem 1 0 0} err]
P "OPENFEM_EXPORT_ERR" [expr {$code ? $err : "none"}]
catch {*createmark comps 1 all}
foreach cid [hm_getmark comps 1] { catch {*deletemark comps 1} }
catch {*createmark nodes 1 all}
foreach nid [hm_getmark nodes 1] { catch {*deletemark nodes 1} }
catch {*createmark elems 1 all}
foreach eid [hm_getmark elems 1] { catch {*deletemark elems 1} }
P "EMPTY_BEFORE_READFILE0" [expr {[FXCount elems] == 0}]
catch {hm_answernext yes}
set code [catch {*readfile [file nativename $openFem] 0} err]
P "READFILE_FEM_0_ERR" [expr {$code ? $err : "none"}]
P "READFILE_FEM_0_NODES" [FXCount nodes]
P "READFILE_FEM_0_ELEMS" [FXCount elems]
P "READFILE_FEM_0_COMPS" [FXCount comps]
P "READFILE_FEM_0_REPLACED" [expr {[FXCount elems] > 0 && [FXCount comps] >= 2}]
# flag 1 = merge semantics: read the same FEM again into the existing model
set compsBeforeMerge [FXCount comps]
catch {hm_answernext yes}
set code [catch {*readfile [file nativename $openFem] 1} err]
P "READFILE_FEM_1_ERR" [expr {$code ? $err : "none"}]
P "READFILE_FEM_1_NODES" [FXCount nodes]
P "READFILE_FEM_1_ELEMS" [FXCount elems]
P "READFILE_FEM_1_COMPS" [FXCount comps]
P "READFILE_1_MERGES" [expr {[FXCount comps] > $compsBeforeMerge}]
# .hm snapshot via *writefile then *readfile 0
set snapPath [file join $outputDir audit_fem_auto_seam_snap_${version}.hm]
catch {file delete -force $snapPath}
catch {hm_answernext yes}
set code [catch {*writefile [file nativename $snapPath] 1} err]
P "WRITEFILE_ERR" [expr {$code ? $err : "none"}]
P "WRITEFILE_EXISTS" [expr {[file isfile $snapPath]}]
P "WRITEFILE_SIZE" [expr {[file isfile $snapPath] ? [file size $snapPath] : 0}]
set nodesSnap [FXCount nodes]
set elemsSnap [FXCount elems]
catch {*createmark comps 1 all}
foreach cid [hm_getmark comps 1] { catch {*deletemark comps 1} }
catch {hm_answernext yes}
set code [catch {*readfile [file nativename $snapPath] 0} err]
P "READFILE_HM_0_ERR" [expr {$code ? $err : "none"}]
P "READFILE_HM_0_NODES" [FXCount nodes]
P "READFILE_HM_0_ELEMS" [FXCount elems]
P "READFILE_HM_0_MATCHES" [expr {[FXCount nodes] == $nodesSnap && [FXCount elems] == $elemsSnap}]

# --- 8. Display / view commands (validity only, batch has no GUI) -----------
L "SECTION=display"
catch {*clearmark comps 1}
eval *createmark comps 1 [list $compA $compB]
set code [catch {*displaycollectorsallbymark 1 off 1 1} err]
P "DISPLAY_OFF_ERR" [expr {$code ? $err : "none"}]
set code [catch {*displaycollectorsallbymark 1 on 1 1} err]
P "DISPLAY_ON_ERR" [expr {$code ? $err : "none"}]
catch {*clearmark nodes 1}
eval *createmark nodes 1 [list $na(20,0)]
set code [catch {*numbersmark nodes 1 1} err]
P "NUMBERSMARK_ERR" [expr {$code ? $err : "none"}]
set code [catch {*numbersclear} err]
P "NUMBERS_CLEAR_ERR" [expr {$code ? $err : "none"}]
set code [catch {hm_redraw} err]
P "HM_REDRAW_ERR" [expr {$code ? $err : "none"}]
set code [catch {hm_viewfit} err]
P "HM_VIEWFIT_ERR" [expr {$code ? $err : "none"}]
set code [catch {*createmarkpanel comps 1 "probe title"} err]
P "CREATEMARKPANEL_ERR" [expr {$code ? $err : "none"}]
P "CREATEMARKPANEL_MARK_COUNT" [llength [hm_getmark comps 1]]

L "SECTION=done"
P "PROBE_COMPLETE" 1
close $channel
exit 0
