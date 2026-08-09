# Enumerate connector datanames and comp association on HM2019.
set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "connector_dataname_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
catch {*templatefileset $templatePath}
set fem [file join $root examples SolidSeam_Validation SolidSeam_Combined_Validation.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
catch {*feinputwithdata2 "\#optistruct\\optistruct" $fem 0 0 0 0 0 1 10 1 0}

set sourceId [hm_getvalue comps name="C01_SOLID_VERTICAL_PLATE" dataname=id]
set targetId [hm_getvalue comps name="C01_SHELL_BASE_LARGE" dataname=id]
P "SOURCE_COMP" $sourceId
P "TARGET_COMP" $targetId

# create one connector using the recorded GUI flow (both comps in mark 2)
set options [list \
    "link_elems_geom=elems" "link_rule=now" "relink_rule=none" \
    "tol_flag=1" "tol=25.000000" "line_spacing=6.000000" "line_density=0" "line_preserve_nodes=0" \
    "seam_area_group=2" "ce_fedepth=8.000000" "ce_fe_tapered_t_input=0" "ce_jacobian_flag=0" \
    "ce_jacobian=0.000000" "ce_warpage_flag=0" "ce_warpage=0.000000" "ce_aspect_flag=0" \
    "ce_aspect=0.000000" "ce_fe_factor_a=1.500000" "ce_fe_factor_b=2.500000" \
    "ce_fe_edgesnapping_t=2" "ce_fe_edgesnapping_l=1" "ce_fe_offsetangle=45.000000" \
    "ce_fe_density=1" "ce_fe_thck_flag=1" "ce_fe_strips=1" "ce_fe_rows=1" "ce_fe_const_height=0.000000" \
    "ce_fe_maint_gaps=0.000000" "ce_nonnormal=1" "ce_connectivity=2" "ce_dir_assign=0" \
    "ce_prop_opt=1" "ce_propertyid=0" "ce_fe_height=5.000000" "ce_fe_createcap=1" \
    "ce_fe_runoffangle=10.000000" "ce_fe_capangle=65.000000" "ce_fe_sharpcorner=0" \
    "ce_hexaoffsetcheck=1" "ce_hexa_position_opt=0" "ce_hexa_tapered_t_position_opt=0" \
    "ce_bl_connection_ang=10.000000" "ce_lt_connection_ang=60.000000" "ce_extralinknum=0" \
    "ce_configfile=C:/Program Files/Altair/2019/hm/bin/win64/feconfig.cfg" "ce_propertyscript=" \
]
catch {*clearmark nodes 1}
eval *createlist nodes 1 {1 2 3 4 5 6 7 8 9}
catch {*clearmark comps 2}
eval *createmark comps 2 $sourceId $targetId
eval *createstringarray [llength $options] $options
catch {*CE_ConnectorCreateByListAndRealizeWithDetails nodes 1 "seam" 2 components 2 "optistruct" 1001 118 25 1 [llength $options]}

# where do connectors live?  try every plausible hm_ce_info request name
set connectorId 1
foreach request {state type tolerance layers fetype fetypename spacing location comps components links geom1 geom2} {
    set code [catch {set v [hm_ce_info $connectorId $request]} err]
    P "CEINFO_$request" [expr {$code ? "ERR:$err" : $v}]
}
# bulk dataname dump on connectors
catch {*clearmark connectors 1}
*createmark connectors 1 all
P "CONNECTOR_IDS" [join [hm_getmark connectors 1] { }]
foreach id [hm_getmark connectors 1] {
    foreach dataname {id config comps display_comp component_id comp_id collector comp} {
        set code [catch {set v [hm_getvalue connectors id=$id dataname=$dataname]} err]
        P "VAL_${id}_${dataname}" [expr {$code ? "ERR" : $v}]
    }
}
# where is the current collector / which comps would own a new connector?
set code [catch {set cur [hm_getvalue comps id=[hm_info currentcollector comps] dataname=name]} err]
P "CURRENT_COMP" [expr {$code ? "ERR:$err" : $cur}]
# connector model-tree ownership: check each comp's connector count
catch {*clearmark comps 1}
*createmark comps 1 all
foreach compId [hm_getmark comps 1] {
    catch {*clearmark connectors 1}
    catch {eval *createmark connectors 1 "by comp" $compId}
    set n 0
    catch {set n [hm_marklength connectors 1]}
    if {$n > 0} { P "COMP_${compId}_CONNECTORS" $n }
}
close $channel
exit 0
