# Standalone HyperMesh 2019/2022 worker that combines isolated task outputs.
# The launcher sets ::BatchMesherWorkerConfig before sourcing this file.
namespace eval ::BatchMesherMergeWorker {
    variable config {}
    if {[info exists ::BatchMesherWorkerConfig]} { set config $::BatchMesherWorkerConfig }
}

proc ::BatchMesherMergeWorker::writeText {path text} {
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts -nonewline $channel $text
    close $channel
}

proc ::BatchMesherMergeWorker::appendLog {level message} {
    variable config
    set channel [open [dict get $config run_log] a]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] [string toupper $level] $message"
    close $channel
}

proc ::BatchMesherMergeWorker::writeState {overall current message} {
    variable config
    set state [dict create schema_version 1 overall_status $overall current_index $current \
        total [llength [dict get $config inputs]] message $message updated_ms [clock milliseconds] \
        tasks [dict get $config tasks] result_fem [dict get $config result_fem] \
        merged_model [dict get $config merged_model] merge_log [dict get $config run_log] worker_pid [pid]]
    set path [dict get $config state_path]
    set temporary "${path}.tmp"
    ::BatchMesherMergeWorker::writeText $temporary $state
    file rename -force $temporary $path
}

proc ::BatchMesherMergeWorker::releaseFromVersion {version} {
    set version [string trim $version]
    if {[regexp {(20[0-9][0-9])} $version -> year]} { return $year }
    if {[regexp {^22([.]|$)} $version]} { return 2022 }
    if {[regexp {^19([.]|$)} $version]} { return 2019 }
    return ""
}

proc ::BatchMesherMergeWorker::optistructTemplate {} {
    variable config
    set candidates {}
    if {![catch {set templatesDir [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]}] && [string trim $templatesDir] ne ""} {
        lappend candidates [file join $templatesDir feoutput optistruct optistruct]
    }
    if {[dict exists $config export_template]} { lappend candidates [dict get $config export_template] }
    foreach candidate $candidates {
        if {![catch {set normalized [file normalize $candidate]}] && [file isfile $normalized]} { return $normalized }
    }
    error "OptiStruct template is missing for this hmbatch installation"
}

proc ::BatchMesherMergeWorker::markAll {entityType} {
    catch {*clearmark $entityType 1}
    *createmark $entityType 1 all
}

proc ::BatchMesherMergeWorker::uniqueIds {values} {
    set out {}
    foreach value $values {
        if {[string is integer -strict $value] && $value > 0} { lappend out $value }
    }
    return [lsort -integer -unique $out]
}

proc ::BatchMesherMergeWorker::markIds {entityType ids} {
    catch {*clearmark $entityType 1}
    set ids [::BatchMesherMergeWorker::uniqueIds $ids]
    if {[llength $ids] > 0} { uplevel #0 [linsert $ids 0 *createmark $entityType 1] }
}

proc ::BatchMesherMergeWorker::entityReference {entityType entityId dataNames} {
    foreach dataName $dataNames {
        if {![catch {set value [hm_getvalue $entityType id=$entityId dataname=$dataName]}] &&
            [string is integer -strict $value] && $value > 0} { return $value }
    }
    return ""
}

proc ::BatchMesherMergeWorker::markMergedMeshForExport {} {
    ::BatchMesherMergeWorker::markAll elems
    set elems [::BatchMesherMergeWorker::uniqueIds [hm_getmark elems 1]]
    set nodes {}; set comps {}; set props {}; set mats {}
    foreach elementId $elems {
        if {![catch {set elementNodes [hm_getvalue elems id=$elementId dataname=nodes]}]} { set nodes [concat $nodes $elementNodes] }
        set compId [::BatchMesherMergeWorker::entityReference elems $elementId {collector.id collectorid component.id comp.id}]
        if {$compId ne ""} { lappend comps $compId }
        set propId [::BatchMesherMergeWorker::entityReference elems $elementId {property.id propertyid prop.id}]
        if {$propId ne ""} { lappend props $propId }
    }
    foreach compId [::BatchMesherMergeWorker::uniqueIds $comps] {
        set propId [::BatchMesherMergeWorker::entityReference comps $compId {property.id propertyid prop.id}]
        if {$propId ne ""} { lappend props $propId }
    }
    foreach propId [::BatchMesherMergeWorker::uniqueIds $props] {
        set matId [::BatchMesherMergeWorker::entityReference props $propId {material.id materialid mat.id}]
        if {$matId ne ""} { lappend mats $matId }
    }
    ::BatchMesherMergeWorker::markIds elems $elems
    ::BatchMesherMergeWorker::markIds nodes $nodes
    ::BatchMesherMergeWorker::markIds comps $comps
    ::BatchMesherMergeWorker::markIds props $props
    ::BatchMesherMergeWorker::markIds mats $mats
}

proc ::BatchMesherMergeWorker::entityCount {entityType} {
    ::BatchMesherMergeWorker::markAll $entityType
    return [llength [hm_getmark $entityType 1]]
}

proc ::BatchMesherMergeWorker::modelCounts {} {
    set counts [dict create]
    foreach entityType {surfs elems nodes comps props mats} {
        if {[catch {set count [::BatchMesherMergeWorker::entityCount $entityType]}]} { set count -1 }
        dict set counts $entityType $count
    }
    return $counts
}

proc ::BatchMesherMergeWorker::importFemInput {index input} {
    set before [::BatchMesherMergeWorker::modelCounts]
    ::BatchMesherMergeWorker::appendLog INFO \
        "fem_import_command index=$index path=$input bytes=[file size $input] overwrite_flag=0 import_options=default before=$before"
    set code [catch {
        catch {hm_answernext yes}
        # overwrite_flag=0 is the documented ID-offset mode.  It prevents
        # independently exported workers from overwriting equal node/element
        # and collector IDs while building one clean FE-only model. Use the
        # reader's default property handling, matching a normal manual import.
        *feinputwithdata2 "#optistruct/optistruct" [file nativename $input] 0 0 0 0 0 1 0 1 0
    } result options]
    set after [::BatchMesherMergeWorker::modelCounts]
    if {$code} {
        set detail $result
        if {[dict exists $options -errorinfo]} { append detail "\n" [dict get $options -errorinfo] }
        ::BatchMesherMergeWorker::appendLog ERROR \
            "fem_import_command_failed index=$index path=$input overwrite_flag=0 import_options=default before=$before after=$after error=$detail"
        return -options $options $result
    }
    ::BatchMesherMergeWorker::appendLog INFO \
        "fem_import_command_complete index=$index result=$result before=$before after=$after"
    if {[dict get $after elems] <= [dict get $before elems]} {
        error "Task FEM added no elements during aggregation: index=$index path=$input overwrite_flag=0 before=$before after=$after"
    }
    return [list $before $after]
}

proc ::BatchMesherMergeWorker::main {} {
    variable config
    set inputs [dict get $config inputs]
    set mergeMode [dict get $config merge_mode]
    set exportWarning ""
    ::BatchMesherMergeWorker::writeState starting 0 "Starting isolated result merge"
    set code [catch {
        set version ""
        catch {set version [string trim [hm_info -appinfo VERSION]]}
        set release [::BatchMesherMergeWorker::releaseFromVersion $version]
        if {$release ni {2019 2022}} { error "Unsupported merge hmbatch release: $version" }
        ::BatchMesherMergeWorker::appendLog INFO "merge_release=$release raw_version=$version"
        catch {hm_answernext yes}
        ::BatchMesherMergeWorker::appendLog INFO "merge_model_reset_start"
        *deletemodel
        ::BatchMesherMergeWorker::appendLog INFO "merge_model_reset_complete counts=[::BatchMesherMergeWorker::modelCounts]"
        set exportTemplate [::BatchMesherMergeWorker::optistructTemplate]
        ::BatchMesherMergeWorker::appendLog INFO "merge_export_template path=$exportTemplate bytes=[file size $exportTemplate]"
        *templatefileset [file nativename $exportTemplate]
        set index 0
        foreach input $inputs {
            incr index
            if {![file isfile $input] || [file size $input] == 0} { error "Task output is missing or empty: $input" }
            ::BatchMesherMergeWorker::writeState merging $index "Combining task output $index / [llength $inputs]"
            ::BatchMesherMergeWorker::appendLog INFO "import_start index=$index path=$input"
            if {$mergeMode ne "fem"} { error "Unsupported merge mode: $mergeMode" }
            lassign [::BatchMesherMergeWorker::importFemInput $index $input] before after
            ::BatchMesherMergeWorker::appendLog INFO \
                "merge_delta index=$index elements=[expr {[dict get $after elems]-[dict get $before elems]}] components=[expr {[dict get $after comps]-[dict get $before comps]}]"
            ::BatchMesherMergeWorker::appendLog INFO "import_complete index=$index path=$input"
        }
        set mergedModel [dict get $config merged_model]
        set finalCounts [::BatchMesherMergeWorker::modelCounts]
        if {[dict get $finalCounts elems] <= 0} { error "Merged model contains no elements: counts=$finalCounts" }
        if {[file exists $mergedModel]} { file delete -force $mergedModel }
        *writefile [file nativename $mergedModel] 1
        if {![file isfile $mergedModel] || [file size $mergedModel] == 0} { error "Merged HyperMesh model was not written: $mergedModel" }
        ::BatchMesherMergeWorker::appendLog INFO \
            "merged_model_written path=$mergedModel bytes=[file size $mergedModel] counts=$finalCounts"
        set result [dict get $config result_fem]
        if {[catch {
            if {[file exists $result]} { file delete -force $result }
            catch {hm_answernext yes}
            catch {*feoutputmergeincludefiles 1}
            *feoutputwithdata [file nativename $exportTemplate] [file nativename $result] 0 0 1 1 0
            if {![file isfile $result] || [file size $result] == 0} { error "HyperMesh did not generate a valid merged FEM: $result" }
            ::BatchMesherMergeWorker::appendLog INFO "final_fem_written path=$result bytes=[file size $result] elements=[dict get $finalCounts elems]"
        } femError femOptions]} {
            # The merged native model remains fully importable. FEM is an
            # archival deliverable and must not discard a valid FE result.
            set exportWarning $femError
            ::BatchMesherMergeWorker::appendLog WARN "final_fem_export_failed error=$femError"
        }
    } errorMessage errorOptions]
    if {$code} {
        set detail $errorMessage
        if {[dict exists $errorOptions -errorinfo]} { append detail "\n" [dict get $errorOptions -errorinfo] }
        ::BatchMesherMergeWorker::appendLog ERROR "merge_failed error=$detail"
        ::BatchMesherMergeWorker::writeState failed -1 $detail
        return 2
    }
    ::BatchMesherMergeWorker::appendLog INFO "merge_complete inputs=[llength $inputs] result=[dict get $config result_fem] fem_warning=$exportWarning"
    set completionMessage "Task FEM results were aggregated into one native model successfully"
    if {$exportWarning ne ""} { append completionMessage "; final FEM archive warning: $exportWarning" }
    ::BatchMesherMergeWorker::writeState completed [llength $inputs] $completionMessage
    return 0
}

if {![info exists ::BatchMesherMergeWorkerNoAutoRun] || !$::BatchMesherMergeWorkerNoAutoRun} {
    ::BatchMesherMergeWorker::main
}
