# Regression smoke: component id order must not replace the explicit
# first-component/second-component roles from the two selection panels.

set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
namespace eval ::SolidSeam {
    variable selectedComponentIds {}
    variable primaryComponentIds {}
    variable secondaryComponentIds {}
}
namespace eval ::HWFlow {
    variable selections {}
}

proc ::SolidSeam::txt {zh en} { return $en }
proc ::SolidSeam::log {level message} {}
proc ::HWFlow::nativeMarkPanel {entityType markSlot prompt} {
    variable selections
    set result [lindex $selections 0]
    set selections [lrange $selections 1 end]
    return $result
}

source -encoding utf-8 [file join $root modules solid_seam tcl component_selector.tcl]

set failures {}
set ::HWFlow::selections [list [list 20] [list 10]]
set selected [::SolidSeam::selectComponents]
if {$selected ne {20 10}} {
    lappend failures "selection order changed: expected {20 10}, got {$selected}"
}
if {$::SolidSeam::primaryComponentIds ne {20} || $::SolidSeam::secondaryComponentIds ne {10}} {
    lappend failures "component roles were not preserved"
}

set ::HWFlow::selections [list [list 30 40]]
set code [catch {::SolidSeam::selectComponents} errorText]
if {!$code || [string first "exactly one first component" $errorText] < 0} {
    lappend failures "multi-select first panel was not rejected: $errorText"
}

set reportPath [file join $root runtime solid_seam_component_order_smoke.log]
set channel [open $reportPath w]
if {[llength $failures] == 0} {
    puts $channel "PASS first=20 second=10 selected={20 10}"
} else {
    puts $channel "FAIL [join $failures {; }]"
}
close $channel
exit [expr {[llength $failures] == 0 ? 0 : 1}]
