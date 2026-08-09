# ============================================================================
# Contact Setup module - argument-mapping disambiguation probe.
#
# Answers two questions left open by the first probes:
#   T1-T3: does *contactsurfcreatewithshells fail when the same element mark
#          is reused for a second creation, or when elements already belong
#          to another contact surface?  (Explains the "ERROR: 0" seen when
#          two creations shared one mark.)
#   A1-A6: what is the real argument order of *adjustcontactsurfacenormal,
#          and is the module's 5-arg call (name, 1, 1, elem, reverse) safe?
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_contact_setup_adjust.tcl
# Results: runtime/audit_contact_setup_adjust_<version>.log (KEY=VALUE).
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_contact_setup_adjust_${version}.log"]
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

P "AUDIT_TOPIC" "contact_setup_adjust_mapping"
P "VERSION" $version

set templatePath [file normalize [file join [hm_info -appinfo EXECUTABLEDIR] \
    .. .. .. templates feoutput optistruct optistruct]]
if {[file isfile $templatePath]} {
    catch {*templatefileset $templatePath}
}

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

*collectorcreateonly components AUDIT_SHELL "" 11
*currentcollector component AUDIT_SHELL
set elemA [::Audit::quad [list [::Audit::node 0 0 0] [::Audit::node 10 0 0] \
    [::Audit::node 10 10 0] [::Audit::node 0 10 0]]]
set elemB [::Audit::quad [list [::Audit::node 0 0 1] [::Audit::node 10 0 1] \
    [::Audit::node 10 10 1] [::Audit::node 0 10 1]]]
set elemC [::Audit::quad [list [::Audit::node 0 0 2] [::Audit::node 10 0 2] \
    [::Audit::node 10 10 2] [::Audit::node 0 10 2]]]
P "ELEM_A" $elemA
P "ELEM_B" $elemB
P "ELEM_C" $elemC

# --- T1: one mark, two back-to-back creations (probe-1 failure repro) -------
catch {*clearmark elems 1}
eval *createmark elems 1 $elemA $elemB
TRY "T1_CREATE_X" {*contactsurfcreatewithshells AUDIT_T1_X 21 1 0}
TRY "T1_CREATE_Y_SAME_MARK" {*contactsurfcreatewithshells AUDIT_T1_Y 22 1 1}

# --- T2: same pair, but re-create the mark between the calls ----------------
catch {*clearmark elems 1}
eval *createmark elems 1 $elemA $elemB
TRY "T2_CREATE_X" {*contactsurfcreatewithshells AUDIT_T2_X 23 1 0}
catch {*clearmark elems 1}
eval *createmark elems 1 $elemA $elemB
TRY "T2_CREATE_Y_FRESH_MARK" {*contactsurfcreatewithshells AUDIT_T2_Y 24 1 1}

# --- T3: reverse flag first, then plain, same mark ---------------------------
catch {*clearmark elems 1}
eval *createmark elems 1 $elemA $elemB
TRY "T3_CREATE_X_REV1" {*contactsurfcreatewithshells AUDIT_T3_X 25 1 1}
TRY "T3_CREATE_Y_SAME_MARK" {*contactsurfcreatewithshells AUDIT_T3_Y 26 1 0}

# --- reference surface for the adjust probes ---------------------------------
catch {*clearmark elems 1}
eval *createmark elems 1 $elemA $elemB
TRY "ADJ_SURF_CREATE" {*contactsurfcreatewithshells AUDIT_ADJ 13 1 0}
set adjId ""
catch {set adjId [hm_entityinfo id contactsurfs AUDIT_ADJ -byname]}
P "ADJ_SURF_ID" $adjId

# --- A1-A6: *adjustcontactsurfacenormal argument mapping ---------------------
# candidate signature (name, mark_id, elem_id, reverse_flag); A5/A6 use the
# module's exact 5-arg call with a non-trivial element id.
catch {*clearmark elems 1}
eval *createmark elems 1 $elemA $elemB
TRY "A1_ADJUST_4ARG_REV0" {*adjustcontactsurfacenormal AUDIT_ADJ 1 1 0}
TRY "A2_ADJUST_4ARG_REV2" {*adjustcontactsurfacenormal AUDIT_ADJ 1 1 2}
TRY "A3_ADJUST_4ARG_ELEM0" {*adjustcontactsurfacenormal AUDIT_ADJ 1 0 1}
TRY "A4_ADJUST_3ARG_ELEM0" {*adjustcontactsurfacenormal AUDIT_ADJ 1 0}
TRY "A5_ADJUST_MODULE_ELEM2_REV0" {*adjustcontactsurfacenormal AUDIT_ADJ 1 1 $elemB 0}
TRY "A6_ADJUST_MODULE_ELEM2_REV1" {*adjustcontactsurfacenormal AUDIT_ADJ 1 1 $elemB 1}

# --- G: group definition-mode behavior after typed entity write --------------
catch {*clearmark groups 2}
*createmark groups 2 "by name only" AUDIT_G1
if {[hm_marklength groups 2] > 0} { *deletemark groups 2 }
TRY "G1_GROUP_CREATE" {*createentity groups name=AUDIT_G1 cardimage=CONTACT}
set g1 ""
catch {set g1 [hm_entityinfo id groups AUDIT_G1 -byname]}
set s1 ""
catch {set s1 [hm_entityinfo id contactsurfs AUDIT_ADJ -byname]}
P "G1_GROUP_ID" $g1
P "G1_SURF_ID" $s1
if {$g1 ne "" && $s1 ne ""} {
    TRY "G1_MASTER_SET" {*setvalue groups id=$g1 masterentityids={contactsurfs $s1}}
    TRY "G1_MASTERDEF_READ" [list hm_getvalue groups id=$g1 dataname=masterdefinition]
    TRY "G1_MASTERDEF_WRITE_5" {*setvalue groups id=$g1 masterdefinition=5}
    TRY "G1_MASTERDEF_READ_AFTER_WRITE" [list hm_getvalue groups id=$g1 dataname=masterdefinition]
    TRY "G1_MASTERREF_READ" [list hm_getvalue groups id=$g1 dataname=mastercontactsurflist]
    TRY "G1_MASTERDEF_WRITE_5_WITH_ENTITY" {*setvalue groups id=$g1 masterdefinition=5 masterentityids={contactsurfs $s1}}
    TRY "G1_MASTERDEF_READ_AFTER_WRITE2" [list hm_getvalue groups id=$g1 dataname=masterdefinition]
    TRY "G1_MASTERREF_READ_AFTER_WRITE2" [list hm_getvalue groups id=$g1 dataname=mastercontactsurflist]
}

close $channel
exit 0
