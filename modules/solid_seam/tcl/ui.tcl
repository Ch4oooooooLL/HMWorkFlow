proc ::SolidSeam::stateKeys {} {
    return {search_distance max_search_distance min_weld_length gap_jump_limit default_width default_spacing}
}
proc ::SolidSeam::loadState {} { ::HWFlow::applyStateToArray solid_seam ::SolidSeam::ui [::SolidSeam::stateKeys] }
proc ::SolidSeam::saveState {} { ::HWFlow::saveArrayState solid_seam ::SolidSeam::ui {status} }

proc ::SolidSeam::validateSettings {} {
    variable ui
    foreach key {search_distance max_search_distance min_weld_length gap_jump_limit default_width default_spacing} {
        if {![string is double -strict $ui($key)]} { error "$key must be numeric" }
    }
    if {$ui(search_distance) <= 0 || $ui(max_search_distance) < $ui(search_distance)} { error "max_search_distance must be >= search_distance > 0" }
    if {$ui(default_width) <= 0} { error "default_width must be > 0" }
    if {$ui(default_spacing) <= 0} { error "default_spacing must be > 0" }
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
    label $w.main.note -text [::SolidSeam::txt "选择两个 Components 后自动识别交界焊缝，按默认宽度/间距（6）创建 PENTA+RBE3 实体焊缝，输出到 SEAM_SOLID 组件。" "Select two components; the module auto-detects the junction seam and creates PENTA+RBE3 solid welds (default width/spacing 6) into the SEAM_SOLID component."] -anchor w -justify left
    pack $w.main.title $w.main.note -fill x -pady {0 6}
    labelframe $w.main.parameters -text [::SolidSeam::txt "识别与创建参数" "Detection & Creation Settings"] -padx 8 -pady 8; pack $w.main.parameters -fill x
    set fields {
        {search_distance "搜索距离" "Search distance"} {max_search_distance "最大搜索距离" "Max distance"}
        {min_weld_length "最小焊缝长度" "Min weld length"} {gap_jump_limit "链断点容差" "Chain gap limit"}
        {default_width "焊缝宽度(默认6)" "Weld width (default 6)"} {default_spacing "节点间距(默认6)" "Point spacing (default 6)"}
    }
    set i 0
    foreach item $fields {
        set key [lindex $item 0]; set row [expr {$i / 2}]; set column [expr {($i % 2) * 2}]
        label $w.main.parameters.l_$key -text [::SolidSeam::txt [lindex $item 1] [lindex $item 2]]
        entry $w.main.parameters.e_$key -textvariable ::SolidSeam::ui($key) -width 10
        grid $w.main.parameters.l_$key -row $row -column $column -sticky w -padx {0 5} -pady 3
        grid $w.main.parameters.e_$key -row $row -column [expr {$column + 1}] -sticky w -padx {0 18}; incr i
    }
    label $w.main.parameters.hint -text [::SolidSeam::txt "宽度/间距若与网格不匹配会自动按网格尺寸调整；容差自动覆盖焊缝间隙。" "Width/spacing auto-adjust to the local mesh; tolerance auto-covers the joint gap."] -anchor w -justify left -fg #666666
    grid $w.main.parameters.hint -row 3 -column 0 -columnspan 4 -sticky w -pady {6 0}
    label $w.main.status -textvariable ::SolidSeam::ui(status) -anchor nw -justify left -wraplength 680; pack $w.main.status -fill both -expand 1 -pady 10
    frame $w.buttons -padx 12 -pady 8; pack $w.buttons -fill x
    button $w.buttons.run -text [::SolidSeam::txt "选择组件并创建" "Select and Create"] -command ::SolidSeam::runDetection
    button $w.buttons.home -text [::SolidSeam::txt "返回主页" "Back to Home"] -command {destroy .solid_seam; ::HWToolkit::showHome}
    button $w.buttons.close -text [::SolidSeam::txt "关闭" "Close"] -command [list destroy $w]
    pack $w.buttons.run -side left -padx {0 6}; pack $w.buttons.close $w.buttons.home -side right -padx {6 0}
    wm protocol $w WM_DELETE_WINDOW [list destroy $w]
}

proc ::SolidSeam::runSettings {} { ::SolidSeam::showPanel }
