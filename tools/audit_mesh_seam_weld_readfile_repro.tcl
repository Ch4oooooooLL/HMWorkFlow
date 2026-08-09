# Minimal repro: does *readfile hard-crash hmbatch when the snapshot model
# contains elements?  CASE=1 nodes only, CASE=2 nodes+elements.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_mesh_seam_weld_readfile_repro.tcl
#   Results: runtime/audit_mesh_seam_weld_readfile_repro_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set caseSel [expr {[info exists env(RF_CASE)] ? $env(RF_CASE) : "1"}]
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_mesh_seam_weld_readfile_repro_${version}_c${caseSel}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

P "status" "STARTED"
P "version" $version
P "CASE" $caseSel

*createnode 1 2 3 0 0 0
*createnode 4 5 6 0 0 0
*createnode 7 8 9 0 0 0
*createnode 10 11 12 0 0 0
if {$caseSel >= 2} {
    *createmark nodes 1 all
    set ids [hm_getmark nodes 1]
    eval *createlist nodes 1 $ids
    *createelement 104 1 1 1
    P "ELEM_CREATED" 1
}
if {$caseSel >= 3} {
    *collectorcreateonly components RF_COMP "" 11
    *currentcollector component RF_COMP
    P "COMP_CREATED" 1
}
set snapPath [file join $outputDir "readfile_repro_${version}_c${caseSel}.hm"]
catch {file delete -force $snapPath}
catch {hm_answernext yes}
if {[catch {*writefile $snapPath 1} wfErr]} {
    P "WRITEFILE_ERROR" $wfErr
} else {
    P "WRITEFILE_OK" 1
    P "WRITEFILE_SIZE" [file size $snapPath]
}
P "BEFORE_READ" 1
# CASE 4: modify the model AFTER the snapshot was written (extra node), then
# *readfile with NO answer queued -> expect the unsaved-changes confirm dialog.
# CASE 5: same modification but *hm_answernext yes queued before *readfile.
if {$caseSel == 4 || $caseSel == 5} {
    *createnode 99 99 99 0 0 0
    P "MARKER_NODE_CREATED" 1
}
if {$caseSel == 5} {
    catch {hm_answernext yes}
    P "ANSWERNEXT_QUEUED" 1
}
if {[catch {*readfile $snapPath 0} rfErr]} {
    P "READFILE_ERROR" $rfErr
} else {
    P "READFILE_OK" 1
}
P "AFTER_READ" 1

P "status" "DONE"
close $channel
exit 0
