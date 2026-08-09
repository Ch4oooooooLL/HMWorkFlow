# Node-input diagnostics for the solid seam module: for every fixture pair,
# report the selected weld node ids, their component membership (must never
# belong to the TARGET only), and the distance spread to the target.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_solid_seam_nodes.tcl
#
# Result: runtime/solid_seam_nodes_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root modules solid_seam_connector.tcl]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "solid_seam_nodes_${version}.log"]
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
    # comps the node belongs to
    catch {*clearmark comps 1}
    catch {*createmark comps 1 "by node id" $nodeId}
    return [hm_getmark comps 1]
}

proc NodeMinDist {nodeId targetIds} {
    global TARGET_XYZ
    set x [hm_getvalue nodes id=$nodeId dataname=x]
    set y [hm_getvalue nodes id=$nodeId dataname=y]
    set z [hm_getvalue nodes id=$nodeId dataname=z]
    set best 1.0e12
    foreach t $targetIds {
        set dx [expr {$x - [lindex $TARGET_XYZ($t) 0]}]
        set dy [expr {$y - [lindex $TARGET_XYZ($t) 1]}]
        set dz [expr {$z - [lindex $TARGET_XYZ($t) 2]}]
        set d [expr {sqrt($dx * $dx + $dy * $dy + $dz * $dz)}]
        if {$d < $best} { set best $d }
    }
    return $best
}

proc AnalyzePair {tag sourceName targetName settings} {
    set source [CompId $sourceName]
    set target [CompId $targetName]
    if {$source eq "" || $target eq ""} {
        P "$tag MISSING_COMP" "$sourceName=$source $targetName=$target"
        return
    }
    P "$tag PAIR" "[set sourceName]($source) -> [set targetName]($target)"
    set detected [::SolidSeam::autoDetectSeams $source $target $settings]
    P "$tag CANDIDATES" [llength $detected]
    global TARGET_XYZ
    array set TARGET_XYZ {}
    foreach n [::SolidSeam::componentNodeIds $target] {
        set TARGET_XYZ($n) [::SolidSeam::nodeXYZ $n]
    }
    set targetSet [lsort -integer -unique [::SolidSeam::componentNodeIds $target]]
    set index 0
    foreach candidate $detected {
        incr index
        set nodeIds [dict get $candidate node_ids]
        set onTargetOnly 0
        set onBoth 0
        set onSourceOnly 0
        set dists {}
        foreach n $nodeIds {
            set comps [NodeComp $n]
            if {[lsearch -exact $comps $target] >= 0} {
                if {[lsearch -exact $comps $source] >= 0} { incr onBoth } else { incr onTargetOnly }
            } else {
                incr onSourceOnly
            }
            lappend dists [format %.2f [NodeMinDist $n $targetSet]]
        }
        set sortedDists [lsort -real $dists]
        P "$tag ${index}_JOINT" [dict get $candidate joint_type]
        P "$tag ${index}_REALIZATION" [dict get $candidate suggested_realization]
        P "$tag ${index}_NODES" [llength $nodeIds]
        P "$tag ${index}_NODE_IDS" [join $nodeIds { }]
        P "$tag ${index}_DIST_MIN" [lindex $sortedDists 0]
        P "$tag ${index}_DIST_MAX" [lindex $sortedDists end]
        P "$tag ${index}_ON_TARGET_ONLY" $onTargetOnly
        P "$tag ${index}_ON_BOTH" $onBoth
        P "$tag ${index}_ON_SOURCE_ONLY" $onSourceOnly
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
set femPath [file join $root examples AutoShellSeamBackend test_fem combined_all_cases.fem]
LoadFem $femPath
P "MODEL1" combined_all_cases.fem

# --- shell pairs (AutoShellSeamBackend) ------------------------------------
# case_01 straight T: rib on plate (perpendicular)
AnalyzePair S01 "F01_CASE_01_STRAIGHT_T__BASE_T2" "F01_CASE_01_STRAIGHT_T__WEB_T1" $settings
# case_02 angled T (perpendicular-ish)
AnalyzePair S02 "F02_CASE_02_ANGLED_T__BASE_T2" "F02_CASE_02_ANGLED_T__ANGLED_WEB_T1" $settings
# case_03 curved T: base first (boundary away from web interior arc)
AnalyzePair S03A "F03_CASE_03_CURVED_T__BASE_T2" "F03_CASE_03_CURVED_T__CURVED_WEB_T1" $settings
# case_03 curved T: web first (closest edge = bottom edge of the web)
AnalyzePair S03B "F03_CASE_03_CURVED_T__CURVED_WEB_T1" "F03_CASE_03_CURVED_T__BASE_T2" $settings
# case_07 patch: small patch on large target (parallel shells, gap 3)
AnalyzePair S07 "F07_CASE_07_PATCH__SMALL_PATCH_T1" "F07_CASE_07_PATCH__LARGE_PATCH_TARGET_T2" $settings

# --- solid pairs (SolidSeam_Validation) ------------------------------------
set fem2 [file join $root examples SolidSeam_Validation SolidSeam_Combined_Validation.fem]
if {[file isfile $fem2]} {
    LoadFem $fem2
    P "MODEL2" SolidSeam_Combined_Validation.fem
    AnalyzePair C01 "C01_SOLID_VERTICAL_PLATE" "C01_SHELL_BASE_LARGE" $settings
    AnalyzePair C02A "C02_SOLID_PLATE_A" "C02_SHELL_COMMON_LARGE" $settings
    AnalyzePair C03 "C03_SOLID_RIGHT_PENTA_PLATE" "C03_SHELL_L_SECTION_LARGE" $settings
    AnalyzePair C05 "C05_SOLID_VERTICAL_PLATE" "C05_SOLID_BASE_PLATE" $settings
    AnalyzePair C07 "C07_SOLID_CLOSED_PLATE" "C07_SHELL_UNDER_PLATE_LARGE" $settings
    AnalyzePair C08A "C08A_SOLID_TETRA_PLATE" "C08A_SHELL_BASE_LARGE" $settings
}

close $channel
puts "node diagnostics done: $reportPath"
exit 0
