# Solid Seam Connector

实体焊缝模块通过原生 Seam Connector 创建 PENTA6 + RBE3，输出到 `SEAM_SOLID`。

## 使用方式（2026-09-03 重构）

1. 启动模块打开子面板，设置参数后点击“开始”。按两次选择组成一组，完整组先缓存，不立即创建。第一步（node path 或源 comp）空选后统一批量执行；第二步（目标 comp）空选仅丢弃当前未完成组，继续收集。所有组的路径及 Auto 参数先计算，再按选择顺序逐组创建，避免新焊缝影响后续识别。各组只连接本组源/目标，不跨组组合；单组失败不阻止其余组，结束后恢复子面板并显示成功/失败组数。空缓存提交不创建任何实体。
2. **nodes+comps**：默认原生 **node path**（`*createlistbypathpanel nodes`），可输入一系列 nodes 或单个 node，再选择一个目标 comp。将每个节点关联的壳/实体单元所属组件取交集，并排除目标 comp，得到唯一源 comp。已有 RBE3/1D 附着单元不参与源组件归属。混合或歧义输入会报错；取消选择不会沿用上次输入。
3. 多点输入的节点顺序原样传给 `*createlist nodes 1 ...`，源 comp 和目标 comp 自动写入 `*createmark comps 2 ...`，调用原生 `*CE_ConnectorCreateByListAndRealizeWithDetails`。单点输入按同款网格焊缝规则寻找源组件的闭合自由边界：边界点只取所在闭环，内部点取源组件全部有效闭环；开口、分叉边界报错，不以距离强行闭合。优先读取 `*findedges` 的边拓扑，保留已有 `^edges`，不支持时按壳单元边拓扑回退。每个闭环由两段共享端点的原生 nodelist 实现，关闭端帽，覆盖包括末点到起点在内的全部边；这是因为 HM2019 `*createlist` 会去除重复的首尾节点。
4. **comps+comps**：依次选择一个源 comp、一个目标 comp。焊缝节点仅取自源 comp。壳网格优先 `*findedges` 提取自由边；实体网格优先 `*findfaces` 提取朝向目标的外表面轮廓。不支持原生命令时保留拓扑回退。使用 k-d tree 精确最近邻查询替换源/目标节点、面心/目标节点及局部间距的全量两两比较；单次识别缓存坐标，结束或异常后清空。
5. 两种手工模式均直接采用面板的类型、尺寸和方向。spacing 默认 6，width 默认 6，tolerance 默认 15，均为模型长度单位且必须为有限正数。tolerance 同时用作组件模式的搜索距离和原生实现容差。手工模式不会自动放大容差或调整尺寸。
6. 每条焊缝独立记录成功或失败，批次包含失败时面板会明确报告失败计数，不会把整批标为成功。

## AutoGroup 模式

选择 **AutoGroup → 开始**，在一次组件选择中输入所有待处理 comps，确认后自动配对并创建。空选取消，至少需要两个不同组件。一个组件可以连接多个邻接组件，不要求组件数量为偶数。

- 复用 Auto 的搜索范围、接头类型、尺寸、侧向及豁口过滤；手动尺寸控件禁用，双侧选择保留。
- 每个组件只预计算一次网格尺度和包围盒；按 Auto 搜索距离排除过远组合。其余组合检查两个源/目标方向，以各候选最大间隙与网格尺度比值的平均值较小者为源方向；相同分数按组件 ID 顺序确定。同一无序组件对只创建一个方向，避免正反重复。
- 全部路径和参数先计算再创建；无焊缝的组合跳过，识别或创建失败记录后继续。结束统计匹配、跳过、识别失败、无效及未配对组件。
- 显示进度条和滚动命令流，包含组件扫描、配对进度、方向识别、跳过原因、逐条实现及结果；完成后保留窗口供查看。批次完整日志及逐组实现结果位于 `runtime/tasks/solid_seam/`。
- AutoGroup 的组件粗筛采用扩大 AABB 的 sweep-and-prune，得到旧精确距离检查的保守超集；最终仍执行旧 AABB 距离判定并按旧组合顺序处理，因此不会漏掉旧流程会检查的组件对。大量远离组件不再进入二重循环。普通扫描进度最多约每 100 ms 刷新一次，错误、配对结果、创建步骤和完成状态仍即时输出，避免 Tk 重绘主导大型批次耗时。

配对沿用 Auto 的网格几何启发式，较宽搜索范围内的邻近边也可能形成候选；复杂模型需检查结果。HM2019 批处理验证：一次输入 T/L/B 样例共 6 个组件，识别 3 对、跳过 12 对，全部实现通过，预计算未改变模型元素。

## Auto 模式

Auto 与 comps+comps 使用相同的两次组件选择，使用“开始 → 两两选择并缓存 → 第一步空选提交 → 批量计算与创建 → 恢复面板”流程。类型、spacing、tolerance、width 由几何推导，对应手工控件禁用；创建侧也进行局部几何判断；无法确定时回退到面板选择，显式 both sides 始终保留。

Auto 和 AutoGroup 会为冻结后的候选生成 `seam-candidate-v1` 指纹。规范输入包含源/目标组件、按创建顺序排列的节点、闭合状态、类型/profile、侧向、width、spacing 和 tolerance；进度文字、候选显示 ID、阶段计时及 shadow 结果不进入指纹。`operation.log` 记录单对 `matching/topology/classification/total` 和 AutoGroup 的 `metadata/broadphase/directional/total` 毫秒数，`realization_result.json` 保存每条创建结果对应的指纹，便于升级前后逐条比对。

界面可勾选“影子检测：计算点到目标面的真实距离”。目标壳单元及实体外表面会三角化并建立 AABB BVH，源边界节点同时计算旧点到节点距离和真实点到三角面距离；日志报告搜索半径内的 shadow 节点、最多 100 个潜在漏识别节点及归一化距离差 P50/P90/P95/P99/max。此开关只执行旁路审计，绝不将 shadow 节点写回候选，也不改变方向评分或创建。默认关闭，避免在普通生产批次中增加外表面提取和 BVH 查询时间。

- 初始搜索范围由组件网格尺度推导：每个组件均匀采样最多 128 个单元，搜索距离取较大网格尺度的 1.5 倍，不读取手工 tolerance。使用原生边界提取和 k-d tree 查询；壳网格焊缝按真实边连接关系生成路径，保留闭环，在分叉节点处分成独立路径，不跨分叉猜测连接，也不合并邻近但不连通的边缘。
- **开放边中段保留**：全局最近层筛选可能将间隙较大的中段误判为另一层，造成只剩两端。现在沿真实自由边拓扑，保留已选两端之间、仍在原始搜索范围内且方向连续的中间节点。路径各边及两端相邻边与两端弦向夹角不超过 60°才保留；不跨越缺失或超范围节点，不沿直角豁口侧壁补连。后续豁口过滤继续生效。Auto 和 AutoGroup 共用此逻辑。
- 每条焊缝最多采样 32 组源/目标节点，读取附近壳单元法向。近垂直判 T；近平行且共面判 B，有法向间隔判 L。至少 80% 样本一致时采用该类型；斜接、混合、缺少壳法向等不明确情形使用原生 `penta (mig)` 自动类型处理。
- 使用每条焊缝自身节点间距的中位数 `h` 和自身最大匹配间隙 `g`，推导 `width = 0.6h`、`spacing = 0.6h`、`tolerance = max(1.5h, g+h)`。参数随模型长度单位缩放，不受手工值和旧版固定下限 6 覆盖。具体类型和参数写入 operation.log。

- **自动侧向**：复用最多 32 组分类样本及节点相邻壳单元缓存。L 使用原生规定的近平行负侧；T 比较目标板在源边两侧的局部材料支撑，近直角按源壳法向映射正负侧，斜角按钝角侧为正侧映射。至少 80% 样本一致才采用推断。对称 T、B 对接、缺少局部壳几何或混合结果不能唯一确定焊接侧时，保留面板选择；不额外创建测试焊缝。日志记录 `side_strategy`、`side_confidence` 和 `side_votes`。原生定义见 [Altair Seam Panel](https://help.altair.com/2022/hwdesktop/hm/topics/panels/help356.htm)。
- **缺单元豁口过滤**：comps+comps 和 Auto 的壳边界均先检查完整自由边轮廓，再应用目标距离筛选。排除局部向材料内部凹入、随后返回原边界方向的侧壁和底边，保留两端肩部节点并断开路径，绝不跨豁口连线。外凸凸台和普通转角不会因此被抹平；手动 node path 与单点闭环仍保留用户显式输入的边界。
- 豁口检查每个候选入口最多向前查看 24 条边，深度上限为局部网格尺度的 4 倍、空间范围为 8 倍；较大开口、平缓圆弧或不能确认返回原边界的结构不猜测删除。新增几何检查按边界规模线性增长，不遍历全模型元素。

这些参数属于基于网格的几何估计，不是材料或工艺规范给出的焊脚尺寸。初始采样和有限搜索范围有意限制开销；网格尺寸差异很大、间隙很宽或复杂混合接头可用手工模式指定参数。2026-09-04 的 HM2019 原生 T/L/B 样例均分类、创建通过，识别约 11–16 ms（小样例，不代表大型模型耗时）。

| 选项 | 含义 / 原生映射 |
| --- | --- |
| T | T 形接头，板边连接另一板表面；`penta (mig + T)`，FE type 118 |
| B | 对接接头，两板边缘相对连接；`penta (mig + B)`，FE type 119 |
| L | 搭接接头，两板搭接并沿边缘连接；`penta (mig + L)`，FE type 117 |
| positive side | 正侧；原生 `ce_pentasideoption=1` |
| negative side | 负侧；原生 `ce_pentasideoption=2` |
| both sides | 双侧；原生 `ce_pentasideoption=3` |

方向沿用 [Altair Seam 面板定义](https://2021.help.altair.com/2021/hwdesktop/hm/topics/panels/help356.htm)：T 正侧通常为钝角侧，L 负侧为两板较平行侧，B 正侧沿第一连接板的单元法向；接近直角时由自由边单元法向决定。创建字符串关键字是 `ce_pentasideoption`，查询已存储 detail 使用 `ce_penta_side_option`。HM2019 默认正侧可能不显式存储该 detail。

The Python detection pipeline is retained as legacy (`python/`, `python_bridge.tcl`) and is not used by the main flow.

Runtime output is written below `runtime/tasks/solid_seam/<run_id>` (`operation.log`, `realization_result.json`) and is intentionally ignored by Git.

## 大量元素被选中的修复（2026-09-04）

原创建流程的 `SolidSeamCommandProfile::snapshotIds` 在创建前后执行 `*createmark elems 1 all`，把全模型元素放进 mark 1，且读取后不立即清理。组件拓扑查询和平均法向查询也曾将整组件元素放进同一选择标记。这些内部统计操作并不是用户输入，却会留下大量元素被选中的状态。

现在全局 ID 快照使用只读 `hm_entitylist ... id all`；组件元素/节点直接读取 `hm_getvalue comps ... dataname=elements/nodes`；节点邻接查询仅使用局部标记，成功或异常都立即清理。创建返回前也清理临时标记。新增 ID 差集改用字典查询，避免在大模型上逐个线性查找。

HM2019 原生回归通过执行跟踪禁止全模型/整组件元素选取，并检查创建命令入口和批次结束的元素标记均为空；同时检查单点闭环的两段原生 Connector 首尾相接、内部种子识别及已有 `^edges` 保留。离线回归额外覆盖 30 万元素快照、开口/分叉、多闭环和异常清理。

## 历史双版本验证（重构前）

Verified headless on the installed builds with the F03 curved-T fixture from
`examples/AutoShellSeamBackend/test_fem/combined_all_cases.fem`:

| Build | candidates | realization | PENTA6 | RBE3 | output |
| --- | --- | --- | --- | --- | --- |
| 2019.0.0.70 | 2 (T_JOINT) | PASS | 48 | 147 | SEAM_SOLID |
| 2022.0.0.33 | 2 (T_JOINT) | PASS | 49 | 150 | SEAM_SOLID |

See `docs/solid_seam_dual_version_alignment_2026-08-08.md`.  Run the harness
with:

```
hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_solid_seam_harness.tcl
```

## Offline test

### 识别阶段性能优化（2026-09-04）

单次 `autoDetectSeams` 内复用原生自由边/外表面数据、自由边图、源/目标组件节点与元素列表及组件壳/实体判定；相邻采样点复用同一壳单元的法向和中心。第一次自由边提取同时读取连边，避免节点筛选和路径排序重复创建/删除临时 `^edges`。

AutoGroup 在全部预计算期间还建立 operation-local immutable cache，跨 A→B、B→A 和 A→C 复用所选组件的节点坐标、原始元素 connectivity、自由边/外表面、自由边图及壳/实体判定。只缓存用户选择组件和当时读取到的原始元素 ID；HyperMesh 创建/删除的临时组件不缓存。全部 candidates 冻结后先清空该缓存，再进入原生创建阶段；准备异常时同样清空。

缓存只在本次识别中有效，正常返回和异常返回均清空，不跨组件对或创建阶段保留。临时组件的节点/元素列表不缓存，防止原生临时 ID 复用造成错误；原生提取失败也不缓存，仍允许后续查询重试。配对顺序、双向判断、参数与原生创建调用保持原流程。

HM2019、T/L/B 六组件样例、连续 7 次预计算的中位数（含原生查询计数跟踪）：

| 指标 | 优化前 | 优化后 |
| --- | --- | --- |
| AutoGroup 预计算 | 86.183 ms | 62.113 ms |
| `hm_getvalue` 次数，7 次合计 | 42,273 | 38,647 |
| `*findedges` 次数，7 次合计 | 84 | 42 |

进一步加入 AutoGroup 操作级缓存后，同一基准的 `hm_getvalue` 总数从 38,647 降至 16,310，XYZ 查询从每轴 7,091 降至 1,288，element config 从 2,702 降至 910。小样例计时容易受进程启动和 trace 影响，因此以数据库调用数作为稳定指标。共享源组件的双目标原生样例只提取每个所选组件一次自由边，并保持旧候选集合不变；该样例当前还会产生目标—目标第三候选，已作为后续准确性 shadow 基准保留，不在性能优化中改变。

预计算约减少 28%，完整候选计划与优化前逐字段一致。此为小模型识别阶段数据，不代表大型模型或整个任务的提速比例；原生创建耗时仍占主要部分。`tests/hm_performance_smoke.tcl` 会把首次候选基线保存到 `temp/solid_seam_refactor/performance_plans.txt`，后续运行核对结果；有意更新候选行为时需更新该测试基线。缓存测试另覆盖异常清理、下一次识别读取模型变更以及临时组件 ID 不被缓存。

```powershell
.\runtime\python\windows-x64\python.exe -c "import sys,unittest; sys.path.insert(0,'python'); r=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.discover('modules/solid_seam/tests')); sys.exit(not r.wasSuccessful())"
```

新增 `refactor_offline.tcl` 验证真实 Tcl 过程的选择、参数、异常和空间索引行为。`test_refactor.py` 自动查找 Tcl 解释器，也可用 `TCLSH` 环境变量指定。

原生回归脚本仅在新建的批处理进程内导入测试模型：

```powershell
& 'D:/Program Files/Altair/2019/hm/bin/win64/hmbatch.exe' -nocommand -nouserprofiledialog -tcl modules/solid_seam/tests/hm_refactor_smoke.tcl
```

日志位于 `temp/solid_seam_refactor/native_<version>.log`，以日志末行 `PASS` 判定脚本检查通过（本机 hmbatch 正常结束时仍返回进程码 1）。脚本检查源组件归属、三种侧向的原生 detail 与实现结果，以及 T/B/L 创建。

2026-09-03 在 HM2019.0.0.70 中通过：T 正侧/负侧分别生成 3 个 PENTA，双侧生成 6 个；L 生成 20 个；B 生成 9 个，均为 `PASS`。21 项 Python 测试（含 Tcl 行为回归）和原有 8 项 Tcl 几何识别检查通过。重构后的图形界面交互仍需在实际模型中确认。

2026-09-04 补充验证：独立 HM2019 测试模型删除一个边界四边形单元后，手动组件模式和 Auto 均生成两条正常边界路径，无凹口节点或跨口连接；小样例检测分别约 8 ms、10 ms。侧向回归覆盖正负支撑、源法向翻转、双侧支撑歧义与 L/B 原生规则。
