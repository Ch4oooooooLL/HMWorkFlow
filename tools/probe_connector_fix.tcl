# End-to-end verify of the current-collector fix: run the module's own
# realizePentaMig and confirm the connector lands on the FIRST component
# while PENTA+RBE3 are still generated.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_connector_fix.tcl
#
# Result: runtime/connector_fix_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "connector_fix_${version}.log"]
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

source [file join $root modules solid_seam_connector.tcl]

# deliberate: activate the TARGET component first to prove the fix overrides it
catch {*currentcollector components "C01_SHELL_BASE_LARGE"}
P "CC_BEFORE" [hm_info currentcollector comps]

set candidate [dict create \
    candidate_id 1 \
    status ACCEPTED \
    duplicate_state UNIQUE \
    source_component_id $sourceId \
    target_component_id $targetId \
    joint_type LAP_JOINT \
    suggested_realization PENTA_MIG_L \
    node_ids {1 2 3 4 5 6 7 8 9} \
    weld_width 8.0 \
    line_spacing 6.0 \
    realization_tolerance 25.0 \
]
set profile [::SolidSeam::loadRealizationProfile [dict get $candidate suggested_realization]]
set result [::SolidSeamCommandProfile::realize $candidate $profile]
P "CONNECTOR_ID" [dict get $result connector_id]
P "CONNECTOR_STATE" [dict get $result connector_state]
P "PENTA_COUNT" [llength [dict get $result penta_ids]]
P "RBE3_COUNT" [llength [dict get $result rbe3_ids]]
set connectorId [dict get $result connector_id]
set code [catch {set v [hm_ce_info $connectorId comp]} err]
P "CONNECTOR_COMP" [expr {$code ? "ERR:$err" : $v}]
P "CC_AFTER" [hm_info currentcollector comps]
close $channel
exit 0
