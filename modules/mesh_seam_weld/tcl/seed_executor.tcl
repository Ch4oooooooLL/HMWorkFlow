# Stable non-interactive adapter used by recognizers.  Detection modules pass
# only existing source nodes and target components; all patch preparation,
# imprint, target-path recovery, ruled creation, quality handling and per-path
# rollback remain owned by Mesh Seam Weld.
proc ::MeshSeamWeld::executeSeedJobs {jobs {progressOpened 0}} {
    set results {}
    set seamComponents {}
    set total [llength $jobs]
    set index 0
    foreach job $jobs {
        incr index
        set candidateId [::MeshSeamWeld::dictValueOr $job candidate_id "SEED_$index"]
        set sourceNodes [::MeshSeamWeld::uniq [dict get $job source_node_ids]]
        set targetComps [::MeshSeamWeld::uniq [dict get $job target_component_ids]]
        set sourceComp [dict get $job source_component_id]
        set closedLoop [expr {[::MeshSeamWeld::dictValueOr $job closed_loop 0] ? 1 : 0}]
        if {[llength $sourceNodes] < [expr {$closedLoop ? 3 : 2}] || ![llength $targetComps]} {
            lappend results [dict create candidate_id $candidateId status FAILED \
                error "invalid recognition seed: nodes=[llength $sourceNodes] targets=[llength $targetComps]"]
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
            continue
        }
        set isolated [::MeshSeamWeld::processWeldPathIsolated \
            $sourceNodes $targetComps $closedLoop $progressOpened $index $total \
            [list $sourceComp] "" {} $targetElements $closedLoop]
        if {![dict get $isolated ok]} {
            lappend results [dict create candidate_id $candidateId status FAILED \
                error [dict get $isolated error] rollback_ok [dict get $isolated rollback_ok]]
            continue
        }
        set created [dict get $isolated result]
        set seamName [dict get $created seamCompName]
        lappend seamComponents $seamName
        lappend results [dict create candidate_id $candidateId status CREATED \
            source_node_count [llength [dict get $created sourceNodes]] \
            target_node_count [llength [dict get $created targetNodes]] \
            created_element_count [llength [dict get $created weldElems]] \
            seam_component $seamName]
    }
    if {[llength $seamComponents]} {
        catch {::MeshSeamWeld::assignCreatedSeamComponentProperties \
            [::MeshSeamWeld::uniq $seamComponents]}
    }
    set succeeded 0
    foreach row $results { if {[dict get $row status] eq "CREATED"} { incr succeeded } }
    return [dict create total $total succeeded $succeeded \
        failed [expr {$total-$succeeded}] results $results \
        seam_components [::MeshSeamWeld::uniq $seamComponents]]
}
