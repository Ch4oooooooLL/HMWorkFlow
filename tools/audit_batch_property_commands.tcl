# Audit probe for modules/batch_property_assignment.tcl native HyperMesh
# commands.  Verifies on the real installed build: command existence,
# entity-type aliases, *EntityPreviewEmpty semantics, MAT1/PSHELL creation
# and field writes, *attributeupdatedouble 95 (PSHELL_T), *propertyupdate,
# and name lookups.
#
# Run headless (one launch per version, shared license so keep it minimal):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_property_commands.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_property_commands.tcl
#
# hmbatch has no stdout channel: everything goes to
# runtime/audit_batch_property_<version>.log as KEY=VALUE ASCII lines.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_property_${version}.log"]
set channel [open $reportPath w]

proc P {key args} {
    variable channel
    set value [join $args " "]
    set value [string map [list "\"" "" "\n" " " "\r" " " "," "_"] $value]
    puts $channel "${key}=${value}"
}

proc T {key script} {
    variable channel
    set code [catch {uplevel 1 $script} msg]
    set msg [string map [list "\n" " " "\r" " " "," "_"] $msg]
    puts $channel "${key}_CODE=$code"
    puts $channel "${key}_MSG=$msg"
    return $code
}

proc E {name} {
    expr {[info commands $name] ne ""}
}

proc N {x y z} {
    # create one node, return its id
    catch {*createnode $x $y $z 0 0 0}
    catch {*createmark nodes 1 -1}
    set ids [hm_getmark nodes 1]
    return [lindex $ids end]
}

namespace eval ::Audit {
    variable comps {}
    variable matId ""
    variable propId ""
}

# --- 1. Command existence --------------------------------------------------
foreach name {
    *EntityPreviewEmpty *propertyupdate *attributeupdatedouble
    *attributeupdateint *attributeupdatestring
    hm_getthickness hm_getvalue hm_getmark hm_entityinfo hm_setvalue
    *createentity *setvalue *createmark *clearmark
    *collectorcreateonly *currentcollector *createnode *createelement
    *createlist *renamecollector *assemblyaddmark *startnotehistorystate
    *propertycreate
} {
    P "EXISTS $name" [E $name]
}

# --- 2. Fixture: components with different content --------------------------
# C_FULL  : quad elements
# C_NODES : nodes only (no elements, no geometry)
# C_LINE  : one line element (no quad)
# C_BEAM  : rod elements (1D)
# C_EMPTY : nothing at all
# C_TARGET: empty, used later for *propertyupdate
foreach {cname color} {
    C_FULL 1 C_NODES 2 C_LINE 3 C_BEAM 4 C_EMPTY 5 C_TARGET 6
} {
    set rc [catch {*collectorcreateonly comps $cname "" $color} cerr]
    set id ""
    if {!$rc} { catch {set id [hm_getvalue comps name=$cname dataname=id]} }
    P "FIXTURE_COMP $cname CREATE_CODE=$rc ID=$id ERR=$cerr"
    if {!$rc} { lappend ::Audit::comps $id }
}

# C_FULL: 4 quads
*currentcollector component C_FULL
set n0 [N 0 0 0]
set n1 [N 10 0 0]
set n2 [N 10 10 0]
set n3 [N 0 10 0]
if {[llength [list $n0 $n1 $n2 $n3]] == 4} {
    catch {*createlist nodes 1 [list $n0 $n1 $n2 $n3]}
    P "FIXTURE_QUAD_CREATE" [catch {*createelement 104 1 1 1}]
}

# C_NODES: 2 nodes only
*currentcollector component C_NODES
set dn1 [N 100 0 0]
set dn2 [N 100 10 0]

# C_LINE: one 2-node line element
*currentcollector component C_LINE
set ln1 [N 200 0 0]
set ln2 [N 200 10 0]
catch {*createlist nodes 1 [list $ln1 $ln2]}
P "FIXTURE_LINE_CREATE" [catch {*createelement 1 1 1}]

# C_BEAM: two rod elements
*currentcollector component C_BEAM
set rn1 [N 300 0 0]
set rn2 [N 300 10 0]
set rn3 [N 300 20 0]
catch {*createlist nodes 1 [list $rn1 $rn2]}
set rc1 [catch {*createelement 41 1 1 1}]
catch {*createlist nodes 1 [list $rn2 $rn3]}
set rc2 [catch {*createelement 41 1 1 1}]
P "FIXTURE_ROD_CREATE" "$rc1/$rc2"

# Element counts per component (mark-based, independent of dataname guesses)
foreach id $::Audit::comps {
    catch {*clearmark elems 1}
    set rc [catch {*createmark elems 1 "by comp" $id}]
    if {$rc} { set count -1 } else { set count [llength [hm_getmark elems 1]] }
    set name [hm_getvalue comps id=$id dataname=name]
    P "ELEMCOUNT $name" $count
}

# --- 3. Entity type aliases -------------------------------------------------
foreach alias {comps components comp} {
    set rc [catch {*createmark $alias 1 all}]
    if {$rc} { P "ALIAS $alias" "FAIL: $rc" } else { P "ALIAS $alias" "OK count=[llength [hm_getmark $alias 1]]" }
    catch {*clearmark $alias 1}
}
foreach alias {mats materials mat} {
    set rc [catch {*createmark $alias 1 all}]
    if {$rc} { P "ALIAS $alias" "FAIL: $rc" } else { P "ALIAS $alias" "OK count=[llength [hm_getmark $alias 1]]" }
    catch {*clearmark $alias 1}
}
foreach alias {props properties property} {
    set rc [catch {*createmark $alias 1 all}]
    if {$rc} { P "ALIAS $alias" "FAIL: $rc" } else { P "ALIAS $alias" "OK count=[llength [hm_getmark $alias 1]]" }
    catch {*clearmark $alias 1}
}

# --- 4. *EntityPreviewEmpty (module usage: clear mark 2, call, read mark 2) --
catch {*clearmark comps 2}
T "PREVIEW_EMPTY_NO_SEED" {*EntityPreviewEmpty comps 2}
P "PREVIEW_EMPTY_NO_SEED_MARK" [lsort -integer [hm_getmark comps 2]]

# alias variant
catch {*clearmark components 2}
T "PREVIEW_EMPTY_ALIAS" {*EntityPreviewEmpty components 2}
P "PREVIEW_EMPTY_ALIAS_MARK" [lsort -integer [hm_getmark components 2]]

# seeded-mark variant: does a pre-populated mark 2 change the result?
catch {*clearmark comps 2}
catch {*createmark comps 2 all}
T "PREVIEW_EMPTY_SEEDED" {*EntityPreviewEmpty comps 2}
P "PREVIEW_EMPTY_SEEDED_MARK" [lsort -integer [hm_getmark comps 2]]
catch {*clearmark comps 2}

# --- 5. MAT1 creation and field writes --------------------------------------
T "CREATE_MAT" {*createentity mats cardimage=MAT1 includeid=0 name=AUDIT_MAT}
T "CREATE_MAT_ALIAS" {*createentity materials cardimage=MAT1 includeid=0 name=AUDIT_MAT2}
T "MAT_ID_BY_NAME" {set ::Audit::matId [hm_getvalue mats name=AUDIT_MAT dataname=id]}
set matId $::Audit::matId
P "MAT_ID_VALUE" $matId
if {$matId ne ""} {
    T "MAT_NAME_READBACK" {hm_getvalue mats id=$matId dataname=name}
    T "MAT_SET_E" {*setvalue mats id=$matId E=210000.0}
    T "MAT_READ_E" {hm_getvalue mats id=$matId dataname=E}
    T "MAT_READ_E_NUM" {hm_getvalue mats id=$matId dataname=1}
    T "MAT_SET_CARDIMAGE" {*setvalue mats id=$matId cardimage=MAT1}
}

# --- 6. PSHELL creation, material link, thickness ---------------------------
T "CREATE_PROP" {*createentity props cardimage=PSHELL includeid=0 name=AUDIT_PROP}
T "CREATE_PROP_ALIAS" {*createentity properties cardimage=PSHELL includeid=0 name=AUDIT_PROP2}
T "PROP_ID_BY_NAME" {set ::Audit::propId [hm_getvalue props name=AUDIT_PROP dataname=id]}
set propId $::Audit::propId
P "PROP_ID_VALUE" $propId
if {$propId ne "" && $matId ne ""} {
    T "PROP_SET_MATERIALID" {*setvalue props id=$propId materialid=$matId}
    foreach dn {materialid material.id material MID mid} {
        T "PROP_READ $dn" {hm_getvalue props id=$propId dataname=$dn}
    }
    # thickness via named field "T"
    T "PROP_SET_T" {*setvalue props id=$propId T=2.5}
    T "PROP_READ_T" {hm_getvalue props id=$propId dataname=T}
    T "PROP_READ_THICKNESS_DN" {hm_getvalue props id=$propId dataname=thickness}
    T "PROP_SET_THICKNESS_FIELD" {*setvalue props id=$propId thickness=2.75}
    T "PROP_READ_T_AFTER" {hm_getvalue props id=$propId dataname=T}
    # attribute 95 (PSHELL_T) exactly as the module calls it
    T "ATTR95_PROPERTIES" {*attributeupdatedouble properties $propId 95 1 1 0 3.0}
    T "ATTR95_PROPS_ALIAS" {*attributeupdatedouble props $propId 95 1 1 0 3.25}
    T "GETTHICKNESS_PROPS" {hm_getthickness props $propId}
    T "GETTHICKNESS_PROPERTIES" {hm_getthickness properties $propId}
    T "PROP_READ_T_FINAL" {hm_getvalue props id=$propId dataname=T}
    T "PROP_READ_MID_FINAL" {hm_getvalue props id=$propId dataname=materialid}
}

# --- 7. *propertyupdate and *setvalue propertyid ----------------------------
set targetId ""
catch {set targetId [hm_getvalue comps name=C_TARGET dataname=id]}
P "TARGET_COMP_ID" $targetId
if {$targetId ne "" && $propId ne ""} {
    foreach dn {propertyid property.id property prop.id} {
        T "TARGET_READ_BEFORE $dn" {hm_getvalue comps id=$targetId dataname=$dn}
    }
    catch {*clearmark comps 1}
    T "MARK_TARGET" {*createmark comps 1 $targetId}
    T "PROPUPDATE_BY_NAME" {*propertyupdate comps 1 AUDIT_PROP}
    T "PROPUPDATE_READBACK" {hm_getvalue comps id=$targetId dataname=propertyid}
    catch {*clearmark comps 1}
    T "MARK_TARGET_2" {*createmark comps 1 $targetId}
    T "PROPUPDATE_BY_ID" {*propertyupdate comps 1 $propId}
    T "PROPUPDATE_ID_READBACK" {hm_getvalue comps id=$targetId dataname=propertyid}
    catch {*clearmark comps 1}
    T "MARK_TARGET_3" {*createmark components 1 $targetId}
    T "PROPUPDATE_ALIAS" {*propertyupdate components 1 AUDIT_PROP}
    T "PROPUPDATE_ALIAS_READBACK" {hm_getvalue comps id=$targetId dataname=propertyid}
    # *setvalue propertyid fallback
    T "SETVALUE_PROPERTYID" {*setvalue comps id=$targetId propertyid=$propId}
    T "SETVALUE_PROPERTYID_READBACK" {hm_getvalue comps id=$targetId dataname=propertyid}
    catch {*clearmark comps 1}
    catch {*clearmark components 1}
}

# --- 8. Name lookups --------------------------------------------------------
if {$targetId ne ""} {
    T "ENTITYINFO_ID_BYNAME" {hm_entityinfo id comps C_TARGET -byname}
    T "ENTITYINFO_ID_LOWERCASE" {hm_entityinfo id comps c_target -byname}
    T "GETVALUE_NAME_LOOKUP" {hm_getvalue comps name=C_TARGET dataname=id}
    T "GETVALUE_NAME_LOWERCASE" {hm_getvalue comps name=c_target dataname=id}
}
if {$propId ne ""} {
    T "ENTITYINFO_PROP" {hm_entityinfo id props AUDIT_PROP -byname}
}

close $channel
exit 0
