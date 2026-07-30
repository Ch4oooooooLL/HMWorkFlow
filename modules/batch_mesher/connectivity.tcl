proc ::BatchMesher::listDifference {left right} {
    array set remove {}
    foreach id $right { set remove($id) 1 }
    set out {}
    foreach id $left { if {![info exists remove($id)]} { lappend out $id } }
    return $out
}

proc ::BatchMesher::listIntersection {left right} {
    array set allowed {}
    foreach id $right { set allowed($id) 1 }
    set out {}
    foreach id $left { if {[info exists allowed($id)]} { lappend out $id } }
    return [::BatchMesher::uniqIds $out]
}

proc ::BatchMesher::surfaceSignature {ids} { return [join [::BatchMesher::uniqIds $ids] ,] }

# HyperMesh 2019's "by attached" method is available on *appendmark.  Repeat
# until the mark stabilizes so this remains correct on patch levels where one
# call expands only one adjacency ring.  Non-target attached surfaces may be
# traversed, but only target IDs are returned to the task.
proc ::BatchMesher::attachedTargetSurfaces {seed targetIds} {
    ::BatchMesher::markSurfaces 1 [list $seed]
    set previousCount -1
    set iterations 0
    while {1} {
        set current [::BatchMesher::uniqIds [hm_getmark surfs 1]]
        set count [llength $current]
        if {$count == $previousCount} { break }
        set previousCount $count
        incr iterations
        if {$iterations > 100000} { error "by attached did not converge for seed surface $seed" }
        if {[catch {*appendmark surfs 1 "by attached"} err opts]} {
            catch {*clearmark surfs 1}
            return -options $opts "by attached failed for seed surface $seed: $err"
        }
    }
    set attached [::BatchMesher::uniqIds [hm_getmark surfs 1]]
    catch {*clearmark surfs 1}
    set group [::BatchMesher::listIntersection $attached $targetIds]
    if {[lsearch -exact $group $seed] < 0} { lappend group $seed }
    return [::BatchMesher::uniqIds $group]
}

proc ::BatchMesher::makeGroup {index surfaceIds total} {
    variable ui
    set info [::BatchMesher::componentInfoForSurfaces $surfaceIds]
    set count [llength $surfaceIds]
    set ratio [expr {$total > 0 ? double($count) / double($total) : 0.0}]
    set warnings {}
    if {$ratio >= double($ui(LARGE_GROUP_RATIO))} { lappend warnings large_group }
    if {$count <= 2} { lappend warnings isolated_small_group }
    if {[llength [dict get $info ids]] > 1} { lappend warnings cross_component }
    return [dict create group_id [format G%03d $index] surface_ids $surfaceIds surface_count $count \
        component_ids [dict get $info ids] component_names [dict get $info names] total_area "" status pending excluded 0 error_message "" warnings $warnings]
}

proc ::BatchMesher::buildTasks {groups} {
    set tasks {}
    set index 0
    foreach group $groups {
        if {[dict get $group excluded]} { continue }
        incr index
        lappend tasks [dict create task_id [format T%03d $index] group_id [dict get $group group_id] \
            surface_ids [dict get $group surface_ids] surface_count [dict get $group surface_count] status pending \
            elapsed_seconds "" started_at "" ended_at "" error_message "" log_path ""]
    }
    return $tasks
}

proc ::BatchMesher::analyzeConnectivity {} {
    variable runtime
    variable ui
    set targets [::BatchMesher::uniqIds $runtime(selected_surfaces)]
    if {[llength $targets] == 0} { error [::BatchMesher::txt "请先选择 Surfaces。" "Select surfaces first."] }
    set existing [::BatchMesher::existingSurfaceIds $targets]
    if {[llength $existing] != [llength $targets]} { error [::BatchMesher::txt "部分 Surface ID 已失效，请重新选择。" "Some surface IDs are invalid; select again."] }
    set remaining $targets
    set groups {}
    set index 0
    while {[llength $remaining] > 0} {
        set seed [lindex $remaining 0]
        set groupIds [::BatchMesher::attachedTargetSurfaces $seed $targets]
        if {[llength $groupIds] == 0} { error "Connectivity analysis returned an empty group for seed surface $seed" }
        incr index
        lappend groups [::BatchMesher::makeGroup $index $groupIds [llength $targets]]
        set remaining [::BatchMesher::listDifference $remaining $groupIds]
    }
    set runtime(groups) $groups
    set runtime(tasks) [::BatchMesher::buildTasks $groups]
    set runtime(analysis_signature) [::BatchMesher::surfaceSignature $targets]
    set runtime(analysis_all_surface_signature) [::BatchMesher::surfaceSignature [::BatchMesher::allSurfaceIds]]
    set counts {}
    foreach group $groups { lappend counts [dict get $group surface_count] }
    set counts [lsort -integer $counts]
    set ui(summary_text) [::BatchMesher::txt \
        "目标 Surfaces：[llength $targets]；几何连通域：[llength $groups]；最大：[lindex $counts end]；最小：[lindex $counts 0]" \
        "Target surfaces: [llength $targets]; groups: [llength $groups]; largest: [lindex $counts end]; smallest: [lindex $counts 0]"]
    if {[llength $groups] == 1} {
        set ui(status_text) [::BatchMesher::txt "当前目标几何属于单一拓扑连通区域；为保持公共边及焊缝连续性，将作为一个整体任务执行。" "The target is one topology-connected region and will run as one task to preserve shared-edge and weld continuity."]
    } else {
        set ui(status_text) [::BatchMesher::txt "连通性分析完成，将按连通域顺序执行。" "Connectivity analysis completed; groups will run sequentially."]
    }
    ::BatchMesher::refreshUi
    return $groups
}

proc ::BatchMesher::invalidateAnalysis {reason} {
    variable runtime
    variable ui
    set runtime(groups) {}
    set runtime(tasks) {}
    set runtime(analysis_signature) ""
    set runtime(analysis_all_surface_signature) ""
    set ui(summary_text) [::BatchMesher::txt "未分析" "Not analyzed"]
    set ui(status_text) $reason
}

proc ::BatchMesher::verifyAnalysisFresh {} {
    variable runtime
    set targets [::BatchMesher::uniqIds $runtime(selected_surfaces)]
    if {$runtime(analysis_signature) eq "" || [::BatchMesher::surfaceSignature $targets] ne $runtime(analysis_signature)} {
        error [::BatchMesher::txt "连通域分析不存在或已失效，请重新分析。" "Connectivity analysis is missing or stale; analyze again."]
    }
    if {[llength [::BatchMesher::existingSurfaceIds $targets]] != [llength $targets]} {
        error [::BatchMesher::txt "模型几何已发生变化，原连通域分析结果已失效，请重新分析。" "Model geometry changed; the analysis is stale. Analyze again."]
    }
    if {[::BatchMesher::surfaceSignature [::BatchMesher::allSurfaceIds]] ne $runtime(analysis_all_surface_signature)} {
        error [::BatchMesher::txt "模型 Surface 集合已变化，原连通域分析结果已失效，请重新分析。" "The model surface set changed; analyze again."]
    }
    return 1
}

proc ::BatchMesher::setGroupExcluded {groupId excluded} {
    variable runtime
    set updated {}
    foreach group $runtime(groups) {
        if {[dict get $group group_id] eq $groupId} { dict set group excluded [expr {$excluded ? 1 : 0}] }
        lappend updated $group
    }
    set runtime(groups) $updated
    set runtime(tasks) [::BatchMesher::buildTasks $updated]
    ::BatchMesher::refreshUi
}
