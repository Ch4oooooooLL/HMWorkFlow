# Matrix probe: *displaycollectorsbymark flag semantics on both builds.
# Help order: entity_type mark_id mode elements geometry. The 2026-08-08
# probe showed `off 1 0` turning ELEMENTS off; this matrix resolves the
# geometry flag position and the re-enable behavior. Usage: one hmbatch per
# build, HM_AUDIT_OUT=<abs path>.
set outFile [expr {[info exists ::env(HM_AUDIT_OUT)] ? $::env(HM_AUDIT_OUT) : "audit_seam_surface_disp2.log"}]
set chan [open $outFile w]
proc log {msg} {
    global chan
    puts $chan $msg
    flush $chan
}
proc state {tag} {
    set g ""; set e ""
    catch {set g [hm_entityinfo geometryvisible comps 1]}
    catch {set e [hm_entityinfo elementsvisible comps 1]}
    log "$tag geom=$g elems=$e"
}
catch {log "VERSION=[hm_info -appinfo VERSION] DISPLAY=[hm_info -appinfo DISPLAYVERSION]"}
log "AUDIT=START [clock format [clock seconds] -format %Y-%m-%d_%H:%M:%S]"
foreach {x y z} {0 0 0  10 0 0  10 10 0  0 10 0} { catch {*createpoint $x $y $z 0} }
*createmark points 1 all
catch {*surfaceprimitivefrompoints points 1 1 0 0}
*createmark comps 1 1

state BASELINE
log "--- off 1 1 ---"
catch {*displaycollectorsbymark comps 1 off 1 1}
state AFTER_OFF_1_1
log "--- on 1 1 ---"
catch {*displaycollectorsbymark comps 1 on 1 1}
state AFTER_ON_1_1
log "--- off 0 1 ---"
catch {*displaycollectorsbymark comps 1 off 0 1}
state AFTER_OFF_0_1
log "--- on 0 1 ---"
catch {*displaycollectorsbymark comps 1 on 0 1}
state AFTER_ON_0_1
log "--- off 1 0 ---"
catch {*displaycollectorsbymark comps 1 off 1 0}
state AFTER_OFF_1_0
log "--- on 1 0 ---"
catch {*displaycollectorsbymark comps 1 on 1 0}
state AFTER_ON_1_0
catch {*displaycollectorsbymark comps 1 on 1 1}
log "AUDIT=DONE"
close $chan
exit 0
