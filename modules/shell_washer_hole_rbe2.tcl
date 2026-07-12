# ============================================================================
# shell_washer_hole_rbe2_release_v1_3_oval.tcl
# Version : Release 1.3 Oval
# Purpose : For shell components with standard washer mesh around bolt holes,
#           identify circular/oval inner free-edge hole loops, verify the first
#           washer ring, tie the inner free-edge loop + first outer washer
#           node loop, create a center node, and create an RBE2/rigidlink.
# Target  : HyperMesh 2019 Tcl style
# Usage   : File > Run > Tcl/Tk Script, then select one or more shell components.
#
# Main behavior:
#   1) Only holes with diameter 6~30 in model units are processed.
#   2) Holes without a valid washer ring are skipped.
#   3) For each selected source component, output RBE2 elements are organized
#      into AUTO_RBE2_<source component name>[_NN].
#   4) Large-model performance optimization: node coordinate cache, reduced UI
#      redraw/logging, component-level batch organization of RBE2 elements.
#   5) The lower-left status area shows throttled overall progress.
#   6) Safety logic: before processing a selected component, if an existing
#      RBE2/rigidlink is found in the source component or in an existing
#      AUTO_RBE2_<source component name> output component, that source component
#      is skipped and reported to the user.
#   7) The script does not call *movemark on nodes; only created RBE2 elements
#      are explicitly moved to the output component.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::RB2W {
    variable VERSION "Release-1.3-Oval"

    # ---------------- Hole / washer parameters ----------------
    variable MIN_HOLE_DIAMETER           6.0
    variable MAX_HOLE_DIAMETER           30.0
    variable CIRCULARITY_TOL             0.08
    variable ALLOW_OVAL_HOLES            1
    variable MAX_OVAL_AXIS_RATIO         3.50
    variable OVAL_RADIAL_FIT_TOL         0.45
    variable MIN_HOLE_EDGE_NODES         8
    variable MAX_HOLE_EDGE_NODES         200
    variable INNER_WASHER_NODE_LOOPS     2
    variable OUTER_RING_CIRCULARITY_TOL  0.20
    variable OUTER_OVAL_RADIAL_FIT_TOL   0.55
    variable OUTER_OVAL_AXIS_RATIO_TOL   0.45
    variable CENTER_OFFSET_TOL           0.20
    variable MIN_WASHER_WIDTH_ABS        0.30
    variable MIN_WASHER_WIDTH_RATIO      0.05
    variable WASHER_ELEM_COUNT_TOL       0.50
    variable MIN_OUTER_NODE_RATIO        0.50
    variable MAX_OUTER_NODE_RATIO        2.50

    # ---------------- RBE2 / output parameters ----------------
    variable RIGID_TYPE                  RBE2
    variable RBE2_DOF                    123456
    variable RBE2_COMPONENT_PREFIX       "AUTO_RBE2"
    variable BATCH_ORGANIZE_RBE2         1
    variable ORGANIZE_BATCH_SIZE         500
    variable SHOW_OUTPUT_COMPONENTS      1
    variable FORCE_BROWSER_REFRESH       1

    # Object-level duplicate checks are always applied; this coarse component
    # gate remains available for conservative legacy workflows.
    variable SKIP_COMPONENT_IF_EXISTING_RBE2            0
    variable CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2   1
    variable CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2   1
    variable OUTPUT_COMPONENT_SUFFIX_SCAN_LIMIT         999

    # ---------------- Logging / progress / performance ----------------
    variable VERBOSE                     1
    variable LOG_EACH_CREATED            0
    variable LOG_EACH_SKIPPED            0
    variable PERFORMANCE_MODE            1
    variable USE_NODE_XYZ_CACHE          1
    variable USE_STATUS_PROGRESS         1
    variable PROGRESS_LOOP_STEP          50
    variable UI_UPDATE_STEP              100
    variable FORCE_STATUS_UPDATE         1
    variable STATUS_PERCENT_STEP         1.0
    variable STATUS_MIN_INTERVAL_MS      500
    variable FAST_RBE2_MARK_FILTER       1
    variable statusLastPercent           -100.0
    variable statusLastTime              0

    # ---------------- Internal arrays / state ----------------
    variable elemNodes
    variable edgeElems
    variable elemNbrs
    variable outputCompBySource
    variable existingRBE2ByDepNodes
    variable nodeXYZCache
    variable rbe2MarkCacheValid          0
    variable rbe2MarkCacheAvailable      0
    variable rbe2MarkCacheIds            {}
    variable rbe2MarkCacheSelector       ""
    variable rbe2MarkCacheGrouped        0
    variable rbe2MarkCacheCanGroup       0
    variable rbe2CandidateCompId
    variable rbe2CandidateByComp
    variable currentComponentName ""
    variable ui
    array set ui {}
}

proc ::RB2W::log {msg} {
    variable VERBOSE
    if {$VERBOSE} {
        set line "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] RB2W: $msg"
        puts $line
        if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
            catch {::HWFlow::progressAppend "RB2W: $msg"}
        }
    }
}

proc ::RB2W::status {msg {force 0}} {
    variable USE_STATUS_PROGRESS
    variable FORCE_STATUS_UPDATE
    variable PERFORMANCE_MODE
    if {!$USE_STATUS_PROGRESS} { return }
    catch {hm_usermessage $msg}
    if {$force || ($FORCE_STATUS_UPDATE && !$PERFORMANCE_MODE)} { catch {update idletasks} }
}

proc ::RB2W::resetOverallProgress {} {
    variable statusLastPercent
    variable statusLastTime
    set statusLastPercent -100.0
    set statusLastTime 0
}

proc ::RB2W::stateKeys {} {
    return {
        MIN_HOLE_DIAMETER MAX_HOLE_DIAMETER CIRCULARITY_TOL
        ALLOW_OVAL_HOLES MAX_OVAL_AXIS_RATIO OVAL_RADIAL_FIT_TOL
        MIN_HOLE_EDGE_NODES MAX_HOLE_EDGE_NODES INNER_WASHER_NODE_LOOPS
        OUTER_RING_CIRCULARITY_TOL OUTER_OVAL_RADIAL_FIT_TOL
        OUTER_OVAL_AXIS_RATIO_TOL CENTER_OFFSET_TOL
        MIN_WASHER_WIDTH_ABS MIN_WASHER_WIDTH_RATIO WASHER_ELEM_COUNT_TOL
        MIN_OUTER_NODE_RATIO MAX_OUTER_NODE_RATIO
        RIGID_TYPE RBE2_DOF RBE2_COMPONENT_PREFIX BATCH_ORGANIZE_RBE2 ORGANIZE_BATCH_SIZE
        SHOW_OUTPUT_COMPONENTS FORCE_BROWSER_REFRESH
        SKIP_COMPONENT_IF_EXISTING_RBE2 CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2
        CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2 OUTPUT_COMPONENT_SUFFIX_SCAN_LIMIT
        VERBOSE LOG_EACH_CREATED LOG_EACH_SKIPPED PERFORMANCE_MODE USE_NODE_XYZ_CACHE
        USE_STATUS_PROGRESS PROGRESS_LOOP_STEP UI_UPDATE_STEP FORCE_STATUS_UPDATE
        STATUS_PERCENT_STEP STATUS_MIN_INTERVAL_MS FAST_RBE2_MARK_FILTER
    }
}

proc ::RB2W::loadState {} {
    if {[llength [info commands ::HWFlow::loadState]] == 0} {
        return
    }
    set state [::HWFlow::loadState shell_washer_hole_rbe2]
    foreach key [::RB2W::stateKeys] {
        if {[dict exists $state $key]} {
            upvar #0 ::RB2W::$key v
            set v [dict get $state $key]
        }
    }
}

proc ::RB2W::saveState {} {
    if {[llength [info commands ::HWFlow::saveState]] == 0} {
        return
    }
    set state [dict create]
    foreach key [::RB2W::stateKeys] {
        upvar #0 ::RB2W::$key v
        if {[info exists v]} {
            dict set state $key $v
        }
    }
    ::HWFlow::saveState shell_washer_hole_rbe2 $state
}

proc ::RB2W::backToHome {w} {
    if {[llength [info commands ::HWFlow::backToHome]] > 0} {
        ::HWFlow::backToHome $w
    } else {
        catch {destroy $w}
    }
}

proc ::RB2W::savePanelState {} {
    variable ui
    foreach key [::RB2W::stateKeys] {
        if {[info exists ui($key)]} {
            upvar #0 ::RB2W::$key v
            set v $ui($key)
        }
    }
    ::RB2W::saveState
}

proc ::RB2W::showPanel {{settingsOnly 0}} {
    variable ui
    variable VERSION

    catch {destroy .rb2w_panel}
    ::RB2W::loadState

    foreach key [::RB2W::stateKeys] {
        upvar #0 ::RB2W::$key v
        if {[info exists v]} {
            set ui($key) $v
        }
    }

    set ui(ok) 0
    set ui(action) create
    set ui(selectedComps) ""
    set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]

    set w .rb2w_panel
    ::HWFlow::createTopLevel $w
    wm title $w "[::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -font [::HWFlow::uiFont heading]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.sel -text [::HWFlow::txt "1. 组件选择" "1. Component Selection"] -padx 8 -pady 8
    grid $w.main.sel -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    button $w.main.sel.pick -text [::HWFlow::txt "选择/重选组件" "Pick / Repick Components"] -width 24 -command "::RB2W::pickComponents"
    label $w.main.sel.info -textvariable ::RB2W::ui(selectedText) -width 72 -anchor w
    grid $w.main.sel.pick -row 0 -column 0 -sticky w -padx {0 8}
    grid $w.main.sel.info -row 0 -column 1 -sticky w

    labelframe $w.main.preset -text [::HWFlow::txt "2. 参数预设" "2. Parameter Presets"] -padx 8 -pady 8
    grid $w.main.preset -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    button $w.main.preset.normal -text [::HWFlow::txt "默认" "Default"] -width 12 -command "::RB2W::applyPreset normal"
    button $w.main.preset.loose  -text [::HWFlow::txt "椭圆宽松" "Loose Oval"] -width 12 -command "::RB2W::applyPreset loose"
    button $w.main.preset.strict -text [::HWFlow::txt "严格" "Strict"] -width 12 -command "::RB2W::applyPreset strict"
    grid $w.main.preset.normal -row 0 -column 0 -sticky w -padx {0 6}
    grid $w.main.preset.loose  -row 0 -column 1 -sticky w -padx {0 6}
    grid $w.main.preset.strict -row 0 -column 2 -sticky w

    labelframe $w.main.param -text [::HWFlow::txt "3. 识别与垫圈参数" "3. Detection and Washer Parameters"] -padx 8 -pady 8
    grid $w.main.param -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    set fields {
        {MIN_HOLE_DIAMETER          "最小孔径"              "Minimum hole diameter"}
        {MAX_HOLE_DIAMETER          "最大孔径"              "Maximum hole diameter"}
        {MIN_HOLE_EDGE_NODES        "最少孔边节点"          "Minimum edge nodes"}
        {MAX_HOLE_EDGE_NODES        "最多孔边节点"          "Maximum edge nodes"}
        {CIRCULARITY_TOL            "圆孔圆度容差"          "Circularity tolerance"}
        {MAX_OVAL_AXIS_RATIO        "椭圆 a/b 最大半径比"   "Max oval a/b radius ratio"}
        {OVAL_RADIAL_FIT_TOL        "椭圆拟合容差"          "Oval fit tolerance"}
        {OUTER_OVAL_RADIAL_FIT_TOL  "外圈椭圆容差"          "Outer oval tolerance"}
        {OUTER_OVAL_AXIS_RATIO_TOL  "内外椭圆比差容差"      "Inner/outer oval ratio tolerance"}
        {CENTER_OFFSET_TOL          "内外中心偏移容差"      "Center offset tolerance"}
        {INNER_WASHER_NODE_LOOPS    "绑定 washer 节点圈数"  "Washer node loops to tie"}
        {RBE2_DOF                   "刚性自由度"           "Rigid DOF"}
        {RBE2_COMPONENT_PREFIX      "输出组件前缀"          "Output component prefix"}
    }

    set i 0
    foreach item $fields {
        set key  [lindex $item 0]
        set name [::HWFlow::txt [lindex $item 1] [lindex $item 2]]
        set r [expr {$i / 2}]
        set c [expr {($i % 2) * 2}]
        label $w.main.param.l_$key -text $name -anchor w
        entry $w.main.param.e_$key -textvariable ::RB2W::ui($key) -width 18
        grid $w.main.param.l_$key -row $r -column $c -sticky w -padx {0 6} -pady 2
        grid $w.main.param.e_$key -row $r -column [expr {$c+1}] -sticky w -padx {0 18} -pady 2
        incr i
    }

    set r [expr {$i / 2}]
    set c [expr {($i % 2) * 2}]
    label $w.main.param.l_RIGID_TYPE -text [::HWFlow::txt "刚性类型" "Rigid type"] -anchor w
    tk_optionMenu $w.main.param.m_RIGID_TYPE ::RB2W::ui(RIGID_TYPE) RBE2 RBE3
    grid $w.main.param.l_RIGID_TYPE -row $r -column $c -sticky w -padx {0 6} -pady 2
    grid $w.main.param.m_RIGID_TYPE -row $r -column [expr {$c+1}] -sticky w -padx {0 18} -pady 2

    labelframe $w.main.opt -text [::HWFlow::txt "4. 选项" "4. Options"] -padx 8 -pady 8
    grid $w.main.opt -row 4 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    checkbutton $w.main.opt.oval -text [::HWFlow::txt "允许识别椭圆孔" "Allow oval holes"] -variable ::RB2W::ui(ALLOW_OVAL_HOLES)
    checkbutton $w.main.opt.skip -text [::HWFlow::txt "组件已有 RIGIDS 时跳过" "Skip component if RIGIDS exists"] -variable ::RB2W::ui(SKIP_COMPONENT_IF_EXISTING_RBE2)
    checkbutton $w.main.opt.src -text [::HWFlow::txt "检查源组件已有 RIGIDS" "Check source component"] -variable ::RB2W::ui(CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2)
    checkbutton $w.main.opt.out -text [::HWFlow::txt "检查输出组件已有 RIGIDS" "Check output components"] -variable ::RB2W::ui(CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2)
    checkbutton $w.main.opt.batch -text [::HWFlow::txt "批量归集 RIGIDS 到输出组件" "Batch organize RIGIDS elements"] -variable ::RB2W::ui(BATCH_ORGANIZE_RBE2)
    checkbutton $w.main.opt.perf -text [::HWFlow::txt "性能模式" "Performance mode"] -variable ::RB2W::ui(PERFORMANCE_MODE)
    grid $w.main.opt.oval  -row 0 -column 0 -sticky w -pady 2
    grid $w.main.opt.skip  -row 0 -column 1 -sticky w -pady 2
    grid $w.main.opt.src   -row 1 -column 0 -sticky w -pady 2
    grid $w.main.opt.out   -row 1 -column 1 -sticky w -pady 2
    grid $w.main.opt.batch -row 2 -column 0 -sticky w -pady 2
    grid $w.main.opt.perf  -row 2 -column 1 -sticky w -pady 2

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 -command "::RB2W::savePanelState; set ::RB2W::ui(ok) 0; ::RB2W::backToHome .rb2w_panel"
    button $w.btn.save -text [::HWFlow::txt "保存配置" "Save Config"] -width 12 -command "::RB2W::savePanelState"
    if {$settingsOnly} {
        button $w.btn.collect -text [::HWFlow::txt "归集全部 RBE2" "Collect All RBE2"] -width 16 -command "::RB2W::collectProjectRBE2FromSettings"
        button $w.btn.start -text [::HWFlow::txt "保存设置" "Save Settings"] -width 18 -command "::RB2W::saveSettingsPanel"
    } else {
        button $w.btn.merge -text [::HWFlow::txt "合并重复节点" "Merge Duplicate Nodes"] -width 16 -command "::RB2W::acceptPanel merge_nodes"
        button $w.btn.rebuild -text [::HWFlow::txt "重建模式" "Rebuild Mode"] -width 12 -command "::RB2W::acceptPanel rebuild"
        button $w.btn.start -text [::HWFlow::txt "开始创建" "Start Creation"] -width 18 -command "::RB2W::acceptPanel create"
    }
    pack $w.btn.back  -side right -padx 4
    pack $w.btn.save  -side right -padx 4
    if {$settingsOnly} {
        pack $w.btn.collect -side right -padx 4
    }
    if {!$settingsOnly} {
        pack $w.btn.merge -side right -padx 4
        pack $w.btn.rebuild -side right -padx 4
    }
    pack $w.btn.start -side right -padx 4

    bind $w <Escape> "::RB2W::savePanelState; set ::RB2W::ui(ok) 0; destroy .rb2w_panel"
    wm protocol $w WM_DELETE_WINDOW "::RB2W::savePanelState; set ::RB2W::ui(ok) 0; destroy .rb2w_panel"

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw-$ww)/2}]+[expr {($sh-$wh)/2}]

    tkwait window $w
    return $ui(ok)
}

proc ::RB2W::pickComponents {} {
    variable ui
    catch {*clearmark comps 1}
    *createmarkpanel comps 1 [::HWFlow::txt "选择用于创建垫圈孔 RIGIDS 的壳单元组件" "Select shell component(s) for washer-hole RIGIDS creation"]
    set comps [hm_getmark comps 1]
    catch {*clearmark comps 1}
    if {[llength $comps] == 0} {
        set ui(selectedComps) ""
        set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]
    } else {
        set ui(selectedComps) [RB2W::uniq $comps]
        set ui(selectedText) [::HWFlow::txt "已选择 [llength $ui(selectedComps)] 个组件" "Selected [llength $ui(selectedComps)] component(s)"]
    }
    catch {raise .rb2w_panel}
    catch {focus .rb2w_panel}
}

proc ::RB2W::applyPreset {mode} {
    variable ui
    switch -- $mode {
        strict {
            set ui(CIRCULARITY_TOL) 0.06
            set ui(MAX_OVAL_AXIS_RATIO) 2.50
            set ui(OVAL_RADIAL_FIT_TOL) 0.32
            set ui(OUTER_OVAL_RADIAL_FIT_TOL) 0.40
            set ui(OUTER_OVAL_AXIS_RATIO_TOL) 0.30
            set ui(CENTER_OFFSET_TOL) 0.15
        }
        loose {
            set ui(ALLOW_OVAL_HOLES) 1
            set ui(CIRCULARITY_TOL) 0.10
            set ui(MAX_OVAL_AXIS_RATIO) 4.50
            set ui(OVAL_RADIAL_FIT_TOL) 0.55
            set ui(OUTER_OVAL_RADIAL_FIT_TOL) 0.65
            set ui(OUTER_OVAL_AXIS_RATIO_TOL) 0.60
            set ui(CENTER_OFFSET_TOL) 0.30
        }
        default {
            set ui(ALLOW_OVAL_HOLES) 1
            set ui(CIRCULARITY_TOL) 0.08
            set ui(MAX_OVAL_AXIS_RATIO) 3.50
            set ui(OVAL_RADIAL_FIT_TOL) 0.45
            set ui(OUTER_OVAL_RADIAL_FIT_TOL) 0.55
            set ui(OUTER_OVAL_AXIS_RATIO_TOL) 0.45
            set ui(CENTER_OFFSET_TOL) 0.20
        }
    }
}

proc ::RB2W::acceptPanel {{action create}} {
    variable ui

    if {[llength $ui(selectedComps)] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "请先选择组件。" "Pick components first."]
        return
    }

    set doubleKeys {
        MIN_HOLE_DIAMETER MAX_HOLE_DIAMETER CIRCULARITY_TOL
        MAX_OVAL_AXIS_RATIO OVAL_RADIAL_FIT_TOL OUTER_OVAL_RADIAL_FIT_TOL
        OUTER_OVAL_AXIS_RATIO_TOL CENTER_OFFSET_TOL
    }
    foreach k $doubleKeys {
        if {![string is double -strict $ui($k)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "$k 必须为数值。" "$k must be a number."]
            return
        }
    }

    set intKeys {
        MIN_HOLE_EDGE_NODES MAX_HOLE_EDGE_NODES INNER_WASHER_NODE_LOOPS
        RBE2_DOF ALLOW_OVAL_HOLES SKIP_COMPONENT_IF_EXISTING_RBE2
        CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2 CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2
        BATCH_ORGANIZE_RBE2 PERFORMANCE_MODE FAST_RBE2_MARK_FILTER
    }
    foreach k $intKeys {
        if {![string is integer -strict $ui($k)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "$k 必须为整数。" "$k must be an integer."]
            return
        }
    }

    if {[lsearch -exact {RBE2 RBE3} $ui(RIGID_TYPE)] < 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "刚性类型必须为 RBE2 或 RBE3。" "Rigid type must be RBE2 or RBE3."]
        return
    }

    if {$ui(MIN_HOLE_DIAMETER) < 0 || $ui(MAX_HOLE_DIAMETER) <= 0 || $ui(MIN_HOLE_DIAMETER) > $ui(MAX_HOLE_DIAMETER)} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "孔径范围无效。" "Invalid hole diameter range."]
        return
    }
    if {$ui(MIN_HOLE_EDGE_NODES) < 3 || $ui(MAX_HOLE_EDGE_NODES) < $ui(MIN_HOLE_EDGE_NODES)} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "孔边节点数量范围无效。" "Invalid edge node range."]
        return
    }
    if {$ui(INNER_WASHER_NODE_LOOPS) < 2} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "绑定 washer 节点圈数至少为 2。" "Washer node loops must be at least 2."]
        return
    }
    if {$ui(MAX_OVAL_AXIS_RATIO) < 1.0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "椭圆 a/b 最大半径比必须不小于 1。" "Max oval a/b radius ratio must be at least 1."]
        return
    }
    foreach k {CIRCULARITY_TOL OVAL_RADIAL_FIT_TOL OUTER_OVAL_RADIAL_FIT_TOL OUTER_OVAL_AXIS_RATIO_TOL CENTER_OFFSET_TOL} {
        if {$ui($k) < 0} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "$k 不能为负值。" "$k cannot be negative."]
            return
        }
    }
    if {[string trim $ui(RBE2_COMPONENT_PREFIX)] eq ""} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "输出组件前缀不能为空。" "Output component prefix cannot be empty."]
        return
    }

    ::RB2W::savePanelState
    set ui(action) $action
    set ui(ok) 1
    catch {destroy .rb2w_panel}
}

proc ::RB2W::saveSettingsPanel {} {
    variable ui
    ::RB2W::savePanelState
    set ui(ok) 1
    catch {destroy .rb2w_panel}
}

proc ::RB2W::projectRBE2ComponentIds {} {
    variable ui
    variable RBE2_COMPONENT_PREFIX

    set prefixes [list "AUTO_RBE2"]
    if {[info exists ui(RBE2_COMPONENT_PREFIX)] && [string trim $ui(RBE2_COMPONENT_PREFIX)] ne ""} {
        lappend prefixes [RB2W::sanitizeNamePart $ui(RBE2_COMPONENT_PREFIX) "AUTO_RBE2"]
    } elseif {[string trim $RBE2_COMPONENT_PREFIX] ne ""} {
        lappend prefixes [RB2W::sanitizeNamePart $RBE2_COMPONENT_PREFIX "AUTO_RBE2"]
    }
    set prefixes [RB2W::uniq $prefixes]

    set out {}
    catch {*clearmark comps 1}
    if {[catch {*createmark comps 1 all}]} { return {} }
    set compIds {}
    catch {set compIds [hm_getmark comps 1]}
    catch {*clearmark comps 1}
    foreach cid $compIds {
        set name [RB2W::getComponentName $cid]
        foreach prefix $prefixes {
            if {[string match "${prefix}_*" $name]} {
                lappend out $cid
                break
            }
        }
    }
    return [RB2W::uniq $out]
}

proc ::RB2W::collectProjectRBE2 {} {
    set sourceCompIds [RB2W::projectRBE2ComponentIds]
    if {[llength $sourceCompIds] == 0} {
        return [dict create components 0 rbe2 0 moved 0 deleted 0 failed 0]
    }

    set marked [RB2W::markRigidLinkCandidates 2]
    if {![lindex $marked 0]} {
        error [::HWFlow::txt "当前求解器配置下无法可靠识别 RBE2 单元，未执行归集。" "RBE2 elements cannot be identified reliably with the current solver profile; nothing was changed."]
    }
    set allRBE2 [lindex $marked 1]
    array set isRBE2 {}
    foreach eid $allRBE2 { set isRBE2($eid) 1 }

    set moveIds {}
    foreach cid $sourceCompIds {
        foreach eid [RB2W::getElemsByComp $cid] {
            if {[info exists isRBE2($eid)]} { lappend moveIds $eid }
        }
    }
    set moveIds [RB2W::uniq $moveIds]

    set moved 0
    if {[llength $moveIds] > 0} {
        RB2W::createComponentByName RBE2
        set moved [RB2W::organizeCreatedRBE2Elements $moveIds RBE2]
    }

    # getElemsByComp is cached; refresh it after the ownership change before
    # deciding which source components are truly empty.
    RB2W::clearComponentElemCache
    set deleted 0
    set failed 0
    foreach cid $sourceCompIds {
        set name [RB2W::getComponentName $cid]
        if {[llength [RB2W::getElemsByComp $cid]] != 0} { continue }
        if {[RB2W::deleteComponentByName $name]} {
            incr deleted
        } else {
            incr failed
            RB2W::log "Warning: empty project RBE2 component could not be deleted: $name"
        }
    }
    RB2W::clearComponentElemCache
    RB2W::resetRBE2CandidateCache
    RB2W::refreshBrowsersAndGraphics 1
    RB2W::log "Collect project RBE2: components=[llength $sourceCompIds], detected=[llength $moveIds], moved=$moved, deletedEmpty=$deleted, deleteFailed=$failed"
    return [dict create components [llength $sourceCompIds] rbe2 [llength $moveIds] moved $moved deleted $deleted failed $failed]
}

proc ::RB2W::collectProjectRBE2FromSettings {} {
    set answer [tk_messageBox -icon question -type yesno -default no \
        -title [::HWFlow::txt "归集项目 RBE2" "Collect Project RBE2"] \
        -message [::HWFlow::txt "将把本项目输出组件中的所有 RBE2 单元移动到统一的 RBE2 组件，并删除搬移后不含单元的输出组件。是否继续？" "Move all RBE2 elements in project output components into one RBE2 component and delete output components that contain no elements afterward. Continue?"]]
    if {$answer ne "yes"} { return }

    set code [catch {set stat [RB2W::collectProjectRBE2]} err]
    if {$code} {
        tk_messageBox -icon error -title [::HWFlow::txt "归集项目 RBE2" "Collect Project RBE2"] -message $err
        return
    }
    set msg [::HWFlow::txt \
        "归集完成。\n扫描项目组件：[dict get $stat components]\n识别 RBE2：[dict get $stat rbe2]\n已移动：[dict get $stat moved]\n已删除空组件：[dict get $stat deleted]\n删除失败：[dict get $stat failed]" \
        "Collection complete.\nProject components scanned: [dict get $stat components]\nRBE2 detected: [dict get $stat rbe2]\nMoved: [dict get $stat moved]\nEmpty components deleted: [dict get $stat deleted]\nDelete failures: [dict get $stat failed]"]
    tk_messageBox -icon info -title [::HWFlow::txt "归集项目 RBE2" "Collect Project RBE2"] -message $msg
    catch {raise .rb2w_panel}
    catch {focus .rb2w_panel}
}

proc ::RB2W::overallStatus {overallPct compIndex compTotal compName loopIndex loopTotal candidateHoles created skipped {force 0}} {
    variable STATUS_PERCENT_STEP
    variable STATUS_MIN_INTERVAL_MS
    variable statusLastPercent
    variable statusLastTime

    if {$overallPct < 0.0} { set overallPct 0.0 }
    if {$overallPct > 100.0} { set overallPct 100.0 }
    set now [clock milliseconds]
    if {!$force && $STATUS_PERCENT_STEP > 0 && ($overallPct - $statusLastPercent) < $STATUS_PERCENT_STEP} { return }
    if {!$force && $STATUS_MIN_INTERVAL_MS > 0 && ($now - $statusLastTime) < $STATUS_MIN_INTERVAL_MS} { return }

    set statusLastPercent $overallPct
    set statusLastTime $now
    set pctText [format %.1f $overallPct]
    set msg [::HWFlow::txt "RB2W 总进度 ${pctText}% | 组件 $compIndex/$compTotal：$compName | 环线 $loopIndex/$loopTotal | 已创建=$created 已跳过=$skipped 候选=$candidateHoles" "RB2W overall ${pctText}% | comp $compIndex/$compTotal: $compName | loop $loopIndex/$loopTotal | created=$created skipped=$skipped candidates=$candidateHoles"]
    if {[llength [info commands ::HWFlow::progressUpdate]] > 0} {
        set title [::HWFlow::txt "Shell Washer-Hole RIGIDS running" "Shell Washer-Hole RIGIDS running"]
        catch {::HWFlow::progressUpdate $overallPct $title $msg $force}
    }
    RB2W::status $msg $force
}

proc ::RB2W::beginPerformanceMode {} {
    variable PERFORMANCE_MODE
    variable USE_STATUS_PROGRESS
    if {!$PERFORMANCE_MODE} { return }
    RB2W::log [::HWFlow::txt "性能模式已开启。" "Performance mode ON."]
    catch {*setoption entity_highlighting=0}
    if {$USE_STATUS_PROGRESS} {
        catch {*setoption block_messages=0}
        catch {hm_blockmessages 0}
    } else {
        catch {*setoption block_messages=1}
        catch {hm_blockmessages 1}
    }
    catch {*setoption block_redraw=1}
    catch {hm_blockredraw 1}
    catch {hwbrowsermanager view flush false}
    catch {hmbr_signals buffer start}
}

proc ::RB2W::enableInteractiveBrowserUpdates {} {
    if {[llength [info commands ::HWFlow::resetBrowserBlocks]] > 0} {
        catch {::HWFlow::resetBrowserBlocks}
    } else {
        catch {hm_blockbrowserupdate 0}
        catch {*setoption block_browser_update=0}
        catch {hmbr_signals buffer stop}
        catch {*setoption block_redraw=0}
        catch {*setoption block_messages=0}
        catch {hm_blockredraw 0}
        catch {hm_blockmessages 0}
        catch {hm_blockerrormessages 0}
        catch {hm_commandfilestate 1}
    }
    catch {hwbrowsermanager view flush true}
    catch {hm_setmouse 1}
    catch {update idletasks}
    catch {update}
}

proc ::RB2W::resumePerformanceModeAfterBrowserUpdate {} {
    variable PERFORMANCE_MODE
    variable USE_STATUS_PROGRESS
    if {!$PERFORMANCE_MODE} { return }

    if {$USE_STATUS_PROGRESS} {
        catch {*setoption block_messages=0}
        catch {hm_blockmessages 0}
    } else {
        catch {*setoption block_messages=1}
        catch {hm_blockmessages 1}
    }
    catch {*setoption block_redraw=1}
    catch {hm_blockredraw 1}
    catch {hwbrowsermanager view flush false}
    catch {hmbr_signals buffer start}
}

proc ::RB2W::endPerformanceMode {} {
    variable PERFORMANCE_MODE
    if {$PERFORMANCE_MODE} {
        catch {*setoption block_redraw=0}
        catch {*setoption block_messages=0}
        catch {*setoption entity_highlighting=1}
        catch {hm_blockredraw 0}
        catch {hm_blockmessages 0}
    }
    RB2W::enableInteractiveBrowserUpdates
    catch {hwbrowsermanager view flush true}
    RB2W::showAllOutputComponents
    RB2W::refreshBrowsersAndGraphics 1
    if {$PERFORMANCE_MODE} {
        RB2W::log [::HWFlow::txt "性能模式已关闭。" "Performance mode OFF."]
    }
}

proc ::RB2W::clearNodeXYZCache {} {
    variable nodeXYZCache
    catch {array unset nodeXYZCache}
    array set nodeXYZCache {}
}

proc ::RB2W::clearComponentElemCache {} {
    variable componentElemsCache
    catch {array unset componentElemsCache}
    array set componentElemsCache {}
}

proc ::RB2W::resetRBE2CandidateCache {} {
    variable rbe2MarkCacheValid
    variable rbe2MarkCacheAvailable
    variable rbe2MarkCacheIds
    variable rbe2MarkCacheSelector
    variable rbe2MarkCacheGrouped
    variable rbe2MarkCacheCanGroup
    variable rbe2CandidateCompId
    variable rbe2CandidateByComp
    set rbe2MarkCacheValid 0
    set rbe2MarkCacheAvailable 0
    set rbe2MarkCacheIds {}
    set rbe2MarkCacheSelector ""
    set rbe2MarkCacheGrouped 0
    set rbe2MarkCacheCanGroup 0
    catch {array unset rbe2CandidateCompId}
    catch {array unset rbe2CandidateByComp}
    array set rbe2CandidateCompId {}
    array set rbe2CandidateByComp {}
}

proc ::RB2W::uniq {lst} {
    set clean {}
    foreach x $lst {
        if {$x ne ""} { lappend clean $x }
    }
    set n [llength $clean]
    if {$n <= 1} { return $clean }
    if {![catch {set out [lsort -integer -unique $clean]}]} { return $out }
    return [lsort -unique $clean]
}

proc ::RB2W::edgeKey {a b} {
    if {$a < $b} { return "${a}:${b}" }
    return "${b}:${a}"
}

proc ::RB2W::addUniqueToArrayList {arrayName key value} {
    upvar $arrayName arr
    if {![info exists arr($key)]} {
        set arr($key) [list $value]
    } elseif {[lsearch -exact $arr($key) $value] < 0} {
        lappend arr($key) $value
    }
}

proc ::RB2W::bumpReason {arrayName reason} {
    upvar $arrayName arr
    if {![info exists arr($reason)]} { set arr($reason) 1 } else { incr arr($reason) }
}

proc ::RB2W::formatReasonStats {arrayName} {
    upvar $arrayName arr
    set parts {}
    foreach k [lsort [array names arr]] { lappend parts "$k=$arr($k)" }
    if {[llength $parts] == 0} { return "none" }
    return [join $parts "; "]
}

proc ::RB2W::getElemNodes {eid} {
    set nodes {}
    if {![catch {set nodes [hm_getvalue elems id=$eid dataname=nodes]}] && [llength $nodes] >= 3} { return $nodes }
    if {![catch {set nodes [hm_nodelist $eid]}] && [llength $nodes] >= 3} { return $nodes }
    set nodes {}
    for {set i 1} {$i <= 8} {incr i} {
        if {![catch {set n [hm_getvalue elems id=$eid dataname=node${i}.id]}] && $n ne "" && $n != 0} { lappend nodes $n }
    }
    return $nodes
}

proc ::RB2W::getNodeXYZRaw {nid} {
    set ok 1
    if {[catch {set x [hm_getvalue nodes id=$nid dataname=x]}]} { set ok 0 }
    if {[catch {set y [hm_getvalue nodes id=$nid dataname=y]}]} { set ok 0 }
    if {[catch {set z [hm_getvalue nodes id=$nid dataname=z]}]} { set ok 0 }
    if {$ok} { return [list $x $y $z] }

    set ok 1
    if {[catch {set x [hm_getvalue nodes id=$nid dataname=globalx]}]} { set ok 0 }
    if {[catch {set y [hm_getvalue nodes id=$nid dataname=globaly]}]} { set ok 0 }
    if {[catch {set z [hm_getvalue nodes id=$nid dataname=globalz]}]} { set ok 0 }
    if {$ok} { return [list $x $y $z] }

    if {![catch {set xyz [join [hm_nodevalue $nid]]}] && [llength $xyz] >= 3} { return [lrange $xyz 0 2] }
    error [::HWFlow::txt "无法读取节点 $nid 的坐标。" "Cannot read coordinates of node $nid"]
}

proc ::RB2W::getNodeXYZ {nid} {
    variable USE_NODE_XYZ_CACHE
    variable nodeXYZCache
    if {$USE_NODE_XYZ_CACHE && [info exists nodeXYZCache($nid)]} { return $nodeXYZCache($nid) }
    set xyz [RB2W::getNodeXYZRaw $nid]
    if {$USE_NODE_XYZ_CACHE} { set nodeXYZCache($nid) $xyz }
    return $xyz
}

proc ::RB2W::distance3 {p q} {
    set dx [expr {[lindex $p 0] - [lindex $q 0]}]
    set dy [expr {[lindex $p 1] - [lindex $q 1]}]
    set dz [expr {[lindex $p 2] - [lindex $q 2]}]
    return [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
}

proc ::RB2W::loopGeometry {nodes} {
    set n [llength $nodes]
    if {$n == 0} { error [::HWFlow::txt "空环线。" "empty loop"] }
    set sx 0.0; set sy 0.0; set sz 0.0
    set xyzList {}
    foreach nid $nodes {
        set xyz [RB2W::getNodeXYZ $nid]
        foreach {x y z} $xyz {}
        lappend xyzList $xyz
        set sx [expr {$sx + $x}]
        set sy [expr {$sy + $y}]
        set sz [expr {$sz + $z}]
    }
    set center [list [expr {$sx / double($n)}] [expr {$sy / double($n)}] [expr {$sz / double($n)}]]
    set sr 0.0; set minr 1.0e99; set maxr -1.0; set radii {}
    foreach xyz $xyzList {
        set r [RB2W::distance3 $xyz $center]
        lappend radii $r
        set sr [expr {$sr + $r}]
        if {$r < $minr} { set minr $r }
        if {$r > $maxr} { set maxr $r }
    }
    set meanr [expr {$sr / double($n)}]
    set ss 0.0
    foreach r $radii { set dr [expr {$r - $meanr}]; set ss [expr {$ss + $dr*$dr}] }
    set rms [expr {sqrt($ss / double($n))}]
    if {$meanr <= 1.0e-12} { set rel 999.0 } else { set rel [expr {$rms / $meanr}] }
    if {$minr <= 1.0e-12} {
        set axisRatio 999.0
    } else {
        set axisRatio [expr {$maxr / $minr}]
    }
    set shape [dict create \
        meanR $meanr \
        minR $minr \
        maxR $maxr \
        meanD [expr {2.0 * $meanr}] \
        minD [expr {2.0 * $minr}] \
        maxD [expr {2.0 * $maxr}] \
        radialRel $rel \
        axisRatio $axisRatio]
    return [list $center $meanr $rel $minr $maxr $shape]
}

proc ::RB2W::loopShape {geom} {
    if {[llength $geom] >= 6} { return [lindex $geom 5] }
    set meanr [lindex $geom 1]
    set rel [lindex $geom 2]
    set minr [lindex $geom 3]
    set maxr [lindex $geom 4]
    if {$minr <= 1.0e-12} {
        set axisRatio 999.0
    } else {
        set axisRatio [expr {$maxr / $minr}]
    }
    return [dict create \
        meanR $meanr \
        minR $minr \
        maxR $maxr \
        meanD [expr {2.0 * $meanr}] \
        minD [expr {2.0 * $minr}] \
        maxD [expr {2.0 * $maxr}] \
        radialRel $rel \
        axisRatio $axisRatio]
}

proc ::RB2W::getElemsByComp {compId} {
    variable componentElemsCache
    if {[info exists componentElemsCache($compId)]} {
        return $componentElemsCache($compId)
    }

    *clearmark elems 1
    set elems {}
    if {![catch {*createmark elems 1 "by comp id" $compId}]} { set elems [hm_getmark elems 1] }
    if {[llength $elems] == 0} {
        catch {*clearmark elems 1}
        if {![catch {*createmark elems 1 "by collector id" $compId}]} { set elems [hm_getmark elems 1] }
    }
    catch {*clearmark elems 1}
    set elems [RB2W::uniq $elems]
    set componentElemsCache($compId) $elems
    return $elems
}

proc ::RB2W::buildGraph {elems} {
    variable elemNodes
    variable edgeElems
    variable elemNbrs
    catch {array unset elemNodes}; catch {array unset edgeElems}; catch {array unset elemNbrs}
    array set elemNodes {}; array set edgeElems {}; array set elemNbrs {}

    foreach eid $elems {
        set ns [RB2W::getElemNodes $eid]
        set nn [llength $ns]
        if {$nn < 3} { continue }
        set elemNodes($eid) $ns
        for {set i 0} {$i < $nn} {incr i} {
            set n1 [lindex $ns $i]
            set n2 [lindex $ns [expr {($i + 1) % $nn}]]
            if {$n1 eq "" || $n2 eq "" || $n1 == $n2} { continue }
            set key [RB2W::edgeKey $n1 $n2]
            lappend edgeElems($key) $eid
        }
    }

    foreach key [array names edgeElems] {
        set el $edgeElems($key)
        set cnt [llength $el]
        if {$cnt > 2 || ($cnt == 2 && [lindex $el 0] eq [lindex $el 1])} {
            set el [RB2W::uniq $el]
            set cnt [llength $el]
            set edgeElems($key) $el
        }
        if {$cnt == 2} {
            set e1 [lindex $el 0]
            set e2 [lindex $el 1]
            RB2W::addUniqueToArrayList elemNbrs $e1 $e2
            RB2W::addUniqueToArrayList elemNbrs $e2 $e1
        }
    }
}

proc ::RB2W::findFreeEdgeLoops {} {
    variable edgeElems
    array set freeAdj {}
    array set freeEdgesByNodePair {}
    foreach key [array names edgeElems] {
        if {[llength $edgeElems($key)] == 1} {
            foreach {a b} [split $key ":"] {}
            RB2W::addUniqueToArrayList freeAdj $a $b
            RB2W::addUniqueToArrayList freeAdj $b $a
            set freeEdgesByNodePair($key) 1
        }
    }

    array set visited {}
    set loops {}
    foreach start [array names freeAdj] {
        if {[info exists visited($start)]} { continue }
        set queue [list $start]
        set nodes {}
        set closed 1
        set qi 0
        set visited($start) 1
        while {$qi < [llength $queue]} {
            set n [lindex $queue $qi]
            incr qi
            lappend nodes $n
            if {![info exists freeAdj($n)] || [llength $freeAdj($n)] != 2} { set closed 0 }
            foreach nb $freeAdj($n) {
                if {![info exists visited($nb)]} { set visited($nb) 1; lappend queue $nb }
            }
        }
        set edgeKeys {}
        catch {array unset seenEdge}
        array set seenEdge {}
        foreach n $nodes {
            foreach nb $freeAdj($n) {
                set k [RB2W::edgeKey $n $nb]
                if {[info exists freeEdgesByNodePair($k)] && ![info exists seenEdge($k)]} {
                    set seenEdge($k) 1
                    lappend edgeKeys $k
                }
            }
        }
        if {[llength $edgeKeys] != [llength $nodes]} { set closed 0 }
        lappend loops [dict create nodes $nodes edges $edgeKeys closed $closed]
    }
    return $loops
}

proc ::RB2W::seedElemsFromLoop {edgeKeys} {
    variable edgeElems
    set seeds {}
    foreach k $edgeKeys {
        if {[info exists edgeElems($k)] && [llength $edgeElems($k)] == 1} { lappend seeds [lindex $edgeElems($k) 0] }
    }
    return [RB2W::uniq $seeds]
}

proc ::RB2W::expandElementLayers {seedElems layerCount} {
    variable elemNbrs
    if {$layerCount <= 1} { return [RB2W::uniq $seedElems] }
    array set selected {}
    set frontier [RB2W::uniq $seedElems]
    foreach e $frontier { set selected($e) 1 }
    for {set layer 2} {$layer <= $layerCount} {incr layer} {
        set next {}
        foreach e $frontier {
            if {![info exists elemNbrs($e)]} { continue }
            foreach nb $elemNbrs($e) {
                if {![info exists selected($nb)]} { set selected($nb) 1; lappend next $nb }
            }
        }
        set frontier $next
        if {[llength $frontier] == 0} { break }
    }
    return [array names selected]
}

proc ::RB2W::nodesFromElems {elems} {
    variable elemNodes
    array set seen {}
    foreach e $elems {
        if {![info exists elemNodes($e)]} { continue }
        foreach n $elemNodes($e) {
            if {$n ne ""} { set seen($n) 1 }
        }
    }
    return [array names seen]
}

proc ::RB2W::listSubtract {all remove} {
    array set rm {}
    foreach n $remove { set rm($n) 1 }
    set out {}
    foreach n $all { if {![info exists rm($n)]} { lappend out $n } }
    return $out
}

proc ::RB2W::componentExistsByName {compName} {
    if {![catch {set exists [hm_entityinfo exist components $compName -byname]}]} { return $exists }
    if {![catch {set cid [hm_entityinfo id components $compName -byname]}] && $cid ne "" && $cid != 0} { return 1 }
    return 0
}

proc ::RB2W::deleteComponentByName {compName} {
    foreach etype {components comps} {
        catch {*clearmark $etype 2}
        foreach selector {"by name only" "by name"} {
            if {![catch {*createmark $etype 2 $selector $compName}]} {
                if {![catch {set ids [hm_getmark $etype 2]}] && [llength $ids] > 0} {
                    catch {*deletemark $etype 2}
                    catch {*clearmark $etype 2}
                    return 1
                }
            }
        }
        catch {*clearmark $etype 2}
    }
    return 0
}

proc ::RB2W::componentIdByName {compName} {
    foreach etype {components comps component} {
        if {![catch {set cid [hm_entityinfo id $etype $compName -byname]}] && $cid ne "" && $cid != 0} { return $cid }
    }
    foreach etype {components comps} {
        catch {*clearmark $etype 2}
        if {![catch {*createmark $etype 2 "by name only" $compName}]} {
            if {![catch {set ids [hm_getmark $etype 2]}] && [llength $ids] > 0} {
                catch {*clearmark $etype 2}
                return [lindex $ids 0]
            }
        }
    }
    return ""
}

proc ::RB2W::getComponentName {compId} {
    foreach etype {comps components component} {
        if {![catch {set n [hm_getcollectorname $etype $compId]}] && $n ne ""} { return $n }
    }
    foreach etype {comps components component} {
        if {![catch {set n [hm_entityinfo name $etype $compId -byid]}] && $n ne ""} { return $n }
    }
    if {![catch {set n [hm_getvalue comps id=$compId dataname=name]}] && $n ne ""} { return $n }
    return "comp_$compId"
}

proc ::RB2W::sanitizeNamePart {raw fallback} {
    set s [string trim $raw]
    if {$s eq ""} { set s $fallback }
    regsub -all {[^[:alnum:]_.-]+} $s "_" s
    regsub -all {_+} $s "_" s
    set s [string trim $s "_"]
    if {$s eq ""} { set s $fallback }
    if {[string length $s] > 48} { set s [string range $s 0 47] }
    return $s
}

proc ::RB2W::sourceOutputBaseName {sourceCompId} {
    variable RBE2_COMPONENT_PREFIX
    set srcName [RB2W::getComponentName $sourceCompId]
    set safeSrc [RB2W::sanitizeNamePart $srcName "comp_$sourceCompId"]
    return "${RBE2_COMPONENT_PREFIX}_${safeSrc}"
}

proc ::RB2W::uniqueComponentName {baseName} {
    set base [RB2W::sanitizeNamePart $baseName "AUTO_RBE2"]
    if {![RB2W::componentExistsByName $base]} { return $base }
    for {set i 1} {$i <= 999} {incr i} {
        set cand [format "%s_%02d" $base $i]
        if {![RB2W::componentExistsByName $cand]} { return $cand }
    }
    return [format "%s_%s" $base [clock seconds]]
}

proc ::RB2W::setCurrentComponent {compName} {
    variable currentComponentName
    if {[info exists currentComponentName] && $currentComponentName eq $compName} { return }
    if {[catch {*currentcollector component $compName} err1]} {
        if {[catch {*currentcollector(component,$compName)} err2]} {
            error [::HWFlow::txt "无法将当前组件设置为 $compName：$err1 / $err2" "Cannot set current component to $compName: $err1 / $err2"]
        }
    }
    set currentComponentName $compName
}

proc ::RB2W::createComponentByName {compName} {
    variable PERFORMANCE_MODE
    if {[RB2W::componentExistsByName $compName]} {
        RB2W::setCurrentComponent $compName
        catch {::HWFlow::syncComponentInBrowser $compName}
        return
    }

    if {$PERFORMANCE_MODE} {
        RB2W::enableInteractiveBrowserUpdates
    }

    set code [catch {
        if {[llength [info commands ::HWFlow::createComponent]] > 0} {
            ::HWFlow::createComponent $compName
        } else {
            set color [expr {1 + int(rand() * 63)}]
            if {$color >= 11} {incr color}
            if {[llength [info commands ::HWFlow::randomComponentColor]] > 0} {
                set color [::HWFlow::randomComponentColor]
            }
            set histName "Created Component $compName"
            set histStarted 0
            catch {*startnotehistorystate $histName}
            set histStarted 1

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
                if {$histStarted} { catch {*endnotehistorystate $histName} }
                error [::HWFlow::txt "无法创建输出组件 $compName：$err1 / $err2" "Cannot create output component $compName: $err1 / $err2"]
            }
            if {$histStarted} { catch {*endnotehistorystate $histName} }
            set compId ""
            catch {set compId [hm_getvalue comps name=$compName dataname=id]}
            if {$compId ne "" && $compId != 0} {
                foreach etype {comps components} {
                    catch {*setvalue $etype id=$compId color=$color}
                }
            }
        }

        RB2W::setCurrentComponent $compName
        if {[llength [info commands ::HWFlow::syncComponentInBrowser]] > 0} {
            ::HWFlow::syncComponentInBrowser $compName
        } else {
            catch {::HWFlow::activateAndShowComponent $compName 0}
            RB2W::showOutputComponent $compName 1
        }
        if {![RB2W::componentExistsByName $compName]} {
            error [::HWFlow::txt "输出组件 $compName 已创建但无法在模型中重新定位。" "Output component $compName was created but cannot be resolved in the model."]
        }
        catch {update idletasks}
        catch {update}
    } err opts]

    if {$PERFORMANCE_MODE} {
        RB2W::resumePerformanceModeAfterBrowserUpdate
    }
    if {$code} {
        return -options $opts $err
    }
}

proc ::RB2W::ensureOutputComponent {sourceCompId} {
    variable outputCompBySource
    variable PERFORMANCE_MODE
    if {[info exists outputCompBySource($sourceCompId)]} {
        set outName $outputCompBySource($sourceCompId)
        RB2W::setCurrentComponent $outName
        return $outName
    }
    set srcName [RB2W::getComponentName $sourceCompId]
    set baseName [RB2W::sourceOutputBaseName $sourceCompId]
    set outName [RB2W::sanitizeNamePart $baseName "AUTO_RBE2"]
    RB2W::createComponentByName $outName
    set outputCompBySource($sourceCompId) $outName
    if {!$PERFORMANCE_MODE} {
        RB2W::showOutputComponent $outName 0
    }
    RB2W::log "Output component created for source component $sourceCompId ($srcName): $outName"
    return $outName
}

proc ::RB2W::markComponentByName {compName markId} {
    foreach etype {components comps} {
        catch {*clearmark $etype $markId}
        if {![catch {*createmark $etype $markId "by name only" $compName}]} {
            if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} { return $etype }
        }
    }
    set cid [RB2W::componentIdByName $compName]
    if {$cid ne ""} {
        foreach etype {components comps} {
            catch {*clearmark $etype $markId}
            if {![catch {*createmark $etype $markId "by id only" $cid}]} {
                if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} { return $etype }
            }
        }
    }
    return ""
}

proc ::RB2W::showOutputComponent {compName {refreshNow 0}} {
    variable SHOW_OUTPUT_COMPONENTS
    if {!$SHOW_OUTPUT_COMPONENTS} { return }
    set compId [RB2W::componentIdByName $compName]
    set markType [RB2W::markComponentByName $compName 2]
    if {$markType ne ""} {
        catch {*marksuppressactive $markType 2 0}
        catch {*marksuppressoutput $markType 2 0}
        catch {*displaycollectorsbymark $markType 2 on 1 1}
        catch {*displaycollectorsbymark components 2 on 1 1}
        catch {*displaycollectorsbymark comps 2 on 1 1}
        catch {*displaycollectorsallbymark 2 on 1 1}
        catch {*clearmark $markType 2}
    }
    catch {*displaycollector component on $compName 1 1}
    catch {*displaycollector components on $compName 1 1}
    catch {*displaycollectorwithfilter component on $compName 1 1}
    catch {*displaycollectorwithfilter components on $compName 1 1}
    if {$compId ne ""} {
        catch {*showentity comps "by id" $compId}
        catch {*showentity components "by id" $compId}
    }
    if {$refreshNow} { RB2W::refreshBrowsersAndGraphics }
}

proc ::RB2W::showAllOutputComponents {} {
    variable outputCompBySource
    if {![array exists outputCompBySource]} { return }
    foreach k [array names outputCompBySource] { RB2W::showOutputComponent $outputCompBySource($k) 0 }
}

proc ::RB2W::refreshBrowsersAndGraphics {{force 0}} {
    variable FORCE_BROWSER_REFRESH
    if {!$FORCE_BROWSER_REFRESH && !$force} { return }
    if {[llength [info commands ::HWFlow::refreshBrowser]] > 0} {
        catch {::HWFlow::refreshBrowser}
        return
    }
    catch {hmbr_signals buffer stop}
    catch {hwbrowsermanager view flush true}
    catch {hm_redraw}
    catch {update idletasks}
    catch {update}
}

proc ::RB2W::countEntitiesInComponent {compName entityType} {
    set compId [RB2W::componentIdByName $compName]
    foreach ctype {components comps} {
        if {![catch {set n [hm_entityincollector $ctype $compName $entityType 0 0 -byname]}] && $n ne ""} {
            return $n
        }
        if {$compId ne "" && ![catch {set n [hm_entityincollector $ctype $compId $entityType 0 0 -byid]}] && $n ne ""} {
            return $n
        }
    }

    catch {*clearmark $entityType 1}
    if {$compId ne "" && ![catch {*createmark $entityType 1 "by comp id" $compId}]} {
        if {![catch {set ids [hm_getmark $entityType 1]}]} {
            catch {*clearmark $entityType 1}
            return [llength $ids]
        }
    }
    if {![catch {*createmark $entityType 1 "by comp name" $compName}]} {
        if {![catch {set ids [hm_getmark $entityType 1]}]} {
            catch {*clearmark $entityType 1}
            return [llength $ids]
        }
    }
    catch {*clearmark $entityType 1}
    return "?"
}

proc ::RB2W::outputComponentSummary {} {
    variable outputCompBySource
    if {![array exists outputCompBySource]} { return "" }

    set lines {}
    foreach sourceId [lsort -integer [array names outputCompBySource]] {
        set compName $outputCompBySource($sourceId)
        set compId [RB2W::componentIdByName $compName]
        set elemCount [RB2W::countEntitiesInComponent $compName elems]
        set nodeCount [RB2W::countEntitiesInComponent $compName nodes]
        lappend lines "$compName  id=$compId  elems=$elemCount  nodes=$nodeCount"
    }
    return [join $lines \n]
}

proc ::RB2W::moveMarkToComponent {entityTypes markId compName} {
    foreach etype $entityTypes {
        if {![catch {*movemark $etype $markId $compName} err]} { return 1 }
    }
    return 0
}

proc ::RB2W::deleteEntitiesByIds {entityTypes ids {chunkSize 500}} {
    set ids [RB2W::uniq $ids]
    set total 0
    if {[llength $ids] == 0} { return 0 }
    foreach chunk [RB2W::listChunks $ids $chunkSize] {
        set deleted 0
        foreach etype $entityTypes {
            catch {*clearmark $etype 1}
            if {[catch {eval *createmark $etype 1 $chunk}]} { continue }
            if {![catch {*deletemark $etype 1}]} {
                set total [expr {$total + [llength $chunk]}]
                set deleted 1
                break
            }
        }
        catch {*clearmark elems 1}
        catch {*clearmark elements 1}
        catch {*clearmark nodes 1}
        if {!$deleted} {
            RB2W::log "Warning: could not delete [llength $chunk] entity/entities: $chunk"
        }
    }
    return $total
}

proc ::RB2W::listChunks {lst chunkSize} {
    if {$chunkSize <= 0} { set chunkSize 500 }
    set out {}
    set n [llength $lst]
    for {set i 0} {$i < $n} {incr i $chunkSize} {
        set j [expr {$i + $chunkSize - 1}]
        if {$j >= $n} { set j [expr {$n - 1}] }
        lappend out [lrange $lst $i $j]
    }
    return $out
}

proc ::RB2W::organizeCreatedRBE2Elements {elemIds outComp} {
    variable ORGANIZE_BATCH_SIZE
    set elemIds [RB2W::uniq $elemIds]
    set total [llength $elemIds]
    if {$total == 0} { return 0 }
    set moved 0
    foreach chunk [RB2W::listChunks $elemIds $ORGANIZE_BATCH_SIZE] {
        catch {*clearmark elems 1}
        if {[catch {eval *createmark elems 1 $chunk} errMark]} {
            RB2W::log "Warning: could not mark RBE2 batch for $outComp: $errMark"
            continue
        }
        if {![RB2W::moveMarkToComponent {elems elements} 1 $outComp]} {
            RB2W::log "Warning: could not batch-organize [llength $chunk] RBE2 element(s) into $outComp."
        } else {
            set moved [expr {$moved + [llength $chunk]}]
        }
        catch {*clearmark elems 1}
    }
    return $moved
}

proc ::RB2W::getLastCreatedOnMark {entityTypes markId} {
    foreach etype $entityTypes {
        if {![catch {set latest [hm_latestentityid $etype]}] && $latest ne "" && $latest != 0} {
            catch {*clearmark $etype $markId}
            if {![catch {*createmark $etype $markId $latest}]} {
                if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} { return [list $etype $ids] }
            }
        }
        catch {*clearmark $etype $markId}
        if {![catch {*createmark $etype $markId -1}]} {
            if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} { return [list $etype $ids] }
        }
    }
    return [list "" {}]
}

# ---------------- Existing RBE2 safety detection ----------------
proc ::RB2W::elemConfigLooksLikePlainShell {cfg} {
    set u [string toupper [string trim "$cfg"]]
    if {$u eq ""} { return 0 }
    if {[string first "RBE2" $u] >= 0 || [string first "RIGID" $u] >= 0} { return 0 }
    if {[regexp {(SHELL|TRIA|QUAD|CQUAD|CTRIA)} $u]} { return 1 }
    if {[regexp {^[0-9]+$} $u] && [lsearch -exact {103 104 106 108} $u] >= 0} { return 1 }
    return 0
}

proc ::RB2W::markElementCandidates {markId selectors} {
    set sawSuccess 0
    set firstSuccessfulSelector ""
    foreach selector $selectors {
        catch {*clearmark elems $markId}
        catch {*clearmark elements $markId}
        set cmd [concat [list *createmark elems $markId] $selector]
        if {![catch {eval $cmd}]} {
            set sawSuccess 1
            if {$firstSuccessfulSelector eq ""} {
                set firstSuccessfulSelector [join $selector " "]
            }
            set ids {}
            catch {set ids [hm_getmark elems $markId]}
            catch {*clearmark elems $markId}
            catch {*clearmark elements $markId}
            set ids [RB2W::uniq $ids]
            if {[llength $ids] > 0} {
                return [list 1 $ids [join $selector " "]]
            }
        }
    }
    catch {*clearmark elems $markId}
    catch {*clearmark elements $markId}
    if {$sawSuccess} {
        return [list 1 {} $firstSuccessfulSelector]
    }
    return [list 0 {} ""]
}

proc ::RB2W::markRigidLinkCandidates {markId} {
    return [RB2W::markElementCandidates $markId {
        {"by config" 55}
        {"by element config" 55}
        {"by elem config" 55}
        {"by configuration" 55}
        {"by card image" RBE2}
        {"by cardimage" RBE2}
        {"by type" RBE2}
    }]
}

proc ::RB2W::rbe2CandidateMarkIds {} {
    variable FAST_RBE2_MARK_FILTER
    variable rbe2MarkCacheValid
    variable rbe2MarkCacheAvailable
    variable rbe2MarkCacheIds
    variable rbe2MarkCacheSelector

    if {!$FAST_RBE2_MARK_FILTER} { return [list 0 {} "disabled"] }
    if {$rbe2MarkCacheValid} {
        return [list $rbe2MarkCacheAvailable $rbe2MarkCacheIds $rbe2MarkCacheSelector]
    }

    set found [RB2W::markRigidLinkCandidates 2]
    set rbe2MarkCacheValid 1
    set rbe2MarkCacheAvailable [lindex $found 0]
    set rbe2MarkCacheIds [lindex $found 1]
    set rbe2MarkCacheSelector [lindex $found 2]
    return [list $rbe2MarkCacheAvailable $rbe2MarkCacheIds $rbe2MarkCacheSelector]
}

proc ::RB2W::rbe2CandidateComponentId {eid} {
    variable rbe2CandidateCompId
    if {[info exists rbe2CandidateCompId($eid)]} { return $rbe2CandidateCompId($eid) }
    set cid ""
    foreach dn {component.id collector.id comp.id} {
        if {![catch {set v [hm_getvalue elems id=$eid dataname=$dn]}] && $v ne "" && $v != 0} {
            set cid $v
            break
        }
    }
    set rbe2CandidateCompId($eid) $cid
    return $cid
}

proc ::RB2W::ensureRBE2CandidateComponentIndex {} {
    variable rbe2MarkCacheGrouped
    variable rbe2MarkCacheCanGroup
    variable rbe2CandidateByComp

    if {$rbe2MarkCacheGrouped} { return $rbe2MarkCacheCanGroup }

    catch {array unset rbe2CandidateByComp}
    array set rbe2CandidateByComp {}

    set marked [RB2W::rbe2CandidateMarkIds]
    if {![lindex $marked 0]} {
        set rbe2MarkCacheGrouped 1
        set rbe2MarkCacheCanGroup 0
        return 0
    }

    set candidates [lindex $marked 1]
    set missingCompId 0
    foreach eid $candidates {
        set cid [RB2W::rbe2CandidateComponentId $eid]
        if {$cid eq ""} {
            set missingCompId 1
            break
        }
        lappend rbe2CandidateByComp($cid) $eid
    }

    if {$missingCompId} {
        catch {array unset rbe2CandidateByComp}
        array set rbe2CandidateByComp {}
        set rbe2MarkCacheGrouped 1
        set rbe2MarkCacheCanGroup 0
        return 0
    }

    foreach cid [array names rbe2CandidateByComp] {
        set rbe2CandidateByComp($cid) [RB2W::uniq $rbe2CandidateByComp($cid)]
    }
    set rbe2MarkCacheGrouped 1
    set rbe2MarkCacheCanGroup 1
    return 1
}

proc ::RB2W::rbe2CandidatesFromComponents {compIds} {
    set marked [RB2W::rbe2CandidateMarkIds]
    if {![lindex $marked 0]} { return [list 0 {} [lindex $marked 2]] }

    if {![RB2W::ensureRBE2CandidateComponentIndex]} {
        return [list 0 {} [lindex $marked 2]]
    }

    variable rbe2CandidateByComp
    set out {}
    foreach cid $compIds {
        if {$cid eq ""} { continue }
        if {[info exists rbe2CandidateByComp($cid)]} {
            foreach eid $rbe2CandidateByComp($cid) { lappend out $eid }
        }
        foreach eid [RB2W::getElemsByComp $cid] {
            if {[RB2W::elemLooksLikeRBE2 $eid]} { lappend out $eid }
        }
    }
    return [list 1 [RB2W::uniq $out] [lindex $marked 2]]
}

proc ::RB2W::elemLooksLikeRBE2 {eid} {
    if {![catch {set cfg [hm_getvalue elems id=$eid dataname=config]}] && $cfg ne ""} {
        set u [string toupper "$cfg"]
        if {[string first "RBE2" $u] >= 0 || [string first "RBE3" $u] >= 0 || [string first "RIGID" $u] >= 0} { return 1 }
        if {[RB2W::elemConfigLooksLikePlainShell $cfg]} { return 0 }
    }

    # Fast/fuzzy string checks from common element data names.
    foreach dn {typename solverkeyword solvername cardimage} {
        if {![catch {set v [hm_getvalue elems id=$eid dataname=$dn]}] && $v ne ""} {
            set u [string toupper "$v"]
            if {[string first "RBE2" $u] >= 0 || [string first "RBE3" $u] >= 0 || [string first "RIGID" $u] >= 0} { return 1 }
        }
    }

    # Rigidlink-specific data name fallback.  Shell elements normally do not
    # expose dependentnodesmax; rigidlink/RBE2 elements do.
    if {![catch {set depmax [hm_getvalue elems id=$eid dataname=dependentnodesmax]}] && $depmax ne ""} {
        if {[catch {expr {$depmax > 0}} ok] == 0 && $ok} { return 1 }
    }
    return 0
}

proc ::RB2W::rigidCenterNode {eid} {
    foreach dn {independentnode.id dependentnode.id} {
        if {![catch {set nodeId [hm_getvalue elems id=$eid dataname=$dn]}] && $nodeId ne ""} {
            return $nodeId
        }
    }
    return ""
}

proc ::RB2W::componentHasRBE2 {compId} {
    set fast [RB2W::rbe2CandidatesFromComponents [list $compId]]
    if {[lindex $fast 0]} {
        set ids [lindex $fast 1]
        if {[llength $ids] > 0} { return [list 1 [lindex $ids 0]] }
        return [list 0 ""]
    }

    set elems [RB2W::getElemsByComp $compId]
    foreach e $elems {
        if {[RB2W::elemLooksLikeRBE2 $e]} { return [list 1 $e] }
    }
    return [list 0 ""]
}

proc ::RB2W::outputComponentCandidatesForSource {sourceCompId} {
    variable OUTPUT_COMPONENT_SUFFIX_SCAN_LIMIT
    set base [RB2W::sourceOutputBaseName $sourceCompId]
    set out {}
    if {[RB2W::componentExistsByName $base]} { lappend out $base } else { return $out }
    for {set i 1} {$i <= $OUTPUT_COMPONENT_SUFFIX_SCAN_LIMIT} {incr i} {
        set cand [format "%s_%02d" $base $i]
        if {![RB2W::componentExistsByName $cand]} { break }
        lappend out $cand
    }
    return $out
}

proc ::RB2W::existingRBE2CheckForSource {sourceCompId} {
    variable CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2
    variable CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2

    set srcName [RB2W::getComponentName $sourceCompId]

    if {$CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2} {
        foreach outName [RB2W::outputComponentCandidatesForSource $sourceCompId] {
            set outId [RB2W::componentIdByName $outName]
            if {$outId ne ""} {
                set chk [RB2W::componentHasRBE2 $outId]
                if {[lindex $chk 0]} {
                    return [list 1 "existing output component $outName contains RBE2 element [lindex $chk 1]"]
                }
            }
        }
    }

    if {$CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2} {
        set chk [RB2W::componentHasRBE2 $sourceCompId]
        if {[lindex $chk 0]} {
            return [list 1 "selected source component $srcName contains RBE2 element [lindex $chk 1]"]
        }
    }
    return [list 0 ""]
}

proc ::RB2W::rbe2DependentNodeKey {eid {knownRBE2 0}} {
    if {!$knownRBE2 && ![RB2W::elemLooksLikeRBE2 $eid]} { return "" }
    if {[catch {set allNodes [hm_getvalue elems id=$eid dataname=nodes]}] || [llength $allNodes] == 0} {
        return ""
    }
    set centerNode [RB2W::rigidCenterNode $eid]
    set depNodes {}
    foreach n $allNodes {
        if {$centerNode ne "" && $n == $centerNode} { continue }
        lappend depNodes $n
    }
    if {[llength $depNodes] == 0} { return "" }
    return [::HWFlow::nodeSetKey $depNodes]
}

proc ::RB2W::rbe2RecordForCleanup {eid {knownRBE2 0}} {
    if {!$knownRBE2 && ![RB2W::elemLooksLikeRBE2 $eid]} { return "" }
    if {[catch {set allNodes [hm_getvalue elems id=$eid dataname=nodes]}] || [llength $allNodes] == 0} {
        return ""
    }
    set centerNode [RB2W::rigidCenterNode $eid]
    set depNodes {}
    foreach n $allNodes {
        if {$centerNode ne "" && $n == $centerNode} { continue }
        lappend depNodes $n
    }
    if {[llength $depNodes] == 0} { return "" }
    return [dict create eid $eid key [::HWFlow::nodeSetKey $depNodes] independent $centerNode depNodes $depNodes]
}

proc ::RB2W::indexRBE2InComponent {compId} {
    variable existingRBE2ByDepNodes
    set count 0
    set fast [RB2W::rbe2CandidatesFromComponents [list $compId]]
    if {[lindex $fast 0]} {
        set elems [lindex $fast 1]
        set knownRBE2 1
    } else {
        set elems [RB2W::getElemsByComp $compId]
        set knownRBE2 0
    }
    foreach eid $elems {
        set key [RB2W::rbe2DependentNodeKey $eid $knownRBE2]
        if {$key ne ""} {
            set existingRBE2ByDepNodes($key) $eid
            incr count
        }
    }
    return $count
}

proc ::RB2W::initExistingRBE2IndexForSource {sourceCompId outComp} {
    variable existingRBE2ByDepNodes
    variable CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2
    variable CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2

    catch {array unset existingRBE2ByDepNodes}
    array set existingRBE2ByDepNodes {}

    set compIds {}
    if {$CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2} {
        foreach outName [RB2W::outputComponentCandidatesForSource $sourceCompId] {
            set outId [RB2W::componentIdByName $outName]
            if {$outId ne ""} { lappend compIds $outId }
        }
        if {$outComp ne ""} {
            set outId [RB2W::componentIdByName $outComp]
            if {$outId ne ""} { lappend compIds $outId }
        }
    }
    if {$CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2} {
        lappend compIds $sourceCompId
    }

    array set seen {}
    set count 0
    foreach compId $compIds {
        if {$compId eq "" || [info exists seen($compId)]} { continue }
        set seen($compId) 1
        set count [expr {$count + [RB2W::indexRBE2InComponent $compId]}]
    }
    return $count
}

proc ::RB2W::existingRBE2ForDepNodes {depNodes} {
    variable existingRBE2ByDepNodes
    set key [::HWFlow::nodeSetKey $depNodes]
    if {[info exists existingRBE2ByDepNodes($key)]} {
        return [list 1 $existingRBE2ByDepNodes($key) $key]
    }
    return [list 0 "" $key]
}

proc ::RB2W::rememberRBE2ForDepNodes {depNodes elemIds} {
    variable existingRBE2ByDepNodes
    set elemId [lindex $elemIds 0]
    if {$elemId eq ""} { return }
    set existingRBE2ByDepNodes([::HWFlow::nodeSetKey $depNodes]) $elemId
}

proc ::RB2W::cleanupDuplicateRBE2InOutputComponents {sourceCompId} {
    set compNames [RB2W::outputComponentCandidatesForSource $sourceCompId]
    if {[llength $compNames] == 0} {
        return [dict create components 0 scanned 0 duplicateElems 0 duplicateNodes 0]
    }

    set compIds {}
    foreach compName $compNames {
        set cid [RB2W::componentIdByName $compName]
        if {$cid ne ""} { lappend compIds $cid }
    }
    if {[llength $compIds] == 0} {
        return [dict create components 0 scanned 0 duplicateElems 0 duplicateNodes 0]
    }

    RB2W::resetRBE2CandidateCache
    set fast [RB2W::rbe2CandidatesFromComponents $compIds]
    if {[lindex $fast 0]} {
        set elems [lindex $fast 1]
        set knownRBE2 1
    } else {
        set elems {}
        foreach cid $compIds {
            foreach eid [RB2W::getElemsByComp $cid] { lappend elems $eid }
        }
        set elems [RB2W::uniq $elems]
        set knownRBE2 0
    }

    array set keptByKey {}
    array set keptIndependentByKey {}
    set duplicateElems {}
    set duplicateNodes {}
    set scanned 0
    foreach eid $elems {
        set rec [RB2W::rbe2RecordForCleanup $eid $knownRBE2]
        if {$rec eq ""} { continue }
        incr scanned
        set key [dict get $rec key]
        set independent [dict get $rec independent]
        if {![info exists keptByKey($key)]} {
            set keptByKey($key) $eid
            set keptIndependentByKey($key) $independent
            continue
        }
        lappend duplicateElems $eid
        if {$independent ne "" && $independent != 0 && (![info exists keptIndependentByKey($key)] || $independent ne $keptIndependentByKey($key))} {
            lappend duplicateNodes $independent
        }
    }

    array set protectedNodes {}
    foreach key [array names keptIndependentByKey] {
        set n $keptIndependentByKey($key)
        if {$n ne "" && $n != 0} { set protectedNodes($n) 1 }
    }
    set safeDuplicateNodes {}
    foreach n $duplicateNodes {
        if {![info exists protectedNodes($n)]} { lappend safeDuplicateNodes $n }
    }
    set duplicateNodes $safeDuplicateNodes

    set deletedElems [RB2W::deleteEntitiesByIds {elems elements} $duplicateElems]
    set deletedNodes 0
    if {$deletedElems > 0 && [llength $duplicateNodes] > 0} {
        set duplicateNodes [RB2W::uniq $duplicateNodes]
        set deletedNodes [RB2W::deleteEntitiesByIds {nodes} $duplicateNodes]
    }
    RB2W::resetRBE2CandidateCache

    return [dict create \
        components [llength $compIds] \
        scanned $scanned \
        duplicateElems $deletedElems \
        duplicateNodes $deletedNodes]
}

proc ::RB2W::mergeDuplicateRBE2ForSources {sourceCompIds} {
    set totalComponents 0
    set totalScanned 0
    set totalElems 0
    set totalNodes 0
    foreach sourceCompId [RB2W::uniq $sourceCompIds] {
        set stat [RB2W::cleanupDuplicateRBE2InOutputComponents $sourceCompId]
        set totalComponents [expr {$totalComponents + [dict get $stat components]}]
        set totalScanned [expr {$totalScanned + [dict get $stat scanned]}]
        set totalElems [expr {$totalElems + [dict get $stat duplicateElems]}]
        set totalNodes [expr {$totalNodes + [dict get $stat duplicateNodes]}]
    }
    return [dict create components $totalComponents scanned $totalScanned duplicateElems $totalElems duplicateNodes $totalNodes]
}

proc ::RB2W::runRebuildCleanup {sourceCompIds} {
    set deleted 0
    foreach sourceCompId [RB2W::uniq $sourceCompIds] {
        foreach outName [RB2W::outputComponentCandidatesForSource $sourceCompId] {
            if {[RB2W::deleteComponentByName $outName]} {
                incr deleted
                RB2W::log "Rebuild cleanup: deleted output component $outName"
            }
        }
    }
    RB2W::clearComponentElemCache
    RB2W::resetRBE2CandidateCache
    return $deleted
}

proc ::RB2W::createCenterNode {center outComp} {
    foreach {x y z} $center {}
    RB2W::setCurrentComponent $outComp
    set beforeNode ""
    catch {set beforeNode [hm_latestentityid nodes]}
    *createnode $x $y $z 0 0 0
    if {![catch {set latestNode [hm_latestentityid nodes]}] && $latestNode ne "" && $latestNode != 0 && $latestNode ne $beforeNode} {
        return $latestNode
    }
    set lastInfo [RB2W::getLastCreatedOnMark {nodes} 1]
    set newNodes [lindex $lastInfo 1]
    catch {*clearmark nodes 1}
    if {[llength $newNodes] == 0} { error [::HWFlow::txt "中心节点未创建。" "Center node was not created."] }
    return [lindex $newNodes 0]
}

proc ::RB2W::createRigidLink {centerNode depNodes outComp} {
    variable RIGID_TYPE
    variable RBE2_DOF
    set rigidType [string toupper $RIGID_TYPE]
    set depNodes [RB2W::uniq $depNodes]
    if {[llength $depNodes] < 3} { error [::HWFlow::txt "从属节点数量不足。" "Too few dependent nodes."] }
    set idx [lsearch -exact $depNodes $centerNode]
    if {$idx >= 0} { set depNodes [lreplace $depNodes $idx $idx] }
    RB2W::setCurrentComponent $outComp
    set beforeElem ""
    catch {set beforeElem [hm_latestentityid elems]}
    catch {*clearmark nodes 2}
    eval *createmark nodes 2 $depNodes
    if {$rigidType eq "RBE3"} {
        set dofs {}
        set weights {}
        foreach n $depNodes {
            lappend dofs $RBE2_DOF
            lappend weights 1.0
        }
        eval *createarray [llength $dofs] $dofs
        eval *createdoublearray [llength $weights] $weights
        *rbe3 2 1 [llength $depNodes] 1 [llength $depNodes] $centerNode $RBE2_DOF 1.0
    } else {
        *rigidlink $centerNode 2 $RBE2_DOF
    }
    catch {*clearmark nodes 2}
    if {![catch {set latestElem [hm_latestentityid elems]}] && $latestElem ne "" && $latestElem != 0 && $latestElem ne $beforeElem} {
        return [list $latestElem]
    }
    set lastInfo [RB2W::getLastCreatedOnMark {elems elements} 1]
    set newElems [lindex $lastInfo 1]
    if {[llength $newElems] == 0} {
        set latestElem ""
        if {![catch {set latestElem [hm_latestentityid elems]}] && $latestElem ne "" && $latestElem != 0 && $latestElem ne $beforeElem} {
            set newElems [list $latestElem]
        }
    }
    if {[llength $newElems] == 0} {
        RB2W::log "Warning: created rigidlink for center node $centerNode, but could not capture the new element id for batch organization."
        return {}
    }
    return $newElems
}

proc ::RB2W::isValidHoleLoop {loopDict} {
    variable MIN_HOLE_DIAMETER
    variable MAX_HOLE_DIAMETER
    variable CIRCULARITY_TOL
    variable ALLOW_OVAL_HOLES
    variable MAX_OVAL_AXIS_RATIO
    variable OVAL_RADIAL_FIT_TOL
    variable MIN_HOLE_EDGE_NODES
    variable MAX_HOLE_EDGE_NODES

    if {![dict get $loopDict closed]} { return [list 0 "open/free-edge branch"] }
    set nodes [dict get $loopDict nodes]
    set n [llength $nodes]
    if {$n < $MIN_HOLE_EDGE_NODES} { return [list 0 "too few edge nodes"] }
    if {$n > $MAX_HOLE_EDGE_NODES} { return [list 0 "too many edge nodes"] }
    if {[catch {set g [RB2W::loopGeometry $nodes]} err]} { return [list 0 "geometry error: $err"] }
    set r [lindex $g 1]
    set rel [lindex $g 2]
    set minr [lindex $g 3]
    set maxr [lindex $g 4]
    set shape [RB2W::loopShape $g]
    set axisRatio [dict get $shape axisRatio]
    set dia [expr {2.0 * $r}]
    if {$dia < $MIN_HOLE_DIAMETER || $dia > $MAX_HOLE_DIAMETER} { return [list 0 [format "diameter %.3f out of range" $dia]] }
    if {$rel <= $CIRCULARITY_TOL && $minr > 1.0e-12 && $axisRatio <= (1.0 + 3.0*$CIRCULARITY_TOL)} {
        dict set shape kind circular
        set g [lreplace $g 5 5 $shape]
        return [list 1 $g]
    }
    if {$ALLOW_OVAL_HOLES && $minr > 1.0e-12 && $axisRatio <= $MAX_OVAL_AXIS_RATIO && $rel <= $OVAL_RADIAL_FIT_TOL} {
        dict set shape kind oval
        set g [lreplace $g 5 5 $shape]
        return [list 1 $g]
    }
    if {$ALLOW_OVAL_HOLES} {
        return [list 0 [format "not circular/oval rel=%.4f axisRatio=%.4f" $rel $axisRatio]]
    }
    if {$rel > $CIRCULARITY_TOL} { return [list 0 [format "poor circularity %.4f" $rel]] }
    if {$minr <= 1.0e-12 || $axisRatio > (1.0 + 3.0*$CIRCULARITY_TOL)} { return [list 0 [format "large radius ratio %.4f" $axisRatio]] }
    return [list 1 $g]
}

proc ::RB2W::validateWasherAndGetDepNodes {loopDict seedElems geom} {
    variable INNER_WASHER_NODE_LOOPS
    variable OUTER_RING_CIRCULARITY_TOL
    variable MAX_OVAL_AXIS_RATIO
    variable OUTER_OVAL_RADIAL_FIT_TOL
    variable OUTER_OVAL_AXIS_RATIO_TOL
    variable CENTER_OFFSET_TOL
    variable MIN_WASHER_WIDTH_ABS
    variable MIN_WASHER_WIDTH_RATIO
    variable WASHER_ELEM_COUNT_TOL
    variable MIN_OUTER_NODE_RATIO
    variable MAX_OUTER_NODE_RATIO
    variable MIN_HOLE_EDGE_NODES

    set innerNodes [dict get $loopDict nodes]
    set innerCount [llength $innerNodes]
    set edgeCount [llength [dict get $loopDict edges]]
    set center [lindex $geom 0]
    set innerR [lindex $geom 1]
    set innerShape [RB2W::loopShape $geom]
    if {[dict exists $innerShape kind]} {
        set innerKind [dict get $innerShape kind]
    } else {
        set innerKind circular
    }
    set innerMinR [dict get $innerShape minR]
    set innerMaxR [dict get $innerShape maxR]
    set innerAxisRatio [dict get $innerShape axisRatio]

    if {$INNER_WASHER_NODE_LOOPS < 2} { return [list 0 "invalid parameter: INNER_WASHER_NODE_LOOPS < 2" {}] }
    if {[llength $seedElems] == 0} { return [list 0 "no adjacent shell elements" {}] }
    set minSeedElems [expr {int(ceil($edgeCount * (1.0 - $WASHER_ELEM_COUNT_TOL)))}]
    if {$minSeedElems < 1} { set minSeedElems 1 }
    if {[llength $seedElems] < $minSeedElems} { return [list 0 "incomplete first washer ring" {}] }

    set elemLayerCount [expr {$INNER_WASHER_NODE_LOOPS - 1}]
    set tieElems [RB2W::expandElementLayers $seedElems $elemLayerCount]
    set depNodes [RB2W::nodesFromElems $tieElems]
    set outerNodes [RB2W::listSubtract $depNodes $innerNodes]
    set outerCount [llength $outerNodes]
    if {$outerCount < $MIN_HOLE_EDGE_NODES} { return [list 0 "no valid outer washer node loop" {}] }
    set outerRatio [expr {$outerCount / double($innerCount)}]
    if {$outerRatio < $MIN_OUTER_NODE_RATIO || $outerRatio > $MAX_OUTER_NODE_RATIO} { return [list 0 [format "outer node count abnormal %.2f" $outerRatio] {}] }
    if {[catch {set og [RB2W::loopGeometry $outerNodes]} err]} { return [list 0 "outer washer geometry error: $err" {}] }
    set outerCenter [lindex $og 0]
    set outerR [lindex $og 1]
    set outerRel [lindex $og 2]
    set outerShape [RB2W::loopShape $og]
    set outerMinR [dict get $outerShape minR]
    set outerMaxR [dict get $outerShape maxR]
    set outerAxisRatio [dict get $outerShape axisRatio]
    set centerDev [RB2W::distance3 $center $outerCenter]
    if {$outerR <= ($innerR + $MIN_WASHER_WIDTH_ABS) && $outerR <= ($innerR * (1.0 + $MIN_WASHER_WIDTH_RATIO))} { return [list 0 [format "washer width too small inner=%.3f outer=%.3f" $innerR $outerR] {}] }
    if {$innerKind eq "oval"} {
        if {$outerMinR <= $innerMinR || $outerMaxR <= $innerMaxR} {
            return [list 0 [format "oval washer not outside inner loop innerMinMax=%.3f/%.3f outerMinMax=%.3f/%.3f" $innerMinR $innerMaxR $outerMinR $outerMaxR] {}]
        }
        if {$outerRel > $OUTER_OVAL_RADIAL_FIT_TOL} {
            return [list 0 [format "outer oval washer irregular rel=%.4f" $outerRel] {}]
        }
        if {$outerAxisRatio > ($MAX_OVAL_AXIS_RATIO * (1.0 + $OUTER_OVAL_AXIS_RATIO_TOL))} {
            return [list 0 [format "outer oval axis ratio too large %.4f" $outerAxisRatio] {}]
        }
        if {$innerAxisRatio > 1.0e-12} {
            set axisDev [expr {abs($outerAxisRatio - $innerAxisRatio) / $innerAxisRatio}]
            if {$axisDev > $OUTER_OVAL_AXIS_RATIO_TOL} {
                return [list 0 [format "outer oval axis ratio mismatch inner=%.4f outer=%.4f" $innerAxisRatio $outerAxisRatio] {}]
            }
        }
    } elseif {$outerRel > $OUTER_RING_CIRCULARITY_TOL} {
        return [list 0 [format "outer ring not washer-like %.4f" $outerRel] {}]
    }
    if {$innerR > 1.0e-12 && ($centerDev / $innerR) > $CENTER_OFFSET_TOL} { return [list 0 [format "outer ring center offset %.4f" [expr {$centerDev / $innerR}]] {}] }
    if {[llength $depNodes] <= [llength $innerNodes]} { return [list 0 "only inner free-edge nodes" {}] }
    set info [dict create depNodes $depNodes tieElems $tieElems outerNodes $outerNodes outerR $outerR outerRel $outerRel outerCount $outerCount outerAxisRatio $outerAxisRatio shape $innerKind]
    return [list 1 "ok" $info]
}

proc ::RB2W::processComponent {compId {compIndex 1} {compTotal 1}} {
    variable RIGID_TYPE
    variable LOG_EACH_CREATED
    variable LOG_EACH_SKIPPED
    variable PROGRESS_LOOP_STEP
    variable UI_UPDATE_STEP
    variable BATCH_ORGANIZE_RBE2
    variable PERFORMANCE_MODE
    set rigidType [string toupper $RIGID_TYPE]

    RB2W::clearNodeXYZCache
    array set reasons {}
    set elems [RB2W::getElemsByComp $compId]
    if {[llength $elems] == 0} {
        RB2W::log "Component $compId: no elements found, skipped."
        return [list 0 0 0 0]
    }

    set t0 [clock milliseconds]
    RB2W::buildGraph $elems
    set loops [RB2W::findFreeEdgeLoops]
    set tGraph [expr {[clock milliseconds] - $t0}]
    set tIndex 0
    set tCreate 0

    set created 0; set skipped 0; set candidateHoles 0
    set createdRBE2Elems {}
    set outComp ""
    set outCompReady 0
    set compName [RB2W::getComponentName $compId]
    set loopTotal [llength $loops]
    RB2W::log "Component $compId ($compName): elems=[llength $elems], freeEdgeLoops=$loopTotal, graphTime=${tGraph}ms"
    set overallPct0 [expr {100.0 * (($compIndex - 1) / double($compTotal))}]
    RB2W::overallStatus $overallPct0 $compIndex $compTotal $compName 0 $loopTotal $candidateHoles $created $skipped 1

    set loopIndex 0
    foreach loop $loops {
        incr loopIndex
        if {$loopIndex == 1 || ($PROGRESS_LOOP_STEP > 0 && ($loopIndex % $PROGRESS_LOOP_STEP) == 0) || $loopIndex == $loopTotal} {
            if {$loopTotal > 0} { set compFrac [expr {$loopIndex / double($loopTotal)}] } else { set compFrac 1.0 }
            set overallPct [expr {100.0 * (($compIndex - 1 + $compFrac) / double($compTotal))}]
            RB2W::overallStatus $overallPct $compIndex $compTotal $compName $loopIndex $loopTotal $candidateHoles $created $skipped [expr {$loopIndex == $loopTotal}]
        }
        if {!$PERFORMANCE_MODE && $UI_UPDATE_STEP > 0 && ($loopIndex % $UI_UPDATE_STEP) == 0} { catch {update} }

        set validInfo [RB2W::isValidHoleLoop $loop]
        if {![lindex $validInfo 0]} {
            incr skipped
            RB2W::bumpReason reasons [lindex $validInfo 1]
            if {$LOG_EACH_SKIPPED} { RB2W::log "Component $compId: skipped loop, reason=[lindex $validInfo 1]" }
            continue
        }
        incr candidateHoles
        set geom [lindex $validInfo 1]
        set center [lindex $geom 0]
        set radius [lindex $geom 1]
        set rel [lindex $geom 2]
        set innerShape [RB2W::loopShape $geom]
        if {[dict exists $innerShape kind]} {
            set shapeKind [dict get $innerShape kind]
        } else {
            set shapeKind circular
        }
        set innerAxisRatio [dict get $innerShape axisRatio]
        set seedElems [RB2W::seedElemsFromLoop [dict get $loop edges]]
        set washerInfo [RB2W::validateWasherAndGetDepNodes $loop $seedElems $geom]
        if {![lindex $washerInfo 0]} {
            incr skipped
            RB2W::bumpReason reasons [lindex $washerInfo 1]
            if {$LOG_EACH_SKIPPED} { RB2W::log "Component $compId: skipped candidate hole D=[format %.3f [expr {2.0*$radius}]], reason=[lindex $washerInfo 1]" }
            continue
        }
        set wdict [lindex $washerInfo 2]
        set depNodes [dict get $wdict depNodes]
        set outerR [dict get $wdict outerR]
        set outerRel [dict get $wdict outerRel]
        set outerCount [dict get $wdict outerCount]
        set outerAxisRatio [dict get $wdict outerAxisRatio]

        if {$outComp eq ""} {
            set outComp [RB2W::sanitizeNamePart [RB2W::sourceOutputBaseName $compId] "AUTO_RBE2"]
            set tIdx0 [clock milliseconds]
            set indexed [RB2W::initExistingRBE2IndexForSource $compId $outComp]
            set tIndex [expr {$tIndex + ([clock milliseconds] - $tIdx0)}]
            if {$indexed > 0} {
                RB2W::log "Component $compId: indexed existing RIGIDS elements for object-level safety check: $indexed"
            }
        }
        set existing [RB2W::existingRBE2ForDepNodes $depNodes]
        if {[lindex $existing 0]} {
            incr skipped
            RB2W::bumpReason reasons "existing RIGIDS for washer hole"
            if {$LOG_EACH_SKIPPED} {
                RB2W::log "Component $compId: skipped existing RIGIDS element [lindex $existing 1] for candidate hole D=[format %.3f [expr {2.0*$radius}]]"
            }
            continue
        }
        if {!$outCompReady} {
            set outComp [RB2W::ensureOutputComponent $compId]
            set outCompReady 1
        }
        if {[catch {
            set tCreate0 [clock milliseconds]
            set cnode [RB2W::createCenterNode $center $outComp]
            set rbeElems [RB2W::createRigidLink $cnode $depNodes $outComp]
            set tCreate [expr {$tCreate + ([clock milliseconds] - $tCreate0)}]
            RB2W::rememberRBE2ForDepNodes $depNodes $rbeElems
            if {$BATCH_ORGANIZE_RBE2} {
                foreach re $rbeElems { lappend createdRBE2Elems $re }
            } else {
                catch {*clearmark elems 1}
                if {[llength $rbeElems] > 0} {
                    eval *createmark elems 1 $rbeElems
                    RB2W::moveMarkToComponent {elems elements} 1 $outComp
                    catch {*clearmark elems 1}
                }
            }
        } err]} {
            incr skipped
            RB2W::bumpReason reasons "create $rigidType failed"
            RB2W::log "Component $compId: failed at D=[format %.3f [expr {2.0*$radius}]], reason=$err"
            continue
        }

        incr created
        if {$LOG_EACH_CREATED} {
            RB2W::log "Component $compId: $rigidType #$created created in $outComp, centerNode=$cnode, rigidElems=$rbeElems, depNodes=[llength $depNodes], innerNodes=[llength [dict get $loop nodes]], outerNodes=$outerCount, shape=$shapeKind, innerD=[format %.3f [expr {2.0*$radius}]], outerD=[format %.3f [expr {2.0*$outerR}]], innerRel=[format %.4f $rel], outerRel=[format %.4f $outerRel], innerAxisRatio=[format %.4f $innerAxisRatio], outerAxisRatio=[format %.4f $outerAxisRatio]"
        }
    }

    set organizeMoved 0; set tOrganize 0
    if {$BATCH_ORGANIZE_RBE2 && [llength $createdRBE2Elems] > 0 && $outComp ne ""} {
        set tOrg0 [clock milliseconds]
        set organizeMoved [RB2W::organizeCreatedRBE2Elements $createdRBE2Elems $outComp]
        set tOrganize [expr {[clock milliseconds] - $tOrg0}]
        set needMove [llength [RB2W::uniq $createdRBE2Elems]]
        if {$organizeMoved < $needMove} { RB2W::log "Warning: component $compId batch-organized $organizeMoved/$needMove RIGIDS element(s) into $outComp." }
    }
    if {!$PERFORMANCE_MODE && $outComp ne "" && $created > 0} {
        RB2W::showOutputComponent $outComp 0
    }

    set totalTime [expr {[clock milliseconds] - $t0}]
    set overallDone [expr {100.0 * ($compIndex / double($compTotal))}]
    RB2W::overallStatus $overallDone $compIndex $compTotal $compName $loopTotal $loopTotal $candidateHoles $created $skipped 1
    RB2W::log "Component $compId ($compName) summary: rigidType=$rigidType, candidates=$candidateHoles, created=$created, skipped=$skipped, existingIndexTime=${tIndex}ms, createTime=${tCreate}ms, organizedRIGIDS=$organizeMoved, organizeTime=${tOrganize}ms, graphTime=${tGraph}ms, totalTime=${totalTime}ms, skipReasons={[RB2W::formatReasonStats reasons]}"
    RB2W::clearNodeXYZCache
    if {$created > 0} { RB2W::resetRBE2CandidateCache }
    return [list $created $skipped $candidateHoles $organizeMoved]
}

proc ::RB2W::printParameterLog {} {
    variable VERSION
    variable MIN_HOLE_DIAMETER; variable MAX_HOLE_DIAMETER; variable CIRCULARITY_TOL
    variable ALLOW_OVAL_HOLES; variable MAX_OVAL_AXIS_RATIO; variable OVAL_RADIAL_FIT_TOL
    variable MIN_HOLE_EDGE_NODES; variable MAX_HOLE_EDGE_NODES; variable INNER_WASHER_NODE_LOOPS
    variable OUTER_RING_CIRCULARITY_TOL; variable CENTER_OFFSET_TOL
    variable OUTER_OVAL_RADIAL_FIT_TOL; variable OUTER_OVAL_AXIS_RATIO_TOL
    variable MIN_WASHER_WIDTH_ABS; variable MIN_WASHER_WIDTH_RATIO; variable WASHER_ELEM_COUNT_TOL
    variable RIGID_TYPE; variable RBE2_DOF; variable RBE2_COMPONENT_PREFIX
    variable BATCH_ORGANIZE_RBE2; variable ORGANIZE_BATCH_SIZE
    variable SHOW_OUTPUT_COMPONENTS; variable FORCE_BROWSER_REFRESH
    variable SKIP_COMPONENT_IF_EXISTING_RBE2; variable CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2; variable CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2
    variable PERFORMANCE_MODE; variable USE_NODE_XYZ_CACHE; variable USE_STATUS_PROGRESS
    variable PROGRESS_LOOP_STEP; variable UI_UPDATE_STEP; variable FORCE_STATUS_UPDATE
    variable STATUS_PERCENT_STEP; variable STATUS_MIN_INTERVAL_MS
    variable FAST_RBE2_MARK_FILTER
    variable LOG_EACH_CREATED; variable LOG_EACH_SKIPPED

    RB2W::log "Version=$VERSION"
    RB2W::log "Parameters: diameter=${MIN_HOLE_DIAMETER}~${MAX_HOLE_DIAMETER}, innerCircTol=$CIRCULARITY_TOL, allowOval=$ALLOW_OVAL_HOLES, maxOvalAxisRatio=$MAX_OVAL_AXIS_RATIO, ovalRadialFitTol=$OVAL_RADIAL_FIT_TOL, edgeNodes=${MIN_HOLE_EDGE_NODES}~${MAX_HOLE_EDGE_NODES}, innerWasherNodeLoops=$INNER_WASHER_NODE_LOOPS, outerCircTol=$OUTER_RING_CIRCULARITY_TOL, outerOvalRadialFitTol=$OUTER_OVAL_RADIAL_FIT_TOL, outerOvalAxisRatioTol=$OUTER_OVAL_AXIS_RATIO_TOL, centerOffsetTol=$CENTER_OFFSET_TOL, minWasherWidthAbs=$MIN_WASHER_WIDTH_ABS, minWasherWidthRatio=$MIN_WASHER_WIDTH_RATIO, washerElemCountTol=$WASHER_ELEM_COUNT_TOL, rigidType=$RIGID_TYPE, dof=$RBE2_DOF, outputPrefix=$RBE2_COMPONENT_PREFIX, batchOrganizeRIGIDS=$BATCH_ORGANIZE_RBE2, organizeBatchSize=$ORGANIZE_BATCH_SIZE, showOutputComponents=$SHOW_OUTPUT_COMPONENTS, browserRefresh=$FORCE_BROWSER_REFRESH"
    RB2W::log "Safety: skipIfExistingRBE2=$SKIP_COMPONENT_IF_EXISTING_RBE2, checkSource=$CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2, checkOutput=$CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2"
    RB2W::log "Performance: performanceMode=$PERFORMANCE_MODE, nodeXYZCache=$USE_NODE_XYZ_CACHE, statusProgress=$USE_STATUS_PROGRESS, progressStep=$PROGRESS_LOOP_STEP, uiUpdateStep=$UI_UPDATE_STEP, forceStatusUpdate=$FORCE_STATUS_UPDATE, statusPercentStep=$STATUS_PERCENT_STEP, statusMinIntervalMs=$STATUS_MIN_INTERVAL_MS, fastRBE2MarkFilter=$FAST_RBE2_MARK_FILTER, logEachCreated=$LOG_EACH_CREATED, logEachSkipped=$LOG_EACH_SKIPPED"
}

proc ::RB2W::main {} {
    if {![::RB2W::showPanel]} {
        return
    }
    ::RB2W::runCurrentSelection
}

proc ::RB2W::runCurrentSelection {} {
    variable outputCompBySource
    variable currentComponentName
    variable RIGID_TYPE
    variable SKIP_COMPONENT_IF_EXISTING_RBE2
    variable PERFORMANCE_MODE
    variable ui

    set currentComponentName ""
    catch {array unset outputCompBySource}
    array set outputCompBySource {}
    RB2W::clearComponentElemCache
    RB2W::resetRBE2CandidateCache

    set runStart [clock milliseconds]
    if {![info exists ui(action)] || $ui(action) eq ""} { set ui(action) create }
    set action $ui(action)
    set rigidType [string toupper $RIGID_TYPE]
    RB2W::log [::HWFlow::txt "==== Shell Washer-Hole RIGIDS started, action=$action, type=$rigidType ====" "==== Shell Washer-Hole RIGIDS started, action=$action, type=$rigidType ===="]
    RB2W::printParameterLog
    RB2W::log [::HWFlow::txt "开始处理界面中选择的壳单元组件。" "Start processing shell components selected in the panel."]

    set comps [RB2W::uniq $ui(selectedComps)]
    RB2W::log "Selected components=[llength $comps]: $comps"

    if {$action eq "merge_nodes"} {
        set procCode [catch {
            RB2W::beginPerformanceMode
            set mergeStat [RB2W::mergeDuplicateRBE2ForSources $comps]
            RB2W::endPerformanceMode
        } procErr procOpts]
        if {$procCode} {
            catch {RB2W::endPerformanceMode}
            RB2W::log [::HWFlow::txt "合并重复节点失败：$procErr" "Merge duplicate nodes failed: $procErr"]
            tk_messageBox -icon error -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "合并重复节点失败：\n$procErr" "Merge duplicate nodes failed:\n$procErr"]
            return -options $procOpts $procErr
        }
        set runMs [expr {[clock milliseconds] - $runStart}]
        set msg [::HWFlow::txt "合并重复节点完成。\n选择组件数：[llength $comps]\n扫描输出组件数：[dict get $mergeStat components]\n扫描 RIGIDS 数：[dict get $mergeStat scanned]\n删除重复 RIGIDS：[dict get $mergeStat duplicateElems]\n删除重复中心节点：[dict get $mergeStat duplicateNodes]\n运行时间：${runMs} ms" "Merge duplicate nodes finished.\nSelected components: [llength $comps]\nOutput components scanned: [dict get $mergeStat components]\nRIGIDS scanned: [dict get $mergeStat scanned]\nDuplicate RIGIDS deleted: [dict get $mergeStat duplicateElems]\nDuplicate center nodes deleted: [dict get $mergeStat duplicateNodes]\nRun time: ${runMs} ms"]
        RB2W::log [::HWFlow::txt "==== 合并重复节点完成：删除重复 RIGIDS=[dict get $mergeStat duplicateElems]，删除重复中心节点=[dict get $mergeStat duplicateNodes]，运行时间=${runMs}ms ====" "==== Merge duplicate nodes finished: duplicate RIGIDS deleted=[dict get $mergeStat duplicateElems], duplicate center nodes deleted=[dict get $mergeStat duplicateNodes], runtime=${runMs}ms ===="]
        RB2W::saveState
        tk_messageBox -icon info -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message $msg
        return
    }

    set totalCreated 0; set totalSkipped 0; set totalCandidates 0; set totalOrganized 0
    set rebuildDeleted 0
    set safetySkipped 0
    set safetyMessages {}
    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] \
            [::HWFlow::txt "准备处理所选组件..." "Preparing selected components..."] \
            0]
    }

    RB2W::beginPerformanceMode
    RB2W::resetOverallProgress
    set procCode [catch {
        if {$action eq "rebuild"} {
            set rebuildDeleted [RB2W::runRebuildCleanup $comps]
            RB2W::log [::HWFlow::txt "重建模式：已删除 $rebuildDeleted 个既有输出组件。" "Rebuild mode: deleted $rebuildDeleted existing output component(s)."]
        }
        set compTotal [llength $comps]
        set compIndex 0
        foreach c $comps {
            incr compIndex
            set cname [RB2W::getComponentName $c]
            if {$SKIP_COMPONENT_IF_EXISTING_RBE2} {
                set check [RB2W::existingRBE2CheckForSource $c]
                if {[lindex $check 0]} {
                    incr safetySkipped
                    set reason [lindex $check 1]
                    lappend safetyMessages "$cname: $reason"
                    RB2W::log [::HWFlow::txt "安全检查跳过：源组件 $c ($cname) 已跳过，原因：$reason。" "Safety skip: source component $c ($cname) skipped because $reason."]
                    set overallDone [expr {100.0 * ($compIndex / double($compTotal))}]
                    RB2W::overallStatus $overallDone $compIndex $compTotal $cname 0 0 0 0 0 1
                    continue
                }
            }
            set result [RB2W::processComponent $c $compIndex $compTotal]
            set totalCreated [expr {$totalCreated + [lindex $result 0]}]
            set totalSkipped [expr {$totalSkipped + [lindex $result 1]}]
            set totalCandidates [expr {$totalCandidates + [lindex $result 2]}]
            set totalOrganized [expr {$totalOrganized + [lindex $result 3]}]
            if {!$PERFORMANCE_MODE} { catch {update} }
        }
    } procErr procOpts]
    RB2W::endPerformanceMode

    if {$procCode} {
        set runMs [expr {[clock milliseconds] - $runStart}]
        RB2W::log [::HWFlow::txt "执行 ${runMs}ms 后发生错误：$procErr" "ERROR after ${runMs}ms: $procErr"]
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "执行中止。" "Run stopped."] 100.0}
        }
        tk_messageBox -icon error -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message [::HWFlow::txt "脚本因错误中止：\n$procErr" "Script stopped because of an error:\n$procErr"]
        return -options $procOpts $procErr
    }

    set runMs [expr {[clock milliseconds] - $runStart}]
    set msg [::HWFlow::txt "Shell Washer-Hole RIGIDS finished.\n模式：$action\n刚性类型：$rigidType\n选择组件数：[llength $comps]\n重建删除输出组件数：$rebuildDeleted\n安全检查跳过组件数：$safetySkipped\n候选孔数量：$totalCandidates\n已创建 $rigidType 数量：$totalCreated\n已归集 RIGIDS 单元数：$totalOrganized\n跳过的环线/候选数量：$totalSkipped\n运行时间：${runMs} ms" "Shell Washer-Hole RIGIDS finished.\nMode: $action\nRigid type: $rigidType\nSelected components: [llength $comps]\nRebuild deleted output components: $rebuildDeleted\nSafety skipped components: $safetySkipped\nCandidate holes: $totalCandidates\nCreated $rigidType: $totalCreated\nOrganized RIGIDS elements: $totalOrganized\nSkipped loops/candidates: $totalSkipped\nRun time: ${runMs} ms"]
    set outSummary [RB2W::outputComponentSummary]
    if {$outSummary ne ""} {
        append msg [::HWFlow::txt "\n\n输出组件：\n$outSummary" "\n\nOutput components:\n$outSummary"]
    }
    if {$safetySkipped > 0} {
        set shown [lrange $safetyMessages 0 4]
        append msg [::HWFlow::txt "\n\n安全检查跳过示例：\n[join $shown \n]" "\n\nSafety skipped examples:\n[join $shown \n]"]
        if {[llength $safetyMessages] > 5} { append msg "\n..." }
    }
    RB2W::status [::HWFlow::txt "RB2W 总进度 100.0% | 已完成 | 组件数=[llength $comps] | 已创建=$totalCreated 安全跳过=$safetySkipped 已跳过=$totalSkipped 候选=$totalCandidates" "RB2W overall 100.0% | finished | components=[llength $comps] | created=$totalCreated safetySkipped=$safetySkipped skipped=$totalSkipped candidates=$totalCandidates"] 1
    RB2W::log [::HWFlow::txt "==== 完成：模式=$action，组件数=[llength $comps]，重建删除=$rebuildDeleted，安全跳过=$safetySkipped，候选=$totalCandidates，已创建=$totalCreated，已归集=$totalOrganized，已跳过=$totalSkipped，运行时间=${runMs}ms ====" "==== Finished: mode=$action, components=[llength $comps], rebuildDeleted=$rebuildDeleted, safetySkipped=$safetySkipped, candidates=$totalCandidates, created=$totalCreated, organized=$totalOrganized, skipped=$totalSkipped, runtime=${runMs}ms ===="]
    RB2W::saveState
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "RB2W 总进度 100.0% | 已完成" "RB2W overall 100.0% | finished"] 100.0}
    }
    tk_messageBox -icon info -title [::HWFlow::txt "Shell Washer-Hole RIGIDS" "Shell Washer-Hole RIGIDS"] -message $msg
}

proc ::RB2W::run {} {
    ::RB2W::main
}

proc ::RB2W::runAction {} {
    variable ui

    ::RB2W::loadState
    foreach key [::RB2W::stateKeys] {
        upvar #0 ::RB2W::$key v
        if {[info exists v]} {
            set ui($key) $v
        }
    }
    set ui(ok) 0
    set ui(action) create
    set ui(selectedComps) ""
    set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]

    ::RB2W::pickComponents
    if {[llength $ui(selectedComps)] == 0} {
        return
    }
    ::RB2W::acceptPanel create
    if {![info exists ui(ok)] || !$ui(ok)} {
        return
    }
    ::RB2W::runCurrentSelection
}

proc ::RB2W::runSettings {} {
    ::RB2W::showPanel 1
}
