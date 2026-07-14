# Local Mesh Optimizer / 局部网格优化

Local Mesh Optimizer 根据 HyperMesh `.criteria` 检查失败壳单元，用 Python 按共享完整边划分局部区域和扩展邻域，并把最终质量裁决保留在 HyperMesh。

## 当前交付状态

已实现并可离线测试：

- 主工具箱 Mesh 分组入口和高级设置入口；
- 组件、element、固定节点原生选择面板；
- 当前显示/全模型/组件/element 四种范围；
- criteria 路径持久化和 HyperMesh 原生读取错误处理；
- 基于 `hm_getelementsqualityinfo` 的质量检查适配和失败 mark 一致性保护；
- 单元连接关系、节点坐标和任务文件导出；
- Python 共享边邻接、连通区域、1～3 层扩展、组件边界阻断和区域上限；
- 原子 JSON、进度文件、取消标志协议；
- 离线 HTML/CSV 报告生成器；
- 模型快照/恢复命令适配壳及明确错误；
- 基于缺陷形态的 quad 切分、短边塌缩、自由边协调外扩动作规划；
- 快速/标准/深度真实轮次和动作映射门禁。

当前开发机没有 HyperMesh 2019，无法从 `command.cmf` 验证 `*splitelements`、`*elementqualitycollapseedge`、`*nodemodify`、Element Quality 会话和模型读写的准确行为。因此修改模型的“开始优化”仍受 `HM2019_PROFILE=hm2019_recorded` 门禁保护。工具不会伪造质量改善、保护状态或进度。

## 启动

在 HyperMesh 2019 中运行：

```text
File > Run > Tcl/Tk Script > install_update.tcl
```

也可使用兼容入口 `hw_toolkit.tcl`。在主面板的“网格 / Mesh”页选择“局部网格优化 / Local Mesh Optimizer”。模块会自动进入现有快捷键管理器。

## 选择优化范围

支持：

1. 用户选择的组件（默认）；
2. 用户选择的单元；
3. 当前显示的全部单元；
4. 当前模型全部单元。

点击“选择组件”或“选择单元”后使用 HyperMesh 原生选择面板。两类选择都可保留，但实际处理范围只由当前单选项决定。“固定节点”用于收集用户锚点。

进入原生选择面板前，工具箱会暂时解除 Tk 窗口置顶并隐藏工具窗口；选择结束或命令报错后恢复。该公共保护已用于工具箱内所有 `*createmarkpanel` 入口，避免原生面板被置顶窗口遮住而表现为“卡死”。

当前版本的导出会忽略不能读取为 3/4 节点连接关系的 element；质量检查仍由 HyperMesh 决定。大范围执行前应先在小模型确认当前 solver profile 的壳单元行为。

## 选择 criteria

点击“浏览”选择 `.criteria`。路径可包含空格和中文，状态保存到现有 `config/local_mesh_optimizer_state.txt`。显示“文件存在”只表示文件系统检查通过；只有原生读取成功后才显示“HyperMesh 读取成功”。

质量检查执行：

1. 根据范围建立 element mark；
2. HyperMesh 读取 criteria；
3. HyperMesh 运行原生质量 API；
4. 检查摘要失败数与失败 mark 数是否一致；
5. 复用项目现有 Washer 孔环识别逻辑，默认把 Washer 网格从自动优化集合中剔除；
6. 导出失败集合和连接关系；
7. Python 同步构建局部区域及具体优化动作计划。

检查完成后的状态区会同时显示失败数、Washer 人工处理数、区域数、自动动作数和其他人工复核数。优化直接使用这份计划：第一轮复用检查阶段由 HyperMesh 产生的失败集合，不重复执行相同检查；修改后才进行局部原生复检。criteria 上下文按规范化路径和文件修改时间缓存，同一任务的区域复检与最终检查不会反复调用 `*readqualitycriteria`。范围、criteria 或影响规划的参数发生变化时，“开始优化”会自动重新检查和规划。

任何命令错误或失败数量不一致都会停止，不会把空 mark 当作合格。

## 优化规则和模式

默认优化不再调用通用 `*optimsmooth` 或逐 element 的默认 optimized：

1. 普通失败四边形：分别计算两条对角线切分后的两组三角形，以“较差三角形的形状得分最高”为最优解，再映射到 `*splitelements 2` 或反向方法 `102`。
2. 两条边均显著长于第三边的三角形：选择短边并进入 Element Quality 会话执行短边塌缩。短边触及锚点、保护边或与其他拓扑动作冲突时转人工处理。
3. 细长四边形条带：若长边是真实自由边，则把共享自由边节点按各自短边向外方向统一计算、每个节点每轮只移动一次；若不在自由边，塌缩可安全处理的内部短边。
4. 其余三角形、受保护动作、冲突动作和无法确认真实自由边的动作标记为人工处理。

- 快速：执行一次安全拓扑动作和复检，不执行自由边外扩。
- 标准：执行上述三类动作，允许按最大轮次渐进外扩和复检。
- 深度：当前与标准采用同一组已规划动作和更完整的人工标记；不会偷偷进入未经验证的局部重网格。

每轮失败数减少，或失败数不变但 HyperMesh 返回的综合 QI 改善时，视为明确改善。失败数相同且没有可比较综合 QI 时视为“结果不确定”。成功执行 quad 切分或短边合并后，每个拓扑替换动作允许最多一个局部失败单元 ID 的暂时增长，因为原单元可能被多个新单元替代；这不等同于缺陷区域扩散。上述结果会保留到最终全范围 HyperMesh 质量守卫。只有增长超过实际拓扑动作额度、可比较 QI 明确变差，或新失败扩散到优化区域外时，才恢复任务前模型。

## 参数

常用参数：

| 参数 | 默认 | 范围/说明 |
| --- | ---: | --- |
| 邻接层数 | 2 | 1～3，共享完整边逐层扩展 |
| 最大轮次 | 3 | 1～10 |
| 特征角 | 30° | 待 HM2019 特征边适配验证 |
| 优化级别 | 标准 | 快速/标准/深度 |

高级设置包含瘦长三角形阈值、细长四边形阈值、自由边目标长宽比、单轮最大外扩倍数、单区域上限、Python 3 命令、报告目录和自动保存/打开选项。

“排除 Washer 网格（人工处理）”默认开启。它复用 `shell_washer_hole_rbe2.tcl` 的闭合自由边、孔径、圆度/椭圆度及外环一致性验证，并按 `config/washer_rules.txt` 的最大 washer 层数排除相关单元。排除的失败单元仍保留在完整质量结果、`washer_excluded_failed.txt` 和报告统计中，但不会进入 Python 区域划分或 Tcl 自动拓扑动作。只有用户明确关闭该开关后才允许自动处理 Washer 网格。

“保护自由边”仍保护一般自由边；“允许细长条带自由边受控外扩”只对规划器确认且 Tcl 再次核验为真实自由边的节点开放。启用“保持节点几何关联”时，`*nodemodify` 外扩会跳过并转人工处理，因为当前没有 HM2019 实机证据证明它能可靠保持关联。

目标 QI 为空时使用 criteria。Python 解析 criteria 只用于元数据/报告，不替代 HyperMesh 判断。

优化进度按“任务 → 区域 → 轮次 → 动作 → 连接刷新 → 保护核验 → 局部复检 → 最终守卫 → 保存 → 报告”分配单调递增的百分比，并显示区域/轮次/动作计数、已用时间和预计剩余时间。动作数量很大时最多分约 20 个刷新批次，避免命令流快速滚动反而拖慢界面。

## 停止

“停止”会调用现有进度取消机制，并在任务目录原子创建 `cancel.flag`。Python 在阶段边界检查它。HyperMesh 原生命令不可安全强杀时，只能等待该命令返回，再恢复唯一的任务前快照；取消后不会保留本次任务已完成区域的修改。

## 恢复

设计要求是在任何修改前只生成一次 `before.hm`，正常结束时只另存一次最终优化模型；不再创建区域或轮次 `.hm` 检查点。当前适配壳使用 `*writefile`/`*readfile`，必须按验证文档在目标 HM2019 build 上确认后才能开放修改流程。

由于没有区域快照，拓扑命令异常、保护节点移动、局部质量明确恶化、整体质量守卫失败或用户取消时，会恢复 `before.hm` 并结束整次任务。该策略以少量磁盘写入换取明确、可靠的恢复边界，绝不通过 Undo 数量猜测。

`*writefile` 和 `*readfile` 调用前使用 HM2019 支持的 `hm_answernext yes` 响应覆盖/替换确认；任务拥有的旧目标文件会先删除，避免确认框隐藏在置顶进度窗口后。自动流程不使用 `tk_messageBox`：状态、错误和完成信息进入主界面状态区、进度命令流和 `optimizer.log`。进度完成后保留窗口，由用户点击“关闭”。

“恢复优化前模型”只在存在非空、已成功保存的任务前快照时可用。为避免确认弹窗，第一次点击会在状态区警告，8 秒内再次点击才执行恢复。原始模型永不作为输出目标。

## 输出位置

任务中间文件默认位于：

```text
<工具箱根目录>/temp/local_mesh_optimizer/task_YYYYMMDD_HHMMSS_<pid>/
```

最终模型设计命名为：

```text
<原模型名>_local_optimized_<时间戳>.hm
```

报告默认放在模型目录：

```text
LocalMeshOptimizer_Report_YYYYMMDD_HHMMSS/
```

模型未保存时回退到工具箱目录，也可在高级设置指定报告目录。

报告包含 `summary.html`、`summary.csv`、`regions.csv`、`settings.json` 和日志。HTML 使用内嵌 CSS，可离线打开。

## Python 与 Tcl 通信

Tcl 写入 `task.json`、`failed_elements.txt`、`element_connectivity.csv`、`node_coordinates.csv`、保护 ID/边文件；Python 写入 `regions.json`、`region_tasks.csv` 和 `progress.json`。区域执行结果通过 `region_results.csv` 汇总，再由 Python finalize 阶段生成报告。

所有 JSON 使用 UTF-8，Python 写入采用同目录临时文件和 `os.replace`。大 ID 集合使用行文本/CSV，避免逐 element 进程通信。

Windows 运行时由 Tcl 后台启动随包提供的 `pythonw.exe`，标准输出、错误输出和完成状态写入任务目录，不显示命令行窗口。Tcl 通过 `after`/`vwait` 等待原子状态文件并继续处理 Tk 事件；不会用同步 `exec` 阻塞主界面。高级设置若填写 `python.exe`，模块只会使用同目录的 `pythonw.exe`；找不到无窗口解释器时会明确报错。

独立运行示例：

```bash
python optimizer_controller.py --task task.json --stage build-regions
python optimizer_controller.py --task task.json --stage finalize
python optimizer_controller.py --task task.json --stage report
```

返回码：0 成功，1 部分成功，2 取消，3 输入错误，4 HyperMesh 调用错误，5 内部异常。

## 哪些情况需要人工处理

- quad 切分、边塌缩或节点外移命令未通过当前 HM2019 build 验证；
- 失败区超过上限且不能安全缩小/分块；
- 受保护连接类型无法可靠识别；
- 拓扑动作后出现新失败、负 Jacobian、翻转或锚点移动；
- 质量摘要与失败 mark 不一致；
- criteria 不适用于当前 element 类型；
- 多轮无改善或区域超时；
- 局部重网格可能改变组件、焊缝、刚性连接或几何关联。

## 故障排查

- “Python 3 未找到”：确认打包目录包含 `runtime/python/windows-x64/pythonw.exe`；或在高级设置填写带同目录 `pythonw.exe` 的 Python 3 路径。模块只依赖标准库。
- “选择后像卡死”：确认所有模块均通过新版 `workflow_common.tcl` 加载；原生选择期间工具窗口应暂时隐藏，中键确认或 Esc 取消后恢复。
- “criteria 读取失败”：在 HyperMesh 2019 手工打开同一文件，检查 solver profile、路径和文件格式，并查看任务日志。
- “质量摘要和 mark 不一致”：不要继续优化；录制一次手工质量检查并核对 `command.cmf`。
- “优化被禁用”：完成 [HM2019 命令验证](doc/local_mesh_optimizer_hm2019_validation.md)，再把实录命令接入版本适配层。
- “恢复失败”：不要覆盖原模型；保留任务目录、当前模型和日志，手工打开 `before.hm`（若已生成）。

## 测试

纯 Python 测试：

```bash
python -m unittest discover -s modules/local_mesh_optimizer/tests -v
```

HyperMesh 集成测试必须使用另存测试模型，并按验证文档执行。当前仓库不能在无 HyperMesh 环境中生成或伪造有效 `.hm` 测试模型。
