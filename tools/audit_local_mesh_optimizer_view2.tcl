set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_lmo_view2_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -encoding ascii -translation lf
proc P {key value} { variable channel; puts $channel "${key}=${value}" }
P "AUDIT_VERSION" $version
foreach cmd {
    hm_fitwindow *fitwindow hm_zoomall *zoomall hm_graphics_create
    hm_graphics_creategraphics hm_graphics_window hm_graphics_setview
    *viewset hm_viewset hm_viewset *viewsave *viewrestore *orientation
    hm_orientation hm_graphics_draw *graphics *windowview *viewwindow
    hm_ui_menubar hm_ui_displaypanel hm_ui_popup hm_ui_update
} {
    P "EXISTS $cmd" [expr {[info commands $cmd] ne ""}]
}
close $channel
exit 0
