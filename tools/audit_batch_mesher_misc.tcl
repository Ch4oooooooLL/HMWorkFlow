# Audit probe C: two open questions from probes A/B on HyperWorks 2022.
#  1) *hm_batchmesh2 without profile/criteria preload: exact Tcl return value
#     and element outcome (the module always preloads on 2022, so this is
#     informational; HM2019 uses the no-preload path).
#  2) hm_getboundingbox on a mark containing BOTH fixture surfaces: confirm
#     the combined bounding box (recommended replacement for the module's
#     geometry-span walk, which uses an invalid points dataname).
# Results: runtime/audit_batch_mesher_misc_<version>.log; exit 0.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set versionRaw [string trim [hm_info -appinfo VERSION]]
set versionTag [regsub -all {[^0-9A-Za-z]} $versionRaw {_}]
set reportPath [file join $outputDir "audit_batch_mesher_misc_${versionTag}.log"]
set channel [open $reportPath w]
fconfigure $channel -encoding utf-8 -translation lf

proc P {key value} {
    variable channel
    set clean [string map [list "\n" { | } "\r" {} "\t" { }] $value]
    puts $channel "${key}=${clean}"
}

set reportDir [file join $root runtime "audit_batch_mesher_work_${versionTag}"]
file mkdir $reportDir
cd $reportDir

set probeCode [catch {
    P "status" STARTED
    P "version" [string trim [hm_info -appinfo VERSION]]

    catch {hm_answernext yes}
    *deletemodel

    # Two 100 x 100 planes sharing the x=100 edge.
    *surfacemode 4
    *createplane 1 0.0 0.0 1.0 0.0 0.0 0.0
    *surfaceplane 1 100.0
    *createplane 2 0.0 0.0 1.0 100.0 0.0 0.0
    *surfaceplane 2 100.0
    *createmark surfs 2 all
    set surfaceIds [hm_getmark surfs 2]
    *clearmark surfs 2
    P "FIXTURE_SURFACES" [llength $surfaceIds]

    # 1) No-preload *hm_batchmesh2: record exact return value and outcome.
    set executableDir [file dirname [info nameofexecutable]]
    set criteriaPath [file normalize [file join $executableDir .. .. .. hm batchmesh general_8mm.criteria]]
    set paramPath [string map {.criteria .param} $criteriaPath]
    P "CRITERIA" [expr {[file isfile $criteriaPath] ? $criteriaPath : "MISSING"}]
    *createmark surfs 1 all
    if {[catch {
        set returnValue [*hm_batchmesh2 surfs 1 1 0 [file nativename $criteriaPath] [file nativename $paramPath]]
        P "HM_BATCHMESH2_NO_PROFILE_RETURN" $returnValue
    } meshError meshOptions]} {
        set detail $meshError
        if {[dict exists $meshOptions -errorinfo]} { append detail " | " [dict get $meshOptions -errorinfo] }
        P "HM_BATCHMESH2_NO_PROFILE_TCL_ERROR" $detail
    }
    *createmark elems 2 all
    P "ELEMENTS_AFTER_NO_PROFILE" [llength [hm_getmark elems 2]]
    *clearmark elems 2
    catch {*clearmark surfs 1}

    # 2) hm_getboundingbox on a mark with both surfaces.
    *createmark surfs 1 {*}$surfaceIds
    if {[catch {set bbox [hm_getboundingbox surfs 1]} bboxError]} {
        P "HM_GETBOUNDINGBOX_TWO_SURFS_ERROR" $bboxError
    } else {
        P "HM_GETBOUNDINGBOX_TWO_SURFS" $bbox
    }
    catch {*clearmark surfs 1}

    P "status" PASS
} probeError probeOptions]

if {$probeCode} {
    set detail $probeError
    if {[dict exists $probeOptions -errorinfo]} { append detail " | " [dict get $probeOptions -errorinfo] }
    P "status" FAIL
    P "probe_error" $detail
}
close $channel
exit 0
