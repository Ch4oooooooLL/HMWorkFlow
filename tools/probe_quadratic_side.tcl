# hex20 side-face check: target plate beside the hex (x=+4) so the closest
# face is F2 (ring 3,15,7,19,8,16,4,11). Expected FACING = that ring.

set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root modules solid_seam_connector.tcl]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "quadratic_side_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
catch {*templatefileset $templatePath}
set fem [file join $root temp quadratic_side.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
catch {*feinputwithdata2 "\#optistruct\\optistruct" $fem 0 0 0 0 0 1 10 1 0}

set source [hm_getvalue comps name="HEX20_SOURCE" dataname=id]
set target [hm_getvalue comps name="SHELL_TARGET" dataname=id]
P "SOURCE" $source
P "TARGET" $target
set facing [::SolidSeam::solidFacingBoundaryNodes $source $target]
P "FACING" [join $facing { }]
set settings [dict create \
    search_distance 15.0 \
    max_search_distance 25.0 \
    min_weld_length 2.0 \
    gap_jump_limit 5.0 \
    default_width 6.0 \
    default_spacing 6.0 \
]
set detected [::SolidSeam::autoDetectSeams $source $target $settings]
P "CANDIDATES" [llength $detected]
foreach candidate $detected {
    P "JOINT" [dict get $candidate joint_type]
    P "NODE_IDS" [join [dict get $candidate node_ids] { }]
}
close $channel
exit 0
