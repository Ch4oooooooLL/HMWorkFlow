namespace eval ::hmtoolkit::seam::ui {
    variable window .geometry_seam
    variable review_state {}
}

proc ::hmtoolkit::seam::ui::center {w} {
    update idletasks
    ::HWFlow::centerWindow $w
}

proc ::hmtoolkit::seam::ui::set_status {text} {
    variable ::hmtoolkit::seam::runtime
    set runtime(status) $text
    catch {update idletasks}
}

proc ::hmtoolkit::seam::ui::show {{settingsOnly 0} {initialContext {}}} {
    variable window
    variable review_state
    variable ::hmtoolkit::seam::runtime
    variable ::hmtoolkit::seam::config
    ::hmtoolkit::seam::config::load
    if {$runtime(log_file) eq ""} { ::hmtoolkit::seam::log::begin }
    set review_state [::hmtoolkit::seam::state::capture]
    if {$settingsOnly} {
        set runtime(status) [::HWFlow::txt "调整后点击“保存配置”；距离和容差采用当前模型单位。" "Adjust values and click Save Settings; distances and tolerances use model units."]
    } else {
        set runtime(status) [::HWFlow::txt "请选择焊缝类型并精确选取几何；创建前始终需要确认。" "Choose a seam type and select geometry precisely; creation always requires confirmation."]
    }
    catch {destroy $window}
    ::HWFlow::createTopLevel $window
    if {$settingsOnly} {
        set panelTitle [::HWFlow::txt "几何焊缝设置" "Geometry Seam Settings"]
    } else {
        set panelTitle [::HWFlow::txt "几何焊缝" "Geometry Seam"]
    }
    wm title $window [::HWFlow::windowTitle $panelTitle "Geometry Seam"]
    wm resizable $window 1 1

    frame $window.body -padx 10 -pady 8
    pack $window.body -fill both -expand 1

    if {!$settingsOnly} {
        labelframe $window.body.precise -text [::HWFlow::txt "精确创建 / 编辑 / 删除" "Precise Creation / Edit / Delete"] -padx 8 -pady 6
        pack $window.body.precise -fill x -pady 8
        set actions {
        {T_PATH "T曲面" "T Surface"} {T_LIST "T列表" "T List"} {L_SURF "搭接曲面（平行重叠）" "Lap Surface (overlap)"}
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
        label $window.body.precise.help -anchor w -justify left -wraplength 760 -text [::HWFlow::txt \
            "T 曲面：两组曲面延伸；T 列表：边线投影后创建连接面；搭接曲面仅用于近似平行且投影区域重叠的两张面，边到面请用搭接边线；其余按钮用于投影、连接、延伸、拓扑合并、拆分、点编辑和删除。" \
            "T Surface extends two surface groups; T List projects an edge path; Lap Surface requires two approximately parallel faces with an overlapping projected area, while edge-to-surface joints use Lap Edges; the remaining actions project, connect, extend, combine, split, edit points, or delete."]
        grid $window.body.precise.help -row [expr {$row+1}] -column 0 -columnspan 4 -sticky ew -padx 3 -pady {5 1}
    }

    labelframe $window.body.params -text [::HWFlow::txt "参数（审计可配置项）" "Parameters (audit-configurable)"] -padx 8 -pady 6
    pack $window.body.params -fill x -pady {0 8}
    set fields {
        {endpoint_merge_tolerance "端点合并容差" "Endpoint merge tolerance"}
        {stitch_tolerance "拓扑缝合容差" "Topology stitch tolerance"}
        {cleanup_tolerance "合并清理容差" "Merge cleanup tolerance"}
        {projected_path_merge_tolerance "投影路径端点合并容差" "Projected-path endpoint tolerance"}
        {projected_path_ambiguity_tolerance "投影路径判定容差" "Projected-path ambiguity tolerance"}
        {area_tolerance "曲面面积下限" "Minimum surface area"}
        {volume_tolerance "实体体积下限" "Minimum solid volume"}
        {min_seam_length "最小焊缝长度" "Minimum seam length"}
        {point_spacing "分布点间距" "Point spacing"}
        {geometry_offset_distance "搭接厚化距离" "Lap offset distance"}
        {extend_offset_distance "延伸偏置距离" "Extend offset distance"}
        {extend_connect_distance "延伸搜索距离（模式3通常为0）" "Extend search distance (normally 0 for mode 3)"}
        {connect_extend_distance "T曲面延伸距离" "T Surface extend distance"}
        {connect_min_angle_to_target "目标面最小夹角" "Min angle to target"}
        {connect_max_angle_edge_to_surf "边-面最大夹角" "Max edge-surface angle"}
        {connect_guide_angle "引导判定角度" "Guide angle"}
        {lap_connect_distance "搭接连接距离" "Lap connect distance"}
        {lap_result_envelope_tolerance "搭接结果包络容差" "Lap result envelope tolerance"}
        {replace_point_projection_distance "替换点最大投影距离（-1=最近）" "Replace-point max projection (-1=nearest)"}
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
    set optionFields {
        {lap_boolean_opcode "搭接布尔模式（8=并 14=交）" "Lap boolean opcode (8=union 14=intersect)" {8 14}}
        {extend_offset_type "延伸偏置模式（基线=2）" "Extend offset type (baseline=2)" {-13 -11 -3 -1 0 1 2 3 10 11 12 13}}
        {extend_connect_trim_mode "延伸结果修剪（0/1）" "Trim extended result (0/1)" {0 1}}
        {diagnostic_preserve_failed_geometry "失败保留几何（0/1）" "Preserve failed geometry (0/1)" {0 1}}
        {t_surface_trim_mode "T曲面修剪模式（0/1）" "T surface trim mode (0/1)" {0 1}}
        {topology_connection_required "强制拓扑连接（0=降级警告）" "Require topology connection (0=downgrade)" {0 1}}
        {private_history_api "启用私有历史接口（0/1）" "Private history API (0/1)" {0 1}}
        {internal_mark_slot "内部 Mark 槽（0=自动，3=双版本）" "Internal mark slot (0=auto, 3=dual-version)" {0 3}}
    }
    set optionIndex 0
    foreach field $optionFields {
        set key [lindex $field 0]
        set row [expr {$optionRow + $optionIndex/2}]
        set pair [expr {$optionIndex%2}]
        label $window.body.params.l_$key -text [::HWFlow::txt [lindex $field 1] [lindex $field 2]] -anchor w
        eval [linsert [lindex $field 3] 0 \
            tk_optionMenu $window.body.params.m_$key ::hmtoolkit::seam::config($key)]
        grid $window.body.params.l_$key -row $row -column [expr {$pair*2}] -sticky w -padx {3 6} -pady 2
        grid $window.body.params.m_$key -row $row -column [expr {$pair*2+1}] -sticky ew -padx {0 12} -pady 2
        incr optionIndex
    }

    label $window.body.status -textvariable ::hmtoolkit::seam::runtime(status) -anchor w -justify left -wraplength 760
    pack $window.body.status -fill x -pady 4
    frame $window.buttons
    pack $window.buttons -fill x
    button $window.buttons.diagnose -text [::HWFlow::txt "诊断" "Diagnose"] \
        -command ::hmtoolkit::seam::ui::run_diagnose
    button $window.buttons.save -text [::HWFlow::txt "保存配置" "Save Settings"] -command ::hmtoolkit::seam::ui::save_settings
    button $window.buttons.close -text [::HWFlow::txt "关闭" "Close"] -command ::hmtoolkit::seam::ui::close
    pack $window.buttons.close $window.buttons.save $window.buttons.diagnose -side right -padx 4
    wm protocol $window WM_DELETE_WINDOW ::hmtoolkit::seam::ui::close
    bind $window <Escape> ::hmtoolkit::seam::ui::handle_escape
    ::hmtoolkit::seam::ui::center $window
    return $window
}

proc ::hmtoolkit::seam::ui::save_settings {} {
    variable ::hmtoolkit::seam::config
    foreach key {endpoint_merge_tolerance stitch_tolerance cleanup_tolerance \
            projected_path_merge_tolerance projected_path_ambiguity_tolerance \
            area_tolerance volume_tolerance min_seam_length point_spacing \
            geometry_offset_distance extend_offset_distance connect_extend_distance connect_min_angle_to_target \
            connect_max_angle_edge_to_surf connect_guide_angle lap_connect_distance \
            lap_result_envelope_tolerance} {
        if {![string is double -strict $config($key)] || $config($key) <= 0.0} {
            ::hmtoolkit::seam::ui::set_status "$key must be a positive number."
            return 0
        }
    }
    if {![string is double -strict $config(thickness_override)] || $config(thickness_override) < 0.0} {
        ::hmtoolkit::seam::ui::set_status "thickness_override must be zero or a positive number."
        return 0
    }
    if {![string is double -strict $config(extend_connect_distance)] || $config(extend_connect_distance) < 0.0} {
        ::hmtoolkit::seam::ui::set_status "extend_connect_distance must be zero or a positive number."
        return 0
    }
    if {![string is double -strict $config(replace_point_projection_distance)] ||
        !($config(replace_point_projection_distance) == -1.0 || $config(replace_point_projection_distance) > 0.0)} {
        ::hmtoolkit::seam::ui::set_status "replace_point_projection_distance must be -1 or a positive number."
        return 0
    }
    if {$config(extend_offset_type) ni {-13 -11 -3 -1 0 1 2 3 10 11 12 13}} {
        ::hmtoolkit::seam::ui::set_status "extend_offset_type is not a documented HyperMesh offset mode."
        return 0
    }
    if {$config(lap_boolean_opcode) ni {8 14}} {
        ::hmtoolkit::seam::ui::set_status "lap_boolean_opcode must be 8 (union) or 14 (intersection)."
        return 0
    }
    if {$config(diagnostic_preserve_failed_geometry) ni {0 1}} {
        ::hmtoolkit::seam::ui::set_status "diagnostic_preserve_failed_geometry must be 0 or 1."
        return 0
    }
    foreach key {t_surface_trim_mode extend_connect_trim_mode topology_connection_required private_history_api} {
        if {$config($key) ni {0 1}} {
            ::hmtoolkit::seam::ui::set_status "$key must be 0 or 1."
            return 0
        }
    }
    if {$config(internal_mark_slot) ni {0 3}} {
        ::hmtoolkit::seam::ui::set_status "internal_mark_slot must be 0 (auto) or 3 on the local HM2019/HW2022 builds."
        return 0
    }
    ::hmtoolkit::seam::config::save
    ::hmtoolkit::seam::ui::set_status [::HWFlow::txt "参数已保存。" "Settings saved."]
    return 1
}

proc ::hmtoolkit::seam::ui::run_diagnose {} {
    return [::hmtoolkit::seam::diagnose::run_and_show]
}

proc ::hmtoolkit::seam::ui::restore_view {} {
    variable review_state
    if {$review_state ne ""} { ::hmtoolkit::seam::state::restore $review_state; catch {hm_redraw} }
}

proc ::hmtoolkit::seam::ui::run_precise {strategy} {
    variable ::hmtoolkit::seam::runtime
    if {$strategy in {T_PATH T_LIST L_SURF L_LIST CONNECT PROJECT}} {
        return [::hmtoolkit::seam::ui::run_continuous $strategy]
    }
    ::hmtoolkit::seam::ui::dismiss_window
    set result [::hmtoolkit::seam::interactive::run $strategy]
    # The panel was dismissed for the native selection panels; reopen it so
    # the operation result (success, warnings or failure) is actually visible
    # to the user instead of being written to a destroyed window.
    ::hmtoolkit::seam::ui::show 0
    ::hmtoolkit::seam::ui::show_result $result
    return $result
}

proc ::hmtoolkit::seam::ui::show_result {result} {
    if {[dict exists $result message]} {
        set message [dict get $result message]
        if {[dict exists $result warnings] && [llength [dict get $result warnings]] > 0} {
            append message "  [::HWFlow::txt "警告：" "Warnings: "][join [dict get $result warnings] {; }]"
        }
        ::hmtoolkit::seam::ui::set_status $message
        if {[dict exists $result success] && ![dict get $result success] &&
            (![dict exists $result cancelled] || ![dict get $result cancelled])} {
            catch {hm_errormessage $message}
        }
    }
    return $result
}

proc ::hmtoolkit::seam::ui::run_continuous {strategy} {
    variable ::hmtoolkit::seam::runtime
    if {$runtime(active_strategy) ne ""} {
        return [dict create success 0 cancelled 0 message [::HWFlow::txt \
            "已有连续创建任务正在运行。" "A continuous creation task is already active."]]
    }

    set runtime(active_strategy) $strategy
    set completed 0
    set result [dict create success 0 cancelled 1 message "Operation cancelled."]
    ::hmtoolkit::seam::ui::set_status [::HWFlow::txt \
        "已进入连续创建模式；完成一次后可继续选择，按 Esc 退出。" \
        "Continuous creation is active; select again after each result, or press Esc to exit."]
    ::hmtoolkit::seam::ui::dismiss_window

    set code [catch {
        while {$runtime(active_strategy) eq $strategy} {
            set result [::hmtoolkit::seam::interactive::run $strategy]
            if {[dict exists $result cancelled] && [dict get $result cancelled]} {
                break
            }
            if {[dict exists $result success] && [dict get $result success]} {
                incr completed
            }
            ::hmtoolkit::seam::ui::show_result $result
            if {[dict exists $result message]} {
                ::hmtoolkit::seam::ui::set_status "[dict get $result message]  [::HWFlow::txt {继续选择，按 Esc 退出。} {Select again, or press Esc to exit.}]"
            }
            catch {update idletasks}
        }
    } value options]
    set runtime(active_strategy) ""
    if {$code} {
        return -options $options $value
    }

    # Continuous mode ends here (Esc or a cancelled selection); reopen the
    # panel with the final summary so the user gets visible feedback.
    ::hmtoolkit::seam::ui::show 0
    ::hmtoolkit::seam::ui::set_status [::HWFlow::txt \
        "已退出连续创建模式，本次完成 $completed 次。" \
        "Continuous creation ended after $completed completed operation(s)."]
    return $result
}

proc ::hmtoolkit::seam::ui::handle_escape {} {
    variable ::hmtoolkit::seam::runtime
    if {$runtime(active_strategy) ne ""} {
        set runtime(active_strategy) ""
        ::hmtoolkit::seam::ui::set_status [::HWFlow::txt \
            "正在退出连续创建模式。" "Exiting continuous creation mode."]
        return
    }
    ::hmtoolkit::seam::ui::close
}

proc ::hmtoolkit::seam::ui::run_shortcut {} {
    return [::hmtoolkit::seam::open_panel]
}

proc ::hmtoolkit::seam::ui::dismiss_window {} {
    variable window
    ::hmtoolkit::seam::ui::restore_view
    catch {destroy $window}
}

proc ::hmtoolkit::seam::ui::close {} {
    variable ::hmtoolkit::seam::runtime
    set runtime(active_strategy) ""
    ::hmtoolkit::seam::ui::dismiss_window
}
