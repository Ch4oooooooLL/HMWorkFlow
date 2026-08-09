# Audit probe 2: is the *feinputwithdata2 error "0" caused by a pending
# interactive confirm (model not empty / overwrite) in hmbatch?
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_mesh_seam_weld_feinput2.tcl
#   Results: runtime/audit_mesh_seam_weld_feinput2_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_mesh_seam_weld_feinput2_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

P "status" "STARTED"
P "version" $version

namespace eval ::FEI2 {}
proc ::FEI2::nodeCount {} {
    catch {*createmark nodes 1 all}
    set s {}
    catch {set s [hm_getmark nodes 1]}
    catch {*clearmark nodes 1}
    return [llength $s]
}

# Delta file with a MAT1 card (V2 style from probe 1)
set deltaPath [file join $outputDir "audit_mesh_seam_weld_feinput2_delta.fem"]
set chan [open $deltaPath w]
puts $chan "BEGIN BULK"
puts $chan "GRID 9101 0. 0. 0."
puts $chan "GRID 9102 10. 0. 0."
puts $chan "GRID 9103 10. 10. 0."
puts $chan "GRID 9104 0. 10. 0."
puts $chan "MAT1 1 210000. 80000. 0.3"
puts $chan "CQUAD4 9201 1 9101 9102 9103 9104"
puts $chan "ENDDATA"
close $chan
P "DELTA_EXISTS" [file isfile $deltaPath]

# --- T1: EMPTY model, answernext yes queued ------------------------------
P "T1_EMPTY_MODEL" [::FEI2::nodeCount]
catch {hm_answernext yes}
if {[catch {*feinputwithdata2 "#optistruct/optistruct" $deltaPath 0 0 0 0 0 1 2 1 0} feErr]} {
    P "T1_ERROR" $feErr
} else {
    P "T1_OK" 1
    P "T1_NODES" [::FEI2::nodeCount]
    catch {*createmark nodes 1 "by id" 9101}
    P "T1_N9101" [expr {[llength [hm_getmark nodes 1]] > 0}]
    catch {*clearmark nodes 1}
}

# --- T2: empty model, NO answer ------------------------------------------
set delta2 [file join $outputDir "audit_mesh_seam_weld_feinput2_delta2.fem"]
set chan [open $delta2 w]
puts $chan "BEGIN BULK"
puts $chan "GRID 9301 100. 0. 0."
puts $chan "GRID 9302 110. 0. 0."
puts $chan "GRID 9303 110. 10. 0."
puts $chan "GRID 9304 100. 10. 0."
puts $chan "MAT1 1 210000. 80000. 0.3"
puts $chan "CQUAD4 9301 1 9301 9302 9303 9304"
puts $chan "ENDDATA"
close $chan
if {[catch {*feinputwithdata2 "#optistruct/optistruct" $delta2 0 0 0 0 0 1 2 1 0} feErr]} {
    P "T2_ERROR" $feErr
} else {
    P "T2_OK" 1
    P "T2_NODES" [::FEI2::nodeCount]
}

# --- T3: NON-empty model (nodes present), answernext yes -----------------
*createnode 5 5 5 0 0 0
P "T3_MODEL_NODES" [::FEI2::nodeCount]
set delta3 [file join $outputDir "audit_mesh_seam_weld_feinput2_delta3.fem"]
set chan [open $delta3 w]
puts $chan "BEGIN BULK"
puts $chan "GRID 9401 200. 0. 0."
puts $chan "GRID 9402 210. 0. 0."
puts $chan "GRID 9403 210. 10. 0."
puts $chan "GRID 9404 200. 10. 0."
puts $chan "MAT1 1 210000. 80000. 0.3"
puts $chan "CQUAD4 9401 1 9401 9402 9403 9404"
puts $chan "ENDDATA"
close $chan
catch {hm_answernext yes}
if {[catch {*feinputwithdata2 "#optistruct/optistruct" $delta3 0 0 0 0 0 1 2 1 0} feErr]} {
    P "T3_ERROR" $feErr
} else {
    P "T3_OK" 1
    P "T3_NODES" [::FEI2::nodeCount]
}

# --- T4: non-empty model, answernext yes twice (save-prompt + import) ----
set delta4 [file join $outputDir "audit_mesh_seam_weld_feinput2_delta4.fem"]
set chan [open $delta4 w]
puts $chan "BEGIN BULK"
puts $chan "GRID 9501 300. 0. 0."
puts $chan "GRID 9502 310. 0. 0."
puts $chan "GRID 9503 310. 10. 0."
puts $chan "GRID 9504 300. 10. 0."
puts $chan "MAT1 1 210000. 80000. 0.3"
puts $chan "CQUAD4 9501 1 9501 9502 9503 9504"
puts $chan "ENDDATA"
close $chan
catch {hm_answernext yes}
catch {hm_answernext yes}
if {[catch {*feinputwithdata2 "#optistruct/optistruct" $delta4 0 0 0 0 0 1 2 1 0} feErr]} {
    P "T4_ERROR" $feErr
} else {
    P "T4_OK" 1
    P "T4_NODES" [::FEI2::nodeCount]
}

# --- T5: abaqus reader (vendor pattern) on empty-ish model ---------------
set delta5 [file join $outputDir "audit_mesh_seam_weld_feinput2_delta5.inp"]
set chan [open $delta5 w]
puts $chan "*NODE"
puts $chan "9601, 400., 0., 0."
puts $chan "9602, 410., 0., 0."
puts $chan "9603, 410., 10., 0."
puts $chan "9604, 400., 10., 0."
puts $chan "*ELEMENT, TYPE=S4, ELSET=WELD"
puts $chan "9601, 9601, 9602, 9603, 9604"
close $chan
catch {hm_answernext yes}
if {[catch {*feinputwithdata2 "#abaqus\\abaqus" $delta5 0 0 0 0 0 1 2 1 0} feErr]} {
    P "T5_ERROR" $feErr
} else {
    P "T5_OK" 1
    P "T5_NODES" [::FEI2::nodeCount]
}

P "status" "DONE"
close $channel
exit 0
