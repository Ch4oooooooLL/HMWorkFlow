# *surface_patch parameter variants on a CLOSED line loop (2022 focus).
set root [file dirname [file dirname [file normalize [info script]]]]
set chan [open [file join $root runtime "audit_geomcleanup_dbg5.log"] w]
proc CP {msg} {
    variable chan
    puts $chan $msg
    flush $chan
}
proc T {key script} {
    set code [catch {uplevel 1 $script} value options]
    if {$code} {
        set msg [string map [list "\n" " " "{" "" "}" ""] $value]
        CP "$key ERR: $msg"
    } else {
        CP "$key OK: $value"
    }
}
CP "VERSION [hm_info -appinfo VERSION]"
foreach {x y z} {0 0 0  10 0 0  10 10 0  0 10 0} {
    catch {*createpoint $x $y $z 0}
}
*createmark points 1 all
catch {*surfaceprimitivefrompoints points 1 1 0 0}
*createmark surfs 1 -1
set s1 [lindex [hm_getmark surfs 1] 0]
catch {*clearmark points 1}
*createmark points 1 all
catch {*deletemark points 1}
set loop [lindex [hm_getsurfaceedges $s1] 0]
CP "LOOP [join $loop { }]"
set before [hm_latestentityid surfs]

*clearmark lines 1
eval *createmark lines 1 $loop
T "PATCH module-args" [list *surface_patch line_mark=1 tangency=best_fit stitch=1 solid_stitch=1 dest_component=original]
CP "PATCH surf-after1 [hm_latestentityid surfs]"

*clearmark lines 1
eval *createmark lines 1 $loop
T "PATCH tangency=none" [list *surface_patch line_mark=1 tangency=none stitch=1 solid_stitch=1 dest_component=original]
CP "PATCH surf-after2 [hm_latestentityid surfs]"

*clearmark lines 1
eval *createmark lines 1 $loop
T "PATCH dest=current" [list *surface_patch line_mark=1 tangency=best_fit stitch=1 solid_stitch=1 dest_component=current]
CP "PATCH surf-after3 [hm_latestentityid surfs]"

*clearmark lines 1
eval *createmark lines 1 $loop
T "PATCH minimal" [list *surface_patch line_mark=1]
CP "PATCH surf-after4 [hm_latestentityid surfs]"
CP "PATCH created-total [expr {[hm_latestentityid surfs] - $before}]"
CP "DONE"
close $chan
exit 0
