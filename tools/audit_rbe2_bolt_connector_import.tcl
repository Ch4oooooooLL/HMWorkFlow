# ============================================================================
# Follow-up audit probe for rbe2_bolt_connector incremental FEM import.
#
# Focus:
#   1. Does *feinputwithdata2 preserve PROP/COMP ids written by the module's
#      Python incremental FEM writer ($HMNAME PROP/COMP + $HMCOMP ID)?
#   2. Is ASSIGNPROP_BYHMCOMMENTS responsible for any renumbering?
#   3. 1D mark selector variants ("by dimension" 1d / "by config" 60 / ...).
#   4. *replacenodes / *rigid functional checks (proper mark reads).
#   5. *propertyupdate with populated marks; *setvalue comps propertyid ref.
#   6. *attributeupdateentity PBAR 3179 with a real PBAR property.
#   7. *createelement nodes readback.
#
# Results: runtime/audit_rbe2_bolt_connector_import_<version>.log
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_rbe2_bolt_connector_import_${version}.log"]
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
proc dumpAll {etype} {
    catch {*clearmark $etype 1}
    *createmark $etype 1 all
    set ids [hm_getmark $etype 1]
    set out {}
    foreach id [lsort -integer $ids] {
        set name ""
        catch {set name [hm_getvalue $etype id=$id dataname=name]}
        lappend out "$id:$name"
    }
    return [join $out { }]
}

P "VERSION" $version
set executableDir [hm_info -appinfo EXECUTABLEDIR]
set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
catch {*templatefileset $templatePath} tErr
P "TEMPLATE" [string trim [hm_info templatetype]]

# module-style incremental FEM: comments + $HMCOMP ID + PBAR/PBEAM props
set fem1 [file join $outputDir audit_rbe2_import_m1.fem]
set f [open $fem1 w]
puts $f {BEGIN BULK}
puts $f {$HMNAME MAT 5001 "steel"}
puts $f {MAT1,5001,210000.0,,0.3,7.85E-9}
puts $f {$HMNAME PROP 4001 "BOLT_D10_PBAR"}
puts $f {PBAR,4001,5001,78.539816,490.873852,490.873852,981.747704,0.0}
puts $f {$HMNAME PROP 4002 "BOLT_D12_PBEAM"}
puts $f {PBEAM,4002,5001,113.097336,1017.876020,1017.876020,0.0,2035.752040,0.0}
puts $f {$HMNAME COMP 2001 "BOLT_D10_CBAR"}
puts $f {$HMNAME COMP 2002 "BOLT_D12_CBEAM"}
puts $f {GRID,1001,,0,0,0}
puts $f {GRID,1002,,10,0,0}
puts $f {GRID,1003,,10,10,0}
puts $f {GRID,1004,,0,10,0}
puts $f {GRID,1011,,0,0,20}
puts $f {GRID,1012,,10,0,20}
puts $f {GRID,1013,,10,10,20}
puts $f {GRID,1014,,0,10,20}
puts $f {RBE2,2001,1001,123456,1002,1003,1004}
puts $f {RBE2,2002,1011,123456,1012,1013,1014}
puts $f {$HMCOMP ID 2001}
puts $f {CBAR,3001,4001,1001,1011,0.0,1.0,0.0}
puts $f {$HMCOMP ID 2002}
puts $f {CBEAM,3002,4002,1011,1001,0.0,1.0,0.0}
puts $f {ENDDATA}
puts $f {}
close $f

# variant without $HMNAME/$HMCOMP comments
set fem2 [file join $outputDir audit_rbe2_import_m2.fem]
set f [open $fem2 w]
puts $f {BEGIN BULK}
puts $f {MAT1,6001,210000.0,,0.3,7.85E-9}
puts $f {PBAR,6002,6001,78.539816,490.873852,490.873852,981.747704,0.0}
puts $f {GRID,2001,,0,0,30}
puts $f {GRID,2002,,10,0,30}
puts $f {GRID,2011,,0,0,50}
puts $f {GRID,2012,,10,0,50}
puts $f {CBEAM,6003,6002,2001,2011,0.0,1.0,0.0}
puts $f {ENDDATA}
puts $f {}
close $f

proc importWith {prefix femPath count lastFlag} {
    catch {*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "}
    set code [catch {*feinputwithdata2 "#optistruct/optistruct" $femPath 0 0 0 0 0 1 $count 1 $lastFlag} e]
    P "${prefix}_CODE" $code
    P "${prefix}_COMPS" [dumpAll comps]
    P "${prefix}_PROPS" [dumpAll props]
    P "${prefix}_MATS" [dumpAll mats]
}

importWith M1_MODULE $fem1 2 0
P "M1_CBEAM3001_PID" [hm_getvalue elems id=3001 dataname=property.id]
P "M1_CBEAM3001_COMP" [hm_getvalue elems id=3001 dataname=collector.id]
P "M1_CBEAM3002_PID" [hm_getvalue elems id=3002 dataname=property.id]
P "M1_CBEAM3002_COMP" [hm_getvalue elems id=3002 dataname=collector.id]
P "M1_RBE22001_COMP" [hm_getvalue elems id=2001 dataname=collector.id]

# variant 2: no comments at all, module option string array
importWith M2_NOCOMMENTS $fem2 2 0
P "M2_CBEAM6003_PID" [hm_getvalue elems id=6003 dataname=property.id]
P "M2_CBEAM6003_COMP" [hm_getvalue elems id=6003 dataname=collector.id]

# 1D mark selector variants on the current model (has CBEAM/CBAR 3001/3002/6003)
foreach sel [list {"by config" 60} {"by config" 1} {"by dimension" 1} {"by dimension" 1d} \
                 {"by dim" 1} {"by type" CBEAM} {"by type" CBAR} {"by card image" CBEAM}] {
    catch {*clearmark elems 1}
    set rc [catch {eval *createmark elems 1 $sel} e]
    set sk [join $sel _]
    regsub -all {[" ]} $sk {_} sk
    P "SEL_${sk}_RC" $rc
    if {!$rc} { P "SEL_${sk}_IDS" [lsort -integer [hm_getmark elems 1]] }
}

# mark helpers for functional tests
proc createMark {etype markId ids} {
    catch {*clearmark $etype $markId}
    eval *createmark $etype $markId $ids
}
proc lastNodeId {} {
    createMark nodes 1 all
    set ids [hm_getmark nodes 1]
    lindex [lsort -integer $ids] end
}

# *replacenodes: create two coincident nodes, merge source into target
*createnode 50.0 50.0 50.0 0 0 0
set srcId [lastNodeId]
*createnode 50.0 50.0 50.0 0 0 0
set tgtId [lastNodeId]
P "REPLACE_SRC_TGT" "$srcId $tgtId"
TRY REPLACENODES [list *replacenodes $srcId $tgtId 1 0]
P "REPLACE_SRC_GONE" [expr {[catch {hm_getvalue nodes id=$srcId dataname=id}] ? 1 : 0}]
P "REPLACE_TGT_KEPT" [hm_getvalue nodes id=$tgtId dataname=id]

# *rigid: RBE2 creation from nodes
*createnode 70.0 0.0 0.0 0 0 0
set r1 [lastNodeId]
*createnode 70.0 10.0 0.0 0 0 0
set r2 [lastNodeId]
*createnode 70.0 10.0 10.0 0 0 0
set r3 [lastNodeId]
*createnode 70.0 0.0 10.0 0 0 0
set r4 [lastNodeId]
TRY RIGID_CREATE [list *rigid $r1 $r2 $r3 $r4]
createMark elems 1 all
set allElems [hm_getmark elems 1]
set newElem ""
foreach id [lsort -integer $allElems] {
    if {$id > 6003} { set newElem $id }
}
P "RIGID_NEW_ELEM" $newElem
if {$newElem ne ""} {
    TRY RIGID_CONFIG [list hm_getvalue elems id=$newElem dataname=config]
    TRY RIGID_INDEP [list hm_getvalue elems id=$newElem dataname=independentnode.id]
    TRY RIGID_NODES [list hm_getvalue elems id=$newElem dataname=nodes]
}

# *propertyupdate with populated mark
createMark elems 1 [list 3001]
TRY PROPUPDATE_ELEMS_MARKED [list *propertyupdate elems 1 BOLT_D10_PBAR]
P "PROPUPDATE_ELEMS_PID" [hm_getvalue elems id=3001 dataname=property.id]
createMark comps 1 [list 2001]
TRY PROPUPDATE_COMPS_MARKED [list *propertyupdate comps 1 BOLT_D10_PBAR]
P "PROPUPDATE_COMPS_PID" [hm_getvalue comps id=2001 dataname=property.id]

# *setvalue comps propertyid ref with an EXISTING prop
set prop1 [hm_getvalue props name=BOLT_D10_PBAR dataname=id]
P "PROP1_ID" $prop1
TRY SETVALUE_COMP_PROPREF [list *setvalue comps id=2001 STATUS=1 "propertyid={props $prop1}"]
foreach dn {property.id propertyid prop.id} {
    TRY "COMP_PROP_READ_$dn" [list hm_getvalue comps id=2001 dataname=$dn]
}
TRY SETVALUE_COMP_PROPID [list *setvalue comps id=2001 STATUS=1 "propertyid=$prop1"]
TRY COMP_PROP_READ_AFTER [list hm_getvalue comps id=2001 dataname=property.id]

# *attributeupdateentity PBAR/PBEAM links with real properties + a section
TRY SECTION_CREATE [list *beamsectioncreatestandardsolver 11 0 HMCirc 0]
set sectId ""
catch {set sectId [hm_latestentityid beamsects]}
P "SECTION_ID" $sectId
TRY ATTR_LINK_PBAR [list *attributeupdateentity properties $prop1 3179 1 2 0 beamsects $sectId]
set prop2 [hm_getvalue props name=BOLT_D12_PBEAM dataname=id]
P "PROP2_ID" $prop2
TRY ATTR_LINK_PBEAM [list *attributeupdateentity properties $prop2 3186 1 2 0 beamsects $sectId]

# *createelement nodes readback (bar2 config 1 via list+mark)
catch {*clearmark nodes 1}
catch {*createlist nodes 1}
TRY CREATEELM_LIST [list *createlist nodes 1 1001 1011]
TRY CREATEELM_MARK [list *createmark nodes 1 1001 1011]
set before [hm_latestentityid elems]
TRY CREATEELM_BAR [list *createelement 1 1 1]
set eAlt ""
catch {set eAlt [hm_latestentityid elems]}
if {$eAlt eq $before} {set eAlt ""}
P "CREATEELM_BAR_ELEM" $eAlt
if {$eAlt ne ""} {
    TRY CREATEELM_NODES [list hm_getvalue elems id=$eAlt dataname=nodes]
    TRY CREATEELM_NODE1 [list hm_getvalue elems id=$eAlt dataname=node1.id]
    TRY CREATEELM_NODE2 [list hm_getvalue elems id=$eAlt dataname=node2.id]
}

close $ch
catch {puts "import audit probe done: $reportPath"}
exit 0
