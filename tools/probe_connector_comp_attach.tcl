# Verify where a seam connector attaches when the comps mark 2 contains
# source+target vs source only.  User report: connector gets marked on the
# SECOND component; it should be marked on the FIRST (the component owning
# the selected weld nodes).
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_connector_comp_attach.tcl
#
# Result: runtime/connector_attach_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "connector_attach_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
catch {*templatefileset $templatePath}
set fem [file join $root examples SolidSeam_Validation SolidSeam_Combined_Validation.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
set err {}
catch {*feinputwithdata2 "\#optistruct\\optistruct" $fem 0 0 0 0 0 1 10 1 0} err
P "FEINPUT" $err

# locate the C01 pair from the recorded GUI session
set sourceId {}
set targetId {}
catch {set sourceId [hm_getvalue comps name="C01_SOLID_VERTICAL_PLATE" dataname=id]}
catch {set targetId [hm_getvalue comps name="C01_SHELL_BASE_LARGE" dataname=id]}
P "SOURCE_COMP" $sourceId
P "TARGET_COMP" $targetId

# connector creation utilities
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
proc queryConnector {connectorId} {
    # try every plausible way to read the connector's component association
    set out {}
    foreach dataname {comps component comp displayed_comps collector display} {
        set code [catch {set v [hm_getvalue connectors id=$connectorId dataname=$dataname]} err]
        lappend out "$dataname=[expr {$code ? "ERR:$err" : $v}]"
    }
    set code [catch {set v [hm_ce_info $connectorId]} err]
    lappend out "ce_info=[expr {$code ? "ERR:$err" : [join $v {;}]}]"
    return [join $out { | }]
}
proc connectorOwningComp {connectorId} {
    # brute force: which comps contain this connector?
    set out {}
    catch {*clearmark comps 1}
    *createmark comps 1 all
    foreach compId [hm_getmark comps 1] {
        catch {*clearmark connectors 1}
        catch {eval *createmark connectors 1 "by comp id" $compId}
        set found 0
        catch {set found [expr {[lsearch -exact [hm_getmark connectors 1] $connectorId] >= 0 ? 1 : 0}]}
        if {$found} { lappend out $compId }
    }
    return [join $out { }]
}

# weld nodes for C01: recorded GUI session used nodes 1..9 on the source plate
set locationNodes {1 2 3 4 5 6 7 8 9}

set feConfigPath "C:/Program Files/Altair/2019/hm/bin/win64/feconfig.cfg"
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
    "ce_configfile=$feConfigPath" "ce_propertyscript=" \
]

proc runCase2 {label nodeList seamCompIds attachCompIds} {
    global options
    set beforeC [snapshot connectors]
    set beforeE [snapshot elems]
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 $nodeList
    catch {*clearmark comps 2}
    eval *createmark comps 2 $seamCompIds
    catch {*clearmark comps 3}
    eval *createmark comps 3 $attachCompIds
    eval *createstringarray [llength $options] $options
    set code [catch {
        *CE_ConnectorCreateByListAndRealizeWithDetails nodes 1 "seam" 2 components 3 "optistruct" 1001 118 25 1 [llength $options]
    } err errOpts]
    P "${label}_CALL" [expr {$code ? "ERROR: $err" : "ok"}]
    if {$code} { return }
    set newC [newIds $beforeC [snapshot connectors]]
    set newE [newIds $beforeE [snapshot elems]]
    P "${label}_CONNECTORS" [join $newC { }]
    foreach connectorId $newC {
        set state UNKNOWN
        catch {set state [hm_ce_state $connectorId]}
        P "${label}_STATE_${connectorId}" $state
        P "${label}_ATTACH_${connectorId}" [queryConnector $connectorId]
        P "${label}_OWNING_COMP_${connectorId}" [connectorOwningComp $connectorId]
    }
    # where do the PENTA elements land before any move?
    catch {*clearmark elems 1}
    catch {eval *createmark elems 1 "by config" 206}
    P "${label}_PENTA_COMP_PRESCAN" "mark-count=[hm_marklength elems 1]"
    P "${label}_PENTA" [join [byConfig $newE 206] { }]
    P "${label}_RBE3" [join [byConfig $newE 56] { }]
    # cleanup
    catch {eval *createmark connectors 1 $newC}
    catch {*deletemark connectors 1}
    catch {eval *createmark elems 1 $newE}
    catch {*deletemark elems 1}
    catch {*clearmark comps 3}
}

# case A: current implementation - source AND target in comps mark 2 (both
# seam and components point at mark 2)
proc runCaseOld {label nodeList compIds} {
    global options
    set beforeC [snapshot connectors]
    set beforeE [snapshot elems]
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 $nodeList
    catch {*clearmark comps 2}
    eval *createmark comps 2 $compIds
    eval *createstringarray [llength $options] $options
    set code [catch {
        *CE_ConnectorCreateByListAndRealizeWithDetails nodes 1 "seam" 2 components 2 "optistruct" 1001 118 25 1 [llength $options]
    } err errOpts]
    P "${label}_CALL" [expr {$code ? "ERROR: $err" : "ok"}]
    if {$code} { return }
    set newC [newIds $beforeC [snapshot connectors]]
    set newE [newIds $beforeE [snapshot elems]]
    P "${label}_CONNECTORS" [join $newC { }]
    foreach connectorId $newC {
        set state UNKNOWN
        catch {set state [hm_ce_state $connectorId]}
        P "${label}_STATE_${connectorId}" $state
        P "${label}_ATTACH_${connectorId}" [queryConnector $connectorId]
        P "${label}_OWNING_COMP_${connectorId}" [connectorOwningComp $connectorId]
    }
    P "${label}_PENTA" [join [byConfig $newE 206] { }]
    P "${label}_RBE3" [join [byConfig $newE 56] { }]
    catch {eval *createmark connectors 1 $newC}
    catch {*deletemark connectors 1}
    catch {eval *createmark elems 1 $newE}
    catch {*deletemark elems 1}
}

# case A: current implementation - source AND target in comps mark 2
runCaseOld "A_BOTH" $locationNodes [list $sourceId $targetId]
# case B: seam=both comps, components=source only  (user's requested semantics)
runCase2 "B_SEAM_BOTH_ATTACH_SOURCE" $locationNodes [list $sourceId $targetId] [list $sourceId]
# case C: seam=both comps, components=target only - control
runCase2 "C_SEAM_BOTH_ATTACH_TARGET" $locationNodes [list $sourceId $targetId] [list $targetId]
# case D: seam=source only, components=source only
runCase2 "D_SEAM_SOURCE_ATTACH_SOURCE" $locationNodes [list $sourceId] [list $sourceId]

close $channel
exit 0
