proc ::BatchMesher::showError {message} {
    variable ui
    set ui(status_text) $message
    catch {tk_messageBox -icon error -title [::BatchMesher::txt "BatchMesher 自动网格划分" "BatchMesher Automatic Meshing"] -message $message}
}

proc ::BatchMesher::guarded {command} {
    if {[catch {uplevel #0 $command} err opts]} { ::BatchMesher::showError $err; return 0 }
    return 1
}

proc ::BatchMesher::browseFile {key extension label} {
    variable ui
    set initial [pwd]
    if {[info exists ui($key)] && $ui($key) ne ""} { set initial [file dirname $ui($key)] }
    set path [tk_getOpenFile -parent .batch_mesher -title $label -initialdir $initial -filetypes [list [list $label [list $extension]] [list [::BatchMesher::txt "所有文件" "All files"] *]]]
    if {$path ne ""} { set ui($key) [file normalize $path] }
}

proc ::BatchMesher::refreshPresetWidget {} {
    variable ui
    set w .batch_mesher.main.config.preset
    if {[llength [info commands $w]] > 0} { $w configure -values [::BatchMesher::presetNames] }
}

proc ::BatchMesher::onPresetSelected {args} {
    variable ui
    ::BatchMesher::selectPreset $ui(ACTIVE_PRESET)
}

proc ::BatchMesher::selectedGroupId {} {
    set tree .batch_mesher.main.groups.tree
    if {[llength [info commands $tree]] == 0} { return "" }
    set selection [$tree selection]
    if {[llength $selection] == 0} { return "" }
    return [lindex $selection 0]
}

proc ::BatchMesher::selectedTaskId {} {
    set tree .batch_mesher.main.tasks.tree
    if {[llength [info commands $tree]] == 0} { return "" }
    set selection [$tree selection]
    if {[llength $selection] == 0} { return "" }
    return [lindex $selection 0]
}

proc ::BatchMesher::groupById {groupId} {
    variable runtime
    foreach group $runtime(groups) { if {[dict get $group group_id] eq $groupId} { return $group } }
    return ""
}

proc ::BatchMesher::taskById {taskId} {
    variable runtime
    foreach task $runtime(tasks) { if {[dict get $task task_id] eq $taskId} { return $task } }
    return ""
}

proc ::BatchMesher::onGroupSelected {args} {
    variable ui
    set group [::BatchMesher::groupById [::BatchMesher::selectedGroupId]]
    if {$group eq ""} { set ui(group_detail) ""; return }
    set ui(group_detail) "Components: [join [dict get $group component_names] {, }]"
}

proc ::BatchMesher::onTaskSelected {args} {
    variable ui
    set task [::BatchMesher::taskById [::BatchMesher::selectedTaskId]]
    if {$task eq ""} { set ui(task_detail) ""; return }
    set ui(task_detail) "[dict get $task status] | [dict get $task log_path]"
    if {[dict get $task error_message] ne ""} {
        set preview [dict get $task error_message]
        if {[string length $preview] > 600} { set preview "[string range $preview 0 599]..." }
        append ui(task_detail) "\n$preview"
    }
}

proc ::BatchMesher::showSelectedGroup {isolate} {
    set group [::BatchMesher::groupById [::BatchMesher::selectedGroupId]]
    if {$group eq ""} { error [::BatchMesher::txt "请先选择一个连通域。" "Select a connectivity group first."] }
    if {$isolate} { ::BatchMesher::isolateSurfaces [dict get $group surface_ids] \
    } else { ::BatchMesher::reviewSurfaces [dict get $group surface_ids] }
}

proc ::BatchMesher::showSelectedGroupIds {} {
    set group [::BatchMesher::groupById [::BatchMesher::selectedGroupId]]
    if {$group eq ""} { error [::BatchMesher::txt "请先选择一个连通域。" "Select a connectivity group first."] }
    set message "[dict get $group group_id]\nSurface IDs:\n[join [dict get $group surface_ids] {, }]\n\nComponents:\n[join [dict get $group component_names] \n]"
    tk_messageBox -icon info -title [dict get $group group_id] -message $message
}

proc ::BatchMesher::toggleSelectedGroupExcluded {excluded} {
    set id [::BatchMesher::selectedGroupId]
    if {$id eq ""} { error [::BatchMesher::txt "请先选择一个连通域。" "Select a connectivity group first."] }
    ::BatchMesher::setGroupExcluded $id $excluded
}

proc ::BatchMesher::retrySelectedTask {} {
    set id [::BatchMesher::selectedTaskId]
    if {$id eq ""} { error [::BatchMesher::txt "请先选择任务。" "Select a task first."] }
    ::BatchMesher::retryTask $id
}

proc ::BatchMesher::showFailedSurfaces {} {
    set task [::BatchMesher::taskById [::BatchMesher::selectedTaskId]]
    if {$task eq "" || [dict get $task status] ne "failed"} { error [::BatchMesher::txt "请选择失败任务。" "Select a failed task."] }
    ::BatchMesher::reviewSurfaces [dict get $task surface_ids]
}

proc ::BatchMesher::refreshUi {} {
    variable runtime
    variable ui
    set groupTree .batch_mesher.main.groups.tree
    if {[llength [info commands $groupTree]] > 0} {
        foreach item [$groupTree children {}] { $groupTree delete $item }
        foreach group $runtime(groups) {
            set status [expr {[dict get $group excluded] ? [::BatchMesher::txt "已排除" "Excluded"] : [::BatchMesher::txt "待处理" "Pending"]}]
            set warningLabels {}
            foreach warning [dict get $group warnings] {
                switch -- $warning {
                    large_group { lappend warningLabels [::BatchMesher::txt "大型连通域" "Large group"] }
                    isolated_small_group { lappend warningLabels [::BatchMesher::txt "可能的孤立区域" "Possible isolated region"] }
                    cross_component { lappend warningLabels [::BatchMesher::txt "跨 Component" "Cross-component"] }
                    default { lappend warningLabels $warning }
                }
            }
            set warnings [join $warningLabels {, }]
            $groupTree insert {} end -id [dict get $group group_id] -values [list [dict get $group surface_count] [llength [dict get $group component_ids]] $status $warnings]
        }
    }
    set taskTree .batch_mesher.main.tasks.tree
    if {[llength [info commands $taskTree]] > 0} {
        foreach item [$taskTree children {}] { $taskTree delete $item }
        foreach task $runtime(tasks) {
            set elapsed [dict get $task elapsed_seconds]
            if {$elapsed eq ""} { set elapsed "-" } else { append elapsed s }
            $taskTree insert {} end -id [dict get $task task_id] -values [list [dict get $task group_id] [dict get $task surface_count] [dict get $task status] $elapsed]
        }
    }
}

proc ::BatchMesher::validateConfigFromUi {} {
    if {[catch {set config [::BatchMesher::validateRunConfig]} err]} { ::BatchMesher::showError $err; return }
    set message [::BatchMesher::txt "Criteria 和 Param 有效。" "Criteria and param files are valid."]
    append message [::BatchMesher::txt "\nhmbatch 路径有效。" "\nhmbatch path is valid."]
    if {[llength [dict get $config warnings]] > 0} { append message "\n\n[::BatchMesher::txt "提示：文件自保存预设后被外部修改，将使用最新内容。" "Notice: files changed since the preset was saved; latest contents will be used."]\n[join [dict get $config warnings] \n]" }
    tk_messageBox -icon info -title [::BatchMesher::txt "配置验证" "Configuration Validation"] -message $message
}

proc ::BatchMesher::showPanel {} {
    variable ui
    variable VERSION
    ::BatchMesher::loadState
    catch {destroy .batch_mesher}
    set w .batch_mesher
    ::HWFlow::createTopLevel $w
    wm title $w "[::BatchMesher::txt "BatchMesher 自动网格划分" "BatchMesher Automatic Meshing"] v$VERSION"
    wm minsize $w 980 720
    wm resizable $w 1 1
    frame $w.main -padx 10 -pady 8
    pack $w.main -fill both -expand 1
    grid columnconfigure $w.main 0 -weight 1
    grid rowconfigure $w.main 3 -weight 1
    grid rowconfigure $w.main 4 -weight 1

    labelframe $w.main.config -text [::BatchMesher::txt "1. HyperMesh 2019 与网格预设" "1. HyperMesh 2019 and mesh preset"] -padx 6 -pady 6
    grid $w.main.config -row 0 -column 0 -sticky ew -pady {0 6}
    grid columnconfigure $w.main.config 1 -weight 1
    label $w.main.config.vl -text [::BatchMesher::txt "HyperMesh 版本" "HyperMesh version"]
    label $w.main.config.version -text "2019"
    label $w.main.config.hl -text "hmbatch.exe"
    entry $w.main.config.h -textvariable ::BatchMesher::ui(HMBATCH_PATH)
    button $w.main.config.hb -text [::BatchMesher::txt "浏览" "Browse"] -command {::BatchMesher::browseFile HMBATCH_PATH .exe hmbatch.exe}
    button $w.main.config.ht -text [::BatchMesher::txt "测试启动" "Test start"] -command {::BatchMesher::guarded ::BatchMesher::testHmbatchStartup}
    button $w.main.config.ho -text [::BatchMesher::txt "打开目录" "Open folder"] -command {::BatchMesher::guarded {::BatchMesher::openDirectory $::BatchMesher::ui(HMBATCH_PATH)}}
    label $w.main.config.pl -text [::BatchMesher::txt "当前预设" "Current preset"]
    if {[llength [info commands ::ttk::combobox]] == 0} { catch {package require tile} }
    ttk::combobox $w.main.config.preset -textvariable ::BatchMesher::ui(ACTIVE_PRESET) -values [::BatchMesher::presetNames]
    bind $w.main.config.preset <<ComboboxSelected>> ::BatchMesher::onPresetSelected
    label $w.main.config.cl -text "Criteria"
    entry $w.main.config.c -textvariable ::BatchMesher::ui(CRITERIA_PATH)
    button $w.main.config.cb -text [::BatchMesher::txt "浏览" "Browse"] -command {::BatchMesher::browseFile CRITERIA_PATH .criteria Criteria}
    button $w.main.config.co -text [::BatchMesher::txt "打开目录" "Open folder"] -command {::BatchMesher::guarded {::BatchMesher::openDirectory $::BatchMesher::ui(CRITERIA_PATH)}}
    label $w.main.config.ml -text "Parameter"
    entry $w.main.config.m -textvariable ::BatchMesher::ui(PARAM_PATH)
    button $w.main.config.mb -text [::BatchMesher::txt "浏览" "Browse"] -command {::BatchMesher::browseFile PARAM_PATH .param Parameter}
    button $w.main.config.mo -text [::BatchMesher::txt "打开目录" "Open folder"] -command {::BatchMesher::guarded {::BatchMesher::openDirectory $::BatchMesher::ui(PARAM_PATH)}}
    grid $w.main.config.vl -row 0 -column 0 -sticky w; grid $w.main.config.version -row 0 -column 1 -sticky w
    grid $w.main.config.hl -row 1 -column 0 -sticky w; grid $w.main.config.h -row 1 -column 1 -sticky ew; grid $w.main.config.hb -row 1 -column 2; grid $w.main.config.ht -row 1 -column 3; grid $w.main.config.ho -row 1 -column 4
    grid $w.main.config.pl -row 2 -column 0 -sticky w; grid $w.main.config.preset -row 2 -column 1 -sticky ew
    grid $w.main.config.cl -row 3 -column 0 -sticky w; grid $w.main.config.c -row 3 -column 1 -sticky ew; grid $w.main.config.cb -row 3 -column 2; grid $w.main.config.co -row 3 -column 3
    grid $w.main.config.ml -row 4 -column 0 -sticky w; grid $w.main.config.m -row 4 -column 1 -sticky ew; grid $w.main.config.mb -row 4 -column 2; grid $w.main.config.mo -row 4 -column 3
    frame $w.main.config.actions
    grid $w.main.config.actions -row 5 -column 0 -columnspan 4 -sticky ew -pady {5 0}
    foreach spec {
        {new "新增预设" "New preset" ::BatchMesher::newPreset}
        {save "保存预设" "Save preset" ::BatchMesher::saveCurrentPreset}
        {delete "删除预设" "Delete preset" ::BatchMesher::deletePreset}
        {default "设为默认" "Set default" ::BatchMesher::setDefaultPreset}
        {validate "验证" "Validate" ::BatchMesher::validateConfigFromUi}
        {restore "恢复默认" "Restore defaults" ::BatchMesher::restoreDefaults}
    } { lassign $spec name zh en command; button $w.main.config.actions.$name -text [::BatchMesher::txt $zh $en] -command [list ::BatchMesher::guarded $command]; pack $w.main.config.actions.$name -side left -padx {0 4} }

    labelframe $w.main.selection -text [::BatchMesher::txt "2. Surface 选择" "2. Surface selection"] -padx 6 -pady 6
    grid $w.main.selection -row 1 -column 0 -sticky ew -pady {0 6}
    foreach spec {
        {pick "手动选择/重选" "Pick / repick" ::BatchMesher::pickSurfaces}
        {displayed "当前显示" "Displayed" ::BatchMesher::selectDisplayedSurfaces}
        {all "全部" "All" ::BatchMesher::selectAllSurfaces}
        {clear "清除" "Clear" ::BatchMesher::clearSelection}
        {show "显示当前选择" "Show selection" {::BatchMesher::reviewSurfaces $::BatchMesher::runtime(selected_surfaces)}}
    } { lassign $spec name zh en command; button $w.main.selection.$name -text [::BatchMesher::txt $zh $en] -command [list ::BatchMesher::guarded $command]; pack $w.main.selection.$name -side left -padx {0 4} }
    label $w.main.selection.info -textvariable ::BatchMesher::ui(selected_text) -anchor w
    pack $w.main.selection.info -side left -padx 8

    frame $w.main.analysis
    grid $w.main.analysis -row 2 -column 0 -sticky ew -pady {0 6}
    button $w.main.analysis.run -text [::BatchMesher::txt "分析几何连通性" "Analyze connectivity"] -command {::BatchMesher::guarded ::BatchMesher::analyzeConnectivity}
    label $w.main.analysis.summary -textvariable ::BatchMesher::ui(summary_text) -anchor w
    pack $w.main.analysis.run -side left; pack $w.main.analysis.summary -side left -padx 10

    labelframe $w.main.groups -text [::BatchMesher::txt "3. 几何连通域" "3. Connectivity groups"] -padx 5 -pady 5
    grid $w.main.groups -row 3 -column 0 -sticky nsew -pady {0 6}
    grid rowconfigure $w.main.groups 0 -weight 1; grid columnconfigure $w.main.groups 0 -weight 1
    ttk::treeview $w.main.groups.tree -columns {surfaces components status warning} -show {tree headings} -height 7
    $w.main.groups.tree heading #0 -text [::BatchMesher::txt "连通域" "Group"]
    foreach item {{surfaces "Surface 数量"} {components "Component 数量"} {status "状态"} {warning "诊断"}} { lassign $item key title; $w.main.groups.tree heading $key -text $title; $w.main.groups.tree column $key -width 130 -anchor center }
    grid $w.main.groups.tree -row 0 -column 0 -sticky nsew
    bind $w.main.groups.tree <<TreeviewSelect>> ::BatchMesher::onGroupSelected
    label $w.main.groups.detail -textvariable ::BatchMesher::ui(group_detail) -anchor w
    grid $w.main.groups.detail -row 1 -column 0 -sticky ew -pady {3 0}
    frame $w.main.groups.actions; grid $w.main.groups.actions -row 2 -column 0 -sticky ew -pady {4 0}
    foreach spec {
        {show "显示" "Show" {::BatchMesher::showSelectedGroup 0}}
        {isolate "隔离" "Isolate" {::BatchMesher::showSelectedGroup 1}}
        {ids "查看 IDs/Components" "View IDs/components" ::BatchMesher::showSelectedGroupIds}
        {exclude "排除" "Exclude" {::BatchMesher::toggleSelectedGroupExcluded 1}}
        {restore "恢复排除" "Restore" {::BatchMesher::toggleSelectedGroupExcluded 0}}
    } { lassign $spec name zh en command; button $w.main.groups.actions.$name -text [::BatchMesher::txt $zh $en] -command [list ::BatchMesher::guarded $command]; pack $w.main.groups.actions.$name -side left -padx {0 4} }

    labelframe $w.main.tasks -text [::BatchMesher::txt "4. 顺序任务" "4. Sequential tasks"] -padx 5 -pady 5
    grid $w.main.tasks -row 4 -column 0 -sticky nsew -pady {0 6}
    grid rowconfigure $w.main.tasks 0 -weight 1; grid columnconfigure $w.main.tasks 0 -weight 1
    ttk::treeview $w.main.tasks.tree -columns {group surfaces status elapsed} -show {tree headings} -height 7
    $w.main.tasks.tree heading #0 -text [::BatchMesher::txt "任务" "Task"]
    foreach item {{group "连通域"} {surfaces "Surface 数量"} {status "状态"} {elapsed "耗时"}} { lassign $item key title; $w.main.tasks.tree heading $key -text $title; $w.main.tasks.tree column $key -width 140 -anchor center }
    grid $w.main.tasks.tree -row 0 -column 0 -sticky nsew
    bind $w.main.tasks.tree <<TreeviewSelect>> ::BatchMesher::onTaskSelected
    label $w.main.tasks.detail -textvariable ::BatchMesher::ui(task_detail) -anchor w -justify left -wraplength 900
    grid $w.main.tasks.detail -row 1 -column 0 -sticky ew -pady {3 0}
    frame $w.main.tasks.actions; grid $w.main.tasks.actions -row 2 -column 0 -sticky ew -pady {4 0}
    foreach spec {
        {start "开始运行" "Start" ::BatchMesher::runTasks}
        {stop "停止后续任务" "Stop later tasks" ::BatchMesher::requestStop}
        {cancel "取消当前（结束后停止）" "Cancel current (stop after it ends)" ::BatchMesher::requestStop}
        {retry "重试失败任务" "Retry failed" ::BatchMesher::retrySelectedTask}
        {failed "显示失败 Surfaces" "Show failed surfaces" ::BatchMesher::showFailedSurfaces}
        {report "查看日志/导出报告" "Logs / report" ::BatchMesher::exportReport}
    } { lassign $spec name zh en command; button $w.main.tasks.actions.$name -text [::BatchMesher::txt $zh $en] -command [list ::BatchMesher::guarded $command]; pack $w.main.tasks.actions.$name -side left -padx {0 4} }
    checkbutton $w.main.tasks.actions.continue -text [::BatchMesher::txt "失败后继续" "Continue after failure"] -variable ::BatchMesher::ui(CONTINUE_AFTER_FAILURE)
    checkbutton $w.main.tasks.actions.backup -text [::BatchMesher::txt "运行前备份" "Backup before run"] -variable ::BatchMesher::ui(AUTO_BACKUP)
    pack $w.main.tasks.actions.continue $w.main.tasks.actions.backup -side right -padx {4 0}

    frame $w.footer
    pack $w.footer -fill x -padx 10 -pady {0 8}
    label $w.footer.status -textvariable ::BatchMesher::ui(status_text) -anchor w
    button $w.footer.back -text [::BatchMesher::txt "返回主页" "Back to Home"] -command ::BatchMesher::closePanel
    pack $w.footer.status -side left -fill x -expand 1; pack $w.footer.back -side right
    wm protocol $w WM_DELETE_WINDOW ::BatchMesher::closePanel
    bind $w <Escape> ::BatchMesher::closePanel
    ::BatchMesher::refreshUi
    return $w
}

proc ::BatchMesher::closePanel {} {
    variable runtime
    if {$runtime(running)} { ::BatchMesher::requestStop; return }
    ::BatchMesher::savePanelState
    catch {destroy .batch_mesher}
    catch {::HWToolkit::showHome}
}
