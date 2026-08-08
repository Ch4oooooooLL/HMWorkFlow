# ============================================================================
# Mesh Seam Weld
# HyperMesh 2019 Tcl/Tk
#
# Imprints a selected source node path to a bounded target mesh region, then
# creates a shell strip between the unchanged source path and the post-imprint
# target path. Recoverable imprint anchors keep explicit structured
# correspondence; only paths without a safe anchor mapping use temporary ruled
# geometry, removed after meshing.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

# Load shared logging, progress, workspace, and HyperMesh bulk-read services
# directly.  The mesh seam production flow does not load its Python bridge or
# FEM exporter and does not schedule a Python worker.
if {![namespace exists ::HybridCore]} {
    ::HWFlow::sourceUtf8 [file join [file dirname [file normalize [info script]]] hybrid_core tcl init.tcl]
}

namespace eval ::MeshSeamWeld {
    variable VERSION "0.51"
    variable MODULE_DIR [file join [file dirname [file normalize [info script]]] mesh_seam_weld]

    variable cfg
    array set cfg {
        run_mode              LEGACY_MANUAL
        fast_auto_enabled     1
        search_distance       12.0
        min_seam_length       20.0
        min_path_nodes        3
        parallel_angle_max    15.0
        perpendicular_angle_min 70.0
        max_distance_variation_ratio 0.35
        existing_path_search_width 20.0
        max_target_path_offset 8.0
        max_node_move         2.0
        max_node_move_ratio   0.25
        allow_target_node_move 0
        allow_local_split     0
        prefer_quad_weld      1
        allow_weld_end_tria   1
        max_weld_tria_ratio   0.15
        quality_guard_enabled 1
        max_new_failed_elements 0
        existing_weld_search_distance 4.0
        exclude_existing_welds 1
        keep_task_files        1
        auto_accept_confidence 0.88
        review_confidence     0.60
        execution_batch_size 25
        output_component       MESH_SEAM_WELD
        weld_mesh_size         8
        patch_expand_layers    2
        imprint_remain         3
        imprint_remesh_mode    2
        imprint_angle          30.0
        mesh_face_shape        1
        mesh_elem_type         2
        mesh_smooth_method     1
        mesh_smooth_tol        0.5
        mesh_size_control      1
        mesh_skew_control      1
        mesh_path_param        1
        mesh_cross_param       1
        mesh_cross_size        0
        create_geometry_surf   0
    }
    # Legacy state keys are retained for old config files.  Ruled transverse
    # layers are now derived from each source/target gap and weld size;
    # mesh_cross_param is intentionally not used as a fixed override.

    variable ui
    array set ui {}

    # The most recent completed weld batch can be restored as one user-facing
    # operation.  Keep the snapshot outside the model so the native history
    # entries used for per-path failure isolation remain independent.
    variable lastUndoSnapshot ""
    variable lastUndoSummary ""
    variable lastUndoCreatedAt ""
    variable undoInProgress 0

    # Per-run caches.  Large node paths previously repeated the same database
    # queries for element connectivity, node adjacency, and coordinates.
    variable elemNodesCache
    variable nodeElemsCache
    variable elemComponentCache
    variable nodeFreeEdgeNeighborsCache
    variable nodeXYZCache
    variable freeEdgePrimedComponents
    # Component names created during the current run.  This is intentionally
    # separate from the output-component lookup: an existing SEAM_T* collector
    # must not be reassigned a property merely because this run reused it.
    variable createdOutputComponents [dict create]
    variable targetElemGrid
    variable targetElemCentroid
    variable targetNodeToElems
    variable targetIndexCellSize 1.0
    variable targetGridMin {0 0 0}
    variable targetGridMax {0 0 0}
    # Detailed per-path diagnostics are disabled in normal runs.  The compact
    # PERF line remains enabled, while avoiding several forced small writes per
    # loop on workstations whose model and task directories live on HDDs.
    variable verbosePathLogging 0
    variable lastImprintTargetMode target_components
    variable lastImprintTargetElemCount 0
    variable lastImprintCoreElemCount 0
    variable lastImprintSupportElemCount 0
    variable lastImprintSharedNeighborElemCount 0
    variable lastImprintAffectedElemIds {}
    variable lastLocalTargetNodeIds {}
    variable lastLocalTargetEdges [dict create]
    # Legacy compatibility only.  The weld execution path no longer relies on
    # hm_latestentityid because IDs are not monotonic after model trimming.
    variable lastKnownNodeId 0
    variable lastKnownElemId 0
    array set elemNodesCache {}
    array set nodeElemsCache {}
    array set elemComponentCache {}
    array set nodeFreeEdgeNeighborsCache {}
    array set nodeXYZCache {}
    array set freeEdgePrimedComponents {}
    array set targetElemGrid {}
    array set targetElemCentroid {}
    array set targetNodeToElems {}
}

proc ::MeshSeamWeld::stateKeys {} {
    return {
        run_mode fast_auto_enabled search_distance min_seam_length min_path_nodes
        parallel_angle_max perpendicular_angle_min max_distance_variation_ratio
        existing_path_search_width max_target_path_offset max_node_move max_node_move_ratio
        allow_target_node_move allow_local_split prefer_quad_weld allow_weld_end_tria
        max_weld_tria_ratio quality_guard_enabled max_new_failed_elements existing_weld_search_distance
        exclude_existing_welds keep_task_files auto_accept_confidence review_confidence execution_batch_size
        output_component weld_mesh_size patch_expand_layers imprint_remain imprint_remesh_mode imprint_angle
        mesh_face_shape mesh_elem_type mesh_smooth_method mesh_smooth_tol
        mesh_size_control mesh_skew_control mesh_path_param
        mesh_cross_param mesh_cross_size create_geometry_surf
    }
}

proc ::MeshSeamWeld::uniq {items} {
    set out {}
    array set seen {}
    foreach item $items {
        if {$item eq "" || [info exists seen($item)]} {
            continue
        }
        set seen($item) 1
        lappend out $item
    }
    return $out
}

proc ::MeshSeamWeld::msg {text} {
    catch {hm_usermessage $text}
    catch {puts $text}
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend "MeshSeamWeld: $text"}
    }
    catch {update}
}

proc ::MeshSeamWeld::tracePath {message} {
    variable verbosePathLogging
    if {$verbosePathLogging} {
        ::HybridCore::log INFO $message
    }
}

# Long HyperMesh workflows run on the Tcl UI thread.  Yield at bounded
# intervals between native commands so Windows can repaint the progress UI
# and dispatch pending window events without adding per-entity update calls.
proc ::MeshSeamWeld::responsiveCheckpoint {completed {interval 128}} {
    if {![string is integer -strict $completed] || $completed <= 0} {
        return 0
    }
    if {![string is integer -strict $interval] || $interval < 1} {
        set interval 128
    }
    if {$completed % $interval != 0} {
        return 0
    }
    if {[llength [info commands ::HWFlow::progressPumpEvents]] > 0} {
        ::HWFlow::progressPumpEvents 0
    } else {
        catch {update idletasks}
        ::HybridCore::cooperativeYield
    }
    return 1
}

proc ::MeshSeamWeld::loadState {} {
    variable cfg
    ::MeshSeamWeld::loadAutoRules
    if {[llength [info commands ::HWFlow::applyStateToArray]] > 0} {
        ::HWFlow::applyStateToArray mesh_seam_weld ::MeshSeamWeld::cfg
    }
}

proc ::MeshSeamWeld::saveState {} {
    if {[llength [info commands ::HWFlow::saveArrayState]] > 0} {
        ::HWFlow::saveArrayState mesh_seam_weld ::MeshSeamWeld::cfg
    }
}

proc ::MeshSeamWeld::saveUndoSnapshot {path} {
    file mkdir [file dirname $path]
    catch {hm_answernext yes}
    if {[catch {uplevel #0 [list *writefile [file nativename $path] 1]} err opts]} {
        return -options $opts $err
    }
    if {![file isfile $path] || [file size $path] == 0} {
        error "HyperMesh did not create a valid mesh-seam undo snapshot"
    }
    return [file normalize $path]
}

proc ::MeshSeamWeld::undoAvailable {} {
    variable lastUndoSnapshot
    variable undoInProgress
    return [expr {!$undoInProgress && $lastUndoSnapshot ne "" && [file isfile $lastUndoSnapshot] && [file size $lastUndoSnapshot] > 0}]
}

proc ::MeshSeamWeld::registerUndoSnapshot {path summary} {
    variable lastUndoSnapshot
    variable lastUndoSummary
    variable lastUndoCreatedAt
    if {![file isfile $path] || [file size $path] == 0} {
        error "Cannot register missing mesh-seam undo snapshot: $path"
    }
    set lastUndoSnapshot [file normalize $path]
    set lastUndoSummary $summary
    set lastUndoCreatedAt [clock seconds]
    return $lastUndoSnapshot
}

proc ::MeshSeamWeld::clearUndoRecord {} {
    variable lastUndoSnapshot
    variable lastUndoSummary
    variable lastUndoCreatedAt
    set lastUndoSnapshot ""
    set lastUndoSummary ""
    set lastUndoCreatedAt ""
}

proc ::MeshSeamWeld::restoreUndoSnapshot {} {
    variable lastUndoSnapshot
    if {$lastUndoSnapshot eq "" || ![file isfile $lastUndoSnapshot] || [file size $lastUndoSnapshot] == 0} {
        error [::HWFlow::txt "没有可撤回的网格焊缝操作。" "There is no completed mesh-seam operation to undo."]
    }
    catch {hm_answernext yes}
    if {[catch {uplevel #0 [list *readfile [file nativename $lastUndoSnapshot] 0]} err opts]} {
        return -options $opts $err
    }
    catch {::HWFlow::refreshBrowser}
    return $lastUndoSnapshot
}

proc ::MeshSeamWeld::undoLast {} {
    variable lastUndoSnapshot
    variable lastUndoSummary
    variable undoInProgress
    if {![::MeshSeamWeld::undoAvailable]} {
        tk_messageBox -icon info -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] \
            -message [::HWFlow::txt "没有可撤回的网格焊缝操作。" "There is no completed mesh-seam operation to undo."]
        return 0
    }
    set detail $lastUndoSummary
    if {$detail eq ""} {
        set detail [::HWFlow::txt "最近一次网格焊缝批次" "the most recent mesh-seam batch"]
    }
    set answer [tk_messageBox -type yesno -icon question \
        -title [::HWFlow::txt "撤回网格焊缝" "Undo Mesh Seam Weld"] \
        -message [::HWFlow::txt \
            "确定撤回$detail吗？这会恢复该批次开始前的模型状态，并覆盖该批次之后对模型所做的修改。" \
            "Undo $detail? This restores the model state captured before that batch and overwrites model changes made afterwards."]]
    if {$answer ne "yes"} { return 0 }
    set undoInProgress 1
    set code [catch {::MeshSeamWeld::restoreUndoSnapshot} err]
    set undoInProgress 0
    if {$code} {
        tk_messageBox -icon error -title [::HWFlow::txt "撤回失败" "Undo Failed"] \
            -message [::HWFlow::txt "网格焊缝撤回失败，原撤回点仍保留：\n$err" \
                "Mesh seam weld undo failed; the undo point was retained:\n$err"]
        return 0
    }
    ::MeshSeamWeld::clearUndoRecord
    tk_messageBox -icon info -title [::HWFlow::txt "撤回完成" "Undo Complete"] \
        -message [::HWFlow::txt "最近一次网格焊缝批次已撤回。" "The most recent mesh-seam batch was undone."]
    return 1
}

proc ::MeshSeamWeld::centerWindow {w} {
    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    ::HWFlow::centerWindow $w
}

proc ::MeshSeamWeld::updateModeUi {} {
    variable ui
    set panel .mesh_seam_weld.main.param
    if {![winfo exists $panel]} { return }
    set autoState [expr {$ui(run_mode) eq "FAST_AUTO" ? "normal" : "disabled"}]
    set manualState [expr {$ui(run_mode) eq "LEGACY_MANUAL" ? "normal" : "disabled"}]
    foreach key {search_distance min_seam_length parallel_angle_max perpendicular_angle_min max_target_path_offset max_node_move} {
        if {[winfo exists $panel.e_$key]} { $panel.e_$key configure -state $autoState }
    }
    foreach key {patch_expand_layers imprint_remain imprint_remesh_mode imprint_angle mesh_face_shape mesh_elem_type} {
        if {[winfo exists $panel.e_$key]} { $panel.e_$key configure -state $manualState }
    }
    foreach widget {exclude_existing keep_tasks local_split node_move} {
        if {[winfo exists $panel.$widget]} { $panel.$widget configure -state $autoState }
    }
    if {[winfo exists .mesh_seam_weld.main.note] && $ui(run_mode) eq "FAST_AUTO"} {
        .mesh_seam_weld.main.note configure -text [::HWFlow::txt \
            "自动模式只导出所选一阶壳网格，经用户复核后优先利用目标侧现有边路径直接创建 CQUAD4/CTRIA3。该路径不调用 imprint、ruled、automesh 或 connector；不安全候选进入人工处理。" \
            "Automatic mode exports selected first-order shells and, after explicit review, creates CQUAD4/CTRIA3 directly on existing target edge paths. It never invokes imprint, ruled, automesh, or connectors; unsafe candidates remain manual review."]
    } elseif {[winfo exists .mesh_seam_weld.main.note]} {
        .mesh_seam_weld.main.note configure -text [::HWFlow::txt \
            "兼容模式保留原有手动源节点路径、局部 Mesh Edit imprint 和 ruled/automesh 创建流程。" \
            "Compatibility mode retains the original manual source-node path, local Mesh Edit imprint, and ruled/automesh creation workflow."]
    }
}

proc ::MeshSeamWeld::showPanel {} {
    variable VERSION
    variable cfg
    variable ui

    ::MeshSeamWeld::loadState
    foreach key [::MeshSeamWeld::stateKeys] {
        set ui($key) $cfg($key)
    }

    catch {destroy .mesh_seam_weld}
    set w .mesh_seam_weld
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle "[::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] v$VERSION" "Mesh Seam Weld v$VERSION"]
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -font [::HWFlow::uiFont heading]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.mode -text [::HWFlow::txt "运行方式" "Run Mode"] -padx 8 -pady 8
    grid $w.main.mode -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    radiobutton $w.main.mode.auto -text [::HWFlow::txt "自动识别并快速创建" "Automatic Detection and Fast Creation"] -variable ::MeshSeamWeld::ui(run_mode) -value FAST_AUTO -command ::MeshSeamWeld::updateModeUi
    radiobutton $w.main.mode.manual -text [::HWFlow::txt "手动选择路径（兼容模式）" "Manual Path Selection (Compatibility)"] -variable ::MeshSeamWeld::ui(run_mode) -value LEGACY_MANUAL -command ::MeshSeamWeld::updateModeUi
    pack $w.main.mode.auto $w.main.mode.manual -side left -padx {0 16}
    labelframe $w.main.param -text [::HWFlow::txt "参数" "Parameters"] -padx 8 -pady 8
    grid $w.main.param -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    set fields {
        {search_distance "自动识别搜索距离" "Auto search distance"}
        {min_seam_length "自动焊缝最小长度" "Minimum auto seam length"}
        {parallel_angle_max "搭接平行角度" "Lap parallel angle"}
        {perpendicular_angle_min "T 型垂直角度" "T perpendicular angle"}
        {max_target_path_offset "目标路径最大偏移" "Maximum target path offset"}
        {max_node_move "最大节点移动（当前默认禁用）" "Maximum node move (disabled by default)"}
        {output_component "未识别厚度时的输出组件" "Fallback output component"}
        {weld_mesh_size "焊缝网格尺寸" "Weld mesh size"}
        {patch_expand_layers "imprint 局部重绘扩展层数" "Imprint remesh layers"}
        {imprint_remain "imprint remain 参数" "Imprint remain option"}
        {imprint_remesh_mode "imprint remesh_mode 参数" "Imprint remesh_mode option"}
        {imprint_angle "imprint angle 参数" "Imprint angle option"}
        {mesh_face_shape "焊缝面 shape_type" "Weld face shape_type"}
        {mesh_elem_type "焊缝面 elem_type，2 为混合" "Weld face elem_type, 2 = mixed"}
    }
    set row 0
    foreach item $fields {
        set key [lindex $item 0]
        label $w.main.param.l_$key -text [::HWFlow::txt [lindex $item 1] [lindex $item 2]] -anchor w
        entry $w.main.param.e_$key -textvariable ::MeshSeamWeld::ui($key) -width 24
        grid $w.main.param.l_$key -row $row -column 0 -sticky w -padx {0 8} -pady 2
        grid $w.main.param.e_$key -row $row -column 1 -sticky w -pady 2
        incr row
    }
    checkbutton $w.main.param.exclude_existing -text [::HWFlow::txt "排除已有 SEAM_T* 焊缝" "Exclude existing SEAM_T* welds"] -variable ::MeshSeamWeld::ui(exclude_existing_welds)
    checkbutton $w.main.param.keep_tasks -text [::HWFlow::txt "保留任务文件" "Keep task files"] -variable ::MeshSeamWeld::ui(keep_task_files)
    checkbutton $w.main.param.local_split -text [::HWFlow::txt "允许局部切分（未验证，默认关闭）" "Allow local split (unvalidated; off by default)"] -variable ::MeshSeamWeld::ui(allow_local_split)
    checkbutton $w.main.param.node_move -text [::HWFlow::txt "允许受控目标节点微调" "Allow guarded target-node adjustment"] -variable ::MeshSeamWeld::ui(allow_target_node_move)
    grid $w.main.param.exclude_existing -row $row -column 0 -columnspan 2 -sticky w; incr row
    grid $w.main.param.keep_tasks -row $row -column 0 -columnspan 2 -sticky w; incr row
    grid $w.main.param.node_move -row $row -column 0 -columnspan 2 -sticky w; incr row
    grid $w.main.param.local_split -row $row -column 0 -columnspan 2 -sticky w

    message $w.main.note -width 520 -text [::HWFlow::txt \
        "连续节点直接作为开放路径执行。单点仍按原有规则处理所在闭环；不连续且均位于自由边界上的节点按端点对分流：每条自由边界只能选两个点，批量选择的端点总数必须为偶数，程序自动补齐两点之间的较短边界路径并按开放路径创建焊缝。其它不连续输入仍按闭合自由边界规则校验。每条路径在执行前即时准备目标组件上投影最近的几层单元，并以原始节点列表和该 Elements patch 调用 Mesh Edit imprint；随后重新获取已被 imprint 调整位置的目标节点。Ruled 的第一侧始终使用原始节点列表，第二侧使用 imprint 后目标节点；对应关系按实际弧长和拓扑连续性校验，不再按节点序号盲目连接。横向层数按每个对应点之间的间距除以焊缝网格尺寸自动计算，间距变化时局部调整；闭环会显式补首尾封口。新建 SEAM_* component 后会自动尝试赋予对应 SEAM_Tx Property。运行流程不导出 FEM，也不调用 Python。" \
        "Continuous nodes execute directly as an open path. Single points retain the existing matching closed-loop behavior. Disconnected nodes that all lie on free boundaries use endpoint-pair mode: select exactly two points per free boundary, keep the total endpoint count even, and the tool fills the shorter boundary path between each pair before creating an open weld span. Other disconnected inputs continue through closed-free-boundary validation. Each path prepares only the nearest projected element layers on the selected target components, then calls Mesh Edit imprint with the original node list and that Elements patch. The post-imprint target nodes are then reacquired. Ruled side 1 is always the original node list and side 2 is the post-imprint target list; correspondence is checked by physical arc length and target topology instead of blindly pairing node indices. Transverse layers are calculated per corresponding gap from gap distance divided by weld mesh size, so local spacing changes are handled locally. Closed loops receive an explicit end-to-start closure. A newly created SEAM_* component also receives the matching SEAM_Tx Property when available. No FEM export or Python runtime planning is used."]
    grid $w.main.note -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.close -text [::HWFlow::txt "关闭" "Close"] -width 10 -command "destroy .mesh_seam_weld"
    button $w.btn.more -text [::HWFlow::txt "更多" "More"] -width 10 -command "::MeshSeamWeld::showMorePanel"
    button $w.btn.save -text [::HWFlow::txt "保存" "Save"] -width 10 -command "::MeshSeamWeld::acceptPanel"
    button $w.btn.undo -text [::HWFlow::txt "撤销上一批" "Undo Last Batch"] -width 10 -command "::MeshSeamWeld::undoLast"
    pack $w.btn.close -side right -padx 4
    pack $w.btn.save -side right -padx 4
    pack $w.btn.undo -side right -padx 4
    pack $w.btn.more -side right -padx 4

    bind $w <Escape> "destroy .mesh_seam_weld"
    wm protocol $w WM_DELETE_WINDOW "destroy .mesh_seam_weld"
    ::MeshSeamWeld::updateModeUi
    ::MeshSeamWeld::centerWindow $w
    tkwait window $w
}

proc ::MeshSeamWeld::showMorePanel {} {
    variable ui
    set ui(create_geometry_surf) 0

    set w .mesh_seam_weld_more
    catch {destroy $w}
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle [::HWFlow::txt "网格焊缝 - 更多" "Mesh Seam Weld - More"] "Mesh Seam Weld - More"]
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    message $w.main.note -width 430 -text [::HWFlow::txt \
        "程序逐节点查找单调对应关系，并只连接连续有效的节点对；局部找不到对应节点或目标网格边不连续时，仅跳过该区段，不影响其余焊缝。" \
        "Nodes are matched monotonically and only consecutive valid pairs are connected. A locally unmatched node or missing target-mesh edge skips only that section, while the remaining weld is retained."]
    pack $w.main.note -anchor w -pady {8 0}

    frame $w.btn -padx 12 -pady {0 10}
    pack $w.btn -fill x
    button $w.btn.close -text [::HWFlow::txt "关闭" "Close"] -width 10 -command [list destroy $w]
    pack $w.btn.close -side right

    bind $w <Escape> [list destroy $w]
    wm protocol $w WM_DELETE_WINDOW [list destroy $w]
    ::MeshSeamWeld::centerWindow $w
    tkwait window $w
}

proc ::MeshSeamWeld::acceptPanel {} {
    variable cfg
    variable ui

    if {$ui(run_mode) eq "FAST_AUTO"} {
        foreach key {search_distance min_seam_length parallel_angle_max perpendicular_angle_min max_target_path_offset max_node_move} {
            if {![string is double -strict $ui($key)] || $ui($key) < 0} {
                tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "$key 必须为非负数。" "$key must be non-negative."]
                return
            }
        }
    }

    if {[string trim $ui(output_component)] eq ""} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "输出组件不能为空。" "Output component cannot be empty."]
        return
    }
    if {![string is double -strict $ui(weld_mesh_size)] || $ui(weld_mesh_size) <= 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "焊缝网格尺寸必须为正数。" "Weld mesh size must be positive."]
        return
    }
    if {![string is integer -strict $ui(patch_expand_layers)] || $ui(patch_expand_layers) < 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "扩展层数必须为非负整数。" "Expansion layers must be a non-negative integer."]
        return
    }
    if {![string is double -strict $ui(imprint_angle)] || $ui(imprint_angle) < 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "imprint angle 必须为非负数值。" "imprint angle must be non-negative."]
        return
    }
    if {![string is double -strict $ui(mesh_smooth_tol)] || $ui(mesh_smooth_tol) <= 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "mesh_smooth_tol 必须为正数。" "mesh_smooth_tol must be positive."]
        return
    }
    foreach key {imprint_remain imprint_remesh_mode mesh_face_shape mesh_elem_type mesh_smooth_method mesh_size_control mesh_skew_control mesh_path_param mesh_cross_param mesh_cross_size create_geometry_surf} {
        if {![string is integer -strict $ui($key)] || $ui($key) < 0} {
            tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "$key 必须为非负整数。" "$key must be a non-negative integer."]
            return
        }
    }
    if {$ui(create_geometry_surf) != 0 && $ui(create_geometry_surf) != 1} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "创建几何 surface 只能为 0（关闭）或 1（开启）。" "Create geometry surface must be 0 (off) or 1 (on)."]
        return
    }

    foreach key [::MeshSeamWeld::stateKeys] {
        set cfg($key) $ui($key)
    }
    ::MeshSeamWeld::saveState
    catch {destroy .mesh_seam_weld}
}

proc ::MeshSeamWeld::runSettings {} {
    ::MeshSeamWeld::showPanel
}

proc ::MeshSeamWeld::resetRunCaches {} {
    variable createdOutputComponents
    foreach arrayName {
        elemNodesCache nodeElemsCache elemComponentCache
        nodeFreeEdgeNeighborsCache nodeXYZCache freeEdgePrimedComponents
        targetElemGrid targetElemCentroid targetNodeToElems
    } {
        upvar #0 ::MeshSeamWeld::$arrayName cache
        catch {array unset cache}
        array set cache {}
    }
    set ::MeshSeamWeld::targetIndexCellSize 1.0
    set ::MeshSeamWeld::targetGridMin {0 0 0}
    set ::MeshSeamWeld::targetGridMax {0 0 0}
    set ::MeshSeamWeld::lastKnownNodeId 0
    set ::MeshSeamWeld::lastKnownElemId 0
    set ::MeshSeamWeld::lastImprintTargetMode target_components
    set ::MeshSeamWeld::lastImprintTargetElemCount 0
    set ::MeshSeamWeld::lastImprintCoreElemCount 0
    set ::MeshSeamWeld::lastImprintSupportElemCount 0
    set ::MeshSeamWeld::lastImprintSharedNeighborElemCount 0
    set ::MeshSeamWeld::lastImprintAffectedElemIds {}
    set ::MeshSeamWeld::lastLocalTargetNodeIds {}
    set ::MeshSeamWeld::lastLocalTargetEdges [dict create]
    set createdOutputComponents [dict create]
}

proc ::MeshSeamWeld::clearNodeSelection {} {
    # *clearmark does not clear the ordered node list used by the node-path
    # selector.  Clear both so a cancelled prior selection cannot be accepted
    # on the next entry to this module.
    foreach listId {1 2} {
        catch {*clearlist nodes $listId}
    }
    foreach markId {1 2} {
        catch {*clearmark nodes $markId}
    }
}

proc ::MeshSeamWeld::clearComponentSelection {} {
    foreach entityType {comps components} {
        foreach markId {1 2} {
            catch {*clearmark $entityType $markId}
        }
    }
}

proc ::MeshSeamWeld::clearTransientSelections {} {
    ::MeshSeamWeld::clearNodeSelection
    ::MeshSeamWeld::clearComponentSelection
}

proc ::MeshSeamWeld::pickNodes {} {
    ::MeshSeamWeld::clearNodeSelection
    set prompt [::HWFlow::txt "按路径顺序选择焊缝源节点" "Select weld source nodes in path order"]
    # The by-path collector repeatedly expands and processes adjacent elements
    # after every click.  On large models that blocks the UI even when only one
    # node is wanted.  A regular list preserves pick order without doing that
    # interactive element traversal; retain by-path only as a compatibility
    # fallback for installations where the regular list panel is unavailable.
    if {[catch {*createlistpanel nodes 1 $prompt} listErr]} {
        if {[catch {*createlistbypathpanel nodes 1 $prompt} pathErr]} {
            error [::HWFlow::txt \
                "无法打开节点列表选择面板：$listErr；备用 path 面板错误：$pathErr" \
                "Could not open the node list selection panel: $listErr; fallback path panel error: $pathErr"]
        }
    }
    set nodes {}
    catch {set nodes [hm_getlist nodes 1]}
    if {[llength $nodes] == 0} {
        catch {set nodes [hm_getmark nodes 1]}
    }
    ::MeshSeamWeld::clearNodeSelection
    return [::MeshSeamWeld::uniq $nodes]
}

proc ::MeshSeamWeld::pickComponents {} {
    ::MeshSeamWeld::clearComponentSelection
    ::HWFlow::nativeMarkPanel comps 1 [::HWFlow::txt "选择要投影到的目标网格组件" "Select target mesh components for projection"]
    set comps {}
    catch {set comps [hm_getmark comps 1]}
    ::MeshSeamWeld::clearComponentSelection
    return [::MeshSeamWeld::uniq $comps]
}

proc ::MeshSeamWeld::collectManualSelectionPairs {} {
    set selectionPairs {}
    while {1} {
        set selectedNodes [::MeshSeamWeld::pickNodes]
        if {[llength $selectedNodes] == 0} {
            break
        }

        set targetComps [::MeshSeamWeld::pickComponents]
        if {[llength $targetComps] == 0} {
            # Cancel only the unfinished pair, then return to node input.  An
            # empty node selection remains the single gesture that submits all
            # completed pairs.
            continue
        }
        if {![::MeshSeamWeld::componentsHaveElements $targetComps]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] \
                -message [::HWFlow::txt "目标组件中没有可用网格单元。" \
                    "Target components contain no usable mesh elements."]
            continue
        }
        lappend selectionPairs [dict create \
            source_nodes $selectedNodes target_components $targetComps]
    }
    return $selectionPairs
}

proc ::MeshSeamWeld::nodeXYZ {nodeId} {
    variable nodeXYZCache
    if {[info exists nodeXYZCache($nodeId)]} {
        return $nodeXYZCache($nodeId)
    }
    if {![catch {hm_getvalue nodes id=$nodeId dataname=x} x] &&
        ![catch {hm_getvalue nodes id=$nodeId dataname=y} y] &&
        ![catch {hm_getvalue nodes id=$nodeId dataname=z} z]} {
        set nodeXYZCache($nodeId) [list $x $y $z]
        return $nodeXYZCache($nodeId)
    }
    if {![catch {hm_nodevalue $nodeId} val] && [llength $val] >= 3} {
        set nodeXYZCache($nodeId) [lrange $val 0 2]
        return $nodeXYZCache($nodeId)
    }
    error [::HWFlow::txt "无法读取节点 $nodeId 坐标。" "Cannot read coordinates for node $nodeId."]
}

proc ::MeshSeamWeld::elemNodes {elemId} {
    variable elemNodesCache
    if {[info exists elemNodesCache($elemId)]} {
        return $elemNodesCache($elemId)
    }
    if {![catch {hm_getvalue elems id=$elemId dataname=nodes} nodes] && [llength $nodes] > 0} {
        set elemNodesCache($elemId) [::MeshSeamWeld::uniq $nodes]
        return $elemNodesCache($elemId)
    }
    if {![catch {hm_nodelist $elemId} nodes] && [llength $nodes] > 0} {
        set elemNodesCache($elemId) [::MeshSeamWeld::uniq $nodes]
        return $elemNodesCache($elemId)
    }
    set elemNodesCache($elemId) {}
    return {}
}

proc ::MeshSeamWeld::componentsHaveElements {compIds} {
    set allCountsAvailable 1
    foreach compId $compIds {
        set countAvailable 0
        foreach dn {elements-count elementcount numelems} {
            if {![catch {set count [hm_getvalue comps id=$compId dataname=$dn]}] &&
                [string is integer -strict $count]} {
                set countAvailable 1
                if {$count > 0} {
                    return 1
                }
                break
            }
        }
        if {!$countAvailable} {
            set allCountsAvailable 0
        }
    }
    # Older HyperMesh versions do not expose a cheap component element count.
    # Let imprint validate those models instead of selecting every target
    # element here and then processing the same elements again during imprint.
    return [expr {!$allCountsAvailable}]
}

proc ::MeshSeamWeld::elemComponentId {elemId} {
    variable elemComponentCache
    if {[info exists elemComponentCache($elemId)]} {
        return $elemComponentCache($elemId)
    }
    foreach dn {component.id collector.id comp.id component collector} {
        if {![catch {set value [hm_getvalue elems id=$elemId dataname=$dn]}] && $value ne "" && $value != 0} {
            if {[string is integer -strict $value]} {
                set elemComponentCache($elemId) $value
                return $elemComponentCache($elemId)
            }
            set compId [::HWFlow::componentIdByName $value]
            if {$compId ne ""} {
                set elemComponentCache($elemId) $compId
                return $elemComponentCache($elemId)
            }
        }
    }
    set elemComponentCache($elemId) ""
    return ""
}

proc ::MeshSeamWeld::nodeElementIds {nodeId} {
    variable nodeElemsCache
    if {[info exists nodeElemsCache($nodeId)]} {
        return $nodeElemsCache($nodeId)
    }
    foreach dn {elems elements} {
        if {![catch {set elems [hm_getvalue nodes id=$nodeId dataname=$dn]}] && [llength $elems] > 0} {
            set nodeElemsCache($nodeId) [::MeshSeamWeld::uniq $elems]
            return $nodeElemsCache($nodeId)
        }
    }

    set out {}
    foreach selector [list \
        [list "by node id" $nodeId] \
        [list "by node" $nodeId] \
        [list "by nodes" $nodeId]] {
        catch {*clearmark elems 2}
        if {![catch {eval *createmark elems 2 $selector}]} {
            catch {set out [hm_getmark elems 2]}
            if {[llength $out] > 0} {
                catch {*clearmark elems 2}
                set nodeElemsCache($nodeId) [::MeshSeamWeld::uniq $out]
                return $nodeElemsCache($nodeId)
            }
        }
        catch {*clearmark elems 2}
    }
    set nodeElemsCache($nodeId) {}
    return {}
}

proc ::MeshSeamWeld::adjacentElementsForNodes {nodeIds} {
    set nodeIds [::MeshSeamWeld::uniq $nodeIds]
    if {[llength $nodeIds] == 0} {
        return {}
    }

    catch {*clearmark elems 2}
    set marked 0
    # Query all nodes in one operation.  The old per-node fallback caused
    # HyperMesh to rebuild the element selection repeatedly.
    foreach command {hm_createmark *createmark} {
        if {![catch {eval $command elems 2 [list "by node id"] $nodeIds}]} {
            set marked 1
            break
        }
    }
    set elems {}
    if {$marked} {
        catch {set elems [hm_getmark elems 2]}
    }
    catch {*clearmark elems 2}
    return [::MeshSeamWeld::uniq $elems]
}

proc ::MeshSeamWeld::cacheNodeElementIncidence {elemIds {onlyNodeIds {}}} {
    variable nodeElemsCache

    array set wanted {}
    foreach nodeId $onlyNodeIds {
        set wanted($nodeId) 1
        set nodeElemsCache($nodeId) {}
    }
    set filter [expr {[llength $onlyNodeIds] > 0}]

    foreach elemId [::MeshSeamWeld::uniq $elemIds] {
        foreach nodeId [::MeshSeamWeld::elemNodes $elemId] {
            if {$filter && ![info exists wanted($nodeId)]} {
                continue
            }
            if {![info exists nodeElemsCache($nodeId)]} {
                set nodeElemsCache($nodeId) {}
            }
            lappend nodeElemsCache($nodeId) $elemId
        }
    }
}

proc ::MeshSeamWeld::primeSelectedNodeElements {nodeIds} {
    variable nodeElemsCache
    set missing {}
    foreach nodeId [::MeshSeamWeld::uniq $nodeIds] {
        if {![info exists nodeElemsCache($nodeId)]} {
            lappend missing $nodeId
        }
    }
    if {[llength $missing] == 0} {
        return {}
    }
    set elemIds [::MeshSeamWeld::adjacentElementsForNodes $missing]
    ::MeshSeamWeld::cacheNodeElementIncidence $elemIds $missing
    return $elemIds
}

proc ::MeshSeamWeld::primeFreeEdgeComponent {seedNode} {
    variable freeEdgePrimedComponents
    set seedElems [::MeshSeamWeld::primeSelectedNodeElements [list $seedNode]]
    if {[llength $seedElems] == 0} {
        set seedElems [::MeshSeamWeld::nodeElementIds $seedNode]
    }
    set compIds {}
    foreach elemId $seedElems {
        set compId [::MeshSeamWeld::elemComponentId $elemId]
        if {$compId ne ""} {
            lappend compIds $compId
        }
    }

    set componentElems {}
    foreach compId [::MeshSeamWeld::uniq $compIds] {
        if {[info exists freeEdgePrimedComponents($compId)]} {
            continue
        }
        if {[llength [info commands ::HWFlow::getCompEntityIds]] > 0} {
            set elems [::HWFlow::getCompEntityIds $compId elems elems]
        } else {
            set elems {}
            catch {*clearmark elems 2}
            if {![catch {*createmark elems 2 "by comp id" $compId}]} {
                catch {set elems [hm_getmark elems 2]}
            }
            catch {*clearmark elems 2}
        }
        set componentElems [concat $componentElems $elems]
        set freeEdgePrimedComponents($compId) 1
    }
    if {[llength $componentElems] > 0} {
        ::MeshSeamWeld::cacheNodeElementIncidence $componentElems
    }
}

proc ::MeshSeamWeld::componentElementIds {compId} {
    set elems {}
    if {[llength [info commands ::HWFlow::getCompEntityIds]] > 0} {
        catch {set elems [::HWFlow::getCompEntityIds $compId elems elems]}
    }
    if {[llength $elems] == 0} {
        catch {*clearmark elems 2}
        if {![catch {*createmark elems 2 "by comp id" $compId}]} {
            catch {set elems [hm_getmark elems 2]}
        }
        catch {*clearmark elems 2}
    }
    return [::MeshSeamWeld::uniq $elems]
}

proc ::MeshSeamWeld::canonicalEdgeKey {a b} {
    if {$a < $b} { return "$a,$b" }
    return "$b,$a"
}

proc ::MeshSeamWeld::componentFreeEdgeGraph {compId} {
    return [::MeshSeamWeld::freeEdgeGraphFromElements \
        [::MeshSeamWeld::componentElementIds $compId]]
}

proc ::MeshSeamWeld::loadAutoRules {} {
    variable cfg
    variable MODULE_DIR
    set path [file join [file dirname [file dirname $MODULE_DIR]] config mesh_seam_auto_rules.txt]
    if {![file isfile $path]} { return }
    set channel [open $path r]
    fconfigure $channel -encoding utf-8
    set content [read $channel]
    close $channel
    foreach line [split $content "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        set fields [split $line |]
        if {[llength $fields] < 2} { continue }
        set key [string trim [lindex $fields 0]]
        set value [string trim [lindex $fields 1]]
        if {[info exists cfg($key)]} { set cfg($key) $value }
    }
}

proc ::MeshSeamWeld::freeEdgeGraphFromElements {elemIds} {
    array set edgeCount {}
    array set edgeEnds {}
    set connectivity [::MeshSeamWeld::readShellElementConnectivityBulk $elemIds]
    set processed 0
    foreach elemId [lsort -integer -unique $elemIds] {
        if {![dict exists $connectivity $elemId]} { continue }
        set nodes [dict get $connectivity $elemId]
        set count [llength $nodes]
        if {$count < 3} { continue }
        for {set i 0} {$i < $count} {incr i} {
            set a [lindex $nodes $i]
            set b [lindex $nodes [expr {($i + 1) % $count}]]
            if {$a == $b} { continue }
            set key [::MeshSeamWeld::canonicalEdgeKey $a $b]
            if {![info exists edgeCount($key)]} {
                set edgeCount($key) 0
                set edgeEnds($key) [list $a $b]
            }
            incr edgeCount($key)
        }
        incr processed
        if {$processed % 1024 == 0} { ::HybridCore::cooperativeYield }
    }
    array set graph {}
    foreach key [array names edgeCount] {
        if {$edgeCount($key) != 1} { continue }
        foreach {a b} $edgeEnds($key) break
        lappend graph($a) $b
        lappend graph($b) $a
    }
    set result [dict create]
    foreach nodeId [array names graph] {
        dict set result $nodeId [lsort -integer -unique $graph($nodeId)]
    }
    return $result
}

proc ::MeshSeamWeld::closedLoopsFromFreeEdgeGraph {graph} {
    set loops {}
    array set visited {}
    set traversed 0
    foreach seed [lsort -integer [dict keys $graph]] {
        if {[info exists visited($seed)]} { continue }
        set queue [list $seed]
        set queueIndex 0
        set region {}
        set isClosed 1
        catch {array unset inRegion}
        array set inRegion {}
        while {$queueIndex < [llength $queue]} {
            set nodeId [lindex $queue $queueIndex]
            incr queueIndex
            if {[info exists inRegion($nodeId)]} { continue }
            set inRegion($nodeId) 1
            set visited($nodeId) 1
            lappend region $nodeId
            incr traversed
            ::MeshSeamWeld::responsiveCheckpoint $traversed 512
            set neighbors [dict get $graph $nodeId]
            if {[llength $neighbors] != 2} { set isClosed 0 }
            foreach neighbor $neighbors {
                if {![info exists inRegion($neighbor)]} { lappend queue $neighbor }
            }
        }
        if {!$isClosed || [llength $region] < 3} { continue }
        set loop [list $seed]
        catch {array unset walked}
        array set walked [list $seed 1]
        set previous $seed
        set current [lindex [dict get $graph $seed] 0]
        while {$current != $seed} {
            if {[info exists walked($current)]} {
                set loop {}
                break
            }
            set walked($current) 1
            lappend loop $current
            incr traversed
            ::MeshSeamWeld::responsiveCheckpoint $traversed 512
            set next ""
            foreach neighbor [dict get $graph $current] {
                if {$neighbor != $previous} {
                    set next $neighbor
                    break
                }
            }
            if {$next eq ""} {
                set loop {}
                break
            }
            set previous $current
            set current $next
        }
        if {[llength $loop] >= 3} { lappend loops $loop }
    }
    return $loops
}

proc ::MeshSeamWeld::sourcePathsForSingleNode {nodeId} {
    set compIds [::MeshSeamWeld::componentIdsFromNodes [list $nodeId]]
    if {[llength $compIds] == 0} {
        error [::HWFlow::txt \
            "节点 $nodeId 不属于任何有网格单元的 component。" \
            "Node $nodeId does not belong to a component containing mesh elements."]
    }
    set allLoops {}
    array set seen {}
    foreach compId $compIds {
        set graph [::MeshSeamWeld::componentFreeEdgeGraph $compId]
        set componentLoops [::MeshSeamWeld::closedLoopsFromFreeEdgeGraph $graph]
        if {[dict exists $graph $nodeId]} {
            set loops {}
            foreach loop $componentLoops {
                if {[lsearch -exact $loop $nodeId] >= 0} {
                    set loops [list $loop]
                    break
                }
            }
            if {[llength $loops] == 0} {
                error [::HWFlow::txt \
                    "节点 $nodeId 位于自由边界上，但该边界不是有效闭环。" \
                    "Node $nodeId is on a free edge, but that boundary is not a valid closed loop."]
            }
        } else {
            set loops $componentLoops
        }
        foreach loop $loops {
            set signature [join [lsort -integer $loop] ,]
            if {![info exists seen($signature)]} {
                set seen($signature) 1
                lappend allLoops $loop
            }
        }
    }
    if {[llength $allLoops] == 0} {
        error [::HWFlow::txt \
            "节点 $nodeId 所属 component 上没有可用的闭合自由边界。" \
            "The component containing node $nodeId has no usable closed free-edge loop."]
    }
    return $allLoops
}

proc ::MeshSeamWeld::elementContainsEdge {elemId a b} {
    set nodes [::MeshSeamWeld::elemNodes $elemId]
    set count [llength $nodes]
    if {$count < 3} {
        return 0
    }
    for {set i 0} {$i < $count} {incr i} {
        set n1 [lindex $nodes $i]
        set n2 [lindex $nodes [expr {($i + 1) % $count}]]
        if {($n1 == $a && $n2 == $b) || ($n1 == $b && $n2 == $a)} {
            return 1
        }
    }
    return 0
}

proc ::MeshSeamWeld::nodesShareElementEdge {a b} {
    ::MeshSeamWeld::primeSelectedNodeElements [list $a $b]
    foreach elemId [::MeshSeamWeld::nodeElementIds $a] {
        if {[lsearch -exact [::MeshSeamWeld::nodeElementIds $b] $elemId] >= 0 &&
            [::MeshSeamWeld::elementContainsEdge $elemId $a $b]} {
            return 1
        }
    }
    return 0
}

proc ::MeshSeamWeld::selectedNodesFormContinuousPath {nodeIds} {
    if {[llength $nodeIds] < 2} {
        return 0
    }
    ::MeshSeamWeld::primeSelectedNodeElements $nodeIds
    for {set i 1} {$i < [llength $nodeIds]} {incr i} {
        if {![::MeshSeamWeld::nodesShareElementEdge \
            [lindex $nodeIds [expr {$i - 1}]] [lindex $nodeIds $i]]} {
            return 0
        }
    }
    return 1
}

proc ::MeshSeamWeld::freeEdgeNeighbors {nodeId} {
    variable nodeFreeEdgeNeighborsCache
    if {[info exists nodeFreeEdgeNeighborsCache($nodeId)]} {
        return $nodeFreeEdgeNeighborsCache($nodeId)
    }

    # Inspect only the one-ring of this node.  This avoids constructing a
    # full-model edge graph when the user supplies one seed node.
    array set candidates {}
    set ownerElems [::MeshSeamWeld::nodeElementIds $nodeId]
    foreach elemId $ownerElems {
        set nodes [::MeshSeamWeld::elemNodes $elemId]
        set count [llength $nodes]
        if {$count ni {3 4}} {
            continue
        }
        for {set i 0} {$i < $count} {incr i} {
            set n1 [lindex $nodes $i]
            set n2 [lindex $nodes [expr {($i + 1) % $count}]]
            if {$n1 == $nodeId && $n2 != $nodeId} {
                set candidates($n2) 1
            } elseif {$n2 == $nodeId && $n1 != $nodeId} {
                set candidates($n1) 1
            }
        }
    }

    set neighbors {}
    foreach neighbor [array names candidates] {
        set owners {}
        foreach elemId $ownerElems {
            if {[llength [::MeshSeamWeld::elemNodes $elemId]] ni {3 4}} {
                continue
            }
            if {[::MeshSeamWeld::elementContainsEdge $elemId $nodeId $neighbor]} {
                lappend owners $elemId
            }
        }
        if {[llength [::MeshSeamWeld::uniq $owners]] == 1} {
            lappend neighbors $neighbor
        }
    }
    set nodeFreeEdgeNeighborsCache($nodeId) [lsort -integer -unique $neighbors]
    return $nodeFreeEdgeNeighborsCache($nodeId)
}

proc ::MeshSeamWeld::closedFreeEdgeLoopFromNode {seedNode} {
    set firstNeighbors [::MeshSeamWeld::freeEdgeNeighbors $seedNode]
    if {[llength $firstNeighbors] != 2} {
        error [::HWFlow::txt \
            "节点 $seedNode 不位于唯一的闭合自由边上（该节点检测到 [llength $firstNeighbors] 条自由边）。请选择同一闭环上的两个或更多节点。" \
            "Node $seedNode is not on one closed free-edge loop ([llength $firstNeighbors] free edges found at the node). Select two or more nodes on the same loop."]
    }

    set loop [list $seedNode]
    array set visited [list $seedNode 1]
    set previous $seedNode
    set current [lindex $firstNeighbors 0]
    set limit 100000
    while {1} {
        if {$current == $seedNode} {
            break
        }
        if {[info exists visited($current)]} {
            error [::HWFlow::txt \
                "自由边路径在回到起始节点前发生自交，不能自动创建焊缝。请选择两个或更多节点。" \
                "The free-edge path self-intersects before returning to its start node; select two or more nodes."]
        }
        if {[llength $loop] >= $limit} {
            error [::HWFlow::txt \
                "自由边路径过长，已停止自动闭环检测。请选择两个或更多节点。" \
                "The free-edge path is too long; select two or more nodes."]
        }
        set visited($current) 1
        lappend loop $current
        set neighbors [::MeshSeamWeld::freeEdgeNeighbors $current]
        if {[llength $neighbors] != 2} {
            error [::HWFlow::txt \
                "自由边在节点 $current 处不是闭合流形路径，不能自动创建焊缝。请选择两个或更多节点。" \
                "The free edge is not a closed manifold path at node $current; select two or more nodes."]
        }
        set next ""
        foreach neighbor $neighbors {
            if {$neighbor != $previous} {
                set next $neighbor
                break
            }
        }
        if {$next eq ""} {
            error [::HWFlow::txt \
                "无法继续追踪节点 $current 处的自由边。请选择两个或更多节点。" \
                "Cannot continue tracing the free edge at node $current; select two or more nodes."]
        }
        set previous $current
        set current $next
    }
    if {[llength $loop] < 3} {
        error [::HWFlow::txt \
            "检测到的自由边闭环节点数不足 3。请选择两个或更多节点。" \
            "The detected free-edge loop has fewer than three nodes; select two or more nodes."]
    }
    return $loop
}

proc ::MeshSeamWeld::closedFreeEdgeLoopsFromSeeds {seedNodes} {
    set loops {}
    array set seenLoops {}
    foreach seedNode $seedNodes {
        ::MeshSeamWeld::primeFreeEdgeComponent $seedNode
        set loop [::MeshSeamWeld::closedFreeEdgeLoopFromNode $seedNode]
        set signature [join [lsort -integer $loop] ,]
        if {[info exists seenLoops($signature)]} {
            continue
        }
        set seenLoops($signature) 1
        lappend loops $loop
    }
    return $loops
}

proc ::MeshSeamWeld::selectedNodesAreSimpleFreeEdgeSeeds {nodeIds} {
    if {[llength $nodeIds] < 2} {
        return 0
    }
    # One bulk query is enough to classify the selected seeds.  Do not export
    # either source or target components merely to decide whether these nodes
    # lie on ordinary manifold boundaries.
    ::MeshSeamWeld::primeSelectedNodeElements $nodeIds
    foreach nodeId [::MeshSeamWeld::uniq $nodeIds] {
        if {[llength [::MeshSeamWeld::freeEdgeNeighbors $nodeId]] != 2} {
            return 0
        }
    }
    return 1
}

proc ::MeshSeamWeld::closedFreeEdgeLoopsFromSeedsLocal {seedNodes} {
    # Trace only the loops touched by the selected seeds.  Nodes encountered
    # while walking the loop query their one-ring lazily, so this path scales
    # with the selected boundaries instead of the full source component.
    ::MeshSeamWeld::primeSelectedNodeElements $seedNodes
    set loops {}
    array set seenLoops {}
    foreach seedNode [::MeshSeamWeld::uniq $seedNodes] {
        set loop [::MeshSeamWeld::closedFreeEdgeLoopFromNode $seedNode]
        set signature [join [lsort -integer $loop] ,]
        if {[info exists seenLoops($signature)]} {
            continue
        }
        set seenLoops($signature) 1
        lappend loops $loop
    }
    return $loops
}

proc ::MeshSeamWeld::edgeGraphFromPlotElements {edgeElemIds} {
    set graph [dict create]
    set connectivity [::MeshSeamWeld::readElementConnectivityBulk \
        $edgeElemIds {2}]
    set processed 0
    foreach elemId [lsort -integer -unique $edgeElemIds] {
        if {![dict exists $connectivity $elemId]} { continue }
        set nodes [dict get $connectivity $elemId]
        lassign $nodes first second
        if {$first == $second} { continue }
        dict lappend graph $first $second
        dict lappend graph $second $first
        incr processed
        ::MeshSeamWeld::responsiveCheckpoint $processed 512
    }
    set processed 0
    foreach nodeId [dict keys $graph] {
        dict set graph $nodeId [lsort -integer -unique [dict get $graph $nodeId]]
        incr processed
        ::MeshSeamWeld::responsiveCheckpoint $processed 1024
    }
    return $graph
}

proc ::MeshSeamWeld::renameComponentById {componentId newName} {
    set oldName [::HWFlow::componentName $componentId]
    if {$oldName eq $newName} { return $componentId }
    set lastErr ""
    foreach entityType {component components comps} {
        if {![catch {*renamecollector $entityType $oldName $newName} renameErr]} {
            return $componentId
        }
        set lastErr $renameErr
    }
    error "Could not rename component $oldName to $newName: $lastErr"
}

proc ::MeshSeamWeld::deleteComponentById {componentId} {
    if {$componentId eq ""} { return 0 }
    foreach entityType {components comps} {
        foreach selector [list [list $componentId] [list "by id only" $componentId]] {
            catch {*clearmark $entityType 2}
            if {![catch {eval *createmark $entityType 2 $selector}]} {
                set marked {}
                catch {set marked [hm_getmark $entityType 2]}
                if {[lsearch -exact $marked $componentId] >= 0} {
                    set deleted [expr {![catch {*deletemark $entityType 2}]}]
                    catch {*clearmark $entityType 2}
                    return $deleted
                }
            }
        }
        catch {*clearmark $entityType 2}
    }
    return 0
}

proc ::MeshSeamWeld::createNativeFreeEdgeComponent {sourceComponentId serial} {
    # HyperMesh 2019 creates PLOTEL free edges in the global ^edges
    # component. Preserve any user-created ^edges collector, rename the new
    # result to a task-owned hidden component, and restore the original.
    set existingEdgesId [::HWFlow::componentIdByName "^edges"]
    set preservedName ""
    if {$existingEdgesId ne ""} {
        set preservedName "^MSW_KEEP_[expr {abs([clock clicks])}]"
        ::MeshSeamWeld::renameComponentById $existingEdgesId $preservedName
    }

    set edgeComponentId ""
    set edgeComponentName "^MSWE_${sourceComponentId}_${serial}"
    set staleEdgeComponentId [::HWFlow::componentIdByName $edgeComponentName]
    if {$staleEdgeComponentId ne "" && $staleEdgeComponentId != $existingEdgesId} {
        ::MeshSeamWeld::deleteComponentById $staleEdgeComponentId
    }
    set code [catch {
        if {![::MeshSeamWeld::markComponents [list $sourceComponentId] 1]} {
            error "Could not mark source component $sourceComponentId for native free-edge discovery."
        }
        *findedges comps 1 0
        set edgeComponentId [::HWFlow::componentIdByName "^edges"]
        if {$edgeComponentId eq "" || $edgeComponentId == $existingEdgesId} {
            error "HyperMesh did not create a new ^edges component for source component $sourceComponentId."
        }
        ::MeshSeamWeld::renameComponentById $edgeComponentId $edgeComponentName
    } edgeErr]
    catch {*clearmark comps 1}
    catch {*clearmark components 1}

    if {$code} {
        set strandedEdgesId [::HWFlow::componentIdByName "^edges"]
        if {$strandedEdgesId ne "" && $strandedEdgesId != $existingEdgesId} {
            catch {::MeshSeamWeld::deleteComponentById $strandedEdgesId}
        }
        if {$edgeComponentId ne "" && $edgeComponentId != $existingEdgesId} {
            catch {::MeshSeamWeld::deleteComponentById $edgeComponentId}
        }
    }
    if {$preservedName ne ""} {
        if {[catch {
            ::MeshSeamWeld::renameComponentById $existingEdgesId "^edges"
        } restoreErr]} {
            append edgeErr " Existing ^edges restoration also failed: $restoreErr"
            set code 1
        }
    }
    if {$code} {
        if {$edgeComponentId ne "" && $edgeComponentId != $existingEdgesId} {
            catch {::MeshSeamWeld::deleteComponentById $edgeComponentId}
        }
        error $edgeErr
    }
    return $edgeComponentId
}

proc ::MeshSeamWeld::buildNativeFreeEdgeGraphs {sourceComponentIds} {
    set graphs [dict create]
    set temporaryComponents {}
    set code [catch {
        set serial 0
        set sourceComponentIds [lsort -integer -unique $sourceComponentIds]
        set sourceComponentCount [llength $sourceComponentIds]
        foreach sourceComponentId $sourceComponentIds {
            incr serial
            ::HybridCore::progressUpdate \
                [expr {1.0 + 1.5*$serial/double(max(1,$sourceComponentCount))}] \
                "Mesh Seam Weld" \
                "Finding native free edges $serial/$sourceComponentCount..." 1
            set edgeComponentId [::MeshSeamWeld::createNativeFreeEdgeComponent \
                $sourceComponentId $serial]
            lappend temporaryComponents $edgeComponentId
            set edgeElements [::MeshSeamWeld::componentElementIds $edgeComponentId]
            set graph [::MeshSeamWeld::edgeGraphFromPlotElements $edgeElements]
            if {[dict size $graph] == 0} {
                error "Native free-edge component for source component $sourceComponentId contains no two-node PLOTEL edges."
            }
            dict set graphs $sourceComponentId $graph
            ::MeshSeamWeld::responsiveCheckpoint $serial 1
        }
    } graphErr]
    foreach componentId $temporaryComponents {
        catch {::MeshSeamWeld::deleteComponentById $componentId}
    }
    if {$code} { error $graphErr }
    return $graphs
}

proc ::MeshSeamWeld::pathBetweenClosedFreeEdgeNodes {loop startNode endNode} {
    set count [llength $loop]
    set startIndex [lsearch -exact $loop $startNode]
    set endIndex [lsearch -exact $loop $endNode]
    if {$startIndex < 0 || $endIndex < 0 || $startNode == $endNode} {
        error "The selected endpoint pair is not two distinct nodes on the same free boundary."
    }

    # A closed boundary has two possible paths between the endpoints.  Select
    # the shorter node path so a pair of picks describes one open seam span,
    # rather than silently expanding back to the whole loop.  Preserve the
    # first selected node as the path start; this keeps source/target
    # correspondence deterministic for equal-length alternatives.
    set forward [list $startNode]
    set index $startIndex
    while {$index != $endIndex} {
        set index [expr {($index + 1) % $count}]
        lappend forward [lindex $loop $index]
    }
    set reverse [list $startNode]
    set index $startIndex
    while {$index != $endIndex} {
        set index [expr {($index - 1 + $count) % $count}]
        lappend reverse [lindex $loop $index]
    }
    if {[llength $reverse] < [llength $forward]} {
        return $reverse
    }
    return $forward
}

proc ::MeshSeamWeld::pathsFromNativeFreeEdgeGraphs {selectedNodes graphsByComponent {pairBoundaryMode 0}} {
    set selectedNodes [::MeshSeamWeld::uniq $selectedNodes]
    set allLoops {}
    foreach componentId [lsort -integer [dict keys $graphsByComponent]] {
        foreach loop [::MeshSeamWeld::closedLoopsFromFreeEdgeGraph \
            [dict get $graphsByComponent $componentId]] {
            lappend allLoops [list $componentId $loop]
        }
    }
    if {[llength $allLoops] == 0} {
        error "HyperMesh native edge components contain no valid closed free-edge loops."
    }

    if {$pairBoundaryMode} {
        if {[llength $selectedNodes] < 2 || [llength $selectedNodes] % 2 != 0} {
            error [::HWFlow::txt \
                "边界端点数量必须为大于等于 2 的偶数；每条自由边界必须选择两个点。" \
                "Boundary endpoint count must be an even number of at least 2; select exactly two points on each free boundary."]
        }

        array set loopForNode {}
        array set loopByKey {}
        array set nodesForLoop {}
        set loopKeys {}
        foreach row $allLoops {
            lassign $row componentId loop
            set loopKey "${componentId}:[join [lsort -integer $loop] ,]"
            set loopByKey($loopKey) $loop
            foreach nodeId $loop {
                if {[info exists loopForNode($nodeId)] &&
                    $loopForNode($nodeId) ne $loopKey} {
                    error [::HWFlow::txt \
                        "节点 $nodeId 同时属于多个自由边界，无法确定端点配对。" \
                        "Node $nodeId belongs to more than one free boundary, so its endpoint pair is ambiguous."]
                }
                set loopForNode($nodeId) $loopKey
            }
        }

        foreach nodeId $selectedNodes {
            if {![info exists loopForNode($nodeId)]} {
                error [::HWFlow::txt \
                    "节点 $nodeId 不在有效的闭合自由边界上；批量边界模式要求所有节点都为边界端点。" \
                    "Node $nodeId is not on a valid closed free boundary; boundary-pair mode requires every node to be a boundary endpoint."]
            }
            set loopKey $loopForNode($nodeId)
            if {![info exists nodesForLoop($loopKey)]} {
                set nodesForLoop($loopKey) {}
                lappend loopKeys $loopKey
            }
            lappend nodesForLoop($loopKey) $nodeId
        }

        set matchedPaths {}
        foreach loopKey $loopKeys {
            set endpoints [::MeshSeamWeld::uniq $nodesForLoop($loopKey)]
            if {[llength $endpoints] != 2} {
                error [::HWFlow::txt \
                    "同一自由边界上只能选择两个点；当前边界选择了 [llength $endpoints] 个点。" \
                    "Only two points may be selected on one free boundary; this boundary has [llength $endpoints] selected points."]
            }
            set loop $loopByKey($loopKey)
            lappend matchedPaths [::MeshSeamWeld::pathBetweenClosedFreeEdgeNodes \
                $loop [lindex $endpoints 0] [lindex $endpoints 1]]
        }
        if {[llength $matchedPaths] == 0} {
            error [::HWFlow::txt \
                "没有生成有效的边界端点路径。" \
                "No valid boundary endpoint paths were generated."]
        }
        return [dict create paths $matchedPaths internal_single_node 0 \
            pair_boundary_mode 1 closed_loop 0]
    }

    set matchedPaths {}
    array set seen {}
    foreach selectedNode $selectedNodes {
        set nodeMatches {}
        foreach row $allLoops {
            set loop [lindex $row 1]
            if {[lsearch -exact $loop $selectedNode] >= 0} {
                lappend nodeMatches $loop
            }
        }
        if {[llength $nodeMatches] > 1} {
            error "Selected node $selectedNode belongs to more than one native free-edge loop."
        }
        if {[llength $nodeMatches] == 1} {
            set loop [lindex $nodeMatches 0]
            set signature [join [lsort -integer $loop] ,]
            if {![info exists seen($signature)]} {
                set seen($signature) 1
                lappend matchedPaths $loop
            }
        } elseif {[llength $selectedNodes] > 1} {
            error "Selected node $selectedNode is not on a valid native free-edge loop."
        }
    }

    set internalSingleNode [expr {
        [llength $selectedNodes] == 1 && [llength $matchedPaths] == 0}]
    if {$internalSingleNode} {
        set selectedNode [lindex $selectedNodes 0]
        foreach componentId [dict keys $graphsByComponent] {
            if {[dict exists [dict get $graphsByComponent $componentId] $selectedNode]} {
                error "Selected node $selectedNode is on an open, branched, or non-manifold native free edge."
            }
        }
        # The seed may be shared by multiple source components.  The native
        # graphs were already built only for components returned by
        # componentIdsFromNodes, so accepting all of them here does not widen
        # the model search scope; it simply lets one internal seed select the
        # free-edge loops of every participating source component.
        foreach row $allLoops {
            set loop [lindex $row 1]
            set signature [join [lsort -integer $loop] ,]
            if {![info exists seen($signature)]} {
                set seen($signature) 1
                lappend matchedPaths $loop
            }
        }
    }
    if {[llength $matchedPaths] == 0} {
        error "No native free-edge loop matches the selected nodes."
    }
    return [dict create paths $matchedPaths internal_single_node $internalSingleNode \
        pair_boundary_mode 0 closed_loop 1]
}

proc ::MeshSeamWeld::closedFreeEdgeLoopsFromSeedsBulk {seedNodes} {
    # A long loop must not issue one HyperMesh ownership query per boundary
    # node. Read each touched source component once, derive all free-boundary
    # nodes in memory, and only then select the loops containing the seeds.
    set seedNodes [::MeshSeamWeld::uniq $seedNodes]
    array set seedSet {}
    foreach seedNode $seedNodes { set seedSet($seedNode) 1 }
    set componentIds [::MeshSeamWeld::componentIdsFromNodes $seedNodes]
    set loopsBySeed [dict create]
    foreach componentId $componentIds {
        set componentElems [::MeshSeamWeld::componentElementIds $componentId]
        if {[llength $componentElems] == 0} { continue }
        set graph [::MeshSeamWeld::freeEdgeGraphFromElements $componentElems]
        foreach loop [::MeshSeamWeld::closedLoopsFromFreeEdgeGraph $graph] {
            foreach nodeId $loop {
                if {[info exists seedSet($nodeId)]} {
                    dict set loopsBySeed $nodeId $loop
                }
            }
        }
    }

    set loops {}
    array set seenLoops {}
    foreach seedNode $seedNodes {
        if {![dict exists $loopsBySeed $seedNode]} {
            error [::HWFlow::txt \
                "节点 $seedNode 不在有效的闭合自由边界上。" \
                "Node $seedNode is not on a valid closed free-edge boundary."]
        }
        set loop [dict get $loopsBySeed $seedNode]
        set signature [join [lsort -integer $loop] ,]
        if {[info exists seenLoops($signature)]} { continue }
        set seenLoops($signature) 1
        lappend loops $loop
    }
    return $loops
}

proc ::MeshSeamWeld::componentIdsFromNodes {nodeIds} {
    ::MeshSeamWeld::primeSelectedNodeElements $nodeIds
    set out {}
    foreach nodeId $nodeIds {
        foreach elemId [::MeshSeamWeld::nodeElementIds $nodeId] {
            set compId [::MeshSeamWeld::elemComponentId $elemId]
            if {$compId ne ""} {
                lappend out $compId
            }
        }
    }
    return [::MeshSeamWeld::uniq $out]
}

proc ::MeshSeamWeld::componentNames {compIds} {
    set names {}
    foreach compId [::MeshSeamWeld::uniq $compIds] {
        if {$compId eq ""} {
            continue
        }
        lappend names [::HWFlow::componentName $compId]
    }
    return [::MeshSeamWeld::uniq $names]
}

proc ::MeshSeamWeld::thicknessFromComponentName {name} {
    if {[llength [info commands ::HWFlow::thicknessFromComponentName]] > 0} {
        return [::HWFlow::thicknessFromComponentName $name]
    }
    return ""
}

proc ::MeshSeamWeld::isWeldComponentName {name} {
    set normalized [string toupper [string trim $name]]
    if {$normalized eq ""} {
        return 0
    }
    # SEAM_Tx is the normal output naming convention.  The other prefixes
    # cover the configured fallback collector and the temporary native-edge
    # collectors used while discovering free boundaries.  Do not classify a
    # normal component such as PANEL_SEAMLESS as a weld component merely
    # because its name contains the word SEAM.
    return [expr {
        [regexp {^SEAM(?:_|$)} $normalized] ||
        [regexp {^MESH_SEAM_WELD(?:_|$)} $normalized] ||
        [regexp {^\^?MSWE(?:_|$)} $normalized]
    }]
}

proc ::MeshSeamWeld::formatThickness {thickness} {
    if {[llength [info commands ::HWFlow::formatThicknessToken]] > 0} {
        return [::HWFlow::formatThicknessToken $thickness]
    }
    return [format "%.6g" $thickness]
}

proc ::MeshSeamWeld::seamComponentForRelatedComps {relatedCompIds} {
    variable cfg

    set minThickness ""
    foreach name [::MeshSeamWeld::componentNames $relatedCompIds] {
        if {[::MeshSeamWeld::isWeldComponentName $name]} {
            continue
        }
        set thickness [::MeshSeamWeld::thicknessFromComponentName $name]
        if {$thickness eq ""} {
            continue
        }
        if {$minThickness eq "" || $thickness < $minThickness} {
            set minThickness $thickness
        }
    }

    if {$minThickness eq ""} {
        return [string trim $cfg(output_component)]
    }
    return "SEAM_T[::MeshSeamWeld::formatThickness $minThickness]"
}

proc ::MeshSeamWeld::moveElemsToComponent {elemIds compName} {
    set elemIds [::MeshSeamWeld::uniq $elemIds]
    if {[llength $elemIds] == 0 || [string trim $compName] eq ""} {
        return 0
    }
    ::MeshSeamWeld::ensureOutputComponent $compName 11
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 $elemIds}]} {
        return 0
    }
    set ok [expr {![catch {*movemark elems 1 $compName}]}]
    catch {*clearmark elems 1}
    return $ok
}

proc ::MeshSeamWeld::ensureOutputComponent {compName {color 11}} {
    variable createdOutputComponents
    set compName [string trim $compName]
    if {$compName eq ""} {
        error [::HWFlow::txt "焊缝输出组件名称不能为空。" "The weld output component name cannot be empty."]
    }

    set compId [::HWFlow::componentIdByName $compName]
    set created 0
    if {$compId eq ""} {
        # Do not call ::HWFlow::createComponent here.  Its Browser creation
        # route is useful for interactive tools, but opens the unwanted
        # Create Component dialog for every new weld output component.
        set createCode [catch {*createentity comps includeid=0 name=$compName} err1]
        if {$createCode} {
            set createCode [catch {*createentity components includeid=0 name=$compName} err1]
        }
        if {$createCode} {
            set createCode [catch {*collectorcreateonly comps $compName "" $color} err2]
        }
        if {$createCode} {
            set createCode [catch {*collectorcreateonly components $compName "" $color} err2]
        }
        if {$createCode} {
            error [::HWFlow::txt \
                "无法静默创建焊缝输出组件 $compName：$err1 / $err2" \
                "Cannot create weld output component $compName without UI: $err1 / $err2"]
        }
        set compId [::HWFlow::componentIdByName $compName]
        if {$compId ne ""} {
            set created 1
        }
    }

    if {$compId ne "" && $color ne ""} {
        foreach entityType {comps components} {
            catch {*setvalue $entityType id=$compId color=$color}
        }
    }
    catch {*currentcollector component $compName}
    catch {*currentcollector components $compName}
    if {$created && [regexp -nocase {^SEAM(?:_|$)} $compName]} {
        dict set createdOutputComponents $compName $compId
    }
    return $compId
}

proc ::MeshSeamWeld::assignCreatedSeamComponentProperties {componentNames} {
    variable MODULE_DIR
    variable createdOutputComponents

    set assigned {}
    set failures {}
    if {[dict size $createdOutputComponents] == 0} {
        return [dict create assigned $assigned failures $failures]
    }

    # The toolkit normally sources modules in order and therefore already has
    # BatchPropertyAssignment loaded. Keep a lazy-load fallback for callers
    # that source MeshSeamWeld directly (including HM command-file smoke tests).
    if {[llength [info commands ::BatchPropertyAssignment::parseComponentName]] == 0} {
        set propertyModule [file join [file dirname $MODULE_DIR] batch_property_assignment.tcl]
        if {[file isfile $propertyModule]} {
            catch {
                if {[llength [info commands ::HWFlow::sourceUtf8]] > 0} {
                    ::HWFlow::sourceUtf8 $propertyModule
                } else {
                    source -encoding utf-8 $propertyModule
                }
            }
        }
    }

    foreach componentName [::MeshSeamWeld::uniq $componentNames] {
        if {![regexp -nocase {^SEAM(?:_|$)} $componentName] ||
            ![dict exists $createdOutputComponents $componentName]} {
            continue
        }
        set componentId [dict get $createdOutputComponents $componentName]
        set assignmentCode [catch {
            if {[llength [info commands ::BatchPropertyAssignment::parseComponentName]] == 0} {
                error "Batch Property Assignment module is unavailable."
            }
            set parsed [::BatchPropertyAssignment::parseComponentName $componentName]
            if {[dict size $parsed] == 0 || ![dict exists $parsed property_name]} {
                error "Could not derive a SEAM property from component name $componentName."
            }
            set materialName [dict get $parsed material]
            set materialId [::BatchPropertyAssignment::materialIdByName $materialName]
            if {$materialId eq "" && [string equal -nocase $materialName Steel]} {
                set materialId [::BatchPropertyAssignment::ensureSteelMaterial]
            }
            if {$materialId eq ""} {
                error "Material $materialName was not found."
            }
            set propertyName [dict get $parsed property_name]
            set propertyId [::BatchPropertyAssignment::ensureProperty \
                $propertyName [dict get $parsed thickness] $materialId]
            if {![::BatchPropertyAssignment::assignProperty \
                $componentId $propertyId $propertyName]} {
                error "Property $propertyName assignment or verification failed."
            }
            lappend assigned [list $componentName $propertyName]
        } assignmentError]
        if {$assignmentCode} {
            lappend failures [list $componentName $assignmentError]
            catch {::HybridCore::log WARN \
                "mesh seam weld SEAM property assignment failed component=$componentName error=$assignmentError"}
        }
    }
    return [dict create assigned $assigned failures $failures]
}

proc ::MeshSeamWeld::vsub {a b} {
    return [list [expr {[lindex $a 0] - [lindex $b 0]}] [expr {[lindex $a 1] - [lindex $b 1]}] [expr {[lindex $a 2] - [lindex $b 2]}]]
}

proc ::MeshSeamWeld::vadd {a b} {
    return [list [expr {[lindex $a 0] + [lindex $b 0]}] [expr {[lindex $a 1] + [lindex $b 1]}] [expr {[lindex $a 2] + [lindex $b 2]}]]
}

proc ::MeshSeamWeld::vscale {a s} {
    return [list [expr {[lindex $a 0] * $s}] [expr {[lindex $a 1] * $s}] [expr {[lindex $a 2] * $s}]]
}

proc ::MeshSeamWeld::dot {a b} {
    expr {[lindex $a 0]*[lindex $b 0] + [lindex $a 1]*[lindex $b 1] + [lindex $a 2]*[lindex $b 2]}
}

proc ::MeshSeamWeld::cross {a b} {
    return [list \
        [expr {[lindex $a 1]*[lindex $b 2] - [lindex $a 2]*[lindex $b 1]}] \
        [expr {[lindex $a 2]*[lindex $b 0] - [lindex $a 0]*[lindex $b 2]}] \
        [expr {[lindex $a 0]*[lindex $b 1] - [lindex $a 1]*[lindex $b 0]}]]
}

proc ::MeshSeamWeld::circumcenterFromPath {nodeIds} {
    if {[llength $nodeIds] < 3} { return {} }
    set first [::MeshSeamWeld::nodeXYZ [lindex $nodeIds 0]]
    set middle [::MeshSeamWeld::nodeXYZ \
        [lindex $nodeIds [expr {[llength $nodeIds] / 2}]]]
    set last [::MeshSeamWeld::nodeXYZ [lindex $nodeIds end]]
    set u [::MeshSeamWeld::vsub $middle $first]
    set v [::MeshSeamWeld::vsub $last $first]
    set normal [::MeshSeamWeld::cross $u $v]
    set normal2 [::MeshSeamWeld::dot $normal $normal]
    if {$normal2 <= 1.0e-16} { return {} }
    set term1 [::MeshSeamWeld::vscale \
        [::MeshSeamWeld::cross $v $normal] [::MeshSeamWeld::dot $u $u]]
    set term2 [::MeshSeamWeld::vscale \
        [::MeshSeamWeld::cross $normal $u] [::MeshSeamWeld::dot $v $v]]
    return [::MeshSeamWeld::vadd $first \
        [::MeshSeamWeld::vscale [::MeshSeamWeld::vadd $term1 $term2] \
            [expr {1.0 / (2.0 * $normal2)}]]]
}

proc ::MeshSeamWeld::dist2 {a b} {
    set d [::MeshSeamWeld::vsub $a $b]
    return [::MeshSeamWeld::dot $d $d]
}

proc ::MeshSeamWeld::distanceBetweenNodes {a b} {
    return [expr {sqrt([::MeshSeamWeld::dist2 \
        [::MeshSeamWeld::nodeXYZ $a] [::MeshSeamWeld::nodeXYZ $b]])}]
}

proc ::MeshSeamWeld::nodePathLength {nodeIds {closedLoop 0}} {
    set count [llength $nodeIds]
    if {$count < 2} {
        return 0.0
    }
    set length 0.0
    for {set i 1} {$i < $count} {incr i} {
        set length [expr {$length + [::MeshSeamWeld::distanceBetweenNodes \
            [lindex $nodeIds [expr {$i - 1}]] [lindex $nodeIds $i]]}]
    }
    if {$closedLoop} {
        set length [expr {$length + [::MeshSeamWeld::distanceBetweenNodes \
            [lindex $nodeIds end] [lindex $nodeIds 0]]}]
    }
    return $length
}

proc ::MeshSeamWeld::meshDensityForLength {length meshSize {minimum 1}} {
    if {![string is double -strict $meshSize] || $meshSize <= 0} {
        error "Mesh size must be a positive number."
    }
    if {$minimum < 1} {
        set minimum 1
    }
    set density [expr {int(ceil(double($length) / double($meshSize)))}]
    if {$density < $minimum} {
        set density $minimum
    }
    return $density
}

proc ::MeshSeamWeld::normalizedPathParameters {nodeIds {closedLoop 0}} {
    set count [llength $nodeIds]
    if {$count == 0} {
        return {}
    }
    if {$count == 1} {
        return {0.0}
    }

    set cumulative {0.0}
    set total 0.0
    for {set index 1} {$index < $count} {incr index} {
        set total [expr {$total + [::MeshSeamWeld::distanceBetweenNodes \
            [lindex $nodeIds [expr {$index - 1}]] [lindex $nodeIds $index]]}]
        lappend cumulative $total
    }
    if {$closedLoop} {
        set total [expr {$total + [::MeshSeamWeld::distanceBetweenNodes \
            [lindex $nodeIds end] [lindex $nodeIds 0]]}]
    }

    # Coincident or effectively zero-length paths have no usable geometric
    # parameter.  Fall back to the stable node order in that degenerate case.
    if {$total <= 1.0e-12} {
        set parameters {}
        set denominator [expr {$closedLoop ? $count : $count - 1}]
        for {set index 0} {$index < $count} {incr index} {
            lappend parameters [expr {double($index) / max(1, $denominator)}]
        }
        return $parameters
    }

    set parameters {}
    foreach value $cumulative {
        lappend parameters [expr {double($value) / $total}]
    }
    return $parameters
}

proc ::MeshSeamWeld::nearestPathIndexForParameter {parameters parameter} {
    set count [llength $parameters]
    if {$count == 0} {
        return -1
    }
    set bestIndex 0
    set bestDistance [expr {abs(double([lindex $parameters 0]) - double($parameter))}]
    for {set index 1} {$index < $count} {incr index} {
        set distance [expr {abs(double([lindex $parameters $index]) - double($parameter))}]
        if {$distance < $bestDistance} {
            set bestIndex $index
            set bestDistance $distance
        }
    }
    return $bestIndex
}

proc ::MeshSeamWeld::nearestPathIndicesForParameters {sourceParameters targetParameters} {
    set targetCount [llength $targetParameters]
    if {$targetCount == 0} {
        return {}
    }
    set targetIndex 0
    set indices {}
    foreach parameter $sourceParameters {
        while {$targetIndex + 1 < $targetCount &&
            abs(double([lindex $targetParameters [expr {$targetIndex + 1}]]) - double($parameter)) <
            abs(double([lindex $targetParameters $targetIndex]) - double($parameter))} {
            incr targetIndex
        }
        lappend indices $targetIndex
    }
    return $indices
}

proc ::MeshSeamWeld::shortestMeshBoundaryPath {elemIds startNode endNode} {
    # Build the free-boundary graph of only the newly created weld elements.
    # The short path between a source/target endpoint pair is the transverse
    # automesh edge, while the alternative travels around the other three
    # sides of the open strip.
    array set edgeCount {}
    array set edgeEnds {}
    foreach elemId $elemIds {
        set nodes [::MeshSeamWeld::elemNodes $elemId]
        set count [llength $nodes]
        if {$count < 3} {
            continue
        }
        for {set i 0} {$i < $count} {incr i} {
            set a [lindex $nodes $i]
            set b [lindex $nodes [expr {($i + 1) % $count}]]
            if {$a == $b} {
                continue
            }
            if {$a < $b} {
                set key "$a,$b"
            } else {
                set key "$b,$a"
            }
            if {![info exists edgeCount($key)]} {
                set edgeCount($key) 0
                set edgeEnds($key) [list $a $b]
            }
            incr edgeCount($key)
        }
    }

    array set neighbors {}
    foreach key [array names edgeCount] {
        if {$edgeCount($key) != 1} {
            continue
        }
        foreach {a b} $edgeEnds($key) break
        lappend neighbors($a) $b
        lappend neighbors($b) $a
    }
    if {![info exists neighbors($startNode)] || ![info exists neighbors($endNode)]} {
        error [::HWFlow::txt \
            "无法在焊缝网格边界上定位封口端点。" \
            "Could not locate closure endpoints on the weld mesh boundary."]
    }

    set queue [list $startNode]
    set head 0
    array set visited [list $startNode 1]
    array set parent {}
    while {$head < [llength $queue]} {
        set current [lindex $queue $head]
        incr head
        if {$current == $endNode} {
            break
        }
        foreach next $neighbors($current) {
            if {[info exists visited($next)]} {
                continue
            }
            set visited($next) 1
            set parent($next) $current
            lappend queue $next
        }
    }
    if {![info exists visited($endNode)]} {
        error [::HWFlow::txt \
            "焊缝横向边界不连续，无法创建闭环封口。" \
            "The transverse weld boundary is discontinuous; closure cannot be created."]
    }

    set path [list $endNode]
    set current $endNode
    while {$current != $startNode} {
        set current $parent($current)
        set path [linsert $path 0 $current]
    }
    return $path
}

proc ::MeshSeamWeld::createClosedStripElements {elemIds sourceNodes targetNodes expectedDensity} {
    set startCross [::MeshSeamWeld::shortestMeshBoundaryPath $elemIds \
        [lindex $sourceNodes 0] [lindex $targetNodes 0]]
    set endCross [::MeshSeamWeld::shortestMeshBoundaryPath $elemIds \
        [lindex $sourceNodes end] [lindex $targetNodes end]]
    set startDensity [expr {[llength $startCross] - 1}]
    set endDensity [expr {[llength $endCross] - 1}]
    if {$startDensity != $expectedDensity || $endDensity != $expectedDensity} {
        error [::HWFlow::txt \
            "闭环首尾横向网格层数异常（期望 $expectedDensity 层，首端 $startDensity 层，末端 $endDensity 层）。" \
            "Unexpected closure density (expected $expectedDensity, start $startDensity, end $endDensity)."]
    }

    for {set i 0} {$i < [llength $startCross] - 1} {incr i} {
        set quadNodes [list \
            [lindex $endCross $i] [lindex $startCross $i] \
            [lindex $startCross [expr {$i + 1}]] [lindex $endCross [expr {$i + 1}]]]
        if {[catch {
            eval *createlist nodes 1 $quadNodes
            *createelement 104 1 1 1
        } err]} {
            error [::HWFlow::txt \
                "创建闭环封口第 [expr {$i + 1}] 层单元失败：$err" \
                "Failed to create closure element layer [expr {$i + 1}]: $err"]
        }
    }
    return 1
}

proc ::MeshSeamWeld::safeLatestEntityId {entityType} {
    if {$entityType eq "nodes"} {
        variable lastKnownNodeId
        set cached $lastKnownNodeId
    } elseif {$entityType eq "elems"} {
        variable lastKnownElemId
        set cached $lastKnownElemId
    } else {
        error "Unsupported entity type for latest-ID tracking: $entityType"
    }

    set current ""
    catch {set current [hm_latestentityid $entityType]}
    if {[string is integer -strict $current] && $current > 0} {
        if {$entityType eq "nodes"} {
            set lastKnownNodeId $current
        } else {
            set lastKnownElemId $current
        }
        return $current
    }
    if {$cached > 0} {
        ::HybridCore::log WARN "hm_latestentityid returned '$current' for $entityType; using rollback-safe cached ID $cached"
        return $cached
    }
    error "Could not read a valid latest ID for $entityType."
}

proc ::MeshSeamWeld::restoreLatestEntityIds {nodeId elemId} {
    variable lastKnownNodeId
    variable lastKnownElemId
    if {[string is integer -strict $nodeId] && $nodeId > 0} {
        set lastKnownNodeId $nodeId
    }
    if {[string is integer -strict $elemId] && $elemId > 0} {
        set lastKnownElemId $elemId
    }
}

proc ::MeshSeamWeld::entityIdsCreatedAfter {entityType beforeId} {
    if {![string is integer -strict $beforeId] || $beforeId <= 0} {
        error [::HWFlow::txt \
            "无法读取操作前的实体 ID，不能可靠识别新建实体。" \
            "Could not read the pre-operation entity ID; new entities cannot be identified reliably."]
    }
    set afterId [::MeshSeamWeld::safeLatestEntityId $entityType]
    if {$afterId < $beforeId} {
        error "The post-operation $entityType ID $afterId is below the pre-operation ID $beforeId."
    }

    set out {}
    for {set id [expr {$beforeId + 1}]} {$id <= $afterId} {incr id} {
        if {$entityType eq "nodes"} {
            if {![catch {::MeshSeamWeld::nodeXYZ $id}]} {
                lappend out $id
            }
        } elseif {$entityType eq "elems"} {
            if {[llength [::MeshSeamWeld::elemNodes $id]] > 0} {
                lappend out $id
            }
        }
    }
    return $out
}

proc ::MeshSeamWeld::markComponents {compIds markId} {
    catch {*clearmark comps $markId}
    catch {*clearmark components $markId}
    if {[llength $compIds] == 0} {
        return 0
    }
    if {![catch {eval *createmark components $markId $compIds}]} {
        return 1
    }
    if {![catch {eval *createmark comps $markId $compIds}]} {
        return 1
    }
    return 0
}

proc ::MeshSeamWeld::markElements {elemIds markId} {
    foreach entityType {elements elems} {
        catch {*clearmark $entityType $markId}
        if {![catch {eval *createmark $entityType $markId $elemIds}]} {
            set marked {}
            catch {set marked [hm_getmark $entityType $markId]}
            if {[llength $marked] > 0} { return $marked }
        }
    }
    return {}
}

proc ::MeshSeamWeld::legacyComponentImprintNodeList {sourceNodes targetComps {closeNodeList 0} {targetElemIds {}}} {
    variable cfg
    variable lastImprintTargetMode
    variable lastImprintTargetElemCount

    set lastImprintTargetMode target_components
    set lastImprintTargetElemCount 0

    # list 2 is the fast path for receiving the imprinted target nodes.  Clear
    # it first so an unsupported runtime cannot accidentally reuse a prior run.
    catch {*clearlist nodes 2}
    if {![::MeshSeamWeld::markComponents $targetComps 2]} {
        error [::HWFlow::txt "无法标记目标组件。" "Could not mark target components."]
    }
    if {[catch {eval *createlist nodes 1 $sourceNodes} err]} {
        error [::HWFlow::txt "无法创建源节点列表：$err" "Could not create source node list: $err"]
    }

    set options [format "remain %s to_dest_component 0 remesh_layers %s remesh_mode %s angle %.6f create_joint_elems 0 close_node_list %d" \
        $cfg(imprint_remain) $cfg(patch_expand_layers) $cfg(imprint_remesh_mode) $cfg(imprint_angle) $closeNodeList]

    set lastErr ""
    if {[llength $targetElemIds] > 0} {
        set localElems [::MeshSeamWeld::markElements $targetElemIds 2]
        set refreshErr ""
        if {[llength $localElems] != [llength $targetElemIds]} {
            if {[catch {
                set localElems [::MeshSeamWeld::markRefreshedLocalTargetElements \
                    $targetElemIds $targetComps 2]
            } refreshErr]} {
                set localElems {}
            }
        }
        if {[llength $localElems] == 0} {
            error "The prepared local target elements are stale; the local index must be rebuilt. $refreshErr"
        }
        foreach entityType {elements elems} {
            if {![catch {*imprint_nodelist 1 $entityType 2 $options} err]} {
                set lastImprintTargetMode local_elements
                set lastImprintTargetElemCount [llength $localElems]
                ::MeshSeamWeld::tracePath "imprint target_mode=local_elements requested=[llength $targetElemIds] refreshed=[llength $localElems]"
                return 1
            }
            set lastErr $err
        }
        # Retired IDs trigger the isolated local-index rebuild above.  Keep the
        # component route only for HM builds that reject element-target imprint.
        ::HybridCore::log WARN "local element imprint command unavailable; falling back to target components requested=[llength $targetElemIds] refreshed=[llength $localElems] error=$lastErr"
        if {![::MeshSeamWeld::markComponents $targetComps 2]} {
            error [::HWFlow::txt "无法标记目标组件。" "Could not mark target components."]
        }
    }
    foreach entityType {components comps} {
        if {![catch {*imprint_nodelist 1 $entityType 2 $options} err]} {
            return 1
        }
        set lastErr $err
    }
    error [::HWFlow::txt "imprint_nodelist 执行失败：$lastErr" "imprint_nodelist failed: $lastErr"]
}

proc ::MeshSeamWeld::isLinearShellElement {elemId} {
    set config ""
    catch {set config [hm_getvalue elems id=$elemId dataname=config]}
    set normalized [string toupper [string trim $config]]
    if {$normalized ne ""} {
        if {$normalized in {103 104 TRIA3 CTRIA3 QUAD4 CQUAD4}} { return 1 }
        if {[regexp {(^|[^A-Z])(C?TRIA3|C?QUAD4)([^A-Z]|$)} $normalized]} { return 1 }
        # A valid non-shell configuration must not be accepted merely because
        # a tetrahedron also happens to have four nodes.
        return 0
    }
    set nodes [::MeshSeamWeld::elemNodes $elemId]
    return [expr {[llength $nodes] in {3 4}}]
}

proc ::MeshSeamWeld::localImprintSharedNeighborElements {coreElemIds} {
    set coreElemIds [lsort -integer -unique $coreElemIds]
    if {[llength $coreElemIds] == 0} {
        return {}
    }
    array set coreSet {}
    foreach elemId $coreElemIds { set coreSet($elemId) 1 }
    set coreNodes {}
    set coreConnectivity [::MeshSeamWeld::readShellElementConnectivityBulk \
        $coreElemIds 1]
    foreach elemId $coreElemIds {
        if {[dict exists $coreConnectivity $elemId]} {
            set coreNodes [concat $coreNodes [dict get $coreConnectivity $elemId]]
        }
    }
    set sharedNeighbors {}
    set adjacentIndex 0
    foreach elemId [::MeshSeamWeld::adjacentElementsForNodes \
        [lsort -integer -unique $coreNodes]] {
        incr adjacentIndex
        ::MeshSeamWeld::responsiveCheckpoint $adjacentIndex 128
        if {[info exists coreSet($elemId)] ||
            ![::MeshSeamWeld::isLinearShellElement $elemId]} {
            continue
        }
        lappend sharedNeighbors $elemId
    }
    return [lsort -integer -unique $sharedNeighbors]
}

proc ::MeshSeamWeld::clearLocalTopologyCaches {elemIds nodeIds} {
    variable elemNodesCache
    variable elemComponentCache
    variable nodeElemsCache
    variable nodeFreeEdgeNeighborsCache
    variable nodeXYZCache
    foreach elemId [::MeshSeamWeld::uniq $elemIds] {
        catch {unset elemNodesCache($elemId)}
        catch {unset elemComponentCache($elemId)}
    }
    foreach nodeId [::MeshSeamWeld::uniq $nodeIds] {
        catch {unset nodeElemsCache($nodeId)}
        catch {unset nodeFreeEdgeNeighborsCache($nodeId)}
        catch {unset nodeXYZCache($nodeId)}
    }
}

# Production imprint is local-only.  A missing/stale patch or an unsupported
# element-target command is a per-loop failure; it must never trigger a scan or
# imprint of all elements in the selected components.
proc ::MeshSeamWeld::runImprintNodeList {sourceNodes targetComps {closeNodeList 0} {targetElemIds {}}} {
    variable cfg
    variable lastImprintTargetMode
    variable lastImprintTargetElemCount
    variable lastImprintCoreElemCount
    variable lastImprintSupportElemCount
    variable lastImprintSharedNeighborElemCount
    variable lastImprintAffectedElemIds

    set lastImprintTargetMode local_elements
    set lastImprintTargetElemCount 0
    set lastImprintCoreElemCount 0
    set lastImprintSupportElemCount 0
    set lastImprintSharedNeighborElemCount 0
    set lastImprintAffectedElemIds {}
    catch {*clearlist nodes 2}
    if {[catch {eval *createlist nodes 1 $sourceNodes} err]} {
        error "Could not create the source node list: $err"
    }
    if {[llength $targetElemIds] == 0} {
        error "No local target elements were prepared; skipped instead of imprinting an entire component."
    }

    set localElems [::MeshSeamWeld::markElements $targetElemIds 2]
    set refreshErr ""
    if {[llength $localElems] != [llength $targetElemIds]} {
        if {[catch {
            set localElems [::MeshSeamWeld::markRefreshedLocalTargetElements \
                $targetElemIds $targetComps 2]
        } refreshErr]} {
            set localElems {}
        }
    }
    if {[llength $localElems] == 0} {
        error "The prepared local target elements are stale or unavailable; this loop was skipped. $refreshErr"
    }

    # Mesh Edit receives exactly the two inputs prepared by this workflow:
    # sourceNodes in node list 1, and the projected local layers from the
    # selected target components in element mark 2.  Shells outside that
    # target patch may share nodes with it, but must not be silently added to
    # the Elements input.  Count them only to correlate shared-node topology
    # with any native imprint failure reported by HyperMesh.
    set coreElems $localElems
    set imprintElems $coreElems
    set sharedNeighborElems [::MeshSeamWeld::localImprintSharedNeighborElements \
        $coreElems]
    set affectedNodesBefore {}
    set affectedConnectivity [::MeshSeamWeld::readShellElementConnectivityBulk \
        $imprintElems 1]
    foreach elemId $imprintElems {
        if {[dict exists $affectedConnectivity $elemId]} {
            set affectedNodesBefore [concat $affectedNodesBefore \
                [dict get $affectedConnectivity $elemId]]
        }
    }
    set affectedNodesBefore [::MeshSeamWeld::uniq $affectedNodesBefore]
    set markedImprintElems [::MeshSeamWeld::markElements $imprintElems 2]
    array set markedImprintSet {}
    foreach elemId $markedImprintElems { set markedImprintSet($elemId) 1 }
    set missingCoreElems {}
    foreach elemId $coreElems {
        if {![info exists markedImprintSet($elemId)]} { lappend missingCoreElems $elemId }
    }
    if {[llength $missingCoreElems] > 0} {
        error "The prepared local target Elements input became stale before Mesh Edit; this loop was skipped."
    }
    set lastImprintCoreElemCount [llength $coreElems]
    set lastImprintSupportElemCount 0
    set lastImprintSharedNeighborElemCount [llength $sharedNeighborElems]
    set lastImprintTargetElemCount [llength $markedImprintElems]
    set lastImprintAffectedElemIds $markedImprintElems

    set options [format "remain %s to_dest_component 0 remesh_layers %s remesh_mode %s angle %.6f create_joint_elems 0 close_node_list %d" \
        $cfg(imprint_remain) $cfg(patch_expand_layers) $cfg(imprint_remesh_mode) \
        $cfg(imprint_angle) $closeNodeList]
    set lastErr ""
    foreach entityType {elements elems} {
        if {![catch {*imprint_nodelist 1 $entityType 2 $options} err]} {
            # Only the local target Elements input is expected to change.
            ::MeshSeamWeld::clearLocalTopologyCaches \
                $markedImprintElems $affectedNodesBefore
            ::HybridCore::log INFO \
                "imprint target_mode=$lastImprintTargetMode requested=[llength $targetElemIds] core=$lastImprintCoreElemCount shared_external=$lastImprintSharedNeighborElemCount total=$lastImprintTargetElemCount"
            return 1
        }
        set lastErr $err
    }
    error "Local-element imprint_nodelist failed; shared external shell elements=$lastImprintSharedNeighborElemCount; this loop was skipped: $lastErr"
}

proc ::MeshSeamWeld::targetNodesFromImprintList {sourceNodes beforeNode {requireEqualCount 1}} {
    variable nodeXYZCache
    set list2 {}
    catch {set list2 [hm_getlist nodes 2]}
    ::MeshSeamWeld::tracePath "imprint list2 raw_count=[llength $list2] source_count=[llength $sourceNodes] before_node=$beforeNode"
    if {$requireEqualCount && [llength $list2] != [llength $sourceNodes]} {
        return {}
    }
    set list2 [::MeshSeamWeld::uniq $list2]
    # Closed-loop callers apply their three-node minimum through the topology
    # continuity check.  An open ruled side is valid with two end nodes even
    # when the imprinted source side contains many intermediate nodes.
    set minimumCount 2
    if {[llength $list2] < $minimumCount ||
        ($requireEqualCount && [llength $list2] != [llength $sourceNodes])} {
        return {}
    }
    # HyperMesh 2019 may remesh the target with new nodes, but it may also
    # reuse target nodes that already existed before the imprint.  List 2 is
    # cleared immediately before *imprint_nodelist, so an ID does not need to
    # be greater than beforeNode to belong to this operation.
    array set sourceSet {}
    foreach nodeId $sourceNodes { set sourceSet($nodeId) 1 }
    set reusedCount 0
    foreach nodeId $list2 {
        if {![string is integer -strict $nodeId] || [info exists sourceSet($nodeId)]} {
            return {}
        }
        catch {unset nodeXYZCache($nodeId)}
        if {$beforeNode ne "" && $nodeId <= $beforeNode} { incr reusedCount }
    }
    # Validate and cache the complete native result in one coordinate read.
    # Per-node hm_getvalue calls are particularly expensive after remeshing a
    # long closed boundary.
    if {[catch {
        set coordinates [::HybridCore::readNodeCoordinatesBulk $list2 \
            [list ::MeshSeamWeld::nodeXYZ]]
        foreach nodeId $list2 {
            if {![dict exists $coordinates $nodeId]} {
                error "Missing coordinates for imprinted node $nodeId."
            }
            set nodeXYZCache($nodeId) [dict get $coordinates $nodeId]
        }
    }]} {
        return {}
    }
    ::MeshSeamWeld::tracePath "imprint list2 accepted count=[llength $list2] reused_count=$reusedCount"
    return $list2
}

proc ::MeshSeamWeld::componentNodeIds {compIds} {
    variable elemNodesCache
    set elemIds {}
    foreach compId [::MeshSeamWeld::uniq $compIds] {
        set elems {}
        if {[llength [info commands ::HWFlow::getCompEntityIds]] > 0} {
            catch {set elems [::HWFlow::getCompEntityIds $compId elems elems]}
        }
        if {[llength $elems] == 0} {
            catch {*clearmark elems 2}
            if {![catch {*createmark elems 2 "by comp id" $compId}]} {
                catch {set elems [hm_getmark elems 2]}
            }
            catch {*clearmark elems 2}
        }
        set elemIds [concat $elemIds $elems]
    }
    set nodeIds {}
    foreach elemId [::MeshSeamWeld::uniq $elemIds] {
        # This function is only a fallback after imprint.  Force a current
        # connectivity read because the target component may just have been
        # remeshed and an older path may have cached this element.
        catch {unset elemNodesCache($elemId)}
        set nodeIds [concat $nodeIds [::MeshSeamWeld::elemNodes $elemId]]
    }
    return [::MeshSeamWeld::uniq $nodeIds]
}

proc ::MeshSeamWeld::markElementsByComponents {compIds markId} {
    set compIds [::MeshSeamWeld::uniq $compIds]
    if {[llength $compIds] == 0} { return {} }
    foreach entityType {elems elements} {
        catch {*clearmark $entityType $markId}
        if {![catch {eval *createmark $entityType $markId [list "by comp id"] $compIds}]} {
            set marked {}
            catch {set marked [hm_getmark $entityType $markId]}
            if {[llength $marked] > 0} { return $marked }
        }
    }

    set elemIds {}
    foreach compId $compIds {
        set elemIds [concat $elemIds [::MeshSeamWeld::componentElementIds $compId]]
    }
    return [::MeshSeamWeld::markElements [::MeshSeamWeld::uniq $elemIds] $markId]
}

proc ::MeshSeamWeld::markedElementIds {markId} {
    set marked {}
    foreach entityType {elems elements} {
        set current {}
        catch {set current [hm_getmark $entityType $markId]}
        set marked [concat $marked $current]
    }
    return [::MeshSeamWeld::uniq $marked]
}

proc ::MeshSeamWeld::markRefreshedLocalTargetElements {targetElemIds targetComps markId {extraLayers 0}} {
    variable cfg
    variable elemComponentCache

    set marked [::MeshSeamWeld::markElements $targetElemIds $markId]
    if {[llength $marked] == 0} { return {} }

    # Imprint can replace the center of the original patch.  Expand from the
    # surviving perimeter after the operation so the new remeshed elements are
    # included without enumerating every element in the target components.
    set expandLayers [expr {$cfg(patch_expand_layers) + 2 + max(0, int($extraLayers))}]
    for {set layer 0} {$layer < $expandLayers} {incr layer} {
        set expanded 0
        foreach entityType {elements elems} {
            foreach option {{by adjacent} adjacent} {
                if {![catch {*appendmark $entityType $markId $option}]} {
                    set expanded 1
                    break
                }
            }
            if {$expanded} { break }
        }
        if {!$expanded} { break }
    }

    array set allowedComp {}
    foreach compId $targetComps { set allowedComp($compId) 1 }
    set filtered {}
    foreach elemId [::MeshSeamWeld::markedElementIds $markId] {
        # Remesh may reuse an entity ID.  Force a current ownership query for
        # the small refreshed patch before filtering it to the selected target.
        catch {unset elemComponentCache($elemId)}
        set compId [::MeshSeamWeld::elemComponentId $elemId]
        if {[info exists allowedComp($compId)]} { lappend filtered $elemId }
    }
    if {[llength $filtered] == 0} {
        catch {*clearmark elems $markId}
        catch {*clearmark elements $markId}
        return {}
    }
    return [::MeshSeamWeld::markElements $filtered $markId]
}

proc ::MeshSeamWeld::targetNodesFromClosestQuery {sourceNodes targetComps {targetElemIds {}}} {
    variable nodeXYZCache
    if {[llength [info commands hm_getclosestnode]] == 0} {
        error "hm_getclosestnode is unavailable."
    }
    if {[llength $targetElemIds] == 0} {
        error "Local target elements are required for closest-node matching."
    }
    set markedElems [::MeshSeamWeld::markRefreshedLocalTargetElements \
        $targetElemIds $targetComps 1]
    set matchScope local_elements
    if {[llength $markedElems] == 0} {
        error "Could not mark $matchScope for closest-node matching."
    }

    catch {*clearmark nodes 1}
    if {[catch {eval *createmark nodes 1 $sourceNodes} markErr]} {
        catch {*clearmark elems 1}
        catch {*clearmark elements 1}
        error "Could not mark source nodes for closest-node exclusion: $markErr"
    }

    set targetNodes {}
    array set used {}
    array set sourceSet {}
    foreach sourceNode $sourceNodes { set sourceSet($sourceNode) 1 }
    set matchedCount 0
    set queryCode [catch {
        foreach sourceNode $sourceNodes {
            foreach {x y z} [::MeshSeamWeld::nodeXYZ $sourceNode] break
            set targetNode [hm_getclosestnode $x $y $z 1 1]
            if {![string is integer -strict $targetNode] || $targetNode <= 0 ||
                [info exists sourceSet($targetNode)]} {
                error "No valid target node was found for source node $sourceNode."
            }
            if {[info exists used($targetNode)]} {
                error "Target node $targetNode was matched to more than one source node."
            }
            set used($targetNode) 1
            catch {unset nodeXYZCache($targetNode)}
            lappend targetNodes $targetNode
            incr matchedCount
            ::MeshSeamWeld::responsiveCheckpoint $matchedCount 64
        }
        set targetCoordinates [::HybridCore::readNodeCoordinatesBulk $targetNodes \
            [list ::MeshSeamWeld::nodeXYZ]]
        foreach targetNode $targetNodes {
            if {![dict exists $targetCoordinates $targetNode]} {
                error "No coordinates were returned for target node $targetNode."
            }
            set nodeXYZCache($targetNode) [dict get $targetCoordinates $targetNode]
        }
    } queryErr]
    catch {*clearmark nodes 1}
    catch {*clearmark elems 1}
    catch {*clearmark elements 1}
    if {$queryCode} { error $queryErr }
    ::MeshSeamWeld::tracePath "imprint target_nodes=closest_query scope=$matchScope count=[llength $targetNodes] target_elements=[llength $markedElems]"
    return $targetNodes
}

proc ::MeshSeamWeld::closestTargetAnchors {sourceNodes targetComps targetElemIds} {
    variable nodeXYZCache
    if {[llength [info commands hm_getclosestnode]] == 0} {
        error "hm_getclosestnode is unavailable."
    }
    set markedElems [::MeshSeamWeld::markRefreshedLocalTargetElements \
        $targetElemIds $targetComps 1]
    if {[llength $markedElems] == 0} {
        error "Could not mark the current local target elements for anchor matching."
    }
    catch {*clearmark nodes 2}
    if {[catch {eval *createmark nodes 2 $sourceNodes} markErr]} {
        catch {*clearmark elems 1}
        catch {*clearmark elements 1}
        error "Could not mark source nodes for target-anchor exclusion: $markErr"
    }

    set anchors {}
    set matchedCount 0
    set queryCode [catch {
        foreach sourceNode $sourceNodes {
            foreach {x y z} [::MeshSeamWeld::nodeXYZ $sourceNode] break
            set targetNode [hm_getclosestnode $x $y $z 1 2]
            if {![string is integer -strict $targetNode] || $targetNode <= 0} {
                error "No target anchor was found for source node $sourceNode."
            }
            lappend anchors $targetNode
            catch {unset nodeXYZCache($targetNode)}
            incr matchedCount
            ::MeshSeamWeld::responsiveCheckpoint $matchedCount 64
        }
    } queryErr]
    catch {*clearmark nodes 2}
    catch {*clearmark elems 1}
    catch {*clearmark elements 1}
    if {$queryCode} { error $queryErr }

    set duplicateCount [expr {
        [llength $anchors] - [llength [lsort -integer -unique $anchors]]}]
    ::HybridCore::log INFO \
        "imprint target_anchor_count=[llength $anchors] duplicate_anchors=$duplicateCount target_elements=[llength $markedElems]"
    return $anchors
}

proc ::MeshSeamWeld::targetNodesFromLocalTopology {sourceNodes targetComps targetElemIds {closedLoop 0}} {
    set candidateNodes [::MeshSeamWeld::localTargetNodesFromElements \
        $targetElemIds $targetComps]
    set anchorNodes [::MeshSeamWeld::closestTargetAnchors \
        $sourceNodes $targetComps $targetElemIds]
    if {[catch {
        set targetNodes [::MeshSeamWeld::matchContinuousTargetPathNodes \
            $sourceNodes $candidateNodes $closedLoop $anchorNodes]
    } equalCountErr]} {
        if {[catch {
            set targetNodes [::MeshSeamWeld::matchVariableTargetPathNodes \
                $sourceNodes $candidateNodes $closedLoop $anchorNodes]
        } variableCountErr]} {
            set endpointErr "not attempted for a closed loop"
            if {!$closedLoop && ![catch {
                set targetNodes [::MeshSeamWeld::matchOpenTargetPathFromEndpoints \
                    $sourceNodes $candidateNodes $anchorNodes]
            } endpointErr]} {
                ::HybridCore::log WARN \
                    "imprint target_path=open_endpoint_fallback equal_error=$equalCountErr variable_error=$variableCountErr"
            } else {
                error "Post-imprint topology recovery failed. equal-count: $equalCountErr; variable-count: $variableCountErr; endpoint fallback: $endpointErr"
            }
        }
    }
    if {[llength $targetNodes] < [expr {$closedLoop ? 3 : 2}] ||
        [llength [lsort -integer -unique $targetNodes]] !=
            [llength $targetNodes]} {
        error "Post-imprint topology matching did not return a usable unique target path."
    }
    return $targetNodes
}

proc ::MeshSeamWeld::targetNodesFromPostImprintTopology {sourceNodes targetComps targetElemIds {closedLoop 0}} {
    if {![catch {
        set targetNodes [::MeshSeamWeld::targetNodesFromLocalTopology \
            $sourceNodes $targetComps $targetElemIds $closedLoop]
    } firstErr]} {
        return $targetNodes
    }

    # The native remesher may keep just enough old element IDs for a mark to
    # succeed while replacing the actual path corridor.  Re-project the source
    # path onto the current target mesh before declaring the visible mesh
    # unusable.  This remains local and does not enumerate or imprint a whole
    # component.
    if {[catch {
        set refreshed [::MeshSeamWeld::prepareCurrentTargetPatch \
            $sourceNodes $targetComps $closedLoop]
        set refreshedElems [dict get $refreshed target_elements]
        set targetNodes [::MeshSeamWeld::targetNodesFromLocalTopology \
            $sourceNodes $targetComps $refreshedElems $closedLoop]
    } refreshErr]} {
        error "Post-imprint local topology recovery failed. initial scope: $firstErr; reprojected scope: $refreshErr"
    }
    ::HybridCore::log WARN \
        "imprint target_path=reprojected_local_topology old_elements=[llength $targetElemIds] refreshed_elements=[llength $refreshedElems] target_nodes=[llength $targetNodes]"
    return $targetNodes
}

proc ::MeshSeamWeld::targetElementsAfterImprint {targetComps fallbackElemIds {sourceNodes {}} {closedLoop 0}} {
    array set allowed {}
    foreach componentId $targetComps { set allowed($componentId) 1 }
    set imprintNodes {}
    catch {set imprintNodes [hm_getlist nodes 2]}
    set seedElements {}
    set nativeSeeds 0
    if {[llength $imprintNodes] > 0} {
        set seedIndex 0
        foreach elemId [::MeshSeamWeld::adjacentElementsForNodes \
            [::MeshSeamWeld::uniq $imprintNodes]] {
            incr seedIndex
            ::MeshSeamWeld::responsiveCheckpoint $seedIndex 128
            set componentId [::MeshSeamWeld::elemComponentId $elemId]
            if {![info exists allowed($componentId)]} { continue }
            if {![::MeshSeamWeld::isLinearShellElement $elemId]} { continue }
            lappend seedElements $elemId
        }
        if {[llength $seedElements] > 0} { set nativeSeeds 1 }
    }
    set survivingFallback [::MeshSeamWeld::markElements $fallbackElemIds 2]
    if {[llength $survivingFallback] > 0} {
        set seedElements [concat $seedElements $survivingFallback]
    }
    if {[llength $seedElements] == 0} {
        set seedElements $fallbackElemIds
    }
    if {$nativeSeeds} {
        set currentElements [::MeshSeamWeld::expandTargetElementPatch \
            [lsort -integer -unique $seedElements] $targetComps 1 2]
    } else {
        set currentElements [::MeshSeamWeld::markRefreshedLocalTargetElements \
            [lsort -integer -unique $seedElements] $targetComps 1 1]
    }
    set reprojectErr "not attempted because the source path was unavailable"
    if {[llength $currentElements] == 0 && [llength $sourceNodes] >= 2} {
        set reprojectErr ""
        if {![catch {
            set refreshed [::MeshSeamWeld::prepareCurrentTargetPatch \
                $sourceNodes $targetComps $closedLoop]
            set currentElements [dict get $refreshed target_elements]
        } reprojectErr] && [llength $currentElements] > 0} {
            ::HybridCore::log WARN \
                "imprint target_scope=reprojected source_nodes=[llength $sourceNodes] old_elements=[llength $fallbackElemIds] refreshed_elements=[llength $currentElements]"
        }
    }
    if {[llength $currentElements] == 0} {
        error "Could not rebuild the current target patch after imprint; source-path reprojection also failed: $reprojectErr"
    }
    return $currentElements
}

proc ::MeshSeamWeld::legacyComponentTargetCandidatesAfterImprint {sourceNodes targetComps beforeNode {targetElemIds {}}} {
    set listNodes [::MeshSeamWeld::targetNodesFromImprintList $sourceNodes $beforeNode]
    if {[llength $listNodes] > 0} {
        return $listNodes
    }

    # A non-empty but incomplete result list is direct evidence that only part
    # of the source path reached the target.  Do not disguise that condition by
    # nearest-matching arbitrary nodes from the target component.
    set rawList {}
    catch {set rawList [hm_getlist nodes 2]}
    if {[llength $rawList] > 0} {
        error [::HWFlow::txt \
            "当前边界/路径只投影成功 [llength $rawList]/[llength $sourceNodes] 个节点，已取消该任务。" \
            "Only [llength $rawList]/[llength $sourceNodes] nodes of this boundary/path were projected; the task was cancelled."]
    }

    set localErr ""
    if {[llength $targetElemIds] > 0 && ![catch {
        set closestNodes [::MeshSeamWeld::targetNodesFromClosestQuery \
            $sourceNodes $targetComps $targetElemIds]
    } localErr]} {
        return $closestNodes
    }
    if {$localErr ne ""} {
        ::HybridCore::log WARN "local closest-node scope unavailable; retrying target-component scope error=$localErr"
    }

    set closestErr ""
    if {![catch {
        set closestNodes [::MeshSeamWeld::targetNodesFromClosestQuery $sourceNodes $targetComps]
    } closestErr]} {
        return $closestNodes
    }
    # Never recover by enumerating every node in the target components.  That
    # Tcl-side scan becomes progressively slower as imprint grows the target
    # mesh.  Let the isolated path transaction roll back so the caller can
    # retry the same local patch with close_node_list=1.
    ::HybridCore::log WARN "closest-node target matching failed; cancelling local attempt without component-wide fallback error=$closestErr"
    error [::HWFlow::txt \
        "局部 imprint 后无法唯一匹配目标节点：$closestErr" \
        "Could not uniquely match target nodes after the local imprint: $closestErr"]
}

proc ::MeshSeamWeld::localTargetNodesFromElements {targetElemIds targetComps} {
    variable elemNodesCache
    variable nodeXYZCache
    variable lastLocalTargetNodeIds
    variable lastLocalTargetEdges

    if {[llength $targetElemIds] == 0} {
        error "Local target elements are required to collect target-node candidates."
    }
    set localElems [::MeshSeamWeld::markElements $targetElemIds 1]
    if {[llength $localElems] != [llength $targetElemIds]} {
        set localElems [::MeshSeamWeld::markRefreshedLocalTargetElements \
            $targetElemIds $targetComps 1]
    }
    if {[llength $localElems] == 0} {
        error "No current local target elements remain for target-node matching."
    }
    foreach elemId $localElems { catch {unset elemNodesCache($elemId)} }
    set connectivity [::MeshSeamWeld::readShellElementConnectivityBulk $localElems 1]
    set targetNodes {}
    set targetEdges [dict create]
    foreach elemId $localElems {
        if {[dict exists $connectivity $elemId]} {
            set elementNodes [dict get $connectivity $elemId]
            set targetNodes [concat $targetNodes $elementNodes]
            set nodeCount [llength $elementNodes]
            for {set index 0} {$index < $nodeCount} {incr index} {
                set first [lindex $elementNodes $index]
                set second [lindex $elementNodes [expr {($index + 1) % $nodeCount}]]
                dict set targetEdges [::MeshSeamWeld::canonicalEdgeKey $first $second] 1
            }
        }
    }
    set targetNodes [lsort -integer -unique $targetNodes]
    if {[llength $targetNodes] == 0} {
        error "The current local target patch contains no shell nodes."
    }
    set coordinates [::HybridCore::readNodeCoordinatesBulk $targetNodes \
        [list ::MeshSeamWeld::nodeXYZ]]
    foreach nodeId $targetNodes {
        if {[dict exists $coordinates $nodeId]} {
            set nodeXYZCache($nodeId) [dict get $coordinates $nodeId]
        }
    }
    set lastLocalTargetNodeIds $targetNodes
    set lastLocalTargetEdges $targetEdges
    return $targetNodes
}

proc ::MeshSeamWeld::targetCandidatesAfterImprint {sourceNodes targetComps beforeNode {targetElemIds {}} {beforeTargetNodes {}}} {
    set listNodes [::MeshSeamWeld::targetNodesFromImprintList $sourceNodes $beforeNode]
    if {[llength $listNodes] > 0} { return $listNodes }

    set rawList {}
    catch {set rawList [hm_getlist nodes 2]}
    if {[llength $rawList] > 0} {
        ::HybridCore::log WARN \
            "imprint list2 incomplete count=[llength $rawList]/[llength $sourceNodes]; reconstructing path from local mesh topology"
    }
    if {[llength $targetElemIds] == 0} {
        error "Local target elements are required for post-imprint matching; this loop was skipped."
    }

    if {[catch {
        set currentTargetNodes [::MeshSeamWeld::localTargetNodesFromElements \
            $targetElemIds $targetComps]
    } localErr]} {
        error "Could not collect target nodes from the refreshed local patch; this loop was skipped: $localErr"
    }
    set addedTargetNodes [::MeshSeamWeld::idsAddedToCollection \
        $beforeTargetNodes $currentTargetNodes]
    if {[llength $addedTargetNodes] >= [llength $sourceNodes]} {
        ::HybridCore::log INFO \
            "imprint target_nodes=local_added candidates=[llength $addedTargetNodes] local_nodes=[llength $currentTargetNodes]"
        return $addedTargetNodes
    }
    if {[llength $currentTargetNodes] >= [llength $sourceNodes]} {
        ::HybridCore::log INFO \
            "imprint target_nodes=local_patch candidates=[llength $currentTargetNodes] added=[llength $addedTargetNodes]"
        return $currentTargetNodes
    }
    error "The refreshed local patch has only [llength $currentTargetNodes] target nodes for [llength $sourceNodes] source nodes; this loop was skipped."
}

proc ::MeshSeamWeld::matchTargetPathNodes {sourceNodes candidateNodes} {
    set candidateNodes [::MeshSeamWeld::uniq $candidateNodes]
    if {[llength $candidateNodes] < [llength $sourceNodes]} {
        error [::HWFlow::txt \
            "imprint 后新增节点数量不足，无法形成目标 node path。" \
            "Not enough nodes were created by imprint to form the target node path."]
    }

    set targetNodes {}
    array set used {}
    foreach sourceNode $sourceNodes {
        set sourcePoint [::MeshSeamWeld::nodeXYZ $sourceNode]
        set bestNode ""
        set bestD2 ""
        foreach candidate $candidateNodes {
            if {[info exists used($candidate)]} {
                continue
            }
            set d2 [::MeshSeamWeld::dist2 $sourcePoint [::MeshSeamWeld::nodeXYZ $candidate]]
            if {$bestNode eq "" || $d2 < $bestD2} {
                set bestNode $candidate
                set bestD2 $d2
            }
        }
        if {$bestNode eq ""} {
            error [::HWFlow::txt "无法匹配目标 node path。" "Could not match the target node path."]
        }
        set used($bestNode) 1
        lappend targetNodes $bestNode
    }
    return $targetNodes
}

proc ::MeshSeamWeld::targetNeighborGraphFromEdges {targetEdges} {
    set graph [dict create]
    foreach edgeKey [dict keys $targetEdges] {
        lassign [split $edgeKey ,] first second
        if {$first eq "" || $second eq "" || $first == $second} { continue }
        dict lappend graph $first $second
        dict lappend graph $second $first
    }
    foreach nodeId [dict keys $graph] {
        dict set graph $nodeId [lsort -integer -unique [dict get $graph $nodeId]]
    }
    return $graph
}

proc ::MeshSeamWeld::nearestCandidateAnchorsFromCoordinates {sourceNodes candidateNodes} {
    set anchors {}
    set sourceIndex 0
    foreach sourceNode $sourceNodes {
        set sourcePoint [::MeshSeamWeld::nodeXYZ $sourceNode]
        set bestNode ""
        set bestDistance ""
        foreach candidateNode $candidateNodes {
            set distance [::MeshSeamWeld::dist2 $sourcePoint \
                [::MeshSeamWeld::nodeXYZ $candidateNode]]
            if {$bestNode eq "" || $distance < $bestDistance} {
                set bestNode $candidateNode
                set bestDistance $distance
            }
        }
        if {$bestNode eq ""} {
            error "No target anchor was found for source node $sourceNode."
        }
        lappend anchors $bestNode
        incr sourceIndex
        ::MeshSeamWeld::responsiveCheckpoint $sourceIndex 64
    }
    return $anchors
}

proc ::MeshSeamWeld::boundedTargetCandidates {anchorNode neighborGraph sourcePoint radius limit} {
    if {![dict exists $neighborGraph $anchorNode]} {
        return [list $anchorNode]
    }
    set queue [list [list $anchorNode 0]]
    set queueIndex 0
    set visited [dict create]
    set scored {}
    while {$queueIndex < [llength $queue]} {
        lassign [lindex $queue $queueIndex] nodeId depth
        incr queueIndex
        if {[dict exists $visited $nodeId]} { continue }
        dict set visited $nodeId 1
        lappend scored [list \
            [::MeshSeamWeld::dist2 $sourcePoint \
                [::MeshSeamWeld::nodeXYZ $nodeId]] $nodeId]
        if {$depth >= $radius} { continue }
        foreach neighbor [dict get $neighborGraph $nodeId] {
            if {![dict exists $visited $neighbor]} {
                lappend queue [list $neighbor [expr {$depth + 1}]]
            }
        }
    }
    set result {}
    foreach row [lrange [lsort -real -index 0 $scored] 0 [expr {$limit - 1}]] {
        lappend result [lindex $row 1]
    }
    return $result
}

proc ::MeshSeamWeld::limitTargetTrackingStates {states limit} {
    if {[dict size $states] <= $limit} {
        return $states
    }
    set ranked {}
    dict for {stateKey stateCost} $states {
        lappend ranked [list $stateCost $stateKey]
    }
    set limited [dict create]
    foreach row [lrange [lsort -real -index 0 $ranked] 0 \
        [expr {$limit - 1}]] {
        dict set limited [lindex $row 1] [lindex $row 0]
    }
    return $limited
}

proc ::MeshSeamWeld::shortestTargetGraphPath {neighborGraph candidateAllowed startNode endNode} {
    if {$startNode == $endNode} { return [list $startNode] }
    if {![dict exists $candidateAllowed $startNode] ||
        ![dict exists $candidateAllowed $endNode] ||
        ![dict exists $neighborGraph $startNode]} {
        return {}
    }
    set queue [list $startNode]
    set queueIndex 0
    set parents [dict create $startNode ""]
    while {$queueIndex < [llength $queue]} {
        set current [lindex $queue $queueIndex]
        incr queueIndex
        foreach neighbor [dict get $neighborGraph $current] {
            if {![dict exists $candidateAllowed $neighbor] ||
                [dict exists $parents $neighbor]} {
                continue
            }
            dict set parents $neighbor $current
            if {$neighbor == $endNode} {
                set path [list $endNode]
                set cursor $endNode
                while {[dict get $parents $cursor] ne ""} {
                    set cursor [dict get $parents $cursor]
                    set path [linsert $path 0 $cursor]
                }
                return $path
            }
            lappend queue $neighbor
        }
        ::MeshSeamWeld::responsiveCheckpoint $queueIndex 256
    }
    return {}
}

# Closest-node queries on a regular target grid can alternate between two
# equally near rows.  The resulting landmark walk is still useful, but its
# small backtracks used to make an otherwise valid open node path look
# self-intersecting.  Erasing completed loops preserves a continuous walk and
# its end-to-end direction while removing only those local reversals.
proc ::MeshSeamWeld::loopEraseNodeWalk {nodeWalk} {
    set result {}
    set positions [dict create]
    foreach nodeId $nodeWalk {
        if {[dict exists $positions $nodeId]} {
            set keepIndex [dict get $positions $nodeId]
            foreach removed [lrange $result [expr {$keepIndex + 1}] end] {
                dict unset positions $removed
            }
            set result [lrange $result 0 $keepIndex]
            continue
        }
        dict set positions $nodeId [llength $result]
        lappend result $nodeId
    }
    return $result
}

proc ::MeshSeamWeld::matchOpenTargetPathFromEndpoints {sourceNodes candidateNodes anchorNodes} {
    variable lastLocalTargetEdges

    if {[llength $sourceNodes] < 2 || [llength $anchorNodes] != [llength $sourceNodes]} {
        error "Open endpoint recovery requires one target anchor per source node."
    }
    set landmarks [::MeshSeamWeld::loopEraseNodeWalk $anchorNodes]
    if {[llength $landmarks] < 2} {
        error "The open source path collapsed onto fewer than two distinct target anchors."
    }
    set neighborGraph [::MeshSeamWeld::targetNeighborGraphFromEdges \
        $lastLocalTargetEdges]
    set candidateAllowed [dict create]
    foreach nodeId [lsort -integer -unique $candidateNodes] {
        dict set candidateAllowed $nodeId 1
    }
    set targetPath [::MeshSeamWeld::shortestTargetGraphPath \
        $neighborGraph $candidateAllowed [lindex $landmarks 0] \
        [lindex $landmarks end]]
    if {[llength $targetPath] < 2} {
        error "No target-mesh path connects the two open-path endpoint anchors."
    }
    ::HybridCore::log INFO \
        "imprint target_path=open_endpoint_graph source_nodes=[llength $sourceNodes] landmarks=[llength $landmarks] target_nodes=[llength $targetPath]"
    return $targetPath
}

proc ::MeshSeamWeld::matchVariableTargetPathNodes {sourceNodes candidateNodes {closedLoop 0} {anchorNodes {}}} {
    variable lastLocalTargetEdges

    set candidateNodes [lsort -integer -unique $candidateNodes]
    if {[llength $anchorNodes] == 0} {
        set anchorNodes [::MeshSeamWeld::nearestCandidateAnchorsFromCoordinates \
            $sourceNodes $candidateNodes]
    }
    if {[llength $anchorNodes] != [llength $sourceNodes]} {
        error "The post-imprint anchor count does not match the source path."
    }

    # Consecutive duplicate anchors are expected when the source boundary is
    # finer than a surrounding cylindrical target.  Keep the ordered angular
    # landmarks, then recover every intervening target-mesh edge rather than
    # requiring exactly one target edge per source node.
    set landmarks {}
    foreach anchor $anchorNodes {
        if {[llength $landmarks] == 0 || [lindex $landmarks end] != $anchor} {
            lappend landmarks $anchor
        }
    }
    if {$closedLoop && [llength $landmarks] > 1 &&
        [lindex $landmarks 0] == [lindex $landmarks end]} {
        set landmarks [lrange $landmarks 0 end-1]
    } elseif {!$closedLoop} {
        set landmarks [::MeshSeamWeld::loopEraseNodeWalk $landmarks]
    }
    set minimum [expr {$closedLoop ? 3 : 2}]
    if {[llength [lsort -integer -unique $landmarks]] < $minimum} {
        error "Too few distinct target landmarks were found for a continuous target path."
    }

    set neighborGraph [::MeshSeamWeld::targetNeighborGraphFromEdges \
        $lastLocalTargetEdges]
    set candidateAllowed [dict create]
    foreach nodeId $candidateNodes { dict set candidateAllowed $nodeId 1 }
    set segmentCount [expr {$closedLoop ? [llength $landmarks] : [llength $landmarks] - 1}]
    set targetPath [list [lindex $landmarks 0]]
    for {set index 0} {$index < $segmentCount} {incr index} {
        set startNode [lindex $landmarks $index]
        set endNode [lindex $landmarks \
            [expr {($index + 1) % [llength $landmarks]}]]
        set segment [::MeshSeamWeld::shortestTargetGraphPath \
            $neighborGraph $candidateAllowed $startNode $endNode]
        if {[llength $segment] < 2} {
            error "No target-mesh path connects landmarks $startNode and $endNode."
        }
        if {$closedLoop && $index == $segmentCount - 1} {
            set targetPath [concat $targetPath [lrange $segment 1 end-1]]
        } else {
            set targetPath [concat $targetPath [lrange $segment 1 end]]
        }
    }
    if {[llength [lsort -integer -unique $targetPath]] != [llength $targetPath]} {
        if {$closedLoop} {
            error "The landmark-guided target path self-intersects or revisits a target node."
        }
        set targetPath [::MeshSeamWeld::loopEraseNodeWalk $targetPath]
        if {[llength $targetPath] < 2} {
            error "The landmark-guided open target path collapsed after removing local backtracks."
        }
    }
    ::HybridCore::log INFO \
        "imprint target_path=landmark_graph source_nodes=[llength $sourceNodes] landmarks=[llength $landmarks] target_nodes=[llength $targetPath] closed_loop=$closedLoop"
    return $targetPath
}

proc ::MeshSeamWeld::matchContinuousTargetPathNodes {sourceNodes candidateNodes {closedLoop 0} {anchorNodes {}}} {
    variable lastLocalTargetEdges

    set sourceNodes [::MeshSeamWeld::uniq $sourceNodes]
    set candidateNodes [lsort -integer -unique $candidateNodes]
    set sourceCount [llength $sourceNodes]
    if {[llength $candidateNodes] < $sourceCount} {
        error "The local target patch has fewer candidate nodes than the source path."
    }
    if {[llength $anchorNodes] == 0} {
        set anchorNodes [::MeshSeamWeld::nearestCandidateAnchorsFromCoordinates \
            $sourceNodes $candidateNodes]
    }
    if {[llength $anchorNodes] != $sourceCount} {
        error "The post-imprint anchor count does not match the source path."
    }

    set neighborGraph [::MeshSeamWeld::targetNeighborGraphFromEdges \
        $lastLocalTargetEdges]
    if {[dict size $neighborGraph] == 0} {
        error "The current target patch contains no usable shell edges."
    }
    set candidateAllowed [dict create]
    foreach nodeId $candidateNodes { dict set candidateAllowed $nodeId 1 }

    # Closest-node anchors are only reliable as starting hints.  In particular,
    # a fine source boundary can produce a long run of identical closest
    # anchors on a coarser or freshly remeshed target.  Restricting every source
    # node to a fixed neighborhood of its own anchor then prevents a valid
    # target walk from ever leaving that neighborhood.
    #
    # Start in a bounded neighborhood of the first anchor, then advance exactly
    # one post-imprint target-mesh edge per source node.  A bounded beam retains
    # the geometrically best walks, so memory and run time do not grow with the
    # full local-patch node count.
    set firstSourcePoint [::MeshSeamWeld::nodeXYZ [lindex $sourceNodes 0]]
    set firstAnchor [lindex $anchorNodes 0]
    foreach attempt {
        {64 1 8}
        {128 2 12}
        {256 3 16}
        {512 5 24}
    } {
        lassign $attempt beamWidth startRadius startLimit
        set startNodes {}
        foreach startNode [::MeshSeamWeld::boundedTargetCandidates \
            $firstAnchor $neighborGraph $firstSourcePoint \
            $startRadius $startLimit] {
            if {[dict exists $candidateAllowed $startNode] &&
                [dict exists $neighborGraph $startNode]} {
                lappend startNodes $startNode
            }
        }
        if {[llength $startNodes] == 0} { continue }

        if {$sourceCount == 1} {
            return [list [lindex $startNodes 0]]
        }

        set states [dict create]
        foreach startNode $startNodes {
            set startCost [::MeshSeamWeld::dist2 \
                $firstSourcePoint \
                [::MeshSeamWeld::nodeXYZ $startNode]]
            foreach candidate [dict get $neighborGraph $startNode] {
                if {$candidate == $startNode ||
                    ![dict exists $candidateAllowed $candidate]} {
                    continue
                }
                set stateKey "$startNode,$startNode,$candidate"
                set stateCost [expr {$startCost + [::MeshSeamWeld::dist2 \
                    [::MeshSeamWeld::nodeXYZ [lindex $sourceNodes 1]] \
                    [::MeshSeamWeld::nodeXYZ $candidate]]}]
                if {![dict exists $states $stateKey] ||
                    $stateCost < [dict get $states $stateKey]} {
                    dict set states $stateKey $stateCost
                }
            }
        }
        set states [::MeshSeamWeld::limitTargetTrackingStates \
            $states $beamWidth]

        set backPointers [dict create]
        for {set layerIndex 2} {
            $layerIndex < $sourceCount && [dict size $states] > 0
        } {incr layerIndex} {
            set nextStates [dict create]
            set nextPrevious [dict create]
            set sourcePoint [::MeshSeamWeld::nodeXYZ \
                [lindex $sourceNodes $layerIndex]]
            foreach stateKey [dict keys $states] {
                lassign [split $stateKey ,] startNode previous current
                if {![dict exists $neighborGraph $current]} { continue }
                foreach candidate [dict get $neighborGraph $current] {
                    if {$candidate == $previous ||
                        $candidate == $startNode ||
                        ![dict exists $candidateAllowed $candidate]} {
                        continue
                    }
                    if {$closedLoop &&
                        $layerIndex == $sourceCount - 1 &&
                        ![dict exists $lastLocalTargetEdges \
                            [::MeshSeamWeld::canonicalEdgeKey \
                                $candidate $startNode]]} {
                        continue
                    }
                    set nextKey "$startNode,$current,$candidate"
                    set nextCost [expr {[dict get $states $stateKey] + \
                        [::MeshSeamWeld::dist2 $sourcePoint \
                            [::MeshSeamWeld::nodeXYZ $candidate]]}]
                    if {![dict exists $nextStates $nextKey] ||
                        $nextCost < [dict get $nextStates $nextKey]} {
                        dict set nextStates $nextKey $nextCost
                        dict set nextPrevious $nextKey $stateKey
                    }
                }
            }
            set states [::MeshSeamWeld::limitTargetTrackingStates \
                $nextStates $beamWidth]
            foreach retainedState [dict keys $states] {
                dict set backPointers "$layerIndex|$retainedState" \
                    [dict get $nextPrevious $retainedState]
            }
            ::MeshSeamWeld::responsiveCheckpoint $layerIndex 16
        }

        set attemptBestPath {}
        set attemptBestCost ""
        foreach stateKey [dict keys $states] {
            lassign [split $stateKey ,] startNode previous endNode
            if {$closedLoop && ![dict exists $lastLocalTargetEdges \
                [::MeshSeamWeld::canonicalEdgeKey $endNode $startNode]]} {
                continue
            }
            set stateCost [dict get $states $stateKey]
            if {$attemptBestCost ne "" &&
                $stateCost >= $attemptBestCost} {
                continue
            }
            set candidatePath [lrepeat $sourceCount 0]
            set currentState $stateKey
            for {set pathIndex [expr {$sourceCount - 1}]} {
                $pathIndex >= 2
            } {incr pathIndex -1} {
                lassign [split $currentState ,] pathStart pathPrevious pathCurrent
                lset candidatePath $pathIndex $pathCurrent
                set currentState [dict get $backPointers \
                    "$pathIndex|$currentState"]
            }
            lassign [split $currentState ,] pathStart pathPrevious pathCurrent
            lset candidatePath 0 $pathStart
            lset candidatePath 1 $pathCurrent
            if {[llength [lsort -integer -unique $candidatePath]] != \
                $sourceCount} {
                continue
            }
            set attemptBestPath $candidatePath
            set attemptBestCost $stateCost
        }
        if {[llength $attemptBestPath] == $sourceCount} {
            set duplicateAnchors [expr {
                [llength $anchorNodes] -
                [llength [lsort -integer -unique $anchorNodes]]}]
            ::HybridCore::log INFO \
                "imprint target_path=topology_beam nodes=$sourceCount beam_width=$beamWidth start_radius=$startRadius duplicate_anchors=$duplicateAnchors candidate_pool=[llength $candidateNodes]"
            return $attemptBestPath
        }
    }
    error "No unique topology-continuous target path could be reconstructed from the post-imprint local patch."
}

proc ::MeshSeamWeld::targetPathNodesAfterImprint {sourceNodes imprintNodes {closedLoop 0}} {
    variable lastLocalTargetNodeIds
    if {[llength $imprintNodes] == [llength $sourceNodes]} {
        # Some HyperMesh builds/workflows expose a complete ordered result
        # list. Preserve it when available; otherwise production reconstructs
        # the path from bounded post-imprint topology neighborhoods.
        return $imprintNodes
    }
    if {![catch {
        set targetNodes [::MeshSeamWeld::matchContinuousTargetPathNodes \
            $sourceNodes $imprintNodes $closedLoop]
    } topologyErr]} {
        return $targetNodes
    }
    if {[llength $lastLocalTargetNodeIds] > [llength $imprintNodes] && ![catch {
        set targetNodes [::MeshSeamWeld::matchContinuousTargetPathNodes \
            $sourceNodes $lastLocalTargetNodeIds $closedLoop]
    } fullPatchErr]} {
        return $targetNodes
    }
    error "$topologyErr"
}

proc ::MeshSeamWeld::pathPairingCost {sourceNodes targetNodes {closedLoop 0}} {
    set sourceCount [llength $sourceNodes]
    set targetCount [llength $targetNodes]
    if {$sourceCount == 0 || $targetCount == 0} { return Inf }
    set sourceParameters [::MeshSeamWeld::normalizedPathParameters \
        $sourceNodes $closedLoop]
    set targetParameters [::MeshSeamWeld::normalizedPathParameters \
        $targetNodes $closedLoop]
    set targetIndices [::MeshSeamWeld::nearestPathIndicesForParameters \
        $sourceParameters $targetParameters]
    set cost 0.0
    for {set sourceIndex 0} {$sourceIndex < $sourceCount} {incr sourceIndex} {
        set targetIndex [lindex $targetIndices $sourceIndex]
        set sourceNode [lindex $sourceNodes $sourceIndex]
        set targetNode [lindex $targetNodes $targetIndex]
        set cost [expr {$cost + [::MeshSeamWeld::dist2 \
            [::MeshSeamWeld::nodeXYZ $sourceNode] \
            [::MeshSeamWeld::nodeXYZ $targetNode]]}]
    }
    return $cost
}

proc ::MeshSeamWeld::rotateList {items offset} {
    set count [llength $items]
    if {$count == 0} {
        return {}
    }
    set offset [expr {(($offset % $count) + $count) % $count}]
    if {$offset == 0} {
        return $items
    }
    return [concat [lrange $items $offset end] [lrange $items 0 [expr {$offset - 1}]]]
}

proc ::MeshSeamWeld::alignTargetPathNodes {sourceNodes targetNodes {closedLoop 0}} {
    if {[llength $sourceNodes] < 2 || [llength $targetNodes] < 2} {
        return $targetNodes
    }

    if {!$closedLoop} {
        set reversed [lreverse $targetNodes]
        if {[::MeshSeamWeld::pathPairingCost $sourceNodes $reversed 0] <
            [::MeshSeamWeld::pathPairingCost $sourceNodes $targetNodes 0]} {
            return $reversed
        }
        return $targetNodes
    }

    # A closed target path may start anywhere and may have a different number
    # of nodes. Compare both directions at every cyclic offset using normalized
    # path position. This keeps the mapping monotonic and prevents a rotated or
    # reversed list from creating long crossed connectors.
    set bestPath {}
    set bestCost ""
    foreach base [list $targetNodes [lreverse $targetNodes]] {
        for {set offset 0} {$offset < [llength $base]} {incr offset} {
            set candidate [::MeshSeamWeld::rotateList $base $offset]
            set cost [::MeshSeamWeld::pathPairingCost \
                $sourceNodes $candidate 1]
            if {$bestCost eq "" || $cost < $bestCost} {
                set bestCost $cost
                set bestPath $candidate
            }
        }
    }
    return $bestPath
}

proc ::MeshSeamWeld::nearestAlignedTargetAnchors {sourceNodes targetNodes {closedLoop 0} {radius 8}} {
    set count [llength $sourceNodes]
    set targetCount [llength $targetNodes]
    set sourceParameters [::MeshSeamWeld::normalizedPathParameters \
        $sourceNodes $closedLoop]
    set targetParameters [::MeshSeamWeld::normalizedPathParameters \
        $targetNodes $closedLoop]
    set baseIndices [::MeshSeamWeld::nearestPathIndicesForParameters \
        $sourceParameters $targetParameters]
    # A target path may be more finely discretized than the source path.  A
    # fixed eight-node window then misses the actual geometric mate.  Scale
    # the local search window by the two path resolutions while retaining the
    # small bounded window used for local list slips.
    set radius [expr {max($radius, int(ceil(2.0 * $targetCount / \
        max(1, $count))) + 2)}]
    set anchors {}
    for {set sourceIndex 0} {$sourceIndex < $count} {incr sourceIndex} {
        set sourcePoint [::MeshSeamWeld::nodeXYZ [lindex $sourceNodes $sourceIndex]]
        set baseIndex [lindex $baseIndices $sourceIndex]
        set bestNode ""
        set bestDistance ""
        catch {unset checked}
        array set checked {}
        for {set delta [expr {-$radius}]} {$delta <= $radius} {incr delta} {
            set targetIndex [expr {$baseIndex + $delta}]
            if {$closedLoop} {
                set targetIndex [expr {(($targetIndex % $targetCount) + $targetCount) % $targetCount}]
            } elseif {$targetIndex < 0 || $targetIndex >= $targetCount} {
                continue
            }
            if {[info exists checked($targetIndex)]} { continue }
            set checked($targetIndex) 1
            set candidateNode [lindex $targetNodes $targetIndex]
            set distance [::MeshSeamWeld::dist2 $sourcePoint \
                [::MeshSeamWeld::nodeXYZ $candidateNode]]
            if {$bestNode eq "" || $distance < $bestDistance} {
                set bestNode $candidateNode
                set bestDistance $distance
            }
        }
        lappend anchors $bestNode
        ::MeshSeamWeld::responsiveCheckpoint [expr {$sourceIndex + 1}] 256
    }
    return $anchors
}

proc ::MeshSeamWeld::refineEqualTargetPathCorrespondence {sourceNodes targetNodes targetComps {closedLoop 0}} {
    if {[llength $sourceNodes] != [llength $targetNodes] ||
        [llength $sourceNodes] < 2} {
        return $targetNodes
    }

    # hm_getlist nodes 2 can contain a topology-continuous path whose local
    # order is not the original source-to-imprint correspondence.  A global
    # rotate/reverse cannot repair that local slip.  Rebuild the one-to-one
    # order from geometric anchors, but accept it only when every target is
    # unique and the reordered target side is still a real target-mesh path.
    # The global direction and cyclic offset are already aligned, so a bounded
    # neighborhood is sufficient for the local slips observed in native list 2
    # and keeps this validation linear for long production boundaries.
    set geometricPath [::MeshSeamWeld::nearestAlignedTargetAnchors \
        $sourceNodes $targetNodes $closedLoop]
    if {[llength [lsort -integer -unique $geometricPath]] !=
        [llength $geometricPath] ||
        ![::MeshSeamWeld::targetPathIsContinuous \
            $geometricPath $targetComps $closedLoop]} {
        return $targetNodes
    }

    set currentCost [::MeshSeamWeld::pathPairingCost \
        $sourceNodes $targetNodes $closedLoop]
    set geometricCost [::MeshSeamWeld::pathPairingCost \
        $sourceNodes $geometricPath $closedLoop]
    if {$geometricCost + 1.0e-12 < $currentCost} {
        ::HybridCore::log WARN \
            "imprint target_path=geometric_one_to_one_refinement nodes=[llength $targetNodes] old_cost=$currentCost new_cost=$geometricCost"
        return $geometricPath
    }
    return $targetNodes
}

proc ::MeshSeamWeld::targetPathEdgeSet {targetNodes targetComps} {
    variable elemNodesCache
    variable elemComponentCache
    variable nodeElemsCache

    array set allowedComp {}
    foreach compId $targetComps { set allowedComp($compId) 1 }
    foreach nodeId $targetNodes { catch {unset nodeElemsCache($nodeId)} }

    set adjacent [::MeshSeamWeld::adjacentElementsForNodes $targetNodes]
    # Clear reused element IDs before reading connectivity.  Clearing them
    # after the bulk reader allowed its per-element compatibility fallback to
    # return pre-imprint cached node lists.
    foreach elemId $adjacent {
        catch {unset elemNodesCache($elemId)}
        catch {unset elemComponentCache($elemId)}
    }
    set connectivity [::MeshSeamWeld::readElementConnectivityBulk \
        $adjacent {3 4} 1]
    array set targetEdges {}
    set processed 0
    foreach elemId $adjacent {
        set compId [::MeshSeamWeld::elemComponentId $elemId]
        if {![info exists allowedComp($compId)]} { continue }
        if {![dict exists $connectivity $elemId]} { continue }
        set nodes [dict get $connectivity $elemId]
        set count [llength $nodes]
        for {set i 0} {$i < $count} {incr i} {
            set a [lindex $nodes $i]
            set b [lindex $nodes [expr {($i + 1) % $count}]]
            set targetEdges([::MeshSeamWeld::canonicalEdgeKey $a $b]) 1
        }
        incr processed
        ::MeshSeamWeld::responsiveCheckpoint $processed 256
    }

    return [array get targetEdges]
}

proc ::MeshSeamWeld::targetPathIsContinuous {targetNodes targetComps {closedLoop 0}} {
    if {[llength $targetNodes] < [expr {$closedLoop ? 3 : 2}]} {
        return 0
    }
    array set targetEdges [::MeshSeamWeld::targetPathEdgeSet $targetNodes $targetComps]
    set pairCount [expr {$closedLoop ? [llength $targetNodes] : [llength $targetNodes] - 1}]
    for {set i 0} {$i < $pairCount} {incr i} {
        set a [lindex $targetNodes $i]
        set b [lindex $targetNodes [expr {($i + 1) % [llength $targetNodes]}]]
        if {![info exists targetEdges([::MeshSeamWeld::canonicalEdgeKey $a $b])]} {
            return 0
        }
        ::MeshSeamWeld::responsiveCheckpoint [expr {$i + 1}] 512
    }
    return 1
}

proc ::MeshSeamWeld::targetGridKey {xyz} {
    variable targetIndexCellSize
    return [list \
        [expr {int(floor(double([lindex $xyz 0]) / $targetIndexCellSize))}] \
        [expr {int(floor(double([lindex $xyz 1]) / $targetIndexCellSize))}] \
        [expr {int(floor(double([lindex $xyz 2]) / $targetIndexCellSize))}]]
}

proc ::MeshSeamWeld::readElementConnectivityBulk {elemIds allowedNodeCounts {markId 2}} {
    set result [dict create]
    set elemIds [lsort -integer -unique $elemIds]
    if {[llength $elemIds] == 0} { return $result }
    set allowedNodeCounts [lsort -integer -unique $allowedNodeCounts]

    set marked [::MeshSeamWeld::markElements $elemIds $markId]
    set bulkValues {}
    foreach entityType {elems elements} {
        if {![catch {
            set bulkValues [hm_getvalue $entityType mark=$markId dataname=nodes]
        }]} {
            break
        }
    }
    set markedCount [llength $marked]
    if {$markedCount == 1 &&
        [lsearch -exact $allowedNodeCounts [llength $bulkValues]] >= 0} {
        dict set result [lindex $marked 0] $bulkValues
    } elseif {[llength $bulkValues] == $markedCount} {
        foreach elemId $marked nodes $bulkValues {
            if {[lsearch -exact $allowedNodeCounts [llength $nodes]] >= 0} {
                dict set result $elemId $nodes
            }
        }
    } elseif {[llength $allowedNodeCounts] == 1} {
        set nodeCount [lindex $allowedNodeCounts 0]
        if {$nodeCount > 0 && [llength $bulkValues] == $markedCount*$nodeCount} {
            set valueIndex 0
            foreach elemId $marked {
                dict set result $elemId \
                    [lrange $bulkValues $valueIndex [expr {$valueIndex + $nodeCount - 1}]]
                incr valueIndex $nodeCount
            }
        }
    }

    # HyperMesh builds that do not expose a list-per-element mark result fall
    # back only for the missing records and periodically return to the UI.
    set index 0
    foreach elemId $elemIds {
        if {![dict exists $result $elemId]} {
            set nodes [::MeshSeamWeld::elemNodes $elemId]
            if {[lsearch -exact $allowedNodeCounts [llength $nodes]] >= 0} {
                dict set result $elemId $nodes
            }
        }
        incr index
        ::MeshSeamWeld::responsiveCheckpoint $index 256
    }
    return $result
}

proc ::MeshSeamWeld::readShellElementConnectivityBulk {elemIds {markId 2}} {
    return [::MeshSeamWeld::readElementConnectivityBulk \
        $elemIds {3 4} $markId]
}

proc ::MeshSeamWeld::buildTargetElementIndex {targetComps {progressOpened 0}} {
    variable cfg
    variable nodeXYZCache
    variable targetElemGrid
    variable targetElemCentroid
    variable targetNodeToElems
    variable targetIndexCellSize
    variable targetGridMin
    variable targetGridMax

    catch {array unset targetElemGrid}; array set targetElemGrid {}
    catch {array unset targetElemCentroid}; array set targetElemCentroid {}
    catch {array unset targetNodeToElems}; array set targetNodeToElems {}
    set targetIndexCellSize [expr {max(1.0, 2.0 * double($cfg(weld_mesh_size)))}]

    set elemIds {}
    foreach compId $targetComps {
        set elemIds [concat $elemIds [::MeshSeamWeld::componentElementIds $compId]]
    }
    set elemIds [::MeshSeamWeld::uniq $elemIds]
    if {$progressOpened} {
        ::HybridCore::progressUpdate 3.0 "Mesh Seam Weld" \
            "Building target element index..." 1
    }

    # Read connectivity once, then query all coordinates with one marked-node
    # HyperMesh call.  The former implementation called hm_getvalue once per
    # node while Python had already finished, which blocked the HM main thread
    # for a long time on large target components.
    set connectivityMap [::MeshSeamWeld::readShellElementConnectivityBulk $elemIds]
    set elementRecords {}
    set allNodeIds {}
    set scanned 0
    foreach elemId $elemIds {
        if {![dict exists $connectivityMap $elemId]} { continue }
        set nodes [dict get $connectivityMap $elemId]
        lappend elementRecords [list $elemId $nodes]
        set allNodeIds [concat $allNodeIds $nodes]
        incr scanned
        if {$scanned % 256 == 0} { ::HybridCore::cooperativeYield }
    }
    set allNodeIds [lsort -integer -unique $allNodeIds]
    set coordinateMap [::HybridCore::readNodeCoordinatesBulk $allNodeIds \
        [list ::MeshSeamWeld::nodeXYZ]]
    foreach nodeId $allNodeIds {
        if {[dict exists $coordinateMap $nodeId]} {
            set nodeXYZCache($nodeId) [dict get $coordinateMap $nodeId]
        }
    }

    set firstKey 1
    set indexed 0
    foreach record $elementRecords {
        lassign $record elemId nodes
        set x 0.0; set y 0.0; set z 0.0; set valid 1
        foreach nodeId $nodes {
            if {![dict exists $coordinateMap $nodeId]} {
                set valid 0
                break
            }
            set xyz [dict get $coordinateMap $nodeId]
            set x [expr {$x + [lindex $xyz 0]}]
            set y [expr {$y + [lindex $xyz 1]}]
            set z [expr {$z + [lindex $xyz 2]}]
            lappend targetNodeToElems($nodeId) $elemId
        }
        if {!$valid} { continue }
        set count [llength $nodes]
        set centroid [list [expr {$x/$count}] [expr {$y/$count}] [expr {$z/$count}]]
        set targetElemCentroid($elemId) $centroid
        set key [::MeshSeamWeld::targetGridKey $centroid]
        set keyText [join $key ,]
        lappend targetElemGrid($keyText) $elemId
        if {$firstKey} {
            set targetGridMin $key
            set targetGridMax $key
            set firstKey 0
        } else {
            set targetGridMin [list \
                [expr {min([lindex $targetGridMin 0],[lindex $key 0])}] \
                [expr {min([lindex $targetGridMin 1],[lindex $key 1])}] \
                [expr {min([lindex $targetGridMin 2],[lindex $key 2])}]]
            set targetGridMax [list \
                [expr {max([lindex $targetGridMax 0],[lindex $key 0])}] \
                [expr {max([lindex $targetGridMax 1],[lindex $key 1])}] \
                [expr {max([lindex $targetGridMax 2],[lindex $key 2])}]]
        }
        incr indexed
        if {$indexed % 256 == 0} { ::HybridCore::cooperativeYield }
    }
    if {$indexed == 0} {
        error [::HWFlow::txt \
            "无法为目标 component 建立局部 imprint 索引。" \
            "Could not build the local imprint index for the target components."]
    }
    ::HybridCore::log INFO "local imprint index elements=$indexed cell_size=$targetIndexCellSize grid_min=$targetGridMin grid_max=$targetGridMax"
    return $indexed
}

proc ::MeshSeamWeld::nearestIndexedTargetElem {xyz} {
    variable targetElemGrid
    variable targetElemCentroid
    variable targetGridMin
    variable targetGridMax

    set raw [::MeshSeamWeld::targetGridKey $xyz]
    set center {}
    for {set axis 0} {$axis < 3} {incr axis} {
        lappend center [expr {max([lindex $targetGridMin $axis], min([lindex $targetGridMax $axis], [lindex $raw $axis]))}]
    }
    set maxSpan [expr {2 + max( \
        [lindex $targetGridMax 0]-[lindex $targetGridMin 0], \
        [lindex $targetGridMax 1]-[lindex $targetGridMin 1], \
        [lindex $targetGridMax 2]-[lindex $targetGridMin 2])}]
    array set candidates {}
    set foundSpan -1
    for {set span 0} {$span <= $maxSpan} {incr span} {
        for {set ix [expr {[lindex $center 0]-$span}]} {$ix <= [lindex $center 0]+$span} {incr ix} {
            for {set iy [expr {[lindex $center 1]-$span}]} {$iy <= [lindex $center 1]+$span} {incr iy} {
                for {set iz [expr {[lindex $center 2]-$span}]} {$iz <= [lindex $center 2]+$span} {incr iz} {
                    set key "$ix,$iy,$iz"
                    if {![info exists targetElemGrid($key)]} { continue }
                    foreach elemId $targetElemGrid($key) { set candidates($elemId) 1 }
                }
            }
        }
        if {[array size candidates] > 0 && $foundSpan < 0} { set foundSpan $span }
        if {$foundSpan >= 0 && $span >= $foundSpan + 1} { break }
    }
    set bestElem ""
    set bestD2 ""
    foreach elemId [array names candidates] {
        if {![info exists targetElemCentroid($elemId)]} { continue }
        set d2 [::MeshSeamWeld::dist2 $xyz $targetElemCentroid($elemId)]
        if {$bestElem eq "" || $d2 < $bestD2} {
            set bestElem $elemId
            set bestD2 $d2
        }
    }
    if {$bestElem eq ""} {
        error [::HWFlow::txt \
            "无法在目标 component 上定位局部 imprint 单元。" \
            "Could not locate a local imprint element on the target components."]
    }
    return $bestElem
}

proc ::MeshSeamWeld::localTargetPatchForPath {sourceNodes {extraLayers 0}} {
    variable cfg
    variable targetNodeToElems

    array set visited {}
    set frontier {}
    foreach sourceNode $sourceNodes {
        set elemId [::MeshSeamWeld::nearestIndexedTargetElem [::MeshSeamWeld::nodeXYZ $sourceNode]]
        if {![info exists visited($elemId)]} {
            set visited($elemId) 1
            lappend frontier $elemId
        }
    }
    set expandLayers [expr {$cfg(patch_expand_layers) + 3 + max(0, int($extraLayers))}]
    for {set layer 0} {$layer < $expandLayers && [llength $frontier] > 0} {incr layer} {
        set nextFrontier {}
        foreach elemId $frontier {
            foreach nodeId [::MeshSeamWeld::elemNodes $elemId] {
                if {![info exists targetNodeToElems($nodeId)]} { continue }
                foreach neighbor $targetNodeToElems($nodeId) {
                    if {[info exists visited($neighbor)]} { continue }
                    set visited($neighbor) 1
                    lappend nextFrontier $neighbor
                }
            }
        }
        set frontier $nextFrontier
    }
    return [lsort -integer [array names visited]]
}

proc ::MeshSeamWeld::idsAddedToCollection {beforeIds afterIds} {
    array set beforeSet {}
    foreach id $beforeIds { set beforeSet($id) 1 }
    set added {}
    foreach id $afterIds {
        if {![info exists beforeSet($id)]} { lappend added $id }
    }
    return [::MeshSeamWeld::uniq $added]
}

proc ::MeshSeamWeld::sourceComponentIdsForPaths {sourcePaths {knownSourceCompIds {}}} {
    if {[llength $knownSourceCompIds] > 0} {
        return [lsort -integer -unique $knownSourceCompIds]
    }
    set componentIds {}
    foreach sourceNodes $sourcePaths {
        set componentIds [concat $componentIds \
            [::MeshSeamWeld::componentIdsFromNodes $sourceNodes]]
    }
    return [lsort -integer -unique $componentIds]
}

proc ::MeshSeamWeld::legacyIndexedPrepareWeldJobs {sourcePaths targetComps {progressOpened 0} {knownSourceCompIds {}}} {
    set jobs {}
    ::MeshSeamWeld::buildTargetElementIndex $targetComps
    if {$progressOpened} {
        ::HybridCore::progressUpdate 3.0 "Mesh Seam Weld" "Target element index ready; preparing local patches..." 1
    }
    # A batch can contain paths from different source components and can
    # imprint against several target components.  The resulting weld
    # component is named from the complete participating set, not from the
    # component of the current path only.
    set processSourceCompIds [::MeshSeamWeld::sourceComponentIdsForPaths \
        $sourcePaths $knownSourceCompIds]
    set processRelated [lsort -integer -unique [concat \
        $processSourceCompIds $targetComps]]
    set processSeamComponent [::MeshSeamWeld::seamComponentForRelatedComps \
        $processRelated]
    set pathTotal [llength $sourcePaths]
    set pathIndex 0
    foreach sourceNodes $sourcePaths {
        incr pathIndex
        if {[llength $knownSourceCompIds] > 0} {
            set sourceCompIds $knownSourceCompIds
        } else {
            set sourceCompIds [::MeshSeamWeld::componentIdsFromNodes $sourceNodes]
        }
        lappend jobs [dict create \
            source_nodes $sourceNodes \
            source_component_ids $sourceCompIds \
            seam_component $processSeamComponent \
            target_elements [::MeshSeamWeld::localTargetPatchForPath $sourceNodes] \
            center [::MeshSeamWeld::pathCenter $sourceNodes] \
            retry_patch_extra_layers 3]
        if {$progressOpened && ($pathIndex == $pathTotal || $pathIndex % 25 == 0)} {
            set percent [expr {3.0 + 6.0*$pathIndex/double(max(1,$pathTotal))}]
            ::HybridCore::progressUpdate $percent "Mesh Seam Weld" "Prepared local patch $pathIndex/$pathTotal" 1
        }
    }
    return $jobs
}

proc ::MeshSeamWeld::markTargetElementsForProjection {targetComps markId} {
    if {[llength $targetComps] == 0} { error "No target components were selected." }
    foreach entityType {elements elems} {
        catch {*clearmark $entityType $markId}
        foreach selector {"by component id" "by comp id"} {
            if {![catch {
                eval *createmark $entityType $markId [list $selector] $targetComps
            }]} {
                return $entityType
            }
        }
    }
    error "Could not mark target elements for local projection."
}

proc ::MeshSeamWeld::projectNodesToTargetComponents {sourceNodes targetComps {closedLoop 0}} {
    if {[llength [info commands hm_getclosestnode]] == 0} {
        error "hm_getclosestnode is unavailable."
    }
    ::MeshSeamWeld::markTargetElementsForProjection $targetComps 1
    catch {*clearmark nodes 2}
    if {[catch {eval *createmark nodes 2 $sourceNodes} sourceMarkErr]} {
        catch {*clearmark elems 1}
        catch {*clearmark elements 1}
        error "Could not mark source nodes for target projection: $sourceMarkErr"
    }

    set projected [dict create]
    set errors [dict create]
    set projectedCount 0
    foreach sourceNode [::MeshSeamWeld::uniq $sourceNodes] {
        foreach {x y z} [::MeshSeamWeld::nodeXYZ $sourceNode] break
        if {[catch {set targetNode [hm_getclosestnode $x $y $z 1 2]} queryErr] ||
            ![string is integer -strict $targetNode] || $targetNode <= 0} {
            dict set errors $sourceNode \
                "Could not project source node $sourceNode to the selected target components: $queryErr"
            continue
        }
        dict set projected $sourceNode $targetNode
        incr projectedCount
        ::MeshSeamWeld::responsiveCheckpoint $projectedCount 64
    }

    # A closed source boundary may sit inside a surrounding cylindrical target.
    # On a coarse cylinder, nearest-node queries made at the inner radius can
    # collapse several angular positions onto one target node.  That leaves the
    # local patch without enough circumferential seed elements even though the
    # actual target surface surrounds the complete loop.  When that specific
    # signature is present, estimate the enclosing radius from the first-pass
    # targets and query once more along each center-to-boundary ray.  These
    # nodes enlarge only the local patch; imprint still uses the original
    # source path, so ordinary parallel/open welds retain their old behavior.
    set patchNodes [::MeshSeamWeld::uniq [dict values $projected]]
    set radialAssist 0
    set sourceCount [llength $sourceNodes]
    set uniqueCount [llength $patchNodes]
    set minimumCoverage [expr {int(ceil(0.75 * max(1, $sourceCount)))}]
    set projectionCenter {}
    if {$closedLoop} {
        set projectionCenter [::MeshSeamWeld::pathCenter $sourceNodes]
    } elseif {$sourceCount >= 3} {
        set projectionCenter [::MeshSeamWeld::circumcenterFromPath $sourceNodes]
    }
    if {$sourceCount >= 3 && $uniqueCount < $minimumCoverage &&
        [dict size $errors] == 0 && [llength $projectionCenter] == 3} {
        set center $projectionCenter
        set sourceRadiusTotal 0.0
        set validSourceRadii 0
        foreach sourceNode $sourceNodes {
            set radial [::MeshSeamWeld::vsub \
                [::MeshSeamWeld::nodeXYZ $sourceNode] $center]
            set radius [expr {sqrt([::MeshSeamWeld::dot $radial $radial])}]
            if {$radius > 1.0e-9} {
                set sourceRadiusTotal [expr {$sourceRadiusTotal + $radius}]
                incr validSourceRadii
            }
        }
        set targetRadiusTotal 0.0
        set validTargetRadii 0
        foreach targetNode $patchNodes {
            if {[catch {
                set radial [::MeshSeamWeld::vsub \
                    [::MeshSeamWeld::nodeXYZ $targetNode] $center]
                set radius [expr {sqrt([::MeshSeamWeld::dot $radial $radial])}]
            }]} { continue }
            if {$radius > 1.0e-9} {
                set targetRadiusTotal [expr {$targetRadiusTotal + $radius}]
                incr validTargetRadii
            }
        }
        if {$validSourceRadii > 0 && $validTargetRadii > 0} {
            set sourceRadius [expr {$sourceRadiusTotal / $validSourceRadii}]
            set targetRadius [expr {$targetRadiusTotal / $validTargetRadii}]
            if {$targetRadius > 1.15 * $sourceRadius} {
                set assistedNodes {}
                set assistedCount 0
                foreach sourceNode $sourceNodes {
                    set radial [::MeshSeamWeld::vsub \
                        [::MeshSeamWeld::nodeXYZ $sourceNode] $center]
                    set radius [expr {sqrt([::MeshSeamWeld::dot $radial $radial])}]
                    if {$radius <= 1.0e-9} { continue }
                    set probe [::MeshSeamWeld::vadd $center \
                        [::MeshSeamWeld::vscale $radial \
                            [expr {$targetRadius / $radius}]]]
                    foreach {x y z} $probe break
                    set queryErr ""
                    if {[catch {
                        set targetNode [hm_getclosestnode $x $y $z 1 2]
                    } queryErr] || ![string is integer -strict $targetNode] ||
                        $targetNode <= 0} {
                        continue
                    }
                    lappend assistedNodes $targetNode
                    incr assistedCount
                    ::MeshSeamWeld::responsiveCheckpoint $assistedCount 64
                }
                set assistedNodes [::MeshSeamWeld::uniq $assistedNodes]
                if {[llength $assistedNodes] > $uniqueCount} {
                    set radialAssist 1
                    set patchNodes [::MeshSeamWeld::uniq \
                        [concat $patchNodes $assistedNodes]]
                    ::HybridCore::log INFO \
                        "target patch radial_assist source_nodes=$sourceCount direct_seeds=$uniqueCount radial_seeds=[llength $assistedNodes] source_radius=$sourceRadius target_radius=$targetRadius"
                }
            }
        }
    }
    catch {*clearmark nodes 2}
    catch {*clearmark elems 1}
    catch {*clearmark elements 1}
    return [dict create projected $projected errors $errors \
        patch_nodes $patchNodes radial_assist $radialAssist]
}

proc ::MeshSeamWeld::expandTargetElementPatch {seedElemIds targetComps {markId 1} {layers ""}} {
    variable cfg
    variable elemComponentCache
    variable elemNodesCache
    if {$layers eq ""} {
        set layers [expr {max(2, min(3, int($cfg(patch_expand_layers))))}]
    } else {
        set layers [expr {max(2, min(3, int($layers)))}]
    }
    set marked [::MeshSeamWeld::markElements \
        [lsort -integer -unique $seedElemIds] $markId]
    if {[llength $marked] == 0} { return {} }
    for {set layer 0} {$layer < $layers} {incr layer} {
        set expanded 0
        foreach entityType {elements elems} {
            foreach option {{by adjacent} adjacent} {
                if {![catch {*appendmark $entityType $markId $option}]} {
                    set expanded 1
                    break
                }
            }
            if {$expanded} { break }
        }
        if {!$expanded} { break }
    }

    array set allowed {}
    foreach componentId $targetComps { set allowed($componentId) 1 }
    set filtered {}
    set filteredIndex 0
    foreach elemId [::MeshSeamWeld::markedElementIds $markId] {
        incr filteredIndex
        ::MeshSeamWeld::responsiveCheckpoint $filteredIndex 128
        catch {unset elemComponentCache($elemId)}
        catch {unset elemNodesCache($elemId)}
        set componentId [::MeshSeamWeld::elemComponentId $elemId]
        if {![info exists allowed($componentId)]} { continue }
        if {![::MeshSeamWeld::isLinearShellElement $elemId]} { continue }
        lappend filtered $elemId
    }
    return [::MeshSeamWeld::markElements \
        [lsort -integer -unique $filtered] $markId]
}

proc ::MeshSeamWeld::localTargetPatchFromProjectedNodes {projectedNodes targetComps} {
    variable elemComponentCache
    variable elemNodesCache
    array set allowed {}
    foreach componentId $targetComps { set allowed($componentId) 1 }
    set seedElems {}
    # Resolve the complete boundary-node set to attached elements in one mark
    # operation. The previous per-node ownership lookup became effectively
    # quadratic in HyperMesh for long closed boundaries.
    set seedIndex 0
    foreach elemId [::MeshSeamWeld::adjacentElementsForNodes \
        [::MeshSeamWeld::uniq $projectedNodes]] {
        incr seedIndex
        ::MeshSeamWeld::responsiveCheckpoint $seedIndex 128
        # Imprint/remesh can reuse an old element ID with new connectivity.
        # Always query ownership and shell shape from the current database.
        catch {unset elemComponentCache($elemId)}
        catch {unset elemNodesCache($elemId)}
        set componentId [::MeshSeamWeld::elemComponentId $elemId]
        if {![info exists allowed($componentId)]} { continue }
        if {![::MeshSeamWeld::isLinearShellElement $elemId]} { continue }
        lappend seedElems $elemId
    }
    set seedElems [::MeshSeamWeld::uniq $seedElems]
    if {[llength $seedElems] == 0} {
        error "Projected target nodes have no attached shell elements in the selected target components."
    }
    # Expand the complete seed set by a bounded two or three target-element
    # rings before imprint. This is the sole production patch planner.
    set patch [::MeshSeamWeld::expandTargetElementPatch \
        $seedElems $targetComps 1]
    if {[llength $patch] == 0} {
        error "Could not create a local target-element patch from projected nodes."
    }
    return [lsort -integer -unique $patch]
}

proc ::MeshSeamWeld::prepareWeldJobs {sourcePaths targetComps {progressOpened 0} {knownSourceCompIds {}}} {
    variable nodeXYZCache
    set jobs {}
    set allSourceNodes {}
    foreach sourceNodes $sourcePaths {
        set allSourceNodes [concat $allSourceNodes $sourceNodes]
    }
    set allSourceNodes [lsort -integer -unique $allSourceNodes]
    # Boundary discovery is complete at this point. Read every source
    # coordinate as one batch before any target query or target-mesh lookup.
    set sourceCoordinates [::HybridCore::readNodeCoordinatesBulk $allSourceNodes \
        [list ::MeshSeamWeld::nodeXYZ]]
    foreach nodeId $allSourceNodes {
        set nodeXYZCache($nodeId) [dict get $sourceCoordinates $nodeId]
    }

    # Use every source path and every selected target component when deriving
    # the batch seam thickness.  This is intentionally computed once so a
    # multi-component batch cannot produce different SEAM_Tx names merely
    # because its paths were prepared in a different order.
    set processSourceCompIds [::MeshSeamWeld::sourceComponentIdsForPaths \
        $sourcePaths $knownSourceCompIds]
    set processRelated [lsort -integer -unique [concat \
        $processSourceCompIds $targetComps]]
    set processSeamComponent [::MeshSeamWeld::seamComponentForRelatedComps \
        $processRelated]

    set pathTotal [llength $sourcePaths]
    set pathIndex 0
    foreach sourceNodes $sourcePaths {
        incr pathIndex
        if {[llength $knownSourceCompIds] > 0} {
            set sourceCompIds $knownSourceCompIds
        } else {
            set sourceCompIds [::MeshSeamWeld::componentIdsFromNodes $sourceNodes]
        }
        lappend jobs [dict create \
            source_nodes $sourceNodes \
            source_component_ids $sourceCompIds \
            seam_component $processSeamComponent \
            target_components $targetComps \
            target_elements {} \
            center [::MeshSeamWeld::pathCenter $sourceNodes] \
            preparation_error ""]
        if {$progressOpened && ($pathIndex == $pathTotal || $pathIndex % 25 == 0)} {
            set percent [expr {3.0 + 6.0*$pathIndex/double(max(1,$pathTotal))}]
            ::HybridCore::progressUpdate $percent "Mesh Seam Weld" \
                "Prepared source boundary $pathIndex/$pathTotal" 1
        }
    }
    return $jobs
}

proc ::MeshSeamWeld::prepareCurrentTargetPatch {sourceNodes targetComps {closedLoop 0}} {
    variable nodeXYZCache
    set sourceNodes [::MeshSeamWeld::uniq $sourceNodes]
    set sourceCoordinates [::HybridCore::readNodeCoordinatesBulk $sourceNodes \
        [list ::MeshSeamWeld::nodeXYZ]]
    foreach nodeId $sourceNodes {
        set nodeXYZCache($nodeId) [dict get $sourceCoordinates $nodeId]
    }

    set projection [::MeshSeamWeld::projectNodesToTargetComponents \
        $sourceNodes $targetComps $closedLoop]
    set projectedMap [dict get $projection projected]
    set projectionErrors [dict get $projection errors]
    set projectedNodes {}
    foreach sourceNode $sourceNodes {
        if {[dict exists $projectionErrors $sourceNode]} {
            error [dict get $projectionErrors $sourceNode]
        }
        if {![dict exists $projectedMap $sourceNode]} {
            error "No projected target node was returned for source node $sourceNode."
        }
        lappend projectedNodes [dict get $projectedMap $sourceNode]
    }
    set patchNodes $projectedNodes
    if {[dict exists $projection patch_nodes]} {
        set patchNodes [dict get $projection patch_nodes]
    }
    set targetElements [::MeshSeamWeld::localTargetPatchFromProjectedNodes \
        $patchNodes $targetComps]
    return [dict create projected_nodes $projectedNodes \
        patch_nodes $patchNodes \
        radial_assist [::MeshSeamWeld::dictValueOr $projection radial_assist 0] \
        target_components $targetComps target_elements $targetElements]
}

proc ::MeshSeamWeld::directStructuredStripQuadNodeLists {crossChains {closedLoop 0}} {
    set nodeCount [llength $crossChains]
    if {$nodeCount < 2 || ($closedLoop && $nodeCount < 3)} {
        error "Too few cross chains for direct structured strip creation."
    }
    set layerNodeCount [llength [lindex $crossChains 0]]
    if {$layerNodeCount < 2} {
        error "Each direct structured strip cross chain must contain at least two nodes."
    }
    foreach chain $crossChains {
        if {[llength $chain] != $layerNodeCount} {
            error "Direct structured strip cross chains have different layer counts."
        }
    }
    set crossDensity [expr {$layerNodeCount - 1}]
    set segmentCount [expr {$closedLoop ? $nodeCount : $nodeCount - 1}]
    set quads {}
    for {set index 0} {$index < $segmentCount} {incr index} {
        set nextIndex [expr {($index + 1) % $nodeCount}]
        set currentChain [lindex $crossChains $index]
        set nextChain [lindex $crossChains $nextIndex]
        for {set layer 0} {$layer < $crossDensity} {incr layer} {
            set quadNodes [list \
                [lindex $currentChain $layer] [lindex $nextChain $layer] \
                [lindex $nextChain [expr {$layer + 1}]] \
                [lindex $currentChain [expr {$layer + 1}]]]
            if {[llength [lsort -integer -unique $quadNodes]] != 4} {
                error "Direct weld strip segment [expr {$index + 1}], layer [expr {$layer + 1}] contains duplicate nodes."
            }
            lappend quads $quadNodes
        }
        ::MeshSeamWeld::responsiveCheckpoint [expr {$index + 1}] 256
    }
    return $quads
}

proc ::MeshSeamWeld::directStripQuadNodeLists {sourceNodes targetNodes {closedLoop 0}} {
    if {[llength $sourceNodes] != [llength $targetNodes]} {
        error "Source and target node counts do not match for direct strip creation."
    }
    set crossChains {}
    for {set index 0} {$index < [llength $sourceNodes]} {incr index} {
        lappend crossChains [list \
            [lindex $sourceNodes $index] [lindex $targetNodes $index]]
    }
    return [::MeshSeamWeld::directStructuredStripQuadNodeLists \
        $crossChains $closedLoop]
}

proc ::MeshSeamWeld::unequalStripElementNodeLists {sourceNodes targetNodes {closedLoop 0}} {
    set sourceCount [llength $sourceNodes]
    set targetCount [llength $targetNodes]
    if {$sourceCount < [expr {$closedLoop ? 3 : 2}] ||
        $targetCount < [expr {$closedLoop ? 3 : 2}]} {
        error "Too few nodes for unequal strip creation."
    }
    set sourceSegments [expr {$closedLoop ? $sourceCount : $sourceCount - 1}]
    set targetSegments [expr {$closedLoop ? $targetCount : $targetCount - 1}]
    set sourceIndex 0
    set targetIndex 0
    set elements {}
    set epsilon 1.0e-10
    while {$sourceIndex < $sourceSegments || $targetIndex < $targetSegments} {
        set sourceNode [lindex $sourceNodes [expr {$sourceIndex % $sourceCount}]]
        set targetNode [lindex $targetNodes [expr {$targetIndex % $targetCount}]]
        set nextSourceParameter [expr {$sourceIndex < $sourceSegments ?
            double($sourceIndex + 1) / $sourceSegments : 2.0}]
        set nextTargetParameter [expr {$targetIndex < $targetSegments ?
            double($targetIndex + 1) / $targetSegments : 2.0}]
        if {abs($nextSourceParameter - $nextTargetParameter) <= $epsilon} {
            set nextSource [lindex $sourceNodes \
                [expr {($sourceIndex + 1) % $sourceCount}]]
            set nextTarget [lindex $targetNodes \
                [expr {($targetIndex + 1) % $targetCount}]]
            lappend elements [list $sourceNode $nextSource $nextTarget $targetNode]
            incr sourceIndex
            incr targetIndex
        } elseif {$nextSourceParameter < $nextTargetParameter} {
            set nextSource [lindex $sourceNodes \
                [expr {($sourceIndex + 1) % $sourceCount}]]
            lappend elements [list $sourceNode $nextSource $targetNode]
            incr sourceIndex
        } else {
            set nextTarget [lindex $targetNodes \
                [expr {($targetIndex + 1) % $targetCount}]]
            lappend elements [list $sourceNode $nextTarget $targetNode]
            incr targetIndex
        }
    }
    return $elements
}

proc ::MeshSeamWeld::adaptiveStructuredStripElementNodeLists {crossChains {closedLoop 0}} {
    set nodeCount [llength $crossChains]
    if {$nodeCount < 2 || ($closedLoop && $nodeCount < 3)} {
        error "Too few cross chains for adaptive structured strip creation."
    }

    set firstCount [llength [lindex $crossChains 0]]
    if {$firstCount < 2} {
        error "Each adaptive structured strip cross chain must contain at least two nodes."
    }
    set uniform 1
    foreach chain $crossChains {
        if {[llength $chain] < 2} {
            error "Each adaptive structured strip cross chain must contain at least two nodes."
        }
        if {[llength $chain] != $firstCount} {
            set uniform 0
        }
    }
    if {$uniform} {
        return [::MeshSeamWeld::directStructuredStripQuadNodeLists \
            $crossChains $closedLoop]
    }

    # A single maximum width forced every longitudinal section to use the
    # same number of transverse layers.  Mesh each neighboring pair with its
    # actual chain lengths instead.  The zipper emits quads where counts
    # agree and only the necessary transition triangles where they do not,
    # so a narrow start does not inherit the wide end's refinement.
    set segmentCount [expr {$closedLoop ? $nodeCount : $nodeCount - 1}]
    set elements {}
    for {set index 0} {$index < $segmentCount} {incr index} {
        set nextIndex [expr {($index + 1) % $nodeCount}]
        set segment [::MeshSeamWeld::unequalStripElementNodeLists \
            [lindex $crossChains $index] [lindex $crossChains $nextIndex] 0]
        if {[llength $segment] == 0} {
            error "Adaptive structured strip segment [expr {$index + 1}] is empty."
        }
        set elements [concat $elements $segment]
        ::MeshSeamWeld::responsiveCheckpoint [expr {$index + 1}] 256
    }
    return $elements
}

proc ::MeshSeamWeld::createTrackedNodeAtXYZ {xyz} {
    foreach {x y z} $xyz break
    if {[catch {*createnode $x $y $z 0 0 0} createErr]} {
        error "Failed to create an intermediate weld node: $createErr"
    }
    catch {*clearmark nodes 1}
    if {[catch {*createmark nodes 1 -1} markErr]} {
        error "Could not mark the intermediate weld node: $markErr"
    }
    set createdNodes {}
    catch {set createdNodes [hm_getmark nodes 1]}
    catch {*clearmark nodes 1}
    if {[llength $createdNodes] != 1} {
        error "Could not uniquely identify the newly created intermediate weld node."
    }
    return [lindex $createdNodes 0]
}

proc ::MeshSeamWeld::normalizedCrossLayerCounts {crossDensity nodeCount} {
    if {[string is integer -strict $crossDensity]} {
        if {$crossDensity < 1} {
            error "Direct structured strip cross density must be a positive integer."
        }
        set counts {}
        for {set index 0} {$index < $nodeCount} {incr index} {
            lappend counts $crossDensity
        }
        return $counts
    }
    if {[llength $crossDensity] != $nodeCount} {
        error "Adaptive cross-layer counts do not match the node path count."
    }
    set counts {}
    foreach density $crossDensity {
        if {![string is integer -strict $density] || $density < 1} {
            error "Adaptive cross-layer counts must be positive integers."
        }
        lappend counts $density
    }
    return $counts
}

proc ::MeshSeamWeld::createDirectStructuredStrip {sourceNodes targetNodes crossDensity outputCompName outputCompId beforeOutputElems {closedLoop 0}} {
    if {[llength $sourceNodes] != [llength $targetNodes]} {
        error "Source and target node counts do not match for direct structured strip creation."
    }
    set crossLayerCounts [::MeshSeamWeld::normalizedCrossLayerCounts \
        $crossDensity [llength $sourceNodes]]
    catch {*currentcollector component $outputCompName}
    catch {*currentcollector components $outputCompName}

    set crossChains {}
    set intermediateNodeCount 0
    set sourcePairCount 0
    for {set index 0} {$index < [llength $sourceNodes]} {incr index} {
        set sourceNode [lindex $sourceNodes $index]
        set targetNode [lindex $targetNodes $index]
        set localCrossDensity [lindex $crossLayerCounts $index]
        set sourceXYZ [::MeshSeamWeld::nodeXYZ $sourceNode]
        set targetXYZ [::MeshSeamWeld::nodeXYZ $targetNode]
        set chain [list $sourceNode]
        for {set layer 1} {$layer < $localCrossDensity} {incr layer} {
            set ratio [expr {double($layer) / double($localCrossDensity)}]
            set xyz {}
            for {set axis 0} {$axis < 3} {incr axis} {
                set sourceValue [lindex $sourceXYZ $axis]
                set targetValue [lindex $targetXYZ $axis]
                lappend xyz [expr {$sourceValue + $ratio * ($targetValue - $sourceValue)}]
            }
            lappend chain [::MeshSeamWeld::createTrackedNodeAtXYZ $xyz]
            incr intermediateNodeCount
            ::MeshSeamWeld::responsiveCheckpoint $intermediateNodeCount 64
        }
        lappend chain $targetNode
        lappend crossChains $chain
        incr sourcePairCount
        ::MeshSeamWeld::responsiveCheckpoint $sourcePairCount 128
    }

    set elementPlans [::MeshSeamWeld::adaptiveStructuredStripElementNodeLists \
        $crossChains $closedLoop]
    set segmentIndex 0
    foreach elementNodes $elementPlans {
        incr segmentIndex
        set config [expr {[llength $elementNodes] == 3 ? 103 : 104}]
        if {[catch {
            eval *createlist nodes 1 $elementNodes
            *createelement $config 1 1 1
        } createErr]} {
            error "Failed to create direct weld strip element $segmentIndex: $createErr"
        }
        ::MeshSeamWeld::responsiveCheckpoint $segmentIndex 64
    }
    set elemIds [::MeshSeamWeld::idsAddedToCollection $beforeOutputElems \
        [::MeshSeamWeld::componentElementIds $outputCompId]]
    if {[llength $elemIds] == 0} {
        error "Direct structured weld strip creation did not add any elements."
    }
    set expectedElemCount [llength $elementPlans]
    if {[llength $elemIds] != $expectedElemCount} {
        error "Direct structured weld strip created [llength $elemIds]/$expectedElemCount expected elements."
    }
    ::MeshSeamWeld::moveElemsToComponent $elemIds $outputCompName
    set layerSummary [join $crossLayerCounts ,]
    ::HybridCore::log INFO \
        "weld_mesh creation_mode=direct_structured cross_layers=$layerSummary intermediate_nodes=$intermediateNodeCount elements=[llength $elemIds] closed_loop=$closedLoop"
    return $elemIds
}

proc ::MeshSeamWeld::createDirectSingleLayerStrip {sourceNodes targetNodes outputCompName outputCompId beforeOutputElems {closedLoop 0}} {
    return [::MeshSeamWeld::createDirectStructuredStrip \
        $sourceNodes $targetNodes 1 $outputCompName $outputCompId \
        $beforeOutputElems $closedLoop]
}

proc ::MeshSeamWeld::createDirectUnequalStrip {sourceNodes targetNodes outputCompName outputCompId beforeOutputElems {closedLoop 0}} {
    catch {*currentcollector component $outputCompName}
    catch {*currentcollector components $outputCompName}
    set elementPlans [::MeshSeamWeld::unequalStripElementNodeLists \
        $sourceNodes $targetNodes $closedLoop]
    set elementIndex 0
    foreach elementNodes $elementPlans {
        incr elementIndex
        set config [expr {[llength $elementNodes] == 3 ? 103 : 104}]
        if {[catch {
            eval *createlist nodes 1 $elementNodes
            *createelement $config 1 1 1
        } createErr]} {
            error "Failed to create unequal weld strip element $elementIndex: $createErr"
        }
        ::MeshSeamWeld::responsiveCheckpoint $elementIndex 64
    }
    set elemIds [::MeshSeamWeld::idsAddedToCollection $beforeOutputElems \
        [::MeshSeamWeld::componentElementIds $outputCompId]]
    if {[llength $elemIds] != [llength $elementPlans]} {
        error "Unequal weld strip created [llength $elemIds]/[llength $elementPlans] expected elements."
    }
    ::MeshSeamWeld::moveElemsToComponent $elemIds $outputCompName
    ::HybridCore::log INFO \
        "weld_mesh creation_mode=direct_topology_zipper source_nodes=[llength $sourceNodes] target_nodes=[llength $targetNodes] elements=[llength $elemIds] closed_loop=$closedLoop"
    return $elemIds
}

proc ::MeshSeamWeld::createAnchoredStructuredStrip {sourceNodes targetNodes anchorIndices crossDensity outputCompName outputCompId beforeOutputElems {closedLoop 0}} {
    variable cfg
    if {[llength $anchorIndices] != [llength $sourceNodes]} {
        error "Invalid anchored structured strip correspondence or cross density."
    }
    set crossLayerCounts [::MeshSeamWeld::normalizedCrossLayerCounts \
        $crossDensity [llength $sourceNodes]]
    catch {*currentcollector component $outputCompName}
    catch {*currentcollector components $outputCompName}

    set crossChains {}
    set intermediateNodeCount 0
    for {set index 0} {$index < [llength $sourceNodes]} {incr index} {
        set sourceNode [lindex $sourceNodes $index]
        set targetNode [lindex $targetNodes [lindex $anchorIndices $index]]
        set localCrossDensity [lindex $crossLayerCounts $index]
        set sourceXYZ [::MeshSeamWeld::nodeXYZ $sourceNode]
        set targetXYZ [::MeshSeamWeld::nodeXYZ $targetNode]
        set chain [list $sourceNode]
        for {set layer 1} {$layer < $localCrossDensity} {incr layer} {
            set ratio [expr {double($layer) / double($localCrossDensity)}]
            set xyz {}
            for {set axis 0} {$axis < 3} {incr axis} {
                lappend xyz [expr {[lindex $sourceXYZ $axis] + $ratio *
                    ([lindex $targetXYZ $axis] - [lindex $sourceXYZ $axis])}]
            }
            lappend chain [::MeshSeamWeld::createTrackedNodeAtXYZ $xyz]
            incr intermediateNodeCount
        }
        lappend chain $targetNode
        lappend crossChains $chain
    }

    set elementPlans {}
    set uniform 1
    set firstDensity [lindex $crossLayerCounts 0]
    foreach density $crossLayerCounts {
        if {$density != $firstDensity} {
            set uniform 0
            break
        }
    }
    if {$uniform && $firstDensity > 1} {
        set innerChains {}
        foreach chain $crossChains { lappend innerChains [lrange $chain 0 end-1] }
        set elementPlans [::MeshSeamWeld::directStructuredStripQuadNodeLists \
            $innerChains $closedLoop]
        set finalSourceNodes {}
        foreach chain $crossChains {
            lappend finalSourceNodes [lindex $chain [expr {$firstDensity - 1}]]
        }
        set elementPlans [concat $elementPlans \
            [::MeshSeamWeld::anchoredUnequalStripElementNodeLists \
                $finalSourceNodes $targetNodes $anchorIndices $closedLoop]]
    } else {
        # Mesh each longitudinal segment independently when its two
        # transverse chains have different layer counts.  The inner part is
        # zipped only when both sides have an inner chain; the final part is
        # always zipped to the real target path segment.  This preserves all
        # available adaptive layers without forcing a narrow start to use the
        # widest cross-section's density.
        set sourceCount [llength $sourceNodes]
        set segmentCount [expr {$closedLoop ? $sourceCount : $sourceCount - 1}]
        for {set index 0} {$index < $segmentCount} {incr index} {
            set nextIndex [expr {($index + 1) % $sourceCount}]
            set currentInner [lrange [lindex $crossChains $index] 0 end-1]
            set nextInner [lrange [lindex $crossChains $nextIndex] 0 end-1]
            if {[llength $currentInner] >= 2 && [llength $nextInner] >= 2} {
                set elementPlans [concat $elementPlans \
                    [::MeshSeamWeld::unequalStripElementNodeLists \
                        $currentInner $nextInner 0]]
            }

            set startTarget [lindex $anchorIndices $index]
            if {$closedLoop && $index == $segmentCount - 1} {
                set targetSegment [concat [lrange $targetNodes $startTarget end] \
                    [list [lindex $targetNodes 0]]]
            } else {
                set endTarget [lindex $anchorIndices $nextIndex]
                set targetSegment [lrange $targetNodes $startTarget $endTarget]
            }
            if {[llength $targetSegment] < 2} {
                error "Adaptive anchored target segment [expr {$index + 1}] contains fewer than two nodes."
            }
            set finalSourceSegment [list \
                [lindex [lindex $crossChains $index] end-1] \
                [lindex [lindex $crossChains $nextIndex] end-1]]
            set elementPlans [concat $elementPlans \
                [::MeshSeamWeld::unequalStripElementNodeLists \
                    $finalSourceSegment $targetSegment 0]]
            ::MeshSeamWeld::responsiveCheckpoint [expr {$index + 1}] 128
        }
    }

    set createdPlanCount 0
    foreach elementNodes $elementPlans {
        set createPlans [list $elementNodes]
        if {$cfg(mesh_elem_type) == 1 && [llength $elementNodes] == 4} {
            set createPlans [list \
                [lrange $elementNodes 0 2] \
                [list [lindex $elementNodes 0] [lindex $elementNodes 2] \
                    [lindex $elementNodes 3]]]
        }
        foreach createNodes $createPlans {
            set config [expr {[llength $createNodes] == 3 ? 103 : 104}]
            if {[catch {
                eval *createlist nodes 1 $createNodes
                *createelement $config 1 1 1
            } createErr]} {
                error "Failed to create anchored weld strip element: $createErr"
            }
            incr createdPlanCount
        }
        ::MeshSeamWeld::responsiveCheckpoint $createdPlanCount 64
    }
    set elemIds [::MeshSeamWeld::idsAddedToCollection $beforeOutputElems \
        [::MeshSeamWeld::componentElementIds $outputCompId]]
    if {[llength $elemIds] != $createdPlanCount} {
        error "Anchored weld strip created [llength $elemIds]/$createdPlanCount expected elements."
    }
    ::MeshSeamWeld::moveElemsToComponent $elemIds $outputCompName
    set layerSummary [join $crossLayerCounts ,]
    ::HybridCore::log INFO \
        "weld_mesh creation_mode=anchored_structured source_nodes=[llength $sourceNodes] target_nodes=[llength $targetNodes] cross_layers=$layerSummary intermediate_nodes=$intermediateNodeCount elements=[llength $elemIds] closed_loop=$closedLoop"
    return $elemIds
}

proc ::MeshSeamWeld::monotonicClosestNodePairs {sourceNodes targetNodes} {
    if {[llength $sourceNodes] == 0 || [llength $targetNodes] == 0} {
        return {}
    }

    # Walk the already aligned target path only in its forward direction.  A
    # coarse/partial target path can map several source nodes to the same target
    # node; keep only the geometrically closest source for that target.  This
    # leaves genuine holes as missing source indices instead of stretching the
    # correspondence across them.
    set targetIndex 0
    set targetCount [llength $targetNodes]
    set bestByTarget [dict create]
    for {set sourceIndex 0} {$sourceIndex < [llength $sourceNodes]} {incr sourceIndex} {
        set sourceNode [lindex $sourceNodes $sourceIndex]
        set sourcePoint [::MeshSeamWeld::nodeXYZ $sourceNode]
        set targetNode [lindex $targetNodes $targetIndex]
        set bestDistance [::MeshSeamWeld::dist2 $sourcePoint \
            [::MeshSeamWeld::nodeXYZ $targetNode]]
        while {$targetIndex + 1 < $targetCount} {
            set nextIndex [expr {$targetIndex + 1}]
            set nextNode [lindex $targetNodes $nextIndex]
            set nextDistance [::MeshSeamWeld::dist2 $sourcePoint \
                [::MeshSeamWeld::nodeXYZ $nextNode]]
            if {$nextDistance > $bestDistance} { break }
            set targetIndex $nextIndex
            set targetNode $nextNode
            set bestDistance $nextDistance
        }
        if {![dict exists $bestByTarget $targetIndex] ||
            $bestDistance < [lindex [dict get $bestByTarget $targetIndex] 0]} {
            dict set bestByTarget $targetIndex [list $bestDistance $sourceIndex \
                $sourceNode $targetNode]
        }
        ::MeshSeamWeld::responsiveCheckpoint [expr {$sourceIndex + 1}] 256
    }

    set pairs {}
    foreach currentTargetIndex [lsort -integer [dict keys $bestByTarget]] {
        lassign [dict get $bestByTarget $currentTargetIndex] \
            pairDistance sourceIndex sourceNode targetNode
        lappend pairs [list $sourceIndex $currentTargetIndex $sourceNode $targetNode]
    }
    return [lsort -integer -index 0 $pairs]
}

proc ::MeshSeamWeld::contiguousMatchedNodeRuns {pairs {targetEdges {}}} {
    set runs {}
    set runSources {}
    set runTargets {}
    set previousSourceIndex ""
    set previousTargetIndex ""
    set previousTargetNode ""

    foreach pair $pairs {
        lassign $pair sourceIndex targetIndex sourceNode targetNode
        set continues [expr {$previousSourceIndex ne "" &&
            $sourceIndex == $previousSourceIndex + 1 &&
            $targetIndex == $previousTargetIndex + 1}]
        if {$continues && [llength $targetEdges] > 0 &&
            ![dict exists $targetEdges \
                [::MeshSeamWeld::canonicalEdgeKey $previousTargetNode $targetNode]]} {
            set continues 0
        }
        if {!$continues} {
            if {[llength $runSources] >= 2} {
                lappend runs [list $runSources $runTargets]
            }
            set runSources [list $sourceNode]
            set runTargets [list $targetNode]
        } else {
            lappend runSources $sourceNode
            lappend runTargets $targetNode
        }
        set previousSourceIndex $sourceIndex
        set previousTargetIndex $targetIndex
        set previousTargetNode $targetNode
    }
    if {[llength $runSources] >= 2} {
        lappend runs [list $runSources $runTargets]
    }
    return $runs
}

proc ::MeshSeamWeld::anchoredTargetCorrespondence {sourceNodes targetNodes {closedLoop 0}} {
    set sourceCount [llength $sourceNodes]
    set targetCount [llength $targetNodes]
    if {$sourceCount < 2 || $targetCount < $sourceCount} { return {} }

    set rawIndices {}
    foreach sourceNode $sourceNodes {
        set sourcePoint [::MeshSeamWeld::nodeXYZ $sourceNode]
        set bestIndex -1
        set bestDistance ""
        for {set targetIndex 0} {$targetIndex < $targetCount} {incr targetIndex} {
            set distance [::MeshSeamWeld::dist2 $sourcePoint \
                [::MeshSeamWeld::nodeXYZ [lindex $targetNodes $targetIndex]]]
            if {$bestIndex < 0 || $distance < $bestDistance} {
                set bestIndex $targetIndex
                set bestDistance $distance
            }
        }
        lappend rawIndices $bestIndex
    }
    if {[llength [lsort -integer -unique $rawIndices]] != $sourceCount} {
        return {}
    }

    if {$closedLoop} {
        set firstIndex [lindex $rawIndices 0]
        set targetNodes [::MeshSeamWeld::rotateList $targetNodes $firstIndex]
        set anchorIndices {}
        foreach rawIndex $rawIndices {
            lappend anchorIndices [expr {(($rawIndex - $firstIndex) % $targetCount + $targetCount) % $targetCount}]
        }
    } else {
        set firstIndex [lindex $rawIndices 0]
        set lastIndex [lindex $rawIndices end]
        if {$lastIndex <= $firstIndex} { return {} }
        set targetNodes [lrange $targetNodes $firstIndex $lastIndex]
        set anchorIndices {}
        foreach rawIndex $rawIndices {
            lappend anchorIndices [expr {$rawIndex - $firstIndex}]
        }
        set targetCount [llength $targetNodes]
    }

    set previous -1
    foreach anchorIndex $anchorIndices {
        if {$anchorIndex <= $previous || $anchorIndex < 0 || $anchorIndex >= $targetCount} {
            return {}
        }
        set previous $anchorIndex
    }
    if {[lindex $anchorIndices 0] != 0 ||
        (!$closedLoop && [lindex $anchorIndices end] != $targetCount - 1)} {
        return {}
    }
    return [dict create target_nodes $targetNodes anchor_indices $anchorIndices]
}

proc ::MeshSeamWeld::anchoredUnequalStripElementNodeLists {sourceNodes targetNodes anchorIndices {closedLoop 0}} {
    set sourceCount [llength $sourceNodes]
    set targetCount [llength $targetNodes]
    if {[llength $anchorIndices] != $sourceCount} {
        error "Anchored strip correspondence does not match the source node count."
    }
    set segmentCount [expr {$closedLoop ? $sourceCount : $sourceCount - 1}]
    set elements {}
    for {set index 0} {$index < $segmentCount} {incr index} {
        set nextIndex [expr {($index + 1) % $sourceCount}]
        set startTarget [lindex $anchorIndices $index]
        if {$closedLoop && $index == $segmentCount - 1} {
            set targetSegment [concat [lrange $targetNodes $startTarget end] \
                [list [lindex $targetNodes 0]]]
        } else {
            set endTarget [lindex $anchorIndices $nextIndex]
            set targetSegment [lrange $targetNodes $startTarget $endTarget]
        }
        if {[llength $targetSegment] < 2} {
            error "Anchored target segment [expr {$index + 1}] contains fewer than two nodes."
        }
        set sourceSegment [list [lindex $sourceNodes $index] \
            [lindex $sourceNodes $nextIndex]]
        set elements [concat $elements \
            [::MeshSeamWeld::unequalStripElementNodeLists \
                $sourceSegment $targetSegment 0]]
    }
    return $elements
}

proc ::MeshSeamWeld::maximumPathCrossDistance {sourceNodes targetNodes {closedLoop 0}} {
    set sourceCount [llength $sourceNodes]
    set targetCount [llength $targetNodes]
    if {$sourceCount == 0 || $targetCount == 0} { return 0.0 }
    set sourceParameters [::MeshSeamWeld::normalizedPathParameters \
        $sourceNodes $closedLoop]
    set targetParameters [::MeshSeamWeld::normalizedPathParameters \
        $targetNodes $closedLoop]
    set targetIndices [::MeshSeamWeld::nearestPathIndicesForParameters \
        $sourceParameters $targetParameters]
    set maximum 0.0
    for {set sourceIndex 0} {$sourceIndex < $sourceCount} {incr sourceIndex} {
        if {$sourceCount == $targetCount} {
            set targetIndex $sourceIndex
        } else {
            set targetIndex [lindex $targetIndices $sourceIndex]
        }
        set distance [::MeshSeamWeld::distanceBetweenNodes \
            [lindex $sourceNodes $sourceIndex] [lindex $targetNodes $targetIndex]]
        if {$distance > $maximum} { set maximum $distance }
    }
    return $maximum
}

proc ::MeshSeamWeld::adaptiveCrossLayerCounts {sourceNodes targetNodes meshSize {closedLoop 0}} {
    set sourceCount [llength $sourceNodes]
    set targetCount [llength $targetNodes]
    if {$sourceCount == 0 || $targetCount == 0} {
        return {}
    }
    if {$sourceCount != $targetCount && $sourceCount < 2} {
        return [list [::MeshSeamWeld::meshDensityForLength 0.0 $meshSize 1]]
    }

    set sourceParameters [::MeshSeamWeld::normalizedPathParameters \
        $sourceNodes $closedLoop]
    set targetParameters [::MeshSeamWeld::normalizedPathParameters \
        $targetNodes $closedLoop]
    set targetIndices [::MeshSeamWeld::nearestPathIndicesForParameters \
        $sourceParameters $targetParameters]
    set counts {}
    for {set sourceIndex 0} {$sourceIndex < $sourceCount} {incr sourceIndex} {
        # Equal-count paths are already an explicit imprint correspondence:
        # source[i] must connect to target[i], even when the two paths have
        # different local edge lengths.  Only unequal paths use normalized
        # arc-length matching here.
        if {$sourceCount == $targetCount} {
            set targetIndex $sourceIndex
        } else {
            set targetIndex [lindex $targetIndices $sourceIndex]
        }
        set distance [::MeshSeamWeld::distanceBetweenNodes \
            [lindex $sourceNodes $sourceIndex] [lindex $targetNodes $targetIndex]]
        lappend counts [::MeshSeamWeld::meshDensityForLength \
            $distance $meshSize 1]
    }
    return $counts
}

proc ::MeshSeamWeld::createRuledMeshBetweenNodePaths {sourceNodes targetNodes outputCompName {closedLoop 0} {targetComps {}}} {
    variable cfg
    if {[llength $sourceNodes] < 2 || [llength $targetNodes] < 2} {
        error "Too few nodes for weld mesh creation."
    }
    # The first Ruled input must remain the same ordered node path supplied to
    # Mesh Edit.  Only orient/rotate the post-imprint target side so the two
    # paths start in the same geometric neighborhood.
    set targetNodes [::MeshSeamWeld::alignTargetPathNodes \
        $sourceNodes $targetNodes $closedLoop]
    # The executor performs this repair after imprint as well.  Repeat it at
    # the mesh boundary so direct callers cannot bypass the geometric/topology
    # validation and accidentally feed a locally slipped target list to ruled.
    if {[llength $targetComps] > 0} {
        catch {
            set refinedTargetNodes [::MeshSeamWeld::refineEqualTargetPathCorrespondence \
                $sourceNodes $targetNodes $targetComps $closedLoop]
            set targetNodes $refinedTargetNodes
        }
    }

    # When imprint returned one target node for every source node, preserve
    # that correspondence explicitly.  A single native ruled surface
    # re-parameterizes both boundaries by arc length; at a sharp corner it can
    # slide one side past the other and produce the fan-shaped/twisted cells
    # seen in production models.  The structured path keeps every cross-chain
    # anchored to its actual imprint mate, including the closed-loop seam.
    set anchored [::MeshSeamWeld::anchoredTargetCorrespondence \
        $sourceNodes $targetNodes $closedLoop]
    if {[dict size $anchored] > 0 && !$cfg(create_geometry_surf)} {
        set targetNodes [dict get $anchored target_nodes]
        set anchorIndices [dict get $anchored anchor_indices]
        if {[string trim $outputCompName] eq ""} {
            set outputCompName $cfg(output_component)
        }
        set outputCompId [::MeshSeamWeld::ensureOutputComponent $outputCompName 11]
        if {$outputCompId eq ""} {
            error "Could not resolve the weld output component ID for $outputCompName."
        }
        set beforeOutputElems [::MeshSeamWeld::componentElementIds $outputCompId]
        set anchorTargetNodes {}
        foreach anchorIndex $anchorIndices {
            lappend anchorTargetNodes [lindex $targetNodes $anchorIndex]
        }
        set crossLayerCounts [::MeshSeamWeld::adaptiveCrossLayerCounts \
            $sourceNodes $anchorTargetNodes $cfg(weld_mesh_size) $closedLoop]
        if {[llength $sourceNodes] == [llength $targetNodes] &&
            $cfg(mesh_elem_type) != 1} {
            return [::MeshSeamWeld::createDirectStructuredStrip \
                $sourceNodes $targetNodes $crossLayerCounts $outputCompName \
                $outputCompId $beforeOutputElems $closedLoop]
        }
        return [::MeshSeamWeld::createAnchoredStructuredStrip \
            $sourceNodes $targetNodes $anchorIndices $crossLayerCounts \
            $outputCompName $outputCompId $beforeOutputElems $closedLoop]
    }
    # If no safe anchor mapping exists, the native fallback uses
    # maximumPathCrossDistance as its conservative width estimator.
    return [::MeshSeamWeld::createNativeRuledMeshBetweenNodePaths \
        $sourceNodes $targetNodes $outputCompName $closedLoop]
}

proc ::MeshSeamWeld::createNativeRuledMeshBetweenNodePaths {sourceNodes targetNodes outputCompName {closedLoop 0}} {
    variable cfg

    if {[llength $sourceNodes] < 2 || [llength $targetNodes] < 2 ||
        ($closedLoop && ([llength $sourceNodes] < 3 || [llength $targetNodes] < 3))} {
        error "Too few nodes for native ruled weld creation."
    }

    if {[string trim $outputCompName] eq ""} {
        set outputCompName $cfg(output_component)
    }
    set outputCompId [::MeshSeamWeld::ensureOutputComponent $outputCompName 11]
    if {$outputCompId eq ""} {
        error "Could not resolve the weld output component ID for $outputCompName."
    }
    set beforeOutputElems [::MeshSeamWeld::componentElementIds $outputCompId]

    set sourceLength [::MeshSeamWeld::nodePathLength $sourceNodes $closedLoop]
    set targetLength [::MeshSeamWeld::nodePathLength $targetNodes $closedLoop]
    set pathLength [expr {max($sourceLength, $targetLength)}]
    set sourceMinimum [expr {$closedLoop ? [llength $sourceNodes] : [llength $sourceNodes] - 1}]
    set targetMinimum [expr {$closedLoop ? [llength $targetNodes] : [llength $targetNodes] - 1}]
    set pathMinimum [expr {max($sourceMinimum, $targetMinimum)}]
    set pathMinimum [expr {max($pathMinimum, $cfg(mesh_path_param))}]
    set pathDensity [::MeshSeamWeld::meshDensityForLength \
        $pathLength $cfg(weld_mesh_size) $pathMinimum]
    # Endpoints alone under-estimate the width on closed loops and on paths
    # whose separation grows near a corner.  Sample the complete aligned path
    # so the native fallback also keeps a sufficient number of cross layers.
    set maximumCrossLength [::MeshSeamWeld::maximumPathCrossDistance \
        $sourceNodes $targetNodes $closedLoop]
    set crossDensity [::MeshSeamWeld::meshDensityForLength \
        $maximumCrossLength $cfg(weld_mesh_size) 1]

    # HyperMesh 2019 records show that ruled node-list creation followed by
    # *automesh can terminate the session in mode 3 (Mesh without surface).
    # Mode 2 uses a temporary ruled surface, deletes it after meshing, and
    # therefore preserves the default requirement: no geometry surface remains.
    set surfaceMode [expr {$cfg(create_geometry_surf) ? 1 : 2}]
    set historyStarted 0
    set code [catch {
        # 1 = mesh and keep surface; 2 = mesh and delete surface.
        *surfacemode $surfaceMode
        if {![catch {*startnotehistorystate {Create ruled surface and mesh}}]} {
            set historyStarted 1
        }

        # Keep the ruled surface open.  HyperMesh ignores a repeated first
        # node in these lists, so relying on it for closure leaves exactly one
        # longitudinal cell missing.  The transverse end-node chains are read
        # from the accepted mesh and explicitly connected below.
        eval *createlist nodes 1 $sourceNodes
        eval *createlist nodes 2 $targetNodes
        *linearsurfacebetweennodes 1 2 1

        *set_meshfaceparams 0 $cfg(mesh_face_shape) $cfg(mesh_elem_type) 0 0 $cfg(mesh_smooth_method) $cfg(mesh_smooth_tol) $cfg(mesh_size_control) $cfg(mesh_skew_control)
        # Signature: edge_index, element density, algorithm type, then bias
        # and chordal controls.  Density is derived from physical edge length;
        # passing mesh size directly here used to force a single cross layer.
        *set_meshedgeparams 0 $pathDensity 1 0 0 0 0 0 0
        *set_meshedgeparams 1 $crossDensity 1 0 0 0 0 0 0
        *set_meshedgeparams 2 $pathDensity 1 0 0 0 0 0 0
        *set_meshedgeparams 3 $crossDensity 1 0 0 0 0 0 0
        *automesh 0 1 2
        *storemeshtodatabase 0
    } err]

    if {$code} {
        catch {*rejectmesh 0}
        catch {*ameshclearsurface}
        if {$historyStarted} {
            catch {*endnotehistorystate {Create ruled surface and mesh}}
        }
        error [::HWFlow::txt "创建 ruled 焊缝网格失败：$err" "Failed to create ruled weld mesh: $err"]
    }

    catch {*ameshclearsurface}
    set openStripElems [::MeshSeamWeld::idsAddedToCollection $beforeOutputElems \
        [::MeshSeamWeld::componentElementIds $outputCompId]]
    if {[llength $openStripElems] == 0} {
        if {$historyStarted} {
            catch {*endnotehistorystate {Create ruled surface and mesh}}
        }
        error "Automesh did not add elements to weld component $outputCompName."
    }
    if {$closedLoop} {
        set closureCode [catch {
            ::MeshSeamWeld::createClosedStripElements \
                $openStripElems $sourceNodes $targetNodes $crossDensity
        } closureErr]
        if {$closureCode} {
            if {$historyStarted} {
                catch {*endnotehistorystate {Create ruled surface and mesh}}
            }
            error $closureErr
        }
    }
    if {$historyStarted} {
        catch {*endnotehistorystate {Create ruled surface and mesh}}
    }
    set elemIds [::MeshSeamWeld::idsAddedToCollection $beforeOutputElems \
        [::MeshSeamWeld::componentElementIds $outputCompId]]
    ::MeshSeamWeld::moveElemsToComponent $elemIds $outputCompName
    ::HybridCore::log INFO \
        "weld_mesh creation_mode=native_ruled source_nodes=[llength $sourceNodes] target_nodes=[llength $targetNodes] cross_layers=$crossDensity elements=[llength $elemIds] closed_loop=$closedLoop"
    return $elemIds
}

proc ::MeshSeamWeld::pathCenter {nodeIds} {
    if {[llength $nodeIds] == 0} { return {0.0 0.0 0.0} }
    set x 0.0
    set y 0.0
    set z 0.0
    foreach nodeId $nodeIds {
        set xyz [::MeshSeamWeld::nodeXYZ $nodeId]
        set x [expr {$x + [lindex $xyz 0]}]
        set y [expr {$y + [lindex $xyz 1]}]
        set z [expr {$z + [lindex $xyz 2]}]
    }
    set count [llength $nodeIds]
    return [list [expr {$x/$count}] [expr {$y/$count}] [expr {$z/$count}]]
}

proc ::MeshSeamWeld::invalidateTargetCaches {targetComps beforeNode beforeElem {targetElemIds {}}} {
    variable elemNodesCache
    variable elemComponentCache
    variable nodeElemsCache
    variable nodeFreeEdgeNeighborsCache
    variable nodeXYZCache

    set affectedElems [::MeshSeamWeld::uniq $targetElemIds]
    if {[llength $affectedElems] == 0} {
        foreach compId $targetComps {
            set affectedElems [concat $affectedElems [::MeshSeamWeld::componentElementIds $compId]]
        }
        set affectedElems [::MeshSeamWeld::uniq $affectedElems]
    }
    set targetNodes {}
    foreach elemId $affectedElems {
        catch {unset elemNodesCache($elemId)}
        catch {unset elemComponentCache($elemId)}
        set targetNodes [concat $targetNodes [::MeshSeamWeld::elemNodes $elemId]]
    }
    foreach nodeId [::MeshSeamWeld::uniq $targetNodes] {
        catch {unset nodeElemsCache($nodeId)}
        catch {unset nodeFreeEdgeNeighborsCache($nodeId)}
        catch {unset nodeXYZCache($nodeId)}
    }

    # IDs created by a failed operation can be reused by the next imprint.
    # Remove only those newer entries instead of discarding stable source-loop
    # topology for the entire batch.
    if {$beforeElem ne ""} {
        foreach elemId [array names elemNodesCache] {
            if {[string is integer -strict $elemId] && $elemId > $beforeElem} {
                catch {unset elemNodesCache($elemId)}
                catch {unset elemComponentCache($elemId)}
            }
        }
    }
    if {$beforeNode ne ""} {
        foreach nodeId [array names nodeXYZCache] {
            if {[string is integer -strict $nodeId] && $nodeId > $beforeNode} {
                catch {unset nodeXYZCache($nodeId)}
                catch {unset nodeElemsCache($nodeId)}
                catch {unset nodeFreeEdgeNeighborsCache($nodeId)}
            }
        }
    }
}

proc ::MeshSeamWeld::processWeldPathIsolated {sourceNodes targetComps closedLoop progressOpened pathIndex pathTotal {sourceCompIds {}} {seamComp ""} {preparedCenter {}} {targetElemIds {}} {imprintClosedLoop ""}} {
    set isolatedStarted [clock milliseconds]
    set ::MeshSeamWeld::lastImprintAffectedElemIds {}
    set pathKindZh [expr {$closedLoop ? "闭合边界" : "开放节点路径"}]
    set pathKindEn [expr {$closedLoop ? "closed boundary" : "open node path"}]
    set historyName "Mesh seam weld $pathKindEn $pathIndex/$pathTotal"
    set failureCenter $preparedCenter
    if {[llength $failureCenter] != 3} {
        set failureCenter [::MeshSeamWeld::pathCenter $sourceNodes]
    }
    # Do not use hm_latestentityid as a model maximum.  After trimming,
    # deleting, importing, or undoing entities HyperMesh 2019 can return zero
    # or an ID below existing entities even though the model is valid.
    set beforeNode ""
    set beforeElem ""
    set historyStarted 0
    if {![catch {*startnotehistorystate $historyName}]} { set historyStarted 1 }
    if {!$historyStarted} {
        ::HybridCore::log ERROR "PERF mesh_seam_weld path=$pathIndex/$pathTotal status=skipped reason=no_undo_transaction total_ms=[expr {[clock milliseconds]-$isolatedStarted}]"
        return [dict create ok 0 \
            error "\[MSW_STAGE:TRANSACTION\] [::HWFlow::txt \
                "无法启动该${pathKindZh}的撤销事务；为避免留下部分投影，已跳过。" \
                "Could not start an undo transaction for this $pathKindEn; it was skipped to avoid leaving a partial imprint."]" \
            center $failureCenter rollback_ok 0]
    }
    set code [catch {
        ::MeshSeamWeld::processWeldPath $sourceNodes $targetComps \
            $closedLoop $progressOpened $pathIndex $pathTotal $sourceCompIds $seamComp $targetElemIds $imprintClosedLoop
    } result opts]
    if {$historyStarted} { catch {*endnotehistorystate $historyName} }
    if {$code} {
        set undoErr ""
        set rollbackOk 1
        if {$historyStarted && [catch {*undohistorystate 1} undoErr]} {
            set rollbackOk 0
            ::HybridCore::log ERROR "weld path rollback failed path=$pathIndex/$pathTotal error=$undoErr"
            append result [::HWFlow::txt \
                "；该${pathKindZh}回滚失败：$undoErr" \
                "; rollback of this $pathKindEn also failed: $undoErr"]
        }
        ::MeshSeamWeld::clearTransientSelections
        set failedAffectedElems [::MeshSeamWeld::uniq [concat \
            $targetElemIds $::MeshSeamWeld::lastImprintAffectedElemIds]]
        ::MeshSeamWeld::invalidateTargetCaches \
            $targetComps $beforeNode $beforeElem $failedAffectedElems
        set logError [string map [list "\r" "" "\n" " | "] $result]
        ::HybridCore::log ERROR "PERF mesh_seam_weld path=$pathIndex/$pathTotal status=failed total_ms=[expr {[clock milliseconds]-$isolatedStarted}] error=$logError"
        return [dict create ok 0 error $result center $failureCenter rollback_ok $rollbackOk]
    }
    return [dict create ok 1 result $result rollback_ok 1]
}

proc ::MeshSeamWeld::stageError {stage message} {
    set clean [string trim [string map [list "\r" " " "\n" " | "] $message]]
    return -code error -errorcode [list MESH_SEAM_WELD $stage] \
        "\[MSW_STAGE:$stage\] $clean"
}

proc ::MeshSeamWeld::diagnoseFailure {errorText} {
    set stage "UNKNOWN"
    regexp {\[MSW_STAGE:([A-Z_]+)\]} $errorText -> stage
    switch -- $stage {
        TARGET_PREPARE {
            set reasonZh "无法在当前目标网格上建立局部投影区域。"
            set reasonEn "The current target mesh could not provide a local projection patch."
            set actionZh "确认目标组件包含三角形或四边形壳单元，并且位于源边界附近。"
            set actionEn "Confirm that the target component contains triangular or quadrilateral shell elements near the source boundary."
        }
        SOURCE_PLAN {
            set reasonZh "HyperMesh 原生自由边组件创建或闭合边界排序失败。"
            set reasonEn "Native HyperMesh free-edge component creation or closed-boundary ordering failed."
            set actionZh "确认源组件包含具有闭合自由边的壳单元，所选自由边没有开放、分叉或非流形拓扑，并检查是否存在无法恢复的 ^edges 组件。"
            set actionEn "Confirm that the source component contains shell elements with closed free edges, that the selected boundary is not open, branched, or non-manifold, and that no unrecoverable ^edges component conflict exists."
        }
        IMPRINT {
            set reasonZh "HyperMesh 在目标网格上执行 imprint 失败。"
            set reasonEn "HyperMesh failed while imprinting the source path onto the target mesh."
            set actionZh "检查源边界是否完整落在目标面范围内，以及目标局部网格是否存在极小、退化或严重扭曲单元。"
            set actionEn "Check that the complete source boundary projects inside the target surface and that the local target mesh has no tiny, degenerate, or severely distorted elements."
        }
        TARGET_MATCH {
            set reasonZh "imprint 后未找到至少一个可形成壳单元的连续节点对应区段。"
            set reasonEn "No continuous node-correspondence section long enough to form shell elements was found after imprint."
            set actionZh "检查目标面附近是否至少有两个连续源节点能分别匹配到相邻目标节点；局部缺失区段会自动跳过。"
            set actionEn "Check that at least two consecutive source nodes can match adjacent target nodes. Locally missing sections are skipped automatically."
        }
        TARGET_CONTINUITY {
            set reasonZh "匹配出的目标节点不能沿目标壳网格形成连续闭合路径。"
            set reasonEn "The matched target nodes do not form a continuous closed path on the target shell mesh."
            set actionZh "检查目标面是否有裂缝、重复节点、组件断开或局部重网格失败。"
            set actionEn "Check the target surface for cracks, duplicate nodes, disconnected components, or a failed local remesh."
        }
        AUTOMESH {
            set reasonZh "目标路径已经建立，但结构化焊缝网格生成失败。"
            set reasonEn "The target path was established, but creation of the structured weld mesh failed."
            set actionZh "检查有效对应区段的首尾方向、两条路径间距以及焊缝网格尺寸。"
            set actionEn "Check the orientation and spacing of valid correspondence sections and the configured weld mesh size."
        }
        TRANSACTION {
            set reasonZh "无法启动或回滚该边界/路径的 HyperMesh 撤销事务。"
            set reasonEn "The HyperMesh undo transaction for this boundary/path could not be started or rolled back."
            set actionZh "保存模型后重新打开 HyperMesh 会话再试，并反馈诊断报告。"
            set actionEn "Save the model, retry in a fresh HyperMesh session, and provide the diagnostic report."
        }
        default {
            set reasonZh "焊缝创建在未分类阶段失败。"
            set reasonEn "Weld creation failed in an unclassified stage."
            set actionZh "请反馈失败报告和 operation.log，以便根据原始错误继续定位。"
            set actionEn "Provide the failure report and operation.log so the raw error can be investigated."
        }
    }
    return [dict create stage $stage reason_zh $reasonZh reason_en $reasonEn \
        action_zh $actionZh action_en $actionEn]
}

proc ::MeshSeamWeld::dictValueOr {record key defaultValue} {
    if {[dict exists $record $key]} { return [dict get $record $key] }
    return $defaultValue
}

proc ::MeshSeamWeld::reportLineValue {value} {
    return [string trim [string map [list "\r" "" "\n" " | "] $value]]
}

proc ::MeshSeamWeld::briefFailureDetail {value {limit 500}} {
    set detail [::MeshSeamWeld::reportLineValue $value]
    regsub {^\[MSW_STAGE:[A-Z_]+\][[:space:]]*} $detail "" detail
    if {[string length $detail] > $limit} {
        set detail "[string range $detail 0 [expr {$limit - 4}]]..."
    }
    return $detail
}

proc ::MeshSeamWeld::writeFailureReport {taskDir context failureRecords} {
    variable VERSION
    if {[llength $failureRecords] == 0 || [string trim $taskDir] eq ""} { return "" }
    file mkdir $taskDir
    set reportPath [file join $taskDir mesh_seam_weld_failure_report.txt]
    set channel [open $reportPath w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts -nonewline $channel "\ufeff"
    puts $channel "MESH_SEAM_WELD_FAILURE_REPORT"
    puts $channel "schema_version=1"
    puts $channel "module_version=$VERSION"
    set hmVersion "unknown"
    catch {set hmVersion [hm_info -appinfo VERSION]}
    puts $channel "hypermesh_version=[::MeshSeamWeld::reportLineValue $hmVersion]"
    puts $channel "created_at=[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
    foreach key {source_mode path_total success_count source_components target_components weld_mesh_size patch_expand_layers imprint_remesh_mode imprint_angle} {
        puts $channel "$key=[::MeshSeamWeld::reportLineValue [::MeshSeamWeld::dictValueOr $context $key {}]]"
    }
    puts $channel "failure_count=[llength $failureRecords]"
    set index 0
    foreach record $failureRecords {
        incr index
        set finalError [::MeshSeamWeld::dictValueOr $record final_error \
            [::MeshSeamWeld::dictValueOr $record error ""]]
        set diagnosis [::MeshSeamWeld::diagnoseFailure $finalError]
        set sourceNodes [::MeshSeamWeld::dictValueOr $record source_nodes {}]
        set targetElems [::MeshSeamWeld::dictValueOr $record target_elements {}]
        puts $channel ""
        puts $channel "[format {--- FAILURE %d ---} $index]"
        puts $channel "path_index=[::MeshSeamWeld::dictValueOr $record path_index 0]"
        puts $channel "stage=[dict get $diagnosis stage]"
        puts $channel "reason_zh=[dict get $diagnosis reason_zh]"
        puts $channel "action_zh=[dict get $diagnosis action_zh]"
        puts $channel "source_seed=[lindex $sourceNodes 0]"
        puts $channel "source_node_count=[llength $sourceNodes]"
        puts $channel "source_nodes=[join $sourceNodes ,]"
        puts $channel "center=[join [::MeshSeamWeld::dictValueOr $record center {}] ,]"
        puts $channel "target_components=[join [::MeshSeamWeld::dictValueOr $record target_components {}] ,]"
        puts $channel "target_element_count=[llength $targetElems]"
        puts $channel "shared_external_element_count=[::MeshSeamWeld::dictValueOr $record shared_external_element_count 0]"
        puts $channel "retry_count=[::MeshSeamWeld::dictValueOr $record retry_count 0]"
        puts $channel "rollback_ok=[::MeshSeamWeld::dictValueOr $record rollback_ok 0]"
        puts $channel "first_error=[::MeshSeamWeld::reportLineValue [::MeshSeamWeld::dictValueOr $record first_error $finalError]]"
        puts $channel "raw_error=[::MeshSeamWeld::reportLineValue $finalError]"
    }
    close $channel
    return $reportPath
}

proc ::MeshSeamWeld::createFailureMarkerNodes {failureRecords} {
    if {[llength $failureRecords] == 0} { return {} }
    set compName "MESH_SEAM_WELD_FAILED_MARKERS"
    if {[catch {set markerCompId [::MeshSeamWeld::ensureOutputComponent $compName 3]} markerCompErr]} {
        ::HybridCore::log ERROR "failure marker component creation failed error=$markerCompErr"
        return {}
    }
    set beforeMarkerNodes [::HWFlow::getCompEntityIds $markerCompId nodes nodes]
    catch {*currentcollector component $compName}
    catch {*currentcollector components $compName}
    foreach record $failureRecords {
        foreach {x y z} [dict get $record center] break
        if {[catch {*createnode $x $y $z 0 0 0} markerErr]} {
            ::HybridCore::log ERROR "failure marker creation failed path=[dict get $record path_index] error=$markerErr"
            continue
        }
    }
    set markerNodes [::MeshSeamWeld::idsAddedToCollection $beforeMarkerNodes \
        [::HWFlow::getCompEntityIds $markerCompId nodes nodes]]
    if {[llength $markerNodes] > 0} {
        catch {eval *createmark nodes 1 $markerNodes}
    }
    return $markerNodes
}

proc ::MeshSeamWeld::clearFailureMarkerComponent {} {
    set compName "MESH_SEAM_WELD_FAILED_MARKERS"
    foreach entityType {comps components} {
        catch {*clearmark $entityType 2}
        foreach selector {"by name only" "by name"} {
            if {![catch {*createmark $entityType 2 $selector $compName}]} {
                set ids {}
                catch {set ids [hm_getmark $entityType 2]}
                if {[llength $ids] > 0} {
                    catch {*deletemark $entityType 2}
                    catch {*clearmark $entityType 2}
                    return 1
                }
            }
        }
    }
    return 0
}

proc ::MeshSeamWeld::runAction {} {
    variable cfg
    ::MeshSeamWeld::loadState
    if {[info exists cfg(run_mode)] && $cfg(run_mode) eq "FAST_AUTO"} {
        ::MeshSeamWeld::runAutoWorkflow
        return
    }
    ::MeshSeamWeld::resetRunCaches
    ::MeshSeamWeld::clearTransientSelections

    set selectionPairs [::MeshSeamWeld::collectManualSelectionPairs]
    if {[llength $selectionPairs] == 0} {
        return
    }

    set selectedNodes {}
    set targetComps {}
    foreach selectionPair $selectionPairs {
        set selectedNodes [concat $selectedNodes \
            [dict get $selectionPair source_nodes]]
        set targetComps [concat $targetComps \
            [dict get $selectionPair target_components]]
    }
    set selectedNodes [::MeshSeamWeld::uniq $selectedNodes]
    set targetComps [::MeshSeamWeld::uniq $targetComps]
    set batchSelectedNodes $selectedNodes
    set batchTargetComps $targetComps

    set sourceSelectionMode "batched node/component pairs"
    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "网格焊缝命令流" "Mesh Seam Weld Command Stream"] \
            [::HWFlow::txt "正在准备边界/路径任务..." "Preparing boundary/path jobs..."] 0]
    }

    set failureReportPath ""
    set sourceComponentIds {}
    set batchTaskDir ""
    set batchLogPath ""
    set undoSnapshot ""
    set code [catch {
        set batchStarted [clock milliseconds]
        set batchWorkspace [::HybridCore::createTaskWorkspace mesh_seam_weld]
        set batchTaskDir [dict get $batchWorkspace task_dir]
        set batchLogPath [file join $batchTaskDir operation.log]
        set undoSnapshot [file join $batchTaskDir state before_manual_mesh_seam_weld.hm]
        ::MeshSeamWeld::saveUndoSnapshot $undoSnapshot
        ::MeshSeamWeld::clearUndoRecord
        ::MeshSeamWeld::clearFailureMarkerComponent
        set prepareStarted [clock milliseconds]
        set batchedSourcePaths {}
        set batchedWeldJobs {}
        set batchedSourceComponentIds {}
        set batchedSourceModes {}
        set selectionPairIndex 0
        foreach selectionPair $selectionPairs {
            incr selectionPairIndex
            set selectedNodes [dict get $selectionPair source_nodes]
            set targetComps [dict get $selectionPair target_components]
            set closedSeedMode [expr {[llength $selectedNodes] == 1 ||
                ![::MeshSeamWeld::selectedNodesFormContinuousPath $selectedNodes]}]
            set internalSingleNode 0
            set pairBoundaryMode 0
            set pathClosedLoop [expr {$closedSeedMode ? 1 : 0}]
            set sourceSelectionMode [expr {$closedSeedMode ?
                "closed free-edge seed nodes" : "open node path"}]
        # Resolve every component touched by the input node list up front.
        # A path may cross component ownership boundaries, and an internal
        # seed may be shared by several components; both cases are valid
        # source selections for the compatibility workflow.
        set sourceComponentIds [::MeshSeamWeld::componentIdsFromNodes $selectedNodes]
        if {[llength $sourceComponentIds] == 0} {
            error [::HWFlow::txt \
                "所选节点不属于包含壳网格的源 component。" \
                "Selected nodes do not belong to a source component containing shell mesh."]
        }
        if {$closedSeedMode} {
            if {[llength [::MeshSeamWeld::uniq [concat $sourceComponentIds $targetComps]]] <
                [expr {[llength [::MeshSeamWeld::uniq $sourceComponentIds]] + [llength [::MeshSeamWeld::uniq $targetComps]]}]} {
                error [::HWFlow::txt \
                    "源 component 与目标 component 不能重叠。" \
                    "Source and target component selections must not overlap."]
            }
            set boundaryTraceStarted [clock milliseconds]
            if {[catch {
                set nativeGraphs [::MeshSeamWeld::buildNativeFreeEdgeGraphs \
                    $sourceComponentIds]
                # Disconnected boundary picks are endpoint pairs, not a
                # request to weld the entire closed loop.  The pair branch
                # also validates the batch rule: exactly two endpoints per
                # free boundary and an even total endpoint count.  Single
                # seeds retain the established full-loop behavior.
                set pairBoundaryMode [expr {[llength $selectedNodes] >= 2}]
                set nativeSelection [::MeshSeamWeld::pathsFromNativeFreeEdgeGraphs \
                    $selectedNodes $nativeGraphs $pairBoundaryMode]
            } nativeEdgeErr]} {
                ::MeshSeamWeld::stageError SOURCE_PLAN $nativeEdgeErr
            }
            set sourcePaths [dict get $nativeSelection paths]
            set internalSingleNode [dict get $nativeSelection internal_single_node]
            set pairBoundaryMode [dict get $nativeSelection pair_boundary_mode]
            set pathClosedLoop [dict get $nativeSelection closed_loop]
            set boundaryTraceMs [expr {[clock milliseconds] - $boundaryTraceStarted}]
            set weldJobs [::MeshSeamWeld::prepareWeldJobs \
                $sourcePaths $targetComps $progressOpened]
            set normalizedJobs {}
            foreach job $weldJobs {
                if {$pathClosedLoop} {
                    dict set job closed_loop 1
                    dict set job imprint_closed_loop 1
                } else {
                    dict set job closed_loop 0
                    dict set job imprint_closed_loop 0
                }
                lappend normalizedJobs $job
            }
            set weldJobs $normalizedJobs
            if {$internalSingleNode} {
                set sourceSelectionMode \
                    "single internal node -> all native component free-edge loops"
            } elseif {$pairBoundaryMode} {
                set sourceSelectionMode \
                    "disconnected free-boundary endpoint pairs -> open boundary spans"
            } elseif {[llength $selectedNodes] == 1} {
                set sourceSelectionMode \
                    "single free-edge seed -> matching native free-edge loop"
            } else {
                set sourceSelectionMode \
                    "multiple free-edge seeds -> matching native free-edge loops"
            }
            ::HybridCore::log INFO \
                "PERF mesh_seam_weld planning_mode=hm_native_edges seeds=[llength $selectedNodes] source_components=[llength $sourceComponentIds] paths=[llength $sourcePaths] boundary_trace_ms=$boundaryTraceMs"
            if {[llength $weldJobs] == 0} {
                error [::HWFlow::txt "没有识别到有效闭合自由边。" "No valid closed free-edge loop was found."]
            }
        } else {
            set sourcePaths [list $selectedNodes]
            set weldJobs [::MeshSeamWeld::prepareWeldJobs $sourcePaths $targetComps $progressOpened]
        }
            set batchedSourcePaths [concat $batchedSourcePaths $sourcePaths]
            set batchedSourceComponentIds [concat \
                $batchedSourceComponentIds $sourceComponentIds]
            lappend batchedSourceModes $sourceSelectionMode
            foreach job $weldJobs {
                dict set job target_components $targetComps
                dict set job selection_pair_index $selectionPairIndex
                if {![dict exists $job closed_loop]} {
                    dict set job closed_loop $pathClosedLoop
                }
                if {![dict exists $job imprint_closed_loop]} {
                    dict set job imprint_closed_loop $pathClosedLoop
                }
                lappend batchedWeldJobs $job
            }
        }
        set selectedNodes $batchSelectedNodes
        set targetComps $batchTargetComps
        set sourcePaths $batchedSourcePaths
        set weldJobs $batchedWeldJobs
        set sourceComponentIds [::MeshSeamWeld::uniq $batchedSourceComponentIds]
        if {[llength $selectionPairs] == 1} {
            set sourceSelectionMode [lindex $batchedSourceModes 0]
        } else {
            set sourceSelectionMode "batched node/component pairs ([llength $selectionPairs] pairs)"
        }
        set prepareMs [expr {[clock milliseconds] - $prepareStarted}]
        ::HybridCore::log INFO "PERF mesh_seam_weld prepare paths=[llength $sourcePaths] source_nodes=[llength [::MeshSeamWeld::uniq [concat {*}$sourcePaths]]] prepare_ms=$prepareMs"
        set executionStarted [clock milliseconds]

        set allSourceNodes {}
        set allSourceCompIds {}
        set allSeamCompNames {}
        set allImprintNodes {}
        set allTargetNodes {}
        set allWeldElems {}
        set failureRecords {}
        set failureMarkerNodes {}
        set pathTotal [llength $sourcePaths]
        set pathIndex 0
        foreach job $weldJobs {
            incr pathIndex
            set sourceNodes [dict get $job source_nodes]
            set jobTargetComps $targetComps
            set jobClosedLoop $pathClosedLoop
            set jobImprintClosedLoop $jobClosedLoop
            if {[dict exists $job target_components]} {
                set jobTargetComps [dict get $job target_components]
            }
            if {[dict exists $job closed_loop]} {
                set jobClosedLoop [dict get $job closed_loop]
            }
            if {[dict exists $job imprint_closed_loop]} {
                set jobImprintClosedLoop [dict get $job imprint_closed_loop]
            }
            set preparationError [::MeshSeamWeld::dictValueOr $job preparation_error ""]
            set jobTargetElems {}
            if {$preparationError eq ""} {
                if {$progressOpened} {
                    set targetPreparePercent [expr {
                        10.0 + 80.0*($pathIndex - 1)/double(max(1,$pathTotal))}]
                    ::HybridCore::progressUpdate $targetPreparePercent \
                        "Mesh Seam Weld" \
                        "Preparing current target patch $pathIndex/$pathTotal..." 1
                }
                if {[catch {
                    set currentTarget [::MeshSeamWeld::prepareCurrentTargetPatch $sourceNodes \
                        $jobTargetComps $jobClosedLoop]
                    set jobTargetComps [dict get $currentTarget target_components]
                    set jobTargetElems [dict get $currentTarget target_elements]
                    dict set job target_components $jobTargetComps
                    dict set job target_elements $jobTargetElems
                } targetPrepareErr]} {
                    set preparationError $targetPrepareErr
                }
            }
            if {$preparationError ne ""} {
                set isolated [dict create ok 0 \
                    error "\[MSW_STAGE:TARGET_PREPARE\] $preparationError" \
                    center [dict get $job center] rollback_ok 1]
            } else {
                set isolated [::MeshSeamWeld::processWeldPathIsolated $sourceNodes $jobTargetComps \
                    $jobClosedLoop $progressOpened $pathIndex $pathTotal \
                    [dict get $job source_component_ids] [dict get $job seam_component] \
                    [dict get $job center] $jobTargetElems $jobImprintClosedLoop]
            }
            if {![dict get $isolated ok]} {
                set sharedExternalCount 0
                if {$preparationError eq ""} {
                    set sharedExternalCount $::MeshSeamWeld::lastImprintSharedNeighborElemCount
                }
                set failure [dict create path_index $pathIndex source_nodes $sourceNodes \
                    center [dict get $isolated center] target_components $jobTargetComps \
                    target_elements $jobTargetElems retry_count 0 \
                    shared_external_element_count $sharedExternalCount \
                    rollback_ok [::MeshSeamWeld::dictValueOr $isolated rollback_ok 0] \
                    first_error [dict get $isolated error] \
                    final_error [dict get $isolated error] error [dict get $isolated error]]
                lappend failureRecords $failure
                ::HybridCore::log ERROR "weld path skipped path=$pathIndex/$pathTotal source_seed=[lindex $sourceNodes 0] error=[dict get $isolated error]"
                continue
            }
            set result [dict get $isolated result]
            foreach {key value} $result {
                switch -- $key {
                    sourceNodes { set allSourceNodes [concat $allSourceNodes $value] }
                    sourceCompIds { set allSourceCompIds [concat $allSourceCompIds $value] }
                    seamCompName { lappend allSeamCompNames $value }
                    imprintNodes { set allImprintNodes [concat $allImprintNodes $value] }
                    targetNodes { set allTargetNodes [concat $allTargetNodes $value] }
                    weldElems { set allWeldElems [concat $allWeldElems $value] }
                }
            }
        }
        # Successful weld paths do not need diagnostic nodes.  Create all
        # marker nodes once, and only at the centers of paths that failed.
        if {[llength $failureRecords] > 0} {
            set failureMarkerNodes \
                [::MeshSeamWeld::createFailureMarkerNodes $failureRecords]
        }
        set executionMs [expr {[clock milliseconds] - $executionStarted}]
        set failureMarkerNodes [::MeshSeamWeld::uniq $failureMarkerNodes]
        set batchElapsedMs [expr {[clock milliseconds] - $batchStarted}]
        if {[llength $failureRecords] > 0} {
            set reportContext [dict create \
                source_mode $sourceSelectionMode \
                path_total $pathTotal \
                success_count [expr {$pathTotal - [llength $failureRecords]}] \
                source_components $sourceComponentIds \
                target_components $targetComps \
                weld_mesh_size $cfg(weld_mesh_size) \
                patch_expand_layers $cfg(patch_expand_layers) \
                imprint_remesh_mode $cfg(imprint_remesh_mode) \
                imprint_angle $cfg(imprint_angle)]
            if {[catch {
                set failureReportPath [::MeshSeamWeld::writeFailureReport \
                    $batchTaskDir $reportContext $failureRecords]
            } reportErr]} {
                set failureReportPath ""
                ::HybridCore::log ERROR "failure report creation failed error=[::MeshSeamWeld::reportLineValue $reportErr]"
            } else {
                ::HybridCore::log ERROR "failure_report=$failureReportPath"
            }
        }
        ::HybridCore::log INFO "PERF mesh_seam_weld batch paths=$pathTotal success=[expr {$pathTotal-[llength $failureRecords]}] failed=[llength $failureRecords] prepare_ms=$prepareMs execution_ms=$executionMs total_ms=$batchElapsedMs"
    } err]

    if {$code} {
        ::MeshSeamWeld::clearUndoRecord
        if {$batchTaskDir eq ""} {
            catch {
                set fatalWorkspace [::HybridCore::createTaskWorkspace mesh_seam_weld]
                set batchTaskDir [dict get $fatalWorkspace task_dir]
                set batchLogPath [file join $batchTaskDir operation.log]
            }
        }
        catch {::HybridCore::log ERROR "mesh_seam_weld batch failed error=$err"}
        set fatalDiagnosis [::MeshSeamWeld::diagnoseFailure $err]
        if {$batchTaskDir ne "" && $failureReportPath eq ""} {
            set fatalRecord [dict create path_index 0 source_nodes $selectedNodes \
                center {} target_components $targetComps target_elements {} retry_count 0 \
                shared_external_element_count 0 \
                rollback_ok 0 first_error $err final_error $err error $err]
            set fatalContext [dict create source_mode $sourceSelectionMode path_total 0 \
                success_count 0 source_components $sourceComponentIds \
                target_components $targetComps weld_mesh_size $cfg(weld_mesh_size) \
                patch_expand_layers $cfg(patch_expand_layers) \
                imprint_remesh_mode $cfg(imprint_remesh_mode) \
                imprint_angle $cfg(imprint_angle)]
            catch {set failureReportPath [::MeshSeamWeld::writeFailureReport \
                $batchTaskDir $fatalContext [list $fatalRecord]]}
        }
        catch {::HybridCore::closeLog}
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "网格焊缝命令流失败。" "Mesh seam weld command stream failed."] 100.0}
        }
        set fatalMessage [::HWFlow::txt \
            "网格焊缝任务失败。\n阶段：[dict get $fatalDiagnosis stage]\n原因：[dict get $fatalDiagnosis reason_zh]\n建议：[dict get $fatalDiagnosis action_zh]\n\n原始错误：$err" \
            "Mesh seam weld task failed.\nStage: [dict get $fatalDiagnosis stage]\nReason: [dict get $fatalDiagnosis reason_en]\nAction: [dict get $fatalDiagnosis action_en]\n\nRaw error: $err"]
        if {$failureReportPath ne ""} {
            append fatalMessage [::HWFlow::txt \
                "\n\n反馈文件：$failureReportPath\n运行日志：$batchLogPath" \
                "\n\nFeedback file: $failureReportPath\nOperation log: $batchLogPath"]
        }
        tk_messageBox -icon error -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message $fatalMessage
        return
    }

    set seamPropertyAssigned {}
    set seamPropertyFailures {}
    if {[catch {
        set seamPropertyResult [::MeshSeamWeld::assignCreatedSeamComponentProperties \
            $allSeamCompNames]
        set seamPropertyAssigned [dict get $seamPropertyResult assigned]
        set seamPropertyFailures [dict get $seamPropertyResult failures]
    } seamPropertyErr]} {
        lappend seamPropertyFailures [list "SEAM_*" $seamPropertyErr]
        catch {::HybridCore::log WARN \
            "mesh seam weld SEAM property assignment stage failed error=$seamPropertyErr"}
    }
    catch {::HWFlow::refreshBrowser}
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "网格焊缝命令流已完成。" "Mesh seam weld command stream finished."] 100.0}
    }
    set sourceCompIds [::MeshSeamWeld::uniq $allSourceCompIds]
    set seamCompNames [::MeshSeamWeld::uniq $allSeamCompNames]
    set failedCount [llength $failureRecords]
    set successCount [expr {[llength $sourcePaths] - $failedCount}]
    set undoRegistered 0
    if {$successCount > 0 && $undoSnapshot ne ""} {
        if {![catch {
            ::MeshSeamWeld::registerUndoSnapshot $undoSnapshot \
                [::HWFlow::txt \
                    "最近一次网格焊缝批次（成功路径 $successCount）" \
                    "the most recent mesh-seam batch ($successCount successful paths)"]
        } undoRegisterErr]} {
            set undoRegistered 1
        } else {
            ::HybridCore::log ERROR "mesh seam weld undo registration failed error=$undoRegisterErr"
        }
    }
    set plannedSourceNodes [::MeshSeamWeld::uniq [concat {*}$sourcePaths]]
    set msg [::HWFlow::txt \
        "网格焊缝完成。\n源选择模式：$sourceSelectionMode\n边界/路径数：[llength $sourcePaths]\n规划源节点：[llength $plannedSourceNodes]\n成功路径源节点：[llength $allSourceNodes]\n源组件：[llength $sourceCompIds]\n目标组件：[llength $targetComps]\n焊缝组件：[join $seamCompNames {, }]\n焊缝网格尺寸：$cfg(weld_mesh_size)\nimprint 目标路径节点：[llength $allImprintNodes]\n目标路径节点：[llength $allTargetNodes]\n新建焊缝单元：[llength $allWeldElems]" \
        "Mesh seam weld finished.\nSource selection mode: $sourceSelectionMode\nBoundaries/paths: [llength $sourcePaths]\nPlanned source nodes: [llength $plannedSourceNodes]\nSuccessful-path source nodes: [llength $allSourceNodes]\nSource components: [llength $sourceCompIds]\nTarget components: [llength $targetComps]\nWeld components: [join $seamCompNames {, }]\nWeld mesh size: $cfg(weld_mesh_size)\nImprint target path nodes: [llength $allImprintNodes]\nTarget path nodes: [llength $allTargetNodes]\nNew weld elements: [llength $allWeldElems]"]
    append msg [::HWFlow::txt \
        "\n成功路径：$successCount\n跳过路径：$failedCount\n失败标记节点：[llength $failureMarkerNodes]\n边界/路径规划及局部目标准备耗时：[format %.3f [expr {$prepareMs/1000.0}]] 秒\nTcl/HyperMesh 执行耗时：[format %.3f [expr {$executionMs/1000.0}]] 秒\n总耗时：[format %.3f [expr {$batchElapsedMs/1000.0}]] 秒" \
        "\nSuccessful paths: $successCount\nSkipped paths: $failedCount\nFailure marker nodes: [llength $failureMarkerNodes]\nBoundary/path planning and local-target preparation: [format %.3f [expr {$prepareMs/1000.0}]] s\nTcl/HyperMesh execution: [format %.3f [expr {$executionMs/1000.0}]] s\nElapsed: [format %.3f [expr {$batchElapsedMs/1000.0}]] s"]
    if {[llength $seamPropertyAssigned] > 0} {
        set assignedText {}
        foreach row $seamPropertyAssigned {
            lappend assignedText "[lindex $row 0] -> [lindex $row 1]"
        }
        append msg [::HWFlow::txt \
            "\n自动赋予焊缝 Property：[join $assignedText {, }]" \
            "\nAutomatically assigned weld properties: [join $assignedText {, }]"]
    }
    if {[llength $seamPropertyFailures] > 0} {
        set propertyFailureText {}
        foreach row $seamPropertyFailures {
            lappend propertyFailureText "[lindex $row 0]: [lindex $row 1]"
        }
        append msg [::HWFlow::txt \
            "\n焊缝 Property 自动赋予失败（默认 Steel 材料创建或 Property 赋予失败，可手动执行批量 Property）：[join $propertyFailureText {； }]" \
            "\nAutomatic weld-property assignment failed (default Steel creation or Property assignment failed; Batch Property Assignment can be run manually): [join $propertyFailureText {; }]"]
    }
    if {$failedCount > 0} {
        set firstFailure [lindex $failureRecords 0]
        set firstDiagnosis [::MeshSeamWeld::diagnoseFailure [dict get $firstFailure final_error]]
        set firstFailureDetail [::MeshSeamWeld::briefFailureDetail \
            [dict get $firstFailure final_error]]
        append msg [::HWFlow::txt \
            "\n\n首个失败边界/路径：[dict get $firstFailure path_index]；阶段：[dict get $firstDiagnosis stage]\n原因：[dict get $firstDiagnosis reason_zh]\n技术详情：$firstFailureDetail\n建议：[dict get $firstDiagnosis action_zh]\n未成功位置已在 MESH_SEAM_WELD_FAILED_MARKERS 中标记。\n\n请将以下两个纯文本文件反馈给开发人员：\n失败报告：$failureReportPath\n运行日志：$batchLogPath" \
            "\n\nFirst failed boundary/path: [dict get $firstFailure path_index]; stage: [dict get $firstDiagnosis stage]\nReason: [dict get $firstDiagnosis reason_en]\nTechnical detail: $firstFailureDetail\nAction: [dict get $firstDiagnosis action_en]\nFailed locations are marked in MESH_SEAM_WELD_FAILED_MARKERS.\n\nProvide these two plain-text files to the developer:\nFailure report: $failureReportPath\nOperation log: $batchLogPath"]
        append msg [::HWFlow::txt \
            "\n失败边界/路径均已直接跳过；未执行扩大补丁重试或整 component imprint。" \
            "\nFailed boundaries/paths were skipped immediately; no expanded-patch retry or whole-component imprint was attempted."]
    }
    set completionIcon [expr {$failedCount > 0 ? "warning" : "info"}]
    append msg [::HWFlow::txt \
        "\n性能日志：$batchLogPath" \
        "\nPerformance log: $batchLogPath"]
    if {$undoRegistered} {
        append msg [::HWFlow::txt \
            "\n可撤回：可在工具箱的“网格焊缝”行点击“撤回”，恢复本次批次开始前的模型状态。" \
            "\nUndo available: click “Undo” on the Mesh Seam Weld row in the toolkit to restore the state before this batch."]
    }
    catch {::HybridCore::closeLog}
    tk_messageBox -icon $completionIcon -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message $msg
}

# Retire the former component-wide index/retry helpers from the runtime command
# surface.  Their definitions are kept temporarily for source compatibility
# while no production or extension call can invoke them.
foreach retiredCommand {
    ::MeshSeamWeld::legacyComponentImprintNodeList
    ::MeshSeamWeld::legacyComponentTargetCandidatesAfterImprint
    ::MeshSeamWeld::legacyIndexedPrepareWeldJobs
    ::MeshSeamWeld::buildTargetElementIndex
    ::MeshSeamWeld::nearestIndexedTargetElem
    ::MeshSeamWeld::localTargetPatchForPath
    ::MeshSeamWeld::componentNodeIds
    ::MeshSeamWeld::markElementsByComponents
} {
    if {[llength [info commands $retiredCommand]] > 0} {
        rename $retiredCommand {}
    }
}

proc ::MeshSeamWeld::run {} {
    ::MeshSeamWeld::runAction
}

# The legacy path remains Tcl-native. FAST_AUTO loads the Python/FEM bridge as
# a separate, explicitly selected workflow and never calls imprint or ruled.
foreach hybridFile {executor.tcl workflow.tcl auto_ui.tcl delta_import.tcl quality_validator.tcl fast_executor.tcl auto_workflow.tcl integrity_link.tcl} {
    ::HWFlow::sourceUtf8 [file join $::MeshSeamWeld::MODULE_DIR tcl $hybridFile]
}
