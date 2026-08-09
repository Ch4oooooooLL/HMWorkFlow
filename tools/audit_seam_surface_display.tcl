# Mini probe: hm_entityinfo display-state read + *displaycollectorsbymark flag
# order (2026-08-08, seam_surface audit follow-up).
#
# Help documents *displaycollectorsbymark as:
#   entity_type mark_id mode elements geometry
# The module (modules/seam_surface/state.tcl) calls:
#   geometry restore -> <on|off> 1 0
#   elements restore -> <on|off> 0 1
# which is consistent with the order <mode> <geometry> <elements> instead.
# hm_getvalue comps dataname=visible/displayed is invalid on both local
# builds (2026-08-08 probe), so the order is measured through hm_entityinfo.
#
# Usage: one hmbatch per build with HM_AUDIT_OUT=<abs path>.
set outFile [expr {[info exists ::env(HM_AUDIT_OUT)] ? $::env(HM_AUDIT_OUT) : "audit_seam_surface_disp.log"}]
set chan [open $outFile w]
proc log {msg} {
    global chan
    puts $chan $msg
    flush $chan
}
proc trycmd {label args} {
    set code [catch {uplevel #0 {*}$args} value options]
    if {$code} { log "$label=ERR {$value}" } else { log "$label=OK {$value}" }
}
catch {log "VERSION=[hm_info -appinfo VERSION] DISPLAY=[hm_info -appinfo DISPLAYVERSION]"}
log "AUDIT=START [clock format [clock seconds] -format %Y-%m-%d_%H:%M:%S]"

set pat [string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} hm_entityinfo]
log "EXIST_hm_entityinfo=[expr {[llength [info commands $pat]] > 0}]"
log "EXIST_hm_getvalue=[expr {[llength [info commands [string map {* {\*}} hm_getvalue]]] > 0}]"

foreach {x y z} {0 0 0  10 0 0  10 10 0  0 10 0} { catch {*createpoint $x $y $z 0} }
*createmark points 1 all
catch {*surfaceprimitivefrompoints points 1 1 0 0}
*createmark comps 1 1

log "--- baseline ---"
trycmd "ENTINFO_GEOM" [list hm_entityinfo geometryvisible comps 1]
trycmd "ENTINFO_ELEMS" [list hm_entityinfo elementsvisible comps 1]

log "--- off 1 0 (module: geometry restore off) ---"
trycmd "DISP_OFF_1_0" [list *displaycollectorsbymark comps 1 off 1 0]
trycmd "ENTINFO_GEOM" [list hm_entityinfo geometryvisible comps 1]
trycmd "ENTINFO_ELEMS" [list hm_entityinfo elementsvisible comps 1]

log "--- on 1 0 (module: geometry restore on) ---"
trycmd "DISP_ON_1_0" [list *displaycollectorsbymark comps 1 on 1 0]
trycmd "ENTINFO_GEOM" [list hm_entityinfo geometryvisible comps 1]
trycmd "ENTINFO_ELEMS" [list hm_entityinfo elementsvisible comps 1]

log "--- off 0 1 (module: elements restore off) ---"
trycmd "DISP_OFF_0_1" [list *displaycollectorsbymark comps 1 off 0 1]
trycmd "ENTINFO_GEOM" [list hm_entityinfo geometryvisible comps 1]
trycmd "ENTINFO_ELEMS" [list hm_entityinfo elementsvisible comps 1]

log "--- on 0 1 (module: elements restore on) ---"
trycmd "DISP_ON_0_1" [list *displaycollectorsbymark comps 1 on 0 1]
trycmd "ENTINFO_GEOM" [list hm_entityinfo geometryvisible comps 1]
trycmd "ENTINFO_ELEMS" [list hm_entityinfo elementsvisible comps 1]

log "--- restore all on 1 1 ---"
trycmd "DISP_ON_1_1" [list *displaycollectorsbymark comps 1 on 1 1]
trycmd "ENTINFO_GEOM" [list hm_entityinfo geometryvisible comps 1]
trycmd "ENTINFO_ELEMS" [list hm_entityinfo elementsvisible comps 1]

catch {*clearmark comps 1}
log "AUDIT=DONE"
close $chan
exit 0
