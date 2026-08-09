set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_feinput_readers_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line
proc P {key value} { variable channel; puts $channel "${key}=${value}" }
P "status" "STARTED"
P "version" $version
namespace eval ::FIR {}
proc ::FIR::nodeCount {} {
    catch {*createmark nodes 1 all}
    set s {}
    catch {set s [hm_getmark nodes 1]}
    catch {*clearmark nodes 1}
    return [llength $s]
}
set deltaPath [file join $outputDir "audit_feinput_readers_delta.fem"]
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
set i 0
foreach reader [list "#optistruct/optistruct" "#nastran/nastran" "#nastran" "#abaqus\abaqus"] {
    incr i
    set before [::FIR::nodeCount]
    catch {hm_answernext yes}
    if {[catch {*feinputwithdata2 $reader $deltaPath 0 0 0 0 0 1 2 1 0} feErr]} {
        P "R${i}_${reader}_ERROR" $feErr
    } else {
        P "R${i}_${reader}_OK" 1
        P "R${i}_${reader}_DELTA" [expr {[::FIR::nodeCount] - $before}]
    }
}
P "status" "DONE"
close $channel
exit 0
