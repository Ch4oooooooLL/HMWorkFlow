# Fix verification: replay the exact command sequence of the new HM2022
# fillet-removal branch in ::GeomCleanup::removeChamfer (geometry_cleanup.tcl).
#
# The branch: *surfacefilletremove 1 1 2 fails on 22 -> fallback now queries
# hm_getfilletfacesfrommark on the chamfer-chain mark (NOT "all") and, when
# non-empty, *deletemark surfs 1.  This probe proves the sequence runs without
# a hard crash and keeps the empty-list contract on a subset mark.
#
# Run once per build:
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/fix_verify_geometry_cleanup22.tcl
# Results: runtime/fix_verify_geometry_cleanup22_<version>.log (KEY=VALUE, ASCII).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "fix_verify_geometry_cleanup22_${version}.log"]
set chan [open $reportPath w]
fconfigure $chan -encoding utf-8 -translation lf

proc P {key value} {
    variable chan
    puts $chan "${key}=${value}"
    flush $chan
}

proc T {key script} {
    set code [catch {uplevel 1 $script} value options]
    if {$code} {
        set msg [string map [list "\n" " " "\r" " " "{" "" "}" ""] $value]
        P "$key" "ERR: $msg"
        return 0
    }
    P "$key" "OK: $value"
    return 1
}

P "AUDIT" "fix_verify_geometry_cleanup22"
P "VERSION" $version

# --- 1. Box fixture (6 primitive surfaces), audit-probe pattern -------------
*collectorcreateonly components AUDIT_FIX "" 1

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

set boxSurfs [list \
    [quadSurf 0 0 0 10 0 0 10 10 0 0 10 0] \
    [quadSurf 0 0 10 10 0 10 10 10 10 0 10 10] \
    [quadSurf 0 0 0 10 0 0 10 0 10 0 0 10] \
    [quadSurf 0 10 0 10 10 0 10 10 10 0 10 10] \
    [quadSurf 0 0 0 0 10 0 0 10 10 0 0 10] \
    [quadSurf 10 0 0 10 10 0 10 10 10 10 0 10]]
P "BOX_SURFS" [llength $boxSurfs]

# --- 2. Module branch replay: subset mark (chamfer chain) -------------------
# markList marks the chamfer chain into surfs 1; mimic with the first two.
catch {*clearmark surfs 1}
eval *createmark surfs 1 [lrange $boxSurfs 0 1]
T "MODULE_SURFACEFILLETREMOVE" {*surfacefilletremove 1 1 2}

# Branch body on failure: query fillet faces on the SAME subset mark.
catch {*clearmark surfs 1}
eval *createmark surfs 1 [lrange $boxSurfs 0 1]
T "QUERY_SUBSET_MARK" {set filletFaces [hm_getfilletfacesfrommark surfs 1 0.0 5.0]}
P "QUERY_SUBSET_LENGTH" [llength $filletFaces]

# Delete path: mark the returned faces (empty here -> verify the non-empty
# branch with an explicit list instead) and delete.
catch {*clearmark surfs 1}
eval *createmark surfs 1 [lindex $boxSurfs 0]
T "DELETE_ONE_SURF" {*deletemark surfs 1}
catch {*clearmark surfs 1}
*createmark surfs 1 all
set remaining [hm_getmark surfs 1]
P "SURFS_AFTER_DELETE" [llength $remaining]

close $chan
exit 0
