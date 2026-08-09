# End-to-end harness: drive the solid_seam module's own flow headless on the
# real validation model.  Loads the module Tcl files, imports the FEM, runs
# autoDetectSeams + createOneCandidate per detected candidate, and reports
# the realization grades.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_solid_seam_harness.tcl
#
# Result: runtime/solid_seam_harness_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "solid_seam_harness_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

# --- load the module (no UI) ----------------------------------------------
source [file join $root modules solid_seam_connector.tcl]

# --- template + model ------------------------------------------------------
set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
if {[catch {*templatefileset $templatePath} err]} { P "TEMPLATE_ERROR" $err }
set femPath [file join $root examples AutoShellSeamBackend test_fem combined_all_cases.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
if {[catch {*feinputwithdata2 "\#optistruct\\optistruct" $femPath 0 0 0 0 0 1 10 1 0} err]} { P "FEINPUT_ERROR" $err }

catch {*clearmark comps 1}
*createmark comps 1 all
P "COMPS_TOTAL" [llength [hm_getmark comps 1]]

# --- settings like the module UI defaults ---------------------------------
set settings [dict create \
    search_distance 15.0 \
    max_search_distance 25.0 \
    min_weld_length 20.0 \
    gap_jump_limit 5.0 \
    default_width 6.0 \
    default_spacing 6.0 \
]

# --- F03 pair: curved T base + web ----------------------------------------
set source [hm_getvalue comps name="F03_CASE_03_CURVED_T__BASE_T2" dataname=id]
set target [hm_getvalue comps name="F03_CASE_03_CURVED_T__CURVED_WEB_T1" dataname=id]
P "F03_SOURCE" $source
P "F03_TARGET" $target

set detected [::SolidSeam::autoDetectSeams $source $target $settings]
P "F03_CANDIDATES" [llength $detected]
set index 0
foreach candidate $detected {
    incr index
    P "F03_${index}_ID" [dict get $candidate candidate_id]
    P "F03_${index}_JOINT" [dict get $candidate joint_type]
    P "F03_${index}_REALIZATION" [dict get $candidate suggested_realization]
    P "F03_${index}_NODES" [llength [dict get $candidate node_ids]]
    P "F03_${index}_MESH" [dict get $candidate mesh_size]
    P "F03_${index}_WIDTH" [dict get $candidate weld_width]
    P "F03_${index}_SPACING" [dict get $candidate line_spacing]
    P "F03_${index}_TOL" [dict get $candidate realization_tolerance]
    set validationErrors [::SolidSeam::validateBeforeCreate $candidate]
    P "F03_${index}_VALIDATE" [join $validationErrors {;}]
    if {[llength $validationErrors] == 0} {
        set result {}
        if {[catch {set result [::SolidSeam::createOneCandidate $candidate]} err]} {
            P "F03_${index}_CREATE_ERROR" $err
        } else {
            set validation [dict get $result validation]
            P "F03_${index}_GRADE" [dict get $validation grade]
            P "F03_${index}_STATE" [dict get $validation connector_state]
            P "F03_${index}_PENTA" [dict get $validation penta_count]
            P "F03_${index}_RBE3" [dict get $validation rbe3_count]
            P "F03_${index}_OUTPUT_COMP" [dict get $result output_component_name]
        }
    }
}

# --- C01 pair: solid vertical plate + shell base (from SolidSeam_Validation)
set fem2 [file join $root examples SolidSeam_Validation SolidSeam_Combined_Validation.fem]
if {[file isfile $fem2]} {
    *feinputpreserveincludefiles
    eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
    if {[catch {*feinputwithdata2 "\#optistruct\\optistruct" $fem2 0 0 0 0 0 1 10 1 0} err]} { P "FEINPUT2_ERROR" $err }
    set s2 [hm_getvalue comps name="C01_SOLID_VERTICAL_PLATE" dataname=id]
    set t2 [hm_getvalue comps name="C01_SHELL_BASE_LARGE" dataname=id]
    P "C01_SOURCE" $s2
    P "C01_TARGET" $t2
    set detected2 [::SolidSeam::autoDetectSeams $s2 $t2 $settings]
    P "C01_CANDIDATES" [llength $detected2]
    set index 0
    foreach candidate $detected2 {
        incr index
        P "C01_${index}_JOINT" [dict get $candidate joint_type]
        P "C01_${index}_REALIZATION" [dict get $candidate suggested_realization]
        P "C01_${index}_NODES" [llength [dict get $candidate node_ids]]
        set validationErrors [::SolidSeam::validateBeforeCreate $candidate]
        P "C01_${index}_VALIDATE" [join $validationErrors {;}]
        if {[llength $validationErrors] == 0} {
            if {[catch {set result [::SolidSeam::createOneCandidate $candidate]} err]} {
                P "C01_${index}_CREATE_ERROR" $err
            } else {
                set validation [dict get $result validation]
                P "C01_${index}_GRADE" [dict get $validation grade]
                P "C01_${index}_STATE" [dict get $validation connector_state]
                P "C01_${index}_PENTA" [dict get $validation penta_count]
                P "C01_${index}_RBE3" [dict get $validation rbe3_count]
            }
        }
    }
}

close $channel
puts "harness done: $reportPath"
exit 0
