# Verify connector owning component follows the current collector, using the
# Altair-native *currentcollector components "name" form.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_connector_collector2.tcl
#
# Result: runtime/connector_collector2_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "connector_collector2_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
catch {*templatefileset $templatePath}
set fem [file join $root examples SolidSeam_Validation SolidSeam_Combined_Validation.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
catch {*feinputwithdata2 "\#optistruct\\optistruct" $fem 0 0 0 0 0 1 10 1 0}

set sourceName "C01_SOLID_VERTICAL_PLATE"
set targetName "C01_SHELL_BASE_LARGE"
set sourceId [hm_getvalue comps name=$sourceName dataname=id]
set targetId [hm_getvalue comps name=$targetName dataname=id]
P "SOURCE_COMP" $sourceId
P "TARGET_COMP" $targetId

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

proc snapshot {type} {
    catch {*clearmark $type 1}
    *createmark $type 1 all
    return [hm_getmark $type 1]
}
proc newIds {before after} {
    set result {}
    foreach id $after { if {[lsearch -exact $before $id] < 0} { lappend result $id } }
    return $result
}
proc byConfig {elemIds wanted} {
    set result {}
    foreach elemId $elemIds {
        if {[catch {set c [hm_getvalue elems id=$elemId dataname=config]}]} { continue }
        if {[string trim $c] eq $wanted} { lappend result $elemId }
    }
    return $result
}
proc connectorCollector {connectorId} {
    set out {}
    foreach cmd {hm_getcollectorname} {
        set code [catch {set v [$cmd connectors $connectorId]} err]
        lappend out "$cmd=[expr {$code ? "ERR:$err" : $v}]"
    }
    set code [catch {set v [hm_ce_info $connectorId collector]} err]
    lappend out "ce_collector=[expr {$code ? "ERR:$err" : $v}]"
    set code [catch {set v [hm_ce_info $connectorId comp]} err]
    lappend out "ce_comp=[expr {$code ? "ERR:$err" : $v}]"
    return [join $out { | }]
}

proc runCase {label nodeList seamCompIds attachCompIds collectorName} {
    global options
    set beforeC [snapshot connectors]
    set beforeE [snapshot elems]
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 $nodeList
    catch {*clearmark comps 2}
    eval *createmark comps 2 $seamCompIds
    catch {*clearmark comps 3}
    eval *createmark comps 3 $attachCompIds
    if {$collectorName ne ""} { catch {*currentcollector components $collectorName} }
    eval *createstringarray [llength $options] $options
    set code [catch {
        *CE_ConnectorCreateByListAndRealizeWithDetails nodes 1 "seam" 2 components 3 "optistruct" 1001 118 25 1 [llength $options]
    } err errOpts]
    P "${label}_CALL" [expr {$code ? "ERROR: $err" : "ok"}]
    catch {P "${label}_CC_AFTER" [hm_info currentcollector comps]}
    if {!$code} {
        set newC [newIds $beforeC [snapshot connectors]]
        set newE [newIds $beforeE [snapshot elems]]
        foreach connectorId $newC {
            set state UNKNOWN
            catch {set state [hm_ce_state $connectorId]}
            P "${label}_STATE_${connectorId}" $state
            P "${label}_COLLECTOR_${connectorId}" [connectorCollector $connectorId]
        }
        P "${label}_PENTA" [llength [byConfig $newE 206]]
        P "${label}_RBE3" [llength [byConfig $newE 56]]
        catch {eval *createmark connectors 1 $newC}
        catch {*deletemark connectors 1}
        catch {eval *createmark elems 1 $newE}
        catch {*deletemark elems 1}
    }
    catch {*clearmark comps 3}
}

set locationNodes {1 2 3 4 5 6 7 8 9}
# control: collector left at default (whatever the last import left)
runCase "A_NO_COLLECTOR" $locationNodes [list $sourceId $targetId] [list $sourceId $targetId] ""
# collector set to SOURCE comp before creation
runCase "B_CC_SOURCE" $locationNodes [list $sourceId $targetId] [list $sourceId $targetId] $sourceName
# collector set to TARGET comp before creation
runCase "C_CC_TARGET" $locationNodes [list $sourceId $targetId] [list $sourceId $targetId] $targetName
close $channel
exit 0
