# ============================================================================
# Local Mesh Optimizer
# HyperMesh 2019 Tcl/Tk integration shell
#
# HyperMesh remains the quality and model-modification authority. Python is
# limited to edge adjacency, region planning, task files and reports.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::LocalMeshOptimizer {
    variable VERSION "0.1.0"
    variable SCRIPT_DIR [file dirname [file normalize [info script]]]
    variable MODULE_DIR [file join $SCRIPT_DIR local_mesh_optimizer]
    variable PYTHON_ENTRY [file join $MODULE_DIR python optimizer_controller.py]
    variable WINDOW .local_mesh_optimizer
    variable ADVANCED_WINDOW .local_mesh_optimizer_advanced
    variable ui
    variable runtime
    array set ui {}
    array set runtime {
        selectedComponents {}
        selectedElements {}
        userAnchorNodes {}
        failedElements {}
        optimizationFailedElements {}
        washerElements {}
        washerExcludedFailed {}
        optimizedElements {}
        checkedElements 0
        taskDir ""
        backupPath ""
        sourceModelPath ""
        lastOutputModel ""
        running 0
        selectionActive 0
        pythonCommand ""
        pythonWaitTick 0
        restoreArmedUntil 0
        topologyFailureAllowance 0
        progressStartedMs 0
        criteriaLoadedPath ""
        criteriaLoadedMtime -1
        checkedCriteriaPath ""
        checkedCriteriaMtime -1
        checkedScopeType ""
        checkedScopeIds {}
        checkedPlanSettings ""
        planReady 0
    }
    variable DEFAULTS
    array set DEFAULTS {
        SCOPE_TYPE components
        CRITERIA_PATH ""
        CRITERIA_RECENT ""
        OPTIMIZATION_LEVEL standard
        ADJACENCY_LAYERS 2
        MAX_ROUNDS 3
        FEATURE_ANGLE 30.0
        TARGET_QI ""
        MAX_REGION_ELEMENTS 50000
        MAX_REGION_SECONDS 120
        SKINNY_TRIANGLE_RATIO 2.5
        NARROW_QUAD_RATIO 2.5
        NARROW_TARGET_ASPECT 1.5
        CONTROLLED_EDGE_GROWTH 1.75
        ALLOW_CONTROLLED_FREE_EDGE_MOVE 1
        PROTECT_FREE_EDGES 1
        PROTECT_COMPONENT_BOUNDARIES 1
        PROTECT_HOLE_EDGES 1
        PROTECT_FEATURE_EDGES 1
        PROTECT_RIGID_NODES 0
        PROTECT_WELD_NODES 0
        PROTECT_USER_NODES 1
        NO_CROSS_COMPONENT_MOVEMENT 1
        PROJECT_TO_GEOMETRY 0
        PRESERVE_GEOMETRY_ASSOCIATION 1
        EXCLUDE_WASHER_ELEMENTS 1
        REPORT_DIR ""
        AUTO_OPEN_REPORT 0
        AUTO_SAVE_MODEL 1
        PYTHON_COMMAND ""
        HM2019_PROFILE unverified
    }
}

proc ::LocalMeshOptimizer::txt {zh en} { return [::HWFlow::txt $zh $en] }

proc ::LocalMeshOptimizer::setStatus {level message} {
    variable ui
    set ui(RESULT_TEXT) $message
    ::LocalMeshOptimizer::log $level $message
    catch {update idletasks}
    return 0
}

proc ::LocalMeshOptimizer::ensureProgress {message} {
    if {[llength [info commands winfo]] > 0 &&
        [info exists ::HWFlow::progressWin] &&
        [winfo exists $::HWFlow::progressWin]} {
        return 1
    }
    return [::HWFlow::progressOpen "Local Mesh Optimizer" $message 1]
}

proc ::LocalMeshOptimizer::formatDuration {seconds} {
    set value [expr {max(0, int($seconds))}]
    set hours [expr {$value / 3600}]
    set minutes [expr {($value % 3600) / 60}]
    set secs [expr {$value % 60}]
    if {$hours > 0} { return [format {%02d:%02d:%02d} $hours $minutes $secs] }
    return [format {%02d:%02d} $minutes $secs]
}

proc ::LocalMeshOptimizer::optimizationProgress {percent stage detail {force 1}} {
    variable runtime
    set now [clock milliseconds]
    if {$runtime(progressStartedMs) <= 0} { set runtime(progressStartedMs) $now }
    set elapsed [expr {($now - $runtime(progressStartedMs)) / 1000.0}]
    set timing [::LocalMeshOptimizer::txt "已用 [::LocalMeshOptimizer::formatDuration $elapsed]" "Elapsed [::LocalMeshOptimizer::formatDuration $elapsed]"]
    # The region-processing phase occupies 10..90 percent. Estimate only once
    # enough real work has completed; early snapshot timings are misleading.
    if {$percent > 12.0 && $percent < 90.0} {
        set fraction [expr {(double($percent) - 10.0) / 80.0}]
        if {$fraction > 0.02} {
            set eta [expr {$elapsed * (1.0 - $fraction) / $fraction}]
            append timing [::LocalMeshOptimizer::txt "；预计剩余 [::LocalMeshOptimizer::formatDuration $eta]" "; ETA [::LocalMeshOptimizer::formatDuration $eta]"]
        }
    }
    if {$detail ne ""} { append detail "；" }
    append detail $timing
    return [::HWFlow::progressUpdate $percent $stage $detail $force]
}

proc ::LocalMeshOptimizer::log {level message {region "-"} {round "-"} {command "-"} {inputCount "-"} {outputCount "-"} {elapsed "-"}} {
    variable runtime
    set timestamp [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]
    set line "\[$timestamp\] \[$level\] \[LocalMeshOptimizer\] region=$region round=$round command=$command input=$inputCount output=$outputCount elapsed=$elapsed $message"
    catch {puts $line}
    catch {::HWFlow::progressAppend $line}
    if {$runtime(taskDir) ne "" && [file isdirectory $runtime(taskDir)]} {
        set path [file join $runtime(taskDir) optimizer.log]
        if {![catch {set stream [open $path a]}]} {
            fconfigure $stream -encoding utf-8 -translation lf
            puts $stream $line
            close $stream
        }
    }
}

proc ::LocalMeshOptimizer::loadState {} {
    variable DEFAULTS
    variable ui
    catch {array unset ui}
    foreach key [array names DEFAULTS] { set ui($key) $DEFAULTS($key) }
    ::HWFlow::applyStateToArray local_mesh_optimizer ::LocalMeshOptimizer::ui
    ::LocalMeshOptimizer::updateCriteriaStatus
}

proc ::LocalMeshOptimizer::stateKeys {} {
    variable DEFAULTS
    return [array names DEFAULTS]
}

proc ::LocalMeshOptimizer::saveState {} {
    variable ui
    set state [dict create]
    foreach key [::LocalMeshOptimizer::stateKeys] {
        if {[info exists ui($key)]} { dict set state $key $ui($key) }
    }
    ::HWFlow::saveState local_mesh_optimizer $state
}

proc ::LocalMeshOptimizer::savePanelState {} { catch {::LocalMeshOptimizer::saveState} }

proc ::LocalMeshOptimizer::invalidatePlan {} {
    variable runtime
    set runtime(planReady) 0
}

proc ::LocalMeshOptimizer::uniq {values} {
    array set seen {}
    foreach value $values { if {$value ne ""} { set seen($value) 1 } }
    set result [array names seen]
    if {[catch {set result [lsort -integer $result]}]} { set result [lsort $result] }
    return $result
}

proc ::LocalMeshOptimizer::restoreMainWindow {} {
    variable WINDOW
    if {[llength [info commands winfo]] == 0 || ![winfo exists $WINDOW]} { return }
    catch {wm deiconify $WINDOW}
    catch {::HWFlow::keepWindowTopmost $WINDOW}
    catch {raise $WINDOW}
    catch {focus -force $WINDOW}
    catch {update idletasks}
}

proc ::LocalMeshOptimizer::runSelectionPanel {entityType prompt} {
    variable WINDOW
    variable runtime
    if {$runtime(running)} {
        error [::LocalMeshOptimizer::txt "当前任务正在运行，不能打开选择面板。" "A task is running; the selection panel cannot be opened."]
    }
    if {$runtime(selectionActive)} {
        error [::LocalMeshOptimizer::txt "已有选择面板处于活动状态。" "A selection panel is already active."]
    }
    set runtime(selectionActive) 1
    catch {*clearmark $entityType 1}

    # A persistent topmost Tk window can sit above HyperMesh's native mark
    # panel and make the application appear frozen. Fully release the Tk grab,
    # remove topmost, and withdraw the module while native picking is active.
    if {[llength [info commands grab]] > 0} {
        catch {set grabbed [grab current]}
        if {[info exists grabbed] && $grabbed ne ""} { catch {grab release $grabbed} }
    }
    if {[winfo exists $WINDOW]} {
        catch {wm attributes $WINDOW -topmost 0}
        catch {wm withdraw $WINDOW}
    }
    catch {update}

    set code [catch {
        set selected [::HWFlow::nativeMarkPanel $entityType 1 $prompt]
    } err opts]
    catch {*clearmark $entityType 1}
    set runtime(selectionActive) 0
    ::LocalMeshOptimizer::restoreMainWindow
    if {$code} { return -options $opts $err }
    return [::LocalMeshOptimizer::uniq $selected]
}

proc ::LocalMeshOptimizer::pickComponents {} {
    variable runtime
    if {[catch {set selected [::LocalMeshOptimizer::runSelectionPanel comps [::LocalMeshOptimizer::txt "选择局部网格优化范围组件；中键确认，Esc 取消" "Select components; middle-click to confirm or Esc to cancel"]]} err]} {
        ::LocalMeshOptimizer::setStatus ERROR $err
        return
    }
    set runtime(selectedComponents) $selected
    ::LocalMeshOptimizer::invalidatePlan
    ::LocalMeshOptimizer::refreshSelectionText
}

proc ::LocalMeshOptimizer::pickElements {} {
    variable runtime
    if {[catch {set selected [::LocalMeshOptimizer::runSelectionPanel elems [::LocalMeshOptimizer::txt "选择待检查的 2D 单元；中键确认，Esc 取消" "Select 2D elements; middle-click to confirm or Esc to cancel"]]} err]} {
        ::LocalMeshOptimizer::setStatus ERROR $err
        return
    }
    set runtime(selectedElements) $selected
    ::LocalMeshOptimizer::invalidatePlan
    ::LocalMeshOptimizer::refreshSelectionText
}

proc ::LocalMeshOptimizer::pickAnchorNodes {} {
    variable runtime
    if {[catch {set selected [::LocalMeshOptimizer::runSelectionPanel nodes [::LocalMeshOptimizer::txt "选择优化期间固定的节点；中键确认，Esc 取消" "Select anchor nodes; middle-click to confirm or Esc to cancel"]]} err]} {
        ::LocalMeshOptimizer::setStatus ERROR $err
        return
    }
    set runtime(userAnchorNodes) $selected
    ::LocalMeshOptimizer::invalidatePlan
    ::LocalMeshOptimizer::refreshSelectionText
}

proc ::LocalMeshOptimizer::clearSelection {} {
    variable runtime
    if {$runtime(running)} {
        ::LocalMeshOptimizer::setStatus WARN [::LocalMeshOptimizer::txt "任务运行期间不能清除选择。" "Selections cannot be cleared while a task is running."]
        return
    }
    set runtime(selectedComponents) {}
    set runtime(selectedElements) {}
    set runtime(userAnchorNodes) {}
    ::LocalMeshOptimizer::invalidatePlan
    ::LocalMeshOptimizer::refreshSelectionText
}

proc ::LocalMeshOptimizer::refreshSelectionText {} {
    variable runtime
    variable ui
    set ui(SELECTION_TEXT) [::LocalMeshOptimizer::txt \
        "已选择组件：[llength $runtime(selectedComponents)]；已选择单元：[llength $runtime(selectedElements)]；固定节点：[llength $runtime(userAnchorNodes)]" \
        "Components: [llength $runtime(selectedComponents)]; elements: [llength $runtime(selectedElements)]; anchors: [llength $runtime(userAnchorNodes)]"]
}

proc ::LocalMeshOptimizer::browseCriteria {} {
    variable ui
    variable runtime
    if {$runtime(running)} { return }
    set initial ""
    if {$ui(CRITERIA_PATH) ne ""} { set initial [file dirname $ui(CRITERIA_PATH)] }
    set path [tk_getOpenFile -parent .local_mesh_optimizer -title [::LocalMeshOptimizer::txt "选择 criteria 文件" "Select criteria file"] -initialdir $initial -filetypes {{{HyperMesh criteria} {.criteria}} {{All files} *}}]
    if {$path ne ""} {
        set ui(CRITERIA_PATH) [file normalize $path]
        ::LocalMeshOptimizer::invalidatePlan
        ::LocalMeshOptimizer::rememberCriteria $ui(CRITERIA_PATH)
    }
    ::LocalMeshOptimizer::updateCriteriaStatus
}

proc ::LocalMeshOptimizer::rememberCriteria {path} {
    variable ui
    set recent [list [file normalize $path]]
    foreach value $ui(CRITERIA_RECENT) {
        if {$value ne "" && [file normalize $value] ne [file normalize $path]} { lappend recent $value }
        if {[llength $recent] >= 8} { break }
    }
    set ui(CRITERIA_RECENT) $recent
    ::LocalMeshOptimizer::refreshRecentMenu
}

proc ::LocalMeshOptimizer::selectRecentCriteria {path} {
    variable ui
    set ui(CRITERIA_PATH) $path
    ::LocalMeshOptimizer::invalidatePlan
    ::LocalMeshOptimizer::updateCriteriaStatus
}

proc ::LocalMeshOptimizer::refreshRecentMenu {} {
    variable ui
    set menu .local_mesh_optimizer.main.criteria.recent.menu
    if {![winfo exists $menu]} { return }
    $menu delete 0 end
    if {[llength $ui(CRITERIA_RECENT)] == 0} {
        $menu add command -label [::LocalMeshOptimizer::txt "无最近记录" "No recent files"] -state disabled
        return
    }
    foreach path $ui(CRITERIA_RECENT) {
        $menu add command -label $path -command [list ::LocalMeshOptimizer::selectRecentCriteria $path]
    }
}

proc ::LocalMeshOptimizer::updateCriteriaStatus {} {
    variable ui
    if {![info exists ui(CRITERIA_PATH)] || [string trim $ui(CRITERIA_PATH)] eq ""} {
        set ui(CRITERIA_STATUS) [::LocalMeshOptimizer::txt "未选择文件" "No file selected"]
    } elseif {![file isfile $ui(CRITERIA_PATH)]} {
        set ui(CRITERIA_STATUS) [::LocalMeshOptimizer::txt "文件不存在" "File does not exist"]
    } elseif {[string tolower [file extension $ui(CRITERIA_PATH)]] ne ".criteria"} {
        set ui(CRITERIA_STATUS) [::LocalMeshOptimizer::txt "扩展名不是 .criteria；HyperMesh 尚未读取" "Extension is not .criteria; not read by HyperMesh"]
    } else {
        set ui(CRITERIA_STATUS) [::LocalMeshOptimizer::txt "文件存在；等待 HyperMesh 原生读取验证" "File exists; awaiting native HyperMesh validation"]
    }
}

proc ::LocalMeshOptimizer::showScope {} {
    variable runtime
    if {$runtime(running)} { return }
    if {[catch {::LocalMeshOptimizer::markScope 1} err]} {
        ::LocalMeshOptimizer::setStatus WARN $err
        return
    }
    set ids [hm_getmark elems 1]
    if {[llength $ids] <= 200} {
        catch {*numbersmark elems 1 1}
        catch {*shownumbers elems 1}
    } else {
        catch {hm_usermessage [::LocalMeshOptimizer::txt "范围包含 [llength $ids] 个单元，为避免图形卡顿不显示逐单元编号。" "Scope contains [llength $ids] elements; individual labels are suppressed to keep graphics responsive."]}
    }
    catch {*viewfit}
    catch {hm_usermessage [::LocalMeshOptimizer::txt "已在图形区标记当前处理范围。" "Current scope was marked in the graphics area."]}
}

proc ::LocalMeshOptimizer::markScope {markId} {
    variable ui
    variable runtime
    catch {*clearmark elems $markId}
    switch -- $ui(SCOPE_TYPE) {
        components {
            if {[llength $runtime(selectedComponents)] == 0} { error [::LocalMeshOptimizer::txt "请先选择组件。" "Select components first."] }
            if {[catch {eval *createmark elems $markId "by comp id" $runtime(selectedComponents)} err]} {
                error [::LocalMeshOptimizer::txt "无法按组件建立单元范围：$err" "Could not create element scope from components: $err"]
            }
        }
        elements {
            if {[llength $runtime(selectedElements)] == 0} { error [::LocalMeshOptimizer::txt "请先选择单元。" "Select elements first."] }
            eval *createmark elems $markId $runtime(selectedElements)
        }
        displayed { *createmark elems $markId displayed }
        all { *createmark elems $markId all }
        default { error "Unknown scope: $ui(SCOPE_TYPE)" }
    }
    set ids [hm_getmark elems $markId]
    if {[llength $ids] == 0} { error [::LocalMeshOptimizer::txt "当前范围没有单元。" "The current scope contains no elements."] }
    return $ids
}

proc ::LocalMeshOptimizer::validateInputs {} {
    variable ui
    if {![file isfile $ui(CRITERIA_PATH)]} { error [::LocalMeshOptimizer::txt "criteria 文件不存在。" "Criteria file does not exist."] }
    foreach key {ADJACENCY_LAYERS MAX_ROUNDS MAX_REGION_ELEMENTS MAX_REGION_SECONDS} {
        if {![string is integer -strict $ui($key)]} { error "$key must be an integer" }
    }
    if {$ui(ADJACENCY_LAYERS) < 1 || $ui(ADJACENCY_LAYERS) > 3} { error "ADJACENCY_LAYERS must be 1..3" }
    if {$ui(MAX_ROUNDS) < 1 || $ui(MAX_ROUNDS) > 10} { error "MAX_ROUNDS must be 1..10" }
    if {$ui(MAX_REGION_ELEMENTS) < 1 || $ui(MAX_REGION_SECONDS) < 1} { error "Region limits must be positive" }
    foreach key {FEATURE_ANGLE SKINNY_TRIANGLE_RATIO NARROW_QUAD_RATIO NARROW_TARGET_ASPECT CONTROLLED_EDGE_GROWTH} {
        if {![string is double -strict $ui($key)] || $ui($key) <= 0.0} { error "$key must be a positive number" }
    }
    if {$ui(CONTROLLED_EDGE_GROWTH) <= 1.0} { error "CONTROLLED_EDGE_GROWTH must be greater than 1.0" }
    return 1
}

proc ::LocalMeshOptimizer::hmVersion {} {
    foreach command {
        {hm_info -appinfo VERSION}
        {hm_info -appinfo ALTAIR_VERSION}
    } {
        if {![catch {set value [uplevel #0 $command]}] && $value ne ""} { return $value }
    }
    return [::LocalMeshOptimizer::txt "未知" "Unknown"]
}

proc ::LocalMeshOptimizer::criteriaIsLoaded {} {
    variable runtime
    variable ui
    if {![file isfile $ui(CRITERIA_PATH)]} { return 0 }
    set path [file normalize $ui(CRITERIA_PATH)]
    return [expr {$runtime(criteriaLoadedPath) eq $path && $runtime(criteriaLoadedMtime) == [file mtime $path]}]
}

proc ::LocalMeshOptimizer::readCriteria {{force 0}} {
    variable runtime
    variable ui
    set path [file normalize $ui(CRITERIA_PATH)]
    set mtime [file mtime $path]
    if {!$force && $runtime(criteriaLoadedPath) eq $path && $runtime(criteriaLoadedMtime) == $mtime} {
        ::LocalMeshOptimizer::log INFO "criteria context reused: $path" - - *readqualitycriteria 0 0 0
        return 0
    }
    set started [clock milliseconds]
    if {[catch {uplevel #0 [list *readqualitycriteria $path]} err opts]} {
        set detail $err
        if {[dict exists $opts -errorinfo]} { append detail "\n" [dict get $opts -errorinfo] }
        ::LocalMeshOptimizer::log ERROR "HyperMesh criteria read failed: $detail" - - *readqualitycriteria 1 0
        error [::LocalMeshOptimizer::txt "HyperMesh 读取 criteria 失败：$err" "HyperMesh could not read criteria: $err"]
    }
    set elapsed [expr {([clock milliseconds] - $started) / 1000.0}]
    ::LocalMeshOptimizer::log INFO "criteria loaded: $path" - - *readqualitycriteria 1 1 $elapsed
    set ui(CRITERIA_STATUS) [::LocalMeshOptimizer::txt "HyperMesh 读取成功" "Read successfully by HyperMesh"]
    set runtime(criteriaLoadedPath) $path
    set runtime(criteriaLoadedMtime) $mtime
    ::LocalMeshOptimizer::rememberCriteria $path
    return 1
}

proc ::LocalMeshOptimizer::nativeQualityCheck {scopeIds {progressBase 15.0} {progressSpan 10.0} {progressContext ""}} {
    if {[llength $scopeIds] == 0} { error "Quality check received an empty element list" }
    catch {*clearmark elems 1}
    catch {*clearmark elems 2}
    eval *createmark elems 1 $scopeIds
    set contextPrefix [expr {$progressContext eq "" ? "" : "$progressContext；"}]
    if {[::LocalMeshOptimizer::criteriaIsLoaded]} {
        set criteriaStage [::LocalMeshOptimizer::txt "复用已加载的 criteria" "Reusing loaded criteria"]
    } else {
        set criteriaStage [::LocalMeshOptimizer::txt "正在读取 criteria" "Reading criteria"]
    }
    catch {::LocalMeshOptimizer::optimizationProgress $progressBase $criteriaStage "$contextPrefix[::LocalMeshOptimizer::txt "随后执行 HyperMesh 原生质量命令" "A native HyperMesh quality command follows"]" 1}
    ::LocalMeshOptimizer::readCriteria
    set started [clock milliseconds]
    set checkPct [expr {double($progressBase) + double($progressSpan)}]
    catch {::LocalMeshOptimizer::optimizationProgress $checkPct [::LocalMeshOptimizer::txt "HyperMesh 正在检查质量" "HyperMesh is checking quality"] "$contextPrefix[::LocalMeshOptimizer::txt "原生命令执行中，请等待" "Native command is running; please wait"]" 1}
    if {[catch {set info [hm_getelementsqualityinfo 1 1 2]} err opts]} {
        set detail $err
        if {[dict exists $opts -errorinfo]} { append detail "\n" [dict get $opts -errorinfo] }
        ::LocalMeshOptimizer::log ERROR "Native quality check failed: $detail" - - hm_getelementsqualityinfo [llength $scopeIds] 0
        error [::LocalMeshOptimizer::txt "HyperMesh 原生质量检查失败：$err" "Native HyperMesh quality check failed: $err"]
    }
    if {[catch {set failedIds [hm_getmark elems 2]} markErr]} {
        error [::LocalMeshOptimizer::txt "无法读取 HyperMesh 失败单元 mark：$markErr" "Could not read the HyperMesh failed-element mark: $markErr"]
    }
    set failedIds [::LocalMeshOptimizer::uniq $failedIds]
    set reportedFailed ""
    if {[llength $info] >= 2 && [string is integer -strict [lindex $info 1]]} { set reportedFailed [lindex $info 1] }
    if {$reportedFailed ne "" && $reportedFailed != [llength $failedIds]} {
        error [::LocalMeshOptimizer::txt \
            "质量摘要失败数 ($reportedFailed) 与失败 mark 数 ([llength $failedIds]) 不一致，已停止，避免假判定。" \
            "Quality summary ($reportedFailed) and failed mark ([llength $failedIds]) disagree; stopped to avoid a false result."]
    }
    set elapsed [expr {([clock milliseconds] - $started) / 1000.0}]
    ::LocalMeshOptimizer::log INFO "native quality check complete detail=$info" - - hm_getelementsqualityinfo [llength $scopeIds] [llength $failedIds] $elapsed
    return [dict create checked [llength $scopeIds] failedIds $failedIds detail $info]
}

proc ::LocalMeshOptimizer::modelPath {} {
    foreach command {
        {hm_info currentfile}
        {hm_info -appinfo CURRENTFILE}
    } {
        if {![catch {set value [uplevel #0 $command]}] && $value ne ""} { return [file normalize $value] }
    }
    return ""
}

proc ::LocalMeshOptimizer::createTaskDir {} {
    variable SCRIPT_DIR
    variable runtime
    set root [file dirname $SCRIPT_DIR]
    set stamp [clock format [clock seconds] -format {%Y%m%d_%H%M%S}]
    set suffix [pid]
    set runtime(taskDir) [file normalize [file join $root temp local_mesh_optimizer "task_${stamp}_${suffix}"]]
    set probe [file join $runtime(taskDir) .write_test]
    ::HWFlow::writeTextFile $probe ok
    file delete -force $probe
    return $runtime(taskDir)
}

proc ::LocalMeshOptimizer::writeIdFile {path ids} {
    ::HWFlow::writeTextFile $path [join [::LocalMeshOptimizer::uniq $ids] "\n"]
}

proc ::LocalMeshOptimizer::csvQuote {value} {
    set value [string map [list "\"" "\"\""] $value]
    return "\"$value\""
}

proc ::LocalMeshOptimizer::cancelRequested {} {
    variable runtime
    if {[llength [info commands ::HWFlow::progressCancelled]] > 0 && [::HWFlow::progressCancelled]} { return 1 }
    if {$runtime(taskDir) ne "" && [file exists [file join $runtime(taskDir) cancel.flag]]} { return 1 }
    return 0
}

proc ::LocalMeshOptimizer::exportScope {scopeIds} {
    variable runtime
    set connectivityPath [file join $runtime(taskDir) element_connectivity.csv]
    set coordinatePath [file join $runtime(taskDir) node_coordinates.csv]
    set connectivityStream [open $connectivityPath w]
    set coordinateStream [open $coordinatePath w]
    fconfigure $connectivityStream -encoding utf-8 -translation lf -buffering full -buffersize 65536
    fconfigure $coordinateStream -encoding utf-8 -translation lf -buffering full -buffersize 65536
    array set seenNodes {}
    set totalElements [llength $scopeIds]
    set elementIndex 0
    set exportedElements 0
    set code [catch {
        puts $connectivityStream "element_id,component_id,n1,n2,n3,n4"
        puts $coordinateStream "node_id,x,y,z"
        foreach elementId $scopeIds {
            incr elementIndex
            if {[catch {set nodes [hm_getvalue elems id=$elementId dataname=nodes]}] || [llength $nodes] < 3 || [llength $nodes] > 4} {
                if {$elementIndex % 500 == 0} {
                    set pct [expr {40.0 + 25.0 * $elementIndex / double($totalElements)}]
                    catch {::HWFlow::progressUpdate $pct [::LocalMeshOptimizer::txt "正在导出 2D 连接关系" "Exporting 2D connectivity"] "$elementIndex/$totalElements"}
                }
                continue
            }
            set componentId 0
            if {[catch {set componentId [hm_getvalue elems id=$elementId dataname=collectorid]}] || $componentId eq ""} {
                foreach dataname {componentid compid} {
                    if {![catch {set value [hm_getvalue elems id=$elementId dataname=$dataname]}] && $value ne ""} { set componentId $value; break }
                }
            }
            set row [list $elementId $componentId]
            foreach node [lrange $nodes 0 3] { lappend row $node; set seenNodes($node) 1 }
            while {[llength $row] < 6} { lappend row "" }
            puts $connectivityStream [join $row ,]
            incr exportedElements
            if {$elementIndex % 500 == 0 || $elementIndex == $totalElements} {
                set pct [expr {40.0 + 25.0 * $elementIndex / double($totalElements)}]
                catch {::HWFlow::progressUpdate $pct [::LocalMeshOptimizer::txt "正在导出 2D 连接关系" "Exporting 2D connectivity"] [::LocalMeshOptimizer::txt "$elementIndex/$totalElements；有效壳单元=$exportedElements" "$elementIndex/$totalElements; valid shells=$exportedElements"]}
                if {[::LocalMeshOptimizer::cancelRequested]} { error "cancelled during connectivity export" }
            }
        }
        set nodeIds [array names seenNodes]
        set totalNodes [llength $nodeIds]
        set nodeIndex 0
        set exportedNodes 0
        foreach nodeId $nodeIds {
            incr nodeIndex
            set xyz ""
            catch {set xyz [hm_nodevalue $nodeId]}
            if {[llength $xyz] < 3} {
                if {[catch {set x [hm_getvalue nodes id=$nodeId dataname=x]}] ||
                    [catch {set y [hm_getvalue nodes id=$nodeId dataname=y]}] ||
                    [catch {set z [hm_getvalue nodes id=$nodeId dataname=z]}]} { continue }
                set xyz [list $x $y $z]
            }
            puts $coordinateStream [join [list $nodeId [lindex $xyz 0] [lindex $xyz 1] [lindex $xyz 2]] ,]
            incr exportedNodes
            if {$nodeIndex % 1000 == 0 || $nodeIndex == $totalNodes} {
                set pct [expr {65.0 + 18.0 * $nodeIndex / double($totalNodes)}]
                catch {::HWFlow::progressUpdate $pct [::LocalMeshOptimizer::txt "正在导出节点坐标" "Exporting node coordinates"] "$nodeIndex/$totalNodes"}
                if {[::LocalMeshOptimizer::cancelRequested]} { error "cancelled during node export" }
            }
        }
        if {$exportedElements == 0} { error [::LocalMeshOptimizer::txt "范围内没有可导出的三角形/四边形 2D 单元。" "No exportable tria/quad 2D elements were found in the scope."] }
    } err opts]
    catch {close $connectivityStream}
    catch {close $coordinateStream}
    if {$code} {
        catch {file delete -force $connectivityPath $coordinatePath}
        return -options $opts $err
    }
    # Header-only file is deliberate until protected-edge extraction has been
    # validated in HM2019. Component crossing is independently blocked in Python.
    ::HWFlow::writeTextFile [file join $runtime(taskDir) protected_edges.csv] "n1,n2\n"
    ::LocalMeshOptimizer::writeIdFile [file join $runtime(taskDir) protected_nodes.txt] $runtime(userAnchorNodes)
    return [dict create elements $exportedElements nodes $exportedNodes]
}

proc ::LocalMeshOptimizer::jsonEscape {value} {
    return [string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $value]
}

proc ::LocalMeshOptimizer::jsonString {value} { return "\"[::LocalMeshOptimizer::jsonEscape $value]\"" }
proc ::LocalMeshOptimizer::jsonBool {value} { return [expr {$value ? "true" : "false"}] }

proc ::LocalMeshOptimizer::reportDir {} {
    variable SCRIPT_DIR
    variable ui
    variable runtime
    if {[string trim $ui(REPORT_DIR)] ne ""} { return [file normalize $ui(REPORT_DIR)] }
    set model [::LocalMeshOptimizer::modelPath]
    set stamp [clock format [clock seconds] -format {%Y%m%d_%H%M%S}]
    if {$model ne ""} { set base [file dirname $model] } else { set base [file dirname [file dirname $SCRIPT_DIR]] }
    return [file normalize [file join $base "LocalMeshOptimizer_Report_$stamp"]]
}

proc ::LocalMeshOptimizer::writeTask {scopeIds failedIds} {
    variable ui
    variable runtime
    set model [::LocalMeshOptimizer::modelPath]
    set report [::LocalMeshOptimizer::reportDir]
    set lines [list \
        "{" \
        "  \"model_path\": [::LocalMeshOptimizer::jsonString $model]," \
        "  \"criteria_path\": [::LocalMeshOptimizer::jsonString [file normalize $ui(CRITERIA_PATH)]]," \
        "  \"scope_type\": [::LocalMeshOptimizer::jsonString $ui(SCOPE_TYPE)]," \
        "  \"optimization_level\": [::LocalMeshOptimizer::jsonString $ui(OPTIMIZATION_LEVEL)]," \
        "  \"adjacency_layers\": $ui(ADJACENCY_LAYERS)," \
        "  \"max_rounds\": $ui(MAX_ROUNDS)," \
        "  \"feature_angle\": $ui(FEATURE_ANGLE)," \
        "  \"max_region_elements\": $ui(MAX_REGION_ELEMENTS)," \
        "  \"max_region_seconds\": $ui(MAX_REGION_SECONDS)," \
        "  \"skinny_triangle_ratio\": $ui(SKINNY_TRIANGLE_RATIO)," \
        "  \"narrow_quad_ratio\": $ui(NARROW_QUAD_RATIO)," \
        "  \"narrow_target_aspect\": $ui(NARROW_TARGET_ASPECT)," \
        "  \"allow_controlled_free_edge_move\": [::LocalMeshOptimizer::jsonBool $ui(ALLOW_CONTROLLED_FREE_EDGE_MOVE)]," \
        "  \"checked_elements\": [llength $scopeIds]," \
        "  \"failed_before\": [llength $runtime(failedElements)]," \
        "  \"optimizable_failed_before\": [llength $failedIds]," \
        "  \"exclude_washer_elements\": [::LocalMeshOptimizer::jsonBool $ui(EXCLUDE_WASHER_ELEMENTS)]," \
        "  \"washer_elements_excluded\": [llength $runtime(washerElements)]," \
        "  \"washer_failed_excluded\": [llength $runtime(washerExcludedFailed)]," \
        "  \"report_dir\": [::LocalMeshOptimizer::jsonString $report]," \
        "  \"protection\": {" \
        "    \"free_edges\": [::LocalMeshOptimizer::jsonBool $ui(PROTECT_FREE_EDGES)]," \
        "    \"component_boundaries\": [::LocalMeshOptimizer::jsonBool $ui(PROTECT_COMPONENT_BOUNDARIES)]," \
        "    \"hole_edges\": [::LocalMeshOptimizer::jsonBool $ui(PROTECT_HOLE_EDGES)]," \
        "    \"feature_edges\": [::LocalMeshOptimizer::jsonBool $ui(PROTECT_FEATURE_EDGES)]," \
        "    \"rigid_connection_nodes\": [::LocalMeshOptimizer::jsonBool $ui(PROTECT_RIGID_NODES)]," \
        "    \"weld_connection_nodes\": [::LocalMeshOptimizer::jsonBool $ui(PROTECT_WELD_NODES)]," \
        "    \"user_anchor_nodes\": [::LocalMeshOptimizer::jsonBool $ui(PROTECT_USER_NODES)]," \
        "    \"no_cross_component_movement\": [::LocalMeshOptimizer::jsonBool $ui(NO_CROSS_COMPONENT_MOVEMENT)]," \
        "    \"preserve_geometry_association\": [::LocalMeshOptimizer::jsonBool $ui(PRESERVE_GEOMETRY_ASSOCIATION)]" \
        "  }" \
        "}"]
    set path [file join $runtime(taskDir) task.json]
    ::HWFlow::writeTextFile $path [join $lines "\n"]
    return $path
}

proc ::LocalMeshOptimizer::pythonCandidates {} {
    variable SCRIPT_DIR
    variable ui
    set candidates {}
    if {[string trim $ui(PYTHON_COMMAND)] ne ""} { lappend candidates [list $ui(PYTHON_COMMAND)] }
    if {$::tcl_platform(platform) eq "windows"} {
        set bundled [file normalize [file join $SCRIPT_DIR .. runtime python windows-x64 python.exe]]
        if {[file isfile $bundled]} { lappend candidates [list $bundled] }
    }
    if {$::tcl_platform(platform) eq "windows"} { lappend candidates [list py -3] }
    lappend candidates [list python3] [list python]
    return $candidates
}

proc ::LocalMeshOptimizer::windowlessPythonCommand {candidate} {
    if {$::tcl_platform(platform) ne "windows"} { return $candidate }
    set executable [lindex $candidate 0]
    set arguments [lrange $candidate 1 end]
    set tail [string tolower [file tail $executable]]
    if {$tail in {pythonw.exe pythonw pyw.exe pyw}} { return $candidate }
    if {$tail in {py.exe py}} {
        set pyw [auto_execok pyw]
        if {$pyw eq ""} { set pyw [auto_execok pyw.exe] }
        if {$pyw ne ""} { return [concat [list $pyw] $arguments] }
        return ""
    }
    set directory [file dirname $executable]
    foreach name {pythonw.exe pythonw} {
        set windowless [file join $directory $name]
        if {[file isfile $windowless]} { return [concat [list $windowless] $arguments] }
    }
    return ""
}

proc ::LocalMeshOptimizer::probePython {candidate} {
    variable runtime
    set launch [::LocalMeshOptimizer::windowlessPythonCommand $candidate]
    if {$launch eq ""} { return "" }
    if {$runtime(taskDir) ne "" && [file isdirectory $runtime(taskDir)]} {
        set directory $runtime(taskDir)
    } else {
        set directory [file normalize [pwd]]
    }
    set marker [file join $directory ".python_probe_[pid].txt"]
    catch {file delete -force $marker}
    set probeScript {import csv,dataclasses,html,json,logging,pathlib,tempfile,sys; pathlib.Path(sys.argv[1]).write_text("%d.%d" % sys.version_info[:2], encoding="utf-8")}
    set command [concat $launch [list -c $probeScript $marker]]
    if {[catch {exec {*}$command &} err]} {
        catch {file delete -force $marker}
        return ""
    }
    set started [clock milliseconds]
    while {![file isfile $marker] && [clock milliseconds] - $started < 5000} {
        after 50 ::LocalMeshOptimizer::waitTick
        vwait ::LocalMeshOptimizer::runtime(pythonWaitTick)
    }
    if {![file isfile $marker]} {
        catch {file delete -force $marker}
        return ""
    }
    set version [string trim [::HWFlow::readTextFile $marker]]
    catch {file delete -force $marker}
    if {![regexp {^3\.[0-9]+$} $version]} { return "" }
    return $launch
}

proc ::LocalMeshOptimizer::resolvePython {} {
    variable runtime
    if {$runtime(pythonCommand) ne ""} { return $runtime(pythonCommand) }
    foreach candidate [::LocalMeshOptimizer::pythonCandidates] {
        set launch [::LocalMeshOptimizer::probePython $candidate]
        if {$launch ne ""} {
            set runtime(pythonCommand) $launch
            return $launch
        }
    }
    error [::LocalMeshOptimizer::txt "未找到可后台运行的 Python 3。请确认包内 pythonw.exe 完整，或在高级设置中指定带 pythonw.exe 的解释器目录。" "No windowless Python 3 runtime was found. Verify bundled pythonw.exe or configure an interpreter that includes pythonw.exe."]
}

proc ::LocalMeshOptimizer::waitTick {} {
    variable runtime
    set runtime(pythonWaitTick) [expr {$runtime(pythonWaitTick) + 1}]
}

proc ::LocalMeshOptimizer::pythonProgressPulse {stage} {
    variable runtime
    set path [file join $runtime(taskDir) progress.json]
    if {![file isfile $path]} { return }
    set data [::HWFlow::readTextFile $path]
    if {![regexp {"percent"\s*:\s*([0-9.]+)} $data -> pythonPercent]} { return }
    if {$stage eq "build-regions"} {
        set percent [expr {83.0 + 0.15 * double($pythonPercent)}]
    } else {
        set percent [expr {96.0 + 0.03 * double($pythonPercent)}]
    }
    catch {::LocalMeshOptimizer::optimizationProgress $percent [::LocalMeshOptimizer::txt "Python 后台处理中" "Python background processing"] [::LocalMeshOptimizer::txt "阶段：$stage；Python=$pythonPercent%" "Stage: $stage; Python=$pythonPercent%"] 0}
}

proc ::LocalMeshOptimizer::runPython {stage taskPath} {
    variable PYTHON_ENTRY
    variable runtime
    if {![file isfile $PYTHON_ENTRY]} { error "Python controller not found: $PYTHON_ENTRY" }
    set python [::LocalMeshOptimizer::resolvePython]
    set safeStage [string map [list "-" "_"] $stage]
    set statusPath [file join $runtime(taskDir) "python_${safeStage}_status.json"]
    set stdoutPath [file join $runtime(taskDir) "python_${safeStage}_stdout.log"]
    set stderrPath [file join $runtime(taskDir) "python_${safeStage}_stderr.log"]
    catch {file delete -force $statusPath $stdoutPath $stderrPath}
    set command [concat $python [list $PYTHON_ENTRY --task $taskPath --stage $stage --status-file $statusPath]]
    ::LocalMeshOptimizer::log INFO "starting Python stage=$stage" - - python 1 0
    set started [clock milliseconds]
    if {[catch {set runtime(pythonPid) [exec {*}$command > $stdoutPath 2> $stderrPath &]} launchErr opts]} {
        ::LocalMeshOptimizer::log ERROR "Python background launch failed: $launchErr" - - python 1 0
        error [::LocalMeshOptimizer::txt "Python 后台进程启动失败：$launchErr" "Could not launch the Python background process: $launchErr"]
    }
    set timeoutMs 1800000
    set stderrObservedAt 0
    while {![file isfile $statusPath]} {
        if {[clock milliseconds] - $started > $timeoutMs} {
            error [::LocalMeshOptimizer::txt "Python 后台阶段超时。请检查 $stderrPath" "Python background stage timed out. Check $stderrPath"]
        }
        if {[file isfile $stderrPath] && [file size $stderrPath] > 0} {
            if {$stderrObservedAt == 0} { set stderrObservedAt [clock milliseconds] }
            if {[clock milliseconds] - $stderrObservedAt > 2000} {
                set detail [string trim [::HWFlow::readTextFile $stderrPath]]
                error [::LocalMeshOptimizer::txt "Python 后台进程异常退出：$detail" "The Python background process exited abnormally: $detail"]
            }
        } else {
            set stderrObservedAt 0
        }
        after 100 ::LocalMeshOptimizer::waitTick
        vwait ::LocalMeshOptimizer::runtime(pythonWaitTick)
        if {$runtime(pythonWaitTick) % 5 == 0} { ::LocalMeshOptimizer::pythonProgressPulse $stage }
    }
    set statusText [::HWFlow::readTextFile $statusPath]
    if {![regexp {"exit_code"\s*:\s*([0-9]+)} $statusText -> exitCode]} {
        error [::LocalMeshOptimizer::txt "Python 状态文件损坏：$statusPath" "Python status file is invalid: $statusPath"]
    }
    if {$exitCode != 0} {
        set detail ""
        if {[file isfile $stderrPath]} { set detail [string trim [::HWFlow::readTextFile $stderrPath]] }
        ::LocalMeshOptimizer::log ERROR "Python stage failed exit=$exitCode: $detail" - - python 1 0
        error [::LocalMeshOptimizer::txt "Python 阶段 $stage 失败（返回码 $exitCode）。详见：$stderrPath" "Python stage $stage failed (exit $exitCode). See: $stderrPath"]
    }
    set elapsed [expr {([clock milliseconds] - $started) / 1000.0}]
    ::LocalMeshOptimizer::log INFO "Python background stage=$stage complete pid=$runtime(pythonPid)" - - python 1 1 $elapsed
    return 1
}

proc ::LocalMeshOptimizer::checkQuality {} {
    variable runtime
    variable ui
    if {$runtime(running)} {
        ::LocalMeshOptimizer::setStatus WARN [::LocalMeshOptimizer::txt "已有任务正在运行。" "A task is already running."]
        return 0
    }
    set runtime(running) 1
    set runtime(planReady) 0
    set runtime(progressStartedMs) [clock milliseconds]
    set progressOpened 0
    set code [catch {
        ::LocalMeshOptimizer::validateInputs
        set progressOpened [::HWFlow::progressOpen "Local Mesh Optimizer" [::LocalMeshOptimizer::txt "正在准备质量检查..." "Preparing quality check..."] 1]
        catch {::HWFlow::progressUpdate 5.0 [::LocalMeshOptimizer::txt "正在建立处理范围" "Building the processing scope"] "" 1}
        set scopeIds [::LocalMeshOptimizer::markScope 1]
        ::LocalMeshOptimizer::createTaskDir
        set quality [::LocalMeshOptimizer::nativeQualityCheck $scopeIds]
        set runtime(failedElements) [dict get $quality failedIds]
        set runtime(checkedElements) [dict get $quality checked]
        set runtime(washerElements) [::LocalMeshOptimizer::washerElementsInScope $scopeIds]
        set runtime(washerExcludedFailed) [::LocalMeshOptimizer::listIntersection $runtime(failedElements) $runtime(washerElements)]
        set runtime(optimizationFailedElements) [::LocalMeshOptimizer::listDifference $runtime(failedElements) $runtime(washerElements)]
        ::LocalMeshOptimizer::writeIdFile [file join $runtime(taskDir) failed_all_elements.txt] $runtime(failedElements)
        ::LocalMeshOptimizer::writeIdFile [file join $runtime(taskDir) washer_excluded_elements.txt] $runtime(washerElements)
        ::LocalMeshOptimizer::writeIdFile [file join $runtime(taskDir) washer_excluded_failed.txt] $runtime(washerExcludedFailed)
        ::LocalMeshOptimizer::writeIdFile [file join $runtime(taskDir) failed_elements.txt] $runtime(optimizationFailedElements)
        catch {::HWFlow::progressUpdate 40.0 [::LocalMeshOptimizer::txt "正在导出局部分析数据" "Exporting local-analysis data"] [::LocalMeshOptimizer::txt "采用分块写入，界面会持续更新。" "Data is streamed in chunks while the UI remains responsive."] 1}
        ::LocalMeshOptimizer::exportScope $scopeIds
        set taskPath [::LocalMeshOptimizer::writeTask $scopeIds $runtime(optimizationFailedElements)]
        catch {::HWFlow::progressUpdate 83.0 [::LocalMeshOptimizer::txt "正在启动 Python 后台分析" "Starting Python background analysis"] "" 1}
        ::LocalMeshOptimizer::runPython build-regions $taskPath
        set runtime(checkedCriteriaPath) [file normalize $ui(CRITERIA_PATH)]
        set runtime(checkedCriteriaMtime) [file mtime $runtime(checkedCriteriaPath)]
        set runtime(checkedScopeType) $ui(SCOPE_TYPE)
        set runtime(checkedScopeIds) [::LocalMeshOptimizer::uniq $scopeIds]
        set runtime(checkedPlanSettings) [::LocalMeshOptimizer::planSettingsSignature]
        set runtime(planReady) 1
        set plan [::LocalMeshOptimizer::planSummary]
        set ui(RESULT_TEXT) [::LocalMeshOptimizer::txt \
            "检查及优化规划完成：$runtime(checkedElements) 个单元，失败 [llength $runtime(failedElements)] 个；其中 Washer 人工处理 [llength $runtime(washerExcludedFailed)] 个；自动优化区域 [dict get $plan regions] 个，自动动作 [expr {[dict get $plan actions]-[dict get $plan manual]}] 个，其他人工复核 [dict get $plan manual] 个。任务目录：$runtime(taskDir)" \
            "Check and optimization planning complete: $runtime(checkedElements) elements, [llength $runtime(failedElements)] failed; [llength $runtime(washerExcludedFailed)] washer failures reserved for manual work; [dict get $plan regions] automatic regions, [expr {[dict get $plan actions]-[dict get $plan manual]}] automatic actions, [dict get $plan manual] other manual reviews. Task: $runtime(taskDir)"]
        ::LocalMeshOptimizer::saveState
    } err opts]
    set runtime(running) 0
    if {$progressOpened} {
        if {$code} {
            catch {::HWFlow::progressFinish [::LocalMeshOptimizer::txt "质量检查未完成；详情已写入状态和日志。" "Quality check did not complete; details are in status and log."] 100.0}
        } else {
            catch {::HWFlow::progressFinish [::LocalMeshOptimizer::txt "质量检查完成。" "Quality check complete."] 100.0}
        }
    }
    if {$code} {
        set ui(RESULT_TEXT) [::LocalMeshOptimizer::txt "检查失败：$err" "Check failed: $err"]
        if {[string match -nocase "*cancel*" $err]} {
            ::LocalMeshOptimizer::setStatus INFO [::LocalMeshOptimizer::txt "质量检查已取消；模型未被优化。" "Quality check was cancelled; the model was not optimized."]
        } else {
            ::LocalMeshOptimizer::setStatus ERROR $ui(RESULT_TEXT)
        }
        return 0
    }
    ::LocalMeshOptimizer::setStatus INFO $ui(RESULT_TEXT)
    return 1
}

proc ::LocalMeshOptimizer::showFailed {} {
    variable runtime
    if {$runtime(running)} { return }
    if {[llength $runtime(failedElements)] == 0} {
        ::LocalMeshOptimizer::setStatus INFO [::LocalMeshOptimizer::txt "当前没有可显示的失败单元，请先检查质量。" "No failed elements are available; run Check Quality first."]
        return
    }
    catch {*clearmark elems 1}
    eval *createmark elems 1 $runtime(failedElements)
    if {[llength $runtime(failedElements)] <= 200} {
        catch {*numbersmark elems 1 1}
        catch {*shownumbers elems 1}
    } else {
        catch {hm_usermessage [::LocalMeshOptimizer::txt "失败单元较多，已跳过逐单元编号显示。" "Many failed elements were found; individual labels were skipped."]}
    }
    catch {*viewfit}
}

proc ::LocalMeshOptimizer::showOptimized {} {
    variable runtime
    if {$runtime(running)} { return }
    if {[llength $runtime(optimizedElements)] == 0} {
        ::LocalMeshOptimizer::setStatus INFO [::LocalMeshOptimizer::txt "当前没有已优化单元。" "No optimized elements are currently recorded."]
        return
    }
    catch {*clearmark elems 1}
    eval *createmark elems 1 $runtime(optimizedElements)
    if {[llength $runtime(optimizedElements)] <= 200} {
        catch {*numbersmark elems 1 1}
        catch {*shownumbers elems 1}
    } else {
        catch {hm_usermessage [::LocalMeshOptimizer::txt "已优化单元较多，已跳过逐单元编号显示。" "Many optimized elements are recorded; individual labels were skipped."]}
    }
    catch {*viewfit}
}

proc ::LocalMeshOptimizer::profileStatus {} {
    variable ui
    if {$ui(HM2019_PROFILE) ne "hm2019_recorded"} {
        return [list 0 [::LocalMeshOptimizer::txt \
            "HM2019 修改命令尚未通过 command.cmf 录制验证。为保护模型，优化被禁用；质量检查、区域划分和报告仍可使用。" \
            "HM2019 modification commands have not been verified from command.cmf. Optimization is disabled to protect the model; checking, region building and reports remain available."]]
    }
    # The profile flag records operator validation; command existence is still
    # checked at call time and any error forces a whole-task restore.
    return [list 1 ""]
}

proc ::LocalMeshOptimizer::semicolonIds {text} {
    set ids {}
    foreach value [split $text ";"] {
        if {[string is integer -strict $value] && $value > 0} { lappend ids $value }
    }
    return [::LocalMeshOptimizer::uniq $ids]
}

proc ::LocalMeshOptimizer::listDifference {values excluded} {
    array set skip {}
    foreach value $excluded { set skip($value) 1 }
    set result {}
    foreach value $values { if {![info exists skip($value)]} { lappend result $value } }
    return $result
}

proc ::LocalMeshOptimizer::listIntersection {values included} {
    array set keep {}
    foreach value $included { set keep($value) 1 }
    set result {}
    foreach value $values { if {[info exists keep($value)]} { lappend result $value } }
    return $result
}

proc ::LocalMeshOptimizer::washerLayerCount {} {
    variable SCRIPT_DIR
    set path [file join [file dirname $SCRIPT_DIR] config washer_rules.txt]
    set maximum 2
    if {![file isfile $path]} { return $maximum }
    foreach line [split [::HWFlow::readTextFile $path] "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line] || [string match "hole_dia_min*" $line]} { continue }
        set fields [split $line |]
        if {[llength $fields] > 4 && [string is integer -strict [lindex $fields 4]]} {
            set maximum [expr {max($maximum, int([lindex $fields 4]))}]
        }
    }
    return $maximum
}

proc ::LocalMeshOptimizer::washerElementsInScope {scopeIds} {
    variable SCRIPT_DIR
    variable ui
    if {!$ui(EXCLUDE_WASHER_ELEMENTS)} { return {} }
    if {[llength [info commands ::RB2W::buildGraph]] == 0} {
        set detector [file join $SCRIPT_DIR shell_washer_hole_rbe2.tcl]
        if {![file isfile $detector]} { error "Washer detector module not found: $detector" }
        source $detector
    }
    foreach command {::RB2W::getElemsByComp ::RB2W::buildGraph ::RB2W::findFreeEdgeLoops ::RB2W::isValidHoleLoop ::RB2W::seedElemsFromLoop ::RB2W::validateWasherAndGetDepNodes ::RB2W::expandElementLayers} {
        if {[llength [info commands $command]] == 0} { error "Washer detector command unavailable: $command" }
    }
    array set inScope {}
    array set components {}
    foreach elementId $scopeIds {
        set inScope($elementId) 1
        if {![catch {set componentId [hm_getvalue elems id=$elementId dataname=collectorid]}] && $componentId ne ""} {
            set components($componentId) 1
        }
    }
    set componentIds [array names components]
    set componentTotal [llength $componentIds]
    set layerCount [::LocalMeshOptimizer::washerLayerCount]
    set detected {}
    set oldVerbose $::RB2W::VERBOSE
    set ::RB2W::VERBOSE 0
    set code [catch {
        set componentIndex 0
        foreach componentId $componentIds {
            incr componentIndex
            set pct [expr {30.0 + 8.0 * $componentIndex / double(max(1, $componentTotal))}]
            catch {::LocalMeshOptimizer::optimizationProgress $pct [::LocalMeshOptimizer::txt "正在识别并排除 Washer 网格" "Detecting and excluding washer mesh"] [::LocalMeshOptimizer::txt "组件 $componentIndex/$componentTotal；washer 层数=$layerCount" "Component $componentIndex/$componentTotal; washer layers=$layerCount"] 1}
            set componentElems [::RB2W::getElemsByComp $componentId]
            ::RB2W::buildGraph $componentElems
            foreach loop [::RB2W::findFreeEdgeLoops] {
                set valid [::RB2W::isValidHoleLoop $loop]
                if {![lindex $valid 0]} { continue }
                set seeds [::RB2W::seedElemsFromLoop [dict get $loop edges]]
                set washer [::RB2W::validateWasherAndGetDepNodes $loop $seeds [lindex $valid 1]]
                if {![lindex $washer 0]} { continue }
                foreach elementId [::RB2W::expandElementLayers $seeds $layerCount] {
                    if {[info exists inScope($elementId)]} { lappend detected $elementId }
                }
            }
            if {[::LocalMeshOptimizer::cancelRequested]} { error "cancelled during washer detection" }
        }
    } err opts]
    set ::RB2W::VERBOSE $oldVerbose
    if {$code} { return -options $opts $err }
    return [::LocalMeshOptimizer::uniq $detected]
}

proc ::LocalMeshOptimizer::qualityImproved {before after} {
    set beforeCount [llength [dict get $before failedIds]]
    set afterCount [llength [dict get $after failedIds]]
    if {$afterCount < $beforeCount} { return 1 }
    if {$afterCount > $beforeCount} { return 0 }
    set beforeDetail [dict get $before detail]
    set afterDetail [dict get $after detail]
    if {[llength $beforeDetail] >= 3 && [llength $afterDetail] >= 3 &&
        [string is double -strict [lindex $beforeDetail 2]] && [string is double -strict [lindex $afterDetail 2]]} {
        return [expr {double([lindex $afterDetail 2]) < double([lindex $beforeDetail 2]) - 1.0e-9}]
    }
    return 0
}

proc ::LocalMeshOptimizer::qualityWorsened {before after {topologyAllowance 0}} {
    set beforeCount [llength [dict get $before failedIds]]
    set afterCount [llength [dict get $after failedIds]]
    if {$afterCount > ($beforeCount + $topologyAllowance)} { return 1 }
    if {$afterCount < $beforeCount} { return 0 }
    if {$topologyAllowance > 0} {
        # A split/collapse can replace entity IDs without expanding the
        # physical failed area. Aggregate QI values are not comparable across
        # that topology change; defer to the final native whole-scope guard.
        return 0
    }
    set beforeDetail [dict get $before detail]
    set afterDetail [dict get $after detail]
    if {[llength $beforeDetail] >= 3 && [llength $afterDetail] >= 3 &&
        [string is double -strict [lindex $beforeDetail 2]] && [string is double -strict [lindex $afterDetail 2]]} {
        return [expr {double([lindex $afterDetail 2]) > double([lindex $beforeDetail 2]) + 1.0e-9}]
    }
    # Equal failure counts with no comparable native QI are inconclusive, not
    # deterioration.  The whole-scope HyperMesh guard still runs at the end.
    return 0
}

proc ::LocalMeshOptimizer::nodeCoordinateMap {nodeIds} {
    set result [dict create]
    set total [llength $nodeIds]
    set index 0
    foreach nodeId $nodeIds {
        incr index
        if {[catch {set coordinate [hm_nodevalue $nodeId]}] || [llength $coordinate] < 3} {
            if {[catch {set coordinate [list \
                [hm_getvalue nodes id=$nodeId dataname=x] \
                [hm_getvalue nodes id=$nodeId dataname=y] \
                [hm_getvalue nodes id=$nodeId dataname=z]]}]} {
                error "Could not read anchor node coordinates: $nodeId"
            }
        }
        dict set result $nodeId [lrange $coordinate 0 2]
        if {$index % 500 == 0} {
            catch {::HWFlow::progressAppend [::LocalMeshOptimizer::txt "读取保护节点：$index/$total" "Reading protected nodes: $index/$total"]}
            catch {update idletasks}
            if {[::LocalMeshOptimizer::cancelRequested]} { error "cancel requested" }
        }
    }
    return $result
}

proc ::LocalMeshOptimizer::movedAnchorNodes {before tolerance} {
    set moved {}
    set nodeIds [dict keys $before]
    set total [llength $nodeIds]
    set index 0
    foreach nodeId $nodeIds {
        incr index
        set old [dict get $before $nodeId]
        if {[catch {set current [hm_nodevalue $nodeId]}] || [llength $current] < 3} {
            if {[catch {set current [list \
                [hm_getvalue nodes id=$nodeId dataname=x] \
                [hm_getvalue nodes id=$nodeId dataname=y] \
                [hm_getvalue nodes id=$nodeId dataname=z]]}]} {
                lappend moved $nodeId
                continue
            }
        }
        set dx [expr {double([lindex $current 0]) - double([lindex $old 0])}]
        set dy [expr {double([lindex $current 1]) - double([lindex $old 1])}]
        set dz [expr {double([lindex $current 2]) - double([lindex $old 2])}]
        if {sqrt($dx*$dx + $dy*$dy + $dz*$dz) > $tolerance} { lappend moved $nodeId }
        if {$index % 500 == 0} {
            catch {::HWFlow::progressAppend [::LocalMeshOptimizer::txt "核验保护节点：$index/$total" "Verifying protected nodes: $index/$total"]}
            catch {update idletasks}
            if {[::LocalMeshOptimizer::cancelRequested]} { error "cancel requested" }
        }
    }
    return $moved
}

proc ::LocalMeshOptimizer::readRegionTasks {} {
    variable runtime
    set path [file join $runtime(taskDir) region_tasks.csv]
    if {![file isfile $path]} { error "Region task file not found: $path" }
    set lines [split [::HWFlow::readTextFile $path] "\n"]
    set regions {}
    foreach line [lrange $lines 1 end] {
        if {[string trim $line] eq ""} { continue }
        set fields [split $line ,]
        if {[llength $fields] < 5} { error "Damaged region task row: $line" }
        lappend regions [dict create \
            regionId [lindex $fields 0] \
            failed [::LocalMeshOptimizer::semicolonIds [lindex $fields 1]] \
            expanded [::LocalMeshOptimizer::semicolonIds [lindex $fields 2]] \
            components [::LocalMeshOptimizer::semicolonIds [lindex $fields 3]] \
            anchors [::LocalMeshOptimizer::semicolonIds [lindex $fields 4]]]
    }
    return $regions
}

proc ::LocalMeshOptimizer::readOptimizationActions {} {
    variable runtime
    set path [file join $runtime(taskDir) optimization_actions.csv]
    set result [dict create]
    if {![file isfile $path]} { return $result }
    set lines [split [::HWFlow::readTextFile $path] "\n"]
    foreach line [lrange $lines 1 end] {
        if {[string trim $line] eq ""} { continue }
        set fields [split $line ,]
        if {[llength $fields] != 12} { error "Damaged optimization action row: $line" }
        set action [dict create \
            regionId [lindex $fields 0] actionId [lindex $fields 1] actionType [lindex $fields 2] \
            elementId [lindex $fields 3] edgeIndex [lindex $fields 4] \
            nodeA [lindex $fields 5] nodeB [lindex $fields 6] \
            referenceA [lindex $fields 7] referenceB [lindex $fields 8] \
            targetDistance [lindex $fields 9] splitMethod [lindex $fields 10] reason [lindex $fields 11]]
        dict lappend result [dict get $action regionId] $action
    }
    return $result
}

proc ::LocalMeshOptimizer::planSummary {} {
    variable runtime
    set regionCount 0
    set actionCount 0
    set manualCount 0
    set regionPath [file join $runtime(taskDir) region_tasks.csv]
    set actionPath [file join $runtime(taskDir) optimization_actions.csv]
    if {[file isfile $regionPath]} {
        set lines [split [string trim [::HWFlow::readTextFile $regionPath]] "\n"]
        set regionCount [expr {max(0, [llength $lines] - 1)}]
    }
    if {[file isfile $actionPath]} {
        set lines [split [string trim [::HWFlow::readTextFile $actionPath]] "\n"]
        foreach line [lrange $lines 1 end] {
            if {[string trim $line] eq ""} { continue }
            incr actionCount
            if {[string first ",manual_review," $line] >= 0} { incr manualCount }
        }
    }
    return [dict create regions $regionCount actions $actionCount manual $manualCount]
}

proc ::LocalMeshOptimizer::planSettingsSignature {} {
    variable ui
    set keys {
        OPTIMIZATION_LEVEL ADJACENCY_LAYERS FEATURE_ANGLE MAX_REGION_ELEMENTS
        SKINNY_TRIANGLE_RATIO NARROW_QUAD_RATIO NARROW_TARGET_ASPECT
        CONTROLLED_EDGE_GROWTH ALLOW_CONTROLLED_FREE_EDGE_MOVE
        EXCLUDE_WASHER_ELEMENTS PROTECT_FREE_EDGES PROTECT_COMPONENT_BOUNDARIES
        PROTECT_HOLE_EDGES PROTECT_FEATURE_EDGES PROTECT_RIGID_NODES
        PROTECT_WELD_NODES PROTECT_USER_NODES NO_CROSS_COMPONENT_MOVEMENT
        PRESERVE_GEOMETRY_ASSOCIATION
    }
    set values {}
    foreach key $keys { lappend values $key $ui($key) }
    return $values
}

proc ::LocalMeshOptimizer::optimizationPlanCurrent {} {
    variable runtime
    variable ui
    if {!$runtime(planReady) || $runtime(taskDir) eq ""} { return 0 }
    foreach name {region_tasks.csv optimization_actions.csv failed_elements.txt task.json} {
        if {![file isfile [file join $runtime(taskDir) $name]]} { return 0 }
    }
    if {![file isfile $ui(CRITERIA_PATH)]} { return 0 }
    set criteria [file normalize $ui(CRITERIA_PATH)]
    if {$criteria ne $runtime(checkedCriteriaPath) || [file mtime $criteria] != $runtime(checkedCriteriaMtime)} { return 0 }
    if {$ui(SCOPE_TYPE) ne $runtime(checkedScopeType)} { return 0 }
    if {[::LocalMeshOptimizer::planSettingsSignature] ne $runtime(checkedPlanSettings)} { return 0 }
    if {[catch {set currentScope [::LocalMeshOptimizer::markScope 1]}]} { return 0 }
    return [expr {[::LocalMeshOptimizer::uniq $currentScope] eq $runtime(checkedScopeIds)}]
}

proc ::LocalMeshOptimizer::nodeCoordinate {nodeId} {
    if {![catch {set value [hm_nodevalue $nodeId]}] && [llength $value] >= 3} {
        return [lrange $value 0 2]
    }
    return [list \
        [hm_getvalue nodes id=$nodeId dataname=x] \
        [hm_getvalue nodes id=$nodeId dataname=y] \
        [hm_getvalue nodes id=$nodeId dataname=z]]
}

proc ::LocalMeshOptimizer::isTrueFreeEdge {nodeA nodeB} {
    catch {*clearmark elems 2}
    *createmark elems 2 "by all nodes" $nodeA $nodeB
    set shellOwners {}
    foreach elementId [hm_getmark elems 2] {
        if {![catch {set nodes [hm_getvalue elems id=$elementId dataname=nodes]}] && [llength $nodes] in {3 4}} {
            lappend shellOwners $elementId
        }
    }
    return [expr {[llength [::LocalMeshOptimizer::uniq $shellOwners]] == 1}]
}

proc ::LocalMeshOptimizer::regionNodeIds {elementIds} {
    set nodes {}
    foreach elementId $elementIds {
        if {![catch {set values [hm_getvalue elems id=$elementId dataname=nodes]}]} { set nodes [concat $nodes $values] }
    }
    return [::LocalMeshOptimizer::uniq $nodes]
}

proc ::LocalMeshOptimizer::currentRegionElements {regionNodeIds componentIds previousElementIds touchedNodeIds} {
    array set regionNode {}
    foreach nodeId $regionNodeIds { set regionNode($nodeId) 1 }
    catch {*clearmark elems 2}
    set candidates $previousElementIds
    set validTouched {}
    foreach nodeId $touchedNodeIds {
        if {![catch {set existing [hm_getvalue nodes id=$nodeId dataname=id]}] && $existing ne ""} { lappend validTouched $nodeId }
    }
    if {[llength $validTouched] > 0} {
        eval *createmark elems 2 {"by node id"} $validTouched
        set candidates [concat $candidates [hm_getmark elems 2]]
    }
    set result {}
    foreach elementId [::LocalMeshOptimizer::uniq $candidates] {
        if {[catch {set nodes [hm_getvalue elems id=$elementId dataname=nodes]}] || [llength $nodes] ni {3 4}} { continue }
        set contained 1
        foreach nodeId $nodes { if {![info exists regionNode($nodeId)]} { set contained 0; break } }
        if {!$contained} { continue }
        set componentId 0
        catch {set componentId [hm_getvalue elems id=$elementId dataname=collectorid]}
        if {[llength $componentIds] == 0 || [lsearch -exact $componentIds $componentId] >= 0} { lappend result $elementId }
    }
    return [::LocalMeshOptimizer::uniq $result]
}

proc ::LocalMeshOptimizer::targetCoordinateFromReference {nodeId referenceId targetDistance} {
    variable ui
    set point [::LocalMeshOptimizer::nodeCoordinate $nodeId]
    set reference [::LocalMeshOptimizer::nodeCoordinate $referenceId]
    set dx [expr {double([lindex $point 0]) - double([lindex $reference 0])}]
    set dy [expr {double([lindex $point 1]) - double([lindex $reference 1])}]
    set dz [expr {double([lindex $point 2]) - double([lindex $reference 2])}]
    set length [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
    if {$length <= 1.0e-12} { error "Cannot expand node $nodeId from coincident reference $referenceId" }
    if {$length >= $targetDistance} { return $point }
    set stepDistance [expr {min(double($targetDistance), $length * double($ui(CONTROLLED_EDGE_GROWTH)))}]
    set scale [expr {$stepDistance / $length}]
    set x [expr {double([lindex $reference 0]) + $dx*$scale}]
    set y [expr {double([lindex $reference 1]) + $dy*$scale}]
    set z [expr {double([lindex $reference 2]) + $dz*$scale}]
    return [list $x $y $z]
}

proc ::LocalMeshOptimizer::runPlannedActions {regionId round actions failedIds regionElements anchorIds {progressBase -1.0} {progressSpan 0.0}} {
    variable ui
    set applied 0
    set methods {}
    set manual 0
    set touchedNodes {}
    set freeActionCount 0
    set topologyChangeCount 0
    array set moveX {}
    array set moveY {}
    array set moveZ {}
    array set moveCount {}
    set actionTotal [llength $actions]
    set actionIndex 0
    set progressEvery [expr {max(1, int(ceil(max(1, $actionTotal) / 20.0)))}]
    foreach action $actions {
        incr actionIndex
        set type [dict get $action actionType]
        set elementId [dict get $action elementId]
        if {$progressBase >= 0.0 && ($actionIndex == 1 || $actionIndex == $actionTotal || ($actionIndex % $progressEvery) == 0)} {
            set actionPct [expr {double($progressBase) + double($progressSpan) * $actionIndex / double(max(1, $actionTotal))}]
            set actionDetail [::LocalMeshOptimizer::txt \
                "$regionId，第 $round 轮；动作 $actionIndex/$actionTotal；已执行=$applied；人工=$manual；类型=$type" \
                "$regionId, round $round; action $actionIndex/$actionTotal; applied=$applied; manual=$manual; type=$type"]
            catch {::LocalMeshOptimizer::optimizationProgress $actionPct [::LocalMeshOptimizer::txt "正在执行局部拓扑动作" "Applying local topology actions"] $actionDetail 1}
        }
        if {$type eq "manual_review"} { incr manual; continue }
        if {[lsearch -exact $failedIds $elementId] < 0} { continue }
        if {[::LocalMeshOptimizer::cancelRequested]} { error "cancel requested" }
        set actionId [dict get $action actionId]
        set started [clock milliseconds]
        if {![catch {set actionNodes [hm_getvalue elems id=$elementId dataname=nodes]}]} {
            set touchedNodes [concat $touchedNodes $actionNodes]
        }
        if {$type eq "split_quad"} {
            catch {*clearmark elems 1}
            *createmark elems 1 $elementId
            set method [dict get $action splitMethod]
            if {$method ni {2 102}} { error "Invalid quad split method for $actionId: $method" }
            uplevel #0 [list *splitelements $method 1]
            incr topologyChangeCount
        } elseif {$type eq "collapse_short_edge"} {
            catch {*clearmark elems 1}
            eval *createmark elems 1 $regionElements
            set setupCode [catch {*elementqualitysetup 1} setupErr setupOpts]
            if {$setupCode} { return -options $setupOpts $setupErr }
            set actionCode [catch {uplevel #0 [list *elementqualitycollapseedge $elementId [dict get $action edgeIndex]]} actionErr actionOpts]
            set shutdownCode [catch {*elementqualityshutdown 1} shutdownErr shutdownOpts]
            if {$actionCode} { return -options $actionOpts $actionErr }
            if {$shutdownCode} { return -options $shutdownOpts $shutdownErr }
            incr topologyChangeCount
        } elseif {$type eq "expand_free_edge"} {
            if {!$ui(ALLOW_CONTROLLED_FREE_EDGE_MOVE) || $ui(PRESERVE_GEOMETRY_ASSOCIATION)} { incr manual; continue }
            set nodeA [dict get $action nodeA]
            set nodeB [dict get $action nodeB]
            if {[lsearch -exact $anchorIds $nodeA] >= 0 || [lsearch -exact $anchorIds $nodeB] >= 0} { incr manual; continue }
            if {![::LocalMeshOptimizer::isTrueFreeEdge $nodeA $nodeB]} { incr manual; continue }
            foreach pair [list [list $nodeA [dict get $action referenceA]] [list $nodeB [dict get $action referenceB]]] {
                set nodeId [lindex $pair 0]
                set target [::LocalMeshOptimizer::targetCoordinateFromReference $nodeId [lindex $pair 1] [dict get $action targetDistance]]
                if {![info exists moveCount($nodeId)]} {
                    set moveX($nodeId) 0.0; set moveY($nodeId) 0.0; set moveZ($nodeId) 0.0; set moveCount($nodeId) 0
                }
                set moveX($nodeId) [expr {$moveX($nodeId) + double([lindex $target 0])}]
                set moveY($nodeId) [expr {$moveY($nodeId) + double([lindex $target 1])}]
                set moveZ($nodeId) [expr {$moveZ($nodeId) + double([lindex $target 2])}]
                incr moveCount($nodeId)
            }
            set touchedNodes [concat $touchedNodes [list $nodeA $nodeB [dict get $action referenceA] [dict get $action referenceB]]]
            incr freeActionCount
            continue
        } else {
            error "Unknown optimization action: $type"
        }
        incr applied
        lappend methods $type
        set elapsed [expr {([clock milliseconds] - $started) / 1000.0}]
        ::LocalMeshOptimizer::log INFO "planned action complete action=$actionId reason=[dict get $action reason]" $regionId $round $type 1 1 $elapsed
    }
    if {$freeActionCount > 0} {
        foreach nodeId [array names moveCount] {
            set count [expr {double($moveCount($nodeId))}]
            uplevel #0 [list *nodemodify $nodeId [expr {$moveX($nodeId)/$count}] [expr {$moveY($nodeId)/$count}] [expr {$moveZ($nodeId)/$count}]]
        }
        set applied [expr {$applied + $freeActionCount}]
        lappend methods expand_free_edge
        ::LocalMeshOptimizer::log INFO "coordinated free-edge expansion actions=$freeActionCount nodes=[array size moveCount]" $regionId $round *nodemodify $freeActionCount [array size moveCount]
    }
    return [dict create applied $applied topologyChangeCount $topologyChangeCount methods [::LocalMeshOptimizer::uniq $methods] manual $manual touchedNodes [::LocalMeshOptimizer::uniq $touchedNodes]]
}

proc ::LocalMeshOptimizer::outputModelPath {} {
    variable runtime
    set source $runtime(sourceModelPath)
    if {$source eq ""} { set source [::LocalMeshOptimizer::modelPath] }
    set stamp [clock format [clock seconds] -format {%Y%m%d_%H%M%S}]
    if {$source eq ""} { return [file join $runtime(taskDir) "unsaved_local_optimized_${stamp}.hm"] }
    set base [file rootname [file tail $source]]
    return [file join [file dirname $source] "${base}_local_optimized_${stamp}.hm"]
}

proc ::LocalMeshOptimizer::writeResultJson {checked before after cancelled output elapsed taskStatus} {
    variable runtime
    set lines [list \
        "{" \
        "  \"status\": [::LocalMeshOptimizer::jsonString $taskStatus]," \
        "  \"checked_elements\": $checked," \
        "  \"failed_before\": $before," \
        "  \"failed_after\": $after," \
        "  \"cancelled\": [::LocalMeshOptimizer::jsonBool $cancelled]," \
        "  \"elapsed_seconds\": $elapsed," \
        "  \"output_model\": [::LocalMeshOptimizer::jsonString $output]" \
        "}"]
    ::HWFlow::writeTextFile [file join $runtime(taskDir) result.json] [join $lines "\n"]
}

proc ::LocalMeshOptimizer::saveModelSnapshot {path} {
    file mkdir [file dirname $path]
    catch {::HWFlow::progressAppend [::LocalMeshOptimizer::txt "HyperMesh 正在保存安全快照：[file tail $path]" "HyperMesh is saving a safety snapshot: [file tail $path]"]}
    catch {update idletasks}
    # This path is owned by the task.  Remove a stale partial file and answer
    # any HyperMesh overwrite question before it can become a hidden modal.
    if {[file exists $path]} {
        if {[catch {file delete -force $path} deleteErr]} {
            error [::LocalMeshOptimizer::txt "无法替换旧模型文件：$deleteErr" "Could not replace the old model file: $deleteErr"]
        }
    }
    catch {hm_answernext yes}
    if {[catch {uplevel #0 [list *writefile [file nativename $path] 1]} err opts]} {
        ::LocalMeshOptimizer::log ERROR "Model snapshot failed: $err" - - *writefile 1 0
        error [::LocalMeshOptimizer::txt "无法保存可靠模型快照：$err" "Could not save a reliable model snapshot: $err"]
    }
    if {![file isfile $path] || [file size $path] == 0} { error [::LocalMeshOptimizer::txt "模型快照命令未生成有效文件。" "The model snapshot command did not produce a valid file."] }
    return 1
}

proc ::LocalMeshOptimizer::restoreSnapshot {path} {
    if {![file isfile $path]} { error [::LocalMeshOptimizer::txt "恢复快照不存在：$path" "Recovery snapshot does not exist: $path"] }
    # Reading replaces a modified database and may otherwise show a modal
    # confirmation behind the progress window.
    catch {hm_answernext yes}
    if {[catch {uplevel #0 [list *readfile [file nativename $path] 0]} err opts]} {
        ::LocalMeshOptimizer::log ERROR "Snapshot restore failed: $err" - - *readfile 1 0
        error [::LocalMeshOptimizer::txt "恢复模型快照失败：$err" "Could not restore model snapshot: $err"]
    }
    catch {::HWFlow::refreshBrowser}
    return 1
}

proc ::LocalMeshOptimizer::restoreBefore {} {
    variable runtime
    if {$runtime(running)} {
        ::LocalMeshOptimizer::setStatus WARN [::LocalMeshOptimizer::txt "任务运行期间不能恢复模型；请先停止并等待当前原生命令结束。" "The model cannot be restored during a task; stop it and wait for the current native command to finish."]
        return
    }
    if {$runtime(backupPath) eq "" || ![file isfile $runtime(backupPath)]} {
        ::LocalMeshOptimizer::setStatus WARN [::LocalMeshOptimizer::txt "没有可用的任务前快照。" "No pre-task snapshot is available."]
        return
    }
    set now [clock seconds]
    if {$runtime(restoreArmedUntil) < $now} {
        set runtime(restoreArmedUntil) [expr {$now + 8}]
        ::LocalMeshOptimizer::setStatus WARN [::LocalMeshOptimizer::txt "恢复会替换当前未保存修改。请在 8 秒内再次点击“恢复优化前模型”确认。" "Restore replaces current unsaved changes. Click Restore Before again within 8 seconds to confirm."]
        return
    }
    set runtime(restoreArmedUntil) 0
    if {[catch {::LocalMeshOptimizer::restoreSnapshot $runtime(backupPath)} err]} {
        ::LocalMeshOptimizer::setStatus ERROR $err
    } else {
        ::LocalMeshOptimizer::setStatus INFO [::LocalMeshOptimizer::txt "已恢复优化前模型。" "The pre-task model has been restored."]
    }
}

proc ::LocalMeshOptimizer::startOptimization {} {
    variable runtime
    if {$runtime(running)} {
        ::LocalMeshOptimizer::setStatus WARN [::LocalMeshOptimizer::txt "已有任务正在运行。" "A task is already running."]
        return 0
    }
    if {![::LocalMeshOptimizer::optimizationPlanCurrent]} {
        ::LocalMeshOptimizer::setStatus INFO [::LocalMeshOptimizer::txt "优化计划不存在或范围/criteria 已变化，正在自动重新检查并规划。" "The optimization plan is missing or scope/criteria changed; rebuilding it automatically."]
        if {![::LocalMeshOptimizer::checkQuality]} { return 0 }
    }
    set runtime(running) 1
    set code [catch {set result [::LocalMeshOptimizer::startOptimizationCore]} err opts]
    set runtime(running) 0
    if {$code} {
        set recovery [::LocalMeshOptimizer::txt "模型尚未修改或没有可用快照。" "The model was not modified or no snapshot is available."]
        if {$runtime(backupPath) ne "" && [file isfile $runtime(backupPath)]} {
            if {[catch {::LocalMeshOptimizer::restoreSnapshot $runtime(backupPath)} restoreErr]} {
                set recovery [::LocalMeshOptimizer::txt "自动恢复失败：$restoreErr；请手工打开 $runtime(backupPath)。" "Automatic restore failed: $restoreErr; open $runtime(backupPath) manually."]
            } else {
                set recovery [::LocalMeshOptimizer::txt "已自动恢复优化前模型。" "The pre-task model was restored automatically."]
            }
        }
        catch {::LocalMeshOptimizer::ensureProgress [::LocalMeshOptimizer::txt "优化异常，正在保存诊断结果..." "Optimization failed; saving diagnostics..."]}
        if {$runtime(taskDir) ne "" && [file isdirectory $runtime(taskDir)]} {
            set initialFailed [llength $runtime(failedElements)]
            catch {::LocalMeshOptimizer::writeResultJson $runtime(checkedElements) $initialFailed $initialFailed 0 "" 0 task_rolled_back}
            set taskPath [file join $runtime(taskDir) task.json]
            if {[file isfile $taskPath]} { catch {::LocalMeshOptimizer::runPython finalize $taskPath} }
        }
        set message [::LocalMeshOptimizer::txt "优化流程失败：$err；$recovery 日志：$runtime(taskDir)/optimizer.log" "Optimization failed: $err; $recovery Log: $runtime(taskDir)/optimizer.log"]
        ::LocalMeshOptimizer::setStatus ERROR $message
        catch {::HWFlow::progressFinish $message 100.0}
        return 0
    }
    return $result
}

proc ::LocalMeshOptimizer::startOptimizationCore {} {
    variable runtime
    variable ui
    set status [::LocalMeshOptimizer::profileStatus]
    if {![lindex $status 0]} {
        ::LocalMeshOptimizer::setStatus WARN [lindex $status 1]
        return 0
    }
    set regions [::LocalMeshOptimizer::readRegionTasks]
    set actionMap [::LocalMeshOptimizer::readOptimizationActions]
    if {[llength $regions] == 0} {
        if {[llength $runtime(washerExcludedFailed)] > 0} {
            ::LocalMeshOptimizer::setStatus INFO [::LocalMeshOptimizer::txt "没有可自动优化区域；[llength $runtime(washerExcludedFailed)] 个 Washer 失败单元已按默认设置保留给人工处理。" "No automatically optimizable regions; [llength $runtime(washerExcludedFailed)] failed washer elements are reserved for manual work by default."]
        } else {
            ::LocalMeshOptimizer::setStatus INFO [::LocalMeshOptimizer::txt "没有失败区域，无需优化。" "There are no failed regions to optimize."]
        }
        return 1
    }
    set taskStart [clock milliseconds]
    set runtime(progressStartedMs) $taskStart
    set taskInitialFailed [llength $runtime(failedElements)]
    set runtime(sourceModelPath) [::LocalMeshOptimizer::modelPath]
    set runtime(backupPath) [file join $runtime(taskDir) before.hm]
    set progressOpened [::HWFlow::progressOpen "Local Mesh Optimizer" [::LocalMeshOptimizer::txt "正在保存优化前模型..." "Saving the pre-task model..."] 1]
    catch {::HWFlow::progressUpdate 2.0 [::LocalMeshOptimizer::txt "正在保存唯一的任务前快照" "Saving the only pre-task snapshot"] [file tail $runtime(backupPath)] 1}
    if {[catch {::LocalMeshOptimizer::saveModelSnapshot $runtime(backupPath)} err]} {
        set message [::LocalMeshOptimizer::txt "优化未开始，模型未修改。$err" "Optimization did not start; the model was not modified. $err"]
        ::LocalMeshOptimizer::setStatus ERROR $message
        catch {::HWFlow::progressFinish $message 100.0}
        return 0
    }
    catch {::HWFlow::progressUpdate 8.0 [::LocalMeshOptimizer::txt "任务前模型已保存，开始逐区域优化" "Pre-task model saved; starting region optimization"] "" 1}
    set resultLines [list "region_id,final_failed_count,rounds,optimization_methods,elapsed_seconds,status,rollback_count,message"]
    set cancelled 0
    set taskRolledBack 0
    set taskRollbackReason ""
    set runtime(topologyFailureAllowance) 0
    set runtime(optimizedElements) {}
    set regionIndex 0
    set totalRegions [llength $regions]
    foreach region $regions {
        incr regionIndex
        set regionId [dict get $region regionId]
        set elements [dict get $region expanded]
        set components [dict get $region components]
        set anchors [dict get $region anchors]
        set regionNodes [::LocalMeshOptimizer::regionNodeIds $elements]
        set currentElements $elements
        if {[dict exists $actionMap $regionId]} { set actions [dict get $actionMap $regionId] } else { set actions {} }
        set initialFailed [llength [dict get $region failed]]
        set currentFailed $initialFailed
        set rounds 0
        set rollbacks 0
        set status failed
        set message ""
        set methodsUsed {}
        set regionElapsed 0.0
        if {[::HWFlow::progressCancelled] || [file exists [file join $runtime(taskDir) cancel.flag]]} { set cancelled 1; break }
        set regionBase [expr {10.0 + 78.0 * ($regionIndex - 1) / double($totalRegions)}]
        set regionSpan [expr {78.0 / double($totalRegions)}]
        catch {::LocalMeshOptimizer::optimizationProgress $regionBase [::LocalMeshOptimizer::txt "正在优化 $regionId" "Optimizing $regionId"] [::LocalMeshOptimizer::txt "区域 $regionIndex/$totalRegions；单元 [llength $elements]；初始失败 $initialFailed" "Region $regionIndex/$totalRegions; elements [llength $elements]; initial failures $initialFailed"] 1}
        set regionStart [clock milliseconds]
        set regionMaxRounds [expr {$ui(OPTIMIZATION_LEVEL) eq "quick" ? 1 : $ui(MAX_ROUNDS)}]
        for {set round 1} {$round <= $regionMaxRounds} {incr round} {
            set rounds $round
            set roundBase [expr {$regionBase + $regionSpan * ($round - 1) / double($regionMaxRounds)}]
            set roundSpan [expr {$regionSpan / double($regionMaxRounds)}]
            set roundContext [::LocalMeshOptimizer::txt "$regionId，第 $round/$regionMaxRounds 轮" "$regionId, round $round/$regionMaxRounds"]
            if {[::HWFlow::progressCancelled] || [file exists [file join $runtime(taskDir) cancel.flag]]} { set cancelled 1; break }
            if {[llength $currentElements] == 0} {
                set status failed
                set message "region has no remaining shell elements"
                break
            }
            if {$round == 1} {
                # The check stage already produced the authoritative initial
                # failure set and the Python region/action plan. Reuse it
                # directly instead of repeating the same native check.
                set plannedFailed {}
                foreach elementId [dict get $region failed] {
                    if {[lsearch -exact $currentElements $elementId] >= 0 && ![catch {hm_getvalue elems id=$elementId dataname=nodes}]} {
                        lappend plannedFailed $elementId
                    }
                }
                set before [dict create failedIds $plannedFailed checked [llength $currentElements] detail {}]
                catch {::LocalMeshOptimizer::optimizationProgress [expr {$roundBase + 0.08*$roundSpan}] [::LocalMeshOptimizer::txt "复用检查阶段质量结果" "Reusing check-stage quality result"] "$roundContext；failed=[llength $plannedFailed]" 1}
            } elseif {[catch {set before [::LocalMeshOptimizer::nativeQualityCheck $currentElements [expr {$roundBase + 0.02*$roundSpan}] [expr {0.10*$roundSpan}] $roundContext]} qualityErr]} {
                    set status failed
                    set message "region quality check failed: $qualityErr"
                    break
            }
            set beforeCount [llength [dict get $before failedIds]]
            if {$beforeCount == 0} { set currentFailed 0; set status success; break }
            if {[catch {set anchorCoordinates [::LocalMeshOptimizer::nodeCoordinateMap $anchors]} anchorReadErr]} {
                set status failed
                set message $anchorReadErr
                break
            }
            catch {::LocalMeshOptimizer::optimizationProgress [expr {$roundBase + 0.16*$roundSpan}] [::LocalMeshOptimizer::txt "正在准备保护节点和局部动作" "Preparing anchors and local actions"] "$roundContext；anchors=[llength $anchors]；actions=[llength $actions]" 1}
            if {[catch {set actionResult [::LocalMeshOptimizer::runPlannedActions $regionId $round $actions [dict get $before failedIds] $currentElements $anchors [expr {$roundBase + 0.20*$roundSpan}] [expr {0.50*$roundSpan}]]} actionErr]} {
                incr rollbacks
                set taskRolledBack 1
                set taskRollbackReason "planned topology action failed in $regionId: $actionErr"
                set message "$taskRollbackReason; restoring pre-task model"
                set status task_rolled_back
                break
            }
            if {[dict get $actionResult applied] == 0} {
                set status [expr {$beforeCount < $initialFailed ? "partial_success" : "failed"}]
                set message "no safe automatic action remains; manual review=[dict get $actionResult manual]"
                break
            }
            set methodsUsed [::LocalMeshOptimizer::uniq [concat $methodsUsed [dict get $actionResult methods]]]
            set roundTopologyAllowance [dict get $actionResult topologyChangeCount]
            set runtime(topologyFailureAllowance) [expr {$runtime(topologyFailureAllowance) + $roundTopologyAllowance}]
            catch {::LocalMeshOptimizer::optimizationProgress [expr {$roundBase + 0.74*$roundSpan}] [::LocalMeshOptimizer::txt "正在刷新局部连接关系" "Refreshing local connectivity"] "$roundContext；applied=[dict get $actionResult applied]" 1}
            if {[catch {set currentElements [::LocalMeshOptimizer::currentRegionElements $regionNodes $components $currentElements [dict get $actionResult touchedNodes]]} refreshErr]} {
                incr rollbacks
                set taskRolledBack 1
                set taskRollbackReason "region connectivity refresh failed in $regionId: $refreshErr"
                set status task_rolled_back
                set message "$taskRollbackReason; restoring pre-task model"
                break
            }
            if {$ui(SCOPE_TYPE) eq "elements"} {
                set runtime(selectedElements) [::LocalMeshOptimizer::uniq [concat $runtime(selectedElements) $currentElements]]
            }
            catch {::LocalMeshOptimizer::optimizationProgress [expr {$roundBase + 0.82*$roundSpan}] [::LocalMeshOptimizer::txt "正在核验保护节点" "Verifying protected nodes"] "$roundContext；anchors=[llength $anchors]" 1}
            if {[catch {set movedAnchors [::LocalMeshOptimizer::movedAnchorNodes $anchorCoordinates 1.0e-9]} anchorVerifyErr]} {
                incr rollbacks
                set taskRolledBack 1
                set taskRollbackReason "protected-node verification failed in $regionId: $anchorVerifyErr"
                set status task_rolled_back
                set message "$taskRollbackReason; restoring pre-task model"
                break
            }
            if {[llength $movedAnchors] > 0} {
                incr rollbacks
                set taskRolledBack 1
                set taskRollbackReason "protected nodes moved in $regionId: [lrange $movedAnchors 0 20]"
                set status task_rolled_back
                set message "$taskRollbackReason; restoring pre-task model"
                ::LocalMeshOptimizer::log ERROR $message $regionId $round planned_actions [llength $anchors] [llength $movedAnchors]
                break
            }
            if {[catch {set after [::LocalMeshOptimizer::nativeQualityCheck $currentElements [expr {$roundBase + 0.86*$roundSpan}] [expr {0.10*$roundSpan}] [::LocalMeshOptimizer::txt "$roundContext，修改后复检" "$roundContext, post-change recheck"]]} recheckErr]} {
                incr rollbacks
                set taskRolledBack 1
                set taskRollbackReason "region recheck failed in $regionId: $recheckErr"
                set status task_rolled_back
                set message "$taskRollbackReason; restoring pre-task model"
                break
            }
            set afterCount [llength [dict get $after failedIds]]
            catch {::LocalMeshOptimizer::optimizationProgress [expr {$roundBase + 0.98*$roundSpan}] [::LocalMeshOptimizer::txt "本轮复检完成" "Round recheck complete"] "$roundContext；before=$beforeCount；after=$afterCount" 1}
            set currentFailed $afterCount
            if {$afterCount == 0} { set status success; set runtime(optimizedElements) [::LocalMeshOptimizer::uniq [concat $runtime(optimizedElements) $currentElements]]; break }
            if {[::LocalMeshOptimizer::qualityWorsened $before $after $roundTopologyAllowance]} {
                incr rollbacks
                set taskRolledBack 1
                set taskRollbackReason "quality worsened beyond topology replacement allowance in $regionId: before=$beforeCount after=$afterCount allowance=$roundTopologyAllowance"
                set status task_rolled_back
                set message "$taskRollbackReason; restoring pre-task model"
                break
            }
            set runtime(optimizedElements) [::LocalMeshOptimizer::uniq [concat $runtime(optimizedElements) $currentElements]]
            set status partial_success
            if {![::LocalMeshOptimizer::qualityImproved $before $after]} {
                if {$afterCount > $beforeCount && $roundTopologyAllowance > 0} {
                    set message "failure IDs increased within local topology-replacement allowance; retained for final native guard"
                } else {
                    set message "no measurable improvement in this round; topology retained for final native guard"
                }
                ::LocalMeshOptimizer::log WARN $message $regionId $round planned_actions $beforeCount $afterCount
            }
        }
        if {$cancelled} {
            incr rollbacks
            set status cancelled
            set taskRolledBack 1
            set taskRollbackReason "cancel requested"
            set message "cancel requested; restoring pre-task model"
        }
        set regionElapsed [expr {([clock milliseconds] - $regionStart) / 1000.0}]
        catch {::LocalMeshOptimizer::optimizationProgress [expr {$regionBase + $regionSpan}] [::LocalMeshOptimizer::txt "$regionId 处理完成" "$regionId complete"] [::LocalMeshOptimizer::txt "区域 $regionIndex/$totalRegions；状态=$status；当前失败=$currentFailed；轮次=$rounds" "Region $regionIndex/$totalRegions; status=$status; current failures=$currentFailed; rounds=$rounds"] 1}
        lappend resultLines [join [list $regionId $currentFailed $rounds [join $methodsUsed {;}] $regionElapsed $status $rollbacks [::LocalMeshOptimizer::csvQuote $message]] ,]
        if {$cancelled || $taskRolledBack} { break }
    }
    if {$cancelled && !$taskRolledBack} {
        set taskRolledBack 1
        set taskRollbackReason "cancel requested"
    }
    set finalFailed [llength $runtime(failedElements)]
    set output ""
    if {$taskRolledBack} {
        ::LocalMeshOptimizer::log WARN "$taskRollbackReason; restoring the only pre-task snapshot"
        if {[catch {::LocalMeshOptimizer::restoreSnapshot $runtime(backupPath)} restoreErr]} {
            ::LocalMeshOptimizer::log ERROR "Whole-task restore failed: $restoreErr"
            error [::LocalMeshOptimizer::txt "优化异常，且恢复优化前模型失败：$restoreErr。请手工打开 $runtime(backupPath)" "Optimization failed and the pre-task model could not be restored: $restoreErr. Open $runtime(backupPath) manually."]
        }
        catch {::LocalMeshOptimizer::ensureProgress [::LocalMeshOptimizer::txt "任务前模型已恢复，正在生成报告..." "Pre-task model restored; generating report..."]}
        catch {::HWFlow::progressUpdate 92.0 [::LocalMeshOptimizer::txt "任务前模型已恢复" "Pre-task model restored"] $taskRollbackReason 1}
        set finalFailed $taskInitialFailed
        set rollbackStatus [expr {$cancelled ? "cancelled" : "task_rolled_back"}]
        set resultLines [list "region_id,final_failed_count,rounds,optimization_methods,elapsed_seconds,status,rollback_count,message"]
        foreach region $regions {
            lappend resultLines [join [list [dict get $region regionId] [llength [dict get $region failed]] 0 "" 0 $rollbackStatus 1 [::LocalMeshOptimizer::csvQuote "$taskRollbackReason; pre-task model restored"]] ,]
        }
    } else {
        set guardPassed 1
        if {[catch {
            catch {::LocalMeshOptimizer::optimizationProgress 89.0 [::LocalMeshOptimizer::txt "正在执行最终全范围质量守卫" "Running final whole-scope quality guard"] [::LocalMeshOptimizer::txt "仅复检最终模型，不重新加载 criteria" "Checking the final model without reloading criteria"] 1}
            set finalScope [::LocalMeshOptimizer::markScope 1]
            set finalQuality [::LocalMeshOptimizer::nativeQualityCheck $finalScope 89.0 2.0 [::LocalMeshOptimizer::txt "最终全范围检查" "Final whole-scope check"]]
            set finalIds [dict get $finalQuality failedIds]
            set newFailures [::LocalMeshOptimizer::listDifference $finalIds $runtime(failedElements)]
            set newFailuresOutside [::LocalMeshOptimizer::listDifference $newFailures $runtime(optimizedElements)]
            set finalFailed [llength $finalIds]
            set allowedFinal [expr {[llength $runtime(failedElements)] + $runtime(topologyFailureAllowance)}]
            if {$finalFailed > $allowedFinal || [llength $newFailuresOutside] > 0} {
                error "overall quality guard failed: initial=[llength $runtime(failedElements)] final=$finalFailed topology_allowance=$runtime(topologyFailureAllowance) new_failures_outside=[llength $newFailuresOutside]"
            }
            set runtime(failedElements) $finalIds
        } guardErr]} {
            set guardPassed 0
            ::LocalMeshOptimizer::log ERROR "$guardErr; restoring whole-task snapshot"
            ::LocalMeshOptimizer::restoreSnapshot $runtime(backupPath)
            catch {::LocalMeshOptimizer::ensureProgress [::LocalMeshOptimizer::txt "整体质量守卫未通过，模型已恢复" "Overall quality guard failed; model restored"]}
            catch {::HWFlow::progressUpdate 92.0 [::LocalMeshOptimizer::txt "任务前模型已恢复" "Pre-task model restored"] $guardErr 1}
            set finalFailed [llength $runtime(failedElements)]
            set taskRolledBack 1
            set taskRollbackReason $guardErr
            set resultLines [list "region_id,final_failed_count,rounds,optimization_methods,elapsed_seconds,status,rollback_count,message"]
            foreach region $regions {
                lappend resultLines [join [list [dict get $region regionId] [llength [dict get $region failed]] 0 "" 0 task_rolled_back 1 [::LocalMeshOptimizer::csvQuote "$guardErr; pre-task model restored"]] ,]
            }
        }
        if {$guardPassed && $ui(AUTO_SAVE_MODEL)} {
            set output [::LocalMeshOptimizer::outputModelPath]
            catch {::LocalMeshOptimizer::optimizationProgress 93.0 [::LocalMeshOptimizer::txt "正在保存最终优化模型" "Saving final optimized model"] [file tail $output] 1}
            if {[catch {::LocalMeshOptimizer::saveModelSnapshot $output} saveErr]} { ::LocalMeshOptimizer::log ERROR "Output model save failed: $saveErr"; set output "" }
            set runtime(lastOutputModel) $output
        }
    }
    ::HWFlow::writeTextFile [file join $runtime(taskDir) region_results.csv] [join $resultLines "\n"]
    set elapsed [expr {([clock milliseconds] - $taskStart) / 1000.0}]
    set topologyPartial [expr {!$taskRolledBack && !$cancelled && $finalFailed > $taskInitialFailed}]
    set taskStatus [expr {$cancelled ? "cancelled" : ($taskRolledBack ? "task_rolled_back" : ($topologyPartial ? "partial_success" : "complete"))}]
    ::LocalMeshOptimizer::writeResultJson $runtime(checkedElements) $taskInitialFailed $finalFailed $cancelled $output $elapsed $taskStatus
    set taskPath [file join $runtime(taskDir) task.json]
    catch {::LocalMeshOptimizer::optimizationProgress 96.0 [::LocalMeshOptimizer::txt "正在生成报告" "Generating report"] [::LocalMeshOptimizer::txt "汇总区域结果、CSV 和 HTML" "Summarizing regions, CSV and HTML"] 1}
    set reportCode [catch {::LocalMeshOptimizer::runPython finalize $taskPath} reportErr]
    if {$reportCode} { ::LocalMeshOptimizer::log ERROR "Report finalize failed: $reportErr" }
    if {$taskRolledBack} {
        set ui(RESULT_TEXT) [::LocalMeshOptimizer::txt "优化未保留：已恢复任务前模型。原因：$taskRollbackReason；报告：[::LocalMeshOptimizer::reportDir]" "Optimization was not retained; the pre-task model was restored. Reason: $taskRollbackReason; report: [::LocalMeshOptimizer::reportDir]"]
    } elseif {$topologyPartial} {
        set ui(RESULT_TEXT) [::LocalMeshOptimizer::txt "任务部分完成：失败单元ID数量由 $taskInitialFailed 变为 $finalFailed，增长未超出局部拓扑替换额度且未扩散到优化区域外。请人工复核相关区域。输出：$output；报告：[::LocalMeshOptimizer::reportDir]" "Task partially completed: failed entity IDs changed from $taskInitialFailed to $finalFailed, within the local topology-replacement allowance and without spreading outside optimized regions. Review the affected regions. Output: $output; report: [::LocalMeshOptimizer::reportDir]"]
    } else {
        set ui(RESULT_TEXT) [::LocalMeshOptimizer::txt "任务结束。输出：$output；报告：[::LocalMeshOptimizer::reportDir]" "Task finished. Output: $output; report: [::LocalMeshOptimizer::reportDir]"]
    }
    ::LocalMeshOptimizer::log INFO $ui(RESULT_TEXT)
    catch {::HWFlow::progressFinish $ui(RESULT_TEXT) 100.0}
    return [expr {!$cancelled && !$taskRolledBack}]
}

proc ::LocalMeshOptimizer::requestStop {} {
    variable runtime
    if {$runtime(taskDir) ne ""} {
        catch {::HWFlow::writeTextFile [file join $runtime(taskDir) cancel.flag] "cancelled\n"}
    }
    catch {::HWFlow::progressRequestCancel}
    ::LocalMeshOptimizer::log WARN "cancel requested"
}

proc ::LocalMeshOptimizer::openReportDirectory {} {
    set directory [::LocalMeshOptimizer::reportDir]
    if {![file isdirectory $directory]} { file mkdir $directory }
    if {[catch {
        if {$::tcl_platform(platform) eq "windows"} {
            exec explorer.exe [file nativename $directory] &
        } elseif {$::tcl_platform(os) eq "Darwin"} {
            exec open $directory &
        } else {
            exec xdg-open $directory &
        }
    } err]} {
        ::LocalMeshOptimizer::setStatus ERROR [::LocalMeshOptimizer::txt "无法打开报告目录：$err" "Could not open report directory: $err"]
    }
}

proc ::LocalMeshOptimizer::browseReportDir {} {
    variable ui
    variable runtime
    if {$runtime(running)} { return }
    set path [tk_chooseDirectory -parent .local_mesh_optimizer_advanced -title [::LocalMeshOptimizer::txt "选择报告输出目录" "Select report output directory"]]
    if {$path ne ""} { set ui(REPORT_DIR) [file normalize $path] }
}

proc ::LocalMeshOptimizer::showAdvanced {} {
    variable ui
    variable runtime
    if {$runtime(running)} { return }
    set w .local_mesh_optimizer_advanced
    if {[winfo exists $w]} { raise $w; return }
    ::HWFlow::createTopLevel $w
    wm title $w [::LocalMeshOptimizer::txt "局部网格优化 - 高级设置" "Local Mesh Optimizer - Advanced Settings"]
    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    set fields {
        {MAX_REGION_ELEMENTS "单区域最大单元数" "Maximum elements per region"}
        {MAX_REGION_SECONDS "单区域最大处理时间（秒）" "Maximum seconds per region"}
        {TARGET_QI "目标 QI（空=criteria）" "Target QI (empty=criteria)"}
        {SKINNY_TRIANGLE_RATIO "瘦长三角形长短边比" "Skinny-tria long/short ratio"}
        {NARROW_QUAD_RATIO "细长四边形长短边比" "Narrow-quad long/short ratio"}
        {NARROW_TARGET_ASPECT "自由边外扩目标长宽比" "Free-edge expansion target aspect"}
        {CONTROLLED_EDGE_GROWTH "自由边单轮最大外扩倍数" "Maximum free-edge growth per round"}
        {PYTHON_COMMAND "Python 3 路径/命令" "Python 3 path/command"}
        {REPORT_DIR "报告输出目录（空=模型目录）" "Report directory (empty=model directory)"}
    }
    set row 0
    foreach item $fields {
        set key [lindex $item 0]
        label $w.main.l_$key -text [::LocalMeshOptimizer::txt [lindex $item 1] [lindex $item 2]] -anchor w
        entry $w.main.e_$key -textvariable ::LocalMeshOptimizer::ui($key) -width 48
        grid $w.main.l_$key -row $row -column 0 -sticky w -pady 3 -padx {0 8}
        grid $w.main.e_$key -row $row -column 1 -sticky ew -pady 3
        incr row
    }
    button $w.main.report -text [::LocalMeshOptimizer::txt "选择报告目录" "Choose Report Directory"] -command ::LocalMeshOptimizer::browseReportDir
    grid $w.main.report -row $row -column 1 -sticky e -pady 4
    incr row
    checkbutton $w.main.project -text [::LocalMeshOptimizer::txt "优化后投影回原几何（HM2019 未验证，当前禁用）" "Project to original geometry (HM2019 unverified; disabled)"] -variable ::LocalMeshOptimizer::ui(PROJECT_TO_GEOMETRY) -state disabled
    checkbutton $w.main.freeedge -text [::LocalMeshOptimizer::txt "允许细长条带自由边受控外扩（保持几何关联时跳过）" "Allow controlled narrow-strip free-edge expansion (skipped when preserving geometry association)"] -variable ::LocalMeshOptimizer::ui(ALLOW_CONTROLLED_FREE_EDGE_MOVE)
    checkbutton $w.main.autosave -text [::LocalMeshOptimizer::txt "自动另存优化模型" "Automatically save optimized model"] -variable ::LocalMeshOptimizer::ui(AUTO_SAVE_MODEL)
    checkbutton $w.main.autoopen -text [::LocalMeshOptimizer::txt "自动打开报告" "Automatically open report"] -variable ::LocalMeshOptimizer::ui(AUTO_OPEN_REPORT)
    grid $w.main.project -row $row -column 0 -columnspan 2 -sticky w; incr row
    grid $w.main.freeedge -row $row -column 0 -columnspan 2 -sticky w; incr row
    grid $w.main.autosave -row $row -column 0 -columnspan 2 -sticky w; incr row
    grid $w.main.autoopen -row $row -column 0 -columnspan 2 -sticky w; incr row
    labelframe $w.main.verify -text [::LocalMeshOptimizer::txt "HM2019 命令验证" "HM2019 Command Validation"] -padx 8 -pady 8
    grid $w.main.verify -row $row -column 0 -columnspan 2 -sticky ew -pady {8 0}
    label $w.main.verify.note -text [::LocalMeshOptimizer::txt \
        "只有按 doc/local_mesh_optimizer_hm2019_validation.md 完成 command.cmf 录制后，才可将配置值设为 hm2019_recorded。此标记不会绕过运行时 catch 和回退。" \
        "Set the value to hm2019_recorded only after completing command.cmf recording per doc/local_mesh_optimizer_hm2019_validation.md. Runtime error handling and rollback remain mandatory."] -wraplength 560 -justify left -anchor w
    entry $w.main.verify.profile -textvariable ::LocalMeshOptimizer::ui(HM2019_PROFILE) -width 24
    grid $w.main.verify.note -row 0 -column 0 -columnspan 2 -sticky ew
    grid $w.main.verify.profile -row 1 -column 0 -sticky w -pady {6 0}
    grid columnconfigure $w.main 1 -weight 1
    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.close -text [::LocalMeshOptimizer::txt "保存并关闭" "Save and Close"] -width 14 -command "::LocalMeshOptimizer::saveState; destroy $w"
    pack $w.btn.close -side right
    bind $w <Escape> "::LocalMeshOptimizer::saveState; destroy $w"
}

proc ::LocalMeshOptimizer::closeWindow {} {
    variable runtime
    if {$runtime(running)} {
        ::LocalMeshOptimizer::requestStop
        ::LocalMeshOptimizer::setStatus INFO [::LocalMeshOptimizer::txt "已请求停止。请等待当前 HyperMesh 原生命令结束后再关闭窗口。" "Stop requested. Wait for the current native HyperMesh command to finish before closing the window."]
        return
    }
    ::LocalMeshOptimizer::saveState
    catch {destroy .local_mesh_optimizer_advanced}
    catch {destroy .local_mesh_optimizer}
}

proc ::LocalMeshOptimizer::showPanel {} {
    variable ui
    variable runtime
    variable VERSION
    ::LocalMeshOptimizer::loadState
    ::LocalMeshOptimizer::refreshSelectionText
    set ui(RESULT_TEXT) [::LocalMeshOptimizer::txt "尚未检查。" "Not checked yet."]
    set w .local_mesh_optimizer
    if {[winfo exists $w]} { raise $w; return }
    ::HWFlow::createTopLevel $w
    wm title $w "[::LocalMeshOptimizer::txt "局部网格优化" "Local Mesh Optimizer"] v$VERSION"
    wm minsize $w 760 620
    wm resizable $w 1 1
    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    label $w.main.title -text [::LocalMeshOptimizer::txt "局部网格优化 / Local Mesh Optimizer" "Local Mesh Optimizer"] -font [::HWFlow::uiFont heading] -anchor w
    label $w.main.subtitle -text [::LocalMeshOptimizer::txt "根据 criteria 文件，仅对不合格网格区域进行增量优化。最终质量判定以 HyperMesh 为准。" "Use criteria to incrementally optimize failed mesh regions only. HyperMesh is the final quality authority."] -anchor w -justify left
    grid $w.main.title -row 0 -column 0 -sticky ew
    grid $w.main.subtitle -row 1 -column 0 -sticky ew -pady {2 8}

    labelframe $w.main.scope -text [::LocalMeshOptimizer::txt "A. 处理范围" "A. Scope"] -padx 8 -pady 8
    grid $w.main.scope -row 2 -column 0 -sticky ew -pady {0 8}
    foreach item {{components "用户选择的组件" "Selected components"} {elements "用户选择的单元" "Selected elements"} {displayed "当前显示的全部单元" "All displayed elements"} {all "当前模型全部单元" "All model elements"}} {
        set value [lindex $item 0]
        radiobutton $w.main.scope.r_$value -text [::LocalMeshOptimizer::txt [lindex $item 1] [lindex $item 2]] -variable ::LocalMeshOptimizer::ui(SCOPE_TYPE) -value $value
        pack $w.main.scope.r_$value -side left -padx {0 8}
    }
    frame $w.main.select
    grid $w.main.select -row 3 -column 0 -sticky ew -pady {0 8}
    button $w.main.select.comps -text [::LocalMeshOptimizer::txt "选择组件" "Pick Components"] -width 12 -command ::LocalMeshOptimizer::pickComponents
    button $w.main.select.elems -text [::LocalMeshOptimizer::txt "选择单元" "Pick Elements"] -width 12 -command ::LocalMeshOptimizer::pickElements
    button $w.main.select.anchors -text [::LocalMeshOptimizer::txt "固定节点" "Anchor Nodes"] -width 12 -command ::LocalMeshOptimizer::pickAnchorNodes
    button $w.main.select.clear -text [::LocalMeshOptimizer::txt "清除选择" "Clear"] -width 10 -command ::LocalMeshOptimizer::clearSelection
    button $w.main.select.show -text [::LocalMeshOptimizer::txt "显示范围" "Show Scope"] -width 10 -command ::LocalMeshOptimizer::showScope
    pack $w.main.select.comps $w.main.select.elems $w.main.select.anchors $w.main.select.clear $w.main.select.show -side left -padx {0 6}
    label $w.main.select.info -textvariable ::LocalMeshOptimizer::ui(SELECTION_TEXT) -anchor w
    pack $w.main.select.info -side left -fill x -expand 1

    labelframe $w.main.criteria -text [::LocalMeshOptimizer::txt "B. Criteria 文件" "B. Criteria File"] -padx 8 -pady 8
    grid $w.main.criteria -row 4 -column 0 -sticky ew -pady {0 8}
    entry $w.main.criteria.path -textvariable ::LocalMeshOptimizer::ui(CRITERIA_PATH) -width 72
    button $w.main.criteria.browse -text [::LocalMeshOptimizer::txt "浏览" "Browse"] -width 8 -command ::LocalMeshOptimizer::browseCriteria
    menubutton $w.main.criteria.recent -text [::LocalMeshOptimizer::txt "最近" "Recent"] -width 8 -relief raised -menu $w.main.criteria.recent.menu
    menu $w.main.criteria.recent.menu -tearoff 0
    label $w.main.criteria.status -textvariable ::LocalMeshOptimizer::ui(CRITERIA_STATUS) -anchor w
    grid $w.main.criteria.path -row 0 -column 0 -sticky ew -padx {0 6}
    grid $w.main.criteria.browse -row 0 -column 1 -padx {0 4}
    grid $w.main.criteria.recent -row 0 -column 2
    grid $w.main.criteria.status -row 1 -column 0 -columnspan 3 -sticky w -pady {4 0}
    grid columnconfigure $w.main.criteria 0 -weight 1
    ::LocalMeshOptimizer::refreshRecentMenu

    labelframe $w.main.parameters -text [::LocalMeshOptimizer::txt "C. 常用参数" "C. Common Parameters"] -padx 8 -pady 8
    grid $w.main.parameters -row 5 -column 0 -sticky ew -pady {0 8}
    set fields {{ADJACENCY_LAYERS "邻接层数 (1-3)" "Adjacency layers (1-3)"} {MAX_ROUNDS "最大轮次 (1-10)" "Maximum rounds (1-10)"} {FEATURE_ANGLE "特征角" "Feature angle"}}
    set column 0
    foreach item $fields {
        set key [lindex $item 0]
        label $w.main.parameters.l_$key -text [::LocalMeshOptimizer::txt [lindex $item 1] [lindex $item 2]]
        entry $w.main.parameters.e_$key -textvariable ::LocalMeshOptimizer::ui($key) -width 8
        grid $w.main.parameters.l_$key -row 0 -column $column -sticky w -padx {0 4}
        incr column
        grid $w.main.parameters.e_$key -row 0 -column $column -sticky w -padx {0 14}
        incr column
    }
    label $w.main.parameters.level -text [::LocalMeshOptimizer::txt "优化级别" "Level"]
    grid $w.main.parameters.level -row 1 -column 0 -sticky w -pady {6 0}
    set column 1
    foreach item {{quick "快速" "Quick"} {standard "标准" "Standard"} {deep "深度" "Deep"}} {
        radiobutton $w.main.parameters.level_[lindex $item 0] -text [::LocalMeshOptimizer::txt [lindex $item 1] [lindex $item 2]] -variable ::LocalMeshOptimizer::ui(OPTIMIZATION_LEVEL) -value [lindex $item 0]
        if {[lindex $item 0] eq "deep"} { $w.main.parameters.level_deep configure -state disabled }
        grid $w.main.parameters.level_[lindex $item 0] -row 1 -column $column -sticky w -pady {6 0}
        incr column
    }
    button $w.main.parameters.advanced -text [::LocalMeshOptimizer::txt "高级设置" "Advanced"] -width 12 -command ::LocalMeshOptimizer::showAdvanced
    grid $w.main.parameters.advanced -row 1 -column 7 -sticky e -pady {6 0}

    labelframe $w.main.protection -text [::LocalMeshOptimizer::txt "D. 保护选项" "D. Protection"] -padx 8 -pady 8
    grid $w.main.protection -row 6 -column 0 -sticky ew -pady {0 8}
    set options {{EXCLUDE_WASHER_ELEMENTS "排除 Washer 网格（人工处理）" "Exclude washer mesh (manual)"} {PROTECT_FREE_EDGES "保护自由边" "Protect free edges"} {PROTECT_COMPONENT_BOUNDARIES "保护组件边界" "Protect component boundaries"} {PROTECT_HOLE_EDGES "保护孔边" "Protect hole edges"} {PROTECT_FEATURE_EDGES "保护特征边" "Protect feature edges"} {PROTECT_RIGID_NODES "保护刚性连接节点" "Protect rigid nodes"} {PROTECT_WELD_NODES "保护焊缝连接节点" "Protect weld nodes"} {PROTECT_USER_NODES "保护用户固定节点" "Protect user anchors"} {NO_CROSS_COMPONENT_MOVEMENT "禁止跨组件移动" "No cross-component movement"} {PRESERVE_GEOMETRY_ASSOCIATION "保持节点几何关联" "Preserve geometry association"}}
    set index 0
    foreach item $options {
        set key [lindex $item 0]
        checkbutton $w.main.protection.c_$key -text [::LocalMeshOptimizer::txt [lindex $item 1] [lindex $item 2]] -variable ::LocalMeshOptimizer::ui($key)
        grid $w.main.protection.c_$key -row [expr {$index / 3}] -column [expr {$index % 3}] -sticky w -padx {0 14} -pady 2
        incr index
    }
    foreach key {PROTECT_RIGID_NODES PROTECT_WELD_NODES} {
        $w.main.protection.c_$key configure -state disabled
    }
    label $w.main.protection.note -text [::LocalMeshOptimizer::txt \
        "刚性/焊缝自动识别尚未通过 HM2019 验证，故默认关闭并置灰；可用“固定节点”手工保护。区域边界、自由边、组件边界和特征边由锚点规划保护。" \
        "Automatic rigid/weld detection is unverified, so it is off and disabled; use Anchor Nodes manually. Region, free, component and feature edges are protected by planned anchors."] -anchor w -justify left -wraplength 700
    grid $w.main.protection.note -row 4 -column 0 -columnspan 3 -sticky ew -pady {5 0}

    labelframe $w.main.result -text [::LocalMeshOptimizer::txt "状态" "Status"] -padx 8 -pady 8
    grid $w.main.result -row 7 -column 0 -sticky nsew -pady {0 8}
    label $w.main.result.text -textvariable ::LocalMeshOptimizer::ui(RESULT_TEXT) -anchor nw -justify left -wraplength 700
    label $w.main.result.version -text [::LocalMeshOptimizer::txt "HyperMesh 版本：[::LocalMeshOptimizer::hmVersion]；修改命令配置：$ui(HM2019_PROFILE)" "HyperMesh version: [::LocalMeshOptimizer::hmVersion]; modification profile: $ui(HM2019_PROFILE)"] -anchor w
    pack $w.main.result.text -fill both -expand 1
    pack $w.main.result.version -fill x -pady {4 0}
    grid rowconfigure $w.main 7 -weight 1
    grid columnconfigure $w.main 0 -weight 1

    frame $w.buttons -padx 12 -pady 10
    pack $w.buttons -fill x
    frame $w.buttons.primary
    frame $w.buttons.secondary
    pack $w.buttons.primary $w.buttons.secondary -fill x -pady 2
    foreach spec {
        {check "检查质量" "Check Quality" ::LocalMeshOptimizer::checkQuality 12}
        {start "开始优化" "Start" ::LocalMeshOptimizer::startOptimization 12}
        {stop "停止" "Stop" ::LocalMeshOptimizer::requestStop 9}
        {failed "显示失败" "Show Failed" ::LocalMeshOptimizer::showFailed 11}
        {optimized "显示已优化" "Show Optimized" ::LocalMeshOptimizer::showOptimized 12}
        {restore "恢复优化前模型" "Restore Before" ::LocalMeshOptimizer::restoreBefore 15}
        {report "打开报告目录" "Open Reports" ::LocalMeshOptimizer::openReportDirectory 13}
        {home "返回主页" "Back to Home" {::LocalMeshOptimizer::closeWindow; ::HWToolkit::showHome} 11}
        {close "关闭" "Close" ::LocalMeshOptimizer::closeWindow 9}
    } {
        set name [lindex $spec 0]
        if {$name in {check start stop failed optimized}} { set group primary } else { set group secondary }
        button $w.buttons.$group.$name -text [::LocalMeshOptimizer::txt [lindex $spec 1] [lindex $spec 2]] -command [lindex $spec 3] -width [lindex $spec 4]
        pack $w.buttons.$group.$name -side left -padx {0 5}
    }
    bind $w <Escape> ::LocalMeshOptimizer::closeWindow
    wm protocol $w WM_DELETE_WINDOW ::LocalMeshOptimizer::closeWindow
    update idletasks
    set sw [winfo screenwidth $w]; set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]; set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw-$ww)/2}]+[expr {($sh-$wh)/2}]
}

proc ::LocalMeshOptimizer::runAction {} { ::LocalMeshOptimizer::showPanel }
proc ::LocalMeshOptimizer::runSettings {} { ::LocalMeshOptimizer::loadState; ::LocalMeshOptimizer::showAdvanced }
proc ::LocalMeshOptimizer::run {} { ::LocalMeshOptimizer::runAction }
