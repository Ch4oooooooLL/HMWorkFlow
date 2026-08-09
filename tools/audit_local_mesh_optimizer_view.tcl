# ============================================================================
# Audit probe 7: view-fit command candidates (hm_viewfit missing in module).
# Results -> runtime/audit_lmo_view_<VERSION>.log
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_lmo_view_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -encoding ascii -translation lf

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc try {key script} {
    if {[catch {uplevel 1 $script} result options]} {
        P $key "ERROR:$result"
    } else {
        P $key $result
    }
}

P "AUDIT_VERSION" $version

foreach cmd {
    hm_viewfit hm_viewfitall hm_view *viewall *viewfit *viewfull *windowfit
    *fitview *zoomtofit hm_graphics hm_setgraphics *draw *display *window
    hm_usermessage hm_ui_show hm_ui
} {
    P "EXISTS $cmd" [expr {[info commands $cmd] ne ""}]
}

# hm_info view-related keys
try {HM_INFO_VIEW} {string trim [hm_info view]}
try {HM_INFO_VIEW1} {string trim [hm_info view1]}
try {HM_INFO_WINDOW} {string trim [hm_info window]}
try {HM_INFO_GRAPHICS} {string trim [hm_info graphics]}
try {HM_INFO_CURRENTVIEW} {string trim [hm_info currentview]}

close $channel
exit 0
