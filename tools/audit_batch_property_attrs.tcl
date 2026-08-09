# Attribute-level probe for batch_property_assignment audit: read PSHELL/MAT1
# card fields through hm_getentityvalue (the attribute reader Altair's own
# scripts use), discover the PSHELL_T and MAT1_E attribute numbers on the
# installed build, and verify *attributeupdatedouble writes plus the module's
# exact call forms.  Also verifies import fidelity of the cards-only fem.
#
# Run headless (one launch per version):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_property_attrs.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_property_attrs.tcl
#
# Results to runtime/audit_batch_property_attrs_<version>.log, ASCII KEY=VALUE.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_property_attrs_${version}.log"]
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

P "HM_VERSION" $version
P "EXISTS_GETENTITYVALUE" [expr {[llength [info commands hm_getentityvalue]] > 0}]
P "CMDS_ATTRIBUTE" [lsort [info commands *attribute*]]
P "CMDS_DATA" [lsort [info commands *data*]]

# --- A. Import cards-only fem (MAT1 + PSHELL with known values) --------------
set fixturePath [file join $outputDir "audit_bpa_fixture2.fem"]
set fh [open $fixturePath w]
fconfigure $fh -translation crlf
puts $fh "BEGIN BULK"
puts $fh "MAT1   1       210000.0       0.3    7.85E-9"
puts $fh "PSHELL 1       1       2.5     1       1"
puts $fh "ENDDATA"
close $fh
T "IMPORT" {*feinputwithdata2 "#optistruct/optistruct" [file nativename $fixturePath] 0 0 0 0 0 1 0 1 0}
catch {*clearmark mats 1}
catch {*createmark mats 1 all}
set mats [hm_getmark mats 1]
catch {*clearmark props 1}
catch {*createmark props 1 all}
set props [hm_getmark props 1]
P "MAT_IDS" [join $mats { }]
P "PROP_IDS" [join $props { }]
set mid [lindex $mats 0]
set pid [lindex $props 0]

# --- B. Baseline ASCII export (import fidelity, no writes) -------------------
set exeDir [file dirname [info nameofexecutable]]
set templatePath [file normalize [file join $exeDir .. .. .. templates feoutput optistruct optistruct]]
T "FEOUTPUT_BASE" {*feoutputwithdata [file nativename $templatePath] [file nativename [file join $outputDir "audit_bpa_base_${version}.fem"]] 0 0 2 1 0}

# --- C. Attribute discovery on MAT1 (find which attr holds E=210000) ---------
if {$mid ne ""} {
    foreach attr {1 2 3 4 5 6 7 8 9 10} {
        T "MAT_ATTR_READ_$attr" {hm_getentityvalue mats $mid $attr 0 -byid}
    }
    T "MAT_GETENTITYVALUE_NAME" {hm_getentityvalue mats $mid name 0 -byid}
    # write via attribute: try attr 1 (E candidate)
    T "MAT_ATTR1_WRITE" {*attributeupdatedouble mats $mid 1 1 1 0 222000.0}
    T "MAT_ATTR1_READ_BACK" {hm_getentityvalue mats $mid 1 0 -byid}
    T "MAT_ATTR3_WRITE" {*attributeupdatedouble mats $mid 3 1 1 0 0.33}
    T "MAT_ATTR3_READ_BACK" {hm_getentityvalue mats $mid 3 0 -byid}
    T "MAT_ATTR4_WRITE" {*attributeupdatedouble mats $mid 4 1 1 0 8.0e-9}
    T "MAT_ATTR4_READ_BACK" {hm_getentityvalue mats $mid 4 0 -byid}
    T "FEOUTPUT_MAT" {*feoutputwithdata [file nativename $templatePath] [file nativename [file join $outputDir "audit_bpa_mat_${version}.fem"]] 0 0 2 1 0}
}

# --- D. Attribute discovery on PSHELL (find which attr holds T=2.5) ----------
if {$pid ne ""} {
    foreach attr {90 91 92 93 94 95 96 97 98 99 100} {
        T "PROP_ATTR_READ_$attr" {hm_getentityvalue props $pid $attr 0 -byid}
    }
    # module's exact write form: attr 95, 7 args
    T "PROP_ATTR95_WRITE_MODULE" {*attributeupdatedouble properties $pid 95 1 1 0 3.0}
    T "PROP_ATTR95_READ_BACK" {hm_getentityvalue props $pid 95 0 -byid}
    T "PROP_GETTHICKNESS" {hm_getthickness props $pid}
    T "FEOUTPUT_PROP" {*feoutputwithdata [file nativename $templatePath] [file nativename [file join $outputDir "audit_bpa_prop_${version}.fem"]] 0 0 2 1 0}
}

# --- E. module-exact flows on imported entities ------------------------------
if {$mid ne "" && $pid ne ""} {
    # material link (module's trySetValue)
    T "SET_MATERIALID" {*setvalue props id=$pid STATUS=1 materialid=$mid}
    T "READ_MATERIALID" {hm_getvalue props id=$pid dataname=materialid}
    # propertyupdate by name (module's assignProperty)
    set propName ""
    catch {set propName [hm_getvalue props id=$pid dataname=name]}
    P "PROP_NAME" $propName
    set targetId ""
    catch {set targetId [hm_getvalue comps name=comp_1 dataname=id]}
    if {$targetId eq ""} {
        catch {*createentity comps includeid=0 name=AUDIT_TARGET}
        catch {set targetId [hm_getvalue comps name=AUDIT_TARGET dataname=id]}
    }
    P "TARGET_ID" $targetId
    if {$targetId ne ""} {
        catch {*clearmark comps 1}
        T "MARK_TARGET" {*createmark comps 1 $targetId}
        T "PROPUPDATE" {*propertyupdate comps 1 $propName}
        T "PROPUPDATE_READBACK" {hm_getvalue comps id=$targetId dataname=propertyid}
        T "PROPERTY_READ" {hm_getvalue comps id=$targetId dataname=property}
        catch {*clearmark comps 1}
    }
}

close $channel
exit 0
