# ============================================================================
# Casting Tetra Mesh Workflow
# HyperMesh 2019 Tcl/Tk
#
# Casting-oriented surface cleanup, tria surface mesh, quality iteration and
# optional CFD/tetmesh volume fill.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::CastingTetMesh {
    variable VERSION "0.1"
    variable CONFIG_KEY "casting_tetramesh"
    variable RULE_FILE [file join [::HWFlow::configDir] "casting_mesh_rules.txt"]

    variable DEFAULTS
    array set DEFAULTS {
        ELEM_SIZE 3.0
        MIN_ELEM_SIZE 1.0
        FEATURE_ANGLE 35
        PINHOLE_DIAM 2.0
        FILLET_MIN_R 0.0
        FILLET_MAX_R 1.5
        SHORT_EDGE_LEN 1.0
        MAX_ITER_2D 4
        TET_MODE 1
        QUALITY_ALLOW_UNKNOWN 1
        CLEANUP_GEOMETRY 1
        AUTO_TOPO_CLEANUP 0
        REMOVE_PINHOLES 1
        REMOVE_LINE_FILLETS 1
        REFEATURE_SURFACES 1
        DELETE_SOLIDS 1
        SURFACE_MESH 1
        ITERATE_2D 1
        RUN_TETMESH 1
        RUN_SHELL_CHECK 1
        ORGANIZE_FAILED 0
        PERFORMANCE_MODE 1
        VERBOSE 1
        CRITERIA_FILE ""
        CLEANUP_PARAM_FILE ""
        TET_STRING "tet: 35 1.2 100 0.1 0.0"
        PARS_STRING "pars: pre_cln=1 post_cln=1 shell_validation=1 shell_remesh=0 delauney nlayer_tet=2"
        TET_QUALITY_CRITERIA "tet_collapse 0.1 vol_skew 0.95 aspect_ratio 8"
    }

    variable ui
    array set ui {}
    variable stat
    array set stat {}
}

proc ::CastingTetMesh::defaultRulesText {} {
    return [join {
        {# Casting surface cleanup + tria + CFD/tetra volume mesh defaults.}
        {# Values are read by modules/casting_tetramesh.tcl and can be changed in the UI.}
        {key|value|note}
        {elem_size|3.0|target tria shell element size}
        {min_elem_size|1.0|minimum element size used by cleanup and local repair}
        {feature_angle|35|feature angle used by cleanup/remeshing}
        {pinhole_diam|2.0|pinhole diameter below this value can be removed}
        {fillet_min_r|0.0|minimum line fillet radius to remove}
        {fillet_max_r|1.5|maximum line fillet radius to remove}
        {short_edge_len|1.0|feature line recognition short-edge threshold}
        {max_iter_2d|4|maximum surface mesh quality cleanup iterations}
        {tet_mode|1|1=fixed shell without boundary layer; 2/3 can be used for CFD BL workflows}
        {quality_allow_unknown|1|continue when the installed HyperMesh has no Tcl quality summary API}
        {cleanup_geometry|1|run geometry cleanup steps before surface mesh}
        {auto_topo_cleanup|0|run *autotopocleanup only when criteria/cleanup parameter files are provided}
        {remove_pinholes|1|remove small pinholes from selected surfaces}
        {remove_line_fillets|1|remove small line fillets from selected surfaces}
        {refeature_surfaces|1|rebuild/recognize surface features after cleanup}
        {delete_solids|1|delete selected solid CAD entities but keep boundary surfaces before meshing}
        {surface_mesh|1|run optimized tria surface mesh}
        {iterate_2d|1|attempt failed-element cleanup and remesh iterations}
        {run_tetmesh|1|fill the closed tria surface mesh with tetra elements}
        {run_shell_check|1|run tetmesh shell validation before volume fill}
        {organize_failed|0|move failed shell elements to AUTO_CASTING_FAILED_2D when quality APIs report them}
        {performance_mode|1|block redraw/browser updates while running}
        {criteria_file||optional HyperMesh quality criteria file; empty uses dummy/defaults}
        {cleanup_param_file||optional HyperMesh cleanup parameter file for *autotopocleanup}
        {tet_string|tet: 35 1.2 100 0.1 0.0|raw *tetmesh tet parameter string}
        {pars_string|pars: pre_cln=1 post_cln=1 shell_validation=1 shell_remesh=0 delauney nlayer_tet=2|raw *tetmesh pars parameter string}
        {tet_quality_criteria|tet_collapse 0.1 vol_skew 0.95 aspect_ratio 8|criteria string for hm_getelemchecksummary3d}
    } "\n"]
}

proc ::CastingTetMesh::ensureConfigFiles {} {
    variable RULE_FILE
    if {![file exists $RULE_FILE]} {
        ::HWFlow::writeTextFile $RULE_FILE [::CastingTetMesh::defaultRulesText]
    }
}

proc ::CastingTetMesh::stateKeys {} {
    return {
        ELEM_SIZE MIN_ELEM_SIZE FEATURE_ANGLE PINHOLE_DIAM FILLET_MIN_R FILLET_MAX_R
        SHORT_EDGE_LEN MAX_ITER_2D TET_MODE QUALITY_ALLOW_UNKNOWN CLEANUP_GEOMETRY
        AUTO_TOPO_CLEANUP REMOVE_PINHOLES REMOVE_LINE_FILLETS REFEATURE_SURFACES
        DELETE_SOLIDS SURFACE_MESH ITERATE_2D RUN_TETMESH RUN_SHELL_CHECK
        ORGANIZE_FAILED PERFORMANCE_MODE VERBOSE CRITERIA_FILE CLEANUP_PARAM_FILE
        TET_STRING PARS_STRING TET_QUALITY_CRITERIA
    }
}

proc ::CastingTetMesh::loadRuleFile {} {
    variable RULE_FILE
    variable ui
    if {![file exists $RULE_FILE]} {
        return
    }
    foreach raw [split [::HWFlow::readTextFile $RULE_FILE] "\n"] {
        set line [string trim $raw]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        set cols [split $line "|"]
        if {[llength $cols] < 2} { continue }
        set key [string tolower [string trim [lindex $cols 0]]]
        set val [string trim [lindex $cols 1]]
        switch -- $key {
            elem_size { set ui(ELEM_SIZE) $val }
            min_elem_size { set ui(MIN_ELEM_SIZE) $val }
            feature_angle { set ui(FEATURE_ANGLE) $val }
            pinhole_diam { set ui(PINHOLE_DIAM) $val }
            fillet_min_r { set ui(FILLET_MIN_R) $val }
            fillet_max_r { set ui(FILLET_MAX_R) $val }
            short_edge_len { set ui(SHORT_EDGE_LEN) $val }
            max_iter_2d { set ui(MAX_ITER_2D) $val }
            tet_mode { set ui(TET_MODE) $val }
            quality_allow_unknown { set ui(QUALITY_ALLOW_UNKNOWN) $val }
            cleanup_geometry { set ui(CLEANUP_GEOMETRY) $val }
            auto_topo_cleanup { set ui(AUTO_TOPO_CLEANUP) $val }
            remove_pinholes { set ui(REMOVE_PINHOLES) $val }
            remove_line_fillets { set ui(REMOVE_LINE_FILLETS) $val }
            refeature_surfaces { set ui(REFEATURE_SURFACES) $val }
            delete_solids { set ui(DELETE_SOLIDS) $val }
            surface_mesh { set ui(SURFACE_MESH) $val }
            iterate_2d { set ui(ITERATE_2D) $val }
            run_tetmesh { set ui(RUN_TETMESH) $val }
            run_shell_check { set ui(RUN_SHELL_CHECK) $val }
            organize_failed { set ui(ORGANIZE_FAILED) $val }
            performance_mode { set ui(PERFORMANCE_MODE) $val }
            criteria_file { set ui(CRITERIA_FILE) $val }
            cleanup_param_file { set ui(CLEANUP_PARAM_FILE) $val }
            tet_string { set ui(TET_STRING) $val }
            pars_string { set ui(PARS_STRING) $val }
            tet_quality_criteria { set ui(TET_QUALITY_CRITERIA) $val }
        }
    }
}

proc ::CastingTetMesh::loadState {} {
    variable DEFAULTS
    variable ui
    ::CastingTetMesh::ensureConfigFiles
    foreach key [::CastingTetMesh::stateKeys] {
        set ui($key) $DEFAULTS($key)
    }
    ::CastingTetMesh::loadRuleFile
    set state [::HWFlow::loadState casting_tetramesh]
    foreach key [::CastingTetMesh::stateKeys] {
        if {[dict exists $state $key]} {
            set ui($key) [dict get $state $key]
        }
    }
}

proc ::CastingTetMesh::saveState {} {
    variable ui
    set state [dict create]
    foreach key [::CastingTetMesh::stateKeys] {
        if {[info exists ui($key)]} {
            dict set state $key $ui($key)
        }
    }
    ::HWFlow::saveState casting_tetramesh $state
}

proc ::CastingTetMesh::savePanelState {} {
    ::CastingTetMesh::saveState
}

proc ::CastingTetMesh::msg {text} {
    variable ui
    set line "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] CastingTetMesh: $text"
    if {![info exists ui(VERBOSE)] || $ui(VERBOSE)} {
        puts $line
    }
    catch {hm_usermessage $text}
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend "CastingTetMesh: $text"}
    }
}

proc ::CastingTetMesh::beginPerformanceMode {} {
    variable ui
    if {![info exists ui(PERFORMANCE_MODE)] || !$ui(PERFORMANCE_MODE)} {
        return
    }
    catch {hm_blockredraw 1}
    catch {hm_blockmessages 1}
    catch {hm_blockerrormessages 1}
    catch {*setoption block_redraw=1}
    catch {*setoption block_messages=1}
    catch {hwbrowsermanager view flush false}
    catch {hmbr_signals buffer start}
}

proc ::CastingTetMesh::endPerformanceMode {} {
    variable ui
    if {![info exists ui(PERFORMANCE_MODE)] || !$ui(PERFORMANCE_MODE)} {
        return
    }
    catch {hmbr_signals buffer stop}
    catch {hwbrowsermanager view flush true}
    catch {*setoption block_redraw=0}
    catch {*setoption block_messages=0}
    catch {hm_blockredraw 0}
    catch {hm_blockmessages 0}
    catch {hm_blockerrormessages 0}
}

proc ::CastingTetMesh::uniq {lst} {
    array set seen {}
    foreach x $lst {
        if {$x ne ""} { set seen($x) 1 }
    }
    set out [array names seen]
    if {[catch {set out [lsort -integer $out]}]} {
        set out [lsort $out]
    }
    return $out
}

proc ::CastingTetMesh::numericValue {key} {
    variable ui
    return [expr {double($ui($key))}]
}

proc ::CastingTetMesh::markList {entityTypes markId ids} {
    foreach etype $entityTypes {
        catch {*clearmark $etype $markId}
    }
    if {[llength $ids] == 0} {
        return 0
    }
    foreach etype $entityTypes {
        if {![catch {eval *createmark $etype $markId $ids}]} {
            if {![catch {set got [hm_getmark $etype $markId]}] && [llength $got] > 0} {
                return $etype
            }
        }
    }
    return ""
}

proc ::CastingTetMesh::componentEntityIds {compId entityTypes datanames {markId 2}} {
    foreach dn $datanames {
        if {![catch {set ids [hm_getvalue comps id=$compId dataname=$dn]}] && [llength $ids] > 0} {
            return [::CastingTetMesh::uniq $ids]
        }
    }
    foreach etype $entityTypes {
        catch {*clearmark $etype $markId}
        if {![catch {*createmark $etype $markId "by comp id" $compId}]} {
            if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} {
                catch {*clearmark $etype $markId}
                return [::CastingTetMesh::uniq $ids]
            }
        }
        catch {*clearmark $etype $markId}
    }
    return {}
}

proc ::CastingTetMesh::componentSurfaces {compId} {
    return [::CastingTetMesh::componentEntityIds $compId {surfs surfaces} {surfaces surfs}]
}

proc ::CastingTetMesh::componentSolids {compId} {
    return [::CastingTetMesh::componentEntityIds $compId {solids solid} {solids solid}]
}

proc ::CastingTetMesh::componentElements {compId} {
    return [::CastingTetMesh::componentEntityIds $compId {elems elements} {elems elements}]
}

proc ::CastingTetMesh::selectedSurfaces {compIds} {
    set all {}
    foreach compId $compIds {
        foreach sid [::CastingTetMesh::componentSurfaces $compId] {
            lappend all $sid
        }
    }
    return [::CastingTetMesh::uniq $all]
}

proc ::CastingTetMesh::selectedElements {compIds} {
    set all {}
    foreach compId $compIds {
        foreach eid [::CastingTetMesh::componentElements $compId] {
            lappend all $eid
        }
    }
    return [::CastingTetMesh::uniq $all]
}

proc ::CastingTetMesh::pickComponents {} {
    variable ui
    catch {*clearmark comps 1}
    *createmarkpanel comps 1 [::HWFlow::txt "选择铸件几何组件（含 solid/surf）" "Select casting geometry components (solid/surf)"]
    set comps [hm_getmark comps 1]
    catch {*clearmark comps 1}
    set ui(selectedComps) [::CastingTetMesh::uniq $comps]
    if {[llength $ui(selectedComps)] == 0} {
        set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]
    } else {
        set ui(selectedText) [::HWFlow::txt "已选择 [llength $ui(selectedComps)] 个组件" "Selected [llength $ui(selectedComps)] component(s)"]
    }
    catch {raise .casting_tetramesh}
}

proc ::CastingTetMesh::showRules {} {
    variable RULE_FILE
    ::CastingTetMesh::ensureConfigFiles
    set msg [::HWFlow::txt "当前铸件网格参数文件：\n$RULE_FILE\n\n[::HWFlow::readTextFile $RULE_FILE]" "Current casting mesh rule file:\n$RULE_FILE\n\n[::HWFlow::readTextFile $RULE_FILE]"]
    tk_messageBox -icon info -title [::HWFlow::txt "Casting TetraMesh 参数" "Casting TetraMesh Rules"] -message $msg
}

proc ::CastingTetMesh::browseFile {target title} {
    variable ui
    set initial ""
    if {[info exists ui($target)] && $ui($target) ne ""} {
        set initial [file dirname $ui($target)]
    }
    set path [tk_getOpenFile -title $title -initialdir $initial]
    if {$path ne ""} {
        set ui($target) [file normalize $path]
    }
    catch {raise .casting_tetramesh}
}

proc ::CastingTetMesh::showPanel {} {
    variable ui
    variable VERSION
    ::CastingTetMesh::loadState
    set ui(ok) 0
    set ui(selectedComps) ""
    set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]

    catch {destroy .casting_tetramesh}
    set w .casting_tetramesh
    toplevel $w
    wm title $w "[::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] -font [::HWFlow::uiFont heading]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.sel -text [::HWFlow::txt "1. 组件选择" "1. Component Selection"] -padx 8 -pady 8
    grid $w.main.sel -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    button $w.main.sel.pick -text [::HWFlow::txt "选择/重选铸件组件" "Pick / Repick Casting Components"] -width 24 -command "::CastingTetMesh::pickComponents"
    label $w.main.sel.info -textvariable ::CastingTetMesh::ui(selectedText) -width 72 -anchor w
    grid $w.main.sel.pick -row 0 -column 0 -sticky w -padx {0 8}
    grid $w.main.sel.info -row 0 -column 1 -sticky w

    labelframe $w.main.mesh -text [::HWFlow::txt "2. 网格与微小特征阈值" "2. Mesh and Defeature Thresholds"] -padx 8 -pady 8
    grid $w.main.mesh -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    set fields {
        {ELEM_SIZE "目标三角尺寸" "Target tria size"}
        {MIN_ELEM_SIZE "最小单元尺寸" "Minimum element size"}
        {FEATURE_ANGLE "特征角" "Feature angle"}
        {PINHOLE_DIAM "删除小孔直径" "Pinhole diameter"}
        {FILLET_MAX_R "删除圆角最大 R" "Max fillet R"}
        {SHORT_EDGE_LEN "短边阈值" "Short edge threshold"}
        {MAX_ITER_2D "2D 迭代上限" "2D max iterations"}
        {TET_MODE "TetMesh 模式" "TetMesh mode"}
    }
    set i 0
    foreach item $fields {
        set key [lindex $item 0]
        set label [::HWFlow::txt [lindex $item 1] [lindex $item 2]]
        set r [expr {$i / 2}]
        set c [expr {($i % 2) * 2}]
        label $w.main.mesh.l_$key -text $label -anchor w
        entry $w.main.mesh.e_$key -textvariable ::CastingTetMesh::ui($key) -width 16
        grid $w.main.mesh.l_$key -row $r -column $c -sticky w -padx {0 6} -pady 2
        grid $w.main.mesh.e_$key -row $r -column [expr {$c + 1}] -sticky w -padx {0 18} -pady 2
        incr i
    }

    labelframe $w.main.files -text [::HWFlow::txt "3. Criteria / 参数文件" "3. Criteria / Parameter Files"] -padx 8 -pady 8
    grid $w.main.files -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    label $w.main.files.lcrit -text [::HWFlow::txt "质量 criteria" "Quality criteria"] -anchor w
    entry $w.main.files.ecrit -textvariable ::CastingTetMesh::ui(CRITERIA_FILE) -width 58
    button $w.main.files.bcrit -text "..." -width 3 -command "::CastingTetMesh::browseFile CRITERIA_FILE [list [::HWFlow::txt "选择质量 criteria 文件" "Select quality criteria file"]]"
    label $w.main.files.lclean -text [::HWFlow::txt "清理参数" "Cleanup params"] -anchor w
    entry $w.main.files.eclean -textvariable ::CastingTetMesh::ui(CLEANUP_PARAM_FILE) -width 58
    button $w.main.files.bclean -text "..." -width 3 -command "::CastingTetMesh::browseFile CLEANUP_PARAM_FILE [list [::HWFlow::txt "选择清理参数文件" "Select cleanup parameter file"]]"
    grid $w.main.files.lcrit -row 0 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.files.ecrit -row 0 -column 1 -sticky ew -pady 2
    grid $w.main.files.bcrit -row 0 -column 2 -sticky w -padx {4 0} -pady 2
    grid $w.main.files.lclean -row 1 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.files.eclean -row 1 -column 1 -sticky ew -pady 2
    grid $w.main.files.bclean -row 1 -column 2 -sticky w -padx {4 0} -pady 2
    grid columnconfigure $w.main.files 1 -weight 1

    labelframe $w.main.tet -text [::HWFlow::txt "4. TetraMesh 原始参数" "4. Raw TetraMesh Parameters"] -padx 8 -pady 8
    grid $w.main.tet -row 4 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    label $w.main.tet.ltet -text "tet_string" -anchor w
    entry $w.main.tet.etet -textvariable ::CastingTetMesh::ui(TET_STRING) -width 76
    label $w.main.tet.lpars -text "pars_string" -anchor w
    entry $w.main.tet.epars -textvariable ::CastingTetMesh::ui(PARS_STRING) -width 76
    grid $w.main.tet.ltet -row 0 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.tet.etet -row 0 -column 1 -sticky ew -pady 2
    grid $w.main.tet.lpars -row 1 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.tet.epars -row 1 -column 1 -sticky ew -pady 2
    grid columnconfigure $w.main.tet 1 -weight 1

    labelframe $w.main.opt -text [::HWFlow::txt "5. 执行选项" "5. Options"] -padx 8 -pady 8
    grid $w.main.opt -row 5 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    checkbutton $w.main.opt.del -text [::HWFlow::txt "删除选中组件内 solid，并保留其边界 surface" "Delete selected solid CAD entities and keep boundary surfaces"] -variable ::CastingTetMesh::ui(DELETE_SOLIDS)
    checkbutton $w.main.opt.clean -text [::HWFlow::txt "执行几何清理（小孔/小圆角/特征重识别）" "Run geometry cleanup (pinholes/fillets/refeature)"] -variable ::CastingTetMesh::ui(CLEANUP_GEOMETRY)
    checkbutton $w.main.opt.auto -text [::HWFlow::txt "使用 autotopocleanup 参数文件" "Use autotopocleanup parameter file"] -variable ::CastingTetMesh::ui(AUTO_TOPO_CLEANUP)
    checkbutton $w.main.opt.mesh -text [::HWFlow::txt "生成三角面网格" "Create tria surface mesh"] -variable ::CastingTetMesh::ui(SURFACE_MESH)
    checkbutton $w.main.opt.iter -text [::HWFlow::txt "质量失败时自动清理并迭代重划" "Auto cleanup and remesh failed shell elements"] -variable ::CastingTetMesh::ui(ITERATE_2D)
    checkbutton $w.main.opt.tet -text [::HWFlow::txt "面网格合格后执行 TetraMesh 体填充" "Run TetraMesh volume fill after shell mesh"] -variable ::CastingTetMesh::ui(RUN_TETMESH)
    checkbutton $w.main.opt.shchk -text [::HWFlow::txt "体网格前执行壳网格封闭性/自交检查" "Run shell validation before volume fill"] -variable ::CastingTetMesh::ui(RUN_SHELL_CHECK)
    checkbutton $w.main.opt.unknown -text [::HWFlow::txt "质量 API 不可用时允许继续" "Continue when quality API is unavailable"] -variable ::CastingTetMesh::ui(QUALITY_ALLOW_UNKNOWN)
    checkbutton $w.main.opt.failed -text [::HWFlow::txt "将失败 2D 单元归集到 AUTO_CASTING_FAILED_2D" "Move failed 2D elems to AUTO_CASTING_FAILED_2D"] -variable ::CastingTetMesh::ui(ORGANIZE_FAILED)
    checkbutton $w.main.opt.perf -text [::HWFlow::txt "性能模式：减少图形/浏览器刷新" "Performance mode: reduce graphics/browser updates"] -variable ::CastingTetMesh::ui(PERFORMANCE_MODE)
    checkbutton $w.main.opt.verbose -text [::HWFlow::txt "输出详细日志" "Verbose log"] -variable ::CastingTetMesh::ui(VERBOSE)
    grid $w.main.opt.del -row 0 -column 0 -sticky w -pady 2
    grid $w.main.opt.clean -row 0 -column 1 -sticky w -pady 2
    grid $w.main.opt.auto -row 1 -column 0 -sticky w -pady 2
    grid $w.main.opt.mesh -row 1 -column 1 -sticky w -pady 2
    grid $w.main.opt.iter -row 2 -column 0 -sticky w -pady 2
    grid $w.main.opt.tet -row 2 -column 1 -sticky w -pady 2
    grid $w.main.opt.shchk -row 3 -column 0 -sticky w -pady 2
    grid $w.main.opt.unknown -row 3 -column 1 -sticky w -pady 2
    grid $w.main.opt.failed -row 4 -column 0 -sticky w -pady 2
    grid $w.main.opt.perf -row 4 -column 1 -sticky w -pady 2
    grid $w.main.opt.verbose -row 5 -column 0 -sticky w -pady 2

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 12 -command "::CastingTetMesh::savePanelState; set ::CastingTetMesh::ui(ok) 0; catch {destroy .casting_tetramesh}; catch {::HWToolkit::showHome}"
    button $w.btn.rules -text [::HWFlow::txt "查看参数" "View Rules"] -width 12 -command "::CastingTetMesh::showRules"
    button $w.btn.save -text [::HWFlow::txt "保存配置" "Save Config"] -width 12 -command "::CastingTetMesh::savePanelState"
    button $w.btn.start -text [::HWFlow::txt "开始铸件网格" "Start Casting Mesh"] -width 18 -command "::CastingTetMesh::acceptPanel"
    pack $w.btn.back $w.btn.rules $w.btn.save $w.btn.start -side right -padx 4

    bind $w <Escape> "::CastingTetMesh::savePanelState; set ::CastingTetMesh::ui(ok) 0; destroy .casting_tetramesh"
    wm protocol $w WM_DELETE_WINDOW "::CastingTetMesh::savePanelState; set ::CastingTetMesh::ui(ok) 0; destroy .casting_tetramesh"

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw - $ww) / 2}]+[expr {($sh - $wh) / 2}]
    tkwait window $w
    return $ui(ok)
}

proc ::CastingTetMesh::acceptPanel {} {
    variable ui
    if {[llength $ui(selectedComps)] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] -message [::HWFlow::txt "请先选择铸件组件。" "Pick casting components first."]
        return
    }
    foreach key {ELEM_SIZE MIN_ELEM_SIZE FEATURE_ANGLE PINHOLE_DIAM FILLET_MIN_R FILLET_MAX_R SHORT_EDGE_LEN MAX_ITER_2D TET_MODE} {
        if {![string is double -strict $ui($key)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] -message "$key must be a number."
            return
        }
    }
    foreach key {
        QUALITY_ALLOW_UNKNOWN CLEANUP_GEOMETRY AUTO_TOPO_CLEANUP REMOVE_PINHOLES
        REMOVE_LINE_FILLETS REFEATURE_SURFACES DELETE_SOLIDS SURFACE_MESH ITERATE_2D
        RUN_TETMESH RUN_SHELL_CHECK ORGANIZE_FAILED PERFORMANCE_MODE VERBOSE
    } {
        if {![string is integer -strict $ui($key)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] -message "$key must be 0 or 1."
            return
        }
    }
    if {$ui(ELEM_SIZE) <= 0 || $ui(MIN_ELEM_SIZE) <= 0 || $ui(MAX_ITER_2D) < 1} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] -message [::HWFlow::txt "网格尺寸和迭代参数无效。" "Invalid mesh size or iteration parameters."]
        return
    }
    if {$ui(FILLET_MAX_R) < $ui(FILLET_MIN_R)} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] -message [::HWFlow::txt "圆角半径范围无效。" "Invalid fillet radius range."]
        return
    }
    if {$ui(CRITERIA_FILE) ne "" && ![file exists $ui(CRITERIA_FILE)]} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] -message [::HWFlow::txt "质量 criteria 文件不存在。" "Quality criteria file does not exist."]
        return
    }
    if {$ui(AUTO_TOPO_CLEANUP) && ($ui(CLEANUP_PARAM_FILE) eq "" || ![file exists $ui(CLEANUP_PARAM_FILE)])} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] -message [::HWFlow::txt "启用 autotopocleanup 时必须提供清理参数文件。" "autotopocleanup requires a cleanup parameter file."]
        return
    }
    ::CastingTetMesh::saveState
    set ui(ok) 1
    destroy .casting_tetramesh
}

proc ::CastingTetMesh::criteriaArg {} {
    variable ui
    if {[info exists ui(CRITERIA_FILE)] && $ui(CRITERIA_FILE) ne "" && [file exists $ui(CRITERIA_FILE)]} {
        return $ui(CRITERIA_FILE)
    }
    return "dummy"
}

proc ::CastingTetMesh::deleteSelectedSolids {compIds} {
    variable stat
    set solids {}
    foreach compId $compIds {
        foreach sid [::CastingTetMesh::componentSolids $compId] {
            lappend solids $sid
        }
    }
    set solids [::CastingTetMesh::uniq $solids]
    set stat(deletedSolids) [llength $solids]
    if {[llength $solids] == 0} {
        ::CastingTetMesh::msg [::HWFlow::txt "未发现需要删除的 solid 几何。" "No solid CAD entities found for deletion."]
        return 0
    }
    set markType [::CastingTetMesh::markList {solids solid} 1 $solids]
    if {$markType eq ""} {
        error [::HWFlow::txt "无法标记 solid 几何。" "Cannot mark solid CAD entities."]
    }
    # Plain *deletemark solids removes the boundary surfaces as well. Use the
    # dedicated solid deletion command with keep_shell=1 to preserve surfaces.
    if {[catch {*deletesolidswithelems 1 1 0} err1]} {
        catch {*clearmark $markType 1}
        error [::HWFlow::txt "删除 solid 并保留 surface 失败：$err1" "Deleting solid CAD entities while keeping surfaces failed: $err1"]
    }
    catch {*clearmark $markType 1}
    ::CastingTetMesh::msg [::HWFlow::txt "已删除 solid 几何数量：$stat(deletedSolids)，边界 surface 已保留。" "Deleted solid CAD entities: $stat(deletedSolids); boundary surfaces kept."]
    return $stat(deletedSolids)
}

proc ::CastingTetMesh::markSelectedSurfaces {compIds markId} {
    set surfs [::CastingTetMesh::selectedSurfaces $compIds]
    if {[llength $surfs] == 0} {
        return ""
    }
    return [::CastingTetMesh::markList {surfs surfaces} $markId $surfs]
}

proc ::CastingTetMesh::cleanupGeometry {compIds} {
    variable ui
    variable stat
    set markType [::CastingTetMesh::markSelectedSurfaces $compIds 1]
    if {$markType eq ""} {
        error [::HWFlow::txt "未找到可网格划分的 surface。请确认删除 solid 后仍保留 surface。" "No meshable surfaces found. Confirm surfaces remain after deleting solids."]
    }
    set surfCount [llength [hm_getmark $markType 1]]
    set stat(surfaces) $surfCount

    if {$ui(AUTO_TOPO_CLEANUP)} {
        set crit [::CastingTetMesh::criteriaArg]
        if {[catch {*autotopocleanup 1 $crit $ui(CLEANUP_PARAM_FILE)} err]} {
            ::CastingTetMesh::msg [::HWFlow::txt "autotopocleanup 未完成：$err" "autotopocleanup did not complete: $err"]
        } else {
            ::CastingTetMesh::msg [::HWFlow::txt "autotopocleanup 已执行。" "autotopocleanup finished."]
        }
        set markType [::CastingTetMesh::markSelectedSurfaces $compIds 1]
    }

    if {$ui(REMOVE_PINHOLES) && $ui(PINHOLE_DIAM) > 0} {
        if {[catch {*surfacemarkremoveallpinholes 1 $ui(PINHOLE_DIAM)} err]} {
            ::CastingTetMesh::msg [::HWFlow::txt "小孔删除未完成：$err" "Pinhole cleanup did not complete: $err"]
        } else {
            ::CastingTetMesh::msg [::HWFlow::txt "已按直径阈值清理小孔：$ui(PINHOLE_DIAM)" "Pinhole cleanup finished by diameter threshold: $ui(PINHOLE_DIAM)"]
        }
        set markType [::CastingTetMesh::markSelectedSurfaces $compIds 1]
    }

    if {$ui(REMOVE_LINE_FILLETS) && $ui(FILLET_MAX_R) > 0} {
        catch {*createdoublearray 0}
        if {[catch {*surfacemarkremovelinefillets 1 $ui(FILLET_MIN_R) $ui(FILLET_MAX_R) 0 1 0} err]} {
            ::CastingTetMesh::msg [::HWFlow::txt "小圆角删除未完成：$err" "Line fillet cleanup did not complete: $err"]
        } else {
            ::CastingTetMesh::msg [::HWFlow::txt "已按 R 范围清理小圆角：$ui(FILLET_MIN_R)~$ui(FILLET_MAX_R)" "Line fillet cleanup finished by R range: $ui(FILLET_MIN_R)~$ui(FILLET_MAX_R)"]
        }
        set markType [::CastingTetMesh::markSelectedSurfaces $compIds 1]
    }

    if {$ui(REFEATURE_SURFACES)} {
        if {[catch {*surfacemarkfeatures 1 $ui(FEATURE_ANGLE) -1 1 $ui(FILLET_MIN_R) $ui(FILLET_MAX_R) -1 $ui(SHORT_EDGE_LEN) -1 0} err]} {
            ::CastingTetMesh::msg [::HWFlow::txt "特征重识别未完成：$err" "Surface refeature did not complete: $err"]
        } else {
            ::CastingTetMesh::msg [::HWFlow::txt "已重识别 surface 特征线。" "Surface features rebuilt."]
        }
    }
    catch {*clearmark $markType 1}
}

proc ::CastingTetMesh::meshSurfaceTria {compIds} {
    variable ui
    variable stat
    set markType [::CastingTetMesh::markSelectedSurfaces $compIds 1]
    if {$markType eq ""} {
        error [::HWFlow::txt "未找到 surface，无法生成三角面网格。" "No surfaces found for tria mesh."]
    }
    set crit [::CastingTetMesh::criteriaArg]
    if {[catch {*optimized_mesh 1 $crit $ui(ELEM_SIZE) 0 1 $ui(FEATURE_ANGLE) 0 3 1} err]} {
        catch {*clearmark $markType 1}
        error [::HWFlow::txt "三角面网格生成失败：$err" "Tria surface mesh failed: $err"]
    }
    catch {*clearmark $markType 1}
    incr stat(surfaceMeshRuns)
    ::CastingTetMesh::msg [::HWFlow::txt "三角面网格已生成，第 $stat(surfaceMeshRuns) 次。" "Tria surface mesh run completed: $stat(surfaceMeshRuns)."]
}

proc ::CastingTetMesh::markSelectedElements {compIds markId} {
    set elems [::CastingTetMesh::selectedElements $compIds]
    if {[llength $elems] == 0} {
        return ""
    }
    return [::CastingTetMesh::markList {elems elements} $markId $elems]
}

proc ::CastingTetMesh::check2DQuality {compIds} {
    variable ui
    set markType [::CastingTetMesh::markSelectedElements $compIds 1]
    if {$markType eq ""} {
        return [dict create status no_elements total 0 failed 0 qi "" detail ""]
    }
    catch {*clearmark $markType 2}

    if {![catch {set info [hm_getelementsqualityinfo 1 1 2]} err]} {
        set total ""
        set failed ""
        set qi ""
        if {[llength $info] >= 1} { set total [lindex $info 0] }
        if {[llength $info] >= 2} { set failed [lindex $info 1] }
        if {[llength $info] >= 3} { set qi [lindex $info 2] }
        if {![string is integer -strict $failed]} {
            set failed [llength [hm_getmark $markType 2]]
        }
        if {![string is integer -strict $total]} {
            set total [llength [hm_getmark $markType 1]]
        }
        return [dict create status ok total $total failed $failed qi $qi detail $info]
    }

    set failedMark {}
    set tmp [file join [::HWFlow::configDir] "casting_mesh_quality.tmp"]
    catch {file delete -force $tmp}
    catch {*getqualitysummary 1 $tmp 2 1}
    catch {set failedMark [hm_getmark $markType 2]}
    if {[llength $failedMark] > 0} {
        return [dict create status ok total [llength [hm_getmark $markType 1]] failed [llength $failedMark] qi "" detail "fallback_failed_mark"]
    }
    return [dict create status unknown total [llength [hm_getmark $markType 1]] failed -1 qi "" detail $err]
}

proc ::CastingTetMesh::ensureComponent {name {color 3}} {
    set id [::HWFlow::componentIdByName $name]
    if {$id ne ""} {
        catch {::HWFlow::activateAndShowComponent $name 0}
        return $id
    }
    if {[llength [info commands ::HWFlow::createComponent]] > 0} {
        return [::HWFlow::createComponent $name $color]
    }
    if {[catch {*collectorcreateonly comps $name "" $color} err1]} {
        if {[catch {*collectorcreateonly components $name "" $color} err2]} {
            if {[catch {*createentity comps name=$name} err3]} {
                error [::HWFlow::txt "无法创建组件 $name：$err1 / $err2 / $err3" "Cannot create component $name: $err1 / $err2 / $err3"]
            }
        }
    }
    catch {::HWFlow::activateAndShowComponent $name 1}
    return [::HWFlow::componentIdByName $name]
}

proc ::CastingTetMesh::moveFailed2DToComponent {compName} {
    variable stat
    ::CastingTetMesh::ensureComponent $compName 3
    set moved 0
    foreach etype {elems elements} {
        if {[catch {set failed [hm_getmark $etype 2]}] || [llength $failed] == 0} {
            continue
        }
        if {![catch {*movemark $etype 2 $compName}]} {
            set moved [llength $failed]
            break
        }
    }
    set stat(failedOrganized) [expr {$stat(failedOrganized) + $moved}]
    return $moved
}

proc ::CastingTetMesh::cleanupFailed2DElements {compIds} {
    variable ui
    set markType ""
    foreach etype {elems elements} {
        if {![catch {set failed [hm_getmark $etype 2]}] && [llength $failed] > 0} {
            set markType $etype
            break
        }
    }
    if {$markType eq ""} {
        set markType [::CastingTetMesh::markSelectedElements $compIds 2]
    }
    if {$markType eq ""} {
        return 0
    }
    if {[catch {*hm_failed_elements_cleanup 2 0 $ui(MIN_ELEM_SIZE) $ui(FEATURE_ANGLE) 150} err]} {
        ::CastingTetMesh::msg [::HWFlow::txt "失败单元自动清理未完成：$err" "Failed-element cleanup did not complete: $err"]
        return 0
    }
    ::CastingTetMesh::msg [::HWFlow::txt "已执行失败单元自动清理。" "Failed-element cleanup executed."]
    return 1
}

proc ::CastingTetMesh::run2DQualityLoop {compIds progressOpened} {
    variable ui
    variable stat
    set maxIter [expr {int($ui(MAX_ITER_2D))}]
    set lastFailed -999

    for {set iter 1} {$iter <= $maxIter} {incr iter} {
        if {$ui(SURFACE_MESH)} {
            if {$progressOpened} {
                catch {::HWFlow::progressUpdate [expr {25.0 + 35.0 * ($iter - 1) / double($maxIter)}] [::HWFlow::txt "正在生成三角面网格" "Creating tria surface mesh"] [::HWFlow::txt "2D 迭代 $iter/$maxIter" "2D iteration $iter/$maxIter"] 1}
            }
            ::CastingTetMesh::meshSurfaceTria $compIds
        }

        set q [::CastingTetMesh::check2DQuality $compIds]
        set stat(last2DQuality) $q
        set status [dict get $q status]
        set failed [dict get $q failed]
        set total [dict get $q total]
        if {$status eq "unknown"} {
            ::CastingTetMesh::msg [::HWFlow::txt "无法读取 2D 质量摘要：$q" "Could not read 2D quality summary: $q"]
            if {$ui(QUALITY_ALLOW_UNKNOWN)} {
                return unknown
            }
            error [::HWFlow::txt "2D 质量 API 不可用，且未允许继续。" "2D quality API is unavailable and continuing is disabled."]
        }
        ::CastingTetMesh::msg [::HWFlow::txt "2D 质量检查：总数=$total，失败=$failed" "2D quality check: total=$total, failed=$failed"]
        if {$failed == 0} {
            set stat(failed2D) 0
            return passed
        }
        set stat(failed2D) $failed
        if {$ui(ORGANIZE_FAILED)} {
            ::CastingTetMesh::moveFailed2DToComponent "AUTO_CASTING_FAILED_2D"
        }
        if {!$ui(ITERATE_2D) || $iter >= $maxIter} {
            return failed
        }
        if {$lastFailed >= 0 && $failed >= $lastFailed} {
            ::CastingTetMesh::msg [::HWFlow::txt "失败单元数未下降，停止自动迭代。" "Failed element count did not improve; stopping iteration."]
            return failed
        }
        set lastFailed $failed
        ::CastingTetMesh::cleanupFailed2DElements $compIds
    }
    return failed
}

proc ::CastingTetMesh::createStringArray {strings} {
    set clean {}
    foreach s $strings {
        if {[string trim $s] ne ""} {
            lappend clean $s
        }
    }
    if {[llength $clean] == 0} {
        error "No string-array data provided."
    }
    set cmd [list *createstringarray [llength $clean]]
    foreach s $clean {
        lappend cmd $s
    }
    if {[catch {eval $cmd} err]} {
        error "createstringarray failed: $err"
    }
    return [llength $clean]
}

proc ::CastingTetMesh::runShellValidation {compIds} {
    variable ui
    if {!$ui(RUN_SHELL_CHECK)} {
        return 1
    }
    set markType [::CastingTetMesh::markSelectedElements $compIds 1]
    if {$markType eq ""} {
        error [::HWFlow::txt "没有可用于壳网格检查的 2D 单元。" "No 2D elements available for shell validation."]
    }
    set n [::CastingTetMesh::createStringArray [list "shchk: 2 0.0 0.0"]]
    if {[catch {*tetmesh elems 1 $ui(TET_MODE) elems 0 -1 1 $n} err1]} {
        if {[catch {*tetmesh elements 1 $ui(TET_MODE) elements 0 -1 1 $n} err2]} {
            ::CastingTetMesh::msg [::HWFlow::txt "壳网格预检查未完成：$err1 / $err2" "Shell validation did not complete: $err1 / $err2"]
            return 0
        }
    }
    ::CastingTetMesh::msg [::HWFlow::txt "壳网格预检查已执行。" "Shell validation executed."]
    return 1
}

proc ::CastingTetMesh::runTetMesh {compIds} {
    variable ui
    variable stat
    set markType [::CastingTetMesh::markSelectedElements $compIds 1]
    if {$markType eq ""} {
        error [::HWFlow::txt "没有可用于 TetraMesh 的封闭三角面网格。" "No closed tria shell mesh found for TetraMesh."]
    }
    set strings [list $ui(TET_STRING) $ui(PARS_STRING)]
    set n [::CastingTetMesh::createStringArray $strings]
    if {[catch {*tetmesh elems 1 $ui(TET_MODE) elems 0 -1 1 $n} err1]} {
        if {[catch {*tetmesh elements 1 $ui(TET_MODE) elements 0 -1 1 $n} err2]} {
            error [::HWFlow::txt "TetraMesh 体网格填充失败：$err1 / $err2" "TetraMesh volume fill failed: $err1 / $err2"]
        }
    }
    set stat(tetmeshRuns) [expr {$stat(tetmeshRuns) + 1}]
    ::CastingTetMesh::msg [::HWFlow::txt "TetraMesh 体网格填充已执行。" "TetraMesh volume fill executed."]
}

proc ::CastingTetMesh::check3DQuality {} {
    variable ui
    catch {*clearmark elems 1}
    if {[catch {*createmark elems 1 displayed}]} {
        catch {*createmark elements 1 displayed}
    }
    if {![catch {set summary [hm_getelemchecksummary3d 1 $ui(TET_QUALITY_CRITERIA)]} err]} {
        return $summary
    }
    return [::HWFlow::txt "3D 质量摘要不可用：$err" "3D quality summary unavailable: $err"]
}

proc ::CastingTetMesh::resetStats {} {
    variable stat
    catch {array unset stat}
    array set stat {
        surfaces 0
        deletedSolids 0
        surfaceMeshRuns 0
        tetmeshRuns 0
        failed2D -1
        failedOrganized 0
        last2DQuality ""
        quality3D ""
    }
}

proc ::CastingTetMesh::main {} {
    variable ui
    variable stat
    if {![::CastingTetMesh::showPanel]} {
        return
    }
    ::CastingTetMesh::resetStats

    set comps [::CastingTetMesh::uniq $ui(selectedComps)]
    set runStart [clock milliseconds]
    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] \
            [::HWFlow::txt "准备执行铸件网格流程..." "Preparing casting mesh workflow..."] \
            0]
    }
    if {!$progressOpened} {
        catch {hm_usermessage [::HWFlow::txt "未能创建 Tk 进度窗口，将使用 HyperMesh 状态栏提示。" "Could not create the Tk progress window; using HyperMesh status messages."]}
    } else {
        catch {::HWFlow::progressForceVisible}
    }

    set code [catch {
        ::CastingTetMesh::msg [::HWFlow::txt "==== Casting TetraMesh 开始 ====" "==== Casting TetraMesh started ===="]
        if {$progressOpened} {
            catch {::HWFlow::progressUpdate 5.0 [::HWFlow::txt "正在准备铸件组件" "Preparing casting components"] [::HWFlow::txt "组件数量：[llength $comps]" "Components: [llength $comps]"] 1}
            catch {::HWFlow::progressForceVisible}
        }
        ::CastingTetMesh::beginPerformanceMode

        if {$ui(DELETE_SOLIDS)} {
            if {$progressOpened} {
                catch {::HWFlow::progressUpdate 10.0 [::HWFlow::txt "正在删除 solid" "Deleting solid CAD entities"] "" 1}
            }
            ::CastingTetMesh::deleteSelectedSolids $comps
        }

        if {$ui(CLEANUP_GEOMETRY)} {
            if {$progressOpened} {
                catch {::HWFlow::progressUpdate 18.0 [::HWFlow::txt "正在清理微小几何特征" "Cleaning small geometric features"] "" 1}
            }
            ::CastingTetMesh::cleanupGeometry $comps
        }

        set qualityStatus passed
        if {$ui(SURFACE_MESH)} {
            set qualityStatus [::CastingTetMesh::run2DQualityLoop $comps $progressOpened]
        } else {
            set q [::CastingTetMesh::check2DQuality $comps]
            set stat(last2DQuality) $q
            set qualityStatus [dict get $q status]
        }

        if {$qualityStatus eq "failed"} {
            error [::HWFlow::txt "2D 面网格质量未通过，已停止 TetraMesh。失败单元数：$stat(failed2D)" "2D surface mesh quality failed; TetraMesh stopped. Failed elements: $stat(failed2D)"]
        }

        if {$ui(RUN_TETMESH)} {
            if {$progressOpened} {
                catch {::HWFlow::progressUpdate 72.0 [::HWFlow::txt "正在检查封闭三角壳" "Checking closed tria shell"] "" 1}
            }
            ::CastingTetMesh::runShellValidation $comps
            if {$progressOpened} {
                catch {::HWFlow::progressUpdate 82.0 [::HWFlow::txt "正在执行 TetraMesh 体填充" "Running TetraMesh volume fill"] "" 1}
            }
            ::CastingTetMesh::runTetMesh $comps
            if {$progressOpened} {
                catch {::HWFlow::progressUpdate 92.0 [::HWFlow::txt "正在检查 3D 质量" "Checking 3D quality"] "" 1}
            }
            set stat(quality3D) [::CastingTetMesh::check3DQuality]
        }

        if {$progressOpened} {
            catch {::HWFlow::progressUpdate 98.0 [::HWFlow::txt "正在刷新结果" "Refreshing results"] "" 1}
        }
        ::HWFlow::refreshBrowser
    } err opts]
    ::CastingTetMesh::endPerformanceMode

    set runMs [expr {[clock milliseconds] - $runStart}]
    if {$code} {
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "Casting TetraMesh 执行失败。" "Casting TetraMesh failed."] 100.0}
        }
        tk_messageBox -icon error -title [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] -message [::HWFlow::txt "执行失败：\n$err" "Run failed:\n$err"]
        return -options $opts $err
    }

    set q2d $stat(last2DQuality)
    set q3d $stat(quality3D)
    set msg [::HWFlow::txt "Casting TetraMesh 已完成。\n组件数：[llength $comps]\n删除 solid：$stat(deletedSolids)\nSurface 数：$stat(surfaces)\n三角面网格次数：$stat(surfaceMeshRuns)\n2D 质量状态：$q2d\nTetraMesh 次数：$stat(tetmeshRuns)\n3D 质量摘要：$q3d\n运行时间：${runMs} ms" "Casting TetraMesh finished.\nComponents: [llength $comps]\nDeleted solids: $stat(deletedSolids)\nSurfaces: $stat(surfaces)\nTria mesh runs: $stat(surfaceMeshRuns)\n2D quality: $q2d\nTetraMesh runs: $stat(tetmeshRuns)\n3D quality summary: $q3d\nRun time: ${runMs} ms"]
    ::CastingTetMesh::msg [::HWFlow::txt "==== 完成：组件数=[llength $comps]，三角网格次数=$stat(surfaceMeshRuns)，tet次数=$stat(tetmeshRuns)，运行时间=${runMs}ms ====" "==== Finished: components=[llength $comps], triaRuns=$stat(surfaceMeshRuns), tetRuns=$stat(tetmeshRuns), runtime=${runMs}ms ===="]
    ::CastingTetMesh::saveState
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "Casting TetraMesh 已完成。" "Casting TetraMesh finished."] 100.0}
    }
    tk_messageBox -icon info -title [::HWFlow::txt "Casting TetraMesh" "Casting TetraMesh"] -message $msg
}

proc ::CastingTetMesh::run {} {
    ::CastingTetMesh::main
}
