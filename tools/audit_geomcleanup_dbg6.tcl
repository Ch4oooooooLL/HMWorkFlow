# *surfacemarkfeatures (official defeature feature-marking) behavior probe.
# 1. markmask angle_surf offset_surf close_orphans fillet_min fillet_max
#    angle_vertex edge_min shape_discontinuity update_only
# Fixture: two coplanar quads sharing an edge (would merge if angle test on),
# plus a perpendicular quad (break angle 90 deg).
set root [file dirname [file dirname [file normalize [info script]]]]
set chan [open [file join $root runtime "audit_geomcleanup_dbg6.log"] w]
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
proc quadSurf {x0 y0 z0 x1 y1 z1 x2 y2 z2 x3 y3 z3} {
    foreach {x y z} [list $x0 $y0 $z0 $x1 $y1 $z1 $x2 $y2 $z2 $x3 $y3 $z3] {
        catch {*createpoint $x $y $z 0}
    }
    *createmark points 1 all
    catch {*surfaceprimitivefrompoints points 1 1 0 0}
    *createmark surfs 1 -1
    set id [lindex [hm_getmark surfs 1] 0]
    catch {*clearmark points 1}
    *createmark points 1 all
    catch {*deletemark points 1}
    return $id
}
set s1 [quadSurf 0 0 0  10 0 0  10 10 0  0 10 0]
set s2 [quadSurf 10 0 0  20 0 0  20 10 0  10 10 0]
set s3 [quadSurf 0 0 0  10 0 0  10 0 10  0 0 10]
CP "SURFS $s1 $s2 $s3"

# fillet-only test (angle test off, no fillets present -> expect no-op)
*clearmark surfs 1
*createmark surfs 1 all
T "SMF fillet-only" [list *surfacemarkfeatures 1 -1 -1 0 0 5 -1 -1 -1 0]
CP "SMF mark-after [join [hm_getmark surfs 1] { }]"

# angle test on (break angle 45): coplanar pair merges, vertical stays
*clearmark surfs 1
*createmark surfs 1 all
T "SMF angle45" [list *surfacemarkfeatures 1 45 0.5 0 -1 -1 -1 -1 -1 0]
CP "SMF surfs-after [join [hm_getmark surfs 1] { }]"
*createmark surfs 1 all
CP "SMF total-surfs [join [hm_getmark surfs 1] { }]"

CP "DONE"
close $chan
exit 0
