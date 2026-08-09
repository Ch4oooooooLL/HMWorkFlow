# Probe dataname=type and config for quadratic solids on the real machine.
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root modules solid_seam_connector.tcl]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "element_configs2_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
catch {*templatefileset $templatePath}
set fem [file join $root temp quadratic_test.fem]
*feinputpreserveincludefiles
eval *createstringarray 10 [list "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "]
catch {*feinputwithdata2 "\#optistruct\\optistruct" $fem 0 0 0 0 0 1 10 1 0} err
P "FEINPUT" $err
catch {*clearmark elems 1}
*createmark elems 1 all
set all [hm_getmark elems 1]
P "ELEMS" [join $all { }]
foreach e $all {
    set cfg {}
    catch {set cfg [hm_getvalue elems id=$e dataname=config]}
    set type {}
    catch {set type [hm_getvalue elems id=$e dataname=type]}
    set nn 0
    catch {set nn [llength [::SolidSeam::elementNodes $e]]}
    P "ELEM $e" "config=[string trim $cfg] type=[string trim $type] nodes=$nn"
}
close $channel
exit 0
