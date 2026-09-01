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

proc ::BatchMesherWorker::invokeFromFileDirectory {anchorPath command} {
    # HM2019 resolves auxiliary files referenced by cleanup/holes tables from
    # the process working directory.  A detached worker normally runs in its
    # task directory, unlike an interactive/manual BatchMesher call.  Execute
    # file-sensitive commands beside their source file and always restore cwd.
    set previous [pwd]
    set target [file dirname [file normalize $anchorPath]]
    cd $target
    set code [catch {uplevel #0 $command} result options]
    set restoreCode [catch {cd $previous} restoreError]
    if {$restoreCode && !$code} { error "Could not restore worker directory to $previous: $restoreError" }
    if {$code} { return -options $options $result }
    return $result
}

proc ::BatchMesherWorker::invokeFromWorkerDirectory {command} {
    variable config
    # BatchMesh creates process-local scratch/command artifacts relative to
    # cwd.  Configuration files are shared by every worker, so running the
    # native mesher beside a .criteria/.param file makes parallel workers
    # overwrite one another.  Keep only the file-loading calls beside their
    # source files and always execute the mesher in this worker's private dir.
    set previous [pwd]
    set target [file normalize [dict get $config run_dir]]
    file mkdir $target
    cd $target
    set code [catch {uplevel #0 $command} result options]
    set restoreCode [catch {cd $previous} restoreError]
    if {$restoreCode && !$code} { error "Could not restore worker directory to $previous: $restoreError" }
    if {$code} { return -options $options $result }
    return $result
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
    variable config
    if {$release ni {2019 2022}} {
        error "Unsupported HyperMesh release for BatchMesh profile initialization: $release"
    }
    # A standalone hmbatch process does not inherit the interactive session's
    # solver profile or quality-criteria state.  Both HM2019 and HM2022 need
    # these initialized before the release-specific BatchMesh API parses the cleanup parameter
    # file.  Skipping this for HM2019 makes valid parameter files abort in the
    # holes-recognition section before any elements are created.
    set template [::BatchMesherWorker::optistructTemplate]
    *templatefileset [file nativename $template]
    set criteria [dict get $config criteria]
    ::BatchMesherWorker::invokeFromFileDirectory $criteria \
        [list *readqualitycriteria [file nativename $criteria]]
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

proc ::BatchMesherWorker::batchMeshElementSize {paramPath} {
    if {[catch {set channel [open $paramPath r]}]} { return "" }
    set text [read $channel]
    close $channel
    if {[regexp -nocase -line {^[ \t]*element_size(?:[ \t]+|[ \t]*=[ \t]*)([0-9]+(?:[.][0-9]*)?(?:[eE][+-]?[0-9]+)?)} $text -> value] &&
        [string is double -strict $value] && $value > 0} {
        return [expr {double($value)}]
    }
    return ""
}

proc ::BatchMesherWorker::taskSurfaceIds {} {
    variable records
    set ids {}
    foreach record $records {
        if {[dict exists $record surface_ids]} { set ids [concat $ids [dict get $record surface_ids]] }
    }
    return [::BatchMesherWorker::uniqueIds $ids]
}

proc ::BatchMesherWorker::selectedSurfaceGeometrySpan {surfaceIds} {
    set count [llength $surfaceIds]
    if {$count == 0} { return "" }
    set stride [expr {max(1, int(ceil(double($count) / 64.0)))}]
    array set seenPoint {}
    set coords {}
    for {set index 0} {$index < $count} {incr index $stride} {
        if {[catch {set loops [hm_getsurfaceedges [lindex $surfaceIds $index]]}]} { continue }
        foreach loop $loops {
            foreach edgeId $loop {
                if {[catch {set pointIds [hm_getverticesfromedge $edgeId]}]} { continue }
                foreach pointId $pointIds {
                    if {[info exists seenPoint($pointId)]} { continue }
                    set seenPoint($pointId) 1
                    if {[catch {set xyz [hm_getvalue points id=$pointId dataname=coordinates]}] || [llength $xyz] < 3} { continue }
                    lappend coords [lrange $xyz 0 2]
                }
            }
        }
    }
    if {[llength $coords] < 2} { return "" }
    lassign [lindex $coords 0] xmin ymin zmin
    set xmax $xmin; set ymax $ymin; set zmax $zmin
    foreach xyz [lrange $coords 1 end] {
        lassign $xyz x y z
        if {$x < $xmin} { set xmin $x }; if {$x > $xmax} { set xmax $x }
        if {$y < $ymin} { set ymin $y }; if {$y > $ymax} { set ymax $y }
        if {$z < $zmin} { set zmin $z }; if {$z > $zmax} { set zmax $z }
    }
    return [expr {max($xmax-$xmin, $ymax-$ymin, $zmax-$zmin)}]
}

proc ::BatchMesherWorker::unitCompatibleCompanion {path} {
    set candidate "[file rootname $path]_meter[file extension $path]"
    if {[file isfile $candidate]} { return [file normalize $candidate] }
    return ""
}

proc ::BatchMesherWorker::resolveUnitCompatibleConfiguration {} {
    variable config
    set originalParam [dict get $config param]
    set originalCriteria [dict get $config criteria]
    set elementSize [::BatchMesherWorker::batchMeshElementSize $originalParam]
    set compatibleParam [::BatchMesherWorker::unitCompatibleCompanion $originalParam]
    set compatibleCriteria [::BatchMesherWorker::unitCompatibleCompanion $originalCriteria]
    set marker "[file rootname $originalParam].use_meter"
    set markerEnabled [file isfile $marker]
    set geometrySpan [::BatchMesherWorker::selectedSurfaceGeometrySpan [::BatchMesherWorker::taskSurfaceIds]]
    set detectedMismatch [expr {$elementSize ne "" && $geometrySpan ne "" && $geometrySpan > 0 && $elementSize >= $geometrySpan}]
    if {!$markerEnabled && !$detectedMismatch} {
        return 0
    }
    if {$compatibleParam eq "" || $compatibleCriteria eq ""} {
        error "BATCHMESH_UNIT_MISMATCH element_size=$elementSize geometry_span=$geometrySpan; compatible _meter.criteria/_meter.param files were not found"
    }
    set compatibleSize [::BatchMesherWorker::batchMeshElementSize $compatibleParam]
    if {$compatibleSize eq "" || $compatibleSize >= $elementSize} {
        error "BATCHMESH_UNIT_MISMATCH invalid compatible parameter file: $compatibleParam"
    }
    dict set config criteria $compatibleCriteria
    dict set config param $compatibleParam
    set reason [expr {$markerEnabled ? "explicit_meter_marker" : "unit_mismatch"}]
    ::BatchMesherWorker::appendLog [dict get $config run_log] WARN \
        "configuration_auto_switched reason=$reason marker=$marker element_size=$elementSize geometry_span=$geometrySpan compatible_element_size=$compatibleSize original_criteria=$originalCriteria original_param=$originalParam criteria=$compatibleCriteria param=$compatibleParam"
    return 1
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

proc ::BatchMesherWorker::appendTaskWarning {taskVar message} {
    upvar 1 $taskVar task
    set message [string trim $message]
    if {$message eq ""} { return }
    set warning ""
    if {[dict exists $task warning_message]} { set warning [string trim [dict get $task warning_message]] }
    if {$warning ne ""} { append warning "\n" }
    append warning $message
    dict set task warning_message $warning
}

# Check the result at the engineering boundary that matters for downstream
# assembly: every element created for one topology-connected surface group
# must belong to the same node-connected FE region. Quality failures do not
# affect this result and are handled separately.
proc ::BatchMesherWorker::meshConnectivitySummary {elementIds} {
    set elementIds [::BatchMesherWorker::uniqueIds $elementIds]
    if {[llength $elementIds] == 0} {
        return [dict create status invalid component_count 0 component_sizes {} message "no created elements"]
    }
    array set elementNodes {}
    array set nodeElements {}
    foreach elementId $elementIds {
        if {[catch {set nodes [hm_getvalue elems id=$elementId dataname=nodes]} queryError]} {
            return [dict create status unavailable component_count "" component_sizes {} \
                message "could not read element $elementId connectivity: $queryError"]
        }
        set nodes [::BatchMesherWorker::uniqueIds $nodes]
        if {[llength $nodes] < 2} {
            return [dict create status invalid component_count "" component_sizes {} \
                message "element $elementId has invalid connectivity: $nodes"]
        }
        set elementNodes($elementId) $nodes
        foreach nodeId $nodes { lappend nodeElements($nodeId) $elementId }
    }
    array set visited {}
    set componentSizes {}
    foreach seed $elementIds {
        if {[info exists visited($seed)]} { continue }
        set queue [list $seed]
        set visited($seed) 1
        set size 0
        set queueIndex 0
        while {$queueIndex < [llength $queue]} {
            set current [lindex $queue $queueIndex]
            incr queueIndex
            incr size
            foreach nodeId $elementNodes($current) {
                foreach neighbor $nodeElements($nodeId) {
                    if {[info exists visited($neighbor)]} { continue }
                    set visited($neighbor) 1
                    lappend queue $neighbor
                }
            }
        }
        lappend componentSizes $size
    }
    set componentSizes [lsort -integer -decreasing $componentSizes]
    set count [llength $componentSizes]
    return [dict create status [expr {$count == 1 ? "valid" : "invalid"}] \
        component_count $count component_sizes $componentSizes \
        message [expr {$count == 1 ? "" : "created mesh has $count node-connected regions"}]]
}

# A native quality miss is intentionally advisory. Record the failing element
# IDs so the merged mesh can be fed to Local Mesh Optimizer in later passes,
# while keeping this worker's mesh package usable even if no pass can satisfy
# every criterion.
proc ::BatchMesherWorker::meshQualitySummary {elementIds} {
    set elementIds [::BatchMesherWorker::uniqueIds $elementIds]
    if {[llength $elementIds] == 0} {
        return [dict create status unavailable failed_ids {} info ""]
    }
    if {[llength [info commands hm_getelementsqualityinfo]] == 0} {
        return [dict create status unavailable failed_ids {} info "quality query command is unavailable"]
    }
    ::BatchMesherWorker::markIds elems 1 $elementIds
    catch {*clearmark elems 2}
    set code [catch {set info [hm_getelementsqualityinfo 1 1 2]} queryError]
    set failed {}
    if {!$code} {
        catch {set failed [::BatchMesherWorker::uniqueIds [hm_getmark elems 2]]}
        set failed [::BatchMesherWorker::difference $failed [::BatchMesherWorker::difference $failed $elementIds]]
    }
    catch {*clearmark elems 1}
    catch {*clearmark elems 2}
    if {$code} { return [dict create status unavailable failed_ids {} info $queryError] }
    return [dict create status [expr {[llength $failed] > 0 ? "needs_optimization" : "passed"}] \
        failed_ids $failed info $info]
}

proc ::BatchMesherWorker::runTask {index} {
    variable config
    variable records
    variable successfulElements
    variable workerRelease
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
        set criteria [dict get $config criteria]
        set param [dict get $config param]
        # HM2019's standalone BatchMesher invokes *hm_batchmesh, not
        # *hm_batchmesh2.  The latter rejects some valid 2019 holes-recognition
        # sections. Match Altair's release-specific runner contract exactly.
        if {$workerRelease eq "2019"} {
            if {[llength [info commands *hm_batchmesh]] == 0} { error "HyperMesh command *hm_batchmesh is unavailable" }
            set batchApi hm_batchmesh
            # The legacy parser used by HM2019 tokenizes native backslash paths
            # incorrectly when a directory contains spaces. Altair's own
            # standalone runner always supplies normalized forward-slash paths.
            set legacyCriteria [string map {\\ /} [file normalize $criteria]]
            set legacyParam [string map {\\ /} [file normalize $param]]
            set command [list *hm_batchmesh 1 \
                $legacyCriteria $legacyParam]
        } else {
            if {[llength [info commands *hm_batchmesh2]] == 0} { error "HyperMesh command *hm_batchmesh2 is unavailable" }
            set batchApi hm_batchmesh2
            set command [list *hm_batchmesh2 surfs 1 1 0 \
                [file nativename $criteria] [file nativename $param]]
        }
        ::BatchMesherWorker::appendLog $taskLog INFO \
            "configuration_loaded mode=direct_paths release=$workerRelease api=$batchApi criteria=$criteria param=$param"
        ::BatchMesherWorker::invokeFromWorkerDirectory $command
    } errorMessage errorOptions]
    catch {*clearmark surfs 1}
    set after [::BatchMesherWorker::allIds elems 2]
    set created [::BatchMesherWorker::difference $after $before]
    dict set task created_elements [llength $created]
    if {[llength $created] == 0} {
        set code 1
        if {[string trim $errorMessage] eq ""} {
            set errorMessage "BatchMesher returned without creating elements; surface_ids=$ids"
            set errorOptions [dict create -errorinfo $errorMessage]
        }
    } else {
        set connectivity [::BatchMesherWorker::meshConnectivitySummary $created]
        dict set task connectivity_status [dict get $connectivity status]
        dict set task connectivity_components [dict get $connectivity component_count]
        if {[dict get $connectivity status] eq "invalid"} {
            set code 1
            set connectivityError "BATCHMESH_CONNECTIVITY_INVALID [dict get $connectivity message]; component_sizes=[dict get $connectivity component_sizes] surface_ids=$ids"
            if {[string trim $errorMessage] ne ""} { append connectivityError "\nNative BatchMesh diagnostic: $errorMessage" }
            set errorMessage $connectivityError
            set errorOptions [dict create -errorinfo $connectivityError]
        } else {
            if {[dict get $connectivity status] eq "unavailable"} {
                ::BatchMesherWorker::appendTaskWarning task \
                    "Connectivity verification unavailable; mesh retained: [dict get $connectivity message]"
            }
            if {$code} {
                # Preserve the native diagnostic, but a created mesh whose
                # connectivity is not known to be wrong remains usable.
                set batchWarning $errorMessage
                set code 0
            }
            set quality [::BatchMesherWorker::meshQualitySummary $created]
            set qualityStatus [dict get $quality status]
            set qualityFailed [dict get $quality failed_ids]
            dict set task quality_status $qualityStatus
            dict set task quality_failed_elements [llength $qualityFailed]
            dict set task optimization_attempts 0
            if {$qualityStatus eq "needs_optimization"} {
                dict set task optimization_status pending
                ::BatchMesherWorker::appendTaskWarning task \
                    "QUALITY_NEEDS_OPTIMIZATION failed_elements=[llength $qualityFailed] element_ids=$qualityFailed; mesh retained for later iterative optimization"
            } elseif {$qualityStatus eq "passed"} {
                dict set task optimization_status not_required
            } else {
                dict set task optimization_status available
                ::BatchMesherWorker::appendTaskWarning task \
                    "Quality verification unavailable; mesh retained for later review: [dict get $quality info]"
            }
        }
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
            ::BatchMesherWorker::appendTaskWarning task $batchWarning
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
    variable successfulElements
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
        ::BatchMesherWorker::resolveUnitCompatibleConfiguration
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
        set femPackagingError ""
        if {[llength [::BatchMesherWorker::uniqueIds $successfulElements]] > 0} {
            ::BatchMesherWorker::writeState exporting [llength $records] "Saving native worker mesh result"
            ::BatchMesherWorker::writeIsolatedOutputModel
        } else {
            ::BatchMesherWorker::appendLog $runLog WARN "packaging_skipped reason=no_successful_mesh_elements"
        }
        if {[llength [::BatchMesherWorker::uniqueIds $successfulElements]] > 0 &&
            [catch {::BatchMesherWorker::exportResult} femError femOptions]} {
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
    set overall [expr {$failures > 0 ? "failed" : "completed"}]
    ::BatchMesherWorker::appendLog $runLog INFO "worker_complete status=$overall failures=$failures result=[dict get $config result_fem]"
    ::BatchMesherWorker::writeState $overall [llength $records] "Background meshing completed; failed_tasks=$failures"
    return [expr {$failures > 0 ? 1 : 0}]
}

if {![info exists ::BatchMesherWorkerNoAutoRun] || !$::BatchMesherWorkerNoAutoRun} {
    ::BatchMesherWorker::main
}
