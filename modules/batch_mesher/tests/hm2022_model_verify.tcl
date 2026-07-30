# Reopen a HyperMesh model in 2022 hmbatch and report basic entity counts.
# Set HMWORKFLOW_VERIFY_MODEL to the full path of the .hm file to verify.

set reportPath [file join [pwd] "hm2022_verify_[pid].txt"]
set lines [list "status=STARTED" "pid=[pid]" "working_directory=[pwd]"]

proc writeVerifyReport {path lines} {
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel [join $lines "\n"]
    close $channel
}

set code [catch {
    if {![info exists ::env(HMWORKFLOW_VERIFY_MODEL)]} {
        error "HMWORKFLOW_VERIFY_MODEL is not set"
    }
    set modelPath [file normalize $::env(HMWORKFLOW_VERIFY_MODEL)]
    if {![file isfile $modelPath]} { error "model not found: $modelPath" }

    hm_answernext "yes"
    *deletemodel
    *readfile $modelPath

    *createmark surfs 1 all
    set surfaceCount [llength [hm_getmark surfs 1]]
    *createmark elems 1 all
    set elementCount [llength [hm_getmark elems 1]]
    if {$surfaceCount <= 0} { error "reopened model has no surfaces" }
    if {$elementCount <= 0} { error "reopened model has no elements" }

    lappend lines "hm_version=[string trim [hm_info -appinfo VERSION]]"
    lappend lines "model_path=$modelPath"
    lappend lines "model_bytes=[file size $modelPath]"
    lappend lines "surfaces=$surfaceCount"
    lappend lines "elements=$elementCount"
} errorMessage errorOptions]

if {$code} {
    lappend lines "status=FAIL"
    lappend lines "error=$errorMessage"
    if {[dict exists $errorOptions -errorinfo]} {
        lappend lines "error_info=[string map {\n { | }} [dict get $errorOptions -errorinfo]]"
    }
    writeVerifyReport $reportPath $lines
    return -options $errorOptions $errorMessage
}

lappend lines "status=PASS"
writeVerifyReport $reportPath $lines
