# Audit follow-up for bom_material_assignment.tcl: can *createentity mats
# accept MAT1 card-field values directly (E=, Nu=, Rho=) so the material is
# created with values in one call instead of create + *setvalue loop?
# Runs with the OptiStruct template loaded (required for MAT1 data names).
#
# Run:
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_bom_material_createentity.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_bom_material_createentity.tcl
#
# Results: runtime/audit_bom_material_ce_<version>.log (KEY=VALUE, ASCII).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_bom_material_ce_${version}.log"]
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
if {[string match "19*" $version]} {
    set tplPath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
} else {
    set tplPath "D:/Program Files/Altair/hwdesktop/templates/feoutput/optistruct/optistruct"
}
TRY "CE_TPL" {*templatefileset $tplPath}

# createentity with inline card field values
set mid ""
TRY "CE_CREATEENTITY_INLINE_FIELDS" {
    set mid [*createentity mats cardimage=MAT1 E=206000.0 Nu=0.30 Rho=7.85e-9 includeid=0 name=CE_Q355]
}
P "CE_MAT_ID" $mid
if {$mid ne ""} {
    foreach dn {E Nu Rho cardimage name} {
        TRY "CE_READ $dn" {hm_getvalue mats id=$mid dataname=$dn}
    }
}

# createentity with only E inline (partial)
set mid2 ""
TRY "CE_CREATEENTITY_PARTIAL" {
    set mid2 [*createentity mats cardimage=MAT1 E=210000.0 includeid=0 name=CE_Q355B]
}
if {$mid2 ne ""} {
    foreach dn {E Nu Rho} {
        TRY "CE_READ2 $dn" {hm_getvalue mats id=$mid2 dataname=$dn}
    }
}

close $channel
exit 0
