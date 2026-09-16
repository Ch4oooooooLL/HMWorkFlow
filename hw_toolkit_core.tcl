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
    variable HOME_SECTION "Common"
    variable HOME_FILTER ""
    variable HOME_STATE_LOADED 0
    variable HOME_FAVORITES {}
    variable HOME_RECENTS {}
    variable HOME_DEFAULT_FAVORITES {
        midsurf batch_mesher mesh_seam_weld fem_auto_seam
        shell_washer_hole_rbe2 contact_setup
    }
    variable HOME_SUMMARIES [dict create \
        midsurf [list "批量抽取钣金实体中面并整理输出组件。" "Extract sheet-metal midsurfaces and organize the outputs."] \
        bom_material_assignment [list "读取 BOM 规则并批量规范材料与组件命名。" "Apply BOM material rules and normalize component names."] \
        geometry_preprocess [list "转换坐标系并整理、归档模型组件。" "Transform coordinates and organize or archive components."] \
        geometry_cleanup [list "连续清理倒角、圆角与沉台等局部几何。" "Clean local chamfers, fillets, and pockets continuously."] \
        seam_surface [list "基于几何路径创建、编辑和诊断曲面焊缝。" "Create, edit, and diagnose geometry-based surface seams."] \
        batch_mesher [list "按拓扑连通域并行执行 BatchMesher 网格划分。" "Mesh topology domains in parallel with BatchMesher."] \
        mesh_seam_weld [list "在已有壳网格上创建并局部重绘焊缝。" "Create welds on existing shell mesh with local remeshing."] \
        node_patch_builder [list "按节点边界追踪并重建局部壳网格补片。" "Trace a node boundary and rebuild a local shell patch."] \
        fem_auto_seam [list "自动识别可信焊缝候选并批量创建或删除。" "Recognize trusted weld candidates for batch creation or deletion."] \
        batch_property_assignment [list "根据组件命名批量创建并赋予属性和材料。" "Create and assign properties and materials from component names."] \
        local_mesh_optimizer [list "仅对质量失败区域执行增量网格优化。" "Incrementally optimize only failed mesh regions."] \
        mesh_add_washer [list "在纯壳网格孔边创建规则 Washer。" "Create a regular washer around a shell-mesh hole."] \
        weld_integrity_check [list "定位可能漏焊的组件对并辅助人工复核。" "Locate possible missing welds for guided review."] \
        shell_washer_hole_rbe2 [list "识别壳网格 Washer 孔并批量创建 RIGIDS。" "Detect shell washer holes and create RIGIDS in batch."] \
        auto_hole_rbe2 [list "识别实体通孔并自动创建 RBE2 或 RBE3。" "Detect solid through-holes and create RBE2 or RBE3."] \
        rbe2_bolt_connector [list "按孔位配对创建螺栓连接。" "Pair holes and create bolt connectors."] \
        cbush_creator [list "在源节点上方创建并连接 CBUSH 单元。" "Create and connect CBUSH elements above source nodes."] \
        batch_temp_nodes [list "根据坐标文本批量创建可撤销的临时节点。" "Create undoable temporary nodes from coordinate text."] \
        batch_load_application [list "读取载荷文件并批量映射、创建载荷工况。" "Map load files and create load cases in batch."] \
        contact_setup [list "基于组件自动识别并创建接触。" "Detect and create contacts automatically from components."] \
        contact_surface_setup [list "选择两侧表面并创建局部接触。" "Create a local contact from two selected surfaces."] \
        adhesive_connector [list "按区域创建并实现胶粘连接。" "Create and realize adhesive connectors by area."] \
        solid_seam_connector [list "按节点或组件创建实体焊缝连接。" "Create solid seam connectors from nodes or components."]]

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
            desc_zh  "打开独立预处理面板：可将当前显示组件按标准两步旋转转换到车辆坐标系；一次选择多个组件，批量归档各自同名及 .数字 后缀组件；或归档名称中包含 SKELL 的骨架组件。\n归档过程显示实时进度，结果统一移动到 USELESS Assembly 并隐藏，不删除任何组件。\n坐标转换作用于当前显示组件，请在执行前确认显示范围与模型初始坐标系。"
            desc_en  "Open a dedicated preprocessing panel: rotate all displayed components in two steps into the vehicle coordinate system; select multiple components and batch-archive every selected name family (base names and .number duplicates); or archive skeleton components whose names contain SKELL.\nArchiving shows live progress; results are moved to the USELESS assembly and hidden, and nothing is deleted.\nThe coordinate conversion affects all displayed components, so verify the display set and starting coordinate system first."
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
            desc_zh  "选择已有网格上的节点路径并投影到目标组件：单个边界点可扩展为与目标局部平面平行的完整开放/闭合直线或曲线，内部单点仍处理所属组件的全部闭合自由边。随后以局部目标 Elements 调用 Mesh Edit Create Patch，直接创建焊缝壳并仅重绘新增 patch。\nFAST_AUTO 路径自动识别 T 型/搭接候选，经确认后直接导入现有边创建壳焊缝；LEGACY_MANUAL 使用原生 Create Patch。\n每条路径/候选都是原生撤销栈上的独立动作，失败自动回滚；成功批次可在主面板点击“撤回”，或直接 Ctrl+Z 逐步撤销。"
            desc_en  "Pick a mesh node path and project it to target components. A single boundary node expands to the complete parallel open/closed line or curve, while an internal node still selects all closed free boundaries of its component. Mesh Edit Create Patch then creates the weld shell directly from a local target Elements scope, and only the new patch is remeshed.\nFAST_AUTO imports accepted existing-edge candidates; LEGACY_MANUAL uses native Create Patch.\nEach path/candidate is its own action on the native undo stack and rolls back on failure; a finished batch can be undone from the home panel or step-by-step with Ctrl+Z."
            proc     "::MeshSeamWeld::runAction"
            settings_proc "::MeshSeamWeld::runSettings"
            undo_proc "::MeshSeamWeld::undoLast"
        }
        node_patch_builder {
            group    "Mesh"
            label_zh "节点补片"
            label_en "Node Patch Builder"
            desc_zh  "按用户点选顺序，以 3 个及以上壳网格节点定义补片边界。工具优先复用满足直线偏差、转角与绕路限制的真实单元边链；缺少边链时，仅沿相邻角点连线在法向连续的局部 TRIA3/QUAD4 壳面内追踪并重构。\n歧义路径、跨空气、明显折角、非流形边、自交和过度非平面边界均会停止；边界边数越多，每条边的追踪与搜索上限按比例收紧。全部修改和补片三角化归入一个原生撤销状态，失败自动回滚。\n默认创建 PATCH_时间戳 组件；不自动识别缺口、焊缝或 Property。"
            desc_en  "Define a local shell patch with 3 or more nodes selected in perimeter order. Existing true element-edge chains are preferred under line-deviation, turn-angle, and detour limits; missing chains are traced and rebuilt only along each adjacent-corner segment across a normal-continuous local TRIA3/QUAD4 shell patch.\nAmbiguous paths, air gaps, sharp folds, non-manifold edges, self-intersection, and excessive non-planarity are rejected, and the per-side trace/search budget tightens as the boundary gains sides. Splits and patch triangulation share one native undo state and roll back together on failure.\nA timestamped PATCH component is created by default; holes, welds, and properties are never inferred."
            proc     "::NodePatch::runAction"
            undo_proc "::NodePatch::undoLast"
        }
        fem_auto_seam {
            group    "Mesh"
            label_zh "FEM 自动焊缝"
            label_en "FEM Automatic Seam"
            desc_zh  "Python 识别 T 型与贴片焊缝并只输出已有节点种子：完整单目标 T 边、以及小贴片完整投影到单一大板的自由边属于可信项。\n可信项直接调用现有网格焊缝的 nodes+comps 局部 patch、imprint、优化与创建链路，不再由 FEM 后台切分或重开模型。\n设置页提供“快速删除焊缝”；本模块的快捷键也直接进入此删除与底面局部重绘流程，不再打开设置面板。"
            desc_en  "Python recognizes T and patch welds and outputs existing-node seeds only. Complete single-target T edges and a smaller patch fully projected onto one larger plate are trusted.\nTrusted seeds call the existing Mesh Seam Weld nodes+comps local patch, imprint, optimization, and creation chain; no FEM-side split or model reopen remains.\nThe settings page provides Quick Delete Weld; this module's shortcut enters that deletion and local supporting-mesh remesh flow directly instead of opening settings."
            proc     "::FemAutoSeam::runAction"
            shortcut_proc "::FemAutoSeam::quickDeleteWeld"
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
        mesh_add_washer {
            group    "Mesh"
            label_zh "添加 Washer"
            label_en "Add Washer"
            desc_zh  "在纯壳网格（无几何）上为既有 FE 孔创建规则 washer：选择孔边一个节点，自动定位所属 component 并用原生 Find Edges 提取自由边，按纯拓扑连通性回溯完整闭合孔边并统计当前孔周节点数。\n随后直接调用 HyperMesh 原生 *add_multi_washer_elements，按目标 hole_density 重建孔周并创建指定层数与每层径向宽度的 washer；降密度请求按用户指定值透传，不做宏层保留原密度处理。\n开放边、分叉/T 连接与多 component 歧义会拒绝执行且不修改网格；临时 ^edges 自动清理，不创建 rigid 与局部坐标系。holeDensity 与 layerWidths 配置在 modules/mesh_add_washer.tcl 顶部，密度调整结果以创建后的孔周复检输出为准。"
            desc_en  "Create a regular washer on an existing FE hole of a geometry-free shell mesh: pick one hole-edge node, the tool locates the owning component, extracts native Find Edges free edges, traces the complete closed hole loop by pure topology, and reports the current hole-ring node count.\nIt then calls HyperMesh's native *add_multi_washer_elements to rebuild the hole boundary at the target hole_density and lay the configured washer layers with per-layer radial widths; density requests are passed through verbatim instead of keeping the original density like the GUI macro.\nOpen edges, branching/T-junctions, and multi-component ambiguity are rejected without modifying the mesh; temporary ^edges data is cleaned up, and no rigid or local system is created. holeDensity and layerWidths are configured at the top of modules/mesh_add_washer.tcl; the achieved density is reported by the post-creation re-check."
            proc     "::WasherTool::run"
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
            label_zh "自动接触"
            label_en "AutoContact"
            desc_zh  "打开统一接触子界面，默认以 Component 为来源并调用 HyperMesh 官方 AutoContact API；也可切换到 SURF 来源，沿用原有双 Face 建接触链路。\nComponent 模式支持 tolerance、反向角、壳厚、相交检查、合并、CONTACT/TIE、PCONT 与 Review；SURF 不支持的选项会在同一界面中禁用。"
            desc_en  "Open the unified contact panel, defaulting to Component input and HyperMesh's official AutoContact API. Switch to SURF to use the retained two-face workflow.\nComponent mode supports tolerance, reverse angle, shell thickness, intersection checks, consolidation, CONTACT/TIE, PCONT and review; unsupported SURF options remain visible but disabled."
            proc     "::ContactSetup::runAction"
            settings_proc "::ContactSetup::runSettings"
        }
        contact_surface_setup {
            file     contact_setup
            group    "Connector"
            label_zh "按面创建接触"
            label_en "Surface Contact"
            desc_zh  "原有接触创建入口：在统一接触子界面中预选 SURF 来源，连续选择两侧 Face，筛选空间公共区域后创建相向 SURF 与 OptiStruct CONTACT group。\n保留 SLIDE/STICK/FREEZE、主面策略和接触修剪能力；可在界面中切换为 Component AutoContact。"
            desc_en  "Legacy contact entry: open the shared panel with SURF selected, pick two opposing faces, filter their common region, and create facing surfaces plus an OptiStruct CONTACT group.\nSLIDE/STICK/FREEZE, main-side selection, and trimming remain available; Component AutoContact can still be selected in the panel."
            proc     "::ContactSetup::runSurfaceAction"
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
            desc_zh  "打开实体焊缝子面板，选择 nodes+comps、comps+comps 或 Auto 输入、T/B/L 类型、spacing/tolerance/width 和正侧/负侧/双侧。\nnodes+comps 默认 node path，支持单点闭环与多点路径；选择目标组件后自动补齐源组件。Auto 根据局部网格和几何推导类型与数值参数。\n两两一组缓存，第一步空选后批量执行；第二步空选仅取消当前组。创建 PENTA6 + RBE3，输出归入 SEAM_SOLID，结束后恢复子面板。"
            desc_en  "Choose nodes+comps, comps+comps or Auto, with manual T/B/L and dimensions or inferred Auto parameters.\nNative node path accepts ordered nodes or a closed-boundary seed, followed by a target component; the source is inferred.\nCache complete pairs, then submit with an empty first selection. Empty target cancels only that pair. Create PENTA6 + RBE3 in SEAM_SOLID and restore the panel after execution."
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

proc ::HWToolkit::moduleSummary {key info} {
    variable HOME_SUMMARIES
    if {[dict exists $HOME_SUMMARIES $key]} {
        set pair [dict get $HOME_SUMMARIES $key]
        return [::HWFlow::txt [lindex $pair 0] [lindex $pair 1]]
    }
    set desc [::HWToolkit::moduleText $info desc]
    return [lindex [split $desc "\n"] 0]
}

proc ::HWToolkit::homeSectionText {section} {
    switch -- $section {
        "Common"     { return [::HWFlow::txt "常用" "Common"] }
        "All"        { return [::HWFlow::txt "全部" "All"] }
        "Geometry"   { return [::HWFlow::txt "几何准备" "Geometry"] }
        "Meshing"    { return [::HWFlow::txt "网格处理" "Meshing"] }
        "Weld"       { return [::HWFlow::txt "焊缝" "Weld"] }
        "Connection" { return [::HWFlow::txt "连接与载荷" "Connection & Loads"] }
    }
    return $section
}

proc ::HWToolkit::homeBusinessSection {key} {
    switch -- $key {
        geometry_preprocess - midsurf - geometry_cleanup -
        bom_material_assignment {
            return Geometry
        }
        batch_mesher - node_patch_builder - mesh_add_washer -
        local_mesh_optimizer - batch_property_assignment {
            return Meshing
        }
        seam_surface - mesh_seam_weld - fem_auto_seam -
        weld_integrity_check - solid_seam_connector {
            return Weld
        }
        shell_washer_hole_rbe2 - auto_hole_rbe2 - rbe2_bolt_connector -
        cbush_creator - batch_temp_nodes - batch_load_application -
        contact_setup - contact_surface_setup - adhesive_connector {
            return Connection
        }
    }
    return Connection
}

proc ::HWToolkit::homeStateFile {} {
    return [file join [::HWFlow::configDir] home.cfg]
}

proc ::HWToolkit::validHomeKeyList {values} {
    variable MODULES
    set result {}
    foreach key $values {
        if {[dict exists $MODULES $key] &&
            [::HWToolkit::moduleVisible [dict get $MODULES $key]] &&
            [lsearch -exact $result $key] < 0} {
            lappend result $key
        }
    }
    return $result
}

proc ::HWToolkit::loadHomeState {} {
    variable HOME_STATE_LOADED
    variable HOME_FAVORITES
    variable HOME_RECENTS
    variable HOME_DEFAULT_FAVORITES
    if {$HOME_STATE_LOADED} { return }
    set HOME_STATE_LOADED 1
    set HOME_FAVORITES [::HWToolkit::validHomeKeyList $HOME_DEFAULT_FAVORITES]
    set HOME_RECENTS {}

    set path [::HWToolkit::homeStateFile]
    if {![file isfile $path]} { return }
    if {[catch {set text [::HWFlow::readTextFile $path]}]} { return }
    foreach line [split $text "\n"] {
        set pos [string first "=" $line]
        if {$pos < 1} { continue }
        set name [string trim [string range $line 0 [expr {$pos - 1}]]]
        set value [string trim [string range $line [expr {$pos + 1}] end]]
        set values {}
        foreach item [split $value ","] {
            set item [string trim $item]
            if {$item ne ""} { lappend values $item }
        }
        switch -- $name {
            favorites { set HOME_FAVORITES [::HWToolkit::validHomeKeyList $values] }
            recents   { set HOME_RECENTS [::HWToolkit::validHomeKeyList $values] }
        }
    }
}

proc ::HWToolkit::saveHomeState {} {
    variable HOME_FAVORITES
    variable HOME_RECENTS
    set text "version=1\n"
    append text "favorites=[join $HOME_FAVORITES ,]\n"
    append text "recents=[join $HOME_RECENTS ,]\n"
    catch {::HWFlow::writeTextFile [::HWToolkit::homeStateFile] $text}
}

proc ::HWToolkit::homeCommonKeys {} {
    variable HOME_FAVORITES
    variable HOME_RECENTS
    ::HWToolkit::loadHomeState
    set result $HOME_FAVORITES
    set added 0
    foreach key $HOME_RECENTS {
        if {[lsearch -exact $result $key] >= 0} { continue }
        lappend result $key
        incr added
        if {$added >= 4} { break }
    }
    return $result
}

proc ::HWToolkit::homeIsFavorite {key} {
    variable HOME_FAVORITES
    ::HWToolkit::loadHomeState
    return [expr {[lsearch -exact $HOME_FAVORITES $key] >= 0}]
}

proc ::HWToolkit::toggleHomeFavorite {key} {
    variable HOME_FAVORITES
    ::HWToolkit::loadHomeState
    set index [lsearch -exact $HOME_FAVORITES $key]
    if {$index >= 0} {
        set HOME_FAVORITES [lreplace $HOME_FAVORITES $index $index]
    } else {
        lappend HOME_FAVORITES $key
    }
    ::HWToolkit::saveHomeState
    ::HWToolkit::refreshHomeContent
}

proc ::HWToolkit::rememberHomeModule {key} {
    variable HOME_RECENTS
    ::HWToolkit::loadHomeState
    set index [lsearch -exact $HOME_RECENTS $key]
    if {$index >= 0} { set HOME_RECENTS [lreplace $HOME_RECENTS $index $index] }
    set HOME_RECENTS [linsert $HOME_RECENTS 0 $key]
    if {[llength $HOME_RECENTS] > 8} { set HOME_RECENTS [lrange $HOME_RECENTS 0 7] }
    ::HWToolkit::saveHomeState
}

proc ::HWToolkit::homeSectionKeys {section} {
    variable MODULES
    if {$section eq "Common"} { return [::HWToolkit::homeCommonKeys] }
    set keys {}
    foreach {key info} $MODULES {
        if {![::HWToolkit::moduleVisible $info]} { continue }
        if {$section eq "All" || [::HWToolkit::homeBusinessSection $key] eq $section} {
            lappend keys $key
        }
    }
    return $keys
}

proc ::HWToolkit::homeFilteredKeys {} {
    variable MODULES
    variable HOME_SECTION
    variable HOME_FILTER
    set query [string tolower [string trim $HOME_FILTER]]
    set keys [::HWToolkit::homeSectionKeys $HOME_SECTION]
    if {$query eq ""} { return $keys }

    set matches {}
    foreach key [::HWToolkit::visibleModuleKeys] {
        set info [dict get $MODULES $key]
        set haystack [string tolower [join [list $key \
            [::HWToolkit::moduleText $info label] \
            [::HWToolkit::moduleSummary $key $info] \
            [::HWToolkit::moduleText $info desc] \
            [::HWToolkit::homeSectionText [::HWToolkit::homeBusinessSection $key]] \
            [::HWToolkit::groupText [dict get $info group]]] " "]]
        if {[string first $query $haystack] >= 0} { lappend matches $key }
    }
    return $matches
}

proc ::HWToolkit::clearExistingWindows {} {
    catch {::MidSurf::savePanelState}
    catch {set ::BomMaterialAssignment::ui(ok) 0}
    catch {::AutoHoleRBE2::savePanelState}
    catch {::RB2W::savePanelState}
    catch {::BatchMesher::savePanelState}
    catch {::MeshSeamWeld::saveState}
    catch {::NodePatch::close}
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
        .node_patch_builder
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

# Searchable, sectioned home panel shared by HyperMesh 2019 and HyperWorks
# 2022.  Only one section is visible at a time; search spans the whole module
# library.  Low-frequency actions live in a row menu so the primary Run action
# remains visually clear.
proc ::HWToolkit::showPanelHome {} {
    variable HOME_FILTER
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
    wm minsize $w 660 460
    wm resizable $w 1 1

    set bodyBg        [::HWFlow::uiColors bodyBg]
    set textPrimary   [::HWFlow::uiColors textPrimary]
    set textSecondary [::HWFlow::uiColors textSecondary]

    ::HWFlow::uiWidget frame $w.header -background $bodyBg
    pack $w.header -fill x -padx 14 -pady {10 0}
    ::HWFlow::uiWidget label $w.header.title -text "HyperMesh Toolkit" \
        -font [::HWFlow::uiFont header] -foreground $textPrimary \
        -background $bodyBg -anchor w
    set version [::HWFlow::hyperWorksVersion]
    if {$version eq ""} { set version "HyperWorks" }
    ::HWFlow::uiWidget label $w.header.version -text $version \
        -font [::HWFlow::uiFont small] -foreground $textSecondary \
        -background $bodyBg -anchor e
    menu $w.header.menu -tearoff 0
    $w.header.menu add command -label [::HWFlow::txt "查看使用指南" "View Guide"] \
        -command ::HWToolkit::openGuide
    $w.header.menu add command -label [::HWFlow::txt "复制诊断信息" "Copy Diagnostics"] \
        -command ::HWToolkit::copyDiagnostics
    ::HWFlow::uiWidget button $w.header.help -text "?" -width 3 -cursor hand2 \
        -command [list ::HWToolkit::showHomeMenu $w.header.menu $w.header.help]
    pack $w.header.version -side right
    pack $w.header.help -side right -padx {0 8}
    pack $w.header.title -side left

    ::HWFlow::uiWidget frame $w.search -background $bodyBg
    pack $w.search -fill x -padx 14 -pady {8 4}
    ::HWFlow::uiWidget label $w.search.label \
        -text [::HWFlow::txt "搜索工具" "Search tools"] -background $bodyBg -anchor w
    ::HWFlow::uiWidget entry $w.search.entry -textvariable ::HWToolkit::HOME_FILTER \
        -background [::HWFlow::uiColors inputBg] -foreground [::HWFlow::uiColors inputFg]
    ::HWFlow::uiWidget button $w.search.clear -text [::HWFlow::txt "清除" "Clear"] \
        -width 7 -command ::HWToolkit::clearHomeFilter -cursor hand2
    pack $w.search.label -side left -padx {0 8}
    pack $w.search.clear -side right -padx {6 0}
    pack $w.search.entry -side left -fill x -expand 1
    bind $w.search.entry <KeyRelease> {after idle ::HWToolkit::refreshHomeContent}

    ::HWFlow::groove $w.rule
    pack $w.rule -fill x -padx 14 -pady {4 0}

    ::HWFlow::uiWidget frame $w.tabs -background $bodyBg
    pack $w.tabs -fill x -padx 14 -pady {8 4}
    foreach section {Common All Geometry Meshing Weld Connection} {
        set count [llength [::HWToolkit::homeSectionKeys $section]]
        set label [::HWToolkit::homeSectionText $section]
        if {$section ne "All"} { append label " $count" }
        set name [string tolower $section]
        ::HWFlow::uiWidget button $w.tabs.$name -text $label -width 12 \
            -command [list ::HWToolkit::selectHomeSection $section] -cursor hand2
        pack $w.tabs.$name -side left -padx {0 5}
    }

    ::HWFlow::scrollableFrame $w.body
    pack $w.body -fill both -expand 1 -padx 14 -pady {2 6}
    catch {$w.body.c configure -height 390}
    bind $w.body.c <Configure> +[list ::HWToolkit::scheduleHomeScroll $w]
    ::HWToolkit::refreshHomeContent

    set footer [::HWFlow::actionBar $w.foot]
    pack $w.foot -fill x -padx 14 -pady {0 10}
    ::HWFlow::uiWidget button $footer.shortcuts \
        -text [::HWFlow::txt "工具箱设置" "Toolbox Settings"] -width 13 \
        -command ::HWShortcut::showSettings -cursor hand2
    pack $footer.shortcuts -side left
    ::HWFlow::uiWidget button $footer.topmost -text [::HWToolkit::topmostButtonText] \
        -width 16 -command ::HWToolkit::toggleProjectTopmost -cursor hand2
    pack $footer.topmost -side right -padx {0 6}
    ::HWFlow::uiWidget button $footer.close -text [::HWFlow::txt "关闭" "Close"] -width 10 \
        -command ::HWToolkit::closePanel -cursor hand2
    pack $footer.close -side right

    bind $w <Escape> ::HWToolkit::closePanel
    wm protocol $w WM_DELETE_WINDOW ::HWToolkit::closePanel

    ::HWFlow::centerWindow $w 720 620
    wm deiconify $w
    catch {raise $w}
    catch {focus $w}
    ::HWToolkit::updateHomeScroll $w
    return $w
}

proc ::HWToolkit::clearHomeFilter {} {
    variable HOME_FILTER
    set HOME_FILTER ""
    ::HWToolkit::refreshHomeContent
    catch {focus .hwtoolkit.search.entry}
}

proc ::HWToolkit::selectHomeSection {section} {
    variable HOME_SECTION
    set HOME_SECTION $section
    ::HWToolkit::refreshHomeContent
}

proc ::HWToolkit::refreshHomeContent {} {
    variable MODULES
    variable HOME_SECTION
    variable HOME_FILTER
    set w .hwtoolkit
    if {[llength [info commands winfo]] == 0} { return }
    if {![winfo exists $w.body.c.inner]} { return }
    set content $w.body.c.inner

    foreach section {Common All Geometry Meshing Weld Connection} {
        set button $w.tabs.[string tolower $section]
        if {![winfo exists $button]} { continue }
        catch {$button configure -relief [expr {$section eq $HOME_SECTION ? "sunken" : "raised"}]}
    }
    foreach child [winfo children $content] { catch {destroy $child} }

    set keys [::HWToolkit::homeFilteredKeys]
    set query [string trim $HOME_FILTER]
    if {$query ne ""} {
        set heading [::HWFlow::txt "搜索结果（[llength $keys]）" "Search results ([llength $keys])"]
    } else {
        set heading "[::HWToolkit::homeSectionText $HOME_SECTION]（[llength $keys]）"
    }
    ::HWFlow::groupHeader $content.heading $heading
    pack $content.heading -fill x -pady {4 3}

    if {[llength $keys] == 0} {
        ::HWFlow::uiWidget label $content.empty \
            -text [::HWFlow::txt "没有匹配的工具，请尝试名称或功能关键词。" "No matching tools. Try a name or capability keyword."] \
            -font [::HWFlow::uiFont default] -foreground [::HWFlow::uiColors textSecondary] \
            -background [::HWFlow::uiColors bodyBg] -anchor w
        pack $content.empty -fill x -padx 8 -pady 18
    } else {
        foreach key $keys {
            ::HWToolkit::buildHomeRow $content $key [dict get $MODULES $key]
        }
    }
    update idletasks
    catch {$w.body.c configure -scrollregion [$w.body.c bbox all]}
    catch {$w.body.c yview moveto 0}
    ::HWToolkit::scheduleHomeScroll $w
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

# One compact tool row: summary and shortcut status are informational; Run is
# the single primary action and the menu holds settings/help/key binding.
proc ::HWToolkit::buildHomeRow {parent key info} {
    set row $parent.r_$key
    set bodyBg [::HWFlow::uiColors bodyBg]
    ::HWFlow::uiWidget frame $row -background $bodyBg
    pack $row -fill x -padx 4 -pady 3

    set favorite [::HWToolkit::homeIsFavorite $key]
    ::HWFlow::uiWidget button $row.favorite -width 3 \
        -text [expr {$favorite ? "★" : "☆"}] \
        -font [::HWFlow::uiFont default] -cursor hand2 \
        -command [list ::HWToolkit::toggleHomeFavorite $key]
    pack $row.favorite -side left -padx {0 2}

    ::HWFlow::uiWidget frame $row.text -background $bodyBg
    pack $row.text -side left -fill x -expand 1 -padx {4 10}
    ::HWFlow::uiWidget label $row.name -text [::HWToolkit::moduleText $info label] \
        -font [::HWFlow::uiFont module] -anchor w -cursor hand2 \
        -foreground [::HWFlow::uiColors textPrimary] -background $bodyBg
    ::HWFlow::uiWidget label $row.summary -text [::HWToolkit::moduleSummary $key $info] \
        -font [::HWFlow::uiFont small] -anchor w \
        -foreground [::HWFlow::uiColors textSecondary] -background $bodyBg
    pack $row.name -in $row.text -fill x
    pack $row.summary -in $row.text -fill x -pady {1 0}
    bind $row.name <Button-1> [list ::HWToolkit::runModule $key]
    bind $row.name <Enter> [list ::HWToolkit::homeRowHover $row.name 1]
    bind $row.name <Leave> [list ::HWToolkit::homeRowHover $row.name 0]

    menu $row.menu -tearoff 0
    if {[dict exists $info settings_proc]} {
        $row.menu add command -label [::HWFlow::txt "设置" "Settings"] \
            -command [list ::HWToolkit::settingsModule $key]
    }
    if {[dict exists $info undo_proc]} {
        $row.menu add command -label [::HWFlow::txt "撤回最近操作" "Undo Latest Action"] \
            -command [list ::HWToolkit::undoModule $key]
    }
    $row.menu add command -label [::HWFlow::txt "模块说明" "Module Help"] \
        -command [list ::HWToolkit::helpModule $key]
    $row.menu add command -label [::HWFlow::txt "设置快捷键" "Set Shortcut"] \
        -command [list ::HWShortcut::showForModule $key]
    $row.menu add separator
    if {$favorite} {
        set favoriteLabel [::HWFlow::txt "从常用中移除" "Remove from Common"]
    } else {
        set favoriteLabel [::HWFlow::txt "添加到常用" "Add to Common"]
    }
    $row.menu add command -label $favoriteLabel \
        -command [list ::HWToolkit::toggleHomeFavorite $key]

    ::HWFlow::uiWidget button $row.more -width 6 -text [::HWFlow::txt "更多" "More"] \
        -font [::HWFlow::uiFont default] -cursor hand2 \
        -command [list ::HWToolkit::showHomeMenu $row.menu $row.more]
    pack $row.more -side right -padx {4 2}
    ::HWFlow::uiWidget button $row.run -width 8 -text [::HWFlow::txt "运行" "Run"] \
        -font [::HWFlow::uiFont default] -cursor hand2 \
        -command [list ::HWToolkit::runModule $key]
    pack $row.run -side right -padx {4 0}
    ::HWFlow::uiWidget label $row.shortcut -text [::HWToolkit::shortcutText $key] \
        -font [::HWFlow::uiFont small] -anchor e \
        -foreground [::HWFlow::uiColors textSecondary] -background $bodyBg
    pack $row.shortcut -side right -padx {4 6}
}

proc ::HWToolkit::showHomeMenu {menuWidget buttonWidget} {
    if {![winfo exists $menuWidget] || ![winfo exists $buttonWidget]} { return }
    tk_popup $menuWidget [winfo rootx $buttonWidget] \
        [expr {[winfo rooty $buttonWidget] + [winfo height $buttonWidget]}]
}

proc ::HWToolkit::homeRowHover {nameWidget active} {
    if {![winfo exists $nameWidget]} { return }
    if {$active} {
        catch {$nameWidget configure -foreground [::HWFlow::uiColors accent]}
    } else {
        catch {$nameWidget configure -foreground [::HWFlow::uiColors textPrimary]}
    }
}

# Compatibility helper retained for shortcut-manager callers that need a
# binding prompt instead of the home row's muted status text.
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
            catch {$button configure -text [::HWToolkit::shortcutText $key]}
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

    ::HWToolkit::rememberHomeModule $key
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

proc ::HWToolkit::undoModule {key} {
    variable MODULES
    variable MODULE_BUSY
    if {$MODULE_BUSY || ![dict exists $MODULES $key]} { return 0 }
    set info [dict get $MODULES $key]
    if {![dict exists $info undo_proc]} { return 0 }
    if {![::HWToolkit::ensureCoreLoaded] ||
        ![::HWToolkit::sourceOneModule $key $info]} {
        return 0
    }
    if {[catch {::HWFlow::requireEngineeringContext} preflightError]} {
        catch {hm_usermessage $preflightError}
        return 0
    }
    set procName [dict get $info undo_proc]
    if {[llength [info commands $procName]] == 0} { return 0 }
    set MODULE_BUSY 1
    set code [catch {uplevel #0 [list $procName]} err opts]
    set MODULE_BUSY 0
    catch {::HWFlow::refreshBrowser}
    if {$code} {
        if {[llength [info commands tk_messageBox]] > 0} {
            tk_messageBox -icon error -title [::HWFlow::txt "撤回失败" "Undo Failed"] -message $err
        } else {
            catch {hm_usermessage $err}
        }
        return 0
    }
    return 1
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
