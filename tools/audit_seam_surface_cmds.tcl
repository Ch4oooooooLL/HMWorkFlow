# Audit probe for the geometry seam_surface module (2026-08-08).
#
# Covers the commands NOT behaviorally verified by the 2026-08-07 dual-version
# alignment (see docs/geometry_seam_dual_version_alignment_2026-08-07.md):
#   * displaycollectorsbymark flag order (elements vs geometry)
#   * undohistorystate rollback in batch
#   * hm_findclosestpointonsurface / hm_getcoordinatesfromnearestsurface
#   * edgesmarkaddpoints point-count semantics
#   * hm_getthickness behavior with an assigned property
#   * setoption/hm_getoption cleanup_tolerance roundtrip
#   * hm_getvalue surfs dataname sweep (collector.id ... collector)
#   * existence of GUI panels and alternative candidates in batch
#
# Run one hmbatch per build (fresh model each):
#   HM_AUDIT_OUT=<abs path> '<Altair>'\<year>\hm\bin\win64\hmbatch.exe \
#       -nocommand -nouserprofiledialog -tcl tools\audit_seam_surface_cmds.tcl
# Results are KEY=VALUE lines written to the file given by HM_AUDIT_OUT
# (hmbatch has no stdout channel). Script always exits 0.
set outFile [expr {[info exists ::env(HM_AUDIT_OUT)] ? $::env(HM_AUDIT_OUT) : "audit_seam_surface.log"}]
set chan [open $outFile w]
proc log {msg} {
    global chan
    puts $chan $msg
    flush $chan
}
proc trycmd {label args} {
    set code [catch {uplevel #0 {*}$args} value options]
    if {$code} {
        log "$label=ERR {$value}"
    } else {
        log "$label=OK {$value}"
    }
}
proc exists {name} {
    set pattern [string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} $name]
    return [expr {[llength [info commands $pattern]] > 0}]
}

catch {log "VERSION=[hm_info -appinfo VERSION] DISPLAY=[hm_info -appinfo DISPLAYVERSION]"}
log "AUDIT=START [clock format [clock seconds] -format %Y-%m-%d_%H:%M:%S]"

# ---------------- fixture: one plate (1 surf, 4 lines, 4 points) ----------------
foreach {x y z} {0 0 0  10 0 0  10 10 0  0 10 0} {
    catch {*createpoint $x $y $z 0}
}
*createmark points 1 all
set pts [hm_getmark points 1]
catch {*surfaceprimitivefrompoints points 1 1 0 0}
*createmark surfs 1 all
set surfs [hm_getmark surfs 1]
*createmark lines 1 all
set lines [hm_getmark lines 1]
log "FIXTURE=surfs=[join $surfs ,] lines=[join $lines ,] points=[join $pts ,]"
set surf [lindex $surfs 0]
set line [lindex $lines 0]
set pt [lindex $pts 0]

# ---------------- existence battery ----------------
log "--- existence ---"
foreach name {*connect_surfaces_11 *linearsurfacebetweenlines *multi_surfs_lines_merge \
    *selfstitchcombine *surfacemarksplitwithlines *duplicatemark *solid_offset_from_surfs \
    *boolean_merge_solids *trim_solids_by_surfaces *deletesolidswithelems \
    *offset_surfaces_and_modify *projectpointstoedges *verticescombine *edgesmarkaddpoints \
    *edgesmarkuntrim *deletemark *movemark *displaycollectorsbymark *currentcollector \
    *startnotehistorystate *endnotehistorystate *undohistorystate *createlist *setoption \
    *createentity *setvalue *createpoint *surfaceprimitivefrompoints \
    hm_getmark hm_getlist hm_getvalue hm_getthickness hm_getoption hm_info \
    hm_getsurfaceedges hm_getsurfacesfromedge hm_getlinesfromsurface hm_getedgesfromsurface \
    hm_getsurfacesfromline hm_getcurrentcollector hm_findclosestpointonsurface \
    hm_getcoordinatesfromnearestsurface hm_getcoordinatesofpointsonline hm_linelength \
    hm_getareaofsurface hm_getvolumeofsolid hm_errormessage hm_redraw hm_private_frwk \
    hm_blockbrowserupdate hm_findprojected \
    *surfmark_trim_by_surfmark *surfmark_trim_by_elemmark \
    *createmarkpanel *createlistpanel *createlistbypathpanel *editmarkpanel} {
    log "EXIST $name=[expr {[exists $name] ? 1 : 0}]"
}

# ---------------- read-only queries ----------------
log "--- read-only ---"
trycmd "GETSURFACEEDGES" [list hm_getsurfaceedges $surf]
trycmd "COORDSONLINE" [list hm_getcoordinatesofpointsonline $line [list 0.0 0.5 1.0]]
trycmd "CLOSESTONSURE" [list hm_findclosestpointonsurface 0 0 0 $surf]
trycmd "COORDSNEARESTSURF" [list hm_getcoordinatesfromnearestsurface 0 0 0 [list $surf]]
trycmd "LINELENGTH" [list hm_linelength $line]
trycmd "SURFAREA" [list hm_getareaofsurface surfs $surf]
foreach dn {collector.id component.id componentid component collector} {
    trycmd "GETVALUE_SURF_$dn" [list hm_getvalue surfs id=$surf dataname=$dn]
}
foreach dn {visible displayed} {
    trycmd "GETVALUE_COMP_$dn" [list hm_getvalue comps id=1 dataname=$dn]
}
trycmd "GETVALUE_COMP_SURFACES" [list hm_getvalue comps id=1 dataname=surfaces]
trycmd "GETVALUE_COMP_SURFS" [list hm_getvalue comps id=1 dataname=surfs]
trycmd "GETOPTION_CLEANUP" [list hm_getoption cleanup_tolerance]
trycmd "CURRENTCOMPONENT" [list hm_info currentcomponent]
trycmd "THICKNESS_NOPROP" [list hm_getthickness comps 1]

# ---------------- setoption roundtrip ----------------
log "--- setoption ---"
set old ""
catch {set old [hm_getoption cleanup_tolerance]}
trycmd "SETOPTION_SET" [list *setoption cleanup_tolerance=0.5]
trycmd "GETOPTION_AFTER" [list hm_getoption cleanup_tolerance]
if {$old ne ""} { catch {*setoption cleanup_tolerance=$old} }
trycmd "GETOPTION_RESTORED" [list hm_getoption cleanup_tolerance]

# ---------------- hm_getthickness with a property ----------------
log "--- thickness ---"
set cid ""
if {![catch {*createentity comps name=audit_comp} e1]} {
    *createmark comps 1 "by name" audit_comp
    set cid [lindex [hm_getmark comps 1] 0]
}
log "THICKNESS_COMP_ID=$cid"
if {$cid ne ""} {
    set pid ""
    if {![catch {*createentity props name=audit_prop cardimage=pshell} e2]} {
        *createmark props 1 "by name" audit_prop
        set pid [lindex [hm_getmark props 1] 0]
    }
    log "THICKNESS_PROP_ID=$pid"
    if {$pid ne ""} {
        trycmd "THICKNESS_SET_PROP" [list *setvalue props id=$pid thickness=2.5]
        # NOTE: *setvalue props id=X "T"=2.5 (card-field form) crashed the
        # hmbatch interpreter on 2022.0.0.33 (probe died there); removed.
        trycmd "THICKNESS_ASSIGN" [list *setvalue comps id=$cid propertyid=$pid]
        trycmd "THICKNESS_READ" [list hm_getthickness comps $cid]
    }
}

# ---------------- displaycollectorsbymark flag order ----------------
# Help syntax: *displaycollectorsbymark entity_type mark_id mode elements geometry
# Module state.tcl calls: geometry restore -> mode,1,0 ; elements restore -> mode,0,1
# Determine empirically which trailing flag drives comps dataname=visible.
log "--- displaycollectorsbymark ---"
set vis0 ""; set disp0 ""
catch {set vis0 [hm_getvalue comps id=1 dataname=visible]}
catch {set disp0 [hm_getvalue comps id=1 dataname=displayed]}
log "DISP_BASELINE visible=$vis0 displayed=$disp0"
*createmark comps 1 1
trycmd "DISP_OFF_1_0" [list *displaycollectorsbymark comps 1 off 1 0]
set vis1 ""; set disp1 ""
catch {set vis1 [hm_getvalue comps id=1 dataname=visible]}
catch {set disp1 [hm_getvalue comps id=1 dataname=displayed]}
log "DISP_AFTER_OFF_1_0 visible=$vis1 displayed=$disp1"
trycmd "DISP_ON_1_0" [list *displaycollectorsbymark comps 1 on 1 0]
trycmd "DISP_OFF_0_1" [list *displaycollectorsbymark comps 1 off 0 1]
set vis2 ""; set disp2 ""
catch {set vis2 [hm_getvalue comps id=1 dataname=visible]}
catch {set disp2 [hm_getvalue comps id=1 dataname=displayed]}
log "DISP_AFTER_OFF_0_1 visible=$vis2 displayed=$disp2"
trycmd "DISP_ON_0_1" [list *displaycollectorsbymark comps 1 on 0 1]
set vis3 ""; set disp3 ""
catch {set vis3 [hm_getvalue comps id=1 dataname=visible]}
catch {set disp3 [hm_getvalue comps id=1 dataname=displayed]}
log "DISP_AFTER_ON_0_1 visible=$vis3 displayed=$disp3"
trycmd "DISP_RESTORE_ALL" [list *displaycollectorsbymark comps 1 on 1 1]

# ---------------- undo rollback in batch ----------------
log "--- undo ---"
if {[exists hm_private_frwk]} { catch {hm_private_frwk enablehistoryfromtcl 1} }
*createmark points 1 all
set before [llength [hm_getmark points 1]]
log "UNDO_POINTS_BEFORE=$before"
trycmd "UNDO_START" [list *startnotehistorystate audit_undo]
trycmd "UNDO_CREATE" [list *createpoint 1 1 1 0]
trycmd "UNDO_END" [list *endnotehistorystate audit_undo]
*createmark points 1 all
set after [llength [hm_getmark points 1]]
log "UNDO_POINTS_AFTER=$after"
trycmd "UNDO_ROLLBACK" [list *undohistorystate 1]
*createmark points 1 all
set rolled [llength [hm_getmark points 1]]
log "UNDO_POINTS_ROLLED=$rolled"

# ---------------- edgesmarkaddpoints semantics ----------------
log "--- edgesmarkaddpoints ---"
*createmark lines 1 all
set linesBefore [lsort -integer [hm_getmark lines 1]]
*createmark points 1 all
set ptsBefore [llength [hm_getmark points 1]]
*createmark lines 1 $line
trycmd "EDGESADDPOINTS" [list *edgesmarkaddpoints 1 3]
*createmark points 1 all
set ptsAfter [llength [hm_getmark points 1]]
*createmark lines 1 all
set linesAfter [lsort -integer [hm_getmark lines 1]]
log "EDGESADDPOINTS_NEW_POINTS=[expr {$ptsAfter-$ptsBefore}]"
log "EDGESADDPOINTS_LINES_BEFORE=[join $linesBefore ,]"
log "EDGESADDPOINTS_LINES_AFTER=[join $linesAfter ,]"
set renumbered [expr {[join $linesBefore ,] eq [join $linesAfter ,] ? 0 : 1}]
log "EDGESADDPOINTS_LINE_RENUMBERED=$renumbered"

# ---------------- selfstitchcombine standalone ----------------
log "--- selfstitchcombine ---"
*createmark surfs 1 $surf
trycmd "SELFSTITCH_134" [list *selfstitchcombine 1 134 0.2 0.2]
trycmd "SELFSTITCH_130" [list *selfstitchcombine 1 130 0.2 0.2]
trycmd "SELFSTITCH_6" [list *selfstitchcombine 1 6 0.2 0.2]

# ---------------- empty createlist (ruled-surface endpoints) ----------------
# Point insertion above can renumber the fixture lines, so use one of the
# live post-insertion IDs instead of the stale pre-insertion $line value.
log "--- createlist ---"
set liveLine [lindex $linesAfter 0]
trycmd "CREATELIST_EMPTY_NODES" [list *createlist nodes 1]
trycmd "CREATELIST_EMPTY_NODES2" [list *createlist nodes 2]
trycmd "CREATELIST_LINE" [list *createlist lines 2 $liveLine]
trycmd "GETLIST_LINES" [list hm_getlist lines 2]
trycmd "GETLIST_NODES_EMPTY" [list hm_getlist nodes 1]

# ---------------- cleanup ----------------
foreach type {points lines surfs solids comps props} {
    foreach markId {1 2} { catch {*clearmark $type $markId} }
}
log "AUDIT=DONE"
close $chan
exit 0
