namespace eval ::hmtoolkit::seam::entity {}

proc ::hmtoolkit::seam::entity::normalize_type {entityType} {
    switch -- $entityType {
        surface - surfaces { return surfs }
        component - components { return comps }
        solid { return solids }
        line { return lines }
        point { return points }
        default { return $entityType }
    }
}

proc ::hmtoolkit::seam::entity::snapshot_ids {entityType {markId 2}} {
    set entityType [::hmtoolkit::seam::entity::normalize_type $entityType]
    catch {*clearmark $entityType $markId}
    set ids {}
    if {![catch {*createmark $entityType $markId all}]} {
        catch {set ids [hm_getmark $entityType $markId]}
    }
    catch {*clearmark $entityType $markId}
    return [lsort -integer -unique $ids]
}

proc ::hmtoolkit::seam::entity::diff_ids {before after} {
    array set seen {}
    foreach id $before { set seen($id) 1 }
    set added {}
    foreach id $after {
        if {![info exists seen($id)]} { lappend added $id }
    }
    return [lsort -integer -unique $added]
}

proc ::hmtoolkit::seam::entity::exists {entityType id} {
    if {![string is integer -strict $id] || $id <= 0} { return 0 }
    set entityType [::hmtoolkit::seam::entity::normalize_type $entityType]
    catch {*clearmark $entityType 2}
    if {[catch {*createmark $entityType 2 $id}]} { return 0 }
    set ids {}
    catch {set ids [hm_getmark $entityType 2]}
    catch {*clearmark $entityType 2}
    return [expr {[lsearch -exact $ids $id] >= 0}]
}

proc ::hmtoolkit::seam::entity::mark {entityType markId ids} {
    set entityType [::hmtoolkit::seam::entity::normalize_type $entityType]
    catch {*clearmark $entityType $markId}
    if {[llength $ids] == 0} { return 0 }
    eval [linsert $ids 0 *createmark $entityType $markId]
    return [llength $ids]
}

proc ::hmtoolkit::seam::entity::surface_component {surfId} {
    foreach dataname {collector.id component.id componentid component collector} {
        if {![catch {set value [hm_getvalue surfs id=$surfId dataname=$dataname]}] && $value ne ""} {
            if {[string is integer -strict $value]} { return $value }
            set id [::HWFlow::componentIdByName $value]
            if {$id ne ""} { return $id }
        }
    }
    return ""
}

proc ::hmtoolkit::seam::entity::component_surfaces {compId} {
    foreach dataname {surfaces surfs} {
        if {![catch {set ids [hm_getvalue comps id=$compId dataname=$dataname]}] && [llength $ids] > 0} {
            return [lsort -integer -unique $ids]
        }
    }
    catch {*clearmark surfs 2}
    set ids {}
    if {![catch {*createmark surfs 2 "by comp id" $compId}]} { catch {set ids [hm_getmark surfs 2]} }
    if {[llength $ids] == 0} {
        set compName [::HWFlow::componentName $compId]
        if {$compName ne "" && ![catch {*createmark surfs 2 "by comp" $compName}]} { catch {set ids [hm_getmark surfs 2]} }
    }
    catch {*clearmark surfs 2}
    return [lsort -integer -unique $ids]
}

proc ::hmtoolkit::seam::entity::surface_lines {surfIds} {
    if {[llength $surfIds] == 0} { return {} }
    set ids {}
    foreach surfId $surfIds {
        set surfaceIds {}
        # hm_getsurfaceedges is already used by other HM2019 geometry modules
        # in this repository and returns boundary loops of geometry edge IDs.
        if {![catch {set loops [hm_getsurfaceedges $surfId]}]} {
            foreach loop $loops { set surfaceIds [concat $surfaceIds $loop] }
        }
        if {[llength $surfaceIds] == 0} {
            foreach command [list [list hm_getlinesfromsurface $surfId] [list hm_getedgesfromsurface $surfId]] {
                if {![catch {set found [eval $command]}]} { set surfaceIds [concat $surfaceIds $found] }
            }
        }
        set ids [concat $ids $surfaceIds]
    }
    return [lsort -integer -unique $ids]
}

proc ::hmtoolkit::seam::entity::new_ids_around {entityType script} {
    set before [::hmtoolkit::seam::entity::snapshot_ids $entityType]
    uplevel 1 $script
    set after [::hmtoolkit::seam::entity::snapshot_ids $entityType]
    return [::hmtoolkit::seam::entity::diff_ids $before $after]
}
