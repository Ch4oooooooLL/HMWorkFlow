# Second audit probe for fem_auto_seam: semantics of marks, quality info,
# automesh face loop, *readfile/.fem reopen, *feinputwithdata2 flags, and
# hm_getvalue datanames.  One hmbatch launch, results to file, exit 0.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_fem_auto_seam_semantics.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_fem_auto_seam2_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc L {text} {
    variable channel
    puts $channel "$text"
}
proc FXComp {name color} {
    *collectorcreateonly components $name "" $color
    set id [hm_getvalue comps name=$name dataname=id]
    return $id
}
proc FXSetComp {name} {
    *currentcollector component $name
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

# --- 0. Candidate command existence -----------------------------------------
L "SECTION=existence"
foreach name {
    *openfile *getmeshfaceparams hm_getmeshfaceparams
    *deletenodes hm_deletenodes *deleteunusednodes hm_deleteunusednodes
    *feinputwithdata *feinputwithdata2 *feinput *hmread *databasename
} {
    P "EXISTS $name" [expr {[info commands $name] ne ""}]
}

# --- 1. Fixture: comp A 4x4 quads of 5x5, comp B 4 quads, sliver in B -------
L "SECTION=fixture"
set compA [FXComp AUDIT2_PLATE_A 1]
set compB [FXComp AUDIT2_PLATE_B 2]
FXSetComp AUDIT2_PLATE_A
array set na {}
foreach x {0 5 10} {
    foreach y {0 5 10} {
        set na($x,$y) [FXNode $x $y 0]
    }
}
set elemsA {}
foreach x0 {0 5} {
    foreach y0 {0 5} {
        lappend elemsA [FXQuad [list $na($x0,$y0) $na([expr {$x0+5}],$y0) $na([expr {$x0+5}],[expr {$y0+5}]) $na($x0,[expr {$y0+5}])]]
    }
}
FXSetComp AUDIT2_PLATE_B
array set nb {}
foreach y {0 5 10} {
    foreach z {5 10} {
        set nb($y,$z) [FXNode 20 $y $z]
    }
}
set elemsB {}
foreach y0 {0 5} {
    set q [FXQuad [list $nb($y0,5) $nb([expr {$y0+5}],5) $nb([expr {$y0+5}],10) $nb($y0,10)]]
    lappend elemsB $q
}
set sliver [FXQuad [list [FXNode 30 0 0] [FXNode 40 0 0] [FXNode 40 0.01 0] [FXNode 30 0.01 0]]]
FXSetComp AUDIT2_PLATE_A
P "FIXTURE_NODES" [FXCount nodes]
P "FIXTURE_ELEMS" [FXCount elems]
P "FIXTURE_COMPS" [FXCount comps]
P "FIXTURE_ELEMS_A" [llength $elemsA]
P "FIXTURE_ELEMS_B" [llength $elemsB]

# --- 2. Mark option semantics ------------------------------------------------
L "SECTION=marks"
foreach option {"by comp" "by component id" "by collector id"} {
    catch {*clearmark elems 1}
    set code [catch {eval *createmark elems 1 [list $option] $compA} err]
    P "MARK_A $option ERR" [expr {$code ? $err : "none"}]
    P "MARK_A $option COUNT" [llength [hm_getmark elems 1]]
}
# which comp are the elements actually in?
foreach eid [concat [lrange $elemsA 0 0] [lrange $elemsB 0 0] [list $sliver]] {
    set cid ""
    catch {set cid [hm_getvalue elems id=$eid dataname=collector.id]}
    P "ELEM $eid COLLECTOR" $cid
}
# by node id on junction nodes
catch {*clearmark elems 2}
set code [catch {eval *createmark elems 2 [list "by node id"] [list $na(10,5) $na(10,10)]} err]
P "MARK_BY_NODE_ID_ERR" [expr {$code ? $err : "none"}]
P "MARK_BY_NODE_ID_COUNT" [llength [hm_getmark elems 2]]
# appendmark growth on the full A plate
catch {*clearmark elems 1}
eval *createmark elems 1 [lrange $elemsA 0 1]
set beforeCount [llength [hm_getmark elems 1]]
P "APPEND_ADJACENT_BEFORE" $beforeCount
catch {*appendmark elems 1 "by adjacent"}
P "APPEND_ADJACENT_AFTER" [llength [hm_getmark elems 1]]

# --- 3. Quality check with module order (criteria first) ----------------------
L "SECTION=quality"
set defaultCriteria [file join $root modules fem_auto_seam defaults fem_auto_seam_default.criteria]
set code [catch {*readqualitycriteria $defaultCriteria} err]
P "READQUALITYCRITERIA_ERR" [expr {$code ? $err : "none"}]
catch {*clearmark elems 1}; *createmark elems 1 all
catch {*clearmark elems 2}
set code [catch {hm_getelementsqualityinfo 1 1 2} err]
P "QI_3ARG_ERR" [expr {$code ? $err : "none"}]
set failed ""
catch {set failed [hm_getmark elems 2]}
P "QI_MARK2_COUNT" [llength $failed]
P "QI_MARK2_HAS_SLIVER" [expr {$failed ne "" && [lsearch -exact $failed $sliver] >= 0}]
set goodInFailed 0
foreach eid [concat $elemsA $elemsB] {
    if {[lsearch -exact $failed $eid] >= 0} { incr goodInFailed }
}
P "QI_GOOD_ELEMS_IN_MARK2" $goodInFailed
set out ""
catch {set out [hm_getelementsqualityinfo 1]}
P "QI_1ARG_RETURN" [string map {" " ,} $out]

# --- 4. Automesh chain + face getter variants ---------------------------------
L "SECTION=automesh"
set totalBefore [FXCount elems]
catch {*clearmark elements 1}
eval *createmark elements 1 $elemsA
catch {*clearmark nodes 2}
eval *createmark nodes 2 [list $na(10,5) $na(10,10)]
catch {*elementsaddnodesfixed 1 2}
catch {*setedgedensitylinkwithaspectratio -1}
catch {*elementorder 1}
catch {*featureangleset 30}
catch {*setusefeatures 3}
set code [catch {*interactiveremeshelems 1 4.0 2 2 1 1 2 30} err]
P "INTERACTIVEREMESHELEMS_ERR" [expr {$code ? $err : "none"}]
# face getter variants, before any set/automesh on face 0
set g0 ""
catch {set g0 [hm_getmeshfaceparams 0]}
P "GETFACE_0_BEFORE_SET" [string map {" " ,} $g0]
set g1 ""
catch {set g1 [hm_getmeshfaceparams]}
P "GETFACE_NOARG" [string map {" " ,} $g1]
set g2 ""
catch {set g2 [*getmeshfaceparams 0]}
P "STARGETFACE_0" [string map {" " ,} $g2]
# module loop: set_meshfaceparams then getter then automesh
set faces 0
for {set faceIndex 0} {$faceIndex < 20} {incr faceIndex} {
    set code [catch {*set_meshfaceparams $faceIndex 2 2 0 0 1 0.5 1 1} err]
    if {$code} {
        P "SETFACE F$faceIndex ERR" $err
        if {$faces > 0} { break }
        continue
    }
    set params ""
    set code2 [catch {set params [hm_getmeshfaceparams $faceIndex]} err2]
    P "GETFACE F$faceIndex AFTER_SET ERR" [expr {$code2 ? $err2 : "none"}]
    P "GETFACE F$faceIndex AFTER_SET VAL" [string map {" " ,} $params]
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
P "TOTAL_AFTER_STORE" [FXCount elems]
# verify old A elems replaced, B elems and sliver untouched
set aliveA 0
foreach eid $elemsA {
    catch {*createmark elems 1 $eid}
    if {[llength [hm_getmark elems 1]]} { incr aliveA }
}
set aliveB 0
foreach eid $elemsB {
    catch {*createmark elems 1 $eid}
    if {[llength [hm_getmark elems 1]]} { incr aliveB }
}
catch {*createmark elems 1 $sliver}
P "A_ORIGINALS_ALIVE" $aliveA
P "B_ORIGINALS_ALIVE" $aliveB
P "SLIVER_ALIVE" [llength [hm_getmark elems 1]]
catch {*ameshclearsurface}
catch {*featureangleset 60}
catch {*setusefeatures 0}

# --- 5. Two-patch face probing (consecutive face indices assumption) ----------
L "SECTION=twopatch"
catch {*clearmark elements 1}
eval *createmark elements 1 [concat $elemsA $elemsB]
catch {*setusefeatures 3}
catch {*featureangleset 30}
set code [catch {*interactiveremeshelems 1 4.0 2 2 1 1 2 30} err]
P "IRM_TWOPATCH_ERR" [expr {$code ? $err : "none"}]
set faceIndex 0
set ok 1
while {$ok && $faceIndex < 20} {
    set code [catch {*set_meshfaceparams $faceIndex 2 2 0 0 1 0.5 1 1} err]
    if {$code} { set ok 0; break }
    set code [catch {*automesh $faceIndex 2 2} err]
    if {$code} { set ok 0; break }
    incr faceIndex
}
P "TWOPATCH_FACES" $faceIndex
catch {*storemeshtodatabase 1}
P "TWOPATCH_TOTAL_AFTER_STORE" [FXCount elems]
catch {*ameshclearsurface}
catch {*setusefeatures 0}

# --- 6. *readfile semantics ----------------------------------------------------
L "SECTION=readfile"
set template [file join [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR] feoutput optistruct optistruct]
# 6a. export whole current model as fem + as hm snapshot
set femPath [file join $outputDir audit2_model_${version}.fem]
set hmPath [file join $outputDir audit2_model_${version}.hm]
catch {file delete -force $femPath $hmPath}
catch {*clearmark elems 1}; *createmark elems 1 all
catch {*clearmark nodes 1}; *createmark nodes 1 all
catch {*feoutput_select $template $femPath 1 0 0}
catch {hm_answernext yes}
catch {*writefile [file nativename $hmPath] 1}
P "SNAP_FEM_SIZE" [expr {[file isfile $femPath] ? [file size $femPath] : 0}]
P "SNAP_HM_SIZE" [expr {[file isfile $hmPath] ? [file size $hmPath] : 0}]
set femElems [FXCount elems]
set femComps [FXCount comps]
# 6b. clear model (delete comps only; nodes are not deletable directly in batch)
catch {*createmark comps 1 all}
catch {*deletemark comps 1}
P "CLEARED_ELEMS" [FXCount elems]
P "CLEARED_COMPS" [FXCount comps]
# 6c. *readfile .hm 0 -> replace
catch {hm_answernext yes}
set code [catch {*readfile [file nativename $hmPath] 0} err]
P "READFILE_HM_0_ERR" [expr {$code ? $err : "none"}]
P "READFILE_HM_0_ELEMS_MATCH" [expr {[FXCount elems] == $femElems}]
P "READFILE_HM_0_COMPS_MATCH" [expr {[FXCount comps] == $femComps}]
# 6d. *readfile .fem 0 -> expect native refusal
set nodesBeforeFem [FXCount nodes]
catch {*createmark comps 1 all}
catch {*deletemark comps 1}
catch {hm_answernext yes}
set code [catch {*readfile [file nativename $femPath] 0} err]
P "READFILE_FEM_0_ERR" [expr {$code ? $err : "none"}]
P "READFILE_FEM_0_ELEMS" [FXCount elems]
P "READFILE_FEM_0_COMPS" [FXCount comps]
# 6e. merge semantics: *readfile .hm 1 onto a model that has 1 extra comp
# (restore the snapshot first, then add one extra comp+quad)
catch {hm_answernext yes}
catch {*readfile [file nativename $hmPath] 0}
set snapComps [FXCount comps]
set snapElems [FXCount elems]
set extraComp [FXComp AUDIT2_EXTRA 3]
FXSetComp AUDIT2_EXTRA
set extra [FXQuad [list [FXNode 50 0 0] [FXNode 55 0 0] [FXNode 55 5 0] [FXNode 50 5 0]]]
set compsBeforeMerge [FXCount comps]
catch {hm_answernext yes}
set code [catch {*readfile [file nativename $hmPath] 1} err]
P "READFILE_HM_1_ERR" [expr {$code ? $err : "none"}]
P "READFILE_HM_1_COMPS" [FXCount comps]
P "READFILE_HM_1_ELEMS" [FXCount elems]
P "READFILE_HM_1_MERGED" [expr {[FXCount comps] > $compsBeforeMerge}]
P "SNAP_COMPS" $snapComps
P "SNAP_ELEMS" $snapElems

# --- 7. *feinputwithdata2 replace vs merge ------------------------------------
L "SECTION=feinput"
# clear all comps, then import the fem; count how many comps appear
catch {*createmark comps 1 all}
catch {*deletemark comps 1}
set compsAfterClear [FXCount comps]
set code [catch {
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    *feinputwithdata2 "#optistruct/optistruct" [file nativename $femPath] 0 0 0 0 0 1 2 1 0
} err]
P "FEINPUT_BASE_ERR" [expr {$code ? $err : "none"}]
P "FEINPUT_BASE_COMPS" [FXCount comps]
P "FEINPUT_BASE_ELEMS" [FXCount elems]
P "FEINPUT_BASE_MERGED" [expr {[FXCount comps] > $compsAfterClear}]
# flag6=0 variant
catch {*createmark comps 1 all}
catch {*deletemark comps 1}
set compsAfterClear [FXCount comps]
set code [catch {
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    *feinputwithdata2 "#optistruct/optistruct" [file nativename $femPath] 0 0 0 0 0 0 2 1 0
} err]
P "FEINPUT_F6_0_ERR" [expr {$code ? $err : "none"}]
P "FEINPUT_F6_0_COMPS" [FXCount comps]
P "FEINPUT_F6_0_ELEMS" [FXCount elems]
# flag1=1 variant (rbe2 overwrite-node flag)
catch {*createmark comps 1 all}
catch {*deletemark comps 1}
set compsAfterClear [FXCount comps]
set code [catch {
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    *feinputwithdata2 "#optistruct/optistruct" [file nativename $femPath] 1 0 0 0 0 1 2 1 0
} err]
P "FEINPUT_F1_1_ERR" [expr {$code ? $err : "none"}]
P "FEINPUT_F1_1_COMPS" [FXCount comps]
P "FEINPUT_F1_1_ELEMS" [FXCount elems]

# --- 8. hm_getvalue datanames for writeExistingSeams ---------------------------
L "SECTION=getvalue"
catch {*createmark elems 1 all}
set any [lindex [hm_getmark elems 1] 0]
foreach dataName {center centroid centerofmass mass volume cardimage config nodes} {
    set value ""
    set code [catch {set value [hm_getvalue elems id=$any dataname=$dataName]} err]
    P "GETVALUE $dataName ERR" [expr {$code ? $err : "none"}]
    P "GETVALUE $dataName VAL" [string map {" " ,} $value]
}

L "SECTION=done"
P "PROBE2_COMPLETE" 1
close $channel
exit 0
