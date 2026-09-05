# Auto / AutoGroup 准确性与性能优化评审

日期：2026-09-05  
范围：`modules/solid_seam` 当前 Tcl 主流程，兼容 HyperMesh 2019/2022。  
依据：现有实现与回归、HM2019 实测，以及右侧 ChatGPT 网页端的独立技术评审。网页建议已按当前代码核对；本文件只保留能在本项目中验证的结论。

## 结论

最优先的三件事是：

1. **先建立候选指纹、分阶段计时和参数化几何基准。** 没有稳定基线，无法证明性能优化没有改变结果，也无法判断新算法提高了准确率还是只改变了阈值偏向。
2. **在影子模式中实现点到目标外表面的真实距离。** 当前点到点最近邻是上游系统误差，会同时影响搜索范围、距离分层、开放边恢复、AutoGroup 方向选择及 tolerance。生产结果暂时仍采用旧算法。
3. **AutoGroup 采用保守 sweep-and-prune 粗筛，并建立本次操作级组件快照。** 先用空间索引得到旧 AABB 检查的超集，再执行原来的精确 AABB 距离判断和原顺序排序，因此不漏掉旧候选；组件固有数据可跨 A→B、B→A 和多个 pair 复用。

继续调整 `1.5h`、80% 或其他固定阈值不应作为首要方案。点到点距离和全局分层未解决前，放宽阈值通常只是用误连换取少漏焊。

## 当前风险排序

| 等级 | 风险 | 当前代码中的影响 |
| --- | --- | --- |
| P0 | 目标只使用节点最近邻 | 粗目标网格的面中心明明很近，到四角节点却很远；会级联改变候选、gap、分层、方向评分和 tolerance |
| P0 | 全局距离分层 | 斜接、曲线及局部网格变化时，同一条真实焊缝的 gap 会连续变化，可能被误切成多层 |
| P1 | AutoGroup 用最大 gap 评价方向 | 单个离群点即可使 A→B/B→A 翻转；不同网格密度也会改变评分 |
| P1 | 开放边事后补段 | 已修复中段漏识别，但两个可信端点之间仍可能存在拓扑连续、实际不应焊接的长绕行段 |
| P1 | 物理焊接侧直接映射原生正负侧 | T/L/B 的 native side 语义不同，近 90° 和法向翻转时风险最高 |
| P2 | 80% 被称为 confidence | 相邻采样高度相关，80% 是 agreement，不是经过校准的正确概率 |
| P2 | 全组件尺度 `h` | 强非均匀网格时，固定 `1.5h` 和最多 128 个单元采样不能代表焊缝局部尺度 |

### 点到节点距离为何是首要问题

对于边长 10 的目标 quad，源点正对面中心且法向间隙为 1：真实点到面距离是 1，最近目标节点距离约为 `sqrt(5²+5²+1²)=7.14`。这不是小的数值误差，而是会改变“是否进入搜索范围”的离散误判。目标重新划分网格但几何不变时，结果也可能变化。

目标为 shell 时，每个 shell 单元就是候选面；目标为 solid 时，先提取 incidence count 为 1 的外表面。quad 稳定拆成两个 triangle，为 triangle 建 AABB/BVH，查询应输出：

- closest face ID；
- closest point 与 distance；
- barycentric/local coordinate；
- face normal；
- 投影点离目标自由边的距离。

该信息还能帮助区分 B（投影接近目标边界）和 L（投影位于目标面内部）。

## 立即安全优化

这些改动的验收条件是 legacy candidate fingerprint 完全一致，并保持旧 pair/create 顺序。

### 1. 候选指纹与分阶段计时

候选指纹的规范输入：

```text
source component ID
target component ID
ordered path node IDs + is_closed
joint type / realization profile
side mode
width / spacing / tolerance（规范化精度）
```

批次记录以下阶段耗时及规模：

```text
component discovery
h + AABB
spatial broad phase
node/element snapshot
free-edge/exterior-face extraction
adjacency and KD/BVH build
directional A->B/B->A matching
layer/path/restoration/notch
joint and side classification
candidate freeze
native connector creation / realization
```

同时记录 component/node/element 数、粗筛后 pair 数、有向识别次数、路径数和总焊缝长度。性能报告至少使用多次运行的 p50、p90、p95 和 max。

### 2. AutoGroup 保守空间粗筛

当前所有无序组件对都进入 Tcl 双循环，复杂度为 `O(n²)`，且每对写进度日志。安全替代方案：

1. 为组件 i 计算 `r_i = 1.5h_i`，将 AABB 每个方向扩大 `r_i`。
2. 按 expanded `xmin` 排序，沿 x 轴 sweep-and-prune；active 集合只保留 `xmax >= current xmin` 的 box。
3. active 中先检查 expanded Y/Z overlap，得到保守候选对。
4. 对候选对继续执行当前的 `distance(AABB_i,AABB_j) <= 1.5*max(h_i,h_j)`，保证最终粗筛集合与旧实现相同。
5. 按旧的 `(i,j)` 组合次序排序后再做双向识别与创建，维持下游实体 ID 尽可能稳定。

不要用组件中心 KD tree。长纵梁等细长组件的中心很远、端部却很近；为保证不漏配对必须加入巨大包围球，通常会退化。

### 3. 操作级 immutable component snapshot

当前缓存只覆盖一次 `autoDetectSeams`。AutoGroup 的 A→B、B→A、A→C 会重新提取 A 的固有数据。一次 AutoGroup 识别期可共享：

```text
node IDs and XYZ
element IDs and connectivity
shell/solid classification
h and AABB
free-edge graph / exterior faces
node KD tree
element normal
node -> adjacent element
edge -> adjacent face
```

依赖目标的 `solidFacingBoundaryNodes`、匹配距离、类型和侧向仍属于 pair cache，不能放进 component intrinsic cache。

缓存 key 使用 `(operation_generation, component_id)`；每次点击开始递增 generation。所有 pair 预计算完成后冻结 candidates，进入 creation epoch。创建 PENTA/RBE3 后不再进行任何识别查询。本次操作结束或异常时统一释放。不要做跨操作的 session-global cache，因为 HM2019/2022 下可靠追踪用户移动节点、重划网格及 organize 的复杂度过高。

### 4. 减少 HyperMesh 数据库跨界和 UI 刷新

- 把 `hm_getvalue`、`hm_getmark`、`*createmark` 从 node/edge/pair 内循环移到 snapshot 构建阶段。
- 从 element connectivity 一次生成 node adjacency 和 element normal，避免每个最多 32 个采样点分别 `by node id` 查询。
- AutoGroup 对被 AABB 粗筛淘汰的 pair 不创建深层组件数据。
- 命令流文件可以完整记录；UI 进度按时间（如 100 ms）或 pair 数节流，错误、成功配对和阶段切换强制刷新。不要为每个被 AABB 排除的 pair 同步刷新 Tk。

## 影子验证后优化

以下项目都会改变候选，第一阶段只旁路计算和记录差异，禁止参与实际创建。

### 1. 点到目标面距离

保留 legacy node KD 结果，同时计算 shadow face distance，记录 `d_node-d_face`、除以局部 h 后的 P50/P90/P95/P99/max，以及：

```text
legacy d_node > 1.5h but shadow d_face <= 1.5h
legacy pair/path/type/side
shadow pair/path/type/side
```

先证明哪些 legacy rejection 是真实潜在漏焊，再决定切换。

### 2. 拓扑约束的双阈值路径增长

使用近距离强种子和较宽增长阈值。距离只决定种子，真实 free-edge graph 决定扩展：

```text
strong seed
  -> grow within relaxed distance
  -> tangent continuity
  -> target face-region continuity
  -> notch mask
  -> split at degree != 2
```

没有强种子、存在多个等价路径、分叉含义不清或 target region 不稳定时，回退 legacy candidate。它最终可取代“全局距离分层 + 事后补段”，但在影子基准成熟前不切换。

开放边补段的 shadow 特征应增加 missing arc length/local h、累计转角以及目标面区域序列。特别记录 `<1h`、`1–2h`、`2–4h`、`>4h` 的真实补段分布；长补段先降置信度，不直接扩大生产恢复范围。

### 3. AutoGroup 方向评分

当前 `maximum_gap/mesh_size` 对离群点敏感。shadow score 可使用：

```text
S = w1 * Q90(normalized gap)
  + w2 * (1 - boundary coverage)
  + w3 * fragmentation penalty
  + w4 * classification uncertainty
```

`abs(scoreAB-scoreBA)<epsilon` 时使用稳定 tie-break（当前排序后的较小 component ID），避免浮点扰动造成版本间方向翻转。该评分必须在 4:1 与 1:4 网格密度、局部离群点和同一几何 remesh 下验证。

### 4. 分类和侧向

- 最多 32 个样本改为按路径弧长分层采样，避免局部密网格占满样本。
- 日志把现有 `confidence` 改称 `agreement`；经过分桶校准后才产生 `confidence`。
- T/L/B shadow 分类增加投影点在目标 face interior 还是 boundary 附近的特征。
- 内部先表达 `physical_side = MATERIAL_LEFT/RIGHT/BOTH/AMBIGUOUS`，创建前根据 T/L/B、源单元法向和原生规则转换为 POSITIVE/NEGATIVE/BOTH。
- 88°–92°、法向不稳定或支持证据不足时继续回退用户选择；原生 `penta(mig)` fallback 是安全阀，不以降低 fallback rate 为目标扩张阈值。

## 准确性基准

Ground truth 不按节点 ID绑定，使用组件对和几何弧长描述，以支持同一几何 remesh。

| 层级 | 指标 |
| --- | --- |
| pair | precision、recall；错误 target 单独计 catastrophic misconnect |
| path | `correct arc length / truth length`、`correct arc length / predicted length` |
| safety | wrongly connected length / predicted length；跨豁口、跨分叉、串联邻近边必须为 0 |
| type | T/L/B confusion matrix、macro precision/recall/F1、native fallback rate |
| side | positive/negative/both/user fallback accuracy 和 fallback rate |
| calibration | agreement/score 分桶后的实际准确率及 ECE |

下一批应优先增加这些参数化模型：

1. source 对准超粗 target quad 面中心；
2. 同一几何 target 分别用粗/细/非匹配网格，验证 mesh invariance；
3. source:target 为 4:1 和 1:4，验证 AutoGroup 方向；
4. 60°/75°/89° 斜 T，89°/90°/91° 法向翻转；
5. 两条平行自由边的距离只差 0.2h；
6. 长曲线 gap 从 0.3h 平滑增到 1.3h；
7. 大豁口整体仍落在 1.5h 内、U 型折返自由边；
8. disconnected coincident target surfaces；
9. mixed tri/quad、高 skew quad；
10. 两组件很近但不存在应焊自由边。

核心验收是：**目标 remesh 后几何不变，组件配对、路径几何、类型和物理侧应保持不变。**

## 暂不建议

- 直接用 face distance 替换生产 node distance；
- 调大搜索半径或减少 h/normal 采样数；
- approximate nearest neighbour；
- 根据粗筛直接省略一个识别方向；
- 并行运行方向识别或改变 pair/create 顺序；
- session-global component cache；
- 用 component-center KD tree 做 AutoGroup broad phase；
- 在缺少基准时继续叠加局部阈值启发式。

## 推荐实施顺序和门槛

1. **基准设施**：候选 fingerprint、阶段计时、参数化几何 ground truth。门槛：当前 HM2019 回归全部通过，重复运行 fingerprint 稳定。
2. **安全性能阶段**：sweep-and-prune、operation snapshot、adjacency/normal 预计算、UI 节流。门槛：全基准 fingerprint 与 legacy 完全相同；HM 数据库调用和阶段耗时有可重复下降。
3. **face-distance shadow**：只记录不创建。门槛：覆盖粗 target、remesh invariance、skew quad 和 solid exterior face；不得产生跨组件/跨豁口误配。
4. **path hysteresis shadow**：比较路径弧长增删和 target face continuity。门槛：所有 catastrophic misconnect 为 0，召回率相对 legacy 提升后才允许小范围 opt-in。
5. **方向/type/side shadow**：建立置信度校准和稳定 tie-break。门槛：方向不随 mesh density 翻转，灰区稳定 fallback。
6. shadow 在真实模型集达到门槛后，再通过显式 feature flag 灰度切换；保留 legacy 回退一个发布周期。

## 已实施的三项首选改进（2026-09-05）

本次评审后已完成三项首选改进：

- 用 expanded-AABB sweep-and-prune 生成保守 pair 超集；
- 对超集继续调用原 `groupBoundsNear` 精确判断；
- 按旧嵌套循环 rank 恢复 pair 顺序；
- 普通组件扫描/粗筛进度按 100 ms 节流，错误、配对结果、创建和完成强制输出；
- 未修改有向识别、路径、类型、侧向、参数或原生创建逻辑。
- 增加 AutoGroup 预计算期 immutable cache，跨方向和 pair 复用所选组件固有数据；临时组件不缓存，创建或异常前释放。
- 候选冻结时生成只包含创建语义字段的稳定 fingerprint；识别与 AutoGroup 记录分阶段毫秒数，真实 HM 基线由旧完整 candidate plan 自动迁移为 fingerprint 基线。
- 增加点到目标外表面的可选 shadow 审计：壳面或实体外表面三角化后建立 AABB BVH，报告旧算法潜在漏识别节点和点到节点/点到面差异；shadow 数据不参与生产候选或创建。
- 增加目标网格尺寸、细分数和法向 gap 参数化的面距离 ground-truth benchmark，验证同一平面 remesh 后 face distance 保持不变。

验证结果：120 个确定性混合 AABB（紧凑、重叠、不同尺度和细长组件）与旧双循环输出的 pair 列表及顺序完全一致；2,000 个稀疏组件的 1,999,000 个理论组合，旧循环约 17.230 s，新粗筛约 0.0036 s，sweep 深比较为 0。该数据表示最适合空间粗筛的稀疏极限，不应外推为实际整批任务提速。操作级缓存使六组件、7 次预计算的 `hm_getvalue` 从 38,647 降至 16,310，XYZ 从每轴 7,091 降至 1,288，element config 从 2,702 降至 910。六组件 HM2019 T/L/B 候选计划与已有 fingerprint 一致并全部创建通过，开放边中段仍生成 PENTA。

新增基准和回归入口：

```powershell
runtime/python/windows-x64/python.exe -m unittest discover modules/solid_seam/tests
"D:/Program Files/Altair/2019/hw/tcl/tcl8.5.9/win64/bin/tclsh85t.exe" modules/solid_seam/tests/autogroup_broadphase_benchmark.tcl 2000
"D:/Program Files/Altair/2019/hw/tcl/tcl8.5.9/win64/bin/tclsh85t.exe" modules/solid_seam/tests/face_distance_parameterized_benchmark.tcl
```

## Altair 接口核对

Altair 2021 官方 [`*findedges` 文档](https://www.help.altair.com/2021/hwdesktop/hwd/topics/reference/hm/_findedges.htm)确认，旧版 `*findedges entity_type mark_id edge_type` 会创建新的 `^edges` 组件，且 mark 仅支持 1/2。这说明减少重复 `*findedges` 不只是节省拓扑计算，也减少临时 collector 创建、重命名、删除和 mark 操作。2023+ 增加了 name-value 新语法，但本项目为兼容 HM2019，应继续使用已经验证的旧式入口，不能把换用新版语法作为性能方案。

官方 [Data Names 文档](https://2023.help.altair.com/2023/hwdesktop/hwd/topics/reference/hm/data_names_r.htm)确认 `hm_getvalue ... dataname=...` 直接查询 HyperMesh 数据库实体。因此性能计数应优先跟踪数据库查询次数，而不是只优化 Tcl 的 `sqrt` 或 list 运算。官方[命令限制说明](https://www.2024.help.altair.com/2024/hwdesktop/hwd/topics/reference/hm/_setvalue_notes_and_limitations.htm)还提示传入 Tcl 命令的字符串可能存在 4096 字符约束，所以 component snapshot 应通过组件 dataname 分批读取并在 Tcl 内复用，不应把大型节点/元素 ID 列表拼成单条命令。
