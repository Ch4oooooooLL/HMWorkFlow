# Auto / AutoGroup 实机性能与识别准确性研究（2026-09-06）

本轮在**当前实机安装**（与 2026-09-05 轮不同的机器路径）上，用大规模验证模型 `examples/model_suite/solid_seam_10joints/SolidSeam_10joints.fem`（20 组件、30,063 节点、21,400 HEXA）替代旧 512 单元样例，量化 Auto/AutoGroup 剩余优化点的真实收益，并用 4 个网格密度对照模型实测识别准确性风险。**未修改任何生产代码**；全部实验通过运行期包装（rename/包裹）完成，实验前后候选指纹完全一致。

## 环境

- `C:/Program Files/Altair/2019/hm/bin/win64/hmbatch.exe`：19.0.0.70（HM2019）。
- `D:/Program Files/Altair/hwdesktop/hm/bin/win64/hmbatch.exe`：22.000000（HM2022）。
- 两套均为 Tcl 8.5.9。与旧机器不同，本机 2019 安装在 C 盘、目录布局为 `<root>/templates/`（非 `<root>/hm/templates/`）。

### 本机 batch 导入兼容性（重要环境发现）

- 旧脚本使用的 reader 名 `#optistruct\optistruct` 在本机两套安装的 hmbatch 中均报 **"The translator does not exist"**；必须改用 **`#optistruct`**（`*templatefileset` 照常执行，`hm_info templatetype` 正确变为 `nastran`，即 HM2019 的 OptiStruct profile；模板加载期间的 `hmbrmgr` 报错是 batch 下的内部噪音，不影响注册）。
- 更严重：该 batch 读取器**严格限制每行最多 10 个逗号分隔字段**。`CHEXA` 单行 11 字段（卡名+ID+属性+8 节点）被**静默丢弃**——导入结果为全部节点+全部组件+全部属性，但 0 个单元，命令本身返回成功。对照实验：`CQUAD4`（7 字段）完整导入；把 CHEXA 改写为标准续行（首行第 10 字段放 `+C` 标记、次行 `+C,g7,g8`）后 21,400 个单元全部导入（config=208）。
- 推论：`tools/model_generation/femlib.py::write_fem` 输出的单行 CHEXA 在 hmbatch 下不可用（此前 GUI 导入验证未暴露此差异）。**建议 femlib 发卡时对 CHEXA/CQUAD8 等超 10 字段卡输出续行**，并更新实机脚本的 reader 名。研究用副本已按续行转换：`temp/solid_seam_research_20260906/*_batch.fem`。

## 方法

- 每版本独立 hmbatch 进程导入模型后：① 基线 `prepareAutoGroup` 重复 5 次取中位数（只读）；② 用执行 trace 统计 `hm_getvalue` 次数、用 rename 包装统计各阶段调用数与耗时；③ 方向表实验：对每对组件正反两方向直接调用 `autoDetectSeams` 并记录评分/类型票/侧向/参数/指纹；④ 点到面距离 shadow 审计（`shadowFaceDistanceAudit`）逐方向运行；⑤ 两个原型实验（见下）；⑥ 创建阶段真实执行（`recorderShadow 1`）。
- 准确性对照模型（`temp/solid_seam_research_20260906/`，由 `make_accuracy_models.py` 生成，同几何 T 型接头、2mm 间隙、两组件不共享节点）：`acct_control_6_6`（6/6mm）、`acct_t6_12`（墙 6mm/地板 12mm）、`acct_t6_24`（6/24mm，4:1）、`acct_remesh_12_12`（12/12mm）。
- 所有计时实验前后候选指纹一致（EXPA_FINGERPRINTS_MATCH=1、EXPB_FINGERPRINTS_MATCH=1、基线 5 次互相一致、HM2019 与 HM2022 全部 DIRECTION/SHADOW 行逐字一致）。

## 性能实测（AutoGroup 整批，20 组件、12 个粗筛后组件对）

| 实验 | HM2019 | HM2022 | 说明 |
|---|---:|---:|---|
| 基线整批预计算（中位数） | 5.573 s | 6.032 s | 5 次；冷启动 5.41/5.68 s，热态无明显差异 |
| `hm_getvalue` 次数/批 | 129,967 | 129,967 | 两版本完全一致（确定性） |
| ─ solidFacingBoundaryNodes | 24 次 × 97 ms ≈ **2.33 s (42%)** | 24 × 105 ms ≈ 2.53 s (42%) | 每方向一次，target 面质心+边界节点逐点 KD 最近邻 |
| ─ nativeBoundaryDataImpl（\*findfaces + 回读） | 18 × 28 ms ≈ 508 ms (9%) | 18 × 43 ms ≈ 777 ms (13%) | 组件级已缓存，\*findfaces 本身 2022 更慢 |
| ─ 逐单元 connectivity 回退读 | 19,668 × 25 µs ≈ 492 ms (9%) | × 40 µs ≈ 787 ms (13%) | 见实验 B 归因 |
| ─ meshPitch（128 单元采样） | 20 × 11.5 ms ≈ 230 ms | ≈ 250 ms | 已缓存，每组件一次 |
| ─ KD 树构建 | 72 × 2.5 ms ≈ 184 ms | ≈ 179 ms | 每方向 3 棵：目标面 ×2（facing 与 junction 各建一次）+ 源链 1 |
| ─ 粗筛 sweep-and-prune | 0.18 ms | 0.12 ms | 已优化完成，不再是问题 |
| 实验A：KD 树/法向 patch/平均法向跨检测复用 | 5.061 s（**-9.2%**） | 5.306 s（**-12.0%**） | 指纹一致 |
| 实验B：整批一次全量 connectivity 预取 | 4.054 s（**-27.3%**） | 4.248 s（**-29.6%**） | 含预取本身；指纹一致 |
| 创建（每对，含 recorder + 影子差集） | 130–482 ms | 199–291 ms | 生产默认无影子差集，实际更少 |

阶段归因（剩余瓶颈排序，两版本一致）：

1. **solidFacingBoundaryNodes 占整批 42%**。其内部是对目标面网格逐面质心、逐边界节点的精确 KD 最近邻查询（每方向约 1,200–2,500 次纯 Tcl 查询）。另外 4 个跨接头方向（1012↔1013、1014↔1015）因 facing 判定返回空而落入 `boundaryNodesOfComponent` 的 O(E) 全拓扑回退（逐单元 elementFaces+faceKey），是其中最重的部分。
2. **逐单元 connectivity 回退读 19,668 次/批**：约 7,600 次来自 `*findfaces` 临时 `^faces` 组件的连接性回读（临时组件不在 groupStableElements 白名单，`elementNodes` 全部走逐实体 `elementNodesImpl`）；其余约 6,000+ 次来自上述全拓扑回退。实验 B 把选中组件全部单元预取进 `groupElementNodes` 后，两条路径同时受益，整批 -27%/-30%。
3. **KD 树每检测重建 3 棵**，其中目标面树在 `solidFacingBoundaryNodes` 与 `detectJunctionNodes` 里对同一节点集合各建一次；树/坐标是组件固有数据，可操作级缓存（实验 A 证实安全，收益 9–12%，因为大头仍在前两项）。

### 建议实施顺序（性能）

1. **整批 connectivity 预取（实验 B 产品化）**：`prepareAutoGroupImpl`/`prepareSelectionPairs` 在 `beginGroupRecognitionCache` 后对所有选中组件调用 `componentElementIds`+`prefetchElementNodes`。改动约 10 行，实测 -27%/-30%，指纹零变化。
2. **目标面 BVH（或均匀网格）组件级缓存**：`diagnostics.tcl` 的三角化+BVH 基础设施已存在，把它按 `(操作代, 目标组件)` 缓存进 group cache，`solidFacingBoundaryNodes` 的面向测试/接触带改用 BVH 最近面查询，`detectJunctionNodes` 复用同一棵（消除每方向 3 棵 KD 树中的重复）；shadow 审计也复用。预计 facingBoundary 2.3–2.5 s → <0.8 s。需指纹门禁。
3. **`^faces` 回读批量化**：对临时组件连接性提供分块批量读取变体（复用 `queryChunks`，node1..8 一次取回），消除约 7,600 次逐实体查询；nativeBoundary 508–777 ms → 约 100–200 ms。
4. **全拓扑回退收窄**：`boundaryNodesOfComponent` 固体回退前先用目标 AABB 预筛单元（结果不变、工作量骤减）；或先在影子模式统计该回退触发频率。
5. **第二批**：`loadRealizationProfile` 每候选重新 `source` profile 文件 → 按批复用；GUI 重绘阻止区间（两版本都有 `hm_blockredraw`、都没有 `hm_blockbrowserupdate`，不要复制依赖后者的脚本）；日志 channel 批量持有。这些需要 GUI 实测，hmbatch 验证不了收益。

不建议：并行访问同一 HM 会话；用近似最近邻替换精确查询；按粗筛结果省略识别方向（会改变结果）。

## 准确性实测发现（两版本一致）

### F1. 实体组件的 T/L/B 分类从不生效（影响所有实体模型）

10joints 全部 12 对 × 双方向的 32 样本投票全部为 `NATIVE 32`（`classification_votes=T 0 B 0 L 0 NATIVE 32`），候选一律 `AUTO_NATIVE`/`PENTA_MIG` 通用实现，`side` 一律 `FALLBACK_SELECTION`。原因：`automaticJointVote` 依赖 `localShellNormal`，而 `localShellPatch` 只接受壳单元 config（103/104/106/108），实体组件返回空法向 → 直接 NATIVE。验证模型 README 预期的 `PENTA_MIG_T/L/B` 在实体模型上**永远不会被 Auto 选出**（手动选择仍可）。改进方向：为实体组件提取焊缝节点处的外表面法向（`solidFacingBoundaryNodes`/shadow 三角化已有全部基础数据），先影子记录"若启用实体法向，T/L/B 票型如何变化"，验证后再切换。

### F2. 目标网格变粗时"最近距离分层"把真实焊缝撕碎

- 6/24（4:1）模型，墙→地板方向：真实焊缝是墙底边整圈（约 112 mm、22 节点），实测被切成 **3 条 2 节点、8 mm 的碎片候选**（`min_weld_length=0` 下碎片全部放行）。
- 机制：closest-layer 用"最大距离跳变"切层，跳变阈值下限 `0.5×链节距` 由**源链**节距（6mm → 3mm）决定，而粗目标（24mm）导致的节点距离跳变远超 3mm → 多次切割。
- 6/12（2:1）时链长从 112 mm 缩到 100 mm（角部两段被切掉）。同几何 12/12 重划分结果与 6/12 完全相同——重划分不变性只在"目标不变"时成立，目标网格一变链就变。
- 改进方向：分层阈值改用 `max(源节距, 目标节距)` 或点到面距离（见 F5）；Auto/AutoGroup 给 `min_weld_length` 一个相对链节距的下限（如 3×节距）拦截碎片。

### F3. 4:1 密度失配下方向评分反转

6/24 模型：正确方向（墙→地板）score=0.559，错误方向（地板→墙，仅 2 节点、48mm、`mesh=48` 的退化链）score=0.264 → **AutoGroup 会选错方向**并在地板上建 2 节点焊缝。现行评分 = 各行 `maximum_gap/mesh_size` 均值，分母（链节距）与分子（到粗目标节点距离）同源放大，碎片反而占优。改进方向：方向选择前先做退化门禁（候选覆盖源面向边界的比例、碎片数量、链长/组件尺度比），再比较评分；评分改用分位数（如 P90）+ 覆盖率组合。

### F4. 相邻接头的跨组件误配与不可实现链

10joints 模型中相邻接头的块之间只有 0.5mm 间隙（生成器布局），AABB 粗筛（9mm）合法地把 V06B-V07A、V07B-V08A、V07B-V08B 三对跨接头组件拉进识别，产出 649.456 mm、108 节点、绕多个面的链：
- HM2019 上该链原生 CE 实现返回 `Connector realization state is FAILED`（同一对里 234mm/72mm 正常创建）→ 整对失败；
- HM2022 上**连正常接头 J04（搭接 402mm/68 节点链，与 2019 指纹一致）也原生 FAILED**（2019 创建成功）→ 跨版本实现稳健性差异，需单独用 command file 排查 2022 的 CE 选项行为。
- 改进方向：链级质量门禁（累计转角、绕面数、链长/组件包围盒比；区域连续性即评审文档的 path hysteresis）；验证模型生成器把接头间距放宽到 >1.5×网格（或明确保留为准确性夹具）。

### F5. 点到节点 vs 点到面距离（shadow 实测）

24 次 shadow 审计中 23 次零漏识别；`1016→1014` 发现 **1 个 potential_false_negative**（面距在半径内、节点最近邻在 legacy 之外）。节点-面差最大为半径的 0.229（V08 斜接，≈2.1mm）、T 接头 0.178（≈1.6mm）——均匀网格下被 `1.5×max(pitch)` 半径吸收，真正的伤害通过 F2/F3 的分层与配对显现（粗网格时按比例放大）。shadow 基础设施已可用但默认关闭（`ui(shadow_face_distance)`），建议在回归中默认打开 accumulating 数据；切换生产判定仍按评审文档门槛（shadow 差异分布 + remesh 不变性 + 灾难性误连为 0）。

### F6. 其他

- J10 负例（30mm 间隙 > 半径 9mm）两版本都正确拒绝（最小节点距离恰为 30.0mm）。
- shadow 审计自身对跨接头方向返回 `source_boundary_nodes=0`（其内部 facing 调用无回退），与主检测的 161 节点回退不一致，审计实现应镜像主检测的回退链。

## 复现

```powershell
# 主基准（每版本一个新 hmbatch 进程，串行执行）
"C:/Program Files/Altair/2019/hm/bin/win64/hmbatch.exe" -nocommand -nouserprofiledialog -tcl C:/WrokSpace/HMWorkFlow/temp/solid_seam_research_20260906/research10joints.tcl
# 密度准确性试验（RESEARCH_FEM 指向 *_batch.fem）
# 生成器：python temp/solid_seam_research_20260906/make_accuracy_models.py
```

原始日志：`temp/solid_seam_research_20260906/research10joints_hm{19,22}.000000.log`、`research_density_acct_*_hm19.000000.log`、`probe_pair9.log`、`probe_pair4_22.log`。临时目录不入库；`*_batch.fem` 为研究用转换副本。

## 与 2026-09-05 两份文档的关系

- 上一轮建议 1（Auto 批次缓存）、3（entity recorder）、4（原生 AABB）已确认落地；本轮证明剩余三个优化点的量级并给出产品化顺序（上节）。
- 上一轮准确性评审的 P0（点到节点距离）、P0（全局分层）、P1（方向评分）本轮首次在实体验证模型上全部实测复现并量化（F2/F3/F5）；实体法向缺失（F1）是本轮新发现。

## 已实施的三项性能改进（2026-09-06，分支 `optimize/solid-seam-auto-batch-prefetch`）

- **整批 connectivity 预取**：`prepareAutoGroup`/`prepareSelectionPairs` 在识别缓存建立后对全部选中组件调用新增的 `prefetchComponentConnectivity`（分块 `hm_getvalue ... user_ids=` 批量读入 group cache）。
- **瞬态组件回读批量化**：新增 `batchedElementRings`，`^faces`/`^edges` 回读按块批量读取（保留原元素顺序、遇错自动回退逐实体读法），瞬态 id 不进入稳定元素缓存。
- **目标表面 KD 树组件级缓存**：新增 `surfaceNodeSpatialIndex`（检测级 + 识别批次级两级缓存），`detectJunctionNodes` 与 `solidFacingBoundaryNodes` 共享同一棵树（新增可选 `targetIndex` 参数），shadow 审计同样复用；同一节点集合不再每方向重复建树。

实机验收（指纹门禁 = 候选指纹 + 规范化文本逐字节一致）：

| 指标 | HM2019 改动前 | HM2019 改动后 | HM2022 改动前 | HM2022 改动后 |
|---|---:|---:|---:|---:|
| AutoGroup 整批中位数 | 5.573 s | **1.355 s（-75.7%）** | 6.032 s | **1.282 s（-78.7%）** |
| `hm_getvalue` 次/批 | 129,967 | **4,729** | 129,967 | **4,729** |
| KD 树构建/批 | 72 | **18** | 72 | **18** |

10 接头模型（两版本）与 4 个密度对照模型的指纹全部一致。剩余性能空间：meshPitch（约 208 ms）与 `*findfaces` 本体（约 380-470 ms/批），以及创建阶段与 GUI 开销（需 GUI 实测）。准确性项（F1-F5）未在本批改动，仍按"影子先行"路线推进。

## 已实施的准确性修复（2026-09-06，分支 `feature/solid-seam-auto-accuracy`）

基于性能分支 `optimize/solid-seam-auto-batch-prefetch`，三项修复（开关 `ui(automatic_solid_normals)`、`ui(automatic_face_layering)`，默认开）：

- **F1 实体分类**：`localShellPatch` 按实体组件分派到 `solidSeamPatch`——原生外表面按组件建立面记录（外向法向/中心/面积）与节点邻接；面积分桶主导轴（1.2×门禁）选出"壳等效"宽面方向，块状实体安全降级 NATIVE；焊缝节点处无对齐宽面（接触面内部节点）时回退组件主导轴——修复 T 接头混票（{T:2,L:3}→NATIVE）的根因。
- **F2 面距分层**：`detectJunctionNodes` 的最近距离分层与 `solidFacingBoundaryNodes` 的面向判定/接触带在 Auto 模式下改用点到目标面距离与最近面点方向（`targetFaceDistanceTree` 缓存 BVH，复用 shadow 三角化），节点距离方案保留为回退。pair 第三元改为面间隙，`maximum_gap` 从此是真实几何间隙。
- **F3 方向门禁**：`groupUsableRows`（≥3 节点）过滤碎片行后再比较方向评分；一方有真实链即胜出，双方碎片保持旧行为。

实机验收（HM2019 + HM2022，`temp/solid_seam_research_20260906/` 日志）：

- 10 接头类型全部对齐地面真值：J01-03→T/PENTA_MIG_T、J04-05→LAP/PENTA_MIG_L、J06-07→BUTT/PENTA_MIG_B（跨接头伪对无真值；J08/J09 的 LAP 是几何正确的——生成器从未应用 30°/40° 旋转，README 预期与实际几何不符，属模型问题）。
- t6_24（4:1）真实焊缝从 3×2 节点碎片恢复为 18 节点/104 mm 环链，且与 control（6/6）结果逐字一致——密度与重划分不变性达成；碎片方向被 F3 门禁压制。
- T/L/B 新实现路径（feType 118/117/119）双版本创建全部 PASS（顺带修复 HM2022 J04 搭接链原生 FAILED——新 57 节点链创建成功）。
- 性能保持：10 接头整批中位数 1.378 s（性能分支为 1.355 s）。
- 离线回归：`classification_offline.tcl`（主导轴、patch 排序、T/L/B 投票、块状降级、中面回退、可用性门禁）+ 既有 7 套全部通过。

F4（跨接头伪链的链级质量门禁）与 F5 的 partner 映射切换仍按影子路线推进；`gen_solid_seam.py` 的 J08/J09 旋转缺失建议修正后重生成模型。
