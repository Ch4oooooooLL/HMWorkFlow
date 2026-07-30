# Merge two independently meshed HyperMesh worker models and verify counts.
# Set HMWORKFLOW_MERGE_MODEL_A and HMWORKFLOW_MERGE_MODEL_B to .hm paths.

set reportPath [file join [pwd] "hm2022_merge_[pid].txt"]
set mergedPath [file join [pwd] "hm2022_merged_[pid].hm"]
set lines [list "status=STARTED" "pid=[pid]" "working_directory=[pwd]"]

proc mergeCounts {} {
    *createmark surfs 1 all
    set surfaces [llength [hm_getmark surfs 1]]
    *createmark elems 1 all
    set elements [llength [hm_getmark elems 1]]
    *createmark comps 1 all
    set components [llength [hm_getmark comps 1]]
    return [list $surfaces $elements $components]
}

proc writeMergeReport {path lines} {
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel [join $lines "\n"]
    close $channel
}

set code [catch {
    foreach variable {HMWORKFLOW_MERGE_MODEL_A HMWORKFLOW_MERGE_MODEL_B} {
        if {![info exists ::env($variable)]} { error "$variable is not set" }
        set value [file normalize $::env($variable)]
        if {![file isfile $value]} { error "$variable model not found: $value" }
        set $variable $value
    }

    hm_answernext "yes"
    *deletemodel
    *mergefile $HMWORKFLOW_MERGE_MODEL_A 1 1
    lassign [mergeCounts] surfacesA elementsA componentsA
    *mergefile $HMWORKFLOW_MERGE_MODEL_B 1 1
    lassign [mergeCounts] surfacesAB elementsAB componentsAB

    if {$surfacesA <= 0 || $elementsA <= 0} {
        error "first worker merge is empty: surfaces=$surfacesA elements=$elementsA"
    }
    if {$surfacesAB <= $surfacesA || $elementsAB <= $elementsA} {
        error "second worker did not add data: before=$surfacesA/$elementsA after=$surfacesAB/$elementsAB"
    }

    *writefile $mergedPath 1
    if {![file isfile $mergedPath] || [file size $mergedPath] == 0} {
        error "merged model was not written: $mergedPath"
    }

    lappend lines "model_a=$HMWORKFLOW_MERGE_MODEL_A"
    lappend lines "model_b=$HMWORKFLOW_MERGE_MODEL_B"
    lappend lines "after_a_surfaces=$surfacesA"
    lappend lines "after_a_elements=$elementsA"
    lappend lines "after_a_components=$componentsA"
    lappend lines "after_ab_surfaces=$surfacesAB"
    lappend lines "after_ab_elements=$elementsAB"
    lappend lines "after_ab_components=$componentsAB"
    lappend lines "merged_model=$mergedPath"
    lappend lines "merged_model_bytes=[file size $mergedPath]"
} errorMessage errorOptions]

if {$code} {
    lappend lines "status=FAIL"
    lappend lines "error=$errorMessage"
    if {[dict exists $errorOptions -errorinfo]} {
        lappend lines "error_info=[string map {\n { | }} [dict get $errorOptions -errorinfo]]"
    }
    writeMergeReport $reportPath $lines
    return -options $errorOptions $errorMessage
}

lappend lines "status=PASS"
writeMergeReport $reportPath $lines
