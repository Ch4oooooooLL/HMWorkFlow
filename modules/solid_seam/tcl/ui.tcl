proc ::SolidSeam::stateKeys {} {
    return {input_type weld_type side_mode tolerance default_width default_spacing}
}
proc ::SolidSeam::loadState {} { ::HWFlow::applyStateToArray solid_seam ::SolidSeam::ui [::SolidSeam::stateKeys] }
proc ::SolidSeam::saveState {} { ::HWFlow::saveArrayState solid_seam ::SolidSeam::ui {status} }

proc ::SolidSeam::validateSettings {} {
    variable ui
    set numericKeys {tolerance default_width default_spacing}
    if {$ui(input_type) in {AUTO AUTO_GROUP}} { set numericKeys {} }
    foreach key $numericKeys {
        set value $ui($key)
        if {![string is double -strict $value] || [catch {expr {$value > 0 && $value < Inf}} valid] || !$valid} {
            error [::SolidSeam::txt "$key 必须为有限的正数。" "$key must be a finite positive number."]
        }
    }
    foreach {key allowed} {input_type {NODES_COMPS COMPS_COMPS AUTO AUTO_GROUP} weld_type {T B L} side_mode {POSITIVE NEGATIVE BOTH}} {
        if {$ui($key) ni $allowed} { error "Invalid $key: $ui($key)" }
    }
}

proc ::SolidSeam::showPanel {} {
    variable ui; variable running
    if {[info exists running] && $running} { return }
    set w .solid_seam
    if {[winfo exists $w]} { raise $w; return }
    ::SolidSeam::loadState
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle [::SolidSeam::txt "实体焊缝" "Solid Seam"] "Solid Seam"]
    wm minsize $w 700 470
    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    labelframe $w.main.input -text [::SolidSeam::txt "输入类型" "Input type"] -padx 8 -pady 6
    pack $w.main.input -fill x -pady {0 8}
    foreach {value label} {NODES_COMPS nodes+comps COMPS_COMPS comps+comps AUTO Auto AUTO_GROUP AutoGroup} {
        radiobutton $w.main.input.r_$value -text $label -value $value -variable ::SolidSeam::ui(input_type) -command ::SolidSeam::refreshInputMode
        pack $w.main.input.r_$value -side left -padx 8
    }
    label $w.main.inputHelp -text [::SolidSeam::txt \
        "nodes+comps：默认 node path，可选一个点寻找闭环，或选择一系列节点；再选目标组件。\ncomps+comps / Auto：依次选源组件和目标组件。Auto 自动确定类型、spacing、tolerance、width。" \
        "nodes+comps: native node path accepts one loop seed or a series of nodes, then a target component.\ncomps+comps / Auto: select source then target. Auto derives type, spacing, tolerance and width."] -anchor w -justify left -wraplength 660
    pack $w.main.inputHelp -fill x -pady {0 8}
    labelframe $w.main.type -text [::SolidSeam::txt "实体焊缝类型" "Solid weld type"] -padx 8 -pady 6
    pack $w.main.type -fill x -pady {0 8}
    foreach {value zh en} {
        T "T — T 形接头：一块板的边缘连接另一块板的表面。" "T — T joint: an edge meets another plate's face."
        B "B — 对接接头：两块板的边缘相对连接。" "B — Butt joint: two plate edges meet."
        L "L — 搭接接头：两块板搭接，沿搭接边缘连接。" "L — Lap joint: overlapping plates join along an edge."
    } {
        radiobutton $w.main.type.r_$value -text [::SolidSeam::txt $zh $en] -value $value -variable ::SolidSeam::ui(weld_type) -anchor w
        pack $w.main.type.r_$value -fill x
    }
    labelframe $w.main.parameters -text [::SolidSeam::txt "创建参数（模型长度单位）" "Parameters (model length units)"] -padx 8 -pady 8
    pack $w.main.parameters -fill x -pady {0 8}
    set column 0
    foreach {key label} {default_spacing spacing tolerance tolerance default_width width} {
        label $w.main.parameters.l_$key -text $label
        entry $w.main.parameters.e_$key -textvariable ::SolidSeam::ui($key) -width 10
        grid $w.main.parameters.l_$key -row 0 -column $column -padx {0 6}
        incr column
        grid $w.main.parameters.e_$key -row 0 -column $column -padx {0 16}
        incr column
    }
    label $w.main.parameters.help -text [::SolidSeam::txt \
        "spacing：沿焊缝间距；tolerance：搜索/实现容差；width：焊缝宽度。数值直接用于创建。" \
        "spacing: along-seam pitch; tolerance: search/realization distance; width: weld width. Values are used as entered."] -wraplength 640 -justify left -anchor w
    grid $w.main.parameters.help -row 1 -column 0 -columnspan 6 -sticky w -pady {6 0}
    labelframe $w.main.side -text [::SolidSeam::txt "创建侧" "Weld side"] -padx 8 -pady 6
    pack $w.main.side -fill x
    foreach {value label} {POSITIVE {positive side} NEGATIVE {negative side} BOTH {both sides}} {
        radiobutton $w.main.side.r_$value -text $label -value $value -variable ::SolidSeam::ui(side_mode)
        pack $w.main.side.r_$value -side left -padx 8
    }
    label $w.main.sideHelp -text [::SolidSeam::txt \
        "遵循原生 Seam 方向：T 正侧通常为钝角侧；L 负侧为两板较平行侧；B 正侧沿第一连接板法向。接近直角时由自由边单元法向决定；both sides 在两侧创建。" \
        "Native Seam: T positive usually faces the obtuse angle; L negative faces near-parallel links; B positive follows the first link normal. Near 90 degrees, free-edge normals decide. Both sides creates on each side."] -anchor w -justify left -wraplength 660
    pack $w.main.sideHelp -fill x -pady 6
    label $w.main.continuousHelp -text [::SolidSeam::txt \
        "AutoGroup：一次多选组件后直接自动配对并执行。其他模式：两两一组缓存，第一步空选提交，第二步空选取消当前组。结束后恢复面板。" \
        "AutoGroup: select all components once to match and execute. Other modes: cache pairs; empty first selection submits, empty target cancels the pair. The panel returns afterwards."] -anchor w -justify left -wraplength 660
    pack $w.main.continuousHelp -fill x -pady 6
    label $w.main.status -textvariable ::SolidSeam::ui(status) -anchor nw -justify left -wraplength 660
    pack $w.main.status -fill both -expand 1 -pady 6
    frame $w.buttons -padx 12 -pady 8
    pack $w.buttons -fill x
    button $w.buttons.run -text [::SolidSeam::txt "开始" "Start"] -command ::SolidSeam::runDetection
    button $w.buttons.home -text [::SolidSeam::txt "返回主页" "Back to Home"] -command {::SolidSeam::closePanel; ::HWToolkit::showHome}
    button $w.buttons.close -text [::SolidSeam::txt "关闭" "Close"] -command ::SolidSeam::closePanel
    pack $w.buttons.run -side left
    pack $w.buttons.close $w.buttons.home -side right -padx {6 0}
    wm protocol $w WM_DELETE_WINDOW ::SolidSeam::closePanel
    ::SolidSeam::refreshInputMode
}

proc ::SolidSeam::refreshInputMode {} {
    variable ui
    set state [expr {$ui(input_type) in {AUTO AUTO_GROUP} ? "disabled" : "normal"}]
    foreach type {T B L} { catch {.solid_seam.main.type.r_$type configure -state $state} }
    foreach key {default_spacing tolerance default_width} { catch {.solid_seam.main.parameters.e_$key configure -state $state} }
    if {$ui(input_type) eq "AUTO_GROUP"} {
        set ui(status) [::SolidSeam::txt "AutoGroup：一次选取全部组件，自动配对后创建；显示进度命令流。类型、尺寸和侧向沿用 Auto，both sides 始终保留。" "AutoGroup: select all components once, automatically match and create with a progress command stream. Uses Auto type, dimensions and side; both sides is respected."]
    } elseif {$ui(input_type) eq "AUTO"} {
        set ui(status) [::SolidSeam::txt "Auto：推导类型、尺寸和创建侧；侧向不明确时采用上方选择，both sides 始终保留。" "Auto derives type, dimensions and weld side; ambiguous sides use the selection above. Both sides is always respected."]
    } else {
        set ui(status) [::SolidSeam::txt "设置参数后点击开始，逐组缓存，第一步空选后统一创建。" "Set parameters, cache pairs, then submit with an empty first selection."]
    }
}

proc ::SolidSeam::closePanel {} {
    if {![catch {::SolidSeam::validateSettings}]} { ::SolidSeam::saveState }
    destroy .solid_seam
}
proc ::SolidSeam::runSettings {} { ::SolidSeam::showPanel }
