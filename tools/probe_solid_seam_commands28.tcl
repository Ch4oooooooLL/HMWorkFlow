# Probe round 28: try to initialize the connector engine like the GUI does
# (source the official connector scripts + display globals), then run the
# exact user-verified sequence.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_solid_seam_commands28.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "solid_seam_probe28_${version}.log"]
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

# --- GUI-like initialization -----------------------------------------------
set doSource [expr {[info exists env(HM_NO_SOURCE)] ? 0 : 1}]
P "DO_SOURCE" $doSource
set hmScripts [file join [hm_info -appinfo ALTAIR_HOME] hm scripts]
# try sourcing the connector engine scripts like the GUI does
if {!$doSource} {
    P "SOURCE_SKIPPED" 1
} else {
foreach script {
    connectors/connectors.tcl
    connectors/ce_table.tcl
    assemblytools/commontools.tcl
} {
    set path [file join $hmScripts $script]
    P "SCRIPT_EXISTS $script" [file isfile $path]
    if {[file isfile $path]} {
        set rc [catch {source $path} result]
        P "SOURCE $script RC" $rc
        if {$rc} { P "SOURCE $script ERR" [regsub -all {\s+} $result " "] }
    }
}
}

# display globals from the user's session
*CE_GlobalSetInt "g_ce_spotvis" 0
*CE_GlobalSetInt "g_ce_seamvis" 1
*CE_GlobalSetInt "g_ce_areavis" 0
*CE_GlobalSetInt "g_ce_boltvis" 0
*CE_GlobalSetInt "g_ce_applymassvis" 0

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
TRY TEMPLATE_SET {*templatefileset $templatePath}

set femPath [file join $root examples AutoShellSeamBackend test_fem combined_all_cases.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
TRY FEINPUT {*feinputwithdata2 "\#optistruct\\optistruct" $femPath 0 0 0 0 0 1 10 1 0}

# --- exact user sequence (12:45 session, tol=1 then tol=50) ----------------
foreach tol {1.000000 50.000000} {
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 [list 239 240 241 242 243 244 245 246 247]
    catch {*clearmark comps 2}
    *createmark components 2 "F03_CASE_03_CURVED_T__BASE_T2" "F03_CASE_03_CURVED_T__CURVED_WEB_T1"
    set seamOptions [list \
        "link_elems_geom=elems" "link_rule=now" "relink_rule=none" \
        "tol_flag=1" "tol=${tol}" "line_spacing=6.000000" "line_density=0" "line_preserve_nodes=0" \
        "seam_area_group=2" "ce_fedepth=6.000000" "ce_fe_tapered_t_input=0" "ce_jacobian_flag=0" \
        "ce_jacobian=0.000000" "ce_warpage_flag=0" "ce_warpage=0.000000" "ce_aspect_flag=0" \
        "ce_aspect=0.000000" "ce_fe_factor_a=1.500000" "ce_fe_factor_b=2.500000" \
        "ce_fe_edgesnapping_t=2" "ce_fe_edgesnapping_l=1" "ce_pentafitoption=2" "ce_fe_offsetangle=45.000000" \
        "ce_fe_thck_flag=1" "ce_fe_density=1" "ce_fe_strips=1" "ce_fe_rows=1" "ce_fe_const_height=0.000000" \
        "ce_fe_maint_gaps=0.000000" "ce_nonnormal=1" "ce_connectivity=2" "ce_dir_assign=0" \
        "ce_prop_opt=1" "ce_propertyid=0" "ce_fe_height=5.000000" "ce_fe_createcap=1" \
        "ce_fe_runoffangle=10.000000" "ce_fe_capangle=65.000000" "ce_fe_sharpcorner=0" \
        "ce_hexaoffsetcheck=1" "ce_hexa_position_opt=0" "ce_hexa_tapered_t_position_opt=0" \
        "ce_bl_connection_ang=10.000000" "ce_lt_connection_ang=60.000000" "ce_extralinknum=0" \
    ]
    P "TOL_${tol}_OPTIONS" [llength $seamOptions]
    set beforeConnectors [::Probe::snapshot connectors]
    set beforeElements [::Probe::snapshot elems]
    eval *createstringarray [llength $seamOptions] $seamOptions
    TRY "CREATE_TOL_${tol}" {*CE_ConnectorCreateByListAndRealizeWithDetails nodes 1 "seam" 2 components 2 "optistruct" 1001 118 $tol 1 [llength $seamOptions]}
    set newConnectors [::Probe::newIds $beforeConnectors [::Probe::snapshot connectors]]
    set newElements [::Probe::newIds $beforeElements [::Probe::snapshot elems]]
    P "TOL_${tol}_NEW_CONNECTORS" [join $newConnectors { }]
    P "TOL_${tol}_NEW_ELEMS" [llength $newElements]
    P "TOL_${tol}_PENTA6" [llength [::Probe::byConfig $newElements 206]]
    P "TOL_${tol}_RBE3" [llength [::Probe::byConfig $newElements 56]]
    P "TOL_${tol}_STATES" [::Probe::states]
    *rejectmark
}

close $channel
puts "probe28 done: $reportPath"
exit 0
