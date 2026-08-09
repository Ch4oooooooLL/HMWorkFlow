# Probe round 30: original module 47-option signature on the real model
# (isolated, tol=15).
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_solid_seam_commands30.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "solid_seam_probe30_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc TRY {label script} {
    set rc [catch {uplevel 1 $script} result options]
    P "${label}_RC" $rc
    if {$rc} {
        P "${label}_ERROR" [regsub -all {\s+} [dict get $options -errorinfo] " "]
    } else {
        P "${label}_RESULT" [string trim $result]
    }
}

namespace eval ::Probe {}
proc ::Probe::snapshot {type} {
    catch {*clearmark $type 1}
    *createmark $type 1 all
    return [hm_getmark $type 1]
}
proc ::Probe::newIds {before after} {
    set result {}
    foreach id $after {
        if {[lsearch -exact $before $id] < 0} { lappend result $id }
    }
    return $result
}
proc ::Probe::byConfig {elemIds wanted} {
    set result {}
    foreach elemId $elemIds {
        if {[catch {set config [hm_getvalue elems id=$elemId dataname=config]}]} { continue }
        if {[string trim $config] eq $wanted} { lappend result $elemId }
    }
    return $result
}
proc ::Probe::states {} {
    catch {*clearmark connectors 1}
    *createmark connectors 1 all
    set out {}
    foreach id [hm_getmark connectors 1] {
        set s UNKNOWN
        catch {set s [hm_ce_state $id]}
        lappend out "$id:$s"
    }
    return [join $out { }]
}

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
TRY TEMPLATE_SET {*templatefileset $templatePath}
set femPath [file join $root examples AutoShellSeamBackend test_fem combined_all_cases.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
TRY FEINPUT {*feinputwithdata2 "\#optistruct\\optistruct" $femPath 0 0 0 0 0 1 10 1 0}

catch {*clearmark nodes 1}
eval *createlist nodes 1 [list 239 240 241 242 243 244 245 246 247]
catch {*clearmark comps 2}
*createmark components 2 "F03_CASE_03_CURVED_T__BASE_T2" "F03_CASE_03_CURVED_T__CURVED_WEB_T1"
set executableDir [hm_info -appinfo EXECUTABLEDIR]
set feConfigPath [file join $executableDir feconfig.cfg]

set seamOptions [list \
    "link_elems_geom=elems" "link_rule=now" "relink_rule=none" \
    "tol_flag=1" "tol=15.000000" "line_spacing=6.000000" "line_density=0" "line_preserve_nodes=0" \
    "seam_area_group=2" "ce_fedepth=6.000000" "ce_fe_tapered_t_input=0" "ce_jacobian_flag=0" \
    "ce_jacobian=0.000000" "ce_warpage_flag=0" "ce_warpage=0.000000" "ce_aspect_flag=0" \
    "ce_aspect=0.000000" "ce_fe_factor_a=1.500000" "ce_fe_factor_b=2.500000" \
    "ce_fe_edgesnapping_t=2" "ce_fe_edgesnapping_l=1" "ce_fe_offsetangle=45.000000" \
    "ce_fe_thck_flag=1" "ce_fe_density=1" "ce_fe_strips=1" "ce_fe_rows=1" "ce_fe_const_height=0.000000" \
    "ce_fe_maint_gaps=0.000000" "ce_nonnormal=1" "ce_connectivity=2" "ce_dir_assign=0" \
    "ce_prop_opt=1" "ce_propertyid=0" "ce_fe_height=5.000000" "ce_fe_createcap=1" \
    "ce_fe_runoffangle=10.000000" "ce_fe_capangle=65.000000" "ce_fe_sharpcorner=0" \
    "ce_hexaoffsetcheck=1" "ce_hexa_position_opt=0" "ce_hexa_tapered_t_position_opt=0" \
    "ce_bl_connection_ang=10.000000" "ce_lt_connection_ang=60.000000" "ce_extralinknum=0" \
    "ce_configfile=$feConfigPath" "ce_propertyscript=" \
]
P "OPTIONS_COUNT" [llength $seamOptions]
set beforeConnectors [::Probe::snapshot connectors]
set beforeElements [::Probe::snapshot elems]
eval *createstringarray [llength $seamOptions] $seamOptions
TRY CREATE {*CE_ConnectorCreateByListAndRealizeWithDetails nodes 1 "seam" 2 components 2 "optistruct" 1001 118 15 1 [llength $seamOptions]}
set newElements [::Probe::newIds $beforeElements [::Probe::snapshot elems]]
P "PENTA6" [llength [::Probe::byConfig $newElements 206]]
P "RBE3" [llength [::Probe::byConfig $newElements 56]]
P "STATES" [::Probe::states]

close $channel
puts "probe30 done: $reportPath"
exit 0
