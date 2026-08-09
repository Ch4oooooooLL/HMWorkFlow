# Report the hm config id of every element type in the validation FEM.
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root modules solid_seam_connector.tcl]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "element_configs_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
catch {*templatefileset $templatePath}
set fem [file join $root examples SolidSeam_Validation SolidSeam_Combined_Validation.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
*feinputwithdata2 "\#optistruct\\optistruct" $fem 0 0 0 0 0 1 10 1 0

array set byComp {101 CHEXA 301 CPENTA 801 CTETRA 803 CPYRA 102 CQUAD4}
foreach {compId type} [array get byComp] {
    catch {*clearmark elems 1}
    *createmark elems 1 "by comp id" $compId
    set elems [hm_getmark elems 1]
    set cfgs {}
    foreach e [lrange $elems 0 3] {
        lappend cfgs [::SolidSeam::elementConfig $e]
    }
    P "[set type](comp $compId)" [join $cfgs { }]
}

# also report config for penta + hex + shell of combined_all_cases
set fem2 [file join $root examples AutoShellSeamBackend test_fem combined_all_cases.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
*feinputwithdata2 "\#optistruct\\optistruct" $fem2 0 0 0 0 0 1 10 1 0
catch {*clearmark elems 1}
*createmark elems 1 all
set all [hm_getmark elems 1]
array set seen {}
foreach e $all {
    set cfg [::SolidSeam::elementConfig $e]
    if {![info exists seen($cfg)]} {
        set seen($cfg) $e
    }
}
foreach cfg [lsort -integer [array names seen]] {
    P "CONFIG $cfg" "example elem $seen($cfg)"
}

close $channel
exit 0
