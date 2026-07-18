# 四模块 Python + Tcl 混合架构重构分析

## 1. 范围与结论

本分析以当前仓库中的实际 Tcl 实现为唯一业务行为基线，覆盖：

- `modules/auto_hole_rbe2.tcl`
- `modules/shell_washer_hole_rbe2.tcl`
- `modules/rbe2_bolt_connector.tcl`
- `modules/mesh_seam_weld.tcl`

参考实现为 `modules/solid_seam_connector.tcl`、`modules/solid_seam/` 和
`modules/local_mesh_optimizer.tcl`。迁移采用以下不可破坏边界：

1. Python 3.8+ 只处理已导出的纯数据，不调用 HyperMesh API。
2. Tcl 保留 UI、选择、配置持久化、HyperMesh 读写、创建、删除、刷新和最终验证。
3. 四个顶层 Tcl 文件、命名空间和公共入口保持不变。
4. 每个模块保留 `legacy_tcl`，新增 `python` 与 `compare` 后端；完成 HyperMesh 2019 回归前不删除旧算法。
5. 所有 Python 运行使用独立任务目录，JSON 用于审计，安全 Tcl sidecar 用于 HM2019 读取。
6. 不引入第三方 Python 包，不更改 GUI 框架、快捷键注册或现有配置文件位置。

现有 `solid_seam` 已验证了内置 Python 优先、`python3`/`python` 回退、隔离运行时
`sys.path` 修正、JSON + Tcl sidecar 的基本方向；但其任务目录、结果状态、run_id
校验和通用错误处理仍是模块私有实现，不能直接复制为四模块公共层。

## 2. 当前公共入口与外部依赖

| 模块 | 命名空间 | 主入口 | 设置入口 | 主界面注册 | 配置持久化键 |
| --- | --- | --- | --- | --- | --- |
| auto_hole_rbe2 | `::AutoHoleRBE2` | `run`, `runAction` | `runSettings` | `hw_toolkit_core.tcl` | `auto_hole_rbe2` |
| shell_washer_hole_rbe2 | `::RB2W` | `run`, `runAction` | `runSettings` | `hw_toolkit_core.tcl` | 现有 `stateKeys` |
| rbe2_bolt_connector | `::RB2Bolt` | `run`, `runAction` | `runSettings` | `hw_toolkit_core.tcl` | `rbe2_bolt_connector` |
| mesh_seam_weld | `::MeshSeamWeld` | `run`, `runAction` | `runSettings` | `hw_toolkit_core.tcl` | `mesh_seam_weld` |

这些入口及 `savePanelState`/`saveState` 调用链必须保留。`workflow_common.tcl` 提供
状态、进度、文件和浏览器刷新能力，是 Tcl 侧桥接的既有基础依赖。

## 3. 函数迁移分类

分类标记：

- **T**：保留在 Tcl，涉及 UI、HyperMesh 访问或模型修改。
- **P**：将算法主体迁移到 Python；旧 Tcl 函数暂时保留用于回退/对比。
- **W**：保留同名 Tcl 兼容包装，Python 默认后端稳定后可缩减主体。
- **D**：只可在等价迁移、单元测试和 HM2019 对比验证全部通过后删除。

### 3.1 auto_hole_rbe2

| 类别 | 现有函数 | 归属 | 说明 |
| --- | --- | --- | --- |
| UI/配置 | `backToHome`, `savePanelState`, `showPanel`, `pickComponents`, `applyPreset`, `acceptPanel`, `saveSettingsPanel` | T | 保留界面、选择和原配置键 |
| 日志/流程 | `initLog`, `closeLog`, `log`, `message`, `warning`, `clearMarks`, `runCore`, `runCurrentSelection`, `runAction`, `runSettings`, `run` | T/W | `runCore` 成为后端分派器，旧主体转 legacy 路径 |
| 通用纯数据 | `uniq`, `edgeKey`, `edgeNodes`, `vdot`, `vcross`, `vadd`, `vsub`, `vscale`, `vnorm`, `vnormalize` | P/D | 迁移到 hybrid_core；旧函数在 compare 稳定前保留 |
| HM 数据读取 | `nodeXYZ`, `elemNodes`, `elemConfig`, `isSolidElem`, `getElemsByComp`, `componentIdByName` | T | 批量导出取代 Python 内查询，不删除兼容函数 |
| 几何/拓扑 | `faceEdges`, `faceNormal`, `centroidNodes`, `loopNormal`, `projectPointOnLine`, `pointLineDistance`, `meanRadius`, `buildLoopsFromEdges`, `boundaryLoops`, `segmentFaces`, `evaluateHoleSegment` | P/W | 保持原阈值与分段规则，输出拒绝原因 |
| 重复检测 | `elemLooksLikeRBE2`, `rigidCenterNode`, `rbe2DependentNodeKey`, `initExistingRBE2Index`, `existingRBE2ForWallNodes` | T+P/W | Tcl 导出实体记录，Python 建索引并判重 |
| 模型修改 | `deleteComponentByName`, `enableInteractiveBrowserUpdates`, `ensureComponent`, `markComponentByName`, `refreshComponentBrowser`, `rememberCreatedRBE2`, `createRBE2` | T | 创建前后验证仍在 Tcl |

关键数据依赖：当前实现先对所选实体组件执行 `*findfaces`，从 `^faces` 读取临时
自由面，再按相邻面法向阈值分段。Python 后端第一版应复用该已验证自由面来源，
同时导出原始实体连接关系，为后续消除临时面依赖保留审计数据。不能假设任意
HyperMesh 2019 profile 都能从实体 config 无歧义推导全部高阶面。

主要风险：自由面元素 ID 是临时 ID；结果中的 `segment_face_ids` 只用于审计，创建
必须依赖稳定的原始 wall node IDs。`requireInnerNormal`、`innerNormalMaxDot`、半径范围、
拟合误差和双端闭环规则必须逐项对照 `evaluateHoleSegment`。

### 3.2 shell_washer_hole_rbe2

| 类别 | 现有函数 | 归属 | 说明 |
| --- | --- | --- | --- |
| UI/状态/日志 | `log`, `status`, `resetOverallProgress`, `stateKeys`, `loadState`, `saveState`, `backToHome`, `savePanelState`, `showPanel`, `pickComponents`, `applyPreset`, `acceptPanel`, `saveSettingsPanel`, `overallStatus`, `printParameterLog` | T | UI 语义和所有参数保持一致 |
| 性能缓存 | `beginPerformanceMode`, `enableInteractiveBrowserUpdates`, `resumePerformanceModeAfterBrowserUpdate`, `endPerformanceMode`, `clearNodeXYZCache`, `clearComponentElemCache`, `resetRBE2CandidateCache`, `addUniqueToArrayList`, `bumpReason`, `formatReasonStats` | T/W | Tcl 侧仍需控制 UI 和导出缓存；统计可由 Python 汇总 |
| HM 数据读取 | `getElemNodes`, `getNodeXYZRaw`, `getNodeXYZ`, `getElemsByComp`, `elemConfigLooksLikePlainShell`, `markElementCandidates`, `markRigidLinkCandidates`, `rbe2CandidateMarkIds`, `rbe2CandidateComponentId`, `ensureRBE2CandidateComponentIndex`, `rbe2CandidatesFromComponents`, `componentHasRBE2`, `outputComponentCandidatesForSource`, `existingRBE2CheckForSource`, `projectRBE2ComponentIds` | T | 负责批量导出 shell 与 RBE2 记录 |
| 纯数据/拓扑 | `uniq`, `edgeKey`, `distance3`, `loopGeometry`, `loopShape`, `buildGraph`, `findFreeEdgeLoops`, `seedElemsFromLoop`, `expandElementLayers`, `nodesFromElems`, `listSubtract`, `listChunks` | P/W | 迁移到 Python，保留 legacy 对比 |
| 孔/垫圈识别 | `isValidHoleLoop`, `validateWasherAndGetDepNodes`, `processComponent` | P/W | `processComponent` 拆成 Tcl 导出/执行与 Python 规划 |
| RBE2 判重/清理规划 | `elemLooksLikeRBE2`, `rigidCenterNode`, `rbe2DependentNodeKey`, `rbe2RecordForCleanup`, `indexRBE2InComponent`, `initExistingRBE2IndexForSource`, `existingRBE2ForDepNodes`, `rememberRBE2ForDepNodes`, `cleanupDuplicateRBE2InOutputComponents`, `mergeDuplicateRBE2ForSources` | T+P/W | Tcl 读写；Python 生成保留/删除计划；删除仍由 Tcl 执行 |
| Component/实体修改 | `componentExistsByName`, `deleteComponentByName`, `componentIdByName`, `getComponentName`, `sanitizeNamePart`, `sourceOutputBaseName`, `uniqueComponentName`, `setCurrentComponent`, `createComponentByName`, `ensureOutputComponent`, `markComponentByName`, `showOutputComponent`, `showAllOutputComponents`, `refreshBrowsersAndGraphics`, `countEntitiesInComponent`, `outputComponentSummary`, `moveMarkToComponent`, `deleteEntitiesByIds`, `organizeCreatedRBE2Elements`, `getLastCreatedOnMark`, `createCenterNode`, `createRigidLink`, `runRebuildCleanup` | T | 保留命名、批量整理与清理语义 |
| 公共入口 | `collectProjectRBE2`, `collectProjectRBE2FromSettings`, `main`, `runCurrentSelection`, `run`, `runAction`, `runSettings` | T/W | 保持入口；`runCurrentSelection` 增加后端分派 |

关键参数共 18 项孔/垫圈规则：直径 6~30、圆度、椭圆允许及轴比、内环节点数、
washer 层数、外环拟合、中心偏差、最小宽度、单元数与外环节点比例。迁移时必须
全部进入 request.settings，不能只迁移圆孔判断。

主要风险：自由边图中分支、开放路径和非流形边目前由 Tcl 的遍历顺序隐式处理；
Python 必须稳定排序并显式给出拒绝原因。清理重复 RBE2 属于破坏性操作，只能执行
经过 schema、run_id 和实体存在性二次验证的计划。

### 3.3 rbe2_bolt_connector

| 类别 | 现有函数 | 归属 | 说明 |
| --- | --- | --- | --- |
| UI/配置/选择 | `msg`, `backToHome`, `loadState`, `saveState`, `showDialog`, `validateParams`, `clearSelectionMarks`, `selectedElementIds`, `markIds`, `selectedElementIdsInteractive`, `rbe2CandidatesFromSelectedElements`, `rbe2CandidatesFromComponents`, `filterCandidatesByComponents`, `componentElementIdsSlow`, `markElementCandidates`, `markRigidLinkCandidates`, `markOneDElementCandidates`, `elemComponentId` | T | 选择与 HM mark 保持在 Tcl |
| 纯数据工具 | `abs`, `dist3`, `safeName`, `coordIndex`, `crossIndices`, `rangeNormalAxis`, `recIsPlanar`, `recNormalAxis`, `groupHasPlanar`, `evenFloorDiameter`, `median`, `chooseModeDiameter`, `uniqueIntegerIds`, `intersectIntegerIds`, `uniqList`, `intFloor` | P/W | 迁移到公共/模块 Python |
| RBE2 读取分析 | `nodeXYZ`, `isRigidLink`, `rbe2Record`, `collectRBE2Records` | T+P/W | Tcl 导出原始 ID/坐标/所属组件；Python 计算平面性、法向、半径 |
| 分组配对 | `ufFind`, `ufUnion`, `pairAxisAllowedByPlanarity`, `pairMatchAxis`, `buildGroupsForAxis`, `recCompareAxis`, `sortGroupByAxis`, `groupKey`, `groupSpread`, `buildGroups`, `groupDiameter`, `pairGroupRecords`, `buildBoltPairList`, `usedRBE2ElementIdsFromGroups`, `unusedShellRBE2Records`, `rbe2ElementIdsFromRecords` | P/W | Python 输出稳定 group_id、pair_id 和未使用记录 |
| Property/Material/Component | `entityIdByName`, `trySetValue`, `trySetEntityRef`, `ensureBoltMaterial`, `propertyCardForElementType`, `autoPropertyName`, `effectivePropertyName`, `circleSection`, `beamSectionName`, `ensureCircleBeamSection`, `ensureBoltProperty`, `allComponentIds`, `componentNameById`, `boltComponentInfo`, `runAssignAllBoltProperties`, `enableInteractiveBrowserUpdates`, `rememberBulkTouchedComp`, `beginBulkCreate`, `endBulkCreate`, `ensureComponentFast`, `setCurrentOutputComponentFast`, `ensureComponent`, `markComponentByName`, `refreshComponentBrowser`, `componentIdByName`, `getElemsByComp` | T | 保留现有 solver card 与命名行为 |
| Beam 判重/创建/验证 | `beamSegmentKey`, `elemLooksLike1DConnector`, `indexExistingBeamSegments`, `existingBeamSegment`, `rememberBeamSegment`, `orientVecForNodes`, `createdElementIdAfter`, `assignBeamProperty`, `createdBeamHasProperty`, `createdBeamNodeIds`, `replaceOneNode`, `nodeDistanceById`, `nodesCoincident`, `forceBeamEndpointNodes`, `createdBeamUsesNodes`, `deleteElementIfKnown`, `finalizeCreatedBeam`, `createBeamBetween`, `createBeamBetweenRecords`, `createBolts`, `createBoltsFast` | T+P | Python 可规划重复项；HM 创建、纠正、属性和最终验证留 Tcl |
| 未使用项处理 | `deleteComponentByName`, `createMarkerPointOrNode`, `createUnusedShellRBE2Markers`, `markElementsForManualDelete`, `enterElementDeleteMode`, `runFindUnusedShellRBE2` | T | 保持人工复核与删除入口 |
| 公共入口 | `runCreateFromSelection`, `runAction`, `runSettings`, `run` | T/W | `runCreateFromSelection` 增加后端分派 |

关键业务规则：平面 RBE2 只能沿检测到的法向轴分组；纯空间 RBE2 分组不创建
CBEAM；直径取有意义的最小中心到 dependent node 半径的两倍并向下取偶数；同组
沿轴排序后只连接相邻记录。现有 `*barelementcreatewithoffsets`、自动 PBAR/PBEAM、
MAT1、端点纠正和属性验证不能迁入 Python。

主要风险：AUTO 轴选择和 union-find 分组存在容差边界；输出必须固定排序，compare
应比较组成员集合而不是组顺序。已有 Beam 判重需要 Tcl 导出端点、类型、属性和组件。

### 3.4 mesh_seam_weld

| 类别 | 现有函数 | 归属 | 说明 |
| --- | --- | --- | --- |
| UI/配置/选择 | `stateKeys`, `uniq`, `msg`, `loadState`, `saveState`, `centerWindow`, `showPanel`, `showMorePanel`, `acceptPanel`, `runSettings`, `clearNodeSelection`, `clearComponentSelection`, `clearTransientSelections`, `pickNodes`, `pickComponents` | T | 保留用户流程和配置 |
| HM 读取/缓存 | `resetRunCaches`, `nodeXYZ`, `elemNodes`, `componentsHaveElements`, `elemComponentId`, `nodeElementIds`, `adjacentElementsForNodes`, `cacheNodeElementIncidence`, `primeSelectedNodeElements`, `primeFreeEdgeComponent`, `componentIdsFromNodes`, `componentNames` | T | 两阶段分别批量导出模型快照 |
| 源路径拓扑 | `elementContainsEdge`, `nodesShareElementEdge`, `selectedNodesFormContinuousPath`, `freeEdgeNeighbors`, `closedFreeEdgeLoopFromNode`, `closedFreeEdgeLoopsFromSeeds` | P/W | 阶段 A Python 路径识别；保留 Tcl 回退 |
| 几何与路径 | `vsub`, `vadd`, `vscale`, `dot`, `dist2`, `distanceBetweenNodes`, `nodePathLength`, `meshDensityForLength`, `shortestMeshBoundaryPath`, `matchTargetPathNodes`, `targetPathNodesAfterImprint`, `pathPairingCost`, `rotateList`, `alignTargetPathNodes` | P/W | 公共几何 + 模块路径对齐；输出旋转/反向决策 |
| 命名/Component | `thicknessFromComponentName`, `formatThickness`, `seamComponentForRelatedComps`, `moveElemsToComponent`, `ensureOutputComponent`, `markComponents` | T | 保留厚度命名与模型组织 |
| Imprint/创建 | `entityIdsCreatedAfter`, `runImprintNodeList`, `targetNodesFromImprintList`, `createClosedStripElements`, `createRuledMeshBetweenNodePaths` | T | 模型 ID 变化、ruled surface、automesh 和闭环补片均留 Tcl |
| 流程入口 | `processWeldPath`, `runAction`, `run` | T/W | `processWeldPath` 编排阶段 A → Tcl imprint → 阶段 B → Tcl 创建 |

主要风险：imprint 之后节点 ID 变化，阶段 B 不得复用阶段 A 的目标模型快照；list 2
只有在数量一致、去重后数量一致且节点 ID 均为本次新增时才可信。闭环目标路径可能
任意起点和方向，需穷举旋转与反向并以总平方距离最小为准。现有 surface mode 2、
`*automesh` 参数和闭环最后一列补片是已落地的 HM2019 安全流程，保持在 Tcl。

## 4. 统一数据协议计划

任务目录：`runtime/tasks/<module>/<run_id>/`。每次运行新建目录，不复用结果。

固定文件：

- `request.json`：模块、run_id、HM 版本、选择、settings、options。
- `mesh.json`：组件、原始节点 ID/坐标、元素 ID/连接关系。
- `existing_entities.json`：RBE2/Beam 等已有实体记录；无数据也写空数组。
- `result.json`：完整审计结果。
- `result.tcl`：仅设置指定命名空间变量，不包含 HM 命令。
- `python_stdout.log`、`python_stderr.log`、`operation.log`。
- compare 模式附加 `comparison.json`。

公共结果必须包含 `schema_version`、`module`、`run_id`、`status`、`summary`、
`candidates`、`warnings`、`errors` 和 `performance`。Tcl 加载前验证 sidecar 只写入
当前任务的预期变量；加载后再次核对 schema、module、run_id 和 SUCCESS 状态。

## 5. 分阶段实施与退出条件

1. **阶段 1，公共桥接层**：实现 Python 解析、任务目录、UTF-8 JSON/Tcl 文件、进程
   执行、日志、schema/run_id 校验和最小自检。退出条件是项目内置 Python 3.8
   离线测试通过，Tcl 文件可被普通 Tcl 解释器语法加载；HM2019 调用留人工验证项。
2. **阶段 2，auto_hole_rbe2**：先接导出与 Python 识别，再接 Tcl 创建，最后 compare。
   退出条件是 Python 单元测试通过并生成 HM 对比报告模板。
3. **阶段 3，shell_washer_hole_rbe2**：复用公共几何/图/判重结构，不复制工具函数。
4. **阶段 4，rbe2_bolt_connector**：迁移记录分析、分组、配对、直径和未使用项规划。
5. **阶段 5，mesh_seam_weld**：实现两阶段 Python 调用，模型修改严格夹在两次调用间。
6. **阶段 6，验证与清理**：只有所有单元测试、HM2019 集成、compare、入口兼容和性能
   验证通过，才讨论删除旧 Tcl 算法；默认不在本阶段自动删除。

## 6. 验证矩阵与人工边界

自动验证包括 Python 3.8 语法、无第三方依赖、schema 错误、缺失 ID、稳定排序、
sidecar 转义、旧结果隔离、四模块算法单元测试和 comparison JSON 生成。

以下只能在 HyperMesh 2019 目标环境人工验证：

- Tcl 批量导出使用的 dataname 和 element config 是否与当前 solver profile 一致。
- `*findfaces` 临时面、RBE2 dependent/independent node 读取及创建后的实体归属。
- `*barelementcreatewithoffsets`、PBAR/PBEAM/MAT1 卡片、属性赋值和端点纠正。
- imprint list 2 行为、ruled surface mode 2、automesh 和闭环补片。
- 主界面、快捷键、配置持久化、进度、浏览器刷新和撤销边界。

在这些验证完成前，默认后端不应从 `legacy_tcl` 强制切换为 Python；开发配置可使用
`python` 或 `compare`，compare 只允许一个明确指定的后端执行模型创建。
