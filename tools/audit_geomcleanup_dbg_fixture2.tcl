# Variant isolation for the *surfaceprimitivefrompoints crash on HM2019.
# HM_FIX_VARIANT = all | four | minus1 | four_tol
set root [file dirname [file dirname [file normalize [info script]]]]
set variant [expr {[info exists ::env(HM_FIX_VARIANT)] ? $::env(HM_FIX_VARIANT) : "all"}]
set chan [open [file join $root runtime "audit_geomcleanup_dbg_${variant}.log"] w]
proc CP {msg} {
    variable chan
    puts $chan $msg
    flush $chan
}
CP "VERSION [hm_info -appinfo VERSION]"
CP "VARIANT $variant"
*collectorcreateonly components AUDIT_SRC "" 1
foreach {x y z} {0 0 0  10 0 0  10 10 0  0 10 0  0 0 5  10 0 5  10 10 5  0 10 5} {
    catch {*createpoint $x $y $z 0}
}
*createmark points 1 all
set allPts [hm_getmark points 1]
CP "POINTS [join $allPts { }]"
switch $variant {
    all {
        CP "CALL all" [catch {*surfaceprimitivefrompoints points 1 1 0 0} v]
    }
    four {
        *createmark points 2 [lindex $allPts 0] [lindex $allPts 1] [lindex $allPts 2] [lindex $allPts 3]
        CP "CALL four mark2" [catch {*surfaceprimitivefrompoints points 2 1 0 0} v]
    }
    minus1 {
        *clearmark points 1
        *createmark points 1 -1
        CP "CALL minus1 mark1" [catch {*surfaceprimitivefrompoints points 1 1 0 0} v]
    }
    four_tol {
        *createmark points 2 [lindex $allPts 0] [lindex $allPts 1] [lindex $allPts 2] [lindex $allPts 3]
        CP "CALL four tol" [catch {*surfaceprimitivefrompoints points 2 1 0 0.001} v]
    }
}
CP "AFTER_CALL"
*createmark surfs 1 all
CP "SURFS [join [hm_getmark surfs 1] { }]"
CP "DONE"
close $chan
exit 0
