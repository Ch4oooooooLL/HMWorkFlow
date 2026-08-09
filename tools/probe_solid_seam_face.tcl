# Probe the solid facing-face boundary pipeline step by step for C08A.
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root modules solid_seam_connector.tcl]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "solid_seam_face_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
catch {*templatefileset $templatePath}
set fem [file join $root examples SolidSeam_Validation SolidSeam_Combined_Validation.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
*feinputwithdata2 "\#optistruct\\optistruct" $fem 0 0 0 0 0 1 10 1 0

set source [hm_getvalue comps name="C08A_SOLID_TETRA_PLATE" dataname=id]
set target [hm_getvalue comps name="C08A_SHELL_BASE_LARGE" dataname=id]
P "SOURCE" $source
P "TARGET" $target

# element configs of the source
catch {*clearmark elems 1}
*createmark elems 1 "by comp id" $source
set elems [hm_getmark elems 1]
set cfgs {}
foreach e [lrange $elems 0 8] {
    lappend cfgs [::SolidSeam::elementConfig $e]
}
P "FIRST_CONFIGS" [join $cfgs { }]
P "IS_SOLID" [::SolidSeam::componentIsSolid $source]

set bnd [::SolidSeam::boundaryNodesOfComponent $source]
P "BOUNDARY_COUNT" [llength $bnd]

set facing [::SolidSeam::solidFacingBoundaryNodes $source $target]
P "FACING_COUNT" [llength $facing]

# manual re-run of the facing pipeline to see each stage
set elementIds [::SolidSeam::componentElementIds $source]
array set faceCount {}
array set faceRing {}
array set faceOwner {}
foreach elementId $elementIds {
    foreach face [::SolidSeam::elementFaces $elementId] {
        set key [::SolidSeam::faceKey $face]
        incr faceCount($key)
        if {![info exists faceRing($key)]} {
            set faceRing($key) $face
            set faceOwner($key) $elementId
        }
    }
}
set outer {}
foreach key [array names faceCount] {
    if {$faceCount($key) == 1} { lappend outer $faceRing($key) }
}
P "OUTER_FACES" [llength $outer]
# count outer faces by z level (centroid)
set zCounts {}
foreach face $outer {
    set sz 0.0
    foreach n $face { set sz [expr {$sz + [lindex [::SolidSeam::nodeXYZ $n] 2]}] }
    set cz [expr {$sz / [llength $face]}]
    lappend zCounts [format %.1f $cz]
}
set zLevels [lsort -unique $zCounts]
P "OUTER_Z_LEVELS" [join $zLevels { }]

close $channel
exit 0
