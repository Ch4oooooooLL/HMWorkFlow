# FEM 自动焊缝全面/压力测试模型创建指南（Agent 执行规范）

本文档用于指导 Agent 为 `fem_auto_seam` 创建可重复、可判定、能覆盖真实 HyperMesh
执行链路的 OptiStruct `.fem` 测试模型。目标不是再做一个“看起来像焊缝”的演示模型，
而是建立一套同时覆盖检测、自动规划、焊缝实现、批量重绘、质量裁决和事务回滚的强测试资产。

## 1. 开始工作前必须阅读

Agent 必须先阅读下列实现和现有资产，预期结果以当前代码为准：

- `modules/fem_auto_seam/python/backend.py`：T、贴片、近自由边检测及自动实现硬门槛；
- `modules/fem_auto_seam/python/multi_element_split_planner.py`：目标母网格拆分限制；
- `modules/fem_auto_seam/python/main.py`：UI 参数映射和已有 SEAM 去重；
- `modules/fem_auto_seam/tcl/fast_executor.tcl`：HyperMesh 分批重绘、属性保持和回滚；
- `modules/fem_auto_seam/tcl/quality_validator.tcl` 与
  `modules/fem_auto_seam/defaults/fem_auto_seam_default.criteria`：最终质量裁决；
- `modules/fem_auto_seam/tests/test_backend.py`：当前离线行为契约；
- `examples/AutoShellSeamBackend/`：10 个已版本化的基础验收夹具；
- `examples/FemAutoSeam_Validation/`：现有实机组合模型；
- `doc/validation_model_generation_conventions.md`：仓库通用生成规范。

不得直接复制现有 README 中的预测作为新模型 oracle。当前实现中，长度 34 mm、距离变化合格的
部分重叠 T 候选是自动候选；旧 `examples/FemAutoSeam_Validation/README.md` 对 F04 的 review
描述与当前 `test_backend.py` 契约不一致。新资产必须运行当前生产后端得到基线，再人工核对并冻结。

## 2. 当前功能的真实边界

默认 UI 参数如下，所有边界测试必须围绕这些值生成，并在 manifest 中逐项记录：

| 参数 | 默认值 | 对模型的实际意义 |
|---|---:|---|
| `search_distance` | 12.0 mm | T 射线或贴片双向投影的最大距离 |
| `min_seam_length` | 20.0 mm | T 路径或每个贴片闭环进入自动处理的最短长度 |
| `parallel_angle_max` | 15° | 贴片两组件平均法向夹角上限 |
| `perpendicular_angle_min` | 70° | 映射为后端 `minimum_t_normal_angle = 20°` |
| `max_distance_variation_ratio` | 0.35 | `(max-min)/average` 自动门槛 |
| `near_edge_distance` | 8.0 mm | 近自由边人工候选距离上限 |
| `near_edge_tangent_angle` | 20° | 后端固定默认值，近自由边切向夹角上限 |
| `small_hole_diameter` | 30.0 mm | 周长/π 小于该值的贴片内孔使整组不能自动 |
| `max_weld_tria_ratio` | 0.75 | zipper 焊缝三角形比例上限 |
| `existing_weld_search_distance` | 4.0 mm | 已有 SEAM 中心附近的候选降级为 review |
| `auto_accept_confidence` | 0.88 | UI 自动接受筛选，不等同于几何硬门槛 |
| `review_confidence` | 0.60 | UI 复核筛选阈值 |
| `remesh_element_size` | 8.0 mm | HyperMesh 原生重绘目标尺寸 |
| `remesh_expand_layers` | 2 | 从替换母单元向外扩展的邻接层数 |
| `remesh_feature_angle` | 30° | HyperMesh 重绘特征角 |
| `remesh_chunk_elements` | 1000 | 每批最大重绘单元数（仅 Tcl 执行阶段使用） |
| `python_workers` | 0 | 自动取最多 8；组件少于 4 或单元少于 2000 时退回单进程 |
| `max_new_failed_elements` | 0 | 相对基线允许新增的质量失败数 |

必须理解以下实现语义：

1. 只对选中组件之间配对，检测对象为一阶 `CTRIA3`/`CQUAD4` 壳；自动拆分目标必须全是一阶壳且每个目标单元有有效直接 PID。
2. T 候选来自源组件的非分叉自由边路径沿“边的外向方向”投向目标。目标法向角、长度和距离变化决定候选及自动资格。
3. T 的曲线源路径受支持，但自动目标拆分要求目标 patch 共面；非共面目标应进入规划失败/人工处理，而不是崩溃。
4. 贴片要求较小、近似平行的壳完整投影在面积更大的目标内；两组件面积差在 2% 以内时不会作为贴片处理。
5. 贴片每个非分叉闭合自由边都会形成候选。任何小内孔会使同一 patch group 全部失去自动资格；大孔目前不会触发这个硬禁用条件。
6. `NEAR_FREE_EDGES` 永远是 review，不允许自动创建。
7. 现有 SEAM 只按候选投影点中心与已有焊缝中心距离去重；命中后状态为 `POSSIBLE_DUPLICATE/REVIEW_REQUIRED`。
8. Python 不移动节点。它重写完整 FEM、拆分母单元并生成 zipper 壳；HyperMesh 打开该 FEM 替换当前模型后再分批原生重绘。
9. 任一批次发生拓扑、属性或质量错误，整个任务必须从唯一的 `before.hm` 恢复，不能留下半成品。

## 3. Agent 必须交付的资产

不要把所有目的混进一个不可诊断的巨型文件。至少生成以下三套 FEM；生成器、说明和 oracle
一并提交，生成出的 `.fem`/manifest 按仓库约定不入库：

```text
examples/FemAutoSeam_Stress/
├── generate_fem.py
├── validate_generated.py
├── README.md
└── expectations.json              # 版本化的语义 oracle

生成产物：
├── FemAutoSeam_BoundaryMatrix.fem
├── FemAutoSeam_BoundaryMatrix_manifest.json
├── FemAutoSeam_DenseStress.fem
├── FemAutoSeam_DenseStress_manifest.json
├── FemAutoSeam_TransactionHostile.fem
└── FemAutoSeam_TransactionHostile_manifest.json
```

- `BoundaryMatrix`：每个场景空间隔离，负责精确功能和阈值判定。
- `DenseStress`：大量合法和干扰组件混排，负责候选爆炸、空间索引、多进程和重绘分批压力。
- `TransactionHostile`：混入质量、属性、非壳卡和规划失败条件，负责保持、拒绝和整批回滚。

生成器必须为纯 Python 3.8 标准库、固定 seed、确定性 ID 和确定性输出。支持至少：

```powershell
runtime\python\windows-x64\python.exe examples\FemAutoSeam_Stress\generate_fem.py --suite all --scale 1 --seed 20260810
runtime\python\windows-x64\python.exe examples\FemAutoSeam_Stress\validate_generated.py
```

`--scale` 必须只改变重复数量/网格密度，不改变单个基础 case 的几何语义。建议支持
`--suite boundary|dense|hostile|all`、`--output-dir` 和 `--seed`。

## 4. FEM 建模硬规则

### 4.1 卡片和属性

- 使用 OptiStruct free-field bulk：`BEGIN BULK`、`GRID`、`CQUAD4`/`CTRIA3`、`MAT1`、
  `PSHELL`、`$HMNAME COMP`、`$HMCOMP ID`、`ENDDATA`。
- 每个可自动创建场景的所有壳单元必须有正 PID，PID 必须对应有效 `PSHELL`。
- 源组件名使用可解析厚度，如 `B031_T_SRC_T1.2`；自动生成的焊缝预期名可据此核对为
  `SEAM_T1.2_Bxxxxxx`。另设少量无 `_T` 名称的场景，验证 `SEAM_UNASSIGNED` 回退。
- 同一正常重绘组件只使用一个直接属性。多 PID 同组件只能放入 hostile case，预期整批报错并回滚。
- 组件、节点、单元、属性 ID 区间不能重叠；加入高 ID、稀疏 ID 和乱序卡片变体，但不能制造引用错误，除非该 case 明确是导入负向测试。

### 4.2 几何和拓扑

- 正常装配语义下，源与目标绝不共享 GRID；共享节点只能用于“已经连接、不应重复创建”的负向对照。
- 每个板件必须是规则多单元网格，不能用单个大四边形冒充零件。
- 同一边界场景内允许混合 CTRIA3/CQUAD4；同一几何至少提供全 quad、交错三角化、不同网格密度三个变体。
- 自动 T/patch 的目标母网格必须共面。非共面、折面、孔洞穿越等只放在明确预期为 planning failure 的场景。
- 场景隔离距离必须大于“场景包围盒半径之和 + 2 × max(search_distance, near_edge_distance)”，
  并由生成器自检，防止意外跨场景候选。
- 所有壳面积必须大于容差，禁止重复连通单元、折叠边和未声明的孤立节点。
- 法向翻转变体要通过反转整个组件的单元节点顺序实现，不能局部随机反转造成无意义的平均法向。

## 5. BoundaryMatrix 必须包含的场景

每个边界必须使用“三点法”：`阈值-ε`、`阈值`、`阈值+ε`。长度/距离建议
`ε=0.01 mm`，比率 `ε=0.001`，角度 `ε=0.1°`。阈值点的包含关系必须由当前代码实跑确认。

### 5.1 T_SEAM 正向、边界和负向

| 组 | 必建场景 | 主要断言 |
|---|---|---|
| T01 | 直 T，均匀 3 mm 间隙，60 mm 路径 | 1 个自动 T；规划和实现成功 |
| T02 | 整体旋转/平移/镜像、整体法向翻转 | 与 T01 语义相同，不依赖全局轴或 ID |
| T03 | 斜 T：实际法向夹角 19.9/20.0/20.1° | 门槛两侧候选数严格变化 |
| T04 | 搜索距离 11.99/12.00/12.01 mm | 前两者命中、后一者无 T（实跑冻结边界） |
| T05 | 路径长度 19.99/20.00/20.01 mm | 均可检测；自动资格在 20 mm 处切换 |
| T06 | 距离沿路径渐变，比率 0.349/0.350/0.351 | 候选保留；自动资格切换 |
| T07 | 正弦、圆弧、折线源自由边，平面目标 | 每段合并为连续候选；可规划的应成功实现 |
| T08 | 部分重叠 5、19.99、20、34、80 mm | 只返回真实公共区间；长度门槛决定 auto |
| T09 | 同一源边投向 2 个叠层目标 | 两个目标均有候选，不被错误合并 |
| T10 | 一根源跨 1、4、16、64 个独立目标 | 候选数等于目标数；顺序稳定 |
| T11 | 目标中间开缝/孔，使投影区间断开 | 分成多个合法区间或规划拒绝，不能跨空洞拉通 |
| T12 | 源自由边带分叉、T 形边图 | 分叉路径跳过，不崩溃 |
| T13 | 源/目标共享全部接缝节点、部分共享节点 | 已连接路径不重复创建；部分共享进入明确拒绝/复核 |
| T14 | 投影方向相反、目标位于自由边“内侧” | 不产生错误的反向候选 |
| T15 | 目标折面或轻微翘曲，检测可命中 | 自动拆分返回非共面警告，模型不修改 |
| T16 | 极粗/极细/不匹配源目标网格 | zipper 保持连续；三角比例和 aspect gate 可判定 |
| T17 | 源路径端点落在目标节点、边中点、单元内部 | 覆盖“复用已有边”和“拆分母单元”两条路径 |
| T18 | 同一路径两次进入同一凹形母单元 | 明确 planning failure，不产生重复/交叉壳 |

### 5.2 PATCH_SEAM 正向、边界和负向

| 组 | 必建场景 | 主要断言 |
|---|---|---|
| P01 | 小矩形贴片完全包含于大目标 | 外环自动 patch，闭合 zipper 成功 |
| P02 | 圆角近似、多边形、三角/四边混网贴片 | 外环闭合、无分叉，结果连续 |
| P03 | 法向夹角 14.9/15.0/15.1° | 前两者可候选，后一者无 patch |
| P04 | 距离 11.99/12.00/12.01 mm | 与搜索距离边界一致 |
| P05 | 外环长度 19.99/20.00/20.01 mm | 候选存在，自动资格在门槛切换 |
| P06 | 两组件面积差 1.9/2.0/2.1% | 验证相近面积抑制的精确包含关系 |
| P07 | 距离变化率 0.349/0.350/0.351 | patch group 自动资格切换 |
| P08 | 无孔、等效孔径 29.99/30.00/30.01 mm | 小孔使整组 review；阈值及大孔行为准确 |
| P09 | 同一贴片有 2~8 个大小混合内孔 | 候选环数、group id 和整组 auto 状态正确 |
| P10 | 贴片边界刚好接触、略超出目标边界 | 完全包含才有 patch，不允许悬空部分 |
| P11 | 目标内部有孔且投影跨孔 | 无完整 containment 或规划拒绝，不能封孔 |
| P12 | 源 patch 非平面、目标非平面 | 检测/规划按当前限制稳定拒绝，不崩溃 |
| P13 | 源、目标面积角色交换 | 始终以面积较小组件为 source |
| P14 | 闭环源/目标节点数量相等和严重不等 | quad-dominant zipper 可用，三角比例受控 |

### 5.3 NEAR_FREE_EDGES、去重和选择域

| 组 | 必建场景 | 主要断言 |
|---|---|---|
| N01 | 平行近自由边，距离 7.99/8.00/8.01 mm | 仅门槛内产生 review 候选 |
| N02 | 切向夹角 19.9/20.0/20.1° | 仅门槛内命中 |
| N03 | 长短边错位、反向节点顺序、多段折线 | 匹配方向不敏感，目标 edge/node 提示完整 |
| N04 | 同时满足 T 和近自由边条件 | 各类型计数符合当前实现，不把 review 误当 auto |
| D01 | 候选中心距已有 `SEAM_*` 3.99/4.00/4.01 mm | 前两者 `POSSIBLE_DUPLICATE`，后一者保持 NEW |
| D02 | 已有 SEAM 靠近端点但远离中心 | 记录当前“中心去重”行为，防止误写更强 oracle |
| S01 | 全模型含有效场景，但只选择一部分组件 | 所有 source/target 均在选择集合内 |
| S02 | 只选 source 或只选 target | 不产生跨越未选组件的候选 |

## 6. 规划、实现和质量 hostile 场景

以下 case 不以“检测到候选”作为通过；必须继续接受候选、运行 plan/apply，并验证失败原子性：

| 组 | 注入条件 | 预期 |
|---|---|---|
| H01 | 目标组件缺 PSHELL/直接 PID | `MANUAL_REVIEW` 或 planning failure；无修改 |
| H02 | 目标混入高阶壳/非支持壳 | 自动拆分拒绝；无崩溃 |
| H03 | 同一待重绘组件跨两个直接 PID | Tcl 属性预检报错，整个任务恢复 `before.hm` |
| H04 | 极瘦目标单元使替换壳超 aspect gate | planning failure，母单元不被删除 |
| H05 | 源/目标离散比导致 zipper 三角比例超限 | 明确失败，零焊缝单元 |
| H06 | 预置重复壳连通签名 | 重复 replacement/weld 被质量预检拒绝 |
| H07 | 原始邻域已有不同数量质量失败 | 按失败率基线和 `max_new_failed_elements` 裁决 |
| H08 | 重绘后潜在属性漂移 | 属性不一致即整批回滚 |
| H09 | 保护节点附近做极端重绘 | 焊缝连通不变，每个保护节点仍连接母壳 |
| H10 | 合法候选与必失败候选同批 | 任一 apply 错误均恢复整批，不能部分提交 |
| H11 | 模型含 CTETRA/RBE2/LOAD/FORCE 等非壳卡 | 完整 FEM 往返后卡片和组件上下文保持 |
| H12 | 高/稀疏实体 ID，规划需预分配新 ID | 新 GRID/element/component ID 全部大于 live max 且唯一 |
| H13 | source 名称有/无 `_T厚度` | SEAM 名称分别解析厚度或回退 `SEAM_UNASSIGNED` |

实机 H03/H08/H10 必须核对：失败后节点、单元、组件、属性计数及关键 connectivity 与
`before.hm` 一致；任务目录状态为 FAILED；不存在残留 SEAM component。

## 7. DenseStress 的压力设计

压力模型至少提供 S/M/L 三档，默认 `--scale 1` 生成 M 档：

| 档位 | 组件 | 壳单元 | 设计候选 | 用途 |
|---|---:|---:|---:|---|
| S | 40~80 | 5k~15k | 100~300 | 每次提交快速回归 |
| M | 200~500 | 50k~150k | 1k~5k | 工作站常规压力测试 |
| L | 1000+ | 300k+ | 10k+ | 夜间/发布前极限测试 |

构造要求：

1. 混合 40% 自动 T、15% 自动 patch、15% review、30% 无候选/干扰组件；比例写入 manifest。
2. 至少一个连通重绘区域在扩展后跨过 1000 单元，使 `remesh_chunk_elements=1000` 产生多批；
   另设 999/1000/1001 的精确分批边界模型。
3. 至少 4 个组件且超过 2000 单元，分别以 `python_workers=1/2/4/0` 运行。候选完整语义必须完全一致，
   不比较 wall-clock 顺序造成的偶然差异。
4. 加入少数跨越大量 AABB cell 的超长壳，触发空间索引 overflow bucket，但单元必须有效；候选不能漏检。
5. 密集场景要有显式 `case_owner_by_component`。除了 manifest 声明的共享目标测试，不允许候选跨 owner。
6. 记录检测、规划、duplicate check、总耗时、峰值 RSS、worker 数、候选/秒、单元/秒。
7. 性能验收采用同机相对基线：M 档不得比冻结基线慢 25% 以上；并设宽松绝对超时防止死循环。
   基线 JSON 必须记录 CPU、内存、Python/HM 版本和日期，不能跨机器直接判回归。
8. 多进程输出应与单进程按以下稳定签名逐项相等：
   `(candidate_type, source_component_id, target_component_id, source_node_ids, closed, rounded_length, auto_eligible)`。

## 8. 变形测试（Metamorphic Testing）

同一基础场景自动派生以下变体，并断言候选语义不变：

- 全局平移到正/负大坐标；绕 X/Y/Z 任意旋转；镜像；
- 节点、单元、组件 ID 加大偏移并打散；FEM 卡片顺序重新排列；
- 整个组件法向翻转；
- quad 规则网格、交错三角化、局部加密/粗化；
- mm 模型与按统一倍率缩放、同时同比例缩放所有距离/长度参数的模型；
- 单进程与多进程。

禁止把“单独缩放几何但仍用原默认阈值”视为不变性测试；那应是单位错误负向测试。

## 9. manifest 与 oracle

每个 case 至少写入：

```json
{
  "case_id": "T005_LEN_EQ",
  "suite": "boundary",
  "component_ids": [101, 102],
  "selected_component_ids": [101, 102],
  "geometry": {
    "gap": 3.0,
    "designed_path_length": 20.0,
    "normal_angle": 90.0,
    "shared_node_count": 0
  },
  "settings": {
    "search_distance": 12.0,
    "min_seam_length": 20.0,
    "python_workers": 1
  },
  "expected_detection": {
    "candidate_count": 1,
    "type_counts": {"T_SEAM": 1},
    "auto_eligible_count": 1,
    "review_count": 0,
    "length_range": [19.999, 20.001]
  },
  "expected_plan": {
    "ready": 1,
    "manual_review": 0,
    "failed": 0
  },
  "expected_apply": {
    "transaction": "COMMIT",
    "minimum_created_weld_elements": 1,
    "moved_nodes": 0
  },
  "expected_warning_substrings": []
}
```

不要只保存总候选数。oracle 至少核对：类型、source/target、路径开闭、长度范围、auto、status、
duplicate status、关键 warning、plan 状态、删/建实体数量下界、焊缝连续性、属性和事务结果。
`candidate_id` 可以记录用于诊断，但跨不同组合 deck 时不要把它当主要身份键。

oracle 冻结流程：

1. 生成每个隔离 case；用生产 `read_shell_fem_bundle` 读回；
2. 分别以 `python_workers=1` 和并行配置调用生产 `detect_candidates`；
3. 人工核对几何设计与候选 source/target/路径，不能盲目接受程序输出；
4. 对应自动项运行 `plan_candidate_deltas` 和离线完整 FEM round-trip；
5. 将已审核结果写入版本化 `expectations.json`；
6. 组合所有 case 后再跑一次，证明无跨场景污染；
7. 在 HM2019 和 HM2022 各做至少一次 M 档 apply，冻结实机报告。

## 10. 生成器自检必须失败即退出

`generate_fem.py` 写文件前和写后至少检查：

- GRID 引用、PID/PSHELL、组件归属完整；ID 唯一；
- CTRIA3/CQUAD4 面积为正、无重复 connectivity、无折叠边；
- 每个 case 的共享/不共享节点关系等于设计值；
- 自由边连通分量数、闭环数、分叉标志和内孔等效直径；
- 实际间隙、路径长度、法向角、距离变化率与设计值误差在容差内；
- 隔离 case 包围盒安全距离；
- 写出后重新解析，节点/单元/组件/PID 计数一致；
- 组合模型候选等于隔离模型候选之和（密集共享目标的显式例外除外）；
- 相同 seed 输出 SHA-256 一致；不同 seed 只允许改变声明的随机干扰布局。

`validate_generated.py` 必须调用生产 reader/detector/planner，禁止复制一份算法作为“独立验证器”，
否则实现和测试可能以同样方式写错。几何不变量可由生成器独立计算，算法结果必须由生产入口产生。

## 11. HyperMesh 2019/2022 实机验收

对每个 suite 执行：

1. 用 OptiStruct profile 导入 FEM，选择 manifest 指定组件；确认非选中干扰组件仍在完整模型中。
2. 使用 case 记录的设置运行“FEM 自动焊缝”。保存检测结果、review 决策和性能信息。
3. 接受自动项并应用；核对 `before.hm` 在模型修改前已生成且非空。
4. 核对 result FEM 打开后，预分配 ID、焊缝 connectivity、母单元替换和 PID 正确。
5. 核对受影响区域分批 automesh，保护节点未断开，焊缝单元未被重绘改变。
6. 读取 `execution_report.json`/`completion_manifest.json`，与 manifest oracle 对比。
7. 对 hostile 回滚 case 对比恢复模型与运行前实体签名；再测试“撤销上一批”。
8. 最终任务清理后只应保留工作流约定的 `before.hm` 和 `result.fem`。

每次实机报告必须包含：HM 版本、模块版本、模型 SHA-256、设置、选择组件、候选分类统计、接受项、
成功/失败/回滚数、创建/删除/重绘数量、质量前后失败率、chunk 数、总耗时和错误文本。

## 12. 完成定义

只有同时满足以下条件，Agent 才能宣称测试模型创建完成：

- 三套 FEM 均可由便携 Python 3.8 确定性生成并通过自检；
- BoundaryMatrix 覆盖本指南全部 T/P/N/D/S 分组，且每个数值硬门槛都有三点边界；
- 自动项不仅被检测，还能规划、写完整 FEM、读回并验证 zipper/母网格连续性；
- DenseStress 达到 M 档，单/多进程语义完全一致，并真正跨越重绘 chunk 边界；
- TransactionHostile 证明拒绝无残留、失败整批恢复、非壳卡保持；
- 组合 deck 无未声明的跨 case 候选；
- HM2019 与 HM2022 实机报告至少各一份，成功和回滚路径都被执行；
- README、manifest、`expectations.json` 与当前代码行为一致，不保留未经验证的“预计”。

