# Adhesive area connector probe: drive the adhesive_connector module's own
# flow headless on a synthetic FEM, on the installed HyperMesh build.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_adhesive_connector.tcl
#
# Result: runtime/adhesive_harness_<version>.log
#
# Phases:
#   0  environment: version, executable dir, feconfig.cfg, adhesives FE type
#   1  command surface: every command the module relies on
#   2  string-array semantics: *createstringarray + spaced values
#   3  model import + data access (hm_getvalue / hm_findprojected)
#   4  cleaning: ::AdhesiveConnector::cleanLocationElems on both cases
#   5  realization matrix: module options with/without template + variants
#   6  end-to-end ::AdhesiveConnector::createAdhesive (dialogs stubbed)

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "adhesive_harness_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc PB {key flag} {
    P $key [expr {$flag ? "yes" : "no"}]
}

set executableDir [hm_info -appinfo EXECUTABLEDIR]
P "VERSION" $version
P "EXECUTABLEDIR" $executableDir
P "TEMPLATE_FRESH" [string trim [hm_info templatetype]]

# ---------- phase 1: command surface ---------------------------------------
foreach command {
    *CE_ConnectorCreateByMarkAndRealizeWithDetails
    *CE_ConnectorCreateByListAndRealizeWithDetails
    *CE_ConnectorCreateByMark
    *CE_ConnectorCreateWithRules
    *CE_AddLinkEntitiesWithArrays
    *CE_FE_SetDetailsAndRealize
    *CE_ConnectorSeamCreateUsingLines
    hm_ce_state
    hm_ce_info
    hm_findprojected
    hm_marklength
    *createstringarray
    *templatefileset
    *deletemark
    *feinputwithdata2
} {
    PB "CMD_$command" [expr {[llength [info commands $command]] > 0}]
}

# ---------- phase 2: string-array semantics --------------------------------
catch {*createstringarray 3 {alpha one} beta gamma} stringArrayError
P "STRING_ARRAY_CALL_ERROR" $stringArrayError
P "STRING_ARRAY_EXISTS" [expr {[info exists string_array] ? "yes" : "no"}]
if {[info exists string_array]} {
    P "STRING_ARRAY_SIZE" [array size string_array]
    P "STRING_ARRAY_0" $string_array(0)
    P "STRING_ARRAY_1" $string_array(1)
    P "STRING_ARRAY_2" $string_array(2)
}
foreach candidateVar [lsort [info globals *string*]] {
    catch {P "GLOBAL_${candidateVar}" [set $candidateVar]}
}

# ---------- load the module (no UI) ----------------------------------------
source [file join $root modules adhesive_connector.tcl]

# ---------- phase 0b: feconfig + FE type resolution -------------------------
set feConfigPath [file join $executableDir feconfig.cfg]
P "FECONFIG_EXISTS" [file isfile $feConfigPath]
if {![file isfile $feConfigPath]} {
    P "FE_TYPE" "ERROR: no feconfig.cfg at $feConfigPath"
    set feType ""
} else {
    if {[catch {set feType [::AdhesiveConnector::adhesivesFeType $feConfigPath]} err]} {
        P "FE_TYPE" "ERROR: $err"
        set feType ""
    } else {
        P "FE_TYPE" $feType
    }
}

# ---------- phase 3: model import + data access ----------------------------
proc ensureTemplate {} {
    set templateType [string tolower [string trim [hm_info templatetype]]]
    if {$templateType eq "none" || $templateType eq ""} {
        set executableDir [hm_info -appinfo EXECUTABLEDIR]
        set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
        if {![file isfile $templatePath]} {
            error "OptiStruct template not found at $templatePath"
        }
        *templatefileset $templatePath
        P "TEMPLATE_SET" $templatePath
    }
    P "TEMPLATE_NOW" [string trim [hm_info templatetype]]
}

set femPath [file join $outputDir "adhesive_probe_model.fem"]
set femChannel [open $femPath w]
puts $femChannel "BEGIN BULK"
# Case A (unit-test mirror): SRC_A owns location elems 10/11 at z=0,
# TGT_A owns elem 20 at z=50.  Elem 11 (x 15-25) sticks out of TGT_A (x 0-20).
puts $femChannel {$HMNAME COMP 100 "SRC_A"}
puts $femChannel {$HMNAME COMP 200 "TGT_A"}
puts $femChannel {GRID,1,,0,0,0}
puts $femChannel {GRID,2,,10,0,0}
puts $femChannel {GRID,3,,10,10,0}
puts $femChannel {GRID,4,,0,10,0}
puts $femChannel {GRID,5,,15,0,0}
puts $femChannel {GRID,6,,25,0,0}
puts $femChannel {GRID,7,,25,10,0}
puts $femChannel {GRID,8,,15,10,0}
puts $femChannel {GRID,21,,0,0,50}
puts $femChannel {GRID,22,,20,0,50}
puts $femChannel {GRID,23,,20,20,50}
puts $femChannel {GRID,24,,0,20,50}
puts $femChannel {CQUAD4,10,100,1,2,3,4}
puts $femChannel {CQUAD4,11,100,5,6,7,8}
puts $femChannel {CQUAD4,20,200,21,22,23,24}
# Case B (realistic): PATCH owns location elems 30/31 at z=25; PLATE_A/B are
# the linked plates at z=0 / z=50.  Elem 31 (x 35-45) sticks out of both.
puts $femChannel {$HMNAME COMP 300 "PATCH"}
puts $femChannel {$HMNAME COMP 400 "PLATE_A"}
puts $femChannel {$HMNAME COMP 500 "PLATE_B"}
puts $femChannel {GRID,31,,5,5,25}
puts $femChannel {GRID,32,,15,5,25}
puts $femChannel {GRID,33,,15,15,25}
puts $femChannel {GRID,34,,5,15,25}
puts $femChannel {GRID,35,,35,5,25}
puts $femChannel {GRID,36,,45,5,25}
puts $femChannel {GRID,37,,45,15,25}
puts $femChannel {GRID,38,,35,15,25}
puts $femChannel {GRID,41,,0,0,0}
puts $femChannel {GRID,42,,40,0,0}
puts $femChannel {GRID,43,,40,40,0}
puts $femChannel {GRID,44,,0,40,0}
puts $femChannel {GRID,51,,0,0,50}
puts $femChannel {GRID,52,,40,0,50}
puts $femChannel {GRID,53,,40,40,50}
puts $femChannel {GRID,54,,0,40,50}
puts $femChannel {CQUAD4,30,300,31,32,33,34}
puts $femChannel {CQUAD4,31,300,35,36,37,38}
puts $femChannel {CQUAD4,40,400,41,42,43,44}
puts $femChannel {CQUAD4,50,500,51,52,53,54}
puts $femChannel "ENDDATA"
close $femChannel
P "FEM_WRITTEN" $femPath

if {[catch {ensureTemplate} err]} { P "TEMPLATE_ERROR" $err }
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
if {[catch {*feinputwithdata2 "\#optistruct\\optistruct" $femPath 0 0 0 0 0 1 10 1 0} err errOpts]} {
    P "FEINPUT" "ERROR: $err :: $errOpts"
} else {
    P "FEINPUT" "ok"
}

proc compIdByName {name} {
    set result ""
    catch {set result [hm_getvalue comps name="$name" dataname=id]}
    return $result
}
proc elemsOfComp {componentId} {
    catch {*clearmark elems 1}
    *createmark elems 1 "by comp id" $componentId
    return [hm_getmark elems 1]
}

set srcA [compIdByName "SRC_A"]
set tgtA [compIdByName "TGT_A"]
set patch [compIdByName "PATCH"]
set plateA [compIdByName "PLATE_A"]
set plateB [compIdByName "PLATE_B"]
P "COMP_SRC_A" $srcA
P "COMP_TGT_A" $tgtA
P "COMP_PATCH" $patch
P "COMP_PLATE_A" $plateA
P "COMP_PLATE_B" $plateB
set locA [elemsOfComp $srcA]
set tgtAElems [elemsOfComp $tgtA]
set locB [elemsOfComp $patch]
P "ELEMS_LOC_A" $locA
P "ELEMS_TGT_A" $tgtAElems
P "ELEMS_LOC_B" $locB

foreach elementId [concat $locA $locB $tgtAElems] {
    if {[catch {set nodes [::AdhesiveConnector::elementNodes $elementId]}]} {
        P "ELEM${elementId}_NODES" "ERROR"
    } else {
        P "ELEM${elementId}_NODES" $nodes
    }
    if {[catch {set config [hm_getvalue elems id=$elementId dataname=config]}]} {
        P "ELEM${elementId}_CONFIG" "ERROR"
    } else {
        P "ELEM${elementId}_CONFIG" $config
    }
    P "ELEM${elementId}_COMP" [::AdhesiveConnector::elementComponentId $elementId]
}
if {[llength $locA] > 0} {
    set probeNode [lindex [::AdhesiveConnector::elementNodes [lindex $locA 0]] 0]
    P "NODE${probeNode}_XYZ" [::AdhesiveConnector::nodeXYZ $probeNode]
}
catch {*clearmark elems 1}
eval *createmark elems 1 $locA
if {[catch {set configRows [hm_getvalue elems mark=1 dataname=config]}]} {
    P "BULK_CONFIG" "ERROR"
} else {
    P "BULK_CONFIG" $configRows
}
if {[catch {set nodeRows [hm_getvalue elems mark=1 dataname=nodes]}]} {
    P "BULK_NODES" "ERROR"
} else {
    P "BULK_NODES" $nodeRows
}
catch {*clearmark nodes 2}
if {[llength $locA] > 0 && [llength $tgtAElems] > 0} {
    eval *createmark nodes 2 [concat [::AdhesiveConnector::elementNodes [lindex $locA 0]] [::AdhesiveConnector::elementNodes [lindex $tgtAElems 0]]]
    if {[catch {set coordRows [hm_getvalue nodes mark=2 dataname=coordinates]}]} {
        P "BULK_COORDS" "ERROR"
    } else {
        P "BULK_COORDS" $coordRows
    }
}

# ---------- phase 4: cleaning ----------------------------------------------
if {[llength $locA] >= 2 && $tgtA ne ""} {
    if {[catch {set cleanA [::AdhesiveConnector::cleanLocationElems $locA [list $srcA $tgtA] 50]} err]} {
        P "CLEAN_A" "ERROR: $err"
    } else {
        P "CLEAN_A_KEPT" [dict get $cleanA kept]
        P "CLEAN_A_REJECTED" [dict get $cleanA rejected]
    }
}
if {[llength $locB] >= 2} {
    if {[catch {set cleanB [::AdhesiveConnector::cleanLocationElems $locB [list $plateA $plateB] 50]} err]} {
        P "CLEAN_B" "ERROR: $err"
    } else {
        P "CLEAN_B_KEPT" [dict get $cleanB kept]
        P "CLEAN_B_REJECTED" [dict get $cleanB rejected]
    }
}
# raw projection behavior: which nodes of the location elems project onto
# the target component's elements (module's exact hm_findprojected call)?
if {[llength [info commands hm_findprojected]] > 0 && [llength $locA] >= 2 && [llength $tgtAElems] > 0} {
    catch {*clearmark elems 1}
    eval *createmark elems 1 $locA
    catch {*clearmark elems 2}
    eval *createmark elems 2 $tgtAElems
    catch {*clearmark nodes 1}
    if {[catch {
        hm_findprojected elems 1 2 0 50.0 0.0 1 0.0 0.0 0.0 2 1 0
    } projErr]} {
        P "RAW_FINDPROJECTED" "ERROR: $projErr"
    } else {
        P "RAW_FINDPROJECTED" [hm_getmark nodes 1]
    }
    # and with an explicit projection direction (+z, i.e. towards the target)
    catch {*clearmark elems 1}
    eval *createmark elems 1 $locA
    catch {*clearmark elems 2}
    eval *createmark elems 2 $tgtAElems
    catch {*clearmark nodes 1}
    if {[catch {
        hm_findprojected elems 1 2 0 50.0 0.0 1 0.0 0.0 1.0 2 1 0
    } projErr2]} {
        P "RAW_FINDPROJECTED_Z" "ERROR: $projErr2"
    } else {
        P "RAW_FINDPROJECTED_Z" [hm_getmark nodes 1]
    }
}

# ---------- phase 5: realization matrix -------------------------------------
proc snapshotElems {} {
    catch {*clearmark elems 3}
    *createmark elems 3 all
    return [hm_getmark elems 3]
}
proc snapshotConnectors {} {
    catch {*clearmark connectors 1}
    *createmark connectors 1 all
    return [hm_getmark connectors 1]
}
proc newIds {before after} {
    set result {}
    foreach value $after {
        if {[lsearch -exact $before $value] < 0} { lappend result $value }
    }
    return $result
}
proc elementConfigs {ids} {
    set result {}
    foreach elementId $ids {
        catch {set config [hm_getvalue elems id=$elementId dataname=config]}
        lappend result "${elementId}:$config"
    }
    return $result
}
proc tryRealize {label locationElems compIds tolerance options} {
    variable feType
    set beforeC [snapshotConnectors]
    set beforeE [snapshotElems]
    catch {*clearmark elems 1}
    eval *createmark elems 1 $locationElems
    catch {*clearmark comps 2}
    eval *createmark comps 2 $compIds
    eval *createstringarray [llength $options] $options
    set code [catch {
        *CE_ConnectorCreateByMarkAndRealizeWithDetails elems 1 area [llength $compIds] comps 2 optistruct 1001 $feType $tolerance 1 [llength $options]
    } err errOpts]
    P "${label}_CALL" [expr {$code ? "ERROR: $err :: $errOpts" : "ok"}]
    if {$code} { return }
    set newC [newIds $beforeC [snapshotConnectors]]
    set newE [newIds $beforeE [snapshotElems]]
    P "${label}_NEW_CONNECTORS" $newC
    P "${label}_NEW_ELEMS" [elementConfigs $newE]
    foreach connectorId $newC {
        if {[catch {set state [hm_ce_state $connectorId]} stateErr]} {
            P "${label}_STATE_${connectorId}" "ERROR: $stateErr"
        } else {
            P "${label}_STATE_${connectorId}" $state
        }
    }
    # keep the model clean for the next attempt
    catch {eval *createmark connectors 1 $newC}
    catch {*deletemark connectors 1}
    catch {eval *createmark elems 1 $newE}
    catch {*deletemark elems 1}
}

set moduleOptions [list \
    "link_elems_geom=elems" \
    "link_rule=now" \
    "relink_rule=none" \
    "tol_flag=1" \
    "tol=50.000000" \
    "seam_area_group=0" \
    "ce_areathicknesstype=3" \
    "ce_areaconstthickness=1.000000" \
    "ce_areastacksize=1" \
    "ce_prop_opt=1" \
    "ce_propertyid=0" \
    "ce_propertyscript=" \
    "ce_configfile=$feConfigPath"]

set minimalOptions [list \
    "link_elems_geom=elems" \
    "link_rule=now" \
    "relink_rule=none" \
    "tol_flag=1" \
    "tol=50.000000" \
    "seam_area_group=0" \
    "ce_areathicknesstype=3" \
    "ce_areaconstthickness=1.000000" \
    "ce_areastacksize=1"]

P "REALIZE_LOCATION_B" $locB
P "REALIZE_COMPS_B" [list $plateA $plateB]

# R1: module options, no template (fresh hmbatch state = module in fresh HM)
tryRealize "R1_NOTEMPLATE" $locB [list $plateA $plateB] 50.0 $moduleOptions

# R2: module options with the OptiStruct template loaded first
if {[catch {ensureTemplate} err]} { P "TEMPLATE_ERROR" $err }
tryRealize "R2_TEMPLATE" $locB [list $plateA $plateB] 50.0 $moduleOptions

# R3: template + minimal options (no ce_prop_*/ce_configfile)
tryRealize "R3_TEMPLATE_MINIMAL" $locB [list $plateA $plateB] 50.0 $minimalOptions

# R4: template + no options at all
tryRealize "R4_TEMPLATE_NOOPT" $locB [list $plateA $plateB] 50.0 {}

# R5: template + minimal options on case A location (unit-test mirror)
if {[llength $locA] >= 2} {
    tryRealize "R5_TEMPLATE_CASE_A" $locA [list $srcA $tgtA] 50.0 $minimalOptions
}

# ---------- phase 6: end-to-end module flow ---------------------------------
proc tk_messageBox args { set ::last_dialog $args }
proc hm_usermessage args {}
rename ::AdhesiveConnector::saveState ::AdhesiveConnector::saveState_real
proc ::AdhesiveConnector::saveState {} {}
if {[info exists cleanB]} {
    set ::AdhesiveConnector::ui(selectedElems) [dict get $cleanB kept]
} else {
    set ::AdhesiveConnector::ui(selectedElems) [lrange $locB 0 0]
}
set ::AdhesiveConnector::ui(selectedComps) [list $plateA $plateB]
set ::AdhesiveConnector::ui(tolerance) 50.0
set ::AdhesiveConnector::ui(coats) 1
set ::AdhesiveConnector::ui(thickness_type) CONST_THICKNESS
set ::AdhesiveConnector::ui(const_thickness) 1.0
if {[catch {set e2e [::AdhesiveConnector::createAdhesive]} e2eErr]} {
    P "E2E" "ERROR: $e2eErr"
} else {
    P "E2E" $e2e
    if {[info exists ::last_dialog]} {
        P "E2E_DIALOG" [lindex $::last_dialog 3]
    }
}

close $channel
puts "adhesive probe done: $reportPath"
exit 0
