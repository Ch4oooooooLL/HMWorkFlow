# Debug fixture builder for the geometry_cleanup audit (2019 crash hunt).
set root [file dirname [file dirname [file normalize [info script]]]]
set chan [open [file join $root runtime "audit_geomcleanup_dbg.log"] w]
proc CP {msg} {
    variable chan
    puts $chan $msg
    flush $chan
}
CP "VERSION [hm_info -appinfo VERSION]"
foreach step {
    {COLLECTOR_SRC {*collectorcreateonly components AUDIT_SRC "" 1}}
    {COLLECTOR_TGT {*collectorcreateonly components AUDIT_TGT "" 2}}
    {GETID_SRC {hm_getvalue comps name=AUDIT_SRC dataname=id}}
    {GETID_TGT {hm_getvalue comps name=AUDIT_TGT dataname=id}}
    {CURRENTCOLLECTOR {*currentcollector component AUDIT_SRC}}
    {CREATEPOINT {*createpoint 0 0 0 0}}
    {CREATEPOINT2 {*createpoint 10 0 0 0}}
    {CREATEPOINT3 {*createpoint 10 10 0 0}}
    {CREATEPOINT4 {*createpoint 0 10 0 0}}
    {MARK_POINTS {*createmark points 1 -1}}
    {GETMARK_POINTS {hm_getmark points 1}}
    {PRIM_SURF {*surfaceprimitivefrompoints points 1 1 0 0}}
    {MARK_SURFS {*createmark surfs 1 -1}}
    {GETMARK_SURFS {hm_getmark surfs 1}}
} {
    lassign $step label script
    if {[catch {uplevel #0 $script} value options]} {
        CP "$label ERR: $value"
    } else {
        CP "$label OK: $value"
    }
}
CP "DONE"
close $chan
exit 0
