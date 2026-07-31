proc ::BatchMesher::jsonString {value} {
    set escaped [string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $value]
    return "\"$escaped\""
}

proc ::BatchMesher::jsonBool {value} { return [expr {$value ? "true" : "false"}] }

proc ::BatchMesher::jsonNumberOrNull {value} {
    if {[string is double -strict $value]} { return $value }
    return null
}

proc ::BatchMesher::jsonIdArray {ids} {
    set values {}
    foreach id [::BatchMesher::uniqIds $ids] { lappend values $id }
    return "\[[join $values ,]\]"
}

proc ::BatchMesher::log {level message} {
    variable runtime
    set runtime(last_log) [::HybridCore::log $level $message]
    catch {::HWFlow::progressAppend $message 1}
    return $runtime(last_log)
}

proc ::BatchMesher::createRunWorkspace {} {
    variable runtime
    set workspace [::HybridCore::createTaskWorkspace batch_mesher]
    set runtime(run_dir) [dict get $workspace task_dir]
    set runtime(run_id) "batchmesh_[clock format [clock seconds] -format {%Y%m%d_%H%M%S}]"
    set runtime(run_started_ms) [clock milliseconds]
    set runtime(run_finished_ms) 0
    set runtime(run_error) ""
    ::HybridCore::closeLog
    ::HybridCore::openLog [file join $runtime(run_dir) run.log]
    return $runtime(run_dir)
}

proc ::BatchMesher::taskLog {task level message} {
    variable runtime
    set path [file join $runtime(run_dir) "task_[dict get $task group_id].log"]
    set line "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] [string toupper $level] $message"
    set ch [open $path a]
    fconfigure $ch -encoding utf-8 -translation lf
    puts $ch $line
    close $ch
    ::BatchMesher::log $level "[dict get $task task_id]/[dict get $task group_id] $message"
    return $path
}

proc ::BatchMesher::modelPath {} {
    foreach command {{hm_info currentfile} {hm_info -appinfo CURRENTFILE}} {
        if {![catch {set value [uplevel #0 $command]}] && [string trim $value] ne ""} { return [file normalize $value] }
    }
    return ""
}

proc ::BatchMesher::groupJson {group indent} {
    set names {}
    foreach name [dict get $group component_names] { lappend names [::BatchMesher::jsonString $name] }
    return [join [list \
        "$indent{" \
        "$indent  \"group_id\": [::BatchMesher::jsonString [dict get $group group_id]]," \
        "$indent  \"surface_ids\": [::BatchMesher::jsonIdArray [dict get $group surface_ids]]," \
        "$indent  \"surface_count\": [dict get $group surface_count]," \
        "$indent  \"component_ids\": [::BatchMesher::jsonIdArray [dict get $group component_ids]]," \
        "$indent  \"component_names\": \[[join $names ,]\]," \
        "$indent  \"excluded\": [::BatchMesher::jsonBool [dict get $group excluded]]" \
        "$indent}"] "\n"]
}

proc ::BatchMesher::taskJson {task indent} {
    set componentNames {}
    foreach name [dict get $task component_names] { lappend componentNames [::BatchMesher::jsonString $name] }
    return [join [list \
        "$indent{" \
        "$indent  \"task_id\": [::BatchMesher::jsonString [dict get $task task_id]]," \
        "$indent  \"group_id\": [::BatchMesher::jsonString [dict get $task group_id]]," \
        "$indent  \"surface_ids\": [::BatchMesher::jsonIdArray [dict get $task surface_ids]]," \
        "$indent  \"surface_count\": [dict get $task surface_count]," \
        "$indent  \"component_ids\": [::BatchMesher::jsonIdArray [dict get $task component_ids]]," \
        "$indent  \"component_names\": \[[join $componentNames ,]\]," \
        "$indent  \"status\": [::BatchMesher::jsonString [dict get $task status]]," \
        "$indent  \"elapsed_seconds\": [::BatchMesher::jsonNumberOrNull [dict get $task elapsed_seconds]]," \
        "$indent  \"started_at\": [::BatchMesher::jsonString [dict get $task started_at]]," \
        "$indent  \"ended_at\": [::BatchMesher::jsonString [dict get $task ended_at]]," \
        "$indent  \"error_message\": [::BatchMesher::jsonString [dict get $task error_message]]," \
        "$indent  \"warning_message\": [::BatchMesher::jsonString [dict get $task warning_message]]," \
        "$indent  \"packaging_status\": [::BatchMesher::jsonString [dict get $task packaging_status]]," \
        "$indent  \"packaging_error\": [::BatchMesher::jsonString [dict get $task packaging_error]]," \
        "$indent  \"log_path\": [::BatchMesher::jsonString [dict get $task log_path]]" \
        "$indent}"] "\n"]
}

proc ::BatchMesher::writeRunReport {{final 0}} {
    variable runtime
    variable ui
    if {$runtime(run_dir) eq ""} { return "" }
    set groupJson {}
    foreach group $runtime(groups) { lappend groupJson [::BatchMesher::groupJson $group "    "] }
    set taskJson {}
    foreach task $runtime(tasks) { lappend taskJson [::BatchMesher::taskJson $task "    "] }
    set resultTaskIds {}
    foreach taskId $runtime(background_task_ids) { lappend resultTaskIds [::BatchMesher::jsonString $taskId] }
    set endTime ""
    set elapsed null
    if {$runtime(run_finished_ms) > 0} {
        set endTime [clock format [expr {$runtime(run_finished_ms) / 1000}] -format {%Y-%m-%dT%H:%M:%S}]
        set elapsed [format %.3f [expr {($runtime(run_finished_ms)-$runtime(run_started_ms))/1000.0}]]
    }
    set statuses {}
    foreach task $runtime(tasks) { lappend statuses [dict get $task status] }
    set result running
    if {$final} {
        if {$runtime(run_error) ne "" || [lsearch -exact $statuses failed] >= 0} { set result failed \
        } elseif {[lsearch -exact $statuses cancelled] >= 0} { set result cancelled \
        } else { set result completed }
    }
    set lines [list \
        "{" \
        "  \"run_id\": [::BatchMesher::jsonString $runtime(run_id)]," \
        "  \"hypermesh_version\": [::BatchMesher::jsonString $ui(HYPERMESH_VERSION)]," \
        "  \"hmbatch_path\": [::BatchMesher::jsonString $ui(HMBATCH_PATH)]," \
        "  \"criteria_path\": [::BatchMesher::jsonString $ui(CRITERIA_PATH)]," \
        "  \"param_path\": [::BatchMesher::jsonString $ui(PARAM_PATH)]," \
        "  \"model_path\": [::BatchMesher::jsonString [::BatchMesher::modelPath]]," \
        "  \"result_fem_path\": [::BatchMesher::jsonString $runtime(result_fem_path)]," \
        "  \"result_task_ids\": \[[join $resultTaskIds ,]\]," \
        "  \"import_status\": [::BatchMesher::jsonString $runtime(import_status)]," \
        "  \"target_surface_count\": [llength $runtime(selected_surfaces)]," \
        "  \"connectivity_group_count\": [llength $runtime(groups)]," \
        "  \"started_at\": [::BatchMesher::jsonString [clock format [expr {$runtime(run_started_ms) / 1000}] -format {%Y-%m-%dT%H:%M:%S}]]," \
        "  \"ended_at\": [::BatchMesher::jsonString $endTime]," \
        "  \"elapsed_seconds\": $elapsed," \
        "  \"cancelled\": [::BatchMesher::jsonBool [expr {[lsearch -exact $statuses cancelled] >= 0}]]," \
        "  \"error_message\": [::BatchMesher::jsonString $runtime(run_error)]," \
        "  \"result\": [::BatchMesher::jsonString $result]," \
        "  \"groups\": \[" \
        [join $groupJson ",\n"] \
        "  \]," \
        "  \"tasks\": \[" \
        [join $taskJson ",\n"] \
        "  \]" \
        "}"]
    set path [file join $runtime(run_dir) [expr {$final ? "result.json" : "run.json"}]]
    ::HWFlow::writeTextFile $path [join $lines "\n"]
    if {$final} { ::HWFlow::writeTextFile [file join $runtime(run_dir) run.json] [join $lines "\n"] }
    return $path
}

proc ::BatchMesher::exportReport {} {
    variable runtime
    if {$runtime(run_dir) eq ""} { error [::BatchMesher::txt "尚无运行报告。" "No run report is available."] }
    ::BatchMesher::writeRunReport [expr {!$runtime(running)}]
    ::BatchMesher::openDirectory $runtime(run_dir)
}

proc ::BatchMesher::openDirectory {path} {
    if {$path eq ""} { return }
    if {[file isfile $path]} { set path [file dirname $path] }
    if {![file isdirectory $path]} { error [::BatchMesher::txt "目录不存在：" "Directory does not exist: "]$path }
    if {$::tcl_platform(platform) eq "windows"} { exec explorer.exe [file nativename $path] & \
    } elseif {$::tcl_platform(os) eq "Darwin"} { exec open $path & \
    } else { exec xdg-open $path & }
}
