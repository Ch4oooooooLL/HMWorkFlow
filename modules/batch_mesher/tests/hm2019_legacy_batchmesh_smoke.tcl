# HM2019 legacy BatchMesh command smoke test. The standalone BatchMesher 2019
# runner uses this API internally; keep this probe to guard that compatibility.
set reportPath [file join [pwd] "hm2019_legacy_batchmesh_[pid].txt"]
set modelPath [file join [pwd] "hm2019_legacy_batchmesh_[pid].hm"]
set lines {}
proc writeLegacyReport {path lines} {
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel [join $lines "\n"]
    close $channel
}
set code [catch {
    set criteria [file normalize $::env(HMWORKFLOW_BATCHMESH_CRITERIA)]
    set param [file normalize $::env(HMWORKFLOW_BATCHMESH_PARAM)]
    lappend lines "hm_version=[string trim [hm_info -appinfo VERSION]]"
    catch {hm_answernext yes}
    *deletemodel
    set templatePath [file normalize [file join [file dirname [info nameofexecutable]] .. .. .. templates feoutput optistruct optistruct]]
    *templatefileset $templatePath
    *createentity comps name=HMWORKFLOW_BATCHMESH_PROBE
    *currentcollector comps HMWORKFLOW_BATCHMESH_PROBE
    *surfacemode 4
    *createplane 1 0.0 0.0 1.0 0.0 0.0 0.0
    *surfaceplane 1 100.0
    *createmark surfs 1 all
    set surfaceIds [hm_getmark surfs 1]
    if {[llength $surfaceIds] != 1} { error "expected one surface, got $surfaceIds" }
    *readqualitycriteria $criteria
    *hm_batchmesh 1 $criteria $param
    *createmark elems 1 all
    set elementIds [hm_getmark elems 1]
    if {[llength $elementIds] == 0} { error "legacy BatchMesh created no elements" }
    *writefile $modelPath 1
    lappend lines "elements=[llength $elementIds]" "model=$modelPath" "status=PASS"
} errorMessage errorOptions]
if {$code} {
    lappend lines "status=FAIL" "error=$errorMessage"
    if {[dict exists $errorOptions -errorinfo]} { lappend lines "error_info=[dict get $errorOptions -errorinfo]" }
}
writeLegacyReport $reportPath $lines
if {$code} { return -options $errorOptions $errorMessage }
