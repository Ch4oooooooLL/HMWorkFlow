set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_property_prof_${version}.log"]
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
T "GETUSERPROFILE" {hm_gethmfileuserprofile}
T "LOADPANEL_EXISTS" {}
P "CMDS_PANEL" [lsort [info commands *panel*]]
close $channel
exit 0
