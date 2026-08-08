proc ::WeldIntegrityCheck::pickComponents {target} {
    variable ui
    catch {*clearmark comps 1}
    ::HWFlow::nativeMarkPanel comps 1 [expr {$target eq "selected" ? [::WeldIntegrityCheck::txt "选择待检查 Components" "Select components to inspect"] : [::WeldIntegrityCheck::txt "选择排除 Components" "Select components to exclude"]}]
    set ids {}; catch {set ids [hm_getmark comps 1]}; set ids [lsort -integer -unique $ids]
    if {$target eq "selected"} {
        set ui(selectedCompIds) $ids
        set ui(selectedText) [::WeldIntegrityCheck::txt "已选择：[llength $ids] 个 Components" "Selected: [llength $ids] component(s)"]
    } else {
        set ui(excludedCompIds) $ids
        set ui(excludedText) [::WeldIntegrityCheck::txt "已排除：[llength $ids] 个 Components" "Excluded: [llength $ids] component(s)"]
    }
    catch {raise .weld_integrity_config}; catch {focus .weld_integrity_config}
}

proc ::WeldIntegrityCheck::useVisibleComponents {} {
    variable ui
    set ids [::WeldIntegrityCheck::displayedComponents]
    set ui(selectedCompIds) $ids
    set ui(selectedText) [::WeldIntegrityCheck::txt "已选择：[llength $ids] 个当前可见 Components" "Selected: [llength $ids] currently visible component(s)"]
}

proc ::WeldIntegrityCheck::clearScope {target} {
    variable ui
    if {$target eq "selected"} { set ui(selectedCompIds) {}; set ui(selectedText) [::WeldIntegrityCheck::txt "未选择组件" "No components selected"] } else { set ui(excludedCompIds) {}; set ui(excludedText) [::WeldIntegrityCheck::txt "未排除组件" "No excluded components"] }
}

proc ::WeldIntegrityCheck::validateConfig {settingsOnly} {
    variable ui; variable cfg
    foreach key {max_search_distance min_contact_length} {
        if {![string is double -strict $ui($key)] || $ui($key) <= 0} {
            tk_messageBox -icon warning -title [::WeldIntegrityCheck::txt "参数错误" "Invalid Setting"] -message [::WeldIntegrityCheck::txt "$key 必须为正数。" "$key must be a positive number."]
            return 0
        }
    }
    if {![string is integer -strict $ui(min_continuous_nodes)] || $ui(min_continuous_nodes) < 2} {
        tk_messageBox -icon warning -title [::WeldIntegrityCheck::txt "参数错误" "Invalid Setting"] -message [::WeldIntegrityCheck::txt "最小连续节点数必须为不小于 2 的整数。" "Minimum continuous nodes must be an integer of at least 2."]
        return 0
    }
    if {!$settingsOnly && [llength $ui(selectedCompIds)] < 2} {
        tk_messageBox -icon warning -title [::WeldIntegrityCheck::txt "选择不足" "Insufficient Selection"] -message [::WeldIntegrityCheck::txt "至少需要选择两个 Component 才能执行检查。" "Select at least two components before running the check."]
        return 0
    }
    foreach key {max_search_distance min_contact_length min_continuous_nodes prefer_free_edges ignore_shared_nodes auto_isolate_next} { set cfg($key) $ui($key) }
    ::WeldIntegrityCheck::saveConfig
    set ui(accepted) 1
    destroy .weld_integrity_config
    return 1
}

proc ::WeldIntegrityCheck::showConfig {{settingsOnly 0}} {
    variable cfg; variable ui
    catch {destroy .weld_integrity_config}
    foreach key [array names cfg] { set ui($key) $cfg($key) }
    set ui(accepted) 0; set ui(selectedCompIds) {}; set ui(excludedCompIds) {}
    set ui(selectedText) [::WeldIntegrityCheck::txt "未选择组件" "No components selected"]
    set ui(excludedText) [::WeldIntegrityCheck::txt "未排除组件" "No excluded components"]
    set w .weld_integrity_config
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle [::WeldIntegrityCheck::txt "网格焊缝完整性检查" "Mesh Weld Integrity Check"] "Mesh Weld Integrity Check"]
    wm resizable $w 0 0
    frame $w.main -padx 12 -pady 10; pack $w.main -fill both -expand 1
    label $w.main.title -text [::WeldIntegrityCheck::txt "网格焊缝完整性检查" "Mesh Weld Integrity Check"] -font [::HWFlow::uiFont heading] -anchor w
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    labelframe $w.main.scope -text [::WeldIntegrityCheck::txt "1. 检查范围" "1. Inspection Scope"] -padx 8 -pady 8
    grid $w.main.scope -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    button $w.main.scope.pick -text [::WeldIntegrityCheck::txt "选择待检查组件" "Select Components"] -command {::WeldIntegrityCheck::pickComponents selected} -width 20
    button $w.main.scope.visible -text [::WeldIntegrityCheck::txt "使用当前可见组件" "Use Visible Components"] -command ::WeldIntegrityCheck::useVisibleComponents -width 20
    button $w.main.scope.clear -text [::WeldIntegrityCheck::txt "清空检查范围" "Clear Scope"] -command {::WeldIntegrityCheck::clearScope selected} -width 16
    label $w.main.scope.info -textvariable ::WeldIntegrityCheck::ui(selectedText) -anchor w
    button $w.main.scope.exclude -text [::WeldIntegrityCheck::txt "选择排除组件" "Select Exclusions"] -command {::WeldIntegrityCheck::pickComponents excluded} -width 20
    button $w.main.scope.clearExclude -text [::WeldIntegrityCheck::txt "清空排除范围" "Clear Exclusions"] -command {::WeldIntegrityCheck::clearScope excluded} -width 16
    label $w.main.scope.excludeInfo -textvariable ::WeldIntegrityCheck::ui(excludedText) -anchor w
    grid $w.main.scope.pick -row 0 -column 0 -padx {0 6} -pady 2; grid $w.main.scope.visible -row 0 -column 1 -padx {0 6}; grid $w.main.scope.clear -row 0 -column 2
    grid $w.main.scope.info -row 1 -column 0 -columnspan 3 -sticky w -pady {2 7}
    grid $w.main.scope.exclude -row 2 -column 0 -padx {0 6} -pady 2; grid $w.main.scope.clearExclude -row 2 -column 1
    grid $w.main.scope.excludeInfo -row 3 -column 0 -columnspan 3 -sticky w -pady {2 0}
    if {$settingsOnly} { foreach child [winfo children $w.main.scope] { catch {$child configure -state disabled} } }
    labelframe $w.main.type -text [::WeldIntegrityCheck::txt "2. 检测类型" "2. Detection Type"] -padx 8 -pady 8
    grid $w.main.type -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    checkbutton $w.main.type.ss -text "Shell - Shell" -variable ::WeldIntegrityCheck::ui(shell_shell)
    checkbutton $w.main.type.sh -text [::WeldIntegrityCheck::txt "Shell - Solid（后续版本）" "Shell - Solid (future)"] -variable ::WeldIntegrityCheck::ui(shell_solid) -state disabled
    checkbutton $w.main.type.hh -text [::WeldIntegrityCheck::txt "Solid - Solid（后续版本）" "Solid - Solid (future)"] -variable ::WeldIntegrityCheck::ui(solid_solid) -state disabled
    pack $w.main.type.ss $w.main.type.sh $w.main.type.hh -side left -padx {0 16}
    labelframe $w.main.params -text [::WeldIntegrityCheck::txt "3. 检测参数（单位跟随当前模型）" "3. Detection Settings (model units)"] -padx 8 -pady 8
    grid $w.main.params -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    foreach item {
        {max_search_distance "最大搜索距离" "Maximum search distance"}
        {min_contact_length "最小有效接近长度" "Minimum contact length"}
        {min_continuous_nodes "最小连续节点数" "Minimum continuous nodes"}
    } row {0 1 2} {
        set key [lindex $item 0]
        label $w.main.params.l_$key -text [::WeldIntegrityCheck::txt [lindex $item 1] [lindex $item 2]] -anchor w
        entry $w.main.params.e_$key -textvariable ::WeldIntegrityCheck::ui($key) -width 16
        grid $w.main.params.l_$key -row $row -column 0 -sticky w -padx {0 8} -pady 2
        grid $w.main.params.e_$key -row $row -column 1 -sticky w -pady 2
    }
    checkbutton $w.main.params.free -text [::WeldIntegrityCheck::txt "优先检测 Shell 自由边" "Prefer shell free edges"] -variable ::WeldIntegrityCheck::ui(prefer_free_edges)
    checkbutton $w.main.params.shared -text [::WeldIntegrityCheck::txt "忽略已直接共节点连接的组件对" "Ignore directly shared-node pairs"] -variable ::WeldIntegrityCheck::ui(ignore_shared_nodes)
    checkbutton $w.main.params.auto -text [::WeldIntegrityCheck::txt "完成后自动孤立下一组" "Auto-isolate next pair after completion"] -variable ::WeldIntegrityCheck::ui(auto_isolate_next)
    grid $w.main.params.free -row 0 -column 2 -sticky w -padx {20 0}; grid $w.main.params.shared -row 1 -column 2 -sticky w -padx {20 0}; grid $w.main.params.auto -row 2 -column 2 -sticky w -padx {20 0}
    frame $w.buttons -padx 12 -pady 10; pack $w.buttons -fill x
    button $w.buttons.cancel -text [::WeldIntegrityCheck::txt "取消" "Cancel"] -width 12 -command {set ::WeldIntegrityCheck::ui(accepted) 0; destroy .weld_integrity_config}
    button $w.buttons.start -text [expr {$settingsOnly ? [::WeldIntegrityCheck::txt "保存设置" "Save Settings"] : [::WeldIntegrityCheck::txt "开始检测" "Start Detection"]}] -width 16 -command [list ::WeldIntegrityCheck::validateConfig $settingsOnly]
    pack $w.buttons.cancel $w.buttons.start -side right -padx {6 0}
    if {!$settingsOnly && [llength $::WeldIntegrityCheck::pairRows] > 0} {
        button $w.buttons.resume -text [::WeldIntegrityCheck::txt "继续上次审查" "Resume Last Review"] -width 16 -command {set ::WeldIntegrityCheck::ui(accepted) 2; destroy .weld_integrity_config}
        pack $w.buttons.resume -side left
    }
    bind $w <Escape> {set ::WeldIntegrityCheck::ui(accepted) 0; destroy .weld_integrity_config}
    wm protocol $w WM_DELETE_WINDOW {set ::WeldIntegrityCheck::ui(accepted) 0; destroy .weld_integrity_config}
    ::HWFlow::centerWindow $w
    tkwait window $w
    return $ui(accepted)
}
