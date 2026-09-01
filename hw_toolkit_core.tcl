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
        midsurf {
            group    "Geometry"
            label_zh "抽中面"
            label_en "Midsurface Extraction"
            desc_zh  "批量抽取钣金实体中面：同一组件中的不连续 solids 会逐实体抽取，生成的 surfaces 分别输出；多实体使用 件号.1、件号.2……命名，已有同名结果时版本递增，且统一归入 MIDSURFED Assembly。\n厚度优先读取组件名中的 _Tx 标记，其次取中面拓扑点厚度，最后按各 solid 体积/中面面积测量；仅无 solid 时使用 surface 兼容回退。\n抽取后请复核输出厚度、自由边、重叠面与组件命名。"
            desc_en  "Extract sheet-metal solid bodies one at a time and write the resulting surfaces to separate part.1, part.2, ... components. Existing exact names advance V01/V02 and all results enter MIDSURFED.\nThickness comes from the _Tx tag, midsurface topology, or per-solid volume/area; surface input is fallback only when no solid exists.\nVerify thickness, free edges, overlaps, and names."
            proc     "::MidSurf::run"
        }
        bom_material_assignment {
            group    "Geometry"
            label_zh "读取 BOM 表"
            label_en "BOM Material Assignment"
            desc_zh  "按设置范围扫描组件（默认仅限 MIDSURFED Assembly，也可切换为当前模型全部组件），统一创建/复用 Q355 材料并赋予组件，同时把组件名规范为 _Q355 后缀。\n真实 BOM 文件解析接口已预留，待 BOM 格式与部件匹配规则确定后接入。\n运行后请复核组件材料指针与命名。"
            desc_en  "Scan components in the configured scope (MIDSURFED only by default, or all model components), create/reuse Q355, assign it, and append the _Q355 suffix to component names.\nA real BOM reader interface is reserved until the BOM format and matching rules are defined.\nReview the assigned material pointers and names after running."
            proc     "::BomMaterialAssignment::runAction"
            settings_proc "::BomMaterialAssignment::runSettings"
        }
        geometry_preprocess {
            group    "Geometry"
            label_zh "预处理"
            label_en "Preprocess"
            desc_zh  "打开独立预处理面板：可将当前显示组件按标准两步旋转转换到车辆坐标系；按所选组件名称归档同名及 .数字 后缀组件；或归档名称中包含 SKELL 的骨架组件。\n归档结果统一移动到 USELESS Assembly 并隐藏，不删除任何组件。\n坐标转换作用于当前显示组件，请在执行前确认显示范围与模型初始坐标系。"
            desc_en  "Open a dedicated preprocessing panel: rotate all displayed components in two steps into the vehicle coordinate system; archive the selected component name family (the base name and .number duplicates); or archive skeleton components whose names contain SKELL.\nArchived components are moved into the USELESS assembly and hidden; nothing is deleted.\nThe coordinate conversion affects all displayed components, so verify the display set and starting coordinate system first."
            proc     "::GeometryPreprocess::runAction"
        }
        geometry_cleanup {
            group    "Geometry"
            label_zh "几何清理"
            label_en "Geometry Cleanup: Chamfer/Recess"
            desc_zh  "一键式局部几何清理，支持 AUTO / CHAMFER / POCKET 三种模式：CHAMFER 智能扩展倒角/圆角相邻面并重建直角拓扑；POCKET 自动封闭沉台内部侧面并与基准面对齐补面。\n以单个种子面为入口连续选取，链式扩展受最大深度与面积比限制，可自动缝合并重建实体。\n每次处理建立 HyperMesh 历史状态，失败自动回滚；成功结果仍应逐面确认缝合、边界与实体闭合。"
            desc_en  "One-click local geometry cleanup with AUTO / CHAMFER / POCKET modes: CHAMFER extends adjacent faces to rebuild square topology on chamfers/fillets; POCKET seals pocket side walls and aligns them to the base face.\nPick seed faces continuously; chain expansion is bounded by depth and area ratio, with automatic stitching and solid rebuild.\nEvery edit has an undo state and rolls back on failure; still review stitching, boundaries, and closure face by face."
            proc     "::GeomCleanup::runAction"
            settings_proc "::GeomCleanup::runSettings"
        }
        seam_surface {
            group    "Geometry"
            label_zh "几何焊缝"
            label_en "Geometry Seam"
            desc_zh  "按焊缝类型精确选取几何后创建曲面焊缝：支持 T 路径、T 列表、搭接面、搭接边、连接、投影/分割、延伸、合并、拆分、替换点、分布点与删除。\n所有创建前必须人工确认，失败会回滚并给出几何诊断；快捷键直接打开功能面板。\n面板内“诊断”按钮可逐条探测模块依赖的 HyperMesh 命令兼容性，报告保存到 %APPDATA%/HMWorkFlow/logs。"
            desc_en  "Create surface seams from precisely picked geometry: T path, T list, lap surface, lap edges, connect, project/split, extend, merge, split, replace points, distribute points, and delete.\nEvery creation requires confirmation, rolls back on failure, and reports geometry diagnostics; shortcuts open the panel directly.\nThe Diagnose button probes each HyperMesh command dependency and saves a report under %APPDATA%/HMWorkFlow/logs."
            proc     "::SeamSurf::runAction"
            shortcut_proc "::SeamSurf::runShortcut"
            settings_proc "::SeamSurf::runSettings"
        }
        batch_mesher {
            group    "Mesh"
            label_zh "BatchMesher 自动网格划分"
            label_en "BatchMesher Automatic Meshing"
            desc_zh  "按 Surface 拓扑连通域将模型拆分到隔离的 HyperMesh 2019/2022 hmbatch 进程并行划分，完整使用所选 criteria/param 文件。\n可配置 1-16 个并发进程；同一拓扑连通域不会被拆开，划分期间当前 HyperMesh 保持响应。\n后台聚合各 worker 的 FEM 并一次导入成功网格；没有新增单元或导入失败时整批回滚。"
            desc_en  "Split the model into surface-topology connected domains and mesh them in parallel with isolated HyperMesh 2019/2022 hmbatch workers using the selected criteria/param files.\nConfigure 1-16 concurrent workers; a connected domain is never split, and the current HyperMesh stays responsive.\nWorker FEMs are merged in the background and imported in one pass; the batch rolls back when nothing was added or the import fails."
            proc     "::BatchMesher::runAction"
            settings_proc "::BatchMesher::runSettings"
        }
        mesh_seam_weld {
            group    "Mesh"
            label_zh "网格焊缝"
            label_en "Mesh Seam Weld"
            desc_zh  "选择已有网格上的节点路径并投影到目标组件，创建焊缝连接带：先对目标局部 patch 执行 imprint 重划分，再以源节点与投影后目标节点生成 Ruled 连接带。\nFAST_AUTO 路径自动识别 T 型/搭接候选，经确认后直接导入现有边创建壳焊缝（禁止 imprint/ruled）；LEGACY_MANUAL 保留手动兼容流程。\n每个闭环独立撤销事务，失败回滚并跳过；成功批次可在主面板点击“撤回”一次恢复。"
            desc_en  "Pick a node path on existing mesh, project it onto target components, and create weld strips: imprint-remesh the local target patch, then build a Ruled strip between source nodes and the projected target nodes.\nFAST_AUTO detects T/lap candidates and, after confirmation, imports existing edges as shell welds (no imprint/ruled); LEGACY_MANUAL keeps the manual flow.\nEach loop runs in its own undo transaction; a successful batch can be restored once via Undo on the home panel."
            proc     "::MeshSeamWeld::runAction"
            settings_proc "::MeshSeamWeld::runSettings"
            undo_proc "::MeshSeamWeld::undoLast"
        }
        fem_auto_seam {
            group    "Mesh"
            label_zh "FEM 自动焊缝"
            label_en "FEM Automatic Seam"
            desc_zh  "对互不共节点的壳组件检测 T 型、贴片型与邻近自由边候选，在 FEM 层面切分并重绘，直接替换当前模型生成焊缝壳。\n检测前自动生成 before.hm 备份；规划结果写回 FEM 文件后以 File>Open 语义重新打开模型，再按连通区域分批执行原生 automesh，质量由原生 criteria 裁决。\n高置信度候选直接创建，其余进入待处理表，可逐项隔离复核或转入网格焊缝手工创建。"
            desc_en  "Detect T, patch, and near-edge candidates between shells that do not share nodes, split and remesh at the FEM level, and replace the current model with the seam shells.\nA before.hm backup is created up front; the plan is written back to the FEM file and reopened with File>Open semantics, then remeshed in native batches with criteria-based quality verdicts.\nHigh-confidence candidates are created directly; the rest go to a review table for isolation or manual creation."
            proc     "::FemAutoSeam::runAction"
            settings_proc "::FemAutoSeam::runSettings"
            undo_proc "::FemAutoSeam::undoLast"
        }
        batch_property_assignment {
            group    "Mesh"
            label_zh "批量赋予 Property 和材料"
            label_en "Batch Property and Material Assignment"
            desc_zh  "按组件命名规则批量创建或复用 PSHELL：从 Vxx_件号_Txx_材料 解析厚度与材料，焊缝组件支持 SEAM_Txx。\n自动匹配模型中已创建的材料实体并复用等价属性，避免重复定义；无法解析的名称集中列出供人工复核。\n命名规则不替代工程校核，材料牌号、厚度、卡片类型与单位制仍须与项目规范一致。"
            desc_en  "Create or reuse PSHELL properties in batch from component names: parse thickness and material from Vxx_part_Txx_material, with SEAM_Txx for weld components.\nExisting materials are matched and equivalent properties reused to avoid duplicates; unparsable names are listed for manual review.\nNaming rules do not replace engineering sign-off: grades, thickness, card types, and units must match the project spec."
            proc     "::BatchPropertyAssignment::runAction"
        }
        local_mesh_optimizer {
            group    "Mesh"
            label_zh "局部网格优化"
            label_en "Local Mesh Optimizer"
            desc_zh  "按 HyperMesh criteria 仅对失败壳单元及必要邻域进行增量优化：Python 负责候选规划与保守质量预模拟，实际修改、局部复检与最终裁决始终由 HyperMesh 完成。\n每个区域修改后立即复检，失败仅恢复当前区域；支持窄条连续协调移动与焊缝两侧节点链平移/外扩。\n用户固定节点始终不可移动；内部超窄四边形扩展与刚性/焊缝保护需显式开启。"
            desc_en  "Use a HyperMesh criteria file to incrementally optimize only the failing shell elements and their neighborhood: Python plans candidates and pre-simulates quality conservatively; HyperMesh performs the edits, local re-checks, and final verdicts.\nEach region is re-checked right after modification and only that region is restored on failure; continuous narrow strips and weld-side node chains are supported.\nUser-fixed nodes never move; internal ultra-narrow expansion and rigid/weld protection must be explicitly enabled."
            proc     "::LocalMeshOptimizer::runAction"
            settings_proc "::LocalMeshOptimizer::runSettings"
        }
        weld_integrity_check {
            group    "Mesh"
            label_zh "网格焊缝完整性检查"
            label_en "Mesh Weld Integrity Check"
            desc_zh  "在主要网格完成后缩小人工漏焊检查范围：将所选组件原生导出为 FEM，解析壳拓扑与自由边，按 Component Pair 汇总可能遗漏焊缝的候选区域。\n可逐组孤立、高亮定位并记录人工审查状态；恢复按钮还原进入前的显示集合，再次进入可继续上次审查。\n模块不判断某处必须焊接，不创建焊缝也不修改模型；候选必须人工确认。"
            desc_en  "Narrow the manual weld-miss check after meshing: export selected components as FEM natively, parse shell topology and free edges, and group candidate regions by component pair.\nReview pairs one by one with isolation/highlighting and persisted status; the restore button reverts the display set, and re-entering continues the last review.\nThe module never decides a weld is required, creates welds, or modifies the model; candidates need human confirmation."
            proc     "::WeldIntegrityCheck::runAction"
            settings_proc "::WeldIntegrityCheck::runSettings"
        }
        shell_washer_hole_rbe2 {
            group    "Connector"
            label_zh "壳孔 RIGIDS"
            label_en "Shell Washer-Hole RIGIDS"
            desc_zh  "批量识别壳网格中的 Washer 螺栓孔并创建 RIGIDS：将所选组件导出为 FEM，由 Python 扫描自由边圆孔，支持椭圆长孔，默认筛选 6.0-30.0mm 孔径。\n刚性类型可选 RBE2 或 RBE3；自动跳过已存在 RIGIDS 的孔位防止重复建模，并可检测未使用的 RBE2 预选供删除。\n输出归入 AUTO_RBE2_<源组件>；重建模式会删除对应输出组件后重建，请确认输出前缀与选择范围。"
            desc_en  "Detect washer bolt holes in shell mesh and create RIGIDS in batch: components are exported to FEM, Python scans free-edge circular holes (oval holes supported), defaulting to 6.0-30.0mm diameters.\nChoose RBE2 or RBE3; holes with existing RIGIDS are skipped to avoid duplicates, and unused RBE2s can be detected and preselected for deletion.\nOutput goes to AUTO_RBE2_<source>; rebuild mode deletes the output component first, so confirm the prefix and selection."
            proc     "::RB2W::runAction"
            settings_proc "::RB2W::runSettings"
        }
        auto_hole_rbe2 {
            group    "Connector"
            label_zh "实体孔 RIGIDS"
            label_en "Solid Through-Hole RIGIDS"
            desc_zh  "针对三维实体网格中的规则圆柱贯通孔自动创建 RIGIDS：提取自由面并拟合圆柱面片，匹配两端端环定位轴线，孔壁节点作为依赖节点，在轴线上创建中心节点。\n刚性类型可选 RBE2 / RBE3，可设置法线夹角、圆柱拟合容差与孔径过滤；拟合失败或端环不足的候选跳过并记入日志。\n沉孔、倒角明显、长圆孔与异形孔不适用；识别用的临时 ^faces 组件会自动清理。"
            desc_en  "Create RIGIDS automatically for regular cylindrical through-holes in solid meshes: free faces are extracted and fitted to cylinders, both end loops locate the axis, wall nodes become dependents, and a center node is created on the axis.\nChoose RBE2/RBE3, with normal-angle, cylinder-fit, and radius filters; failed fits are skipped and logged.\nCounterbores, obvious chamfers, slots, and irregular holes are not supported; temporary ^faces are cleaned up."
            proc     "::AutoHoleRBE2::runAction"
            settings_proc "::AutoHoleRBE2::runSettings"
        }
        rbe2_bolt_connector {
            group    "Connector"
            label_zh "螺栓连接"
            label_en "RIGIDS Bolt Connector"
            desc_zh  "对共轴的 RIGIDS 中心节点分组并创建 CBEAM/CBAR 螺栓段：导出 FEM 后由 Python 解析中心节点并完成共轴分组，Tcl 导入增量 FEM 并核验每个梁的端点。\n按中心至依赖节点的有效最小半径推算直径并向下取偶，自动创建/复用对应 1D 属性与材料；支持 dryRun 仅预览分组。\n平面 RIGIDS 仅沿检测到的法线分组，空间型分组会跳过；请确认每组代表同一物理螺栓后再创建。"
            desc_en  "Group coaxial RIGIDS center nodes and create CBEAM/CBAR bolt segments: the selection is exported to FEM, Python parses center nodes and groups them coaxially, and Tcl imports the incremental FEM and verifies each beam endpoint.\nDiameter is derived from the effective minimum radius to dependent nodes and rounded down to even; 1D properties and materials are created/reused; dryRun previews groups only.\nPlanar RIGIDS group only along their detected normal; spatial groups are skipped. Confirm each group is one physical bolt."
            proc     "::RB2Bolt::runAction"
            settings_proc "::RB2Bolt::runSettings"
        }
        cbush_creator {
            group    "Connector"
            label_zh "创建 CBUSH"
            label_en "Create CBUSH"
            desc_zh  "选择一个或多个源节点，在相同 X/Y、全局 Z+5 处创建临时节点，并以 Spring config 21 / CBUSH type 6 连接，输出到 CBUSH_<源组件>。\n同一源组件内的节点复用同一输出组件；单点失败不影响其余节点，创建失败时本次临时节点自动删除。\n模块仅创建 CBUSH 拓扑，PBUSH 属性、方向与坐标系需按项目要求分配。"
            desc_en  "Pick one or more source nodes; temporary nodes are created at the same X/Y and global Z+5, connected with Spring config 21 / CBUSH type 6, and output to CBUSH_<source component>.\nNodes from one source component share one output component; a single failure does not stop the rest, and temporary nodes are deleted on failure.\nOnly CBUSH topology is created; PBUSH properties, orientation, and coordinate systems are yours to assign."
            proc     "::CBushCreator::runAction"
        }
        batch_temp_nodes {
            group    "Connector"
            label_zh "批量添加临时节点"
            label_en "Batch Temporary Nodes"
            desc_zh  "按每行 X,Y,Z 坐标批量创建临时节点：支持整批坐标校验、一次创建与撤销上一批。\n用于快速建立分析所需的辅助/加载节点；创建前会校验坐标格式与数量。"
            desc_en  "Create temporary nodes from X,Y,Z coordinate rows in batch, with whole-batch validation, one-shot creation, and undo of the last batch.\nUse it to quickly place auxiliary/loading nodes; coordinates are validated before creation."
            proc     "::BatchTempNodes::runAction"
            undo_proc "::BatchTempNodes::undoLast"
        }
        batch_load_application {
            group    "Connector"
            label_zh "载荷批量施加"
            label_en "Batch Load Application"
            desc_zh  "选择由 CSV 转换的 TXT 载荷文件，以 case数字 行划分工况，从记录行尾识别坐标、点位中英文名及六分量载荷，并汇总展示完成状态、详情、定位与删除操作。\n定位确认后从 1001 起建立点位与 Node ID 映射；手动点击“创建所有工况”可为已完成点位按 case 创建同名 Load Collector、Force/Moment 和线性静力 Subcase。"
            desc_en  "Select TXT load files converted from CSV. Case-number rows delimit cases, and the stable record suffix supplies coordinates, English/Chinese names, and six load components for aggregation, details, location, and deletion.\nConfirmed nodes are mapped from ID 1001. Create All Cases then creates a same-name Load Collector, Force/Moment loads, and a linear-static Subcase for each case using completed points."
            proc     "::BatchLoadApplication::runAction"
        }
        contact_setup {
            group    "Connector"
            label_zh "接触创建"
            label_en "Contact Setup"
            desc_zh  "连续两次使用 HyperMesh 原生 Face 选择器选取相向单元：第一次选择确认 A 侧后直接进入 B 侧选择，完成后恢复工具窗口。\n以双向邻近关系筛选空间公共覆盖区域，创建法向相向的接触面与 OptiStruct CONTACT group。\n支持 SLIDE / STICK / FREEZE 类型与主面策略；两次选择不能包含相同单元，创建后可修剪。"
            desc_en  "Use the native HyperMesh face picker twice in one session: after the A side is confirmed the B side picker opens immediately.\nBidirectional proximity filters the common spatial coverage, then facing contact surfaces and an OptiStruct CONTACT group are created.\nSLIDE/STICK/FREEZE types and master-side strategy are supported; the two passes must not share elements, and trimming is available."
            proc     "::ContactSetup::runAction"
            settings_proc "::ContactSetup::runSettings"
        }
        adhesive_connector {
            group    "Connector"
            label_zh "模型打胶"
            label_en "Adhesive Connector"
            desc_zh  "先选择打胶区域壳单元作为 location，再选择需要连接的组件作为 links，创建 Area 类型 1D Connector 并实现为 adhesives（RBE3 + HEXA8）。\n固定使用 Tolerance=50、Coats=1、厚度 1.0；原生多线程投影会剔除任一节点未被任一目标组件接受的越界单元。\n创建后请确认 connector 已 REALIZED；首次投产前在目标 HM2019/OptiStruct 环境做 smoke test。"
            desc_en  "Pick adhesive-area shell elements as the location, then pick the components to connect as links; an Area 1D connector is created and realized as adhesives (RBE3 + HEXA8).\nFixed options: Tolerance=50, Coats=1, thickness 1.0; the native projection drops any element whose nodes are not accepted by a target component.\nVerify the connector is REALIZED after creation and smoke-test on the target environment before first production use."
            proc     "::AdhesiveConnector::runAction"
            settings_proc "::AdhesiveConnector::runSettings"
        }
        solid_seam_connector {
            group    "Connector"
            label_zh "实体焊缝"
            label_en "Solid Seam Connector"
            desc_zh  "选择两个 Components 后自动识别交界焊缝：检测交界节点链、判断接头类型（T/LAP/BUTT/ANGLED），按原生 seam connector 流程创建 PENTA6 + RBE3 实体焊缝。\n焊缝宽度与节点间距默认 6 并随网格尺寸自动修正；realization 容差自适应为 max(6.0, 1.5×网格尺寸, 最大间隙+网格尺寸)。\n输出归入 SEAM_SOLID 组件，单条失败独立记录；2019 与 2022 双版本实机验证通过。"
            desc_en  "Pick two components; the module detects the junction node chains, classifies the joint (T/LAP/BUTT/ANGLED), and creates PENTA6 + RBE3 solid welds through the native seam connector flow.\nWidth/spacing default to 6 and adapt to the mesh; the realization tolerance floors at max(6.0, 1.5×mesh size, max gap + mesh size).\nOutput goes to SEAM_SOLID with per-seam failure records; verified on both 2019 and 2022 builds."
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
        .hwtoolkit_help
        .hwflow_progress
        .midsurf_dlg
        .bom_material_assignment
        .bom_material_assignment_settings
        .autoHoleRBE2
        .rb2w_panel
        .rb2bolt_dlg
        .seam_surface
        .geometry_seam
        .geometry_seam_shortcut_selector
        .geometry_seam_thickness
        .geometry_cleanup
        .geometry_preprocess
        .contact_setup
        .adhesive_connector
        .batch_mesher
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
    set button .hwtoolkit.foot.buttons.topmost
    if {[llength [info commands winfo]] > 0 && [winfo exists $button]} {
        $button configure -text [::HWToolkit::topmostButtonText]
    }
}

proc ::HWToolkit::showPanel {} {
    # Both host generations build the same flat home panel; the shared Tk
    # backend, system palette and font scale keep 2019 and 2022 identical.
    return [::HWToolkit::showPanelHome]
}

# Flat single-level home panel shared by HyperMesh 2019 and HyperWorks 2022.
# Every visible tool is one row: clicking its name runs it immediately and
# the two trailing buttons open its settings and its shortcut binding.  One
# builder serves both host generations; the shared Tk backend, the system
# palette and the unified font scale keep the two layouts identical.
proc ::HWToolkit::showPanelHome {} {
    variable MODULES
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
    # The compact rows and footer set a natural width of about 540 px; the
    # minimum lets users shrink the panel down to the point where the footer
    # buttons still fit without clipping.
    wm minsize $w 540 380
    wm resizable $w 1 1

    set bodyBg        [::HWFlow::uiColors bodyBg]
    set textPrimary   [::HWFlow::uiColors textPrimary]
    set textSecondary [::HWFlow::uiColors textSecondary]

    # The widest visible tool name sets the shared name-column width so every
    # row starts its buttons at the same offset without clipping names.  The
    # width is measured in the module font (pixel text width converted to the
    # character unit the label -width option uses), not in a visual-length
    # heuristic, which truncated mixed CJK/ASCII names like
    # "BatchMesher 自动网格划分".
    set nameFont [::HWFlow::uiFont module]
    set zeroWidth [font measure $nameFont "0"]
    set nameWidth 0
    foreach {key info} $MODULES {
        if {![::HWToolkit::moduleVisible $info]} { continue }
        set text [::HWToolkit::moduleText $info label]
        set pixels [font measure $nameFont $text]
        set chars [expr {int(ceil(double($pixels) / $zeroWidth)) + 1}]
        if {$chars > $nameWidth} { set nameWidth $chars }
    }

    ::HWFlow::uiWidget frame $w.header -background $bodyBg
    pack $w.header -fill x -padx 12 -pady {8 0}
    ::HWFlow::uiWidget label $w.header.title -text "HyperMesh Toolkit" \
        -font [::HWFlow::uiFont header] -foreground $textPrimary \
        -background $bodyBg -anchor w
    set version [::HWFlow::hyperWorksVersion]
    if {$version eq ""} { set version "HyperWorks" }
    ::HWFlow::uiWidget label $w.header.version -text $version \
        -font [::HWFlow::uiFont small] -foreground $textSecondary \
        -background $bodyBg -anchor e
    ::HWFlow::uiWidget label $w.header.hint \
        -text [::HWFlow::txt "点击名称运行 · 行尾按钮：快捷键 / 设置 / 帮助" "Click a name to run · trailing buttons: shortcut / settings / help"] \
        -font [::HWFlow::uiFont small] -foreground $textSecondary \
        -background $bodyBg -anchor w
    pack $w.header.version -side right
    pack $w.header.title -side left
    pack $w.header.hint -side left -padx {12 0}
    ::HWFlow::groove $w.rule
    pack $w.rule -fill x -padx 12 -pady {6 0}

    ::HWFlow::scrollableFrame $w.body
    pack $w.body -fill both -expand 1 -padx 12 -pady {2 6}
    set content $w.body.c.inner

    # Building a row creates several children and therefore several
    # <Configure> events.  Recomputing the canvas bbox after every child used
    # to turn initial layout into dozens of full scroll-region passes.  The
    # panel is still withdrawn here, so suspend that binding while the fixed
    # home-page tree is assembled and perform one calculation afterwards.
    bind $content <Configure> ""

    set groupIndex 0
    foreach group [::HWToolkit::moduleGroups] {
        ::HWFlow::groupHeader $content.g$groupIndex [::HWToolkit::groupText $group]
        pack $content.g$groupIndex -fill x -pady {4 1}
        ::HWToolkit::buildHomeGroup $content $group $nameWidth
        incr groupIndex
    }
    bind $content <Configure> [list ::HWFlow::scrollableInnerConfigure $w.body.c]
    # Let the canvas adopt the full content height so the window opens tall
    # enough to show every tool; the scrollbar only appears when the user
    # shrinks the window or the screen cannot fit the panel.
    update idletasks
    set contentHeight [winfo reqheight $content]
    if {$contentHeight > 50} {
        catch {$w.body.c configure -height $contentHeight}
    }
    # Append (do not replace) the scrollable-frame binding that keeps the
    # inner frame at the canvas width; replacing it left every row at its
    # content width and pushed the trailing buttons next to the name instead
    # of the end of the row.
    bind $w.body.c <Configure> +[list ::HWToolkit::scheduleHomeScroll $w]

    set footer [::HWFlow::actionBar $w.foot]
    pack $w.foot -fill x -padx 12 -pady {0 8}
    foreach {name text width command} [list \
        help [::HWFlow::txt "查看帮助" "View Help"] 12 ::HWToolkit::openGuide \
        diagnostics [::HWFlow::txt "复制诊断" "Copy Diagnostics"] 12 ::HWToolkit::copyDiagnostics \
        shortcuts [::HWFlow::txt "工具箱设置" "Toolbox Settings"] 13 ::HWShortcut::showSettings] {
        ::HWFlow::uiWidget button $footer.$name -text $text -width $width -command $command -cursor hand2
        pack $footer.$name -side left -padx {0 6}
    }
    ::HWFlow::uiWidget button $footer.topmost -text [::HWToolkit::topmostButtonText] \
        -width 16 -command ::HWToolkit::toggleProjectTopmost -cursor hand2
    pack $footer.topmost -side right -padx {0 6}
    ::HWFlow::uiWidget button $footer.close -text [::HWFlow::txt "关闭" "Close"] -width 10 \
        -command ::HWToolkit::closePanel -cursor hand2
    pack $footer.close -side right

    bind $w <Escape> ::HWToolkit::closePanel
    wm protocol $w WM_DELETE_WINDOW ::HWToolkit::closePanel

    # Size to the natural requested width instead of a fixed legacy width:
    # the flat compact layout only needs what the header, rows, and footer
    # actually request, so the window adapts to the current content.
    ::HWFlow::centerWindow $w 0 0
    wm deiconify $w
    catch {raise $w}
    catch {focus $w}
    ::HWToolkit::updateHomeScroll $w
    return $w
}

# Keep the home panel scroll-free whenever the content fits: the vertical
# scrollbar is hidden while every tool row is visible and only reappears when
# the window is shrunk below the content height.
proc ::HWToolkit::updateHomeScroll {w} {
    variable HOME_SCROLL_LAST_H
    if {![winfo exists $w.body.c]} { return }
    update idletasks
    set canvasHeight [winfo height $w.body.c]
    # The canvas reports a pre-map or intermediate height while the window
    # geometry is still settling; keep retrying on idle until the first real
    # layout stops changing before deciding whether the scrollbar is needed.
    if {$canvasHeight <= 50 || ([info exists HOME_SCROLL_LAST_H] && $canvasHeight ne $HOME_SCROLL_LAST_H)} {
        set HOME_SCROLL_LAST_H $canvasHeight
        after idle [list ::HWToolkit::updateHomeScroll $w]
        return
    }
    set HOME_SCROLL_LAST_H $canvasHeight
    set needed [expr {[winfo reqheight $w.body.c.inner] > $canvasHeight}]
    if {$needed} {
        if {[winfo manager $w.body.vsb] eq ""} {
            pack $w.body.vsb -side right -fill y
        }
    } else {
        catch {pack forget $w.body.vsb}
    }
}

proc ::HWToolkit::scheduleHomeScroll {w} {
    variable HOME_SCROLL_TIMER
    if {[info exists HOME_SCROLL_TIMER] && $HOME_SCROLL_TIMER ne ""} {
        catch {after cancel $HOME_SCROLL_TIMER}
    }
    set HOME_SCROLL_TIMER [after 80 [list ::HWToolkit::updateHomeScroll $w]]
}

# One tool row: the name runs the module on click (highlighted on hover),
# followed by the shortcut, settings, and help buttons.  The enriched module
# description lives behind the help button instead of on the row, keeping the
# panel compact while the full help text stays one click away.
proc ::HWToolkit::buildHomeRow {parent key info nameWidth} {
    set row $parent.r_$key
    set bodyBg [::HWFlow::uiColors bodyBg]
    ::HWFlow::uiWidget frame $row -background $bodyBg
    pack $row -fill x -pady 1

    ::HWFlow::uiWidget label $row.name -text [::HWToolkit::moduleText $info label] \
        -font [::HWFlow::uiFont module] -width $nameWidth -anchor w -cursor hand2 \
        -foreground [::HWFlow::uiColors textPrimary] -background $bodyBg
    pack $row.name -side left -padx {4 8}
    bind $row.name <Button-1> [list ::HWToolkit::runModule $key]
    bind $row.name <Enter> [list ::HWToolkit::homeRowHover $row.name 1]
    bind $row.name <Leave> [list ::HWToolkit::homeRowHover $row.name 0]

    # Packed right first, so the visual order is: shortcut, settings, help.
    ::HWFlow::uiWidget button $row.help -width 6 \
        -text [::HWFlow::txt "帮助" "Help"] -font [::HWFlow::uiFont default] \
        -cursor hand2 -command [list ::HWToolkit::helpModule $key]
    pack $row.help -side right -padx {0 4}
    ::HWFlow::uiWidget button $row.settings -width 8 \
        -text [::HWFlow::txt "设置" "Settings"] -font [::HWFlow::uiFont default] \
        -cursor hand2 -command [list ::HWToolkit::settingsModule $key]
    if {![dict exists $info settings_proc]} {
        $row.settings configure -state disabled
    }
    pack $row.settings -side right -padx {0 2}
    ::HWFlow::uiWidget button $row.shortcut -text [::HWToolkit::shortcutButtonText $key] \
        -font [::HWFlow::uiFont default] -cursor hand2 \
        -command [list ::HWShortcut::showForModule $key]
    pack $row.shortcut -side right -padx {2 4}
}

proc ::HWToolkit::buildHomeGroup {parent group nameWidth} {
    variable MODULES
    foreach {key info} $MODULES {
        if {![::HWToolkit::moduleVisible $info]} { continue }
        if {[dict get $info group] ne $group} { continue }
        ::HWToolkit::buildHomeRow $parent $key $info $nameWidth
    }
}

proc ::HWToolkit::homeRowHover {nameWidget active} {
    if {![winfo exists $nameWidget]} { return }
    if {$active} {
        catch {$nameWidget configure -foreground [::HWFlow::uiColors accent]}
    } else {
        catch {$nameWidget configure -foreground [::HWFlow::uiColors textPrimary]}
    }
}

# The row shortcut button doubles as the binding status: it shows the bound
# key when one exists and a bind prompt otherwise.
proc ::HWToolkit::shortcutButtonText {key} {
    if {[llength [info commands ::HWShortcut::moduleShortcut]] > 0} {
        set value [::HWShortcut::moduleShortcut $key]
        if {$value ne ""} {
            return $value
        }
    }
    return [::HWFlow::txt "绑定快捷键" "Bind Key"]
}

# Compatibility aliases retained for callers written against the split
# two-pane implementation; both host generations now share showPanelHome.
proc ::HWToolkit::showPanel2022 {} {
    return [::HWToolkit::showPanelHome]
}

proc ::HWToolkit::showPanelLegacy {} {
    return [::HWToolkit::showPanelHome]
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
    set content .hwtoolkit.body.c.inner
    if {![winfo exists $content]} {
        return
    }
    # Each home row carries its binding on the row button, so a rebind only
    # needs the visible button texts refreshed.
    foreach {key info} $MODULES {
        if {![::HWToolkit::moduleVisible $info]} { continue }
        set button $content.r_$key.shortcut
        if {[winfo exists $button]} {
            catch {$button configure -text [::HWToolkit::shortcutButtonText $key]}
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

    if {![dict exists $MODULES $key]} {
        return
    }
    set info [dict get $MODULES $key]
    if {![::HWToolkit::moduleVisible $info]} {
        return
    }
    # The home panel intentionally does not source every large business
    # module.  Load only the module whose settings the user requested.
    if {![::HWToolkit::ensureCoreLoaded] ||
        ![::HWToolkit::sourceOneModule $key $info]} {
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

# Show the enriched module description in a small scrollable dialog.  The
# home rows no longer carry the description text, so this is the single place
# where users read what a tool does before running it.
proc ::HWToolkit::helpModule {key} {
    variable MODULES
    if {![dict exists $MODULES $key]} { return }
    set info [dict get $MODULES $key]
    if {![::HWToolkit::moduleVisible $info]} { return }
    set w .hwtoolkit_help
    if {[winfo exists $w]} {
        catch {destroy $w}
    }
    ::HWFlow::createTopLevel $w help
    wm title $w [::HWFlow::windowTitle [::HWFlow::txt "模块说明" "Module Help"] "Module Help"]

    set bodyBg        [::HWFlow::uiColors bodyBg]
    set textPrimary   [::HWFlow::uiColors textPrimary]
    set textSecondary [::HWFlow::uiColors textSecondary]

    ::HWFlow::uiWidget frame $w.header -background $bodyBg
    pack $w.header -fill x -padx 14 -pady {10 0}
    ::HWFlow::uiWidget label $w.header.title -text [::HWToolkit::moduleText $info label] \
        -font [::HWFlow::uiFont title] -foreground $textPrimary -background $bodyBg -anchor w
    ::HWFlow::uiWidget label $w.header.sub \
        -text "[::HWToolkit::groupText [dict get $info group]] · [::HWToolkit::moduleFile $key $info]" \
        -font [::HWFlow::uiFont small] -foreground $textSecondary -background $bodyBg -anchor w
    pack $w.header.title -fill x
    pack $w.header.sub -fill x -pady {2 0}
    ::HWFlow::groove $w.rule
    pack $w.rule -fill x -padx 14 -pady {8 0}

    ::HWFlow::uiWidget frame $w.body -background $bodyBg
    pack $w.body -fill both -expand 1 -padx 14 -pady 8
    text $w.body.t -wrap word -font [::HWFlow::uiFont default] -relief flat \
        -borderwidth 0 -highlightthickness 0 -padx 4 -pady 4 -width 62 -height 15 \
        -background $bodyBg -foreground $textPrimary -state normal
    scrollbar $w.body.s -orient vertical -command [list $w.body.t yview] -highlightthickness 0
    $w.body.t configure -yscrollcommand [list $w.body.s set]
    pack $w.body.s -side right -fill y
    pack $w.body.t -side left -fill both -expand 1
    $w.body.t insert end [::HWToolkit::moduleText $info desc]
    $w.body.t configure -state disabled

    set footer [::HWFlow::actionBar $w.foot]
    pack $w.foot -fill x -padx 14 -pady {0 10}
    ::HWFlow::uiWidget button $footer.close -text [::HWFlow::txt "关闭" "Close"] -width 10 \
        -command ::HWToolkit::closeHelp -cursor hand2
    pack $footer.close -side right

    bind $w <Escape> ::HWToolkit::closeHelp
    wm protocol $w WM_DELETE_WINDOW ::HWToolkit::closeHelp
    ::HWFlow::centerWindow $w 680 0
    catch {raise $w}
    catch {focus $w}
    return $w
}

proc ::HWToolkit::closeHelp {} {
    if {[llength [info commands winfo]] > 0 && [winfo exists .hwtoolkit_help]} {
        catch {destroy .hwtoolkit_help}
    }
}

proc ::HWToolkit::run {{refreshShortcuts 1}} {
    # Drawing the home panel only needs the shared UI and shortcut layers.
    # Business modules are sourced by invokeModule/settingsModule on first
    # use; some are thousands of lines long, so loading all of them here made
    # both host generations appear to paint the same small window slowly.
    if {![::HWToolkit::ensureCoreLoaded]} {
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
