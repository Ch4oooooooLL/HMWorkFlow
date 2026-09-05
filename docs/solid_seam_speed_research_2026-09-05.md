# Auto / AutoGroup 实机提速研究（2026-09-05）

## 结论

下一轮优先处理 **Auto 批次缓存、HM 数据批量读取，以及创建阶段全模型差集**。AutoGroup 已有空间粗筛和组件快照，继续只优化配对循环不是所有场景下的最佳投入。原生 AABB 可用，但其局部倍率远大于整批收益；升级 HM 版本也不能保证提速。

本轮新增独立实验脚本，不改生产算法。工作区原先已有未提交的缓存、粗筛、诊断等改动；所有实测均基于这些改动后的当前代码，不能视作对发布版的提速对比。

## 环境与方法

- `D:/Program Files/Altair/2019/hm/bin/win64/hmbatch.exe`：`hm_info -appinfo VERSION = 19.000000`。
- `D:/Program Files/Altair/2020/hwdesktop/hm/bin/win64/hmbatch.exe`：运行目录为 `hwdesktop/hw/bin/win64`，**实际版本为 22.000000**，不能按文件夹名称认定为 HM2020。
- 两者均为 Tcl 8.5.9。各自独立、隐藏的 hmbatch 进程导入仓库样例，没有操作用户交互模型。
- 样例 `examples/AutoShellSeamBackend/test_fem/combined_all_cases.fem`：全模型 763 节点、512 单元；选择六个组件，覆盖 T/L/B，得到三组候选。闭环组分两段，共四次原生创建调用。
- 每个识别/查询实验连续执行九次，报告中位数；所有单次值保留在日志。创建仅执行一批，没有九次重复，因此不能把创建数字当作稳定版本性能排名。
- Auto 对照使用 AutoGroup 选出的三个有向组件对，保证输入可比较；AutoGroup 还做粗筛及双方向判断，两者并非等量工作。
- 这些是小模型、无 GUI 的测试，未覆盖真实大装配、显示重绘、百万单元、实体—实体及异常创建。收益不得直接外推。

## 实测结果

以下为最终脚本一轮输出，单位毫秒：

| 实验 | HM2019 | HM2022 | 解释 |
|---|---:|---:|---|
| 当前 AutoGroup 预计算 | 52.740 | 77.599 | 九次中位数 |
| AutoGroup 改用原生 AABB 实验 | 44.597 | 75.350 | 候选指纹一致，约下降 15.4% / 2.9% |
| 当前 Auto 三组预计算 | 36.367 | 64.043 | 包含 automaticSettings |
| Auto 包裹现有操作级缓存实验 | 29.236 | 49.970 | 指纹一致，约下降 19.6% / 22.0% |
| 256 节点 XYZ 逐节点读取 | 2.498 | 5.560 | 每次 768 个查询 |
| 相同节点 XYZ 批量读取 | 0.638 | 0.556 | 每次三个查询，逐值及逆序输入映射核对通过 |
| 六组件 AABB，独立 Tcl 坐标扫描 | 2.971 | 5.144 | 缓存关闭的局部基准 |
| 六组件 AABB，原生查询 | 0.083 | 0.077 | 包含组件 mark 操作，六个数值一致 |
| 三组创建，包含新增实体审计 | 192.226 | 303.160 | 单批，不含预计算 |
| 四次原生 CE 调用之和 | 98.828 | 171.047 | 包含在上一行内，不可相加 |

两套版本的三组新增单元分别为 43、86、39；`hm_entityrecorder elems` 与旧全模型前后差集一致，包括闭环的两段创建。它证明本样例上的接口可用和结果一致，尚未证明替换后的整批提速比例。

HM2019 原有 `hm_performance_smoke.tcl` 也通过：七次带 query trace 的预计算中位数 60.238 ms，`hm_getvalue` 共 16,310 次，`*findedges` 共 42 次；三组原有候选指纹全部一致，创建合计 189.404 ms。带 trace 和不带 trace 的计时不直接混用。

冷启动需要单独看：最终实验第一次 AutoGroup 预计算分别约 599 / 633 ms，后续明显更快。这提示懒加载/首次原生调用等一次性成本存在，但本轮没有细分其归因；不能只用热态中位数描述用户首次点击体验。

## 建议实施顺序

### 1. Auto 使用与 AutoGroup 相同的预计算期缓存

位置：`tcl/main.tcl::prepareSelectionPairs`、`tcl/seam_creator.tcl::autoDetectAndCreate`、`tcl/automatic_mode.tcl::automaticSettings`。

当前 Auto 的 automaticSettings 在单次 detection cache 开启前计算网格尺度；识别又读取相同坐标、connectivity。多个选择对之间也没有 AutoGroup 的操作级复用。实验在 prepareSelectionPairs 外包裹 beginGroupRecognitionCache/endGroupRecognitionCache 即获得约 20% 的预计算收益。

实现时收集本批所有被选组件，在全部预计算之前开始缓存，正常和异常出口统一释放，创建之前清空。可进一步缓存 componentMeshPitch 的最终值。保持逐组异常继续、候选顺序及当前 Auto 的有向语义。用户选择阶段不能提前建立快照。

### 2. 分块批量读取坐标和 connectivity

位置：`tcl/auto_detect.tcl::nodeXYZ / elementNodesImpl`。

当前仍大量执行 x/y/z 三个独立查询；elementNodesImpl 从 node1 逐个读到终止位置，壳单元也会查询 node5。HM 两个实装版本均支持 `hm_getvalue nodes user_ids=... dataname=x`，本轮 256 节点测试查询阶段约快 3.9 / 10 倍。

先在缓存填充层按块取 x/y/z，再按原节点 ID 顺序映射；遇到不支持、长度不符或查询错误时回退现有逐实体方法。connectivity 建议按 config 分组、按所需角点/节点字段批量查询，本轮尚未实测该部分。保留高阶/混合单元原始 connectivity 语义，不能只存前三四个节点。块大小应同时限制 ID 数量和命令字符串长度。

这是数据提取阶段的倍率，不是任务整体倍率；尽量按需填充，避免为粗筛淘汰的组件建立完整拓扑。

### 3. 创建阶段改用新增实体记录器，消除全模型扫描

位置：`command_profiles/hm2019_penta_mig_common.tcl::snapshotIds / newIds / realizePentaMig`。

目前每个开放焊缝/闭环半弧都枚举创建前后的全部单元，再在 Tcl 建 dict 求差集；另有 connector、component 快照。若原模型 E 个单元、K 次原生创建，仅单元扫描和集合构造就约随 K×E 增长。这是代码复杂度结论，当前 512 单元样例不足以量化百万单元上的收益。

推荐紧贴原生 CE 命令开启/关闭 elems、connectors、comps 记录器，直接取得本次新增实体；保留状态、PENTA/RBE3、组件归属校验。闭环应每半弧独立记录，再合并结果。不能用“ID 大于创建前最大 ID”代替，ID 复用可能漏掉新实体。

正式切换前需扩展验证：创建失败/部分成功、临时实体创建后删除、既有 SEAM_SOLID、稀疏及复用 ID、记录器嵌套调用。确认记录 ID 是否全部仍存活；异常也必须关闭记录器。先 shadow 对照差集，满足门槛后关闭全量快照，否则保留快照就没有消除 O(E) 成本。

随后将新单元 config 一次读出并同时分出 PENTA/RBE3，减少当前 elementIdsByConfig 的两遍逐元素查询。

### 4. AutoGroup 原生 AABB 与派生几何复用

位置：`tcl/auto_group.tcl::groupComponentBounds`、`tcl/automatic_mode.tcl::localShellPatch`、`tcl/spatial_index.tcl::spatialIndex`。

`hm_getboundingbox comps 1 1 0 0` 在两套实装可用，flag=1 限定网格、global AABB。本轮数值和最终候选指纹都一致。独立查询快数十倍，但替换后的整批预计算仅约下降 3%～15%，因为旧 AABB 的坐标缓存还可供识别复用，而且其他计算占主导。大型真实模型仍需验证，并正确保存/恢复占用的 mark。

AutoGroup 已缓存坐标、原始 connectivity 和边界，但目标 KD tree、localShellPatch/normal 等派生数据仍会跨方向重建。可将目标索引、组件内 node→element 邻接、原始壳单元中心/法向放入预计算期缓存。索引键须包含确切节点集合/表面用途，不能复用方向相关的实体 facing boundary。保留最近邻等距时较小 ID 的规则。该收益尚未量化。

现有 sweep 固定沿 X 轴；大量组件在 X 上重叠、只沿 Y/Z 分离时，active 列表仍可能接近二次扫描。可按组件分布选择更合适的扫描轴，继续保留精确 AABB 判定及旧 pair 顺序。真正密集相邻的组件仍需识别，不能期待空间粗筛消除真实候选数量。

### 5. GUI 与文件开销列为第二批

- `nativePanelSessionBegin/End` 主要隐藏/恢复工具窗口，并没有包裹整个识别/创建的图形重绘开关。两套实装存在 hm_blockredraw，但不存在 hm_blockbrowserupdate；不要复制依赖后者的新版本脚本。选择完成后再进入阻止重绘的计算区间，成功和异常均恢复原状态。需在 GUI 实测，hmbatch 不能验证收益。
- `validateBeforeCreate` 加载 profile，createOneCandidate 随后再次加载；每次还反复读取 JSON 和 source Tcl。可将已验证 profile 按 realization 类型在本批复用，但必须处理 T/L/B 使用同名 realize 过程的切换，不能只简单跳过 source。收益尚未测量。
- 日志每条 open/write/close，AutoGroup 还写组日志。可批次持有 channel、按事件 flush；保留完整文件日志，GUI 文本插入合并节流。当前小样例不是瓶颈证据，公司环境下文件访问代价需另测。

## 不建议作为本轮提速手段

- 不减少 AutoGroup 的双向识别，不改变 search distance、spacing、width、gap 或候选数量；这会改变结果，无法称为等价性能优化。
- 不并行访问同一 HM 会话的 mark、临时组件和 connector 创建；均为可变会话状态。若未来外置 Python，仅考虑在只读快照上做纯计算，并先测量导出/启动/回传成本。现有运行链路是 Tcl + 原生 CE，Python 并非自动提速开关。
- 不以安装目录名或软件新旧选择更快版本；本轮 HM2022 没有显示小样例性能优势，也未控制到足以给出通用版本排名。
- 不默认开启 face-distance shadow。当前默认关闭；它增加审计工作，不是提速功能。

## 后续验收与复现

实施推荐按 1→2→3→4 推进；若真实模型主要慢在创建，则将第 3 项提前。每项保持候选 fingerprint、创建类型/侧向/参数、PENTA/RBE3 和失败行为一致，单独测量收益。增加“大背景模型 + 少量焊缝”“共享目标多源”“沿 Y/Z 分离”“实体外表面/高阶网格”“失败与闭环”案例，记录冷/热总耗时、各阶段 p50/p95、数据库调用和峰值内存。

研究脚本：`modules/solid_seam/tests/hm_speed_research.tcl`。**只允许在新 hmbatch 进程执行**，会导入样例并创建焊缝。不同安装必须串行运行，因为写入同一个 research.log。启动参数为 `-nocommand -nouserprofiledialog -tcl D:/WrokSpace/HMWorkFlow/modules/solid_seam/tests/hm_speed_research.tcl`，退出后检查日志末行 PASS；进程退出码本身不足以判断通过。

最终原始数据保留于 `temp/solid_seam_speed/research_hm2019.log` 和 `research_hm2022.log`；临时目录不会作为正式测试基线提交。Python 运行时与压缩包未改动。

## 官方接口依据

- [hm_getvalue](https://2024.help.altair.com/2024.1/hwdesktop/hwd/topics/reference/hm/hm_getvalue.htm)：支持 user_ids 等集合选择；旧版本兼容性由上述本机实验核实。
- [hm_entityrecorder](https://2024.help.altair.com/2024.1/hwdesktop/hwd/topics/reference/hm/hm_entityrecorder.htm)：记录新实体，需显式 on/off，文档列为 12.0 引入。
- [hm_getboundingbox](https://help.altair.com/hwdesktop/hwd/topics/reference/hm/hm_getboundingbox.htm)：网格 flag 与全局 AABB；本轮使用旧版支持的 box_type=0。
- [图形重绘恢复说明](https://2021.help.altair.com/2021.2/hwdesktop/hwd/topics/reference/hm/api_programmers_guide_12_110_r.htm)：阻止重绘是持续状态，脚本必须恢复。

接口文档说明能力与语义；所有性能数字来自本轮本机日志。
