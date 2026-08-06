proc ::SolidSeam::stateKeys {} {
    return {search_distance max_search_distance min_weld_length min_valid_ratio feature_angle_deg max_chain_turn_angle_deg gap_jump_limit allow_closed_loop detect_duplicates default_realization auto_accept_high}
}
proc ::SolidSeam::loadState {} { ::HWFlow::applyStateToArray solid_seam ::SolidSeam::ui [::SolidSeam::stateKeys] }
proc ::SolidSeam::saveState {} { ::HWFlow::saveArrayState solid_seam ::SolidSeam::ui {status} }

proc ::SolidSeam::validateSettings {} {
    variable ui
    foreach key {search_distance max_search_distance min_weld_length min_valid_ratio feature_angle_deg max_chain_turn_angle_deg gap_jump_limit high_confidence_threshold review_confidence_threshold} {
        if {![string is double -strict $ui($key)]} { error "$key must be numeric" }
    }
    if {$ui(search_distance) <= 0 || $ui(max_search_distance) < $ui(search_distance)} { error "max_search_distance must be >= search_distance > 0" }
    if {$ui(min_valid_ratio) < 0 || $ui(min_valid_ratio) > 1} { error "min_valid_ratio must be between 0 and 1" }
}

proc ::SolidSeam::showPanel {} {
    variable ui
    ::SolidSeam::loadState
    set w .solid_seam
    if {[winfo exists $w]} { raise $w; return }
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle [::SolidSeam::txt "实体焊缝自动识别与创建" "Solid Seam Recognition and Creation"] "Solid Seam Recognition and Creation"]
    wm minsize $w 720 430
    frame $w.main -padx 12 -pady 10; pack $w.main -fill both -expand 1
    label $w.main.title -text [::SolidSeam::txt "实体焊缝 / Solid Seam" "Solid Seam"] -font [::HWFlow::uiFont heading] -anchor w
    label $w.main.note -text [::SolidSeam::txt "首次选一个 Component 时会继续选择连接件；首次选多个时直接分析。两实体/两壳体直接创建，混合类型进入预览。" "Selecting one component opens a second selector; selecting multiple components starts analysis. Solid/solid and shell/shell pairs create directly; mixed selections open preview."] -anchor w -justify left
    pack $w.main.title $w.main.note -fill x -pady {0 6}
    labelframe $w.main.parameters -text [::SolidSeam::txt "识别参数" "Detection Settings"] -padx 8 -pady 8; pack $w.main.parameters -fill x
    set fields {
        {search_distance "搜索距离" "Search distance"} {max_search_distance "最大搜索距离" "Max distance"}
        {min_weld_length "最小焊缝长度" "Min weld length"} {feature_angle_deg "特征边角度" "Feature angle"}
        {min_valid_ratio "最小有效比例" "Min valid ratio"} {max_chain_turn_angle_deg "最大链转角" "Max chain turn"}
    }
    set i 0
    foreach item $fields {
        set key [lindex $item 0]; set row [expr {$i / 2}]; set column [expr {($i % 2) * 2}]
        label $w.main.parameters.l_$key -text [::SolidSeam::txt [lindex $item 1] [lindex $item 2]]
        entry $w.main.parameters.e_$key -textvariable ::SolidSeam::ui($key) -width 10
        grid $w.main.parameters.l_$key -row $row -column $column -sticky w -padx {0 5} -pady 3
        grid $w.main.parameters.e_$key -row $row -column [expr {$column + 1}] -sticky w -padx {0 18}; incr i
    }
    checkbutton $w.main.parameters.closed -text [::SolidSeam::txt "识别闭合焊缝" "Detect closed loops"] -variable ::SolidSeam::ui(allow_closed_loop)
    checkbutton $w.main.parameters.duplicates -text [::SolidSeam::txt "检测重复焊缝" "Detect duplicates"] -variable ::SolidSeam::ui(detect_duplicates)
    checkbutton $w.main.parameters.high -text [::SolidSeam::txt "自动接受无警告高置信度项" "Auto-accept clean high-confidence items"] -variable ::SolidSeam::ui(auto_accept_high)
    grid $w.main.parameters.closed -row 3 -column 0 -columnspan 2 -sticky w; grid $w.main.parameters.duplicates -row 3 -column 2 -columnspan 2 -sticky w
    grid $w.main.parameters.high -row 4 -column 0 -columnspan 4 -sticky w
    label $w.main.status -textvariable ::SolidSeam::ui(status) -anchor nw -justify left -wraplength 680; pack $w.main.status -fill both -expand 1 -pady 10
    frame $w.buttons -padx 12 -pady 8; pack $w.buttons -fill x
    button $w.buttons.run -text [::SolidSeam::txt "选择组件并识别" "Select and Detect"] -command ::SolidSeam::runDetection
    button $w.buttons.results -text [::SolidSeam::txt "查看候选" "View Candidates"] -command ::SolidSeam::showCandidateWindow
    button $w.buttons.home -text [::SolidSeam::txt "返回主页" "Back to Home"] -command {destroy .solid_seam; ::HWToolkit::showHome}
    button $w.buttons.close -text [::SolidSeam::txt "关闭" "Close"] -command [list destroy $w]
    pack $w.buttons.run $w.buttons.results -side left -padx {0 6}; pack $w.buttons.close $w.buttons.home -side right -padx {6 0}
    wm protocol $w WM_DELETE_WINDOW [list destroy $w]
}

proc ::SolidSeam::runSettings {} { ::SolidSeam::showPanel }
