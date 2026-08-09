# Why does *contactsurfcreatewithshells abort on HM2022 hmbatch (V9/V10
# probes die there) while it works on HM2019?  Capture the exact error.
#
# Run headless with the same hmbatch invocations as the other audit probes.
# Result: runtime/audit_auto_hole_rbe2_contactsurf22_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_auto_hole_rbe2_contactsurf22_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
namespace eval ::Audit {}
proc ::Audit::node {x y z} {
    catch {*createnode $x $y $z 0 0 0}
    catch {*createmark nodes 1 -1}
    return [lindex [hm_getmark nodes 1] end]
}
proc ::Audit::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    return [hm_latestentityid elems]
}

P "VERSION" $version
source [file join $root modules contact_setup.tcl]
P "MODULE_SOURCED" "ok"

*collectorcreateonly components AUDIT_SHELL "" 11
*currentcollector component AUDIT_SHELL
set elemA [::Audit::quad [list [::Audit::node 0 0 0] [::Audit::node 10 0 0] \
    [::Audit::node 10 10 0] [::Audit::node 0 10 0]]]
set elemB [::Audit::quad [list [::Audit::node 0 0 1] [::Audit::node 10 0 1] \
    [::Audit::node 10 10 1] [::Audit::node 0 10 1]]]
P "ELEMS" "$elemA $elemB"

# step 1: raw command
catch {*clearmark elems 1}
eval *createmark elems 1 [list $elemA]
if {[catch {*contactsurfcreatewithshells RAW_TEST 13 1 0} e]} {
    P "RAW_CREATE" "ERROR: $e"
} else {
    P "RAW_CREATE" "ok"
}
catch {*clearmark elems 1}

# step 2: through module proc with error captured
if {[catch {::ContactSetup::createContactSurf CLI_MAIN [list $elemA] 13 $elemA 0} e]} {
    P "MODULE_CREATE" "ERROR: $e"
} else {
    P "MODULE_CREATE" "ok"
}

P "STATUS" "DONE"
close $channel
exit 0
