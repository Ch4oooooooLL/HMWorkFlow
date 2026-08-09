# Audit probe for modules/geometry_cleanup.tcl native HyperMesh commands.
#
# Verifies existence and behavioural correctness of every *command / hm_command
# used by geometry_cleanup.tcl against the installed HyperMesh build, using the
# module's exact call-site argument patterns plus documented-variant calls where
# the module's pattern is suspected to be wrong.
#
# Run once per build (one hmbatch launch covers everything):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_geometry_cleanup_cmds.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_geometry_cleanup_cmds.tcl
#
# Results: runtime/audit_geometry_cleanup_cmds_<version>.log  (KEY=VALUE, ASCII)

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_geometry_cleanup_cmds_${version}.log"]
set chan [open $reportPath w]
fconfigure $chan -encoding utf-8 -translation lf

proc P {key value} {
    variable chan
    puts $chan "${key}=${value}"
    flush $chan
}

# Run a script, log OK with return value or ERR with error text (ASCII only).
proc T {key script} {
    set code [catch {uplevel 1 $script} value options]
    if {$code} {
        set msg [string map [list "\n" " " "{" "" "}" ""] $value]
        P "$key" "ERR: $msg"
        return 0
    }
    P "$key" "OK: $value"
    return 1
}

P "AUDIT" "geometry_cleanup_cmds"
P "VERSION" $version
P "TCL" [info patchlevel]

# ---------------------------------------------------------------------------
# Phase 1: command existence (both the module's calls and its helpers)
# ---------------------------------------------------------------------------
set nativeCommands {
    *clearmark *createmark *deletemark *createlist *movemark *setoption
    *linefromsurfedge *linefromsurfedgecomp *selfstitchcombine
    *solids_create_from_surfaces *surface_patch *surfacecreateruled
    *surfacefilletremove *surfacemarkremovelinefillets *surfacemode
    *startnotehistorystate *endnotehistorystate *undohistorystate
    *createpoint *surfaceprimitivefrompoints *collectorcreateonly
    *currentcollector *createdoublearray *createarray
    hm_getfilletfacesfrommark hm_getsurfaceedges hm_getverticesfromedge
    hm_getcoordinatesofpointsonline hm_getsurfacesfromedge
    hm_getareaofsurface hm_latestentityid hm_getsolidboundsforsurfaces
    hm_getmark hm_getvalue hm_getentityvalue hm_usermessage
    hm_blockredraw hm_blockmessages hm_blockerrormessages
    hwbrowsermanager hmbr_signals hm_getcollectorname hm_entityinfo
    hm_getlist
}
foreach name $nativeCommands {
    set pat [string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} $name]
    P "EXISTS $name" [expr {[llength [info commands $pat]] > 0}]
}

# ---------------------------------------------------------------------------
# Phase 2: fixture
#   Plate A (quad 0,0 - 20,0 - 20,10 - 0,10) split into two surfaces A1/A2
#   sharing the outline line at x=10, in components AUDIT_SRC / AUDIT_TGT.
#   Box (0..10)^3 built from 6 primitive surfaces in AUDIT_BOX.
#   Surfaces are built one quad at a time with the seam-probe pattern
#   (*createpoint x4, mark all, *surfaceprimitivefrompoints, then delete the
#   construction points), because that exact pattern is stable on HM2019
#   hmbatch while other mark patterns hard-crash it.
# ---------------------------------------------------------------------------
*collectorcreateonly components AUDIT_SRC "" 1
*collectorcreateonly components AUDIT_TGT "" 2
*collectorcreateonly components AUDIT_BOX "" 3
*collectorcreateonly components AUDIT_MOVE "" 4
set compSrc [hm_getvalue comps name=AUDIT_SRC dataname=id]
set compTgt [hm_getvalue comps name=AUDIT_TGT dataname=id]
set compBox [hm_getvalue comps name=AUDIT_BOX dataname=id]
set compMove [hm_getvalue comps name=AUDIT_MOVE dataname=id]

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

set surfA1 [quadSurf 0 0 0  10 0 0  10 10 0  0 10 0]
set surfA2 [quadSurf 10 0 0  20 0 0  20 10 0  10 10 0]
*clearmark surfs 1
*createmark surfs 1 $surfA2
*movemark surfs 1 AUDIT_TGT
*clearmark surfs 1
# Box: 6 faces, each 4 points, closed volume.
set boxFaces {}
foreach face {
    {0 0 0  10 0 0  10 10 0  0 10 0}
    {0 0 10  10 0 10  10 10 10  0 10 10}
    {0 0 0  10 0 0  10 0 10  0 0 10}
    {0 10 0  10 10 0  10 10 10  0 10 10}
    {0 0 0  0 10 0  0 10 10  0 0 10}
    {10 0 0  10 10 0  10 10 10  10 0 10}
} {
    lappend boxFaces [eval quadSurf $face]
}

*createmark surfs 1 all
set allSurfs [hm_getmark surfs 1]
*createmark lines 1 all
set allLines [hm_getmark lines 1]
P "FIXTURE SURFS" [llength $allSurfs]
P "FIXTURE LINES" [llength $allLines]
P "FIXTURE SURFA1" $surfA1
P "FIXTURE SURFA2" $surfA2
P "FIXTURE BOXFACES" [join $boxFaces { }]

set loops [hm_getsurfaceedges $surfA1]
P "EDGES SURFA1 LOOPS" [llength $loops]
set edge0 [lindex [lindex $loops 0] 0]
P "EDGES SURFA1 FIRST" $edge0

# ---------------------------------------------------------------------------
# Phase 3: behavioural tests with the module's exact call patterns
# ---------------------------------------------------------------------------
# 3.1 mark / list basics
T "MARK createmark-single" [list *createmark surfs 1 $surfA1]
T "MARK getmark" [list hm_getmark surfs 1]
T "MARK createmark-list" [list eval *createmark surfs 1 [list $surfA1 $surfA2]]
T "MARK clearmark" [list *clearmark surfs 1]
T "MARK by-comp-id" [list *createmark surfs 2 "by comp id" $compTgt]
T "MARK getmark-bycomp" [list hm_getmark surfs 2]
T "MARK surfaces-alias createmark" [list *createmark surfaces 1 [list $surfA1]]
T "MARK surfaces-alias getmark" [list hm_getmark surfaces 1]
T "MARK surfaces-alias clearmark" [list *clearmark surfaces 1]
T "MARK comps-createmark" [list *createmark comps 1 $compSrc]
T "LIST createlist-empty" [list *createlist lines 1]
T "LIST createlist-fill" [list eval *createlist lines 1 [list $edge0]]
T "LIST hm_getlist" [list hm_getlist lines 1]
T "LIST createlist-two" [list eval *createlist lines 2 [list $edge0]]

# 3.2 geometry queries (module's exact patterns)
T "Q surfaceedges" [list hm_getsurfaceedges $surfA1]
T "Q verticesfromedge" [list hm_getverticesfromedge $edge0]
T "Q coords-pointsonline" [list hm_getcoordinatesofpointsonline $edge0 [list 0.0 1.0]]
T "Q surfacesfromedge" [list hm_getsurfacesfromedge $edge0]
T "Q getareaofsurface" [list hm_getareaofsurface surfs $surfA1]
T "Q linelength" [list hm_linelength $edge0]
T "Q getvalue area" [list hm_getvalue surfs id=$surfA1 dataname=area]
T "Q getvalue collector.id" [list hm_getvalue surfs id=$surfA1 dataname=collector.id]
T "Q getvalue component.id" [list hm_getvalue surfs id=$surfA1 dataname=component.id]
T "Q getvalue componentid" [list hm_getvalue surfs id=$surfA1 dataname=componentid]
T "Q getvalue component" [list hm_getvalue surfs id=$surfA1 dataname=component]
T "Q getvalue collector" [list hm_getvalue surfs id=$surfA1 dataname=collector]
T "Q getentityvalue coordinates" [list hm_getentityvalue surfs $surfA1 coordinates 0]
T "Q getentityvalue area" [list hm_getentityvalue surfs $surfA1 area 0]
T "Q comps dataname=surfaces" [list hm_getvalue comps id=$compSrc dataname=surfaces]
T "Q comps dataname=surfs" [list hm_getvalue comps id=$compSrc dataname=surfs]
T "Q latestentityid surfs" [list hm_latestentityid surfs]
T "Q latestentityid lines" [list hm_latestentityid lines]
T "Q latestentityid solids" [list hm_latestentityid solids]
T "Q getcollectorname" [list hm_getcollectorname comps $compSrc]
T "Q entityinfo name" [list hm_entityinfo name comps $compSrc -byid]
T "Q getvalue comps name" [list hm_getvalue comps id=$compSrc dataname=name]

# 3.3 fillet-face query (module's exact call: comps mark and surfs mark)
*clearmark surfs 1
*createmark surfs 1 all
T "FILLET from surfs mark" [list hm_getfilletfacesfrommark surfs 1 0.0 5.0]
*clearmark comps 1
*createmark comps 1 $compSrc
T "FILLET from comps mark" [list hm_getfilletfacesfrommark comps 1 0.0 5.0]
*clearmark surfs 1

# 3.4 construction-line copy (module's exact calls)
set linesBefore [hm_latestentityid lines]
*clearmark lines 1
*createmark lines 1 $edge0
T "LINE linefromsurfedgecomp" [list *linefromsurfedgecomp lines 1 0]
set linesMid [hm_latestentityid lines]
T "LINE count-after-comp" [list expr {$linesMid - $linesBefore}]
T "LINE linefromsurfedge lines 1" [list *linefromsurfedge lines 1]
set linesMid2 [hm_latestentityid lines]
T "LINE count-after-surfedge" [list expr {$linesMid2 - $linesMid}]
*clearmark lines 1
*createmark lines 1 $edge0
T "LINE linefromsurfedge bare-1" [list *linefromsurfedge 1]
set linesAfter [hm_latestentityid lines]
T "LINE count-after-bare" [list expr {$linesAfter - $linesMid2}]
set constructionLines {}
for {set i [expr {$linesBefore + 1}]} {$i <= $linesAfter} {incr i} {
    lappend constructionLines $i
}
P "LINE construction-ids" [join $constructionLines { }]

# 3.5 delete (construction lines only) + move
*clearmark lines 1
eval *createmark lines 1 $constructionLines
T "DEL deletemark lines" [list *deletemark lines 1]
*createmark surfs 1 $surfA2
T "MOVE movemark to comp" [list *movemark surfs 1 AUDIT_MOVE]
T "MOVE verify comp" [list hm_getvalue surfs id=$surfA2 dataname=collector.id]
*clearmark surfs 1
*createmark surfs 1 $surfA2
T "MOVE movemark back" [list *movemark surfs 1 AUDIT_TGT]

# 3.6 stitching (module's exact patterns: mode 130 then mode 2)
*clearmark surfs 1
*createmark surfs 1 $surfA1
*appendmark surfs 1 $surfA2
T "STITCH mode130" [list *selfstitchcombine 1 130 0.2 0.2]
T "STITCH mode2" [list *selfstitchcombine 1 2 0.2 0.2]

# 3.7 chamfer / fillet removal
# Module's exact call: *surfacefilletremove 1 1 2  (mark 1, then literal 1, 2)
# Documented signature: *surfacefilletremove entity_type mark_id size
*clearmark surfs 1
*createmark surfs 1 $surfA1
*appendmark surfs 1 $surfA2
T "FILLETREMOVE module-call" [list *surfacefilletremove 1 1 2]
T "FILLETREMOVE documented surfs 1 2.0" [list *surfacefilletremove surfs 1 2.0]
T "FILLETREMOVE documented surfs 1 5.0" [list *surfacefilletremove surfs 1 5.0]
# Module's exact call: *surfacemarkremovelinefillets 1 0 5 0 1 0
T "LINEFILLETS module-call" [list *surfacemarkremovelinefillets 1 0.0 5.0 0 1 0]
*clearmark surfs 1

# 3.8 ruled surface creation (module's exact call chain)
# pick two opposite outline lines of surfA1 as the two ruled levels, fill
# line list 1 exactly like the module does (innerLines + baseLines).
set sLoops [hm_getsurfaceedges $surfA1]
set lv1 [lindex [lindex $sLoops 0] 0]
set lv2 [lindex [lindex $sLoops 0] 2]
catch {*clearmark lines 1}
*createmark lines 1 $lv1
set lv1line [lindex [hm_getmark lines 1] 0]
*createmark lines 2 $lv2
set lv2line [lindex [hm_getmark lines 2] 0]
catch {*clearmark lines 1}
catch {*createlist lines 1}
eval *createlist lines 1 [list $lv1line $lv2line]
T "LIST ruled-lines in list1" [list hm_getlist lines 1]
T "SURFMODE 4" [list *surfacemode 4]
T "RULED surfacecreateruled module-call" [list *surfacecreateruled 1 1 0 2 1 0 0]
set surfsAfterRuled [hm_latestentityid surfs]
P "RULED latest-surf-after" $surfsAfterRuled
set ruledNew [expr {$surfsAfterRuled - 8}]
P "RULED new-surf-count" $ruledNew

# 3.9 patch fallback (2022 only; module guards with info commands)
set patched 0
if {[llength [info commands ::*surface_patch]] > 0} {
    catch {*clearmark lines 1}
    eval *createmark lines 1 [list $lv1line $lv2line]
    T "PATCH surface_patch module-call" [list *surface_patch line_mark=1 tangency=best_fit stitch=1 solid_stitch=1 dest_component=original]
    set patched 1
} else {
    P "PATCH surface_patch module-call" "SKIP (command missing)"
}
P "PATCH available" $patched

# 3.10 solids from closed bounds (module's exact chain)
set solidsBefore [hm_latestentityid solids]
*clearmark surfs 1
eval *createmark surfs 1 $boxFaces
T "STITCH box" [list *selfstitchcombine 1 2 0.01 0.01]
T "BOUNDS getsolidboundsforsurfaces" [list hm_getsolidboundsforsurfaces mark=1 exclude_solids=1 find_baffles=0]
T "SOLIDS create module-call" [list *solids_create_from_surfaces 1 4 0 2]
set solidsAfter [hm_latestentityid solids]
P "SOLIDS created-count" [expr {$solidsAfter - $solidsBefore}]
*clearmark surfs 1

# 3.11 history state (module's exact chain, each step logged)
set hisLinesBefore [hm_latestentityid lines]
T "HISTORY startnotehistorystate" [list *startnotehistorystate "AUDIT_GEOM_CLEANUP_TEST"]
T "HISTORY clearmark lines" [list *clearmark lines 1]
T "HISTORY createmark lines edge" [list *createmark lines 1 $edge0]
T "HISTORY linefromsurfedgecomp" [list *linefromsurfedgecomp lines 1 0]
T "HISTORY endnotehistorystate" [list *endnotehistorystate "AUDIT_GEOM_CLEANUP_TEST"]
T "HISTORY undohistorystate" [list *undohistorystate 1]
set hisLinesAfter [hm_latestentityid lines]
P "HISTORY lines-reverted" [expr {$hisLinesAfter == $hisLinesBefore}]

# 3.12 performance-mode calls (module's exact patterns, all catch-wrapped)
T "PERF hm_blockredraw 1" [list hm_blockredraw 1]
T "PERF hm_blockmessages 1" [list hm_blockmessages 1]
T "PERF hm_blockerrormessages 1" [list hm_blockerrormessages 1]
T "PERF setoption block_redraw=1" [list *setoption block_redraw=1]
T "PERF setoption block_messages=1" [list *setoption block_messages=1]
T "PERF hwbrowsermanager flush" [list hwbrowsermanager view flush false]
T "PERF hmbr_signals buffer start" [list hmbr_signals buffer start]
T "PERF hmbr_signals buffer stop" [list hmbr_signals buffer stop]
T "PERF hwbrowsermanager flush true" [list hwbrowsermanager view flush true]
T "PERF setoption block_redraw=0" [list *setoption block_redraw=0]
T "PERF setoption block_messages=0" [list *setoption block_messages=0]
T "PERF hm_blockredraw 0" [list hm_blockredraw 0]
T "PERF hm_blockmessages 0" [list hm_blockmessages 0]
T "PERF hm_blockerrormessages 0" [list hm_blockerrormessages 0]

# 3.13 messaging
T "MSG hm_usermessage" [list hm_usermessage "audit geometry cleanup"]

P "AUDIT DONE" 1
close $chan
exit 0
