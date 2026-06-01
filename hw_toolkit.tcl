# ======================================================================
# HyperMesh Preprocess Workflow Toolkit - Main Entry
# HyperMesh 2019 Tcl/Tk
#
# Main launcher with a workflow-oriented Tk GUI.
# ======================================================================

namespace eval ::HWToolkit {
    variable SCRIPT_DIR [file dirname [file normalize [info script]]]
    variable COMMON_MODULES {workflow_common}
    variable MODULES
    variable SOURCED_FILES {}

    set MODULES {
        component_category {
            group    "01. Organize"
            file     "component_workflow"
            label_zh "组件类型分类"
            label_en "Component Type Classification"
            desc_zh  "将组件分类为 SHELL、SOLID 或 CASTING，并按类型前缀规范化命名。"
            desc_en  "Classify components into SHELL, SOLID or CASTING and rename them with the category prefix."
            proc     "::CompWorkflow::runCategory"
        }
        material_assignment {
            group    "01. Organize"
            file     "component_workflow"
            label_zh "材料标识分配"
            label_en "Material Assignment"
            desc_zh  "从 TXT 材料库选择材料标识，重命名组件并按材料装配归类。"
            desc_en  "Assign material keys from the TXT library, rename components and organize material assemblies."
            proc     "::CompWorkflow::runMaterial"
        }
        midsurf {
            group    "02. Geometry"
            label_zh "钣金中面抽取"
            label_en "Midsurface Extraction"
            desc_zh  "批量抽取钣金中面，并按 CATEGORY_NAME_Tx_MATERIAL 规则命名输出组件。"
            desc_en  "Extract sheet-metal midsurfaces and name outputs as CATEGORY_NAME_Tx_MATERIAL."
            proc     "::MidSurf::run"
        }
        seam_surface {
            group    "03. Seam"
            label_zh "焊缝面创建"
            label_en "Seam Surface Creation"
            desc_zh  "通过线-面或线-线流程创建 SEAM_Tx 焊缝几何面。"
            desc_en  "Create SEAM_Tx geometry surfaces with Line-Surface or Line-Line workflows."
            proc     "::SeamSurf::run"
        }
        shell_washer_hole_rbe2 {
            group    "04. RBE2"
            label_zh "壳单元垫圈孔 RBE2"
            label_en "Shell Washer-Hole RBE2"
            desc_zh  "识别壳单元标准垫圈孔，并自动创建 RBE2 连接。"
            desc_en  "Create RBE2 elements for shell washer holes."
            proc     "::RB2W::run"
        }
        auto_hole_rbe2 {
            group    "04. RBE2"
            label_zh "实体贯通孔 RBE2"
            label_en "Solid Through-Hole RBE2"
            desc_zh  "识别实体网格圆柱贯通孔，并自动创建 RBE2 连接。"
            desc_en  "Create RBE2 elements for cylindrical through-holes in solid meshes."
            proc     "::AutoHoleRBE2::run"
        }
        rbe2_bolt_connector {
            group    "05. Bolt"
            label_zh "RBE2 螺栓连接生成"
            label_en "RBE2 Bolt Connector"
            desc_zh  "对 RBE2 中心节点分组，并生成 CBEAM/CBAR 螺栓段。"
            desc_en  "Group RBE2 elements and create CBEAM/CBAR bolt segments."
            proc     "::RB2Bolt::run"
        }
    }
}

proc ::HWToolkit::moduleText {info field} {
    set zhKey "${field}_zh"
    set enKey "${field}_en"
    if {[dict exists $info $zhKey] && [dict exists $info $enKey]} {
        return [::HWFlow::txt [dict get $info $zhKey] [dict get $info $enKey]]
    }
    if {[dict exists $info $field]} {
        return [dict get $info $field]
    }
    return ""
}

proc ::HWToolkit::moduleFile {key {info ""}} {
    variable SCRIPT_DIR
    set fileKey $key
    if {$info ne "" && [dict exists $info file]} {
        set fileKey [dict get $info file]
    }
    return [file join $SCRIPT_DIR "modules" "${fileKey}.tcl"]
}

proc ::HWToolkit::sourceOneModule {key {info ""}} {
    variable SOURCED_FILES
    set f [::HWToolkit::moduleFile $key $info]
    set norm [file normalize $f]
    if {[lsearch -exact $SOURCED_FILES $norm] >= 0} {
        return 1
    }
    if {![file exists $f]} {
        tk_messageBox -icon error -title [::HWFlow::txt "HW 工作流" "HWToolkit"] -message [::HWFlow::txt "未找到模块文件：\n$f" "Module file not found:\n$f"]
        return 0
    }
    if {[catch {uplevel #0 [list source $f]} err]} {
        tk_messageBox -icon error -title [::HWFlow::txt "HW 工作流" "HWToolkit"] -message [::HWFlow::txt "模块 $key 加载失败：\n$err" "Failed to load module $key:\n$err"]
        return 0
    }
    lappend SOURCED_FILES $norm
    return 1
}

proc ::HWToolkit::sourceModules {} {
    variable COMMON_MODULES
    variable MODULES
    variable SOURCED_FILES
    set SOURCED_FILES {}

    foreach key $COMMON_MODULES {
        if {![::HWToolkit::sourceOneModule $key]} {
            return 0
        }
    }
    foreach {key info} $MODULES {
        if {![::HWToolkit::sourceOneModule $key $info]} {
            return 0
        }
    }
    return 1
}

proc ::HWToolkit::moduleGroups {} {
    variable MODULES
    set groups {}
    foreach {key info} $MODULES {
        set group [dict get $info group]
        if {[lsearch -exact $groups $group] < 0} {
            lappend groups $group
        }
    }
    return $groups
}

proc ::HWToolkit::groupText {group} {
    switch -- $group {
        "01. Organize" {
            return [::HWFlow::txt "01. 组织与标识" "01. Organize"]
        }
        "02. Geometry" {
            return [::HWFlow::txt "02. 几何处理" "02. Geometry"]
        }
        "03. Seam" {
            return [::HWFlow::txt "03. 焊缝面" "03. Seam"]
        }
        "04. RBE2" {
            return [::HWFlow::txt "04. RBE2 连接" "04. RBE2"]
        }
        "05. Bolt" {
            return [::HWFlow::txt "05. 螺栓连接" "05. Bolt"]
        }
    }
    return $group
}

proc ::HWToolkit::clearExistingWindows {} {
    catch {::CompWorkflow::saveState}
    catch {::MidSurf::savePanelState}
    catch {::AutoHoleRBE2::savePanelState}
    catch {::RB2W::savePanelState}
    catch {::RB2Bolt::saveState}
    catch {::SeamSurf::savePanelState}

    catch {set ::MidSurf::ui(ok) 0}
    catch {set ::MidSurf::ui(promptOk) -1}
    catch {set ::AutoHoleRBE2::ui(ok) 0}
    catch {set ::RB2W::ui(ok) 0}
    catch {set ::RB2Bolt::done -1}
    catch {set ::SeamSurf::ui(ok) 0}
    catch {set ::SeamSurf::ui(promptOk) -1}
    catch {set ::SeamSurf::ui(pickOk) -1}

    foreach w {
        .hwtoolkit
        .hwflow_progress
        .comp_category
        .material_assign
        .material_editor
        .midsurf_dlg
        .midsurf_thick
        .autoHoleRBE2
        .rb2w_panel
        .rb2bolt_dlg
        .seam_surface
        .seam_thickness
        .seam_pick
    } {
        if {[winfo exists $w]} {
            catch {destroy $w}
        }
    }
    catch {update idletasks}
}

proc ::HWToolkit::showPanel {} {
    variable MODULES

    catch {destroy .hwtoolkit}
    set w .hwtoolkit
    toplevel $w
    wm title $w [::HWFlow::txt "HyperMesh 前处理工作流工具集" "HyperMesh Preprocess Workflow Toolkit"]
    wm resizable $w 0 0

    frame $w.header -padx 12 -pady 10
    pack $w.header -fill x
    label $w.header.title -text [::HWFlow::txt "HyperMesh 前处理工作流工具集" "HyperMesh Preprocess Workflow Toolkit"] -font {Arial 14 bold}
    label $w.header.subtitle -text [::HWFlow::txt "面向 HyperMesh 2019 的工程化前处理流程模块" "Workflow modules for HyperMesh 2019 preprocessing"] -font {Arial 9}
    pack $w.header.title -anchor w
    pack $w.header.subtitle -anchor w

    frame $w.body -padx 12 -pady 4
    pack $w.body -fill both -expand 1

    set row 0
    foreach group [::HWToolkit::moduleGroups] {
        labelframe $w.body.g$row -text [::HWToolkit::groupText $group] -padx 8 -pady 8
        grid $w.body.g$row -row $row -column 0 -sticky ew -pady 4
        grid columnconfigure $w.body.g$row 0 -weight 1

        set innerRow 0
        foreach {key info} $MODULES {
            if {[dict get $info group] ne $group} {
                continue
            }
            set labelText [::HWToolkit::moduleText $info label]
            set descText [::HWToolkit::moduleText $info desc]
            label $w.body.g$row.l_$key -text $labelText -font {Arial 9 bold} -anchor w
            message $w.body.g$row.d_$key -text $descText -width 430 -anchor w -font {Arial 9}
            button $w.body.g$row.b_$key -text [::HWFlow::txt "运行" "Run"] -width 10 -command [list ::HWToolkit::runModule $key]
            grid $w.body.g$row.l_$key -row $innerRow -column 0 -sticky w -padx {0 8} -pady {2 0}
            grid $w.body.g$row.b_$key -row $innerRow -column 1 -sticky e -pady {2 0}
            incr innerRow
            grid $w.body.g$row.d_$key -row $innerRow -column 0 -columnspan 2 -sticky w -padx {12 0} -pady {0 6}
            incr innerRow
        }
        incr row
    }
    grid columnconfigure $w.body 0 -weight 1

    frame $w.foot -padx 12 -pady 10
    pack $w.foot -fill x
    button $w.foot.close -text [::HWFlow::txt "退出" "Exit"] -width 10 -command "destroy .hwtoolkit"
    pack $w.foot.close -side right
    bind $w <Escape> "destroy .hwtoolkit"

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw - $ww) / 2}]+[expr {($sh - $wh) / 2}]
    catch {wm deiconify $w}
    catch {raise $w}
    catch {focus -force $w}
    catch {wm attributes $w -topmost 1}
    catch {after 250 [list catch [list wm attributes $w -topmost 0]]}
    tkwait window $w
}

proc ::HWToolkit::showHome {} {
    if {[winfo exists .hwtoolkit]} {
        raise .hwtoolkit
        return
    }
    ::HWToolkit::showPanel
}

proc ::HWToolkit::runModule {key} {
    variable MODULES
    catch {destroy .hwtoolkit}

    set info [dict get $MODULES $key]
    set procName [dict get $info proc]
    if {[catch {uplevel #0 [list $procName]} err]} {
        tk_messageBox -icon error -title [::HWFlow::txt "HW 工作流" "HWToolkit"] -message [::HWFlow::txt "模块 $key 运行失败：\n$err" "Module $key error:\n$err"]
    }
}

proc ::HWToolkit::run {} {
    if {![::HWToolkit::sourceModules]} {
        return
    }
    ::HWToolkit::clearExistingWindows
    if {[catch {::HWToolkit::showPanel} err]} {
        tk_messageBox -icon error -title [::HWFlow::txt "HW 工作流" "HWToolkit"] -message [::HWFlow::txt "主面板启动失败：\n$err" "Panel error:\n$err"]
    }
}

::HWToolkit::run
