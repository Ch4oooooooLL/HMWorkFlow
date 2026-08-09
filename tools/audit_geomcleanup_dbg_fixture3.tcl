# Bisect the *surfaceprimitivefrompoints crash on HM2019 hmbatch.
# HM_FIX_VARIANT = exact | no_comp | four_comp | eight_z
#   exact     : seam-probe fresh_model verbatim (8 coplanar pts, no collectors)
#   no_comp   : 8 coplanar pts, no collectors, single call
#   four_comp : 4 coplanar pts, collector created first
#   eight_z   : 8 pts at two z levels, collector created first
set root [file dirname [file dirname [file normalize [info script]]]]
set variant [expr {[info exists ::env(HM_FIX_VARIANT)] ? $::env(HM_FIX_VARIANT) : "exact"}]
set chan [open [file join $root runtime "audit_geomcleanup_dbg3_${variant}.log"] w]
proc CP {msg} {
    variable chan
    puts $chan $msg
    flush $chan
}
CP "VERSION [hm_info -appinfo VERSION] VARIANT $variant"
if {$variant ne "exact" && $variant ne "no_comp"} {
    *collectorcreateonly components AUDIT_SRC "" 1
    CP "COLLECTOR OK"
}
switch $variant {
    exact {
        foreach {x y z} {0 0 0  10 0 0  10 10 0  0 10 0  10 0 0  20 0 0  20 10 0  10 10 0} {
            catch {*createpoint $x $y $z 0}
        }
        *createmark points 1 all
        catch {*surfaceprimitivefrompoints points 1 1 0 0}
        *createmark points 1 all
        catch {*surfaceprimitivefrompoints points 1 1 0 0}
    }
    no_comp {
        foreach {x y z} {0 0 0  10 0 0  10 10 0  0 10 0  10 0 0  20 0 0  20 10 0  10 10 0} {
            catch {*createpoint $x $y $z 0}
        }
        *createmark points 1 all
        catch {*surfaceprimitivefrompoints points 1 1 0 0}
    }
    four_comp {
        foreach {x y z} {0 0 0  10 0 0  10 10 0  0 10 0} {
            catch {*createpoint $x $y $z 0}
        }
        *createmark points 1 all
        catch {*surfaceprimitivefrompoints points 1 1 0 0}
    }
    eight_z {
        foreach {x y z} {0 0 0  10 0 0  10 10 0  0 10 0  0 0 5  10 0 5  10 10 5  0 10 5} {
            catch {*createpoint $x $y $z 0}
        }
        *createmark points 1 all
        catch {*surfaceprimitivefrompoints points 1 1 0 0}
    }
}
CP "AFTER_CALL"
*createmark surfs 1 all
CP "SURFS [join [hm_getmark surfs 1] { }]"
CP "DONE"
close $chan
exit 0
