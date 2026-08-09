# Full module flow verification: autoDetectSeams + realize on the C01 pair.
# Checks:
#   - node_ids all belong to the FIRST component's boundary (never target)
#   - connector entity lands on the FIRST component (current-collector fix)
#   - PENTA + RBE3 generated, state REALIZED
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_connector_full_flow.tcl
#
# Result: runtime/connector_full_flow_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "connector_full_flow_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
catch {*templatefileset $templatePath}
set fem [file join $root examples SolidSeam_Validation SolidSeam_Combined_Validation.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
catch {*feinputwithdata2 "\#optistruct\\optistruct" $fem 0 0 0 0 0 1 10 1 0}

source [file join $root modules solid_seam_connector.tcl]

set sourceId [hm_getvalue comps name="C01_SOLID_VERTICAL_PLATE" dataname=id]
set targetId [hm_getvalue comps name="C01_SHELL_BASE_LARGE" dataname=id]
P "SOURCE_COMP" $sourceId
P "TARGET_COMP" $targetId

# ---- node selection ----
set settings [dict create \
    search_distance 15.0 \
    max_search_distance 25.0 \
    min_weld_length 2.0 \
    gap_jump_limit 5.0 \
    default_width 6.0 \
    default_spacing 6.0 \
]
set detected [::SolidSeam::autoDetectSeams $sourceId $targetId $settings]
P "CANDIDATES" [llength $detected]
set nodesAll {}
foreach candidate $detected {
    set nodes [dict get $candidate node_ids]
    P "JOINT" [dict get $candidate joint_type]
    P "REALIZATION" [dict get $candidate suggested_realization]
    P "NODE_COUNT" [llength $nodes]
    P "NODE_IDS" [join $nodes { }]
    set nodesAll [concat $nodesAll $nodes]
    # which comp does each node belong to?  (nodes carry no comp: resolve
    # through the elements attached to the node)
    set compsOfNodes {}
    foreach n $nodes {
        catch {*clearmark elems 1}
        catch {*createmark elems 1 "by node" $n}
        set elemsOfNode {}
        catch {set elemsOfNode [hm_getmark elems 1]}
        foreach e $elemsOfNode {
            catch {set c [hm_getvalue elems id=$e dataname=component]}
            if {$c ne ""} { lappend compsOfNodes $c }
        }
    }
    P "NODE_COMPS" [join [lsort -integer -unique $compsOfNodes] { }]
    # boundary membership check
    set bnd [::SolidSeam::boundaryNodesOfComponent $sourceId]
    set outside {}
    foreach n $nodes { if {[lsearch -exact $bnd $n] < 0} { lappend outside $n } }
    P "NODES_OUTSIDE_SOURCE_BOUNDARY" [join $outside { }]
}

# ---- realization with the fix ----
set candidate [lindex $detected 0]
dict set candidate status ACCEPTED
dict set candidate duplicate_state UNIQUE
catch {*currentcollector components "C01_SHELL_BASE_LARGE"}
P "CC_BEFORE_REALIZE" [hm_info currentcollector comps]
set profile [::SolidSeam::loadRealizationProfile [dict get $candidate suggested_realization]]
set result [::SolidSeamCommandProfile::realize $candidate $profile]
P "CONNECTOR_ID" [dict get $result connector_id]
P "CONNECTOR_STATE" [dict get $result connector_state]
P "PENTA_COUNT" [llength [dict get $result penta_ids]]
P "RBE3_COUNT" [llength [dict get $result rbe3_ids]]
set connectorId [dict get $result connector_id]
set code [catch {set v [hm_ce_info $connectorId comp]} err]
P "CONNECTOR_COMP" [expr {$code ? "ERR:$err" : $v}]
P "OUTPUT_COMPONENT" [dict get $result output_component_name]
close $channel
exit 0
