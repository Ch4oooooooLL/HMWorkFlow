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
    variable UI2022_GROUP ""
    variable UI2022_KEYS {}

    set MODULES {
        midsurf {
            group    "Geometry"
            label_zh "抽中面"
            label_en "Midsurface Extraction"
            desc_zh  "抽取钣金中面，并按 Vxx_件号_T厚度[_材料] 规则命名；材料由后续网格模块处理。"
            desc_en  "Extract sheet-metal midsurfaces as Vxx_part_Tx[_material]; material assignment is handled later by mesh modules."
            proc     "::MidSurf::run"
        }
        bom_material_assignment {
            group    "Geometry"
            label_zh "读取 BOM 表"
            label_en "BOM Material Assignment"
            desc_zh  "扫描 MIDSURFED Assembly 中的全部 component；当前统一创建/复用 Q355、赋予材料并追加组件名后缀，BOM 读取接口预留。"
            desc_en  "Scan all components in MIDSURFED; currently create/reuse Q355, assign it, and append the component-name suffix while reserving the BOM reader interface."
            proc     "::BomMaterialAssignment::runAction"
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
        batch_mesher {
            group    "Mesh"
            label_zh "BatchMesher 自动网格划分"
            label_en "BatchMesher Automatic Meshing"
            desc_zh  "在隔离的 HyperMesh 2019/2022 hmbatch 进程中按 Surface 拓扑连通域并行划分，完整使用用户 criteria/param。"
            desc_en  "Mesh surface-topology groups in isolated parallel HyperMesh 2019/2022 hmbatch workers using the selected criteria/param files."
            proc     "::BatchMesher::runAction"
            settings_proc "::BatchMesher::runSettings"
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
            desc_zh  "选择已有网格节点路径并投影到目标组件，创建焊缝连接带；支持撤回最近一次批次。"
            desc_en  "Select an existing mesh node path, project to target components, create a weld strip, and undo the most recent batch."
            proc     "::MeshSeamWeld::runAction"
            settings_proc "::MeshSeamWeld::runSettings"
            undo_proc "::MeshSeamWeld::undoLast"
        }
        fem_auto_seam {
            group    "Mesh"
            label_zh "FEM 自动焊缝"
            label_en "FEM Automatic Seam"
            desc_zh  "分析孤立划分后的壳网格，识别并复核 T 型、贴片型和邻近自由边，在 FEM 层面切分并创建焊缝。"
            desc_en  "Analyze independently meshed shells, review T/patch/near-edge candidates, and create seams through FEM-level splitting."
            proc     "::FemAutoSeam::runAction"
            settings_proc "::FemAutoSeam::runSettings"
            undo_proc "::FemAutoSeam::undoLast"
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
        batch_temp_nodes {
            group    "Connector"
            label_zh "批量添加临时节点"
            label_en "Batch Temporary Nodes"
            desc_zh  "按每行 X,Y,Z 坐标批量创建临时节点，支持整批校验和撤销上一批。"
            desc_en  "Create temporary nodes from X,Y,Z rows with batch validation and undo."
            proc     "::BatchTempNodes::runAction"
            undo_proc "::BatchTempNodes::undoLast"
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
    catch {::MidSurf::savePanelState}
    catch {set ::BomMaterialAssignment::ui(ok) 0}
    catch {::AutoHoleRBE2::savePanelState}
    catch {::RB2W::savePanelState}
    catch {::BatchMesher::savePanelState}
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
        .midsurf_dlg
        .bom_material_assignment
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
        .batch_mesher
        .casting_tetramesh
        .mesh_seam_weld
        .fem_auto_seam
        .fem_auto_seam_review
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

proc ::HWToolkit::closePanel {} {
    if {[llength [info commands winfo]] > 0 && [winfo exists .hwtoolkit]} {
        catch {destroy .hwtoolkit}
    }
}

proc ::HWToolkit::topmostButtonText {} {
    if {[::HWFlow::projectTopmostEnabled]} {
        return [::HWFlow::txt "窗口置顶：开" "Always on Top: On"]
    }
    return [::HWFlow::txt "窗口置顶：关" "Always on Top: Off"]
}

proc ::HWToolkit::toggleProjectTopmost {} {
    ::HWFlow::toggleProjectTopmost
    set button .hwtoolkit.foot.topmost
    if {[llength [info commands winfo]] > 0 && [winfo exists $button]} {
        $button configure -text [::HWToolkit::topmostButtonText]
    }
}

proc ::HWToolkit::showPanel {} {
    if {[::HWFlow::uiProfile] eq "hw2022"} {
        return [::HWToolkit::showPanel2022]
    }
    return [::HWToolkit::showPanelLegacy]
}

# Unified home panel used by HyperWorks 2022 and, through
# ::HWToolkit::showPanelLegacy, by HyperMesh 2019.  It renders one category at
# a time instead of constructing every module row and every action button up
# front, which keeps the widget count low on both host generations.  The
# two-pane layout and header/footer structure are shared; only fonts and the
# widget backend differ per profile (::HWFlow::uiFont / ::HWFlow::uiWidget).
proc ::HWToolkit::showPanel2022 {} {
    set w .hwtoolkit
    if {[winfo exists $w]} {
        catch {wm deiconify $w}
        catch {raise $w}
        catch {focus $w}
        return $w
    }

    ::HWFlow::createTopLevel $w main
    wm withdraw $w
    wm title $w "HyperMesh Toolkit"
    wm minsize $w 760 520
    wm resizable $w 1 1

    set headerBg       [::HWFlow::uiColors headerBg]
    set bodyBg         [::HWFlow::uiColors bodyBg]
    set cardBg         [::HWFlow::uiColors cardBg]
    set border         [::HWFlow::uiColors border]
    set accent         [::HWFlow::uiColors accent]
    set accentDark     [::HWFlow::uiColors accentDark]
    set accentSoftText [::HWFlow::uiColors accentSoftText]
    set textPrimary    [::HWFlow::uiColors textPrimary]
    set textSecondary  [::HWFlow::uiColors textSecondary]
    set listSelBg      [::HWFlow::uiColors listSelBg]
    set listSelFg      [::HWFlow::uiColors listSelFg]

    ::HWFlow::uiWidget frame $w.header -background $headerBg
    pack $w.header -fill x
    ::HWFlow::uiWidget label $w.header.title -text "HyperMesh Toolkit" \
        -font [::HWFlow::uiFont header] -foreground $textPrimary -background $headerBg -anchor w
    pack $w.header.title -fill x -padx 18 -pady {14 2}
    set version [::HWFlow::hyperWorksVersion]
    if {$version eq ""} { set version "HyperWorks" }
    ::HWFlow::uiWidget label $w.header.subtitle \
        -text [::HWFlow::txt "请选择分类和工具" "Choose a category and tool"] \
        -font [::HWFlow::uiFont default] -foreground $textSecondary -background $headerBg -anchor w
    ::HWFlow::uiWidget label $w.header.version -text $version \
        -font [::HWFlow::uiFont small] -foreground $textSecondary -background $headerBg -anchor e
    pack $w.header.version -side right -padx 18 -pady {0 12}
    pack $w.header.subtitle -side left -fill x -expand 1 -padx 18 -pady {0 12}
    ::HWFlow::uiWidget frame $w.header.rule -height 3 -background $accent
    pack $w.header.rule -fill x

    ::HWFlow::uiWidget frame $w.body -background $bodyBg
    pack $w.body -fill both -expand 1 -padx 16 -pady 14
    ::HWFlow::uiWidget frame $w.body.navigation -background $bodyBg
    ::HWFlow::uiWidget frame $w.body.detail -relief solid -borderwidth 1 -background $cardBg
    grid $w.body.navigation -row 0 -column 0 -sticky ns -padx {0 16}
    grid $w.body.detail -row 0 -column 1 -sticky nsew
    grid rowconfigure $w.body 0 -weight 1
    grid columnconfigure $w.body 1 -weight 1

    ::HWFlow::uiWidget label $w.body.navigation.heading \
        -text [::HWFlow::txt "工具分类" "Categories"] -font [::HWFlow::uiFont heading] \
        -foreground $textPrimary -background $bodyBg -anchor w
    pack $w.body.navigation.heading -fill x -pady {0 8}
    set groupIndex 0
    foreach group [::HWToolkit::moduleGroups] {
        set button $w.body.navigation.group_$groupIndex
        ::HWFlow::uiWidget button $button -text [::HWToolkit::groupText $group] \
            -font [::HWFlow::uiFont module] -width 18 -anchor w -relief flat -borderwidth 1 \
            -highlightthickness 0 -cursor hand2 \
            -command [list ::HWToolkit::select2022Group $group]
        ::HWToolkit::styleGroupButton $button normal
        pack $button -fill x -pady 2
        incr groupIndex
    }
    ::HWFlow::uiWidget label $w.body.navigation.tools \
        -text [::HWFlow::txt "工具" "Tools"] -font [::HWFlow::uiFont heading] \
        -foreground $textPrimary -background $bodyBg -anchor w
    pack $w.body.navigation.tools -fill x -pady {16 6}
    listbox $w.body.navigation.list -width 29 -height 12 -font [::HWFlow::uiFont default] \
        -exportselection 0 -selectmode browse -activestyle none \
        -background $cardBg -foreground $textPrimary \
        -selectbackground $listSelBg -selectforeground $listSelFg \
        -selectborderwidth 0 -relief solid -borderwidth 1 \
        -highlightthickness 1 -highlightbackground $border -highlightcolor $accent
    pack $w.body.navigation.list -fill both -expand 1
    bind $w.body.navigation.list <<ListboxSelect>> ::HWToolkit::update2022Selection

    ::HWFlow::uiWidget label $w.body.detail.title -text "" -font [::HWFlow::uiFont title] \
        -foreground $textPrimary -background $cardBg -anchor w
    ::HWFlow::uiWidget label $w.body.detail.group -text "" -font [::HWFlow::uiFont small] \
        -foreground $accentSoftText -background $cardBg -anchor w
    ::HWFlow::uiWidget label $w.body.detail.desc -text "" -font [::HWFlow::uiFont default] \
        -foreground $textPrimary -background $cardBg -justify left -anchor nw -wraplength 430
    pack $w.body.detail.title -fill x -padx 20 -pady {22 3}
    pack $w.body.detail.group -fill x -padx 20
    pack $w.body.detail.desc -fill both -expand 1 -padx 20 -pady {16 12}
    ::HWFlow::bindAutoWrap $w.body.detail.desc 350

    ::HWFlow::uiWidget frame $w.body.detail.actions -background $cardBg
    pack $w.body.detail.actions -fill x -padx 18 -pady {8 18}
    foreach {name text width primary} [list \
        run [::HWFlow::txt "运行" "Run"] 12 1 \
        settings [::HWFlow::txt "设置" "Settings"] 10 0 \
        shortcut [::HWFlow::txt "快捷键" "Shortcut"] 12 0 \
        undo [::HWFlow::txt "撤回" "Undo"] 10 0] {
        ::HWFlow::uiWidget button $w.body.detail.actions.$name -text $text \
            -font [::HWFlow::uiFont default] -width $width -cursor hand2
        if {$primary} {
            catch {$w.body.detail.actions.$name configure \
                -background $accent -foreground #ffffff \
                -activebackground $accentDark -activeforeground #ffffff}
        }
        pack $w.body.detail.actions.$name -side left -padx 3
    }

    ::HWFlow::uiWidget frame $w.foot -background $bodyBg
    pack $w.foot -fill x -padx 16 -pady {0 14}
    ::HWFlow::uiWidget frame $w.foot.rule -height 1 -background $border
    pack $w.foot.rule -fill x -pady {0 10}
    foreach {name text width command} [list \
        help [::HWFlow::txt "查看帮助" "View Help"] 12 ::HWToolkit::openGuide \
        diagnostics [::HWFlow::txt "复制诊断" "Copy Diagnostics"] 12 ::HWToolkit::copyDiagnostics \
        shortcuts [::HWFlow::txt "快捷键管理" "Shortcuts"] 13 ::HWShortcut::showManager] {
        ::HWFlow::uiWidget button $w.foot.$name -text $text -width $width -command $command -cursor hand2
        pack $w.foot.$name -side left -padx {0 6}
    }
    ::HWFlow::uiWidget button $w.foot.topmost -text [::HWToolkit::topmostButtonText] \
        -width 16 -command ::HWToolkit::toggleProjectTopmost -cursor hand2
    pack $w.foot.topmost -side right -padx {0 6}
    ::HWFlow::uiWidget button $w.foot.close -text [::HWFlow::txt "关闭" "Close"] -width 10 \
        -command ::HWToolkit::closePanel -cursor hand2
    pack $w.foot.close -side right

    bind $w <Escape> ::HWToolkit::closePanel
    wm protocol $w WM_DELETE_WINDOW ::HWToolkit::closePanel
    set groups [::HWToolkit::moduleGroups]
    if {[llength $groups] > 0} { ::HWToolkit::select2022Group [lindex $groups 0] }

    set width 820
    set height 560
    set x [expr {([winfo screenwidth $w] - $width) / 2}]
    set y [expr {([winfo screenheight $w] - $height) / 2}]
    wm geometry $w ${width}x${height}+$x+$y
    wm deiconify $w
    catch {raise $w}
    catch {focus $w}
    return $w
}

# Flat navigation-button look for the unified home panel.  The active category
# gets the accent tint while inactive buttons match the body background.
# Classic Tk options are used so hwtk and ttk backends fall back cleanly.
proc ::HWToolkit::styleGroupButton {button state} {
    set bodyBg [::HWFlow::uiColors bodyBg]
    set accentSoft [::HWFlow::uiColors accentSoft]
    set accentSoftText [::HWFlow::uiColors accentSoftText]
    set textSecondary [::HWFlow::uiColors textSecondary]
    if {$state eq "active"} {
        catch {$button configure -relief flat -borderwidth 1 \
            -background $accentSoft -foreground $accentSoftText \
            -activebackground $accentSoft -activeforeground $accentSoftText}
    } else {
        catch {$button configure -relief flat -borderwidth 1 \
            -background $bodyBg -foreground $textSecondary \
            -activebackground $accentSoft -activeforeground $accentSoftText}
    }
}

proc ::HWToolkit::select2022Group {group} {
    variable MODULES
    variable UI2022_GROUP
    variable UI2022_KEYS
    set UI2022_GROUP $group
    set UI2022_KEYS {}
    set list .hwtoolkit.body.navigation.list
    if {![winfo exists $list]} { return }
    $list delete 0 end
    foreach {key info} $MODULES {
        if {![::HWToolkit::moduleVisible $info] || [dict get $info group] ne $group} { continue }
        lappend UI2022_KEYS $key
        $list insert end [::HWToolkit::moduleText $info label]
    }
    set index 0
    foreach candidate [::HWToolkit::moduleGroups] {
        set button .hwtoolkit.body.navigation.group_$index
        if {[winfo exists $button]} {
            ::HWToolkit::styleGroupButton $button [expr {$candidate eq $group ? "active" : "normal"}]
        }
        incr index
    }
    if {[llength $UI2022_KEYS] > 0} {
        $list selection set 0
        $list activate 0
        ::HWToolkit::update2022Selection
    }
}

proc ::HWToolkit::update2022Selection {} {
    variable MODULES
    variable UI2022_GROUP
    variable UI2022_KEYS
    set list .hwtoolkit.body.navigation.list
    if {![winfo exists $list]} { return }
    set selection [$list curselection]
    if {[llength $selection] == 0} { return }
    set key [lindex $UI2022_KEYS [lindex $selection 0]]
    if {![dict exists $MODULES $key]} { return }
    set info [dict get $MODULES $key]
    set detail .hwtoolkit.body.detail
    $detail.title configure -text [::HWToolkit::moduleText $info label]
    $detail.group configure -text "[::HWToolkit::groupText $UI2022_GROUP]  ·  [::HWToolkit::shortcutText $key]"
    $detail.desc configure -text [::HWToolkit::moduleText $info desc]
    $detail.actions.run configure -state normal -command [list ::HWToolkit::runModule $key]
    if {[dict exists $info settings_proc]} {
        $detail.actions.settings configure -state normal -command [list ::HWToolkit::settingsModule $key]
    } else {
        $detail.actions.settings configure -state disabled -command {}
    }
    $detail.actions.shortcut configure -state normal -command [list ::HWShortcut::showForModule $key]
    if {[dict exists $info undo_proc]} {
        $detail.actions.undo configure -state normal -command [dict get $info undo_proc]
    } else {
        $detail.actions.undo configure -state disabled -command {}
    }
}

# HyperMesh 2019 entry point.  The 2019 profile renders the same two-pane
# layout as HyperWorks 2022; ::HWFlow::uiWidget picks the host-appropriate
# widget backend and ::HWFlow::uiFont keeps per-generation font sizes, so the
# shared builder needs no version-specific copy.
proc ::HWToolkit::showPanelLegacy {} {
    return [::HWToolkit::showPanel2022]
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
    # The unified two-pane panel shows the shortcut of the currently selected
    # module in the detail area; re-render that selection after bindings
    # change.  No module rows exist anymore on either host generation.
    if {[winfo exists .hwtoolkit.body.navigation.list]} {
        catch {::HWToolkit::update2022Selection}
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
        # The shortcut library is already initialized before a native key can
        # dispatch here.  Re-registering the active key while handling it can
        # invalidate that binding in HyperWorks 2022 after the panel closes.
        ::HWToolkit::run 0
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
    lappend rows "hyperworks_version=[::HWFlow::hyperWorksVersion]"
    lappend rows "ui_profile=[::HWFlow::uiProfile]"
    lappend rows "ui_backend=[::HWFlow::uiBackend]"
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

proc ::HWToolkit::run {{refreshShortcuts 1}} {
    if {![::HWToolkit::sourceModules]} {
        return
    }
    if {$refreshShortcuts && [llength [info commands ::HWShortcut::initialize]] > 0} {
        catch {::HWShortcut::initialize}
    }
    ::HWToolkit::clearExistingWindows
    if {[catch {::HWToolkit::showPanel} err]} {
        tk_messageBox -icon error -title [::HWFlow::txt "HW 工作流" "HWToolkit"] -message [::HWFlow::txt "主面板启动失败：\n$err" "Panel error:\n$err"]
    }
}
