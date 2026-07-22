namespace eval ::hmtoolkit::seam::selector {}
namespace eval ::hmtoolkit::seam::interactive {}

proc ::hmtoolkit::seam::selector::marked_ids {entityType markId} {
    set ids {}
    catch {set ids [hm_getmark $entityType $markId]}
    return [lsort -integer -unique $ids]
}

proc ::hmtoolkit::seam::selector::context_from_components {source target} {
    set source [lsort -integer -unique $source]
    set target [lsort -integer -unique $target]
    if {[llength $source] == 0 || [llength $target] == 0} { return {} }
    set sourceSurfs {}; set targetSurfs {}
    foreach compId $source { set sourceSurfs [concat $sourceSurfs [::hmtoolkit::seam::entity::component_surfaces $compId]] }
    foreach compId $target { set targetSurfs [concat $targetSurfs [::hmtoolkit::seam::entity::component_surfaces $compId]] }
    if {[llength $sourceSurfs] == 0 || [llength $targetSurfs] == 0} { return {} }
    return [dict create valid 1 origin PRESELECTED_COMPONENTS source_components $source target_components $target \
        source_surfs [lsort -integer -unique $sourceSurfs] target_surfs [lsort -integer -unique $targetSurfs]]
}

proc ::hmtoolkit::seam::selector::context_from_surfaces {source target} {
    set source [lsort -integer -unique $source]
    set target [lsort -integer -unique $target]
    if {[llength $source] == 0 || [llength $target] == 0} { return {} }
    return [dict create valid 1 origin PRESELECTED_SURFACES source_surfs $source target_surfs $target \
        source_components [::hmtoolkit::seam::selector::components_for_surfaces $source] \
        target_components [::hmtoolkit::seam::selector::components_for_surfaces $target]]
}

proc ::hmtoolkit::seam::selector::capture_preselection {} {
    set comps1 [::hmtoolkit::seam::selector::marked_ids comps 1]
    set comps2 [::hmtoolkit::seam::selector::marked_ids comps 2]
    if {[llength $comps1] > 0 && [llength $comps2] > 0} {
        set context [::hmtoolkit::seam::selector::context_from_components $comps1 $comps2]
        if {$context ne ""} { return $context }
    }
    if {[llength $comps1] >= 2} {
        set context [::hmtoolkit::seam::selector::context_from_components [list [lindex $comps1 0]] [lrange $comps1 1 end]]
        if {$context ne ""} { return $context }
    }
    set surfs1 [::hmtoolkit::seam::selector::marked_ids surfs 1]
    set surfs2 [::hmtoolkit::seam::selector::marked_ids surfs 2]
    if {[llength $surfs1] > 0 && [llength $surfs2] > 0} {
        return [::hmtoolkit::seam::selector::context_from_surfaces $surfs1 $surfs2]
    }
    if {[llength $surfs1] >= 2} {
        return [::hmtoolkit::seam::selector::context_from_surfaces [list [lindex $surfs1 0]] [lrange $surfs1 1 end]]
    }
    return {}
}

proc ::hmtoolkit::seam::selector::strategy_needs_thickness {strategy} {
    return [expr {$strategy in {T_PATH T_LIST L_SURF L_LIST CONNECT}}]
}

proc ::hmtoolkit::seam::selector::accept_thickness {} {
    variable ::hmtoolkit::seam::runtime
    set value [string trim $runtime(prompt_value)]
    if {![string is double -strict $value] || $value <= 0.0} {
        catch {tk_messageBox -icon warning -title "Geometry Seam" -message "Thickness must be a positive number."}
        return
    }
    set runtime(prompt_value) $value
    set runtime(prompt_ok) 1
    catch {destroy .geometry_seam_thickness}
}

proc ::hmtoolkit::seam::selector::prompt_thickness {} {
    variable ::hmtoolkit::seam::runtime
    catch {destroy .geometry_seam_thickness}
    set runtime(prompt_value) ""
    set runtime(prompt_ok) 0
    set w .geometry_seam_thickness
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::txt "输入焊缝板厚" "Input Seam Thickness"]
    wm resizable $w 0 0
    frame $w.body -padx 12 -pady 10
    pack $w.body -fill both -expand 1
    label $w.body.message -text [::HWFlow::txt "无法从组件名称读取厚度，请输入本次焊缝板厚：" "Thickness is unavailable from component names. Enter the seam thickness:"]
    entry $w.body.value -textvariable ::hmtoolkit::seam::runtime(prompt_value) -width 18
    pack $w.body.message -anchor w -pady {0 6}
    pack $w.body.value -anchor w
    frame $w.buttons -padx 12 -pady 8
    pack $w.buttons -fill x
    button $w.buttons.cancel -text [::HWFlow::txt "取消" "Cancel"] -command "set ::hmtoolkit::seam::runtime(prompt_ok) 0; destroy $w"
    button $w.buttons.ok -text [::HWFlow::txt "确定" "OK"] -command ::hmtoolkit::seam::selector::accept_thickness
    pack $w.buttons.ok $w.buttons.cancel -side right -padx 4
    bind $w <Return> ::hmtoolkit::seam::selector::accept_thickness
    bind $w <Escape> "set ::hmtoolkit::seam::runtime(prompt_ok) 0; destroy $w"
    focus $w.body.value
    tkwait window $w
    if {!$runtime(prompt_ok)} { return "" }
    return $runtime(prompt_value)
}

proc ::hmtoolkit::seam::selector::ensure_execution_data {strategy data} {
    variable ::hmtoolkit::seam::config
    if {![::hmtoolkit::seam::selector::strategy_needs_thickness $strategy]} {
        return [dict create valid 1 data $data]
    }
    if {[string is double -strict $config(thickness_override)] && $config(thickness_override) > 0.0} {
        dict set data thickness $config(thickness_override)
        return [dict create valid 1 data $data]
    }
    if {![catch {::hmtoolkit::seam::naming::thickness_from_data $data} thickness]} {
        dict set data thickness $thickness
        return [dict create valid 1 data $data]
    }
    set thickness [::hmtoolkit::seam::selector::prompt_thickness]
    if {$thickness eq ""} { return [dict create valid 0 cancelled 1 message "Thickness input cancelled."] }
    dict set data thickness $thickness
    return [dict create valid 1 data $data]
}

proc ::hmtoolkit::seam::selector::mark_panel {entityType markId prompt {requiredCount ""}} {
    catch {*clearmark $entityType $markId}
    ::HWFlow::nativeMarkPanel $entityType $markId $prompt
    set ids {}
    catch {set ids [hm_getmark $entityType $markId]}
    catch {*clearmark $entityType $markId}
    if {[llength $ids] == 0} { return [dict create valid 0 cancelled 1 message "Operation cancelled."] }
    if {$requiredCount ne "" && [llength $ids] != $requiredCount} {
        return [dict create valid 0 cancelled 0 message "Exactly $requiredCount $entityType entities are required."]
    }
    return [dict create valid 1 ids $ids]
}

proc ::hmtoolkit::seam::selector::list_panel {mode listId prompt} {
    catch {*createlist lines $listId}
    if {$mode eq "PATH"} {
        *createlistbypathpanel lines $listId $prompt
    } else {
        *createlistpanel lines $listId $prompt
    }
    set ids {}
    catch {set ids [hm_getlist lines $listId]}
    catch {*createlist lines $listId}
    if {[llength $ids] == 0} { return [dict create valid 0 cancelled 1 message "Operation cancelled."] }
    return [dict create valid 1 ids $ids]
}

proc ::hmtoolkit::seam::selector::surfaces_for_lines {lineIds} {
    set surfaces {}
    foreach lineId $lineIds {
        catch {*clearmark surfs 1}
        if {![catch {*createmark surfs 1 "by lines" $lineId}]} { catch {set surfaces [concat $surfaces [hm_getmark surfs 1]]} }
    }
    catch {*clearmark surfs 1}
    return [lsort -integer -unique $surfaces]
}

proc ::hmtoolkit::seam::selector::components_for_surfaces {surfIds} {
    set components {}
    foreach surfId $surfIds {
        set id [::hmtoolkit::seam::entity::surface_component $surfId]
        if {$id ne ""} { lappend components $id }
    }
    return [lsort -integer -unique $components]
}

proc ::hmtoolkit::seam::selector::selection_error {selection} {
    if {![dict get $selection valid] && ![dict get $selection cancelled]} {
        catch {hm_errormessage [dict get $selection message]}
    }
    return [dict create success 0 cancelled [dict get $selection cancelled] message [dict get $selection message]]
}

proc ::hmtoolkit::seam::selector::select_analysis_scope {scope} {
    switch -- $scope {
        COMPONENT_PAIR {
            set first [::hmtoolkit::seam::selector::mark_panel comps 1 "Select the first seam component" 1]
            if {![dict get $first valid]} { return $first }
            set second [::hmtoolkit::seam::selector::mark_panel comps 2 "Select the second seam component" 1]
            if {![dict get $second valid]} { return $second }
            set a [dict get $first ids]; set b [dict get $second ids]
            if {[lindex $a 0] == [lindex $b 0]} { return [dict create valid 0 cancelled 0 message "The two components must be different."] }
            return [dict create valid 1 source_components $a target_components $b \
                source_surfs [::hmtoolkit::seam::entity::component_surfaces [lindex $a 0]] \
                target_surfs [::hmtoolkit::seam::entity::component_surfaces [lindex $b 0]]]
        }
        SURFACE_GROUPS {
            set first [::hmtoolkit::seam::selector::mark_panel surfs 1 "Select the first surface group"]
            if {![dict get $first valid]} { return $first }
            set second [::hmtoolkit::seam::selector::mark_panel surfs 2 "Select the second surface group"]
            if {![dict get $second valid]} { return $second }
            set a [dict get $first ids]; set b [dict get $second ids]
            return [dict create valid 1 source_surfs $a target_surfs $b \
                source_components [::hmtoolkit::seam::selector::components_for_surfaces $a] \
                target_components [::hmtoolkit::seam::selector::components_for_surfaces $b]]
        }
        default { return [dict create valid 0 cancelled 0 message "Unsupported analysis scope: $scope"] }
    }
}

proc ::hmtoolkit::seam::selector::select_strategy_input {strategy} {
    switch -- $strategy {
        T_PATH - T_LIST - L_LIST {
            set mode [expr {$strategy eq "T_PATH" ? "PATH" : "LIST"}]
            set lines [::hmtoolkit::seam::selector::list_panel $mode 1 "Select seam lines"]
            if {![dict get $lines valid]} { return $lines }
            set targets [::hmtoolkit::seam::selector::mark_panel surfs 2 "Select target surfaces"]
            if {![dict get $targets valid]} { return $targets }
            set source [::hmtoolkit::seam::selector::surfaces_for_lines [dict get $lines ids]]
            return [dict create valid 1 seam_lines [dict get $lines ids] source_surfs $source target_surfs [dict get $targets ids] \
                source_components [::hmtoolkit::seam::selector::components_for_surfaces $source] \
                target_components [::hmtoolkit::seam::selector::components_for_surfaces [dict get $targets ids]]]
        }
        L_SURF {
            set source [::hmtoolkit::seam::selector::mark_panel surfs 1 "Select one base surface" 1]
            if {![dict get $source valid]} { return $source }
            set target [::hmtoolkit::seam::selector::mark_panel surfs 2 "Select one target surface" 1]
            if {![dict get $target valid]} { return $target }
            return [dict create valid 1 source_surfs [dict get $source ids] target_surfs [dict get $target ids] \
                source_components [::hmtoolkit::seam::selector::components_for_surfaces [dict get $source ids]] \
                target_components [::hmtoolkit::seam::selector::components_for_surfaces [dict get $target ids]]]
        }
        CONNECT {
            set first [::hmtoolkit::seam::selector::list_panel LIST 1 "Select the first edge group"]
            if {![dict get $first valid]} { return $first }
            set second [::hmtoolkit::seam::selector::list_panel LIST 2 "Select the second edge group"]
            if {![dict get $second valid]} { return $second }
            set surfaces [::hmtoolkit::seam::selector::surfaces_for_lines [concat [dict get $first ids] [dict get $second ids]]]
            return [dict create valid 1 first_lines [dict get $first ids] second_lines [dict get $second ids] \
                source_components [::hmtoolkit::seam::selector::components_for_surfaces $surfaces]]
        }
        PROJECT - SPLIT {
            set lines [::hmtoolkit::seam::selector::mark_panel lines 2 "Select lines to project/split"]
            if {![dict get $lines valid]} { return $lines }
            set count [expr {$strategy eq "PROJECT" ? 1 : ""}]
            set target [::hmtoolkit::seam::selector::mark_panel surfs 1 "Select target surfaces" $count]
            if {![dict get $target valid]} { return $target }
            return [dict create valid 1 seam_lines [dict get $lines ids] target_surfs [dict get $target ids]]
        }
        COMBINE - DELETE {
            set selected [::hmtoolkit::seam::selector::mark_panel surfs 1 "Select seam surfaces"]
            if {![dict get $selected valid]} { return $selected }
            return [dict create valid 1 surfaces [dict get $selected ids]]
        }
        DISTRIBUTE_POINTS {
            set selected [::hmtoolkit::seam::selector::mark_panel lines 1 "Select lines for distributed points"]
            if {![dict get $selected valid]} { return $selected }
            return [dict create valid 1 seam_lines [dict get $selected ids]]
        }
        REPLACE_POINT {
            set point [::hmtoolkit::seam::selector::mark_panel points 1 "Select one point" 1]
            if {![dict get $point valid]} { return $point }
            set line [::hmtoolkit::seam::selector::mark_panel lines 2 "Select one projection line" 1]
            if {![dict get $line valid]} { return $line }
            return [dict create valid 1 points [dict get $point ids] seam_lines [dict get $line ids]]
        }
        EXTEND {
            set line [::hmtoolkit::seam::selector::mark_panel lines 1 "Select one seam edge to extend" 1]
            if {![dict get $line valid]} { return $line }
            set targets [::hmtoolkit::seam::selector::mark_panel surfs 2 "Select extension target surfaces"]
            if {![dict get $targets valid]} { return $targets }
            return [dict create valid 1 seam_lines [dict get $line ids] target_surfs [dict get $targets ids]]
        }
        default { return [dict create valid 0 cancelled 0 message "Unsupported interactive strategy: $strategy"] }
    }
}

proc ::hmtoolkit::seam::interactive::run {strategy} {
    set data [::hmtoolkit::seam::selector::select_strategy_input $strategy]
    if {![dict get $data valid]} { return [::hmtoolkit::seam::selector::selection_error $data] }
    dict unset data valid
    set prepared [::hmtoolkit::seam::selector::ensure_execution_data $strategy $data]
    if {![dict get $prepared valid]} { return $prepared }
    return [::hmtoolkit::seam::executor::dispatch $strategy [dict get $prepared data]]
}

foreach {name strategy} {
    create_t_path T_PATH create_t_list T_LIST create_l_surface L_SURF create_l_list L_LIST
    connect_edges CONNECT project_lines PROJECT extend_surface EXTEND combine_surfaces COMBINE
    split_surface SPLIT replace_point REPLACE_POINT distribute_points DISTRIBUTE_POINTS delete_seam_surface DELETE
} {
    proc ::hmtoolkit::seam::interactive::$name {} [format {return [::hmtoolkit::seam::interactive::run %s]} $strategy]
}
