set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_feinput_readers2_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line
proc P {key value} { variable channel; puts $channel "${key}=${value}" }
P "status" "STARTED"
P "version" $version
namespace eval ::FIR2 {}
proc ::FIR2::nodeCount {} {
    catch {*createmark nodes 1 all}
    set s {}
    catch {set s [hm_getmark nodes 1]}
    catch {*clearmark nodes 1}
    return [llength $s]
}
proc ::FIR2::elemCount {} {
    catch {*createmark elems 1 all}
    set s {}
    catch {set s [hm_getmark elems 1]}
    catch {*clearmark elems 1}
    return [llength $s]
}
# Comma-separated free field Nastran
set deltaPath [file join $outputDir "audit_feinput_readers2_delta.fem"]
set chan [open $deltaPath w]
puts $chan "BEGIN BULK"
puts $chan "GRID,9101,,0.0,0.0,0.0"
puts $chan "GRID,9102,,10.0,0.0,0.0"
puts $chan "GRID,9103,,10.0,10.0,0.0"
puts $chan "GRID,9104,,0.0,10.0,0.0"
puts $chan "MAT1,1,210000.0,80000.0,0.3"
puts $chan "CQUAD4,9201,1,9101,9102,9103,9104"
puts $chan "ENDDATA"
close $chan
set i 0
foreach reader [list "#optistruct/optistruct" "#nastran/nastran"] {
    incr i
    set before [::FIR2::nodeCount]
    set beforeE [::FIR2::elemCount]
    catch {hm_answernext yes}
    if {[catch {*feinputwithdata2 $reader $deltaPath 0 0 0 0 0 1 2 1 0} feErr]} {
        P "R${i}_${reader}_ERROR" $feErr
    } else {
        P "R${i}_${reader}_OK" 1
        P "R${i}_${reader}_NODES_DELTA" [expr {[::FIR2::nodeCount] - $before}]
        P "R${i}_${reader}_ELEMS_DELTA" [expr {[::FIR2::elemCount] - $beforeE}]
        catch {*createmark nodes 1 "by id" 9101}
        P "R${i}_N9101" [expr {[llength [hm_getmark nodes 1]] > 0}]
        catch {*clearmark nodes 1}
        catch {*createmark elems 1 "by id" 9201}
        P "R${i}_E9201" [expr {[llength [hm_getmark elems 1]] > 0}]
        catch {*clearmark elems 1}
    }
}
P "status" "DONE"
close $channel
exit 0
