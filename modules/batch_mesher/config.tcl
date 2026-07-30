namespace eval ::BatchMesher {
    variable VERSION "1.0"
    variable CONFIG_KEY "batch_mesher"
    variable TASK_STATUSES {pending running completed failed cancelled skipped}
    variable ui
    variable runtime
    array set ui {}
    array set runtime {
        selected_surfaces {}
        groups {}
        tasks {}
        analysis_signature ""
        analysis_all_surface_signature ""
        stop_after_current 0
        running 0
        run_dir ""
        run_id ""
        run_started_ms 0
        run_finished_ms 0
        run_error ""
        last_log ""
    }
}

proc ::BatchMesher::txt {zh en} { return [::HWFlow::txt $zh $en] }

proc ::BatchMesher::defaultPreset {} {
    return [dict create name Default criteria_path "" param_path "" criteria_mtime "" param_mtime ""]
}

proc ::BatchMesher::setDefaults {} {
    variable ui
    array set ui {
        HYPERMESH_VERSION 2019
        HMBATCH_PATH ""
        ACTIVE_PRESET Default
        DEFAULT_PRESET Default
        CRITERIA_PATH ""
        PARAM_PATH ""
        PRESETS {}
        CONTINUE_AFTER_FAILURE 1
        AUTO_BACKUP 1
        LARGE_GROUP_RATIO 0.8
        FUTURE_PARALLEL_WORKERS 1
        selected_text "No surfaces selected"
        summary_text "Not analyzed"
        status_text "Ready"
        group_detail ""
        task_detail ""
    }
    set ui(PRESETS) [list [::BatchMesher::defaultPreset]]
}

proc ::BatchMesher::loadState {} {
    variable ui
    ::BatchMesher::setDefaults
    set state [::HWFlow::loadState batch_mesher]
    foreach key {HMBATCH_PATH ACTIVE_PRESET DEFAULT_PRESET CRITERIA_PATH PARAM_PATH PRESETS CONTINUE_AFTER_FAILURE AUTO_BACKUP LARGE_GROUP_RATIO FUTURE_PARALLEL_WORKERS} {
        if {[dict exists $state $key]} { set ui($key) [dict get $state $key] }
    }
    if {[catch {llength $ui(PRESETS)}] || [llength $ui(PRESETS)] == 0} {
        set ui(PRESETS) [list [::BatchMesher::defaultPreset]]
    }
    if {[catch {::BatchMesher::selectPreset $ui(ACTIVE_PRESET) 0}]} {
        set ui(PRESETS) [list [::BatchMesher::defaultPreset]]
        set ui(ACTIVE_PRESET) Default
        set ui(DEFAULT_PRESET) Default
        ::BatchMesher::selectPreset Default 0
    }
}

proc ::BatchMesher::saveState {} {
    variable ui
    set state [dict create]
    foreach key {HMBATCH_PATH ACTIVE_PRESET DEFAULT_PRESET CRITERIA_PATH PARAM_PATH PRESETS CONTINUE_AFTER_FAILURE AUTO_BACKUP LARGE_GROUP_RATIO FUTURE_PARALLEL_WORKERS} {
        dict set state $key $ui($key)
    }
    ::HWFlow::saveState batch_mesher $state
}

proc ::BatchMesher::savePanelState {} { catch {::BatchMesher::saveState} }

proc ::BatchMesher::presetNames {} {
    variable ui
    set names {}
    foreach preset $ui(PRESETS) {
        if {[dict exists $preset name]} { lappend names [dict get $preset name] }
    }
    return $names
}

proc ::BatchMesher::findPresetIndex {name} {
    variable ui
    set i 0
    foreach preset $ui(PRESETS) {
        if {[dict exists $preset name] && [dict get $preset name] eq $name} { return $i }
        incr i
    }
    return -1
}

proc ::BatchMesher::selectPreset {name {refresh 1}} {
    variable ui
    set index [::BatchMesher::findPresetIndex $name]
    if {$index < 0} {
        set index [::BatchMesher::findPresetIndex $ui(DEFAULT_PRESET)]
    }
    if {$index < 0} { set index 0 }
    set preset [lindex $ui(PRESETS) $index]
    set ui(ACTIVE_PRESET) [dict get $preset name]
    set ui(CRITERIA_PATH) [dict get $preset criteria_path]
    set ui(PARAM_PATH) [dict get $preset param_path]
    if {$refresh} { catch {::BatchMesher::refreshPresetWidget} }
    return $preset
}

proc ::BatchMesher::fileMtime {path} {
    if {$path ne "" && [file isfile $path]} { return [file mtime $path] }
    return ""
}

proc ::BatchMesher::saveCurrentPreset {} {
    variable ui
    set name [string trim $ui(ACTIVE_PRESET)]
    if {$name eq ""} { error [::BatchMesher::txt "预设名称不能为空。" "Preset name cannot be empty."] }
    set preset [dict create name $name criteria_path [string trim $ui(CRITERIA_PATH)] param_path [string trim $ui(PARAM_PATH)] \
        criteria_mtime [::BatchMesher::fileMtime $ui(CRITERIA_PATH)] param_mtime [::BatchMesher::fileMtime $ui(PARAM_PATH)]]
    set index [::BatchMesher::findPresetIndex $name]
    if {$index < 0} { lappend ui(PRESETS) $preset } else { set ui(PRESETS) [lreplace $ui(PRESETS) $index $index $preset] }
    set ui(ACTIVE_PRESET) $name
    ::BatchMesher::saveState
    catch {::BatchMesher::refreshPresetWidget}
    return $preset
}

proc ::BatchMesher::newPreset {} {
    variable ui
    set base [::BatchMesher::txt "新预设" "NewPreset"]
    set name $base
    set i 1
    while {[::BatchMesher::findPresetIndex $name] >= 0} { incr i; set name "${base}_$i" }
    set ui(ACTIVE_PRESET) $name
    set ui(CRITERIA_PATH) ""
    set ui(PARAM_PATH) ""
    ::BatchMesher::saveCurrentPreset
}

proc ::BatchMesher::deletePreset {} {
    variable ui
    set index [::BatchMesher::findPresetIndex $ui(ACTIVE_PRESET)]
    if {$index < 0} { return }
    if {[llength $ui(PRESETS)] <= 1} { error [::BatchMesher::txt "至少保留一个预设。" "Keep at least one preset."] }
    set ui(PRESETS) [lreplace $ui(PRESETS) $index $index]
    set next [lindex $ui(PRESETS) 0]
    if {$ui(DEFAULT_PRESET) eq $ui(ACTIVE_PRESET)} { set ui(DEFAULT_PRESET) [dict get $next name] }
    ::BatchMesher::selectPreset [dict get $next name]
    ::BatchMesher::saveState
}

proc ::BatchMesher::setDefaultPreset {} {
    variable ui
    ::BatchMesher::saveCurrentPreset
    set ui(DEFAULT_PRESET) $ui(ACTIVE_PRESET)
    ::BatchMesher::saveState
}

proc ::BatchMesher::restoreDefaults {} {
    variable ui
    ::BatchMesher::setDefaults
    ::BatchMesher::saveState
    catch {::BatchMesher::refreshPresetWidget}
}

proc ::BatchMesher::validateReadableFile {label path extension} {
    set path [string trim $path]
    if {$path eq ""} { error "$label: [::BatchMesher::txt "未配置路径" "path is not configured"]" }
    if {![file isfile $path]} { error "$label: [::BatchMesher::txt "文件不存在" "file does not exist"]: $path" }
    if {![file readable $path]} { error "$label: [::BatchMesher::txt "文件不可读" "file is not readable"]: $path" }
    if {[string tolower [file extension $path]] ne $extension} { error "$label: [::BatchMesher::txt "扩展名应为" "expected extension"] $extension: $path" }
    return [file normalize $path]
}

proc ::BatchMesher::validateHmbatch {{required 1}} {
    variable ui
    set path [string trim $ui(HMBATCH_PATH)]
    if {$path eq "" && !$required} { return "" }
    if {![file isfile $path]} { error "hmbatch.exe: [::BatchMesher::txt "文件不存在" "file does not exist"]: $path" }
    if {[string tolower [file tail $path]] ne "hmbatch.exe"} { error [::BatchMesher::txt "所选文件名必须是 hmbatch.exe。" "The selected file must be named hmbatch.exe."] }
    if {![file executable $path]} { error "hmbatch.exe: [::BatchMesher::txt "当前用户不可执行" "not executable by the current user"]: $path" }
    return [file normalize $path]
}

proc ::BatchMesher::validateRunConfig {} {
    variable ui
    set criteria [::BatchMesher::validateReadableFile Criteria $ui(CRITERIA_PATH) .criteria]
    set param [::BatchMesher::validateReadableFile Parameter $ui(PARAM_PATH) .param]
    if {![string is double -strict $ui(LARGE_GROUP_RATIO)] || $ui(LARGE_GROUP_RATIO) <= 0 || $ui(LARGE_GROUP_RATIO) > 1} {
        error [::BatchMesher::txt "大型连通域阈值必须在 0 到 1 之间。" "Large-group ratio must be between 0 and 1."]
    }
    set warnings {}
    set index [::BatchMesher::findPresetIndex $ui(ACTIVE_PRESET)]
    if {$index >= 0} {
        set preset [lindex $ui(PRESETS) $index]
        foreach pair [list [list criteria $criteria criteria_mtime] [list param $param param_mtime]] {
            lassign $pair label path key
            if {[dict exists $preset $key] && [dict get $preset $key] ne "" && [dict get $preset $key] != [file mtime $path]} {
                lappend warnings "$label file was modified externally: $path"
            }
        }
    }
    return [dict create criteria $criteria param $param hmbatch [::BatchMesher::validateHmbatch 1] warnings $warnings]
}
