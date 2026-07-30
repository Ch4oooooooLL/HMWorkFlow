proc ::BatchMesher::uniqIds {ids} {
    set out {}
    foreach id $ids {
        if {[string is integer -strict $id] && $id > 0} { lappend out $id }
    }
    return [lsort -integer -unique $out]
}

proc ::BatchMesher::markSurfaces {markId ids} {
    set ids [::BatchMesher::uniqIds $ids]
    catch {*clearmark surfs $markId}
    if {[llength $ids] == 0} { return 0 }
    set command [linsert $ids 0 *createmark surfs $markId]
    if {[catch {uplevel #0 $command} err opts]} {
        catch {*clearmark surfs $markId}
        return -options $opts "Could not create surface mark $markId: $err"
    }
    return [llength $ids]
}

proc ::BatchMesher::surfaceIdsByMode {mode} {
    catch {*clearmark surfs 2}
    if {[catch {uplevel #0 [list *createmark surfs 2 $mode]} err opts]} {
        catch {*clearmark surfs 2}
        return -options $opts "Could not query surfaces ($mode): $err"
    }
    set ids [::BatchMesher::uniqIds [hm_getmark surfs 2]]
    catch {*clearmark surfs 2}
    return $ids
}

proc ::BatchMesher::allSurfaceIds {} { return [::BatchMesher::surfaceIdsByMode all] }
proc ::BatchMesher::displayedSurfaceIds {} { return [::BatchMesher::surfaceIdsByMode displayed] }

proc ::BatchMesher::setSelectedSurfaces {ids} {
    variable runtime
    variable ui
    set runtime(selected_surfaces) [::BatchMesher::uniqIds $ids]
    set count [llength $runtime(selected_surfaces)]
    set ui(selected_text) [::BatchMesher::txt "已选择 $count 个 Surfaces" "Selected $count surface(s)"]
    ::BatchMesher::invalidateAnalysis [::BatchMesher::txt "Surface 选择已变化，请重新分析。" "Surface selection changed; analyze again."]
    catch {::BatchMesher::refreshUi}
    return $runtime(selected_surfaces)
}

proc ::BatchMesher::pickSurfaces {} {
    if {[catch {set ids [::HWFlow::nativeMarkPanel surfs 1 [::BatchMesher::txt "选择需要 BatchMesher 划分的 Surfaces" "Select surfaces for BatchMesher"]]} err]} {
        ::BatchMesher::showError $err
        return
    }
    catch {*clearmark surfs 1}
    ::BatchMesher::setSelectedSurfaces $ids
}

proc ::BatchMesher::selectDisplayedSurfaces {} {
    if {[catch {::BatchMesher::setSelectedSurfaces [::BatchMesher::displayedSurfaceIds]} err]} { ::BatchMesher::showError $err }
}

proc ::BatchMesher::selectAllSurfaces {} {
    if {[catch {::BatchMesher::setSelectedSurfaces [::BatchMesher::allSurfaceIds]} err]} { ::BatchMesher::showError $err }
}

proc ::BatchMesher::clearSelection {} { ::BatchMesher::setSelectedSurfaces {} }

proc ::BatchMesher::existingSurfaceIds {ids} {
    array set wanted {}
    foreach id [::BatchMesher::uniqIds $ids] { set wanted($id) 1 }
    set found {}
    foreach id [::BatchMesher::allSurfaceIds] {
        if {[info exists wanted($id)]} { lappend found $id }
    }
    return $found
}

proc ::BatchMesher::surfaceComponentId {surfaceId} {
    foreach dataname {collector.id collectorid component.id comp.id} {
        if {![catch {set value [hm_getvalue surfs id=$surfaceId dataname=$dataname]}] && [string is integer -strict $value] && $value > 0} { return $value }
    }
    return ""
}

proc ::BatchMesher::componentName {componentId} {
    if {$componentId eq ""} { return "" }
    foreach dataname {name} {
        if {![catch {set value [hm_getvalue comps id=$componentId dataname=$dataname]}] && $value ne ""} { return $value }
    }
    return "Component_$componentId"
}

proc ::BatchMesher::componentInfoForSurfaces {surfaceIds} {
    set ids {}
    foreach surfaceId $surfaceIds {
        set componentId [::BatchMesher::surfaceComponentId $surfaceId]
        if {$componentId ne ""} { lappend ids $componentId }
    }
    set ids [lsort -integer -unique $ids]
    set names {}
    foreach id $ids { lappend names [::BatchMesher::componentName $id] }
    return [dict create ids $ids names $names]
}

proc ::BatchMesher::reviewSurfaces {ids} {
    if {[llength $ids] == 0} { error [::BatchMesher::txt "没有可显示的 Surface。" "There are no surfaces to display."] }
    ::BatchMesher::markSurfaces 1 $ids
    *setreviewbymark surfs 1 4
    *setreviewcolormode 0
    *setreviewtransparentmode 1
    *setreviewmode 1
    catch {*window_entitymark surfs 1}
    catch {hm_redraw}
}

proc ::BatchMesher::isolateSurfaces {ids} {
    if {[llength $ids] == 0} { error [::BatchMesher::txt "没有可隔离的 Surface。" "There are no surfaces to isolate."] }
    ::BatchMesher::markSurfaces 1 $ids
    *isolateentitybymark 1 1 0
    catch {*window_entitymark surfs 1}
    catch {hm_redraw}
}
