# FINAL confirmation on the user's real F01-F08 case model (and the solid
# validation cases).  For every pair:
#   - auto-detect the seam candidates
#   - verify every weld node belongs to the FIRST component (never target)
#   - verify every weld node is on the first component's boundary
#   - realize the first candidate with the current-collector fix, after
#     deliberately activating the TARGET component first
#   - verify connector entity lands on the FIRST component (hm_ce_info comp)
#   - verify PENTA + RBE3 are generated and the connector is REALIZED
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_solid_seam_final.tcl
#
# Result: runtime/solid_seam_final_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root modules solid_seam_connector.tcl]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "solid_seam_final_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

proc LoadFem {femPath} {
    *feinputpreserveincludefiles
    eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
    if {[catch {*feinputwithdata2 "\#optistruct\\optistruct" $femPath 0 0 0 0 0 1 10 1 0} err]} { P "FEINPUT_ERROR" $err }
}

proc CompId {name} {
    set id {}
    catch {set id [hm_getvalue comps name=$name dataname=id]}
    return $id
}

proc NodeComp {nodeId} {
    catch {*clearmark comps 1}
    catch {*createmark comps 1 "by node id" $nodeId}
    return [hm_getmark comps 1]
}

# Run detection + realization checks for one ordered pair.
proc CheckPair {tag sourceName targetName settings} {
    set source [CompId $sourceName]
    set target [CompId $targetName]
    if {$source eq "" || $target eq ""} {
        P "$tag MISSING_COMP" "$sourceName=$source $targetName=$target"
        return
    }
    P "$tag PAIR" "[set sourceName]($source) -> [set targetName]($target)"
    set detected [::SolidSeam::autoDetectSeams $source $target $settings]
    P "$tag CANDIDATES" [llength $detected]
    set targetSet [lsort -integer -unique [::SolidSeam::componentNodeIds $target]]
    set sourceBoundary [::SolidSeam::boundaryNodesOfComponent $source]
    set index 0
    foreach candidate $detected {
        incr index
        set nodeIds [dict get $candidate node_ids]
        set onTargetOnly 0
        set onBoth 0
        set onSourceOnly 0
        set outsideBoundary {}
        set dists {}
        foreach n $nodeIds {
            set comps [NodeComp $n]
            if {[lsearch -exact $comps $target] >= 0} {
                if {[lsearch -exact $comps $source] >= 0} { incr onBoth } else { incr onTargetOnly }
            } else {
                incr onSourceOnly
            }
            if {[lsearch -exact $sourceBoundary $n] < 0} { lappend outsideBoundary $n }
            # min distance to target nodes
            set x [hm_getvalue nodes id=$n dataname=x]
            set y [hm_getvalue nodes id=$n dataname=y]
            set z [hm_getvalue nodes id=$n dataname=z]
            set best 1.0e12
            foreach t $targetSet {
                set dx [expr {$x - [hm_getvalue nodes id=$t dataname=x]}]
                set dy [expr {$y - [hm_getvalue nodes id=$t dataname=y]}]
                set dz [expr {$z - [hm_getvalue nodes id=$t dataname=z]}]
                set d [expr {sqrt($dx * $dx + $dy * $dy + $dz * $dz)}]
                if {$d < $best} { set best $d }
            }
            lappend dists $best
        }
        set sortedDists [lsort -real $dists]
        P "$tag ${index}_JOINT" [dict get $candidate joint_type]
        P "$tag ${index}_REALIZATION" [dict get $candidate suggested_realization]
        P "$tag ${index}_NODES" [llength $nodeIds]
        P "$tag ${index}_DIST_MIN" [format %.2f [lindex $sortedDists 0]]
        P "$tag ${index}_DIST_MAX" [format %.2f [lindex $sortedDists end]]
        P "$tag ${index}_ON_TARGET_ONLY" $onTargetOnly
        P "$tag ${index}_ON_SOURCE_ONLY" $onSourceOnly
        P "$tag ${index}_OUTSIDE_SOURCE_BOUNDARY" [join $outsideBoundary { }]
    }
    # realize the FIRST candidate only (keep runtime sane)
    if {[llength $detected] > 0} {
        set candidate [lindex $detected 0]
        dict set candidate status ACCEPTED
        dict set candidate duplicate_state UNIQUE
        # deliberate: activate the TARGET component before realizing to prove
        # the fix overrides the ambient collector
        catch {*currentcollector components $targetName}
        set ccBefore {}
        catch {set ccBefore [hm_info currentcollector comps]}
        P "$tag CC_BEFORE_REALIZE" $ccBefore
        set code [catch {
            set profile [::SolidSeam::loadRealizationProfile [dict get $candidate suggested_realization]]
            set result [::SolidSeamCommandProfile::realize $candidate $profile]
        } err]
        if {$code} {
            P "$tag REALIZE_ERROR" $err
            return
        }
        P "$tag CONNECTOR_STATE" [dict get $result connector_state]
        P "$tag PENTA_COUNT" [llength [dict get $result penta_ids]]
        P "$tag RBE3_COUNT" [llength [dict get $result rbe3_ids]]
        set connectorId [dict get $result connector_id]
        set ccode [catch {set v [hm_ce_info $connectorId comp]} cerr]
        P "$tag CONNECTOR_COMP" [expr {$ccode ? "ERR:$cerr" : $v}]
        P "$tag CONNECTOR_COMP_IS_SOURCE" [expr {!$ccode && $v eq $sourceName ? "yes" : "no"}]
        # clean up generated entities so later cases start fresh
        catch {eval *createmark connectors 1 $connectorId}
        catch {*deletemark connectors 1}
        catch {eval *createmark elems 1 [dict get $result penta_ids]}
        catch {*deletemark elems 1}
        catch {eval *createmark elems 1 [dict get $result rbe3_ids]}
        catch {*deletemark elems 1}
    }
}

set settings [dict create \
    search_distance 15.0 \
    max_search_distance 25.0 \
    min_weld_length 20.0 \
    gap_jump_limit 5.0 \
    default_width 6.0 \
    default_spacing 6.0 \
]

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
catch {*templatefileset $templatePath}

# --- shell pairs (the user's F01-F08 model) ----------------------------------
set femPath [file join $root examples AutoShellSeamBackend test_fem combined_all_cases.fem]
LoadFem $femPath
P "MODEL1" combined_all_cases.fem

CheckPair F01 "F01_CASE_01_STRAIGHT_T__WEB_T1" "F01_CASE_01_STRAIGHT_T__BASE_T2" $settings
CheckPair F02 "F02_CASE_02_ANGLED_T__ANGLED_WEB_T1" "F02_CASE_02_ANGLED_T__BASE_T2" $settings
CheckPair F03 "F03_CASE_03_CURVED_T__CURVED_WEB_T1" "F03_CASE_03_CURVED_T__BASE_T2" $settings
CheckPair F03R "F03_CASE_03_CURVED_T__BASE_T2" "F03_CASE_03_CURVED_T__CURVED_WEB_T1" $settings
CheckPair F04 "F04_CASE_04_PARTIAL_OVERLAP_T__LONG_WEB_T1" "F04_CASE_04_PARTIAL_OVERLAP_T__PARTIAL_BASE_T2" $settings
CheckPair F05A "F05_CASE_05_MULTI_TARGET_SAME_EDGE__SHARED_SOURCE_WEB_T1" "F05_CASE_05_MULTI_TARGET_SAME_EDGE__UPPER_TARGET_T2" $settings
CheckPair F05B "F05_CASE_05_MULTI_TARGET_SAME_EDGE__SHARED_SOURCE_WEB_T1" "F05_CASE_05_MULTI_TARGET_SAME_EDGE__LOWER_TARGET_T2" $settings
CheckPair F06A "F06_CASE_06_FOUR_TARGET_T__CENTER_WEB_T1" "F06_CASE_06_FOUR_TARGET_T__BASE1_T2" $settings
CheckPair F06B "F06_CASE_06_FOUR_TARGET_T__CENTER_WEB_T1" "F06_CASE_06_FOUR_TARGET_T__BASE2_T2" $settings
CheckPair F06C "F06_CASE_06_FOUR_TARGET_T__CENTER_WEB_T1" "F06_CASE_06_FOUR_TARGET_T__BASE3_T2" $settings
CheckPair F06D "F06_CASE_06_FOUR_TARGET_T__CENTER_WEB_T1" "F06_CASE_06_FOUR_TARGET_T__BASE4_T2" $settings
CheckPair F07 "F07_CASE_07_PATCH__SMALL_PATCH_T1" "F07_CASE_07_PATCH__LARGE_PATCH_TARGET_T2" $settings
CheckPair F08 "F08_CASE_08_PATCH_SMALL_HOLE_REVIEW__PATCH_WITH_SMALL_HOLE_T1" "F08_CASE_08_PATCH_SMALL_HOLE_REVIEW__LARGE_PATCH_TARGET_T2" $settings

# --- solid pairs (SolidSeam_Validation model) --------------------------------
set fem2 [file join $root examples SolidSeam_Validation SolidSeam_Combined_Validation.fem]
if {[file isfile $fem2]} {
    LoadFem $fem2
    P "MODEL2" SolidSeam_Combined_Validation.fem
    CheckPair C01 "C01_SOLID_VERTICAL_PLATE" "C01_SHELL_BASE_LARGE" $settings
    CheckPair C02A "C02_SOLID_PLATE_A" "C02_SHELL_COMMON_LARGE" $settings
    CheckPair C03 "C03_SOLID_RIGHT_PENTA_PLATE" "C03_SHELL_L_SECTION_LARGE" $settings
    CheckPair C05 "C05_SOLID_VERTICAL_PLATE" "C05_SOLID_BASE_PLATE" $settings
    CheckPair C08A "C08A_SOLID_TETRA_PLATE" "C08A_SHELL_BASE_LARGE" $settings
}

close $channel
puts "final confirmation done: $reportPath"
exit 0
