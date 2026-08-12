# HyperMesh 2019 command-availability and by-attached smoke test.
# A production *hm_batchmesh2 call is intentionally not made on a blank model;
# validate that separately with a saved representative model and approved
# criteria/param files using doc/batch_mesher.md.

set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
set outputDir [file join $root runtime tasks batch_mesher cli_smoke]
file mkdir $outputDir
set reportPath [file join $outputDir hm2019_api_smoke.txt]

proc batchMesherSmokeReport {path status details} {
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel "status=$status"
    puts $channel $details
    close $channel
}

proc runBatchMesherApiSmoke {} {
    set version [hm_info -appinfo VERSION]
    if {![regexp {(^|[^0-9])(2019|19)([.]|[^0-9]|$)} $version]} { error "Expected HyperMesh 2019, got: $version" }
    foreach command {*appendmark *hm_batchmesh2 *readbatchparamsfile *readqualitycriteria *isolateentitybymark *setreviewbymark *window_entitymark} {
        if {[llength [info commands $command]] == 0} { error "Required HM2019 command is unavailable: $command" }
    }
    catch {*clearmark surfs 1}
    *createmark surfs 1
    if {[catch {*appendmark surfs 1 "by attached"} err options]} {
        return -options $options "HM2019 rejected *appendmark surfs 1 by attached: $err"
    }
    catch {*clearmark surfs 1}
    return "version=$version\ncommand_availability=PASS\nby_attached_empty_mark=PASS\nbatchmesh_production_invocation=NOT_RUN"
}

set code [catch {runBatchMesherApiSmoke} details options]
if {$code} {
    batchMesherSmokeReport $reportPath FAIL $details
    return -options $options $details
}
batchMesherSmokeReport $reportPath PASS $details
