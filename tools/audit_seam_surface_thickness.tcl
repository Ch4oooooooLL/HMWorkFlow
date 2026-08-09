# Final probe: hm_getthickness comps against a REAL imported FE model with
# PSHELL cards (2026-08-08, seam_surface audit). The 2026-08-08 fixture probe
# returned 0.0 for an empty created property; this decides whether the module
# naming::component_thickness primary path can ever return a real value on
# the local builds. Usage: one hmbatch per build, HM_AUDIT_OUT=<abs path>,
# HM_FEM=<abs path to input.fem>.
set fem [expr {[info exists ::env(HM_FEM)] ? $::env(HM_FEM) : ""}]
set outFile [expr {[info exists ::env(HM_AUDIT_OUT)] ? $::env(HM_AUDIT_OUT) : "audit_seam_surface_thick.log"}]
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
if {$fem eq ""} { log "NO_FEM=1"; log "AUDIT=DONE"; close $chan; exit 0 }
trycmd "FEINPUT" [list *feinputwithdata2 "#nastran" $fem 1 0 0 0]
*createmark comps 1 all
set comps [hm_getmark comps 1]
log "COMPS=[join $comps ,]"
foreach cid $comps {
    trycmd "THICK_COMP_$cid" [list hm_getthickness comps $cid]
    trycmd "NAME_COMP_$cid" [list hm_getvalue comps id=$cid dataname=name]
}
*createmark props 1 all
set props [hm_getmark props 1]
log "PROPS=[join $props ,]"
foreach pid $props {
    trycmd "THICK_PROP_$pid" [list hm_getthickness props $pid]
}
log "AUDIT=DONE"
close $chan
exit 0
