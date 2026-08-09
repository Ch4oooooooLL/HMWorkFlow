# Fix probe: find a working HM2022 replacement for *surfacefilletremove.
#
# Evidence: *surfacefilletremove 1 1 2 works on 2019 but fails on 2022
# (audit_geometry_cleanup_cmds).  The module's line-fillet fallback
# (*surfacemarkremovelinefillets 1 minR maxR 0 1 0) fails on BOTH builds.
# This probe checks the candidate replacement path for the 2022 branch:
#   hm_getfilletfacesfrommark (exists on both) + *deletemark surfs.
#
# Run once per build:
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/fix_probe_geometry_cleanup22.tcl
# Results: runtime/fix_probe_geometry_cleanup22_<version>.log (KEY=VALUE, ASCII).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "fix_probe_geometry_cleanup22_${version}.log"]
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

P "AUDIT" "fix_probe_geometry_cleanup22"
P "VERSION" $version

# --- 1. Command existence ------------------------------------------------
foreach name {
    *surfacefilletremove *surfacemarkremovelinefillets *surfremove
    *removesurfaces *surfacekill *deletemark hm_getfilletfacesfrommark
    *surfacemode *defeaturesurface *removefillet
} {
    P "EXISTS $name" [expr {[info commands $name] ne ""}]
}

# --- 2. Box fixture (6 primitive surfaces) --------------------------------
# Use the exact audit-probe pattern: one quad per 4 construction points
# (*createpoint x4, mark all, *surfaceprimitivefrompoints, then delete the
# construction points).  Other mark patterns hard-crash HM2019 hmbatch.
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

# --- 3. Reproduce the 2022 failure ---------------------------------------
catch {*clearmark surfs 1}
*createmark surfs 1 [lindex $boxSurfs 0]
T "FIL_22_MODULE_CALL" {*surfacefilletremove 1 1 2}
catch {*clearmark surfs 1}
*createmark surfs 1 [lindex $boxSurfs 0]
T "LINE_FIL_MODULE_CALL" {*surfacemarkremovelinefillets 1 0.0 5.0 0 1 0}

# --- 4. Candidate replacement contract -----------------------------------
# hm_getfilletfacesfrommark on a plain box returns an empty list, not an
# error; that is the contract the 2022 branch relies on.
catch {*clearmark surfs 1}
*createmark surfs 1 all
T "FILLETQUERY_SURFS_0_5" {hm_getfilletfacesfrommark surfs 1 0.0 5.0}
catch {*clearmark comps 1}
*createmark comps 1 "by name only" AUDIT_FIX
T "FILLETQUERY_COMPS_0_5" {hm_getfilletfacesfrommark comps 1 0.0 5.0}
catch {*clearmark surfs 1}
*createmark surfs 1 all
T "FILLETQUERY_SURFS_0_100" {hm_getfilletfacesfrommark surfs 1 0.0 100.0}

# --- 5. *deletemark surfs works on both builds ----------------------------
catch {*clearmark surfs 1}
*createmark surfs 1 [lindex $boxSurfs 0]
T "DELETE_ONE_SURF" {*deletemark surfs 1}
catch {*clearmark surfs 1}
*createmark surfs 1 all
set remaining [hm_getmark surfs 1]
P "SURFS_AFTER_DELETE" [llength $remaining]

close $chan
exit 0
