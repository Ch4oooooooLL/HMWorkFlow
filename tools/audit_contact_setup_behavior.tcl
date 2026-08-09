# ============================================================================
# Contact Setup module - follow-up behavioral probe.
#
# Disambiguates findings from audit_contact_setup_commands.tcl:
#   1. *contactsurfcreatewithshells with reverse_normals=1 on a fresh element
#   2. *contactsurfcreatewithshells on elements already in another surface
#   3. *adjustcontactsurfacenormal argument mapping
#   4. full CONTACT group chain (master/slave set, dataname reads, TYPE write)
#   5. *movemark through a "by comp id" element mark
#   6. history/undo of *removeelemsfromcontactsurf
#   7. end-to-end OptiStruct export with a fully populated group
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_contact_setup_behavior.tcl
# Results: runtime/audit_contact_setup_behavior_<version>.log (KEY=VALUE).
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_contact_setup_behavior_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    set text [string map {"\n" " " "\r" " "} $value]
    puts $channel "${key}=${text}"
    flush $channel
}
proc TRY {key script} {
    set code [catch {uplevel 1 $script} result]
    if {$code} {
        P $key "ERROR: $result"
    } else {
        P $key "OK: $result"
    }
}

P "AUDIT_TOPIC" "contact_setup_behavior"
P "VERSION" $version

set templatePath [file normalize [file join [hm_info -appinfo EXECUTABLEDIR] \
    .. .. .. templates feoutput optistruct optistruct]]
P "TEMPLATE_PATH_EXISTS" [expr {[file isfile $templatePath] ? "yes" : "no"}]
if {[file isfile $templatePath]} {
    catch {*templatefileset $templatePath}
}
P "TEMPLATE_TYPE_NOW" [string trim [hm_info templatetype]]

namespace eval ::Audit {}
proc ::Audit::node {x y z} {
    *createnode $x $y $z 0 0 0
    return [hm_latestentityid nodes]
}
proc ::Audit::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    return [hm_latestentityid elems]
}
proc ::Audit::hex {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 208 1 1 1
    return [hm_latestentityid elems]
}

# --- fixture: quads A (z=0) and B (z=1) in one comp, hex in another ---------
*collectorcreateonly components AUDIT_SHELL "" 11
*currentcollector component AUDIT_SHELL
set elemA [::Audit::quad [list [::Audit::node 0 0 0] [::Audit::node 10 0 0] \
    [::Audit::node 10 10 0] [::Audit::node 0 10 0]]]
set elemB [::Audit::quad [list [::Audit::node 0 0 1] [::Audit::node 10 0 1] \
    [::Audit::node 10 10 1] [::Audit::node 0 10 1]]]
*collectorcreateonly components AUDIT_SOLID "" 12
*currentcollector component AUDIT_SOLID
set hexE [::Audit::hex [list [::Audit::node 0 0 0] [::Audit::node 10 0 0] \
    [::Audit::node 10 10 0] [::Audit::node 0 10 0] \
    [::Audit::node 0 0 10] [::Audit::node 10 0 10] \
    [::Audit::node 10 10 10] [::Audit::node 0 10 10]]]
set shellCompId [hm_getvalue comps name=AUDIT_SHELL dataname=id]
set solidCompId [hm_getvalue comps name=AUDIT_SOLID dataname=id]
P "ELEM_A" $elemA
P "ELEM_B" $elemB
P "ELEM_HEX" $hexE
P "COMP_SHELL" $shellCompId
P "COMP_SOLID" $solidCompId

# --- 1. reverse_normals=1 on a fresh element --------------------------------
catch {*clearmark elems 1}
eval *createmark elems 1 $elemB
TRY "CS_REV1_FRESH_ELEM" {*contactsurfcreatewithshells AUDIT_REV 45 1 1}
set revId ""
catch {set revId [hm_entityinfo id contactsurfs AUDIT_REV -byname]}
P "CS_REV1_ID" $revId
if {$revId ne ""} {
    TRY "CS_REV1_CARDIMAGE" [list hm_getvalue contactsurfs id=$revId dataname=cardimage]
    TRY "CS_REV1_ELEMENTS" [list hm_getvalue contactsurfs id=$revId dataname=elements]
}

# --- 2. creation from elements already in another surface -------------------
catch {*clearmark elems 1}
eval *createmark elems 1 $elemB
TRY "CS_REUSE_ELEM" {*contactsurfcreatewithshells AUDIT_DUP 46 1 0}

# --- 3. 3-arg creation form (reverse omitted) -------------------------------
catch {*clearmark elems 1}
eval *createmark elems 1 $elemA
TRY "CS_3ARG" {*contactsurfcreatewithshells AUDIT_TRI 47 1}
set triId ""
catch {set triId [hm_entityinfo id contactsurfs AUDIT_TRI -byname]}
P "CS_3ARG_ID" $triId

# --- 4. *adjustcontactsurfacenormal argument mapping ------------------------
catch {*clearmark elems 1}
eval *createmark elems 1 $elemA $elemB
TRY "ADJUST_BAD_ELEM_POS3" {*adjustcontactsurfacenormal AUDIT_REV 1 999999 1}
TRY "ADJUST_BAD_MARK_POS2" {*adjustcontactsurfacenormal AUDIT_REV 999999 1 $elemA 1}
TRY "ADJUST_BAD_REVERSE_POS4" {*adjustcontactsurfacenormal AUDIT_REV 1 $elemA 999999}
TRY "ADJUST_MODULE_5ARG" {*adjustcontactsurfacenormal AUDIT_REV 1 1 $elemA 1}
TRY "ADJUST_4ARG" {*adjustcontactsurfacenormal AUDIT_REV 1 $elemA 1}

# --- 5. CONTACT group chain --------------------------------------------------
# delete any pre-existing group, then create fresh
catch {*clearmark groups 2}
TRY "GROUP_MARK_BYNAME" {*createmark groups 2 "by name only" AUDIT_CONTACT}
P "GROUP_MARK_BYNAME_LEN" [hm_marklength groups 2]
if {[hm_marklength groups 2] > 0} {
    TRY "GROUP_DELETE_PREEXISTING" {*deletemark groups 2}
}
TRY "GROUP_CREATE" {*createentity groups name=AUDIT_CONTACT cardimage=CONTACT}
set gid ""
catch {set gid [hm_entityinfo id groups AUDIT_CONTACT -byname]}
P "GROUP_ID" $gid
if {$gid ne ""} {
    TRY "GROUP_MASTER_SET" {*setvalue groups id=$gid masterentityids={contactsurfs $revId}}
    TRY "GROUP_SLAVE_SET" {*setvalue groups id=$gid slaveentityids={contactsurfs $triId}}
    foreach dn {cardimage maincontactsurflist mastercontactsurflist secondarycontactsurflist \
                slavecontactsurflist maindefinition masterdefinition secondarydefinition slavedefinition} {
        TRY "GROUP_${dn}" [list hm_getvalue groups id=$gid dataname=$dn]
    }
    TRY "GROUP_ATTRLIST_NAME_BYID" [list hm_attributelist groups $gid name -byid]
    TRY "ATTRID_FROMNAME_TYPE" {hm_attributeidfromname TYPE}
    TRY "ATTRID_FROMNAME_CONTACT_PROP_TYPE" {hm_attributeidfromname CONTACT_PROP_TYPE}
    TRY "GROUP_TYPE_CPT_WRITE" {*setvalue groups id=$gid STATUS=2 CONTACT_PROP_TYPE=STICK}
    TRY "GROUP_TYPE_CPT_READ" [list hm_getvalue groups id=$gid dataname=CONTACT_PROP_TYPE]
    TRY "GROUP_TYPE_TYPE_WRITE" {*setvalue groups id=$gid STATUS=2 TYPE=SLIDE}
    TRY "GROUP_TYPE_TYPE_READ" [list hm_getvalue groups id=$gid dataname=TYPE]
    TRY "GROUP_TYPE_CPT_READ_AFTER_TYPE" [list hm_getvalue groups id=$gid dataname=CONTACT_PROP_TYPE]
}

# --- 6. *movemark through "by comp id" element mark --------------------------
catch {*clearmark comps 1}
*createmark comps 1 $solidCompId
TRY "FINDFACES" {*findfaces components 1}
set facesId ""
catch {set facesId [hm_entityinfo id comps ^faces -byname]}
P "FACES_COMP_ID" $facesId
if {$facesId ne ""} {
    catch {*clearmark elems 2}
    TRY "MARK_FACES_BY_COMP_ID" [list *createmark elems 2 "by comp id" $facesId]
    P "MARK_FACES_BY_COMP_ID_LEN" [hm_marklength elems 2]
    set faceElems {}
    catch {set faceElems [hm_getmark elems 2]}
    P "FACES_ELEM_COUNT" [llength $faceElems]
    if {[llength $faceElems] > 0} {
        *collectorcreateonly components AUDIT_FACES_TMP "" 35
        TRY "MOVEMARK_BY_NAME" {*movemark elems 2 AUDIT_FACES_TMP}
        TRY "TMP_COMP_ELEMS_VERIFY" [list hm_getvalue comps name=AUDIT_FACES_TMP dataname=elements]
    }
}

# --- 7. history/undo of *removeelemsfromcontactsurf --------------------------
if {$revId ne ""} {
    catch {*clearmark elems 1}
    eval *createmark elems 1 $elemB
    TRY "UNDO_ADD" {*addshellstocontactsurf AUDIT_REV 1}
    TRY "UNDO_BEFORE" [list hm_getvalue contactsurfs id=$revId dataname=elements]
    TRY "UNDO_HIST_START" {*startnotehistorystate AUDIT_HIST2}
    TRY "UNDO_REMOVE" {*removeelemsfromcontactsurf AUDIT_REV 1}
    TRY "UNDO_AFTER_REMOVE" [list hm_getvalue contactsurfs id=$revId dataname=elements]
    TRY "UNDO_HIST_END" {*endnotehistorystate AUDIT_HIST2}
    TRY "UNDO_HIST_UNDO" {*undohistorystate 1}
    TRY "UNDO_AFTER_UNDO" [list hm_getvalue contactsurfs id=$revId dataname=elements]
}

# --- 8. end-to-end export ----------------------------------------------------
set deckPath [file join $outputDir "audit_contact_setup_behavior_${version}.fem"]
if {[file exists $deckPath]} { file delete -force $deckPath }
if {[catch {*feoutputwithdata $templatePath $deckPath 0 0 1 1 0} eErr]} {
    P "EXPORT" "ERROR: $eErr"
} else {
    P "EXPORT" "ok"
}
if {[file isfile $deckPath]} {
    set fh [open $deckPath r]
    set deck [read $fh]
    close $fh
    P "EXPORT_SURF_CARD" [expr {[regexp -line {^[ \t]*SURF[ \t,]} $deck] ? "yes" : "no"}]
    P "EXPORT_CONTACT_CARD" [expr {[regexp -line {^[ \t]*CONTACT[ \t,]} $deck] ? "yes" : "no"}]
    P "EXPORT_STICK" [expr {[regexp -line {^[ \t]*CONTACT[ \t]+[0-9]+[ \t]+STICK([ \t]|$)} $deck] ? "yes" : "no"}]
    foreach line [split $deck "\n"] {
        if {[regexp {^[ \t]*(CONTACT|SURF)[ \t,]} $line]} {
            P "EXPORT_CARD_LINE" [string trim $line]
        }
    }
}

close $channel
exit 0
