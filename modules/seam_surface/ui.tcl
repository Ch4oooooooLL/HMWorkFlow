namespace eval ::hmtoolkit::seam::ui {
    variable window .geometry_seam
    variable review_state {}
    variable selected_index -1
}

proc ::hmtoolkit::seam::ui::center {w} {
    update idletasks
    wm geometry $w +[expr {([winfo screenwidth $w]-[winfo reqwidth $w])/2}]+[expr {([winfo screenheight $w]-[winfo reqheight $w])/2}]
}

proc ::hmtoolkit::seam::ui::set_status {text} {
    variable ::hmtoolkit::seam::runtime
    set runtime(status) $text
    catch {update idletasks}
}

proc ::hmtoolkit::seam::ui::context_text {context} {
    if {$context eq "" || ![dict exists $context valid] || ![dict get $context valid]} {
        return [::HWFlow::txt "未传入几何范围" "No incoming geometry"]
    }
    return [::HWFlow::txt \
        "已传入：源组件 [llength [dict get $context source_components]]，目标组件 [llength [dict get $context target_components]]，源面 [llength [dict get $context source_surfs]]，目标面 [llength [dict get $context target_surfs]]" \
        "Incoming: source comps [llength [dict get $context source_components]], target comps [llength [dict get $context target_components]], source surfaces [llength [dict get $context source_surfs]], target surfaces [llength [dict get $context target_surfs]]"]
}

proc ::hmtoolkit::seam::ui::set_context {context} {
    variable ::hmtoolkit::seam::runtime
    set runtime(context_data) $context
    set runtime(context_text) [::hmtoolkit::seam::ui::context_text $context]
}

proc ::hmtoolkit::seam::ui::clear_context {} {
    ::hmtoolkit::seam::ui::set_context {}
    ::hmtoolkit::seam::ui::set_status [::HWFlow::txt "已清除传入范围；精确创建将调用选择器。" "Incoming scope cleared; precise creation will invoke a selector."]
}

proc ::hmtoolkit::seam::ui::show {{settingsOnly 0} {initialContext {}}} {
    variable window
    variable review_state
    variable ::hmtoolkit::seam::runtime
    variable ::hmtoolkit::seam::config
    ::hmtoolkit::seam::config::load
    if {$runtime(log_file) eq ""} { ::hmtoolkit::seam::log::begin }
    set review_state [::hmtoolkit::seam::state::capture]
    set runtime(candidates) {}
    ::hmtoolkit::seam::ui::set_context $initialContext
    set runtime(status) [::HWFlow::txt "请选择局部范围后分析；创建前始终需要确认。" "Select a local scope and analyze; creation always requires confirmation."]
    catch {destroy $window}
    ::HWFlow::createTopLevel $window
    wm title $window [::HWFlow::txt "几何焊缝" "Geometry Seam"]
    wm resizable $window 1 1

    frame $window.body -padx 10 -pady 8
    pack $window.body -fill both -expand 1
    labelframe $window.body.auto -text [::HWFlow::txt "自动识别与复核" "Automatic Recognition and Review"] -padx 8 -pady 6
    pack $window.body.auto -fill both -expand 1
    radiobutton $window.body.auto.c -text [::HWFlow::txt "两个组件" "Two components"] -variable ::hmtoolkit::seam::runtime(selection_scope) -value COMPONENT_PAIR
    radiobutton $window.body.auto.s -text [::HWFlow::txt "两组曲面" "Two surface groups"] -variable ::hmtoolkit::seam::runtime(selection_scope) -value SURFACE_GROUPS
    button $window.body.auto.analyze -text [::HWFlow::txt "分析" "Analyze"] -command ::hmtoolkit::seam::ui::analyze
    grid $window.body.auto.c -row 0 -column 0 -sticky w
    grid $window.body.auto.s -row 0 -column 1 -sticky w -padx 8
    grid $window.body.auto.analyze -row 0 -column 2 -sticky e
    grid columnconfigure $window.body.auto 1 -weight 1

    listbox $window.body.auto.list -height 7 -width 100 -exportselection 0
    scrollbar $window.body.auto.scroll -orient vertical -command "$window.body.auto.list yview"
    $window.body.auto.list configure -yscrollcommand "$window.body.auto.scroll set"
    grid $window.body.auto.list -row 1 -column 0 -columnspan 3 -sticky nsew -pady 6
    grid $window.body.auto.scroll -row 1 -column 3 -sticky ns -pady 6
    grid rowconfigure $window.body.auto 1 -weight 1
    bind $window.body.auto.list <<ListboxSelect>> ::hmtoolkit::seam::ui::candidate_selected

    frame $window.body.auto.review
    grid $window.body.auto.review -row 2 -column 0 -columnspan 4 -sticky ew
    label $window.body.auto.review.jl -text [::HWFlow::txt "类型" "Joint"]
    tk_optionMenu $window.body.auto.review.j ::hmtoolkit::seam::runtime(forced_joint) AUTO T_JOINT CORNER_JOINT LAP_JOINT UNKNOWN
    label $window.body.auto.review.sl -text [::HWFlow::txt "策略" "Strategy"]
    tk_optionMenu $window.body.auto.review.s ::hmtoolkit::seam::runtime(forced_strategy) AUTO T_PATH T_LIST L_SURF L_LIST CONNECT PROJECT REVIEW
    button $window.body.auto.review.locate -text [::HWFlow::txt "定位/孤立" "Locate/Isolate"] -command ::hmtoolkit::seam::ui::locate_candidate
    button $window.body.auto.review.restore -text [::HWFlow::txt "恢复显示" "Restore View"] -command ::hmtoolkit::seam::ui::restore_view
    button $window.body.auto.review.create -text [::HWFlow::txt "确认创建" "Confirm Create"] -command ::hmtoolkit::seam::ui::create_candidate
    pack $window.body.auto.review.jl $window.body.auto.review.j $window.body.auto.review.sl $window.body.auto.review.s -side left -padx 3
    pack $window.body.auto.review.create $window.body.auto.review.restore $window.body.auto.review.locate -side right -padx 3

    labelframe $window.body.precise -text [::HWFlow::txt "精确创建 / 编辑 / 删除" "Precise Creation / Edit / Delete"] -padx 8 -pady 6
    pack $window.body.precise -fill x -pady 8
    label $window.body.precise.context -textvariable ::hmtoolkit::seam::runtime(context_text) -anchor w -justify left
    button $window.body.precise.clear -text [::HWFlow::txt "清除传入范围" "Clear Incoming Scope"] -command ::hmtoolkit::seam::ui::clear_context
    grid $window.body.precise.context -row 0 -column 0 -columnspan 3 -sticky ew -padx 3 -pady {0 5}
    grid $window.body.precise.clear -row 0 -column 3 -sticky e -padx 3 -pady {0 5}
    set actions {
        {T_PATH "T路径" "T Path"} {T_LIST "T列表" "T List"} {L_SURF "搭接曲面" "Lap Surface"}
        {L_LIST "搭接边线" "Lap Edges"} {CONNECT "连接边线" "Connect Edges"} {PROJECT "投影切分" "Project/Split"}
        {EXTEND "延伸" "Extend"} {COMBINE "合并" "Combine"} {SPLIT "拆分" "Split"}
        {REPLACE_POINT "替换点" "Replace Point"} {DISTRIBUTE_POINTS "分布点" "Distribute Points"} {DELETE "删除" "Delete"}
    }
    set column 0; set row 1
    foreach action $actions {
        set strategy [lindex $action 0]
        button $window.body.precise.b_$strategy -text [::HWFlow::txt [lindex $action 1] [lindex $action 2]] -width 14 \
            -command [list ::hmtoolkit::seam::ui::run_precise $strategy]
        grid $window.body.precise.b_$strategy -row $row -column $column -padx 3 -pady 3 -sticky ew
        incr column
        if {$column == 4} { set column 0; incr row }
    }
    for {set i 0} {$i < 4} {incr i} { grid columnconfigure $window.body.precise $i -weight 1 }

    labelframe $window.body.params -text [::HWFlow::txt "参数" "Parameters"] -padx 8 -pady 6
    pack $window.body.params -fill x -pady {0 8}
    set fields {
        {angle_parallel_max "平行角度上限" "Parallel angle max"}
        {angle_perpendicular_min "垂直角度下限" "Perpendicular angle min"}
        {distance_tolerance "距离容差" "Distance tolerance"}
        {min_seam_length "最小焊缝长度" "Minimum seam length"}
        {point_spacing "分布点间距" "Point spacing"}
        {auto_accept_confidence "自动接受置信度" "Auto-accept confidence"}
        {review_confidence "人工复核置信度" "Review confidence"}
        {thickness_override "厚度覆盖（0=自动/询问）" "Thickness override (0=auto/prompt)"}
    }
    set index 0
    foreach field $fields {
        set key [lindex $field 0]
        set row [expr {$index/2}]
        set pair [expr {$index%2}]
        label $window.body.params.l_$key -text [::HWFlow::txt [lindex $field 1] [lindex $field 2]] -anchor w
        entry $window.body.params.e_$key -textvariable ::hmtoolkit::seam::config($key) -width 12
        grid $window.body.params.l_$key -row $row -column [expr {$pair*2}] -sticky w -padx {3 6} -pady 2
        grid $window.body.params.e_$key -row $row -column [expr {$pair*2+1}] -sticky ew -padx {0 12} -pady 2
        incr index
    }
    grid columnconfigure $window.body.params 1 -weight 1
    grid columnconfigure $window.body.params 3 -weight 1
    set optionRow [expr {([llength $fields]+1)/2}]
    label $window.body.params.l_shortcut_mode -text [::HWFlow::txt "快捷键选择方式" "Shortcut selector mode"] -anchor w
    tk_optionMenu $window.body.params.m_shortcut_mode ::hmtoolkit::seam::config(shortcut_selector_mode) PANEL CONFIG
    label $window.body.params.l_shortcut_scope -text [::HWFlow::txt "配置模式选择范围" "Configured shortcut scope"] -anchor w
    tk_optionMenu $window.body.params.m_shortcut_scope ::hmtoolkit::seam::config(shortcut_scope) COMPONENT_PAIR SURFACE_GROUPS
    grid $window.body.params.l_shortcut_mode -row $optionRow -column 0 -sticky w -padx {3 6} -pady 2
    grid $window.body.params.m_shortcut_mode -row $optionRow -column 1 -sticky ew -padx {0 12} -pady 2
    grid $window.body.params.l_shortcut_scope -row $optionRow -column 2 -sticky w -padx {3 6} -pady 2
    grid $window.body.params.m_shortcut_scope -row $optionRow -column 3 -sticky ew -padx {0 12} -pady 2

    label $window.body.status -textvariable ::hmtoolkit::seam::runtime(status) -anchor w -justify left -wraplength 760
    pack $window.body.status -fill x -pady 4
    frame $window.buttons
    pack $window.buttons -fill x
    button $window.buttons.save -text [::HWFlow::txt "保存配置" "Save Settings"] -command ::hmtoolkit::seam::ui::save_settings
    button $window.buttons.close -text [::HWFlow::txt "关闭" "Close"] -command ::hmtoolkit::seam::ui::close
    pack $window.buttons.close $window.buttons.save -side right -padx 4
    wm protocol $window WM_DELETE_WINDOW ::hmtoolkit::seam::ui::close
    bind $window <Escape> ::hmtoolkit::seam::ui::close
    ::hmtoolkit::seam::ui::center $window
    return $window
}

proc ::hmtoolkit::seam::ui::save_settings {} {
    variable ::hmtoolkit::seam::config
    foreach key {angle_parallel_max angle_perpendicular_min distance_tolerance min_seam_length point_spacing auto_accept_confidence review_confidence} {
        if {![string is double -strict $config($key)] || $config($key) <= 0.0} {
            ::hmtoolkit::seam::ui::set_status "$key must be a positive number."
            return 0
        }
    }
    if {![string is double -strict $config(thickness_override)] || $config(thickness_override) < 0.0} {
        ::hmtoolkit::seam::ui::set_status "thickness_override must be zero or a positive number."
        return 0
    }
    if {$config(shortcut_selector_mode) ni {PANEL CONFIG} || $config(shortcut_scope) ni {COMPONENT_PAIR SURFACE_GROUPS}} {
        ::hmtoolkit::seam::ui::set_status "Invalid shortcut selector configuration."
        return 0
    }
    if {$config(angle_parallel_max) >= $config(angle_perpendicular_min)} {
        ::hmtoolkit::seam::ui::set_status "angle_parallel_max must be less than angle_perpendicular_min."
        return 0
    }
    if {$config(review_confidence) > $config(auto_accept_confidence) || $config(auto_accept_confidence) > 1.0} {
        ::hmtoolkit::seam::ui::set_status "Confidence thresholds must satisfy review <= auto-accept <= 1.0."
        return 0
    }
    ::hmtoolkit::seam::config::save
    ::hmtoolkit::seam::ui::set_status [::HWFlow::txt "参数已保存。" "Settings saved."]
    return 1
}

proc ::hmtoolkit::seam::ui::analyze {} {
    variable ::hmtoolkit::seam::runtime
    set selected [::hmtoolkit::seam::selector::select_analysis_scope $runtime(selection_scope)]
    if {![dict get $selected valid]} {
        ::hmtoolkit::seam::ui::set_status [dict get $selected message]
        return
    }
    ::hmtoolkit::seam::ui::set_context $selected
    ::hmtoolkit::seam::ui::analyze_context $selected
}

proc ::hmtoolkit::seam::ui::render_candidates {candidates} {
    variable window
    variable selected_index
    variable ::hmtoolkit::seam::runtime
    set runtime(candidates) $candidates
    set selected_index -1
    $window.body.auto.list delete 0 end
    set index 0
    foreach candidate $candidates {
        $window.body.auto.list insert end [format "%s | %s | %s | confidence=%s | length=%.4g" \
            [dict get $candidate candidate_id] [dict get $candidate joint_type] [dict get $candidate strategy] \
            [dict get $candidate confidence] [dict get $candidate seam_length]]
        incr index
    }
    if {[llength $candidates] == 0} {
        ::hmtoolkit::seam::ui::set_status [::HWFlow::txt "未找到满足距离容差的局部候选。" "No local candidate satisfies the distance tolerance."]
    } else {
        $window.body.auto.list selection set 0
        ::hmtoolkit::seam::ui::candidate_selected
        ::hmtoolkit::seam::log::write INFO "Analyzed context candidates=[llength $candidates]"
    }
}

proc ::hmtoolkit::seam::ui::analyze_context {context {forcedStrategy AUTO}} {
    set candidates [::hmtoolkit::seam::candidate::extract [dict get $context source_surfs] [dict get $context target_surfs] \
        [dict get $context source_components] [dict get $context target_components]]
    if {$forcedStrategy ne "AUTO"} {
        set precise {}
        foreach candidate $candidates {
            set kind [dict get [dict get $candidate path_topology] kind]
            set detected [dict get $candidate joint_type]
            set keep 1
            switch -- $forcedStrategy {
                T_PATH {
                    if {$kind ne "PATH" || $detected ni {T_JOINT UNKNOWN}} { set keep 0 }
                    dict set candidate joint_type T_JOINT
                }
                T_LIST {
                    if {$kind eq "BRANCH" || $detected ni {T_JOINT UNKNOWN}} { set keep 0 }
                    dict set candidate joint_type T_JOINT
                }
                L_SURF {
                    if {$detected ni {LAP_JOINT UNKNOWN}} { set keep 0 }
                    dict set candidate joint_type LAP_JOINT
                }
                L_LIST {
                    if {$kind eq "BRANCH" || $detected ni {LAP_JOINT UNKNOWN}} { set keep 0 }
                    dict set candidate joint_type LAP_JOINT
                }
                CONNECT {
                    if {$detected ni {CORNER_JOINT UNKNOWN} || [llength [dict get $candidate paired_target_lines]] == 0} { set keep 0 }
                    dict set candidate joint_type CORNER_JOINT
                }
                PROJECT { dict set candidate joint_type PROJECT_REQUIRED }
            }
            if {!$keep} { continue }
            if {$detected eq "UNKNOWN"} { dict lappend candidate warnings "Precise type was requested but automatic classification remained UNKNOWN; manual review is required." }
            dict set candidate strategy $forcedStrategy
            dict lappend candidate reasons "Precise recognition requested strategy $forcedStrategy."
            lappend precise $candidate
        }
        set candidates $precise
    }
    ::hmtoolkit::seam::ui::render_candidates $candidates
    return $candidates
}

proc ::hmtoolkit::seam::ui::candidate_selected {} {
    variable window
    variable selected_index
    variable ::hmtoolkit::seam::runtime
    set selection [$window.body.auto.list curselection]
    if {[llength $selection] == 0} { set selected_index -1; return }
    set selected_index [lindex $selection 0]
    set candidate [lindex $runtime(candidates) $selected_index]
    set runtime(forced_joint) AUTO
    set runtime(forced_strategy) AUTO
    ::hmtoolkit::seam::ui::set_status "Reasons: [join [dict get $candidate reasons] {; }]  Warnings: [join [dict get $candidate warnings] {; }]"
}

proc ::hmtoolkit::seam::ui::current_candidate {} {
    variable selected_index
    variable ::hmtoolkit::seam::runtime
    if {$selected_index < 0 || $selected_index >= [llength $runtime(candidates)]} { return "" }
    set candidate [lindex $runtime(candidates) $selected_index]
    if {$runtime(forced_joint) ne "AUTO"} {
        dict set candidate joint_type $runtime(forced_joint)
        if {$runtime(forced_strategy) eq "AUTO"} {
            set pathKind [dict get [dict get $candidate path_topology] kind]
            switch -- $runtime(forced_joint) {
                T_JOINT { dict set candidate strategy [expr {$pathKind eq "PATH" ? "T_PATH" : "T_LIST"}] }
                CORNER_JOINT { dict set candidate strategy CONNECT }
                LAP_JOINT { dict set candidate strategy [expr {$pathKind eq "LIST" ? "L_LIST" : "L_SURF"}] }
                UNKNOWN { dict set candidate strategy REVIEW }
            }
        }
    }
    if {$runtime(forced_strategy) ne "AUTO"} { dict set candidate strategy $runtime(forced_strategy) }
    return $candidate
}

proc ::hmtoolkit::seam::ui::locate_candidate {} {
    set candidate [::hmtoolkit::seam::ui::current_candidate]
    if {$candidate eq ""} { return }
    set comps [lsort -integer -unique [concat [dict get $candidate source_components] [dict get $candidate target_components]]]
    set all [::hmtoolkit::seam::entity::snapshot_ids comps]
    catch {::hmtoolkit::seam::entity::mark comps 1 $all; *displaycollectorsbymark comps 1 off 1 1}
    catch {::hmtoolkit::seam::entity::mark comps 1 $comps; *displaycollectorsbymark comps 1 on 1 1}
    catch {*createmark lines 1 {*}[dict get $candidate seam_lines]}
    catch {*viewfit}
    catch {hm_redraw}
}

proc ::hmtoolkit::seam::ui::restore_view {} {
    variable review_state
    if {$review_state ne ""} { ::hmtoolkit::seam::state::restore $review_state; catch {hm_redraw} }
}

proc ::hmtoolkit::seam::ui::create_candidate {} {
    set candidate [::hmtoolkit::seam::ui::current_candidate]
    if {$candidate eq ""} { ::hmtoolkit::seam::ui::set_status "Select a candidate first."; return }
    set strategy [dict get $candidate strategy]
    if {$strategy eq "REVIEW"} { ::hmtoolkit::seam::ui::set_status "Choose an executable strategy before creation."; return }
    if {$strategy eq "CONNECT"} {
        dict set candidate first_lines [dict get $candidate seam_lines]
        dict set candidate second_lines [dict get $candidate paired_target_lines]
    }
    set prepared [::hmtoolkit::seam::selector::ensure_execution_data $strategy $candidate]
    if {![dict get $prepared valid]} {
        ::hmtoolkit::seam::ui::set_status [dict get $prepared message]
        return
    }
    set result [::hmtoolkit::seam::executor::dispatch $strategy [dict get $prepared data]]
    ::hmtoolkit::seam::ui::set_status [dict get $result message]
}

proc ::hmtoolkit::seam::ui::run_precise {strategy} {
    variable ::hmtoolkit::seam::runtime
    if {$runtime(context_data) ne "" && $strategy in {T_PATH T_LIST L_SURF L_LIST CONNECT PROJECT}} {
        set candidates [::hmtoolkit::seam::ui::analyze_context $runtime(context_data) $strategy]
        if {[llength $candidates] == 0} {
            ::hmtoolkit::seam::ui::set_status [::HWFlow::txt "传入范围内没有找到适用于该精确类型的候选。" "No candidate for this precise type was found in the incoming scope."]
        } else {
            ::hmtoolkit::seam::ui::set_status [::HWFlow::txt "已针对传入范围完成精确识别，请复核后确认创建。" "Precise recognition used the incoming scope; review and confirm creation."]
        }
        return
    }
    set result [::hmtoolkit::seam::interactive::run $strategy]
    if {[dict exists $result message]} { ::hmtoolkit::seam::ui::set_status [dict get $result message] }
}

proc ::hmtoolkit::seam::ui::shortcut_accept_context {context} {
    if {$context eq "" || ![dict exists $context valid] || ![dict get $context valid]} { return 0 }
    ::hmtoolkit::seam::ui::show 0 $context
    ::hmtoolkit::seam::ui::analyze_context $context
    return 1
}

proc ::hmtoolkit::seam::ui::shortcut_select_scope {scope} {
    catch {destroy .geometry_seam_shortcut_selector}
    set context [::hmtoolkit::seam::selector::select_analysis_scope $scope]
    if {![dict get $context valid]} { return 0 }
    return [::hmtoolkit::seam::ui::shortcut_accept_context $context]
}

proc ::hmtoolkit::seam::ui::shortcut_selector_panel {} {
    variable ::hmtoolkit::seam::runtime
    variable ::hmtoolkit::seam::config
    set runtime(shortcut_panel_scope) $config(shortcut_scope)
    catch {destroy .geometry_seam_shortcut_selector}
    set w .geometry_seam_shortcut_selector
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::txt "几何焊缝选择器" "Geometry Seam Selector"]
    wm resizable $w 0 0
    frame $w.body -padx 12 -pady 10
    pack $w.body -fill both -expand 1
    label $w.body.title -text [::HWFlow::txt "选择范围类型后立即进入 HyperMesh 选择面板" "Choose a scope type, then enter the HyperMesh selector immediately"]
    radiobutton $w.body.comps -text [::HWFlow::txt "两个组件" "Two components"] -variable ::hmtoolkit::seam::runtime(shortcut_panel_scope) -value COMPONENT_PAIR
    radiobutton $w.body.surfs -text [::HWFlow::txt "两组曲面" "Two surface groups"] -variable ::hmtoolkit::seam::runtime(shortcut_panel_scope) -value SURFACE_GROUPS
    pack $w.body.title $w.body.comps $w.body.surfs -anchor w -pady 3
    frame $w.buttons -padx 12 -pady 8
    pack $w.buttons -fill x
    button $w.buttons.cancel -text [::HWFlow::txt "取消" "Cancel"] -command "destroy $w"
    button $w.buttons.start -text [::HWFlow::txt "开始选择" "Start Selection"] -command {::hmtoolkit::seam::ui::shortcut_select_scope $::hmtoolkit::seam::runtime(shortcut_panel_scope)}
    pack $w.buttons.start $w.buttons.cancel -side right -padx 4
    bind $w <Return> {::hmtoolkit::seam::ui::shortcut_select_scope $::hmtoolkit::seam::runtime(shortcut_panel_scope)}
    bind $w <Escape> "destroy $w"
    ::hmtoolkit::seam::ui::center $w
    return $w
}

proc ::hmtoolkit::seam::ui::run_shortcut {} {
    variable ::hmtoolkit::seam::config
    ::hmtoolkit::seam::config::load
    if {$config(shortcut_selector_mode) eq "CONFIG"} {
        return [::hmtoolkit::seam::ui::shortcut_select_scope $config(shortcut_scope)]
    }
    return [::hmtoolkit::seam::ui::shortcut_selector_panel]
}

proc ::hmtoolkit::seam::ui::close {} {
    variable window
    ::hmtoolkit::seam::ui::restore_view
    catch {destroy $window}
}
