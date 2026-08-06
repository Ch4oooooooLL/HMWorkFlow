if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] workflow_common.tcl]
}
if {![namespace exists ::HybridCore]} {
    ::HWFlow::sourceUtf8 [file join [file dirname [file normalize [info script]]] hybrid_core tcl init.tcl]
}

namespace eval ::FemAutoSeam {
    variable VERSION "0.17"
    variable MODULE_DIR [file join [file dirname [file normalize [info script]]] fem_auto_seam]
    variable cfg
    array set cfg {
        search_distance 12.0
        min_seam_length 20.0
        parallel_angle_max 15.0
        perpendicular_angle_min 70.0
        max_distance_variation_ratio 0.35
        near_edge_distance 8.0
        small_hole_diameter 30.0
        max_weld_tria_ratio 0.75
        existing_weld_search_distance 4.0
        exclude_existing_welds 1
        auto_accept_confidence 0.88
        review_confidence 0.60
        criteria_path ""
        remesh_element_size 8.0
        remesh_expand_layers 2
        remesh_feature_angle 30.0
        remesh_chunk_elements 1000
        python_workers 0
        max_new_failed_elements 0
    }
    variable ui
    array set ui {}
    variable lastUndoSnapshot ""
    variable lastUndoSummary ""
}

proc ::FemAutoSeam::stateKeys {} {
    return {
        search_distance min_seam_length parallel_angle_max perpendicular_angle_min
        max_distance_variation_ratio near_edge_distance small_hole_diameter
        max_weld_tria_ratio existing_weld_search_distance exclude_existing_welds
        auto_accept_confidence review_confidence criteria_path
        remesh_element_size remesh_expand_layers remesh_feature_angle remesh_chunk_elements python_workers max_new_failed_elements
    }
}

proc ::FemAutoSeam::loadState {} {
    if {[llength [info commands ::HWFlow::applyStateToArray]]} {
        ::HWFlow::applyStateToArray fem_auto_seam ::FemAutoSeam::cfg [::FemAutoSeam::stateKeys]
    }
}

proc ::FemAutoSeam::saveState {} {
    if {[llength [info commands ::HWFlow::saveArrayState]]} {
        ::HWFlow::saveArrayState fem_auto_seam ::FemAutoSeam::cfg
    }
}

proc ::FemAutoSeam::centerWindow {w} {
    update idletasks
    wm geometry $w +[expr {([winfo screenwidth $w]-[winfo reqwidth $w])/2}]+[expr {([winfo screenheight $w]-[winfo reqheight $w])/2}]
}

proc ::FemAutoSeam::browseFile {key extension zh en} {
    variable ui
    set initial [pwd]
    if {[string trim $ui($key)] ne ""} {
        set candidate [file dirname [file normalize $ui($key)]]
        if {[file isdirectory $candidate]} { set initial $candidate }
    }
    set path [tk_getOpenFile -parent .fem_auto_seam -title [::HWFlow::txt $zh $en] -initialdir $initial \
        -filetypes [list [list "HyperMesh $extension" [list $extension]] [list "All files" "*"]]]
    if {$path ne ""} { set ui($key) [file normalize $path] }
}

proc ::FemAutoSeam::validateUi {} {
    variable ui
    foreach key {search_distance min_seam_length parallel_angle_max perpendicular_angle_min max_distance_variation_ratio near_edge_distance small_hole_diameter max_weld_tria_ratio existing_weld_search_distance auto_accept_confidence review_confidence} {
        if {![string is double -strict $ui($key)] || $ui($key) < 0} { error "$key must be non-negative" }
    }
    foreach key {remesh_expand_layers max_new_failed_elements python_workers} {
        if {![string is integer -strict $ui($key)] || $ui($key) < 0} { error "$key must be a non-negative integer" }
    }
    if {![string is integer -strict $ui(remesh_chunk_elements)] || $ui(remesh_chunk_elements) <= 0} {
        error "remesh_chunk_elements must be a positive integer"
    }
    foreach key {remesh_element_size remesh_feature_angle} {
        if {![string is double -strict $ui($key)] || $ui($key) <= 0} { error "$key must be positive" }
    }
    foreach item [list [list criteria_path .criteria]] {
        set key [lindex $item 0]; set extension [lindex $item 1]
        if {[string trim $ui($key)] eq ""} { continue }
        if {![file isfile $ui($key)] || [string tolower [file extension $ui($key)]] ne $extension} {
            error "$key must reference a valid $extension file"
        }
        set ui($key) [file normalize $ui($key)]
    }
}

proc ::FemAutoSeam::effectiveSpecificationPath {key} {
    variable cfg; variable MODULE_DIR
    if {[string trim $cfg($key)] ne ""} { return [file normalize $cfg($key)] }
    switch -- $key {
        criteria_path { set name fem_auto_seam_default.criteria }
        default { error "unsupported FEM automatic seam specification: $key" }
    }
    set path [file join $MODULE_DIR defaults $name]
    if {![file isfile $path] || [file size $path] == 0} { error "built-in specification is missing: $path" }
    return [file normalize $path]
}

proc ::FemAutoSeam::acceptPanel {runNow} {
    variable cfg; variable ui
    if {[catch {::FemAutoSeam::validateUi} err]} {
        tk_messageBox -icon warning -title [::HWFlow::txt "FEM 自动焊缝" "FEM Automatic Seam"] -message $err
        return
    }
    foreach key [::FemAutoSeam::stateKeys] { set cfg($key) $ui($key) }
    ::FemAutoSeam::saveState
    set ui(ok) [expr {$runNow ? 1 : 2}]
    destroy .fem_auto_seam
}

proc ::FemAutoSeam::showPanel {{settingsOnly 0}} {
    variable cfg; variable ui; variable VERSION
    ::FemAutoSeam::loadState
    foreach key [::FemAutoSeam::stateKeys] { set ui($key) $cfg($key) }
    set ui(ok) 0
    set w .fem_auto_seam; catch {destroy $w}; ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle "[::HWFlow::txt "FEM 自动焊缝" "FEM Automatic Seam"] v$VERSION" "FEM Automatic Seam v$VERSION"]
    wm resizable $w 0 0
    frame $w.main -padx 12 -pady 10; pack $w.main -fill both -expand 1
    label $w.main.title -text [::HWFlow::txt "FEM 自动焊缝" "FEM Automatic Seam"] -font [::HWFlow::uiFont heading]
    message $w.main.note -width 620 -text [::HWFlow::txt \
        "独立分析孤立划分后的壳网格，识别 T 型、贴片型和邻近自由边，在 FEM 层面切分母单元并创建焊缝壳。此功能与原“网格焊缝”配置相互独立。" \
        "Analyze independently meshed shell components, detect T/patch/near-edge candidates, split mother shells at FEM level, and create weld shells. This tool has configuration independent from Mesh Seam Weld."]
    grid $w.main.title -row 0 -column 0 -columnspan 3 -sticky w
    grid $w.main.note -row 1 -column 0 -columnspan 3 -sticky ew -pady {4 8}
    set fields {
        {search_distance "搜索距离" "Search distance"}
        {min_seam_length "最小焊缝长度" "Minimum seam length"}
        {parallel_angle_max "贴片平行角度" "Patch parallel angle"}
        {perpendicular_angle_min "T 型角度下限" "T angle lower limit"}
        {near_edge_distance "邻近自由边距离" "Near free-edge distance"}
        {small_hole_diameter "人工复核孔径阈值" "Review hole diameter"}
        {auto_accept_confidence "自动创建置信度" "Auto-create confidence"}
        {review_confidence "复核置信度" "Review confidence"}
        {criteria_path "Criteria 文件" "Criteria file"}
        {python_workers "Python 并行进程数（0=自动）" "Python workers (0=auto)"}
        {remesh_element_size "重绘单元尺寸" "Remesh element size"}
        {remesh_expand_layers "重绘扩展层数" "Remesh expansion layers"}
        {remesh_feature_angle "重绘特征角" "Remesh feature angle"}
        {remesh_chunk_elements "单批重绘单元上限" "Elements per remesh chunk"}
        {max_new_failed_elements "允许新增失败单元" "Allowed new failed elements"}
    }
    set row 2
    foreach item $fields {
        set key [lindex $item 0]
        label $w.main.l_$key -text [::HWFlow::txt [lindex $item 1] [lindex $item 2]] -anchor w
        entry $w.main.e_$key -textvariable ::FemAutoSeam::ui($key) -width [expr {$key eq "criteria_path" ? 48 : 18}]
        grid $w.main.l_$key -row $row -column 0 -sticky w -padx {0 8} -pady 2
        grid $w.main.e_$key -row $row -column 1 -sticky w -pady 2
        if {$key eq "criteria_path"} {
            set extension ".criteria"
            button $w.main.b_$key -text [::HWFlow::txt "浏览" "Browse"] -command [list ::FemAutoSeam::browseFile $key $extension "选择 $extension 文件" "Select $extension file"]
            grid $w.main.b_$key -row $row -column 2 -padx {6 0}
        }
        incr row
    }
    checkbutton $w.main.exclude -text [::HWFlow::txt "排除附近已有 SEAM 焊缝" "Exclude nearby existing SEAM welds"] -variable ::FemAutoSeam::ui(exclude_existing_welds)
    grid $w.main.exclude -row $row -column 0 -columnspan 3 -sticky w; incr row
    label $w.main.required -text [::HWFlow::txt "固定流程：Python 仅规划切分与连接；HyperMesh 按连通区域分批重绘受影响网格。" "Fixed workflow: Python plans topology only; HyperMesh remeshes affected regions in bounded chunks."] -anchor w
    grid $w.main.required -row $row -column 0 -columnspan 3 -sticky w
    frame $w.buttons -padx 12 -pady 10; pack $w.buttons -fill x
    button $w.buttons.cancel -text [::HWFlow::txt "取消" "Cancel"] -command [list destroy $w]
    button $w.buttons.save -text [::HWFlow::txt "保存配置" "Save Configuration"] -command [list ::FemAutoSeam::acceptPanel 0]
    pack $w.buttons.cancel $w.buttons.save -side right -padx {6 0}
    if {!$settingsOnly} {
        button $w.buttons.run -text [::HWFlow::txt "保存并开始" "Save and Start"] -command [list ::FemAutoSeam::acceptPanel 1]
        pack $w.buttons.run -side right -padx {6 0}
    }
    bind $w <Escape> [list destroy $w]; wm protocol $w WM_DELETE_WINDOW [list destroy $w]
    ::FemAutoSeam::centerWindow $w; tkwait window $w
    return [expr {$ui(ok) == 1}]
}

proc ::FemAutoSeam::componentElementIds {componentId} {
    catch {*clearmark elems 1}; eval *createmark elems 1 "by component id" $componentId
    set ids [hm_getmark elems 1]; catch {*clearmark elems 1}; return [lsort -integer -unique $ids]
}
proc ::FemAutoSeam::elemNodes {elementId} { return [hm_getvalue elems id=$elementId dataname=nodes] }
proc ::FemAutoSeam::componentExportName {componentId} {
    set name ""; catch {set name [hm_getvalue comps id=$componentId dataname=name]}
    return [expr {[string trim $name] eq "" ? "COMP_$componentId" : $name}]
}
proc ::FemAutoSeam::pickComponents {} {
    catch {*clearmark comps 1}
    if {[catch {*createmarkpanel comps 1 [::HWFlow::txt "选择至少两个孤立壳网格 Component" "Select at least two independently meshed shell components"]}]} { return {} }
    set ids [hm_getmark comps 1]; catch {*clearmark comps 1}; return [lsort -integer -unique $ids]
}

proc ::FemAutoSeam::registerUndoSnapshot {path summary} {
    variable lastUndoSnapshot; variable lastUndoSummary
    set lastUndoSnapshot $path; set lastUndoSummary $summary
}
proc ::FemAutoSeam::undoAvailable {} { variable lastUndoSnapshot; return [expr {$lastUndoSnapshot ne "" && [file isfile $lastUndoSnapshot]}] }
proc ::FemAutoSeam::undoLast {} {
    variable lastUndoSnapshot; variable lastUndoSummary
    if {![::FemAutoSeam::undoAvailable]} { tk_messageBox -icon info -message [::HWFlow::txt "没有可撤回的 FEM 自动焊缝批次。" "There is no FEM automatic seam batch to undo."]; return 0 }
    if {[tk_messageBox -type yesno -icon question -message [::HWFlow::txt "撤回$lastUndoSummary？" "Undo $lastUndoSummary?"]] ne "yes"} { return 0 }
    catch {hm_answernext yes}; *readfile [file nativename $lastUndoSnapshot] 0
    set lastUndoSnapshot ""; set lastUndoSummary ""; catch {::HWFlow::refreshBrowser}; return 1
}

proc ::FemAutoSeam::runAction {} { if {[::FemAutoSeam::showPanel 0]} { ::FemAutoSeam::runWorkflow } }
proc ::FemAutoSeam::runSettings {} { ::FemAutoSeam::showPanel 1 }
proc ::FemAutoSeam::run {} { ::FemAutoSeam::runAction }

foreach file {exporter.tcl auto_ui.tcl delta_import.tcl quality_validator.tcl fast_executor.tcl workflow.tcl} {
    ::HWFlow::sourceUtf8 [file join $::FemAutoSeam::MODULE_DIR tcl $file]
}
