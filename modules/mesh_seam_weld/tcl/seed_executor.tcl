# Stable non-interactive adapter used by recognizers.  Detection modules pass
# only existing source nodes and target components; all patch preparation,
# imprint, target-path recovery, ruled creation, quality handling and per-path
# rollback remain owned by Mesh Seam Weld.
proc ::MeshSeamWeld::executeSeedJobs {jobs {progressOpened 0} {checkpointEvery 10}} {
    set batchStarted [clock milliseconds]
    set results {}
    set seamComponents {}
    set pendingPropertyComponents {}
    set total [llength $jobs]
    set index 0
    set abortRemaining 0
    set cancelled 0
    set succeeded 0
    set failed 0
    set checkpointCount 0
    set longestPathMs 0
    if {![string is integer -strict $checkpointEvery] || $checkpointEvery < 1} {
        set checkpointEvery 10
    }
    # A recognition run may follow a manual mesh-seam run in the same Tcl
    # interpreter.  Never carry topology/coordinate caches into this batch.
    if {[llength [info commands ::MeshSeamWeld::resetRunCaches]]} {
        ::MeshSeamWeld::resetRunCaches
    }
    foreach job $jobs {
        incr index
        set candidateId [::MeshSeamWeld::dictValueOr $job candidate_id "SEED_$index"]
        if {$abortRemaining} {
            lappend results [dict create candidate_id $candidateId status FAILED \
                error [expr {$cancelled ? \
                    "Batch cancelled before this weld started." : \
                    "Batch stopped because the previous weld could not be rolled back."}]]
            incr failed
            continue
        }
        if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]]} {
            set percent [expr {55.0 + 33.0*($index-1)/double(max(1,$total))}]
            catch {::HWFlow::progressUpdate $percent \
                [::HWFlow::ctxt "正在分批创建焊缝" "Creating welds in bounded batches"] \
                [::HWFlow::ctxt \
                    "第 $index/$total 条；成功 $succeeded，失败 $failed" \
                    "Weld $index/$total; $succeeded succeeded, $failed failed"] 1}
        } elseif {[llength [info commands ::HWFlow::progressPumpEvents]]} {
            catch {::HWFlow::progressPumpEvents 1}
        }
        if {[llength [info commands ::HWFlow::progressCancelled]] &&
            [::HWFlow::progressCancelled]} {
            set cancelled 1
            set abortRemaining 1
            lappend results [dict create candidate_id $candidateId status FAILED \
                error "Batch cancelled before this weld started." rollback_ok 1 \
                block_kind cancelled]
            incr failed
            continue
        }
        set pathStarted [clock milliseconds]
        set sourceNodes [dict get $job source_node_ids]
        set targetComps [::MeshSeamWeld::uniq [dict get $job target_component_ids]]
        set sourceComp [dict get $job source_component_id]
        set closedLoop [expr {[::MeshSeamWeld::dictValueOr $job closed_loop 0] ? 1 : 0}]
        if {[llength $sourceNodes] < [expr {$closedLoop ? 3 : 2}] || ![llength $targetComps] ||
            [llength $sourceNodes] != [llength [::MeshSeamWeld::uniq $sourceNodes]]} {
            lappend results [dict create candidate_id $candidateId status FAILED \
                error "invalid recognition seed: nodes=[llength $sourceNodes] targets=[llength $targetComps]"]
            incr failed
            continue
        }
        set preparationError ""
        set targetElements {}
        if {[catch {
            set prepared [::MeshSeamWeld::prepareCurrentTargetPatch \
                $sourceNodes $targetComps $closedLoop]
            set targetComps [dict get $prepared target_components]
            set targetElements [dict get $prepared target_elements]
        } preparationError]} {
            lappend results [dict create candidate_id $candidateId status FAILED \
                error "\[MSW_STAGE:TARGET_PREPARE\] $preparationError"]
            incr failed
            continue
        }
        # processWeldPathIsolated owns the per-path undo transaction.  An
        # unexpected Tcl error outside that contract is allowed to propagate
        # so the caller restores the task snapshot instead of continuing on an
        # uncertain model.
        set isolated [::MeshSeamWeld::processWeldPathIsolated \
            $sourceNodes $targetComps $closedLoop $progressOpened $index $total \
            [list $sourceComp] "" {} $targetElements $closedLoop]
        if {![dict get $isolated ok]} {
            if {![dict get $isolated rollback_ok]} { set abortRemaining 1 }
            if {[string first "\[MSW_STAGE:CANCELLED\]" [dict get $isolated error]] >= 0} {
                set cancelled 1
                set abortRemaining 1
            }
            lappend results [dict create candidate_id $candidateId status FAILED \
                error [dict get $isolated error] rollback_ok [dict get $isolated rollback_ok] \
                imprint_kept [::MeshSeamWeld::dictValueOr $isolated imprint_kept 0] \
                block_kind [expr {$cancelled ? "cancelled" : \
                    [::MeshSeamWeld::dictValueOr $isolated block_kind creation]}]]
            incr failed
            continue
        }
        set created [dict get $isolated result]
        set seamName [dict get $created seamCompName]
        lappend seamComponents $seamName
        lappend pendingPropertyComponents $seamName
        lappend results [dict create candidate_id $candidateId status CREATED \
            source_node_count [llength [dict get $created sourceNodes]] \
            target_node_count [llength [dict get $created targetNodes]] \
            created_element_count [llength [dict get $created weldElems]] \
            seam_component $seamName]
        incr succeeded
        set pathMs [expr {[clock milliseconds]-$pathStarted}]
        if {$pathMs > $longestPathMs} { set longestPathMs $pathMs }

        # Commit cheap housekeeping at bounded intervals.  Property assignment
        # and event pumping no longer accumulate until a very large batch ends,
        # while the actual HyperMesh mesh mutations remain safely serial.
        if {$index % $checkpointEvery == 0 || $index == $total} {
            incr checkpointCount
            if {[llength $pendingPropertyComponents]} {
                catch {::MeshSeamWeld::assignCreatedSeamComponentProperties \
                    [::MeshSeamWeld::uniq $pendingPropertyComponents]}
                set pendingPropertyComponents {}
            }
            catch {::MeshSeamWeld::clearTransientSelections}
            if {[llength [info commands ::HWFlow::progressPumpEvents]]} {
                catch {::HWFlow::progressPumpEvents 1}
            }
            ::HybridCore::log INFO \
                "PERF mesh_seam_weld seed_checkpoint=$checkpointCount completed=$index/$total succeeded=$succeeded failed=$failed elapsed_ms=[expr {[clock milliseconds]-$batchStarted}]"
        }
    }
    if {[llength $pendingPropertyComponents]} {
        catch {::MeshSeamWeld::assignCreatedSeamComponentProperties \
            [::MeshSeamWeld::uniq $pendingPropertyComponents]}
    }
    catch {::MeshSeamWeld::clearTransientSelections}
    set totalSeconds [expr {([clock milliseconds]-$batchStarted)/1000.0}]
    return [dict create total $total succeeded $succeeded \
        failed $failed cancelled $cancelled results $results \
        seam_components [::MeshSeamWeld::uniq $seamComponents] \
        performance [dict create total_seconds $totalSeconds \
            checkpoint_count $checkpointCount longest_path_seconds \
            [expr {$longestPathMs/1000.0}]]]
}
