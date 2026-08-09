# Focused follow-up probes for geometry_cleanup audit findings:
#  1. *linefromsurfedgecomp inside an active *startnotehistorystate (crash?)
#  2. *surfacefilletremove argument semantics (entity_type numeric vs word)
#  3. *surfacemarkremovelinefillets error variants
#  4. hm_getentityvalue surfs area semantics
# Fixture: two adjacent quads (seam-probe pattern), plus 3rd quad.
set root [file dirname [file dirname [file normalize [info script]]]]
set chan [open [file join $root runtime "audit_geomcleanup_dbg4.log"] w]
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
set s3 [quadSurf 0 0 10  10 0 10  10 10 10  0 10 10]
CP "SURFS $s1 $s2 $s3"

set loops [hm_getsurfaceedges $s1]
set edge0 [lindex [lindex $loops 0] 0]
CP "EDGE0 $edge0"

# --- 1. history-state isolation: each step logged, crash point visible -------
CP "H1 startnotehistorystate"
T "H1 start" [list *startnotehistorystate "AUDIT_H1"]
CP "H2 clearmark lines"
T "H2 clear" [list *clearmark lines 1]
CP "H3 createmark lines edge0"
T "H3 mark" [list *createmark lines 1 $edge0]
CP "H4 linefromsurfedgecomp"
T "H4 lfsec" [list *linefromsurfedgecomp lines 1 0]
CP "H5 endnotehistorystate"
T "H5 end" [list *endnotehistorystate "AUDIT_H1"]
CP "H6 undohistorystate 1"
T "H6 undo" [list *undohistorystate 1]

# --- 2. surfacefilletremove semantics ---------------------------------------
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "FR numeric-type mark1" [list *surfacefilletremove 1 1 2]
CP "FR after numeric-type surfs [join [hm_getmark surfs 1] { }]"
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "FR bogus-type" [list *surfacefilletremove bogus 1 2]
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "FR word-type surfs" [list *surfacefilletremove surfs 1 2]
T "FR word-type surfaces" [list *surfacefilletremove surfaces 1 2]
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "FR word-type size0" [list *surfacefilletremove surfs 1 0]

# --- 3. surfacemarkremovelinefillets variants --------------------------------
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF module-exact" [list *surfacemarkremovelinefillets 1 0.0 5.0 0 1 0]
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF word-type" [list *surfacemarkremovelinefillets surfs 1 0.0 5.0 0 1 0]
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF min-angle-90" [list *surfacemarkremovelinefillets 1 0.0 5.0 90 1 0]
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF doublearray-created" {
    catch {*createdoublearray 1 3 0.0 0.0 0.0}
    *surfacemarkremovelinefillets 1 0.0 5.0 0 1 1
}

# --- 4. hm_getentityvalue area semantics -------------------------------------
T "EV area" [list hm_getentityvalue surfs $s1 area 0]
T "EV collector" [list hm_getentityvalue surfs $s1 collector 0]
T "EV collector.id" [list hm_getentityvalue surfs $s1 collector.id 0]
T "GV area" [list hm_getvalue surfs id=$s1 dataname=area]
T "GV points coordinates" [list hm_getvalue points id=1 dataname=coordinates]
T "GV points x" [list hm_getvalue points id=1 dataname=x]
T "EV points coordinates" [list hm_getentityvalue points 1 coordinates 0]
T "GV lines coordinates" [list hm_getvalue lines id=$edge0 dataname=coordinates]
catch {*createpoint 5 5 5 0}
*createmark points 1 -1
set livePt [lindex [hm_getmark points 1] 0]
CP "LIVEPT $livePt"
T "GV livept coordinates" [list hm_getvalue points id=$livePt dataname=coordinates]
T "GV livept x" [list hm_getvalue points id=$livePt dataname=x]
T "EV livept coordinates" [list hm_getentityvalue points $livePt coordinates 0]
T "EV livept x" [list hm_getentityvalue points $livePt x 0]
*createmark points 1 all
catch {*deletemark points 1}

# --- 5. linefilletremoval extra variants --------------------------------------
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF empty-mark count0" [list *surfacemarkremovelinefillets 1 0.0 5.0 0 1 0]
*clearmark surfs 1
T "LF cleared-mark count0" [list *surfacemarkremovelinefillets 1 0.0 5.0 0 1 0]
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF dblarray-created count0" {
    catch {*createdoublearray 1 1 0.0}
    *surfacemarkremovelinefillets 1 0.0 5.0 0 1 0
}
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF dblarray-created count1" {
    catch {*createdoublearray 1 3 0.0 0.0 0.0}
    *surfacemarkremovelinefillets 1 0.0 5.0 0 1 1
}
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF wordtype-first" [list *surfacemarkremovelinefillets surfs 1 0.0 5.0 0 1 0]
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF angle90 count0" [list *surfacemarkremovelinefillets 1 0.0 5.0 90 1 0]
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF dblarray-created count3" {
    catch {*createdoublearray 1 3 0.0 0.0 0.0}
    *surfacemarkremovelinefillets 1 0.0 5.0 0 1 3
}
*clearmark surfs 1
*createmark surfs 1 $s1
*appendmark surfs 1 $s2
T "LF empty-mark2 count1" {
    *clearmark surfs 2
    *surfacemarkremovelinefillets 2 0.0 5.0 0 1 1
}
*clearmark surfs 1
T "FR empty-mark" [list *surfacefilletremove surfs 1 2]
T "FR mark0" [list *surfacefilletremove surfs 0 2]

CP "DONE"
close $chan
exit 0
