# MidSurf module supplementary probe (part 3).
#
# 1. Where do the 17-arg fallback's extracted surfaces actually go?
#    (17-arg layout misaligns new_or_curr_comp; probe confirms the surfaces
#    land in the CURRENT component, not in "Middle Surface".)
# 2. hm_getsurfacethicknessvalues MARK form (single call for all points)
#    vs the module's per-point loop - candidate better API.
# 3. hm_getcompthickness / hm_estimategeomthicknesslimits functional smoke.
#
# Run headless, one hmbatch per installed build:
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_midsurf_alt.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe"   -nocommand -nouserprofiledialog -tcl tools/audit_midsurf_alt.tcl
#
# Results: runtime/audit_midsurf_alt_<version>.log (ASCII KEY=VALUE).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_midsurf_alt_${version}.log"]
set channel [open $reportPath w]
proc P {key value} {
    global channel
    puts $channel "${key}=${value}"
    flush $channel
}
proc try {label args} {
    if {[catch {uplevel #0 {*}$args} value]} {
        P "$label" "ERR [regsub -all {\s+} [string trim $value] { }]"
        return 0
    }
    P "$label" "OK"
    return 1
}
proc query {label script} {
    set rc [catch {uplevel #0 $script} value]
    P "${label}_RC" $rc
    P "${label}_VALUE" [regsub -all {\s+} [string trim $value] { }]
    if {$rc} { return "" }
    return $value
}
proc has {name} {
    set pat [string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} $name]
    expr {[llength [info commands $pat]] > 0}
}

P "VERSION" $version

# --- fixture: two parallel sheets 10x10, 2 mm apart, in SRC_SHEET -----------
try COLLECTOR_SHEET [list *collectorcreateonly components SRC_SHEET "" 1]
try CURRENT_SHEET [list *currentcollector component SRC_SHEET]
foreach {x y z} {0 0 10  10 0 10  10 10 10  0 10 10  0 0 12  10 0 12  10 10 12  0 10 12} {
    catch {*createpoint $x $y $z 0}
}
catch {*clearmark points 1}
*createmark points 1 all
set pts [lsort -integer [hm_getmark points 1]]
catch {*clearmark points 1}
eval *createmark points 1 [lrange $pts 0 3]
try SURFP1 [list *surfaceprimitivefrompoints points 1 1 0 0]
catch {*clearmark points 1}
eval *createmark points 1 [lrange $pts 4 7]
try SURFP2 [list *surfaceprimitivefrompoints points 1 1 0 0]

# --- 19-arg extraction -> rename away -> 17-arg extraction ------------------
catch {*clearmark surfs 1}
*createmark surfs 1 all
set cmd19 [list *midsurface_extract_10 surfaces 1 -1 0 1 1 9 0 2.0 0 0 10.0 0 0 0.5 undefined 0 0 1]
try EXTRACT_19ARGS $cmd19
set midId [query MID_COMP {hm_entityinfo id comps "Middle Surface" -byname}]
if {$midId ne "" && $midId ne 0} {
    # mark-form thickness read on the midsurface points (candidate better API)
    catch {*clearmark points 1}
    *createmark points 1 "by comp id" $midId
    set midPts [hm_getmark points 1]
    P "MID_POINTS_BY_COMP" [join $midPts { }]
    query THICK_MARK_FORM [list hm_getsurfacethicknessvalues points 1 0]
    # per-point loop baseline (module's approach)
    set loopReads {}
    foreach pt $midPts {
        if {![catch {set raw [hm_getsurfacethicknessvalues points $pt]}]} {
            lappend loopReads [llength $raw]
        }
    }
    P "PER_POINT_READ_COUNTS" [join $loopReads { }]
    try RENAME_MID [list *renamecollector component "Middle Surface" "MID_SHEET_T2"]
}

# --- 17-arg fallback: where do the surfaces go? -----------------------------
try COLLECTOR_SRC2 [list *collectorcreateonly components SRC2 "" 2]
try CURRENT_SRC2 [list *currentcollector component SRC2]
foreach {x y z} {0 0 20  10 0 20  10 10 20  0 10 20  0 0 22  10 0 22  10 10 22  0 10 22} {
    catch {*createpoint $x $y $z 0}
}
catch {*clearmark points 1}
*createmark points 1 all
set pts2 [lsort -integer [hm_getmark points 1]]
catch {*clearmark points 1}
eval *createmark points 1 [lrange $pts2 0 3]
try SURFP2_1 [list *surfaceprimitivefrompoints points 1 1 0 0]
catch {*clearmark points 1}
eval *createmark points 1 [lrange $pts2 4 7]
try SURFP2_2 [list *surfaceprimitivefrompoints points 1 1 0 0]
query SRC2_SURFS_BEFORE [list hm_getvalue comps name=SRC2 dataname=surfaces]
catch {*clearmark surfs 1}
*createmark surfs 1 all
set cmd17 [list *midsurface_extract_10 surfaces 1 -1 0 1 1 9 0 2.0 10.0 0 0 0.5 undefined 0 0 1]
try EXTRACT_17ARGS $cmd17
query MID_COMP_AFTER_17 {hm_entityinfo id comps "Middle Surface" -byname}
query SRC2_SURFS_AFTER [list hm_getvalue comps name=SRC2 dataname=surfaces]
query ANY_NEW_SURF_COMP {hm_getvalue surfs id=3 dataname=collector.id}
catch {*clearmark surfs 1}
*createmark surfs 1 all
P "ALL_SURFS_AFTER_17" [join [hm_getmark surfs 1] { }]
catch {*clearmark comps 1}
*createmark comps 1 all
P "ALL_COMPS" [join [hm_getmark comps 1] { }]

# --- undocumented thickness helpers (existence + functional smoke) -----------
P "EXISTS hm_getcompthickness" [expr {[has hm_getcompthickness] ? 1 : 0}]
query HM_GETCOMPTHICKNESS [list hm_getcompthickness SRC_SHEET]
P "EXISTS hm_estimategeomthicknesslimits" [expr {[has hm_estimategeomthicknesslimits] ? 1 : 0}]
query HM_ESTIMATE_GEOM_LIMITS [list hm_estimategeomthicknesslimits surfs 1 2]
query HM_GETTHICKNESS_AFTER [list hm_getthickness comps [hm_entityinfo id comps MID_SHEET_T2 -byname]]

close $channel
exit 0
