# ======================================================================
# HyperMesh Toolkit - Core
# HyperMesh 2019 Tcl/Tk
#
# Core definitions for the workflow-oriented Tk GUI. Sourcing this file must
# not open any window.
# ======================================================================

namespace eval ::HWToolkit {
    variable SCRIPT_DIR [file dirname [file normalize [info script]]]
    variable COMMON_MODULES {workflow_common shortcut_manager}
    variable MODULES
    variable SOURCED_FILES {}
    variable MODULE_BUSY 0
    variable QUIET_ERRORS 0

    set MODULES {
        component_category {
            group    "Geometry"
            hidden   1
            file     "component_workflow"
            label_zh "Component Classification"
            label_en "Component Classification"
            desc_zh  "按 SHELL、SOLID、CASTING 分类组件，并规范化组件名称。"
            desc_en  "Classify components as SHELL, SOLID, or CASTING and normalize component names."
            proc     "::CompWorkflow::runCategory"
        }
        material_assignment {
            group    "Geometry"
            hidden   1
            file     "component_workflow"
            label_zh "Material Assignment"
            label_en "Material Assignment"
            desc_zh  "从材料库分配材料标识，并按材料装配归类。"
            desc_en  "Assign material keys from the material library and organize material assemblies."
            proc     "::CompWorkflow::runMaterial"
        }
        midsurf {
            group    "Geometry"
            hidden   1
            label_zh "Midsurface Extraction"
            label_en "Midsurface Extraction"
            desc_zh  "抽取钣金中面，并按 CATEGORY_NAME_Tx_MATERIAL 规则命名输出组件。"
            desc_en  "Extract sheet-metal midsurfaces and name outputs as CATEGORY_NAME_Tx_MATERIAL."
            proc     "::MidSurf::run"
        }
        geometry_cleanup {
            group    "Geometry"
            label_zh "几何清理"
            label_en "Geometry Cleanup: Chamfer/Recess"
            desc_zh  "处理倒角、圆角和沉台补面等几何清理任务。"
            desc_en  "Clean chamfers, fillets, and recessed pocket surfaces."
            proc     "::GeomCleanup::runAction"
            settings_proc "::GeomCleanup::runSettings"
        }
        seam_surface {
            group    "Geometry"
            hidden   1
            label_zh "焊缝面创建"
            label_en "Seam Surface Creation"
            desc_zh  "通过线-面或线-线方式创建 SEAM_Tx 焊缝面。"
            desc_en  "Create SEAM_Tx geometry surfaces with Line-Surface or Line-Line workflows."
            proc     "::SeamSurf::runAction"
            settings_proc "::SeamSurf::runSettings"
        }
        batch_mesh_washer {
            group    "Mesh"
            hidden   1
            label_zh "Sheet BatchMesh and Washer"
            label_en "Sheet BatchMesh and Washer"
            desc_zh  "对钣金中面/壳组件执行 BatchMesh，不修改几何，并按孔径标准忽略小孔或生成 washer。"
            desc_en  "Run BatchMesh on sheet-metal midsurface/shell components and create washers by hole rules."
            proc     "::BatchMeshWasher::run"
        }
        casting_tetramesh {
            group    "Mesh"
            hidden   1
            label_zh "Casting TetraMesh"
            label_en "Casting TetraMesh"
            desc_zh  "执行铸件 surface 清理、三角面网格质量迭代和 TetraMesh 体网格。"
            desc_en  "Run casting surface cleanup, tria quality iterations, and TetraMesh volume meshing."
            proc     "::CastingTetMesh::run"
        }
        mesh_seam_weld {
            group    "Mesh"
            label_zh "网格焊缝"
            label_en "Mesh Seam Weld"
            desc_zh  "选择已有网格节点路径并投影到目标组件，创建焊缝连接带。"
            desc_en  "Select an existing mesh node path, project to target components, and create a weld strip."
            proc     "::MeshSeamWeld::runAction"
            settings_proc "::MeshSeamWeld::runSettings"
        }
        shell_washer_hole_rbe2 {
            group    "Connector"
            label_zh "壳孔 RIGIDS"
            label_en "Shell Washer-Hole RIGIDS"
            desc_zh  "识别壳单元 washer 孔，并创建 RIGIDS。"
            desc_en  "Create RIGIDS elements for shell washer holes."
            proc     "::RB2W::runAction"
            settings_proc "::RB2W::runSettings"
        }
        auto_hole_rbe2 {
            group    "Connector"
            label_zh "实体孔 RIGIDS"
            label_en "Solid Through-Hole RIGIDS"
            desc_zh  "识别实体网格圆柱贯通孔，并创建 RIGIDS。"
            desc_en  "Create RIGIDS elements for cylindrical through-holes in solid meshes."
            proc     "::AutoHoleRBE2::runAction"
            settings_proc "::AutoHoleRBE2::runSettings"
        }
        rbe2_bolt_connector {
            group    "Connector"
            label_zh "螺栓连接"
            label_en "RIGIDS Bolt Connector"
            desc_zh  "对 RIGIDS 中心节点分组，并生成 CBEAM/CBAR 螺栓连接段。"
            desc_en  "Group RIGIDS elements and create CBEAM/CBAR bolt segments."
            proc     "::RB2Bolt::runAction"
            settings_proc "::RB2Bolt::runSettings"
        }
        contact_setup {
            group    "Connector"
            label_zh "接触创建"
            label_en "Contact Setup"
            desc_zh  "选择两个 component，自动识别方向并创建可修剪的接触面。"
            desc_en  "Pick two components, detect their facing direction, and create trimmable contact surfaces."
            proc     "::ContactSetup::runAction"
            settings_proc "::ContactSetup::runSettings"
        }
    }
}

proc ::HWToolkit::moduleVisible {info} {
    if {[dict exists $info hidden] && [dict get $info hidden]} {
        return 0
    }
    return 1
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
    variable QUIET_ERRORS
    set f [::HWToolkit::moduleFile $key $info]
    set norm [file normalize $f]
    if {[lsearch -exact $SOURCED_FILES $norm] >= 0} {
        return 1
    }
    if {![file exists $f]} {
        set msg [::HWFlow::txt "未找到模块文件：\n$f" "Module file not found:\n$f"]
        catch {puts "HMWorkFlow: $msg"}
        if {!$QUIET_ERRORS && [llength [info commands tk_messageBox]] > 0} {
            tk_messageBox -icon error -title [::HWFlow::txt "HW 工作流" "HWToolkit"] -message $msg
        }
        return 0
    }
    if {[catch {uplevel #0 [list source $f]} err]} {
        set msg [::HWFlow::txt "模块 $key 加载失败：\n$err" "Failed to load module $key:\n$err"]
        catch {puts "HMWorkFlow: $msg"}
        if {!$QUIET_ERRORS && [llength [info commands tk_messageBox]] > 0} {
            tk_messageBox -icon error -title [::HWFlow::txt "HW 工作流" "HWToolkit"] -message $msg
        }
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
        if {![::HWToolkit::moduleVisible $info]} {
            continue
        }
        if {![::HWToolkit::sourceOneModule $key $info]} {
            return 0
        }
    }
    return 1
}

proc ::HWToolkit::ensureCoreLoaded {} {
    variable COMMON_MODULES
    foreach key $COMMON_MODULES {
        if {![::HWToolkit::sourceOneModule $key]} {
            return 0
        }
    }
    return 1
}

proc ::HWToolkit::visibleModuleKeys {} {
    variable MODULES
    set out {}
    foreach {key info} $MODULES {
        if {[::HWToolkit::moduleVisible $info]} {
            lappend out $key
        }
    }
    return $out
}

# The home panel may intentionally hide unfinished/advanced tools, but the
# shortcut manager must enumerate the complete tool library so users can
# review, clear, or assign every available module binding.
proc ::HWToolkit::allModuleKeys {} {
    variable MODULES
    set out {}
    foreach {key info} $MODULES {
        lappend out $key
    }
    return $out
}

proc ::HWToolkit::moduleGroups {} {
    variable MODULES
    set groups {}
    foreach group {Geometry Mesh Connector} {
        foreach {key info} $MODULES {
            if {![::HWToolkit::moduleVisible $info]} {
                continue
            }
            if {[dict get $info group] eq $group} {
                lappend groups $group
                break
            }
        }
    }
    foreach {key info} $MODULES {
        if {![::HWToolkit::moduleVisible $info]} {
            continue
        }
        set group [dict get $info group]
        if {[lsearch -exact $groups $group] < 0} {
            lappend groups $group
        }
    }
    return $groups
}

proc ::HWToolkit::groupText {group} {
    switch -- $group {
        "Geometry" { return [::HWFlow::txt "几何" "Geometry"] }
        "Mesh" { return [::HWFlow::txt "网格" "Mesh"] }
        "Connector" { return [::HWFlow::txt "连接" "Connection"] }
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
    catch {::MeshSeamWeld::saveState}
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
        .mesh_seam_weld
        .hwshortcut_manager
        .hwshortcut_capture
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
    wm minsize $w 640 420
    wm resizable $w 1 1

    frame $w.header -padx 12 -pady 10
    pack $w.header -fill x
    label $w.header.title -text "HyperMesh Toolkit" -font [::HWFlow::uiFont header]
    label $w.header.subtitle -text [::HWFlow::txt "按类别选择工具；主入口和模块快捷键均由 HyperMesh 原生快捷键库维护。" "Select a tool by category; main and module shortcuts are maintained in the HyperMesh native key library."] -font [::HWFlow::uiFont default] -justify left -anchor w
    pack $w.header.title -anchor w
    pack $w.header.subtitle -anchor w
    ::HWFlow::bindAutoWrap $w.header.subtitle 40

    frame $w.body -padx 12 -pady 4
    pack $w.body -fill both -expand 1

    if {[llength [info commands ttk::notebook]] == 0} {
        catch {package require tile}
    }
    ttk::notebook $w.body.tabs
    pack $w.body.tabs -fill both -expand 1

    set tabIndex 0
    foreach group {Geometry Mesh Connector} {
        set tabPath $w.body.tabs.tab$tabIndex
        frame $tabPath -padx 8 -pady 8
        $w.body.tabs add $tabPath -text [::HWToolkit::groupText $group]
        grid columnconfigure $tabPath 0 -weight 1
        set innerRow 0
        foreach {key info} $MODULES {
            if {![::HWToolkit::moduleVisible $info]} {
                continue
            }
            if {[dict get $info group] ne $group} {
                continue
            }
            set labelText [::HWToolkit::moduleText $info label]
            frame $tabPath.row_$key
            button $tabPath.row_$key.run -text $labelText -font [::HWFlow::uiFont module] -width 28 -anchor w -command [list ::HWToolkit::runModule $key]
            label $tabPath.row_$key.desc -text [::HWToolkit::moduleText $info desc] -font [::HWFlow::uiFont small] -justify left -anchor w
            ::HWFlow::bindAutoWrap $tabPath.row_$key.desc 340
            button $tabPath.row_$key.settings -text [::HWFlow::txt "设置" "Settings"] -width 10 -command [list ::HWToolkit::settingsModule $key]
            set shortcutText [::HWToolkit::shortcutText $key]
            button $tabPath.row_$key.shortcut -text $shortcutText -width 16 -command [list ::HWShortcut::showForModule $key]
            grid $tabPath.row_$key.run -row 0 -column 0 -sticky nw -padx {0 8}
            grid $tabPath.row_$key.desc -row 0 -column 1 -sticky new -padx {0 8}
            grid $tabPath.row_$key.settings -row 0 -column 2 -sticky n -padx {0 6}
            grid $tabPath.row_$key.shortcut -row 0 -column 3 -sticky n
            grid columnconfigure $tabPath.row_$key 1 -weight 1
            grid $tabPath.row_$key -row $innerRow -column 0 -sticky ew -pady 6
            incr innerRow
        }
        if {$innerRow == 0} {
            label $tabPath.empty -text [::HWFlow::txt "暂无可用工具" "No tools available"] -font [::HWFlow::uiFont default] -anchor center
            grid $tabPath.empty -row 0 -column 0 -sticky ew -pady 18
        }
        incr tabIndex
    }

    frame $w.foot -padx 12 -pady 10
    pack $w.foot -fill x
    button $w.foot.help -text [::HWFlow::txt "查看帮助" "View Help"] -width 14 -command "::HWToolkit::openGuide"
    button $w.foot.shortcuts -text [::HWFlow::txt "快捷键管理" "Shortcuts"] -width 14 -command "::HWShortcut::showManager"
    button $w.foot.close -text [::HWFlow::txt "退出" "Exit"] -width 10 -command "destroy .hwtoolkit"
    pack $w.foot.close -side right
    pack $w.foot.shortcuts -side right -padx {0 8}
    pack $w.foot.help -side right -padx {0 8}
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

proc ::HWToolkit::shortcutText {key} {
    if {[llength [info commands ::HWShortcut::moduleShortcut]] > 0} {
        set value [::HWShortcut::moduleShortcut $key]
        if {$value ne ""} {
            return $value
        }
    }
    return [::HWFlow::txt "未绑定" "Unbound"]
}

proc ::HWToolkit::refreshShortcutDisplays {} {
    variable MODULES
    if {![winfo exists .hwtoolkit]} {
        return
    }
    foreach {key info} $MODULES {
        set widget [lindex [winfo children .hwtoolkit.body.tabs] 0]
        foreach tab [winfo children .hwtoolkit.body.tabs] {
            set row "$tab.row_$key"
            if {[winfo exists $row.shortcut]} {
                catch {$row.shortcut configure -text [::HWToolkit::shortcutText $key]}
            }
        }
    }
}

proc ::HWToolkit::showHome {} {
    if {[winfo exists .hwtoolkit]} {
        raise .hwtoolkit
        return
    }
    ::HWToolkit::showPanel
}

proc ::HWToolkit::openGuide {} {
    variable SCRIPT_DIR

    set guideFile [file join $SCRIPT_DIR "guide.html"]
    if {![file exists $guideFile]} {
        set message [::HWFlow::txt "未找到本地帮助文件：\n$guideFile" "Local help file was not found:\n$guideFile"]
        if {[llength [info commands tk_messageBox]] > 0} {
            tk_messageBox -icon error -title [::HWFlow::txt "查看帮助" "View Help"] -message $message
        } else {
            catch {hm_usermessage $message}
        }
        return 0
    }

    set nativeGuideFile [file nativename $guideFile]
    set code [catch {
        if {$::tcl_platform(platform) eq "windows"} {
            exec cmd.exe /c start "" $nativeGuideFile &
        } elseif {$::tcl_platform(os) eq "Darwin"} {
            exec open $guideFile &
        } else {
            exec xdg-open $guideFile &
        }
    } err]
    if {$code} {
        set message [::HWFlow::txt "无法打开本地帮助网页：\n$nativeGuideFile\n\n$err" "Could not open the local help page:\n$nativeGuideFile\n\n$err"]
        if {[llength [info commands tk_messageBox]] > 0} {
            tk_messageBox -icon error -title [::HWFlow::txt "查看帮助" "View Help"] -message $message
        } else {
            catch {hm_usermessage $message}
        }
        return 0
    }
    return 1
}

proc ::HWToolkit::runModule {key} {
    catch {destroy .hwtoolkit}
    ::HWToolkit::invokeModule $key
}

proc ::HWToolkit::invokeModule {key} {
    variable MODULES
    variable MODULE_BUSY

    if {$MODULE_BUSY} {
        catch {hm_usermessage [::HWFlow::txt "当前已有模块正在运行，请先完成或退出当前操作。" "Another module is already active. Complete or exit it first."]}
        return 0
    }
    if {![dict exists $MODULES $key]} {
        catch {hm_usermessage "HMWorkFlow: unknown module $key"}
        return 0
    }
    set info [dict get $MODULES $key]
    if {![::HWToolkit::ensureCoreLoaded]} {
        return 0
    }
    if {![::HWToolkit::sourceOneModule $key $info]} {
        return 0
    }
    set procName [dict get $info proc]
    if {[llength [info commands $procName]] == 0} {
        set err [::HWFlow::txt "模块入口不存在：$procName" "Module entry does not exist: $procName"]
        catch {hm_usermessage $err}
        catch {puts "HMWorkFlow: $err"}
        return 0
    }

    set MODULE_BUSY 1
    set code [catch {uplevel #0 [list $procName]} err opts]
    set MODULE_BUSY 0
    catch {::HWFlow::refreshBrowser}
    if {$code} {
        catch {puts "HMWorkFlow module $key failed: $err"}
        if {[llength [info commands tk_messageBox]] > 0} {
            tk_messageBox -icon error -title [::HWFlow::txt "HW 工作流" "HWToolkit"] -message [::HWFlow::txt "模块 $key 运行失败：\n$err" "Module $key error:\n$err"]
        } else {
            catch {hm_usermessage [::HWFlow::txt "模块 $key 运行失败。" "Module $key failed."]}
        }
        return 0
    }
    return 1
}

proc ::HWToolkit::settingsModule {key} {
    variable MODULES

    set info [dict get $MODULES $key]
    if {![::HWToolkit::moduleVisible $info]} {
        return
    }
    if {[dict exists $info settings_proc]} {
        set procName [dict get $info settings_proc]
    } else {
        set procName [dict get $info proc]
    }
    set code [catch {uplevel #0 [list $procName]} err opts]
    catch {::HWFlow::refreshBrowser}
    if {$code} {
        tk_messageBox -icon error -title [::HWFlow::txt "HW 工作流" "HWToolkit"] -message [::HWFlow::txt "模块 $key 设置失败：\n$err" "Module $key settings error:\n$err"]
    }
}

proc ::HWToolkit::run {} {
    if {![::HWToolkit::sourceModules]} {
        return
    }
    if {[llength [info commands ::HWShortcut::initialize]] > 0} {
        catch {::HWShortcut::initialize}
    }
    ::HWToolkit::clearExistingWindows
    if {[catch {::HWToolkit::showPanel} err]} {
        tk_messageBox -icon error -title [::HWFlow::txt "HW 工作流" "HWToolkit"] -message [::HWFlow::txt "主面板启动失败：\n$err" "Panel error:\n$err"]
    }
}
