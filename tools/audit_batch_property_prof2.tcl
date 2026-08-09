set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_property_prof2_${version}.log"]
set channel [open $reportPath w]
proc P {key args} {
    variable channel
    set value [join $args " "]
    set value [string map [list "\"" "" "\n" " " "\r" " " "," "_"] $value]
    puts $channel "${key}=${value}"
}
proc T {key script} {
    variable channel
    set code [catch {uplevel 1 $script} msg]
    set msg [string map [list "\n" " " "\r" " " "," "_"] $msg]
    puts $channel "${key}_CODE=$code"
    puts $channel "${key}_MSG=$msg"
}
P "HM_VERSION" $version
P "FRAMEWORK_EXISTS" [expr {[llength [info commands hm_framework*]] > 0}]
P "FRAMEWORK_CMDS" [lsort [info commands hm_framework*]]
# does the profile flag change anything observable? create a mat with a card
T "CREATE_MAT" {*createentity mats cardimage=MAT1 includeid=0 name=PROF_MAT}
set mid ""
catch {set mid [hm_getvalue mats name=PROF_MAT dataname=id]}
P "MAT_ID" $mid
if {$mid ne ""} {
    T "CARDIMAGE_READ" {hm_getvalue mats id=$mid dataname=cardimage}
    T "READ_E" {hm_getvalue mats id=$mid dataname=E}
    T "SET_E" {*setvalue mats id=$mid STATUS=1 E=210000.0}
}
close $channel
exit 0
