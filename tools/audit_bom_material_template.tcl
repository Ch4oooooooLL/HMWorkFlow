# Follow-up audit for bom_material_assignment.tcl: re-test MAT1 card-field
# writes (*setvalue E/Nu/Rho + numeric 1/3/4, cardimage) WITH the OptiStruct
# template loaded, because the first probe ran under hmbatch's default
# template where MAT1 card data names do not exist (cardimage=<None>).
# Also exercises the real module (ensureQ355Material) under the template and
# probes hm_entitylist as the official name-lookup alternative.
#
# Run:
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_bom_material_template.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_bom_material_template.tcl
#
# Results: runtime/audit_bom_material_tpl_<version>.log (KEY=VALUE, ASCII).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_bom_material_tpl_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    regsub -all {[\r\n]+} $value " | " value
    puts $channel "${key}=${value}"
}

proc TRY {label script} {
    set code [catch {uplevel 1 $script} result]
    if {$code == 0} {
        P "$label" "OK:[string trim $result]"
    } else {
        regsub -all {[\r\n]+} $result " | " result
        P "$label" "ERR:$result"
    }
}

P "HM_VERSION" $version

# --- 1. Load OptiStruct template ---------------------------------------------
if {[string match "19*" $version]} {
    set tplPath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
} else {
    set tplPath "D:/Program Files/Altair/hwdesktop/templates/feoutput/optistruct/optistruct"
}
P "TPL_FILE_EXISTS" [file exists $tplPath]
TRY "TPL_TEMPLATEFILESET" {*templatefileset $tplPath}
TRY "TPL_CURRENT_TEMPLATE" {hm_info -appinfo TEMPLATE}

# --- 2. Create MAT1 material and probe card fields ---------------------------
set mid ""
TRY "TPL_CREATEENTITY_MATS" {set mid [*createentity mats cardimage=MAT1 includeid=0 name=TPL_Q355]}
P "TPL_MAT_ID" $mid
TRY "TPL_READ_CARDIMAGE" {hm_getvalue mats id=$mid dataname=cardimage}

foreach pair [list "E=206000.0" "1=206000.0" "Nu=0.30" "3=0.30" "Rho=7.85e-9" "4=7.85e-9"] {
    TRY "TPL_SET $pair" {*setvalue mats id=$mid STATUS=1 $pair}
}
foreach dn {E 1 G 2 Nu 3 Rho 4 cardimage name} {
    TRY "TPL_READ $dn" {hm_getvalue mats id=$mid dataname=$dn}
}
TRY "TPL_SET_CARDIMAGE" {*setvalue mats id=$mid cardimage=MAT1}
TRY "TPL_SET_BY_NAME_SELECTOR" {*setvalue mats name=TPL_Q355 STATUS=1 Nu=0.30}
TRY "TPL_READ_NU_AFTER_NAME_SET" {hm_getvalue mats id=$mid dataname=Nu}

# --- 3. Real module under the template ----------------------------------------
TRY "TPL_SOURCE_WORKFLOW" {source -encoding utf-8 [file join $root modules workflow_common.tcl]}
TRY "TPL_SOURCE_MODULE" {source -encoding utf-8 [file join $root modules bom_material_assignment.tcl]}
if {[namespace exists ::BomMaterialAssignment]} {
    TRY "TPL_MODULE_ENSURE_Q355" {::BomMaterialAssignment::ensureQ355Material}
    set q355id ""
    catch {set q355id [::BomMaterialAssignment::materialIdByName Q355]}
    P "TPL_MODULE_Q355_ID" $q355id
    if {$q355id ne ""} {
        foreach dn {E Nu Rho cardimage} {
            TRY "TPL_MODULE_READBACK $dn" {hm_getvalue mats id=$q355id dataname=$dn}
        }
    }
}

# --- 4. hm_entitylist as official name lookup alternative ---------------------
TRY "TPL_ENTITYLIST_MATS_NAME" {hm_entitylist mats name TPL_Q355}
TRY "TPL_ENTITYLIST_COMPS_NAME" {hm_entitylist comps name NONE_SUCH_COMP}
P "TPL_ENTITYLIST_EXISTS" [expr {[info commands hm_entitylist] ne ""}]

close $channel
exit 0
