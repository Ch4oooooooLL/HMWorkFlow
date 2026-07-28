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
    variable PENDING_SHORTCUT_TARGET ""
    variable PENDING_SHORTCUT_AFTER ""

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
            label_zh "抽中面"
            label_en "Midsurface Extraction"
            desc_zh  "抽取钣金中面，并按与网格焊缝一致的 T<厚度> 规则命名输出组件。"
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
            label_zh "几何焊缝"
            label_en "Geometry Seam"
            desc_zh  "局部识别 T 型、角接和搭接接头，复核策略并安全创建、编辑或删除几何焊缝。"
            desc_en  "Recognize local T, corner, and lap joints, review strategies, and safely create, edit, or delete geometry seams."
            proc     "::SeamSurf::runAction"
            shortcut_proc "::SeamSurf::runShortcut"
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
        batch_property_assignment {
            group    "Mesh"
            label_zh "批量赋予 Property 和材料"
            label_en "Batch Property and Material Assignment"
            desc_zh  "按 Vxx_件号_Txx_材料 / SEAM_Txx 命名批量创建 PSHELL Property，并生成异常名称复核清单。"
            desc_en  "Create and assign PSHELL properties from Vxx_part_Txx_material / SEAM_Txx names and list exceptions for review."
            proc     "::BatchPropertyAssignment::runAction"
        }
        local_mesh_optimizer {
            group    "Mesh"
            label_zh "局部网格优化"
            label_en "Local Mesh Optimizer"
            desc_zh  "根据 criteria 文件，仅对不合格网格区域进行增量优化。"
            desc_en  "Use criteria to incrementally optimize failed mesh regions only."
            proc     "::LocalMeshOptimizer::runAction"
            settings_proc "::LocalMeshOptimizer::runSettings"
        }
        weld_integrity_check {
            group    "Mesh"
            label_zh "网格焊缝完整性检查"
            label_en "Mesh Weld Integrity Check"
            desc_zh  "网格完成后识别可能遗漏焊缝的 Shell Component Pair，并逐组孤立、定位和审查。"
            desc_en  "Detect shell component pairs that may have missing welds, then isolate, locate, and review them."
            proc     "::WeldIntegrityCheck::runAction"
            settings_proc "::WeldIntegrityCheck::runSettings"
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
        cbush_creator {
            group    "Connector"
            label_zh "创建 CBUSH"
            label_en "Create CBUSH"
            desc_zh  "选择一个或多个源节点，分别在全局 Z+5 处创建临时节点，并生成 CBUSH 连接。"
            desc_en  "Select source nodes, create temporary nodes at global Z+5, and connect them with CBUSH."
            proc     "::CBushCreator::runAction"
        }
        contact_setup {
            group    "Connector"
            label_zh "接触创建"
            label_en "Contact Setup"
            desc_zh  "分两次选择相向 Face 单元，并直接创建可修剪的接触面。"
            desc_en  "Pick opposing face elements in two passes and create trimmable contact surfaces directly."
            proc     "::ContactSetup::runAction"
            settings_proc "::ContactSetup::runSettings"
        }
        adhesive_connector {
            group    "Connector"
            label_zh "模型打胶"
            label_en "Adhesive Connector"
            desc_zh  "以 elems 定义 Area location、以 comps 定义 links，清洗越界单元后创建 adhesives。"
            desc_en  "Create Area adhesives from element locations after removing elements outside the linked-component footprint."
            proc     "::AdhesiveConnector::runAction"
            settings_proc "::AdhesiveConnector::runSettings"
        }
        solid_seam_connector {
            group    "Connector"
            label_zh "实体焊缝"
            label_en "Solid Seam Connector"
            desc_zh  "从实体外表面边自动识别焊缝候选，并通过已验证的原生 seam connector profile 创建 PENTA + RBE3。"
            desc_en  "Detect seam candidates on solid exterior edges and create PENTA + RBE3 through verified native connector profiles."
            proc     "::SolidSeam::runAction"
            settings_proc "::SolidSeam::runSettings"
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
    if {[catch {uplevel #0 [list source -encoding utf-8 $f]} err]} {
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
    catch {::AdhesiveConnector::savePanelState}
    catch {::LocalMeshOptimizer::savePanelState}
    catch {::WeldIntegrityCheck::saveConfig}

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

    # hwtk/Tk windows created through the shared factory are authoritative.
    # Keep the legacy path list below for windows created by an older version
    # that may still exist in the same HyperMesh session.
    catch {::HWFlow::destroyManagedWindows}

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
        .geometry_seam
        .geometry_seam_shortcut_selector
        .geometry_seam_thickness
        .geometry_cleanup
        .contact_setup
        .adhesive_connector
        .batch_mesh_washer
        .casting_tetramesh
        .mesh_seam_weld
        .hwshortcut_manager
        .hwshortcut_capture
        .local_mesh_optimizer
        .local_mesh_optimizer_advanced
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
    ::HWFlow::createTopLevel $w main
    wm title $w "HyperMesh Toolkit"
    wm minsize $w 720 620
    wm resizable $w 1 1

    ::HWFlow::uiWidget frame $w.header
    pack $w.header -fill x -padx 12 -pady 10
    ::HWFlow::uiWidget label $w.header.title -text "HyperMesh Toolkit" -font [::HWFlow::uiFont header]
    ::HWFlow::uiWidget label $w.header.subtitle -text [::HWFlow::txt "全部工具按类别平铺展示；主入口和模块快捷键均由 HyperMesh 原生快捷键库维护。" "All tools are shown by category; main and module shortcuts are maintained in the HyperMesh native key library."] -font [::HWFlow::uiFont default] -justify left -anchor w
    pack $w.header.title -anchor w
    pack $w.header.subtitle -anchor w
    ::HWFlow::bindAutoWrap $w.header.subtitle 40

    ::HWFlow::uiWidget frame $w.body
    pack $w.body -fill both -expand 1 -padx 12 -pady 4

    ::HWFlow::uiWidget frame $w.body.modules
    pack $w.body.modules -fill both -expand 1
    grid columnconfigure $w.body.modules 0 -weight 1

    set bodyRow 0
    set groupIndex 0
    foreach group [::HWToolkit::moduleGroups] {
        if {$groupIndex > 0} {
            ::HWFlow::uiWidget separator $w.body.modules.separator_$groupIndex -orient horizontal
            grid $w.body.modules.separator_$groupIndex -row $bodyRow -column 0 -sticky ew -pady {8 6}
            incr bodyRow
        }
        ::HWFlow::uiWidget label $w.body.modules.group_$groupIndex -text [::HWToolkit::groupText $group] -font [::HWFlow::uiFont heading] -anchor w
        grid $w.body.modules.group_$groupIndex -row $bodyRow -column 0 -sticky ew -pady {2 3}
        incr bodyRow

        foreach {key info} $MODULES {
            if {![::HWToolkit::moduleVisible $info]} {
                continue
            }
            if {[dict get $info group] ne $group} {
                continue
            }
            set labelText [::HWToolkit::moduleText $info label]
            set row $w.body.modules.row_$key
            ::HWFlow::uiWidget frame $row
            ::HWFlow::uiWidget button $row.run -text $labelText -font [::HWFlow::uiFont module] -width 28 -anchor w -command [list ::HWToolkit::runModule $key]
            ::HWFlow::uiWidget label $row.desc -text [::HWToolkit::moduleText $info desc] -font [::HWFlow::uiFont small] -justify left -anchor w
            ::HWFlow::bindAutoWrap $row.desc 340
            ::HWFlow::uiWidget button $row.settings -text [::HWFlow::txt "设置" "Settings"] -width 10 -command [list ::HWToolkit::settingsModule $key]
            set shortcutText [::HWToolkit::shortcutText $key]
            ::HWFlow::uiWidget button $row.shortcut -text $shortcutText -width 16 -command [list ::HWShortcut::showForModule $key]
            grid $row.run -row 0 -column 0 -sticky nw -padx {0 8}
            grid $row.desc -row 0 -column 1 -sticky new -padx {0 8}
            grid $row.settings -row 0 -column 2 -sticky n -padx {0 6}
            grid $row.shortcut -row 0 -column 3 -sticky n
            grid columnconfigure $row 1 -weight 1
            grid $row -row $bodyRow -column 0 -sticky ew -pady 4
            incr bodyRow
        }
        incr groupIndex
    }

    ::HWFlow::uiWidget frame $w.foot
    pack $w.foot -fill x -padx 12 -pady 10
    ::HWFlow::uiWidget button $w.foot.help -text [::HWFlow::txt "查看帮助" "View Help"] -width 14 -command "::HWToolkit::openGuide"
    ::HWFlow::uiWidget button $w.foot.diagnostics -text [::HWFlow::txt "复制诊断" "Copy Diagnostics"] -width 14 -command "::HWToolkit::copyDiagnostics"
    ::HWFlow::uiWidget button $w.foot.shortcuts -text [::HWFlow::txt "快捷键管理" "Shortcuts"] -width 14 -command "::HWShortcut::showManager"
    ::HWFlow::uiWidget button $w.foot.close -text [::HWFlow::txt "退出" "Exit"] -width 10 -command "destroy .hwtoolkit"
    pack $w.foot.close -side right
    pack $w.foot.shortcuts -side right -padx {0 8}
    pack $w.foot.diagnostics -side right -padx {0 8}
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
        set row ".hwtoolkit.body.modules.row_$key"
        if {[winfo exists $row.shortcut]} {
            catch {$row.shortcut configure -text [::HWToolkit::shortcutText $key]}
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

proc ::HWToolkit::shortcutLaunchBlocked {} {
    if {[llength [info commands ::HWFlow::progressIsActive]] > 0 &&
        [::HWFlow::progressIsActive]} {
        catch {hm_usermessage [::HWFlow::txt \
            "当前任务仍在执行，不能通过快捷键关闭任务窗口。请先等待完成或请求取消。" \
            "A task is still running. Wait for it to finish or request cancellation before switching tools."]}
        return 1
    }
    return 0
}

# Native key callbacks can arrive while a module proc is suspended in
# `tkwait window`.  Destroy the registered toolkit windows first, then defer
# the requested launch until that nested call stack has unwound and
# MODULE_BUSY has returned to zero.
proc ::HWToolkit::requestShortcutLaunch {target} {
    variable MODULES
    variable PENDING_SHORTCUT_TARGET
    variable PENDING_SHORTCUT_AFTER

    if {$target ne "__toolkit_home__" && ![dict exists $MODULES $target]} {
        catch {hm_usermessage "HMWorkFlow: unknown shortcut target $target"}
        return 0
    }
    if {[::HWToolkit::shortcutLaunchBlocked]} {
        return 0
    }
    set PENDING_SHORTCUT_TARGET $target
    ::HWToolkit::clearExistingWindows
    if {$PENDING_SHORTCUT_AFTER eq ""} {
        set PENDING_SHORTCUT_AFTER [after idle ::HWToolkit::drainShortcutLaunch]
    }
    return 1
}

proc ::HWToolkit::requestShortcutModule {key} {
    return [::HWToolkit::requestShortcutLaunch $key]
}

proc ::HWToolkit::requestShortcutHome {} {
    return [::HWToolkit::requestShortcutLaunch "__toolkit_home__"]
}

proc ::HWToolkit::drainShortcutLaunch {} {
    variable MODULE_BUSY
    variable PENDING_SHORTCUT_TARGET
    variable PENDING_SHORTCUT_AFTER

    set PENDING_SHORTCUT_AFTER ""
    if {$PENDING_SHORTCUT_TARGET eq ""} {
        return
    }
    if {$MODULE_BUSY} {
        set PENDING_SHORTCUT_AFTER [after 10 ::HWToolkit::drainShortcutLaunch]
        return
    }

    set target $PENDING_SHORTCUT_TARGET
    set PENDING_SHORTCUT_TARGET ""
    if {$target eq "__toolkit_home__"} {
        ::HWToolkit::run
    } else {
        ::HWToolkit::invokeModule $target shortcut
    }
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

proc ::HWToolkit::copyDiagnostics {} {
    variable SCRIPT_DIR
    set rows [list "HMWorkFlow diagnostics"]
    if {[llength [info commands ::HybridCore::diagnosticSummary]] > 0} {
        set summary [::HybridCore::diagnosticSummary]
        foreach key [lsort [dict keys $summary]] {
            lappend rows "$key=[dict get $summary $key]"
        }
    } else {
        set version "unknown"
        set versionPath [file join $SCRIPT_DIR VERSION]
        if {[file isfile $versionPath] && ![catch {
            set channel [open $versionPath r]
            set version [string trim [read $channel]]
            close $channel
        }]} {}
        lappend rows "package_version=$version"
        lappend rows "hm_pid=[pid]"
    }
    if {[llength [info commands ::HWShortcut::getStartupHeartbeatStatus]] > 0} {
        lappend rows "shortcut_startup=[::HWShortcut::getStartupHeartbeatStatus]"
        lappend rows "shortcut_config=[::HWShortcut::getConfigFile]"
    }
    set text [join $rows "\n"]
    if {[llength [info commands clipboard]] > 0} {
        clipboard clear
        clipboard append $text
        catch {hm_usermessage [::HWFlow::txt "诊断信息已复制到剪贴板。" "Diagnostics copied to the clipboard."]}
    } else {
        catch {puts $text}
    }
    return $text
}

proc ::HWToolkit::runModule {key} {
    catch {destroy .hwtoolkit}
    ::HWToolkit::invokeModule $key
}

proc ::HWToolkit::invokeModule {key {launchMode ui}} {
    variable MODULES
    variable MODULE_BUSY
    variable PENDING_SHORTCUT_TARGET

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
    # Direct UI and shortcut flows share one engineering-context gate before
    # a module can reach model-mutating commands.
    if {[catch {::HWFlow::requireEngineeringContext} preflightError]} {
        catch {puts "HMWorkFlow module $key blocked by preflight: $preflightError"}
        if {[llength [info commands tk_messageBox]] > 0} {
            tk_messageBox -icon warning -title "HMWorkFlow Preflight" -message $preflightError
        } else {
            catch {hm_usermessage $preflightError}
        }
        return 0
    }
    set procName [dict get $info proc]
    if {$launchMode eq "shortcut" && [dict exists $info shortcut_proc]} {
        set procName [dict get $info shortcut_proc]
    }
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
        if {$PENDING_SHORTCUT_TARGET ne ""} {
            catch {puts "HMWorkFlow module $key was closed by shortcut switch: $err"}
            return 0
        }
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
