# Standalone HyperMesh 2019/2022 hmbatch worker. The launcher sets
# ::BatchMesherWorkerConfig before sourcing this file.
namespace eval ::BatchMesherWorker {
    variable config {}
    if {[info exists ::BatchMesherWorkerConfig]} { set config $::BatchMesherWorkerConfig }
    variable records {}
    variable successfulElements {}
    variable workerRelease ""
}

proc ::BatchMesherWorker::uniqueIds {values} {
    set out {}
    foreach value $values {
        if {[string is integer -strict $value] && $value > 0} { lappend out $value }
    }
    return [lsort -integer -unique $out]
}

proc ::BatchMesherWorker::difference {left right} {
    array set excluded {}
    foreach value $right { set excluded($value) 1 }
    set out {}
    foreach value $left { if {![info exists excluded($value)]} { lappend out $value } }
    return $out
}

proc ::BatchMesherWorker::writeText {path text} {
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts -nonewline $channel $text
    close $channel
}

proc ::BatchMesherWorker::appendLog {path level message} {
    set channel [open $path a]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] [string toupper $level] $message"
    close $channel
}

proc ::BatchMesherWorker::writeState {overall current message} {
    variable config
    variable records
    variable workerRelease
    set release $workerRelease
    set state [dict create schema_version 1 overall_status $overall current_index $current \
        total [llength $records] message $message updated_ms [clock milliseconds] tasks $records \
        result_fem [dict get $config result_fem] worker_pid [pid] \
        hypermesh_release $release]
    set path [dict get $config state_path]
    set temporary "${path}.tmp"
    ::BatchMesherWorker::writeText $temporary $state
    file rename -force $temporary $path
}

proc ::BatchMesherWorker::releaseFromVersion {version} {
    set version [string trim $version]
    if {[regexp {(20[0-9][0-9])} $version -> year]} { return $year }
    if {[regexp {^22([.]|$)} $version]} { return 2022 }
    if {[regexp {^19([.]|$)} $version]} { return 2019 }
    return ""
}

proc ::BatchMesherWorker::optistructTemplate {} {
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

proc ::BatchMesherWorker::initializeBatchMeshProfile {release} {
    if {$release ne "2022"} { return }
    variable config
    set template [::BatchMesherWorker::optistructTemplate]
    *templatefileset [file nativename $template]
    *readqualitycriteria [file nativename [dict get $config criteria]]
}

proc ::BatchMesherWorker::verifyConfigurationFiles {} {
    variable config
    foreach spec {
        {criteria criteria_mtime criteria_size}
        {param param_mtime param_size}
    } {
        lassign $spec pathKey mtimeKey sizeKey
        set path [dict get $config $pathKey]
        if {![file isfile $path]} { error "BatchMesh configuration file disappeared: $path" }
        if {[dict exists $config $mtimeKey] && ([file mtime $path] != [dict get $config $mtimeKey] || [file size $path] != [dict get $config $sizeKey])} {
            error "CONFIG_CHANGED_DURING_RUN file=$path expected_mtime=[dict get $config $mtimeKey] actual_mtime=[file mtime $path] expected_size=[dict get $config $sizeKey] actual_size=[file size $path]"
        }
    }
}

proc ::BatchMesherWorker::allIds {entityType markId} {
    catch {*clearmark $entityType $markId}
    *createmark $entityType $markId all
    set values [::BatchMesherWorker::uniqueIds [hm_getmark $entityType $markId]]
    catch {*clearmark $entityType $markId}
    return $values
}

proc ::BatchMesherWorker::markIds {entityType markId ids} {
    catch {*clearmark $entityType $markId}
    set ids [::BatchMesherWorker::uniqueIds $ids]
    if {[llength $ids] == 0} { return }
    uplevel #0 [linsert $ids 0 *createmark $entityType $markId]
}

proc ::BatchMesherWorker::replaceRecord {index record} {
    variable records
    set records [lreplace $records $index $index $record]
}

proc ::BatchMesherWorker::runTask {index} {
    variable config
    variable records
    variable successfulElements
    set task [lindex $records $index]
    set taskId [dict get $task task_id]
    set groupId [dict get $task group_id]
    set ids [dict get $task surface_ids]
    set taskLog [file join [dict get $config run_dir] "task_${groupId}.log"]
    set before [::BatchMesherWorker::allIds elems 2]
    set started [clock milliseconds]
    dict set task status running
    dict set task started_ms $started
    dict set task started_at [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}]
    dict set task ended_at ""
    dict set task elapsed_seconds ""
    dict set task error_message ""
    dict set task log_path $taskLog
    ::BatchMesherWorker::replaceRecord $index $task
    ::BatchMesherWorker::writeState running $index "Running $taskId / $groupId ([llength $ids] surfaces)"
    set componentNames {}
    if {[dict exists $task component_names]} { set componentNames [dict get $task component_names] }
    ::BatchMesherWorker::appendLog $taskLog INFO "started components=$componentNames surfaces=[llength $ids] surface_ids=$ids"

    set batchWarning ""
    set code [catch {
        ::BatchMesherWorker::markIds surfs 1 $ids
        set existing [::BatchMesherWorker::uniqueIds [hm_getmark surfs 1]]
        if {[llength $existing] != [llength [::BatchMesherWorker::uniqueIds $ids]]} {
            error "MODEL_STATE_STALE expected_surfaces=[llength $ids] existing_surfaces=[llength $existing] surface_ids=$ids"
        }
        set command [list *hm_batchmesh2 surfs 1 1 0 [file nativename [dict get $config criteria]] [file nativename [dict get $config param]]]
        uplevel #0 $command
    } errorMessage errorOptions]
    catch {*clearmark surfs 1}
    set after [::BatchMesherWorker::allIds elems 2]
    set created [::BatchMesherWorker::difference $after $before]
    if {[llength $created] == 0} {
        set code 1
        if {[string trim $errorMessage] eq ""} {
            set errorMessage "BatchMesher returned without creating elements; surface_ids=$ids"
            set errorOptions [dict create -errorinfo $errorMessage]
        }
    } elseif {$code} {
        # Preserve the diagnostic, but the newly created elements make this a
        # usable result rather than a failed task.
        set batchWarning $errorMessage
        set code 0
    }
    set ended [clock milliseconds]
    dict set task ended_at [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}]
    dict set task elapsed_seconds [format %.3f [expr {($ended-$started)/1000.0}]]
    if {$code} {
        set detail $errorMessage
        if {[dict exists $errorOptions -errorinfo]} { append detail "\n" [dict get $errorOptions -errorinfo] }
        if {[regexp -nocase {license|licensing|checkout failed} $detail]} {
            append detail "\nLICENSE_HINT: Reduce Parallel workers to 1 and verify available HyperMesh licenses."
        }
        dict set task status failed
        dict set task error_message $detail
        ::BatchMesherWorker::appendLog $taskLog ERROR "failed created_partial_elements=[llength $created] Tcl_error=$detail"
    } else {
        set successfulElements [concat $successfulElements $created]
        dict set task status completed
        if {[string trim $batchWarning] ne ""} {
            # BatchMesher can return a Tcl error after producing a usable mesh
            # (for example when quality optimization cannot meet every target).
            # Element creation is the authoritative result boundary.
            dict set task warning_message $batchWarning
            ::BatchMesherWorker::appendLog $taskLog WARN \
                "completed_with_warning created_elements=[llength $created] warning=$batchWarning"
        } else {
            ::BatchMesherWorker::appendLog $taskLog INFO "completed created_elements=[llength $created] elapsed_seconds=[dict get $task elapsed_seconds]"
        }
    }
    ::BatchMesherWorker::replaceRecord $index $task
    return $code
}

proc ::BatchMesherWorker::entityReference {entityType entityId dataNames} {
    foreach dataName $dataNames {
        if {![catch {set value [hm_getvalue $entityType id=$entityId dataname=$dataName]}] &&
            [string is integer -strict $value] && $value > 0} { return $value }
    }
    return ""
}

proc ::BatchMesherWorker::resultEntityIds {} {
    variable successfulElements
    set elems [::BatchMesherWorker::uniqueIds $successfulElements]
    set nodes {}
    set comps {}
    set props {}
    set mats {}
    foreach elementId $elems {
        if {![catch {set elementNodes [hm_getvalue elems id=$elementId dataname=nodes]}]} { set nodes [concat $nodes $elementNodes] }
        set compId [::BatchMesherWorker::entityReference elems $elementId {collector.id collectorid component.id comp.id}]
        if {$compId ne ""} { lappend comps $compId }
        set propId [::BatchMesherWorker::entityReference elems $elementId {property.id propertyid prop.id}]
        if {$propId ne ""} { lappend props $propId }
    }
    # BatchMesh may assign the property on the component rather than directly
    # on each element. Preserve that resolved collector chain as well.
    foreach compId [::BatchMesherWorker::uniqueIds $comps] {
        set propId [::BatchMesherWorker::entityReference comps $compId {property.id propertyid prop.id}]
        if {$propId ne ""} { lappend props $propId }
    }
    foreach propId [::BatchMesherWorker::uniqueIds $props] {
        set matId [::BatchMesherWorker::entityReference props $propId {material.id materialid mat.id}]
        if {$matId ne ""} { lappend mats $matId }
    }
    return [dict create elems $elems nodes [::BatchMesherWorker::uniqueIds $nodes] \
        comps [::BatchMesherWorker::uniqueIds $comps] props [::BatchMesherWorker::uniqueIds $props] \
        mats [::BatchMesherWorker::uniqueIds $mats]]
}

proc ::BatchMesherWorker::deleteIds {entityType ids} {
    if {[llength $ids] == 0} { return }
    ::BatchMesherWorker::markIds $entityType 1 $ids
    *deletemark $entityType 1
    catch {*clearmark $entityType 1}
}

proc ::BatchMesherWorker::isolationStep {stage command} {
    variable config
    set runLog [dict get $config run_log]
    ::BatchMesherWorker::appendLog $runLog INFO "isolation_stage_start stage=$stage"
    if {[catch {uplevel 1 $command} errorMessage errorOptions]} {
        set detail $errorMessage
        if {[dict exists $errorOptions -errorinfo]} { append detail "\n" [dict get $errorOptions -errorinfo] }
        ::BatchMesherWorker::appendLog $runLog ERROR "isolation_stage_failed stage=$stage error=$detail"
        error "ISOLATION_STAGE_FAILED stage=$stage error=$errorMessage"
    }
    ::BatchMesherWorker::appendLog $runLog INFO "isolation_stage_complete stage=$stage"
}

proc ::BatchMesherWorker::deleteUnretained {entityType keepIds} {
    set remove [::BatchMesherWorker::difference \
        [::BatchMesherWorker::allIds $entityType 2] $keepIds]
    ::BatchMesherWorker::deleteIds $entityType $remove
}

proc ::BatchMesherWorker::exportResult {} {
    variable config
    variable successfulElements
    set successfulElements [::BatchMesherWorker::uniqueIds $successfulElements]
    if {[llength $successfulElements] == 0} { error "No successful BatchMesher elements are available for export" }
    set entities [::BatchMesherWorker::resultEntityIds]
    set resultComponents [dict get $entities comps]
    if {[llength $resultComponents] == 0} { error "Successful BatchMesher elements have no owning components" }
    ::BatchMesherWorker::markIds elems 1 [dict get $entities elems]
    set markedElements [::BatchMesherWorker::uniqueIds [hm_getmark elems 1]]
    if {$markedElements ne $successfulElements} {
        error "Result element mark does not match created elements: expected=$successfulElements actual=$markedElements"
    }
    set result [dict get $config result_fem]
    if {[file exists $result]} { file delete -force $result }
    # After native isolation every owning component contains only this worker's
    # new elements. Custom component output lets the solver template serialize
    # the elements and their dependencies as a coherent deck. In production
    # HM2019, selecting individual entity marks produced a non-empty deck with
    # GRID cards but no element cards.
    set exportCode [catch {
        *allsuppressoutput 1
        foreach entityType {comps props mats} {
            set ids [dict get $entities $entityType]
            if {[llength $ids] == 0} { continue }
            ::BatchMesherWorker::markIds $entityType 1 $ids
            *marksuppressoutput $entityType 1 0
        }
        catch {*feoutputmergeincludefiles 1}
        catch {hm_answernext yes}
        *feoutputwithdata [file nativename [::BatchMesherWorker::optistructTemplate]] \
            [file nativename $result] 0 0 2 1 0
    } exportError exportOptions]
    catch {*allsuppressoutput 0}
    if {$exportCode} { return -options $exportOptions $exportError }
    if {![file isfile $result] || [file size $result] == 0} { error "HyperMesh did not generate a valid result FEM: $result" }
    ::BatchMesherWorker::appendLog [dict get $config run_log] INFO \
        "task_fem_written path=$result bytes=[file size $result] elements=[llength $successfulElements] components=[llength $resultComponents] export_mode=custom_components"
    return $result
}

proc ::BatchMesherWorker::writeIsolatedOutputModel {} {
    variable config
    if {![dict exists $config output_model]} { return "" }
    set model [dict get $config output_model]
    set keep [::BatchMesherWorker::resultEntityIds]
    if {[llength [dict get $keep elems]] == 0} { error "No successful elements are available for the isolated worker model" }

    # Keep the native BatchMesh result and remove only pre-existing elements.
    # Geometry, nodes and collectors are intentionally left untouched here.
    # The HM is retained as a per-worker recovery artifact. Final aggregation
    # uses the selected FEM export because this file is already FE-only.
    ::BatchMesherWorker::isolationStep remove_unretained_elements [list \
        ::BatchMesherWorker::deleteUnretained elems [dict get $keep elems]]
    set remaining [::BatchMesherWorker::allIds elems 2]
    if {$remaining ne [dict get $keep elems]} {
        error "Worker model isolation changed the successful element set: expected=[dict get $keep elems] actual=$remaining"
    }
    if {[file exists $model]} { file delete -force $model }
    catch {hm_answernext yes}
    *writefile [file nativename $model] 1
    if {![file isfile $model] || [file size $model] == 0} { error "HyperMesh did not create a valid isolated worker model: $model" }
    return $model
}

proc ::BatchMesherWorker::main {} {
    variable config
    variable records
    variable workerRelease
    set records [dict get $config tasks]
    set runLog [dict get $config run_log]
    ::BatchMesherWorker::writeState starting -1 "Loading background model snapshot"
    ::BatchMesherWorker::appendLog $runLog INFO "worker_start pid=[pid] model=[dict get $config model] tasks=[llength $records]"
    set fatalCode [catch {
        set version ""
        catch {set version [string trim [hm_info -appinfo VERSION]]}
        set release [::BatchMesherWorker::releaseFromVersion $version]
        if {$release ni {2019 2022}} { error "Unsupported background HyperMesh release: $version" }
        set workerRelease $release
        ::BatchMesherWorker::appendLog $runLog INFO "worker_release=$release raw_version=$version"
        ::BatchMesherWorker::verifyConfigurationFiles
        catch {hm_answernext yes}
        *readfile [file nativename [dict get $config model]] 0
        ::BatchMesherWorker::initializeBatchMeshProfile $release
        for {set index 0} {$index < [llength $records]} {incr index} {
            set failed [::BatchMesherWorker::runTask $index]
            if {$failed && ![dict get $config continue_after_failure]} {
                for {set skipped [expr {$index+1}]} {$skipped < [llength $records]} {incr skipped} {
                    set record [lindex $records $skipped]
                    dict set record status skipped
                    dict set record error_message "Skipped because continue-after-failure is disabled"
                    ::BatchMesherWorker::replaceRecord $skipped $record
                }
                break
            }
        }
        ::BatchMesherWorker::writeState exporting [llength $records] "Saving native worker mesh result"
        ::BatchMesherWorker::writeIsolatedOutputModel
        set femPackagingError ""
        if {[catch {::BatchMesherWorker::exportResult} femError femOptions]} {
            set femPackagingError $femError
            # Meshing remains successful, but this worker cannot participate in
            # final aggregation without its FE-only payload.
            ::BatchMesherWorker::appendLog $runLog ERROR "task_fem_packaging_failed error=$femError"
            for {set warningIndex 0} {$warningIndex < [llength $records]} {incr warningIndex} {
                set warningRecord [lindex $records $warningIndex]
                if {[dict get $warningRecord status] ne "completed"} { continue }
                set previousWarning [dict get $warningRecord warning_message]
                if {$previousWarning ne ""} { append previousWarning "\n" }
                append previousWarning "Task FEM packaging failed: $femError"
                dict set warningRecord warning_message $previousWarning
                ::BatchMesherWorker::replaceRecord $warningIndex $warningRecord
            }
        }
        for {set recordIndex 0} {$recordIndex < [llength $records]} {incr recordIndex} {
            set record [lindex $records $recordIndex]
            if {[dict get $record status] eq "completed"} {
                if {$femPackagingError eq ""} {
                    dict set record packaging_status completed
                    dict set record packaging_error ""
                } else {
                    dict set record packaging_status failed
                    dict set record packaging_error $femPackagingError
                }
                ::BatchMesherWorker::replaceRecord $recordIndex $record
            }
        }
    } fatalError fatalOptions]
    if {$fatalCode} {
        set detail $fatalError
        if {[dict exists $fatalOptions -errorinfo]} { append detail "\n" [dict get $fatalOptions -errorinfo] }
        if {[regexp -nocase {license|licensing|checkout failed} $detail]} {
            append detail "\nLICENSE_HINT: Reduce Parallel workers to 1 and verify available HyperMesh licenses."
        }
        ::BatchMesherWorker::appendLog $runLog ERROR "worker_failed error=$detail"
        ::BatchMesherWorker::writeState failed -1 $detail
        return 2
    }
    set failures 0
    foreach record $records { if {[dict get $record status] eq "failed"} { incr failures } }
    ::BatchMesherWorker::appendLog $runLog INFO "worker_complete failures=$failures result=[dict get $config result_fem]"
    ::BatchMesherWorker::writeState completed [llength $records] "Background meshing completed; failed_tasks=$failures"
    return 0
}

if {![info exists ::BatchMesherWorkerNoAutoRun] || !$::BatchMesherWorkerNoAutoRun} {
    ::BatchMesherWorker::main
}
