# Audit probe D: hm_getboundingbox argument contract on both releases.
# Probe A showed single-surface mark works, probe C showed a two-surface
# mark reports "No entities found."  This probe runs an argument matrix on a
# two-surface fixture to pin down the contract:
#   hm_getboundingbox <entity_type> <mark_id>      (mark 1 = both surfaces)
#   hm_getboundingbox <entity_type> <mark_id>      (mark 1 = one surface)
#   hm_getboundingbox <entity_type> <id1> <id2>    (ids as separate args)
#   hm_getboundingbox <entity_type> <ids-as-one-arg>
#   hm_getboundingbox <mark_id> <entity_type>      (reversed)
# Results: runtime/audit_batch_mesher_bbox_<version>.log; exit 0.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set versionRaw [string trim [hm_info -appinfo VERSION]]
set versionTag [regsub -all {[^0-9A-Za-z]} $versionRaw {_}]
set reportPath [file join $outputDir "audit_batch_mesher_bbox_${versionTag}.log"]
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
    *surfacemode 4
    *createplane 1 0.0 0.0 1.0 0.0 0.0 0.0
    *surfaceplane 1 100.0
    *createplane 2 0.0 0.0 1.0 100.0 0.0 0.0
    *surfaceplane 2 100.0
    *createmark surfs 2 all
    set surfaceIds [hm_getmark surfs 2]
    *clearmark surfs 2
    P "FIXTURE_SURFACES" [join $surfaceIds {,}]

    # Control: mark with one surface.
    catch {*clearmark surfs 1}
    *createmark surfs 1 [lindex $surfaceIds 0]
    if {[catch {set bbox [hm_getboundingbox surfs 1]} err]} {
        P "BBOX_MARK_SINGLE_ERROR" $err
    } else {
        P "BBOX_MARK_SINGLE" $bbox
    }

    # Mark with both surfaces.
    catch {*clearmark surfs 1}
    *createmark surfs 1 {*}$surfaceIds
    if {[catch {set bbox [hm_getboundingbox surfs 1]} err]} {
        P "BBOX_MARK_BOTH_ERROR" $err
    } else {
        P "BBOX_MARK_BOTH" $bbox
    }

    # IDs as separate trailing arguments.
    if {[catch {set bbox [hm_getboundingbox surfs {*}$surfaceIds]} err]} {
        P "BBOX_IDS_SEPARATE_ERROR" $err
    } else {
        P "BBOX_IDS_SEPARATE" $bbox
    }

    # IDs as one braced list argument.
    if {[catch {set bbox [hm_getboundingbox surfs $surfaceIds]} err]} {
        P "BBOX_IDS_LIST_ERROR" $err
    } else {
        P "BBOX_IDS_LIST" $bbox
    }

    # Reversed order.
    if {[catch {set bbox [hm_getboundingbox 1 surfs]} err]} {
        P "BBOX_REVERSED_ERROR" $err
    } else {
        P "BBOX_REVERSED" $bbox
    }

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
