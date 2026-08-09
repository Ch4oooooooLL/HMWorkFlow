# ============================================================================
# Final targeted probe: PBAR property creation under OptiStruct template.
# The main audit only tested cardimage=PBEAM; the repl probe tested PBAR in
# the DEFAULT profile (no template) where the command throws
# "supports OptiStruct & Nastran User Profile only" but STILL creates the
# entity (cardimage=<None>).  The module's PBAR path (bolt D10 CBAR) runs in
# a real session with OptiStruct/Nastran profile, so verify:
#   1. *createentity props cardimage=PBAR with template set
#   2. module fallback *createentity properties cardimage=PBAR
#   3. *setvalue cardimage recovery on a bare-created prop
#   4. section link (3179) + sync on a REAL PBAR
# Results: runtime/audit_rbe2_bolt_connector_pbar_<version>.log
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_rbe2_bolt_connector_pbar_${version}.log"]
set ch [open $reportPath w]
fconfigure $ch -translation lf

proc P {key value} {
    variable ch
    regsub -all {[\r\n]} $value { } value
    puts $ch "${key}=${value}"
    flush $ch
}
proc TRY {prefix script} {
    variable ch
    if {[catch {uplevel 1 $script} result options]} {
        P "${prefix}_RC" 1
        P "${prefix}_ERR" $result
    } else {
        P "${prefix}_RC" 0
        P "${prefix}_VAL" [string trim $result]
    }
}

P "VERSION" $version
set executableDir [hm_info -appinfo EXECUTABLEDIR]
set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
catch {*templatefileset $templatePath} tErr
P "TEMPLATE" [string trim [hm_info templatetype]]

# 1. module-style creation with template set
set err1 ""
set rc1 [catch {*createentity props cardimage=PBAR includeid=0 name=AUDIT_PBAR_T} err1]
P "CREATE_PBAR_TEMPLATE_RC" $rc1
P "CREATE_PBAR_TEMPLATE_ERR" $err1
set pbid ""
catch {set pbid [hm_getvalue props name=AUDIT_PBAR_T dataname=id]}
P "CREATE_PBAR_TEMPLATE_ID" $pbid
if {$pbid ne ""} {
    TRY PBAR_T_CARDIMAGE [list hm_getvalue props id=$pbid dataname=cardimage]
    TRY PBAR_T_MATREF [list hm_getvalue props id=$pbid dataname=materialid]
}

# 2. module fallback *createentity properties (only if the first path threw)
if {$rc1} {
    set err2 ""
    set rc2 [catch {*createentity properties cardimage=PBAR includeid=0 name=AUDIT_PBAR_F} err2]
    P "CREATE_PBAR_FALLBACK_RC" $rc2
    P "CREATE_PBAR_FALLBACK_ERR" $err2
    set pbid2 ""
    catch {set pbid2 [hm_getvalue props name=AUDIT_PBAR_F dataname=id]}
    P "CREATE_PBAR_FALLBACK_ID" $pbid2
    if {$pbid2 ne ""} {
        TRY PBAR_F_CARDIMAGE [list hm_getvalue props id=$pbid2 dataname=cardimage]
    }
}

# 3. setvalue cardimage recovery on a bare prop (created without card image)
catch {*createentity props includeid=0 name=AUDIT_PBAR_BARE}
set pbid3 ""
catch {set pbid3 [hm_getvalue props name=AUDIT_PBAR_BARE dataname=id]}
P "CREATE_PBAR_BARE_ID" $pbid3
if {$pbid3 ne ""} {
    TRY BARE_BEFORE_CARD [list hm_getvalue props id=$pbid3 dataname=cardimage]
    TRY BARE_SETVALUE_CARD [list *setvalue props id=$pbid3 cardimage=PBAR]
    TRY BARE_AFTER_CARD [list hm_getvalue props id=$pbid3 dataname=cardimage]
    TRY BARE_AFTER_A [list hm_getvalue props id=$pbid3 dataname=A]
}

# 4. full PBAR chain: section + link (3179) + sync on a REAL PBAR
TRY SECTION_CREATE [list *beamsectioncreatestandardsolver 11 0 HMCirc 0]
set sectId ""
catch {set sectId [hm_latestentityid beamsects]}
P "SECTION_ID" $sectId
set collId ""
catch {set collId [hm_getvalue beamsects id=$sectId dataname=setid]}
TRY SECTION_DATAROOT [list *beamsectionsetdataroot $sectId $collId 0 2 7 1 0 1.0 1.0 0 0 0 0]
TRY SECTION_DOUBLEARRAY [list *createdoublearray 3 6.0 0.006 6000.0]
TRY SECTION_DATASET [list *beamsectionsetdatastandard 1 3 $sectId 11 0 HMCirc]
if {$pbid ne ""} {
    TRY ATTR_LINK_3179 [list *attributeupdateentity properties $pbid 3179 1 2 0 beamsects $sectId]
    catch {*clearmark props 1}
    TRY SYNC_MARK [list *createmark props 1 $pbid]
    TRY SYNC_PROP [list *syncpropertybeamsectionvalues 1]
    foreach dn {A I1 I2 J} {
        TRY "PBAR_AFTERSYNC_$dn" [list hm_getvalue props id=$pbid dataname=$dn]
    }
}

close $ch
catch {puts "pbar probe done: $reportPath"}
exit 0
