namespace eval ::BatchMesher {
    variable VERSION "2.6"
    variable CONFIG_KEY "batch_mesher"
    # hmbatch.exe can return before the real hmopengl process has finished
    # loading HyperMesh and sourcing the worker Tcl, especially when several
    # HM2022 instances start together.  Do not treat that launcher exit as a
    # task failure until the worker has had time to create its state handshake.
    variable WORKER_STARTUP_TIMEOUT_MS 120000
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
        background_pid ""
        background_started_ms 0
        background_after ""
        background_state_path ""
        background_task_ids {}
        background_pending {}
        background_active {}
        background_startup_verified 0
        background_outputs {}
        background_phase ""
        background_merge_pid ""
        background_merge_launcher_pid ""
        background_merge_dir ""
        background_merge_stdout ""
        background_merge_stderr ""
        background_merge_launch_log ""
        background_merge_state_path ""
        background_snapshot ""
        background_executable ""
        background_criteria ""
        background_param ""
        background_criteria_mtime 0
        background_criteria_size 0
        background_param_mtime 0
        background_param_size 0
        background_export_template ""
        background_release ""
        validated_hmbatch_path ""
        validated_hmbatch_mtime 0
        validated_hmbatch_version ""
        validated_hmbatch_executable ""
        background_monitor_status_path ""
        background_monitor_done_path ""
        result_fem_path ""
        import_status ""
        imported_result_paths {}
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
        PARALLEL_WORKERS 2
        BACKGROUND_POLL_MS 500
        SHOW_CMD_WINDOW 1
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
    foreach key {HMBATCH_PATH ACTIVE_PRESET DEFAULT_PRESET CRITERIA_PATH PARAM_PATH PRESETS CONTINUE_AFTER_FAILURE AUTO_BACKUP LARGE_GROUP_RATIO PARALLEL_WORKERS SHOW_CMD_WINDOW} {
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
    foreach key {HMBATCH_PATH ACTIVE_PRESET DEFAULT_PRESET CRITERIA_PATH PARAM_PATH PRESETS CONTINUE_AFTER_FAILURE AUTO_BACKUP LARGE_GROUP_RATIO PARALLEL_WORKERS SHOW_CMD_WINDOW} {
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
    if {![string is integer -strict $ui(PARALLEL_WORKERS)] || $ui(PARALLEL_WORKERS) < 1 || $ui(PARALLEL_WORKERS) > 16} {
        error [::BatchMesher::txt "并行 hmbatch 数量必须是 1 到 16 的整数。" "Parallel hmbatch count must be an integer from 1 to 16."]
    }
    set warnings {}
    if {$ui(PARALLEL_WORKERS) > 2} {
        lappend warnings [::BatchMesher::txt \
            "当前并行数为 $ui(PARALLEL_WORKERS)；本项目对 HyperMesh 2022 的实机验证上限为 2，更多实例可能受许可证或启动资源限制。首次验证请使用 1。" \
            "Parallel workers is $ui(PARALLEL_WORKERS); live HyperMesh 2022 validation covered up to 2, and additional instances may hit license or startup-resource limits. Use 1 for the first validation."]
    }
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

proc ::BatchMesher::batchMeshElementSize {paramPath} {
    if {[catch {set text [::HWFlow::readTextFile $paramPath]}]} { return "" }
    if {[regexp -line {^[ \t]*element_size[ \t]+([0-9]+(?:[.][0-9]*)?(?:[eE][+-]?[0-9]+)?)} $text -> value] &&
        [string is double -strict $value] && $value > 0} {
        return [expr {double($value)}]
    }
    return ""
}

proc ::BatchMesher::selectedSurfaceGeometrySpan {surfaceIds} {
    if {[llength $surfaceIds] == 0} { return "" }
    set count [llength $surfaceIds]
    set stride [expr {max(1, int(ceil(double($count) / 64.0)))}]
    array set seenPoint {}
    set coords {}
    for {set index 0} {$index < $count} {incr index $stride} {
        set surfaceId [lindex $surfaceIds $index]
        if {[catch {set loops [hm_getsurfaceedges $surfaceId]}]} { continue }
        foreach loop $loops {
            foreach edgeId $loop {
                if {[catch {set pointIds [hm_getverticesfromedge $edgeId]}]} { continue }
                foreach pointId $pointIds {
                    if {[info exists seenPoint($pointId)]} { continue }
                    set seenPoint($pointId) 1
                    if {[catch {set xyz [hm_getvalue points id=$pointId dataname=coordinates]}] || [llength $xyz] < 3} { continue }
                    lappend coords [lrange $xyz 0 2]
                }
            }
        }
    }
    if {[llength $coords] < 2} { return "" }
    lassign [lindex $coords 0] xmin ymin zmin
    set xmax $xmin; set ymax $ymin; set zmax $zmin
    foreach xyz [lrange $coords 1 end] {
        lassign $xyz x y z
        if {$x < $xmin} { set xmin $x }; if {$x > $xmax} { set xmax $x }
        if {$y < $ymin} { set ymin $y }; if {$y > $ymax} { set ymax $y }
        if {$z < $zmin} { set zmin $z }; if {$z > $zmax} { set zmax $z }
    }
    return [expr {max($xmax-$xmin, $ymax-$ymin, $zmax-$zmin)}]
}

proc ::BatchMesher::validateBatchMeshScale {surfaceIds paramPath} {
    set elementSize [::BatchMesher::batchMeshElementSize $paramPath]
    if {$elementSize eq ""} { return "" }
    set geometrySpan [::BatchMesher::selectedSurfaceGeometrySpan $surfaceIds]
    if {$geometrySpan eq "" || $geometrySpan <= 0} { return "" }
    if {$elementSize >= $geometrySpan} {
        error [::BatchMesher::txt \
            "BatchMesh 单元尺寸 $elementSize 大于或等于所选几何整体跨度 [format %.6g $geometrySpan]。模型与 criteria/param 很可能使用了不同长度单位（例如米制模型应将 8 mm 写为 0.008）；已在启动 worker 前停止。" \
            "BatchMesh element size $elementSize is greater than or equal to the selected geometry span [format %.6g $geometrySpan]. The model and criteria/param likely use different length units (for example, use 0.008 for 8 mm in a metre-based model); stopped before launching workers."]
    }
    return [dict create element_size $elementSize geometry_span $geometrySpan]
}
