# HyperWorks 2022 production BatchMesh smoke test.
#
# The caller must set these environment variables:
#   HMWORKFLOW_BATCHMESH_CRITERIA - full path to a .criteria file
#   HMWORKFLOW_BATCHMESH_PARAM    - full path to a .param file
#
# Run this script from an isolated working directory. It creates a fresh model,
# meshes one 20 x 20 planar surface, saves the model, and writes a text report.

set reportPath [file join [pwd] "hm2022_batchmesh_[pid].txt"]
set modelPath [file join [pwd] "hm2022_batchmesh_[pid].hm"]
set started [clock milliseconds]
set lines [list "status=STARTED" "pid=[pid]" "working_directory=[pwd]" "started_epoch_ms=$started"]

proc writeSmokeReport {path lines} {
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel [join $lines "\n"]
    close $channel
}

set code [catch {
    if {![info exists ::env(HMWORKFLOW_BATCHMESH_CRITERIA)]} {
        error "HMWORKFLOW_BATCHMESH_CRITERIA is not set"
    }
    if {![info exists ::env(HMWORKFLOW_BATCHMESH_PARAM)]} {
        error "HMWORKFLOW_BATCHMESH_PARAM is not set"
    }
    set criteria [file normalize $::env(HMWORKFLOW_BATCHMESH_CRITERIA)]
    set param [file normalize $::env(HMWORKFLOW_BATCHMESH_PARAM)]
    if {![file isfile $criteria]} { error "criteria file not found: $criteria" }
    if {![file isfile $param]} { error "param file not found: $param" }

    lappend lines "hm_version=[string trim [hm_info -appinfo VERSION]]"
    lappend lines "criteria=$criteria"
    lappend lines "param=$param"

    # In 2022 batch mode *deletemodel still asks for confirmation. Without
    # hm_answernext the process terminates with an uncapturable FatalError.
    hm_answernext "yes"
    *deletemodel
    set templatePath [file normalize [file join [file dirname [info nameofexecutable]] .. .. .. templates feoutput optistruct optistruct]]
    if {![file isfile $templatePath]} {
        error "OptiStruct template not found: $templatePath"
    }
    *templatefileset $templatePath
    lappend lines "template=$templatePath"
    *createentity comps name=HMWORKFLOW_BATCHMESH_PROBE
    *currentcollector comps HMWORKFLOW_BATCHMESH_PROBE
    set planeSize 100.0
    if {[info exists ::env(HMWORKFLOW_BATCHMESH_SIZE)]} {
        set planeSize [string trim $::env(HMWORKFLOW_BATCHMESH_SIZE)]
    }
    if {![string is double -strict $planeSize] || $planeSize <= 0.0} {
        error "invalid HMWORKFLOW_BATCHMESH_SIZE: $planeSize"
    }
    set originX 0.0
    if {[info exists ::env(HMWORKFLOW_BATCHMESH_ORIGIN_X)]} {
        set originX [string trim $::env(HMWORKFLOW_BATCHMESH_ORIGIN_X)]
    }
    if {![string is double -strict $originX]} {
        error "invalid HMWORKFLOW_BATCHMESH_ORIGIN_X: $originX"
    }
    lappend lines "plane_size=$planeSize"
    lappend lines "origin_x=$originX"
    *surfacemode 4
    *createplane 1 0.0 0.0 1.0 $originX 0.0 0.0
    *surfaceplane 1 $planeSize

    *createmark surfs 1 all
    set surfaceIds [hm_getmark surfs 1]
    if {[llength $surfaceIds] != 1} {
        error "expected one generated surface, got [llength $surfaceIds]: $surfaceIds"
    }
    *createmark elems 1 all
    set beforeCount [llength [hm_getmark elems 1]]
    lappend lines "surface_ids=$surfaceIds"
    lappend lines "elements_before=$beforeCount"

    lappend lines "method=hm_batchmesh2"

    set meshStarted [clock milliseconds]
    lappend lines "mesh_started_epoch_ms=$meshStarted"
    # 2022 hmbatch requires the criteria to be preloaded. The installed
    # standalone runner follows the same rule in its dedicated context.
    *readqualitycriteria $criteria
    *hm_batchmesh2 surfs 1 1 0 $criteria $param
    set meshFinished [clock milliseconds]
    set meshElapsed [expr {($meshFinished - $meshStarted) / 1000.0}]
    lappend lines "mesh_finished_epoch_ms=$meshFinished"

    *createmark elems 1 all
    set elementIds [hm_getmark elems 1]
    set afterCount [llength $elementIds]
    if {$afterCount <= $beforeCount} {
        error "BatchMesh created no elements: before=$beforeCount after=$afterCount"
    }

    *writefile $modelPath 1
    if {![file isfile $modelPath] || [file size $modelPath] == 0} {
        error "HyperMesh did not create a valid model: $modelPath"
    }

    lappend lines "elements_after=$afterCount"
    lappend lines "batchmesh_elapsed_seconds=$meshElapsed"
    lappend lines "model_path=$modelPath"
    lappend lines "model_bytes=[file size $modelPath]"
} errorMessage errorOptions]

set finished [clock milliseconds]
lappend lines "finished_epoch_ms=$finished"
lappend lines "total_elapsed_seconds=[expr {($finished - $started) / 1000.0}]"
if {$code} {
    lappend lines "status=FAIL"
    lappend lines "error=$errorMessage"
    if {[dict exists $errorOptions -errorinfo]} {
        lappend lines "error_info=[string map {\n { | }} [dict get $errorOptions -errorinfo]]"
    }
    writeSmokeReport $reportPath $lines
    return -options $errorOptions $errorMessage
}

lappend lines "status=PASS"
writeSmokeReport $reportPath $lines
