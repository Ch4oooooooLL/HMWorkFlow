# ======================================================================
# HyperMesh Toolkit - Main Entry
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
            group    "Organize"
            file     "component_workflow"
            label_zh "Component Classification"
            label_en "Component Classification"
            desc_zh  "按 SHELL、SOLID、CASTING 分类组件，并规范化组件名称。"
            desc_en  "Classify components as SHELL, SOLID, or CASTING and normalize component names."
            proc     "::CompWorkflow::runCategory"
        }
        material_assignment {
            group    "Organize"
            file     "component_workflow"
            label_zh "Material Assignment"
            label_en "Material Assignment"
            desc_zh  "从材料库分配材料标识，并按材料装配归类。"
            desc_en  "Assign material keys from the material library and organize material assemblies."
            proc     "::CompWorkflow::runMaterial"
        }
        midsurf {
            group    "Organize"
            label_zh "Midsurface Extraction"
            label_en "Midsurface Extraction"
            desc_zh  "抽取钣金中面，并按 CATEGORY_NAME_Tx_MATERIAL 规则命名输出组件。"
            desc_en  "Extract sheet-metal midsurfaces and name outputs as CATEGORY_NAME_Tx_MATERIAL."
            proc     "::MidSurf::run"
        }
        geometry_cleanup {
            group    "Organize"
            label_zh "Geometry Cleanup: Chamfer/Recess"
            label_en "Geometry Cleanup: Chamfer/Recess"
            desc_zh  "处理倒角、圆角和沉台补面等几何清理任务。"
            desc_en  "Clean chamfers, fillets, and recessed pocket surfaces."
            proc     "::GeomCleanup::run"
        }
        seam_surface {
            group    "Connector"
            label_zh "Seam Surface Creation"
            label_en "Seam Surface Creation"
            desc_zh  "通过线-面或线-线方式创建 SEAM_Tx 焊缝面。"
            desc_en  "Create SEAM_Tx geometry surfaces with Line-Surface or Line-Line workflows."
            proc     "::SeamSurf::run"
        }
        batch_mesh_washer {
            group    "Mesh"
            label_zh "Sheet BatchMesh and Washer"
            label_en "Sheet BatchMesh and Washer"
            desc_zh  "对钣金中面/壳组件执行 BatchMesh，不修改几何，并按孔径标准忽略小孔或生成 washer。"
            desc_en  "Run BatchMesh on sheet-metal midsurface/shell components and create washers by hole rules."
            proc     "::BatchMeshWasher::run"
        }
        casting_tetramesh {
            group    "Mesh"
            label_zh "Casting TetraMesh"
            label_en "Casting TetraMesh"
            desc_zh  "执行铸件 surface 清理、三角面网格质量迭代和 TetraMesh 体网格。"
            desc_en  "Run casting surface cleanup, tria quality iterations, and TetraMesh volume meshing."
            proc     "::CastingTetMesh::run"
        }
        shell_washer_hole_rbe2 {
            group    "Connector"
            label_zh "Shell Washer-Hole RIGIDS"
            label_en "Shell Washer-Hole RIGIDS"
            desc_zh  "识别壳单元 washer 孔，并创建 RIGIDS。"
            desc_en  "Create RIGIDS elements for shell washer holes."
            proc     "::RB2W::run"
        }
        auto_hole_rbe2 {
            group    "Connector"
            label_zh "Solid Through-Hole RIGIDS"
            label_en "Solid Through-Hole RIGIDS"
            desc_zh  "识别实体网格圆柱贯通孔，并创建 RIGIDS。"
            desc_en  "Create RIGIDS elements for cylindrical through-holes in solid meshes."
            proc     "::AutoHoleRBE2::run"
        }
        rbe2_bolt_connector {
            group    "Connector"
            label_zh "RIGIDS Bolt Connector"
            label_en "RIGIDS Bolt Connector"
            desc_zh  "对 RIGIDS 中心节点分组，并生成 CBEAM/CBAR 螺栓连接段。"
            desc_en  "Group RIGIDS elements and create CBEAM/CBAR bolt segments."
            proc     "::RB2Bolt::run"
        }
        contact_setup {
            group    "Connector"
            label_zh "Contact Setup"
            label_en "Contact Setup"
            desc_zh  "选择两个 component，自动识别方向并创建可修剪的接触面。"
            desc_en  "Pick two components, detect their facing direction, and create trimmable contact surfaces."
            proc     "::ContactSetup::run"
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
    foreach group {Organize Mesh Connector} {
        foreach {key info} $MODULES {
            if {[dict get $info group] eq $group} {
                lappend groups $group
                break
            }
        }
    }
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
        "Organize" { return "Organize" }
        "Mesh" { return "Mesh" }
        "Connector" { return "Connector" }
    }
    return $group
}

proc ::HWToolkit::clearExistingWindows {} {
    catch {::CompWorkflow::saveState}
    catch {::MidSurf::savePanelState}
    catch {::AutoHoleRBE2::savePanelState}
    catch {::RB2W::savePanelState}
    catch {::BatchMeshWasher::savePanelState}
    catch {::CastingTetMesh::savePanelState}
    catch {::RB2Bolt::saveState}
    catch {::SeamSurf::savePanelState}
    catch {::GeomCleanup::savePanelState}
    catch {::ContactSetup::savePanelState}

    catch {set ::MidSurf::ui(ok) 0}
    catch {set ::AutoHoleRBE2::ui(ok) 0}
    catch {set ::RB2W::ui(ok) 0}
    catch {set ::CastingTetMesh::ui(ok) 0}
    catch {set ::RB2Bolt::done -1}
    catch {set ::SeamSurf::ui(ok) 0}
    catch {set ::GeomCleanup::ui(ok) 0}
    catch {set ::ContactSetup::ui(ok) 0}
    catch {set ::SeamSurf::ui(promptOk) -1}
    catch {set ::SeamSurf::ui(pickOk) -1}

    foreach w {
        .hwtoolkit
        .hwflow_progress
        .comp_category
        .material_assign
        .material_editor
        .midsurf_dlg
        .autoHoleRBE2
        .rb2w_panel
        .rb2bolt_dlg
        .seam_surface
        .geometry_cleanup
        .contact_setup
        .batch_mesh_washer
        .casting_tetramesh
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
    ::HWFlow::createTopLevel $w
    wm title $w "HyperMesh Toolkit"
    wm resizable $w 0 0

    frame $w.header -padx 12 -pady 10
    pack $w.header -fill x
    label $w.header.title -text "HyperMesh Toolkit" -font [::HWFlow::uiFont header]
    label $w.header.subtitle -text "Preprocessing Utilities" -font [::HWFlow::uiFont default]
    pack $w.header.title -anchor w
    pack $w.header.subtitle -anchor w

    frame $w.body -padx 12 -pady 4
    pack $w.body -fill both -expand 1

    set row 0
    foreach group [::HWToolkit::moduleGroups] {
        labelframe $w.body.g$row -text [::HWToolkit::groupText $group] -padx 8 -pady 6
        grid $w.body.g$row -row $row -column 0 -sticky ew -pady 3
        grid columnconfigure $w.body.g$row 0 -weight 1

        set innerRow 0
        foreach {key info} $MODULES {
            if {[dict get $info group] ne $group} {
                continue
            }
            set labelText [::HWToolkit::moduleText $info label]
            label $w.body.g$row.l_$key -text $labelText -font [::HWFlow::uiFont module] -anchor w
            button $w.body.g$row.b_$key -text [::HWFlow::txt "运行" "Run"] -width 10 -command [list ::HWToolkit::runModule $key]
            grid $w.body.g$row.l_$key -row $innerRow -column 0 -sticky ew -padx {0 18} -pady 3
            grid $w.body.g$row.b_$key -row $innerRow -column 1 -sticky e -pady 3
            incr innerRow
        }
        incr row
    }
    grid columnconfigure $w.body 0 -weight 1

    frame $w.foot -padx 12 -pady 10
    pack $w.foot -fill x
    button $w.foot.refresh -text [::HWFlow::txt "刷新浏览器" "Refresh Browser"] -width 14 -command "::HWToolkit::manualRefreshBrowser"
    button $w.foot.close -text [::HWFlow::txt "退出" "Exit"] -width 10 -command "destroy .hwtoolkit"
    pack $w.foot.close -side right
    pack $w.foot.refresh -side right -padx {0 8}
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
    tkwait window $w
}

proc ::HWToolkit::showHome {} {
    if {[winfo exists .hwtoolkit]} {
        raise .hwtoolkit
        return
    }
    ::HWToolkit::showPanel
}

proc ::HWToolkit::manualRefreshBrowser {} {
    if {[llength [info commands ::HWFlow::refreshBrowser]] > 0} {
        set progressOpened 0
        if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
            set progressOpened [::HWFlow::progressOpen \
                [::HWFlow::txt "刷新浏览器" "Refresh Browser"] \
                [::HWFlow::txt "正在刷新 Model Browser..." "Refreshing Model Browser..."] \
                0]
        }

        if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
            catch {::HWFlow::progressUpdate 10.0 \
                [::HWFlow::txt "正在准备刷新" "Preparing refresh"] \
                [::HWFlow::txt "解除浏览器缓冲并刷新 Model Browser，不改变组件显示/隐藏状态。" "Resetting browser buffers and refreshing Model Browser without changing component visibility."] \
                1}
        }

        set summary [::HWFlow::refreshBrowser 0 0]

        if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
            set touchedCount 0
            if {[dict exists $summary touchedCount]} {
                set touchedCount [dict get $summary touchedCount]
            }
            set modelCount 0
            if {[dict exists $summary modelCount]} {
                set modelCount [dict get $summary modelCount]
            }
            set preview {}
            set previewTotal $modelCount
            set previewSource [::HWFlow::txt "模型 component" "Model components"]
            if {[dict exists $summary touchedComponents]} {
                set preview [lrange [dict get $summary touchedComponents] 0 12]
            }
            if {$touchedCount == 0 && [dict exists $summary modelComponents]} {
                set preview [lrange [dict get $summary modelComponents] 0 12]
                set previewTotal $modelCount
            } elseif {$touchedCount > 0} {
                set previewSource [::HWFlow::txt "脚本记录 component" "Tracked components"]
                set previewTotal $touchedCount
            }
            set detail [::HWFlow::txt "当前模型 component：$modelCount 个；脚本记录 component：$touchedCount 个" "Model components: $modelCount; tracked components: $touchedCount"]
            if {[llength $preview] > 0} {
                append detail "\n${previewSource}:"
                append detail [::HWFlow::txt "\n[join $preview \n]" "\n[join $preview \n]"]
                if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
                    foreach compName $preview {
                        catch {::HWFlow::progressAppend $compName 1}
                    }
                }
                if {$previewTotal > [llength $preview]} {
                    append detail [::HWFlow::txt "\n..." "\n..."]
                }
            } elseif {[llength [info commands ::HWFlow::progressAppend]] > 0} {
                catch {::HWFlow::progressAppend [::HWFlow::txt "未扫描到模型 component。" "No model components found."] 1}
            }
            catch {::HWFlow::progressUpdate 80.0 \
                [::HWFlow::txt "正在整理刷新结果" "Finalizing browser refresh"] \
                $detail \
                1}
        }

        set message [::HWFlow::refreshBrowserSummaryText $summary]
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "浏览器刷新已完成。" "Browser refresh completed."] 100.0}
        }
        if {[llength [info commands tk_messageBox]] > 0} {
            tk_messageBox -icon info -title [::HWFlow::txt "刷新浏览器" "Refresh Browser"] -message $message
        } elseif {[llength [info commands hm_usermessage]] > 0} {
            catch {hm_usermessage $message}
        }
    }
}

proc ::HWToolkit::runModule {key} {
    variable MODULES
    catch {destroy .hwtoolkit}

    set info [dict get $MODULES $key]
    set procName [dict get $info proc]
    set code [catch {uplevel #0 [list $procName]} err opts]
    catch {::HWFlow::refreshBrowser}
    if {$code} {
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
