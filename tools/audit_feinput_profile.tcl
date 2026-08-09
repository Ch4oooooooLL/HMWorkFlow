set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_feinput_profile_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line
proc P {key value} { variable channel; puts $channel "${key}=${value}" }
P "status" "STARTED"
P "version" $version
catch {set p [hm_info -appinfo PROFILE]} pe
P "PROFILE_CATCH" [expr {$pe eq "" ? "OK" : "ERR:$pe"}]
catch {*readprofile "optistruct"} rpErr
P "READPROFILE" [expr {$rpErr eq "" ? "OK" : "ERR:$rpErr"}]
set deltaPath [file join $outputDir "audit_feinput_profile_delta.fem"]
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
catch {hm_answernext yes}
if {[catch {*feinputwithdata2 "#optistruct/optistruct" $deltaPath 0 0 0 0 0 1 2 1 0} feErr]} {
    P "AFTER_PROFILE_ERROR" $feErr
} else {
    P "AFTER_PROFILE_OK" 1
}
P "status" "DONE"
close $channel
exit 0
