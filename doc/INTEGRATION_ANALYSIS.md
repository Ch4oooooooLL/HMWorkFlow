# Local Mesh Optimizer 集成分析

日期：2026-07-14
目标版本：HyperMesh 2019
状态：第一阶段项目分析完成；HyperMesh 命令仍需在 HyperMesh 2019 实机录制并验证

## 1. 分析范围与结论

本分析在新增模块代码之前完成，检查了项目入口、核心加载器、全部模块文件、通用函数、快捷键、安装/更新入口、配置文件、构建脚本和现有网格质量相关实现。

当前项目是面向 HyperMesh 2019 的 Tcl/Tk 工具箱，采用“核心模块字典 + 每功能一个 Tcl 文件 + `workflow_common.tcl` 通用层”的结构。Local Mesh Optimizer 应继续采用该结构：在 `hw_toolkit_core.tcl` 注册一个可见 Mesh 模块，Tcl 主模块放在 `modules/`，纯标准库 Python 代码作为该模块的辅助目录放在 `modules/local_mesh_optimizer/`。不应建立第二套主界面、注册器、快捷键系统、主题或状态配置格式。

项目当前没有运行期 Python 启动器，也没有 Python 解释器定位封装；唯一 Python 用途是构建/打包，不由 HyperMesh Tcl 调用。因此 Python 启动是本功能必须补齐的集成能力，但应只增加一个可复用的解释器解析/启动入口，不复制多套启动逻辑。

当前环境没有发现 HyperMesh/HM Batch 可执行文件、Altair 环境变量、`command.cmf` 或 `.criteria` 样本，不能声称已经完成 HyperMesh 2019 原生命令的动态验证。现有源码只能证明部分命令曾被项目采用，不能证明候选的局部优化命令参数与 HM2019 完全一致。所有高风险优化命令必须经过实机 capability probe 和录制命令确认后才启用；未验证能力应在 UI 中禁用或明确标为不可用，不能静默降级或伪造结果。

## 2. 当前工具箱架构

### 2.1 启动链

启动链如下：

```text
hw_toolkit.tcl
  -> install_update.tcl
     -> source hw_toolkit_core.tcl
     -> ::HWToolkit::ensureCoreLoaded
     -> ::HWShortcut::initialize / installAutoLoader
     -> ::HWToolkit::run
        -> source workflow_common.tcl、shortcut_manager.tcl 和可见模块
        -> ::HWToolkit::showPanel
```

推荐启动入口是 `install_update.tcl`；`hw_toolkit.tcl` 是兼容入口。工具箱根目录由脚本自身的规范化路径推导，不依赖当前工作目录。

### 2.2 主界面入口

主界面定义在 `hw_toolkit_core.tcl` 的 `::HWToolkit::showPanelHome`（`showPanel` 直接委托给它，`showPanel2022` / `showPanelLegacy` 保留为兼容别名）。2019 与 2022 使用同一个扁平单层布局：所有可见工具按 `Geometry`、`Mesh`、`Connector` 分组一屏列出，每个工具一行，包含：

- 工具名称（点击直接运行，悬停高亮）；
- 一句话描述；
- `设置` 与 `绑定快捷键` 两个按钮（未提供设置项的模块按钮置灰；已绑定快捷键时按钮直接显示快捷键）。

窗口使用系统色板（`SystemButtonFace` 面板灰、`SystemWindow` 输入区、`SystemHighlight` 选择蓝），后端统一为经典 Tk（进度条等用 ttk），不再加载 hwtk：2022 的 batch 解释器在 `package require hwtk` 时会直接崩溃（已用本机 hmbatch 实测），且统一后端保证两代布局像素级一致。字体在 `::HWFlow::initFonts` 中统一为 Microsoft YaHei UI 9pt 系列，两代相同。

Local Mesh Optimizer 应加入 `::HWToolkit::MODULES` 字典的 `Mesh` 组，使用现有 `label_zh/label_en`、`desc_zh/desc_en`、`proc`、`settings_proc` 字段。模块入口建议为：

```tcl
proc          "::LocalMeshOptimizer::runAction"
settings_proc "::LocalMeshOptimizer::runSettings"
```

### 2.3 模块注册和加载

`::HWToolkit::sourceOneModule` 根据模块 key 或 `file` 字段从 `modules/<name>.tcl` 加载脚本，并用 `SOURCED_FILES` 避免重复 source。`::HWToolkit::invokeModule` 负责忙状态、异常捕获、用户提示和结束后的浏览器刷新。

因此新模块不需要也不应创建自己的注册器。模块应通过现有入口被主界面和快捷键管理器自动发现。

### 2.4 模块目录风格

现有运行期模块均是 `modules/*.tcl` 单文件，使用独立 namespace 和数组保存 UI 状态。没有现成的运行期 Python 包目录。

为了隔离本模块较多的 Python 数据处理代码，同时保持现有加载约定，建议采用：

```text
modules/local_mesh_optimizer.tcl             # 注册器直接 source 的 Tcl 入口/UI/HM 适配层
modules/local_mesh_optimizer/
  python/
    optimizer_controller.py
    adjacency.py
    region_builder.py
    report_generator.py
    criteria_parser.py
    io_utils.py
  tests/
  README.md
```

第一版不拆成多个互相 source 的 Tcl 文件，避免偏离项目现有单文件模块惯例；若实机适配代码增长明显，再在该子目录中拆分 HM2019 适配文件。

## 3. 可复用机制

### 3.1 UI、主题和布局

`modules/workflow_common.tcl` 已提供：

- `::HWFlow::createTopLevel`：创建并登记顶层窗口，不使用永久置顶；
- `::HWFlow::uiFont`：`header/title/heading/module/small/fixed` 字体角色；
- `::HWFlow::txt`：中英文切换；
- `::HWFlow::bindAutoWrap`：描述文字自动换行；
- `::HWFlow::backToHome`：返回主界面。

主界面按钮宽度、字体和布局由 `hw_toolkit_core.tcl` 统一生成。界面基础设施统一使用经典 Tk 后端（进度条等用 ttk）和系统色板，2019/2022 共用同一实现；新模块不得建立独立 GUI 后端或复制窗口生命周期逻辑。

### 3.2 配置持久化

通用配置 API 为：

- `::HWFlow::stateFile`；
- `::HWFlow::loadState` / `saveState`；
- `::HWFlow::applyStateToArray` / `saveArrayState`。

模块状态保存为 `config/<module>_state.txt`，采用 Tcl list 安全编码的 `key value` 行，可保存含空格和非 ASCII 字符的路径。Local Mesh Optimizer 应复用 `saveArrayState local_mesh_optimizer ...`，不创建 JSON 配置系统。任务级 JSON 是 Tcl/Python 通信文件，不是第二套用户配置。

快捷键配置是唯一单独存放在用户目录的配置，由 `shortcut_manager.tcl` 管理；新模块会自动进入现有快捷键模块列表，不新增快捷键逻辑。

### 3.3 选择和 mark

现有模块直接使用 HyperMesh 原生选择面板：

```tcl
*createmarkpanel comps 1 ...
*createmarkpanel elems 1 ...
set ids [hm_getmark ... 1]
```

并在选择前后清理 mark。项目没有统一的通用 selection wrapper，也没有 mark 租约/分配器。新模块应封装自身的 `pickComponents`、`pickElements`、`pickAnchorNodes`，清楚约定 mark 1 用于当前输入/操作、mark 2 用于失败输出，并在每次命令前后清理。不能假设 mark 会跨命令保持。

### 3.4 进度和取消

`::HWFlow::progressOpen`、`progressUpdate`、`progressAppend`、`progressCancelled`、`progressClose` 已实现进度窗口、命令流、事件泵和取消按钮。Local Mesh Optimizer 应复用它们。

本模块还需要 `cancel.flag`，原因是 Python 子进程/文件协议不能直接读取 Tcl 变量。Tcl 的取消动作应同时设置现有进度取消状态并原子创建任务目录中的 `cancel.flag`；这属于现有取消机制的跨进程适配，不是第二套 UI。

### 3.5 浏览器和显示

`workflow_common.tcl` 已有 component 创建、查找、显示、浏览器刷新和脚本触碰组件跟踪函数，可复用：

- `componentIdByName` / `componentName`；
- `createComponent`；
- `displayComponent`；
- `refreshBrowser`；
- `markComponents` 等相近实现。

项目没有完整的 mask/display/current collector 快照恢复封装。新模块必须新增模块内的显示状态保存/恢复适配，并以 HM2019 实测命令为准。

### 3.6 日志

现有运行期日志方式是 `puts`、`hm_usermessage` 和 `progressAppend`，没有文件日志框架。Local Mesh Optimizer 的审计要求高于现有模块，需在任务目录写 `optimizer.log`，同时把摘要推送到现有进度窗口。Python 使用标准库 `logging`，Tcl 使用一个模块内文件追加函数；两者写同一日志格式或分别写后合并。该日志只属于任务产物，不建立全局日志系统。

### 3.7 临时目录

项目没有统一临时目录 API。历史铸件模块曾把质量临时文件放在 `config/`（该模块已废弃移除），不适合长任务和模型快照。

建议在工具箱根目录下使用被构建脚本明确包含/排除策略管理的：

```text
temp/local_mesh_optimizer/task_YYYYMMDD_HHMMSS_<pid>/
```

目录必须在启动时做可写测试，任务文件采用 UTF-8，JSON/进度文件采用“同目录临时文件 + rename”原子替换。报告目录应由用户设置决定，默认放在模型目录；模型未保存时回退到工具箱 `reports/`。

### 3.8 Python 调用和定位

当前运行期没有 Tcl 调 Python 的实现，也没有 Python 定位约定。构建脚本使用系统 `python`/`python3`，不能直接视为 HyperMesh 运行期保证。

建议解析顺序：

1. 持久化配置中的显式 Python 路径；
2. HyperMesh/Altair 已知 Python 命令（仅在 HM2019 实机确认后加入）；
3. Windows `py -3`；
4. `python3`；
5. `python`。

每个候选都以短命令验证版本和 UTF-8 路径能力。最终启动必须用 Tcl list 构造参数，不能拼接 shell 字符串。第一版 Python 仅做邻接、区域、文件解析和报告，不调用网络或修改 HyperMesh 模型。

## 4. 现有质量与网格命令证据

### 4.1 源码中已存在的命令

`modules/batch_mesher/`（原 `modules/batch_mesh_washer.tcl` 已并入 BatchMesher 模块）当前包含：

- `*hm_batchmesh2`；
- `*createstringarray`；
- `hm_ce_gethmholes`。

这些命令提供集成参考，但现有 `check2DQuality` 在无法读取 API 且 mark 2 为空时会返回 `unknown`，并允许配置继续执行。Local Mesh Optimizer 不能采用这种宽松策略作为最终质量结论。

### 4.2 候选命令的验证状态

| 命令/能力 | 仓库证据 | 当前环境动态验证 | 集成策略 |
| --- | --- | --- | --- |
| `hm_getelementsqualityinfo` | 原铸件模块曾调用（模块已废弃移除） | 未验证 | capability probe 后用于质量摘要/失败 mark；必须确认 criteria 上下文 |
| `*getqualitysummary` | 原铸件模块曾调用（模块已废弃移除） | 未验证 | 仅在 HM2019 录制确认参数及失败 mark 语义后使用 |
| `*readqualitycriteria` | 仓库无调用；Altair 官方参考给出单文件参数，版本历史注明 2019.1 更新 3D criteria | 未验证 | 已按官方单文件签名封装；仍需实机确认路径、错误和当前 criteria 上下文 |
| `*splitelements` | 官方旧版参考给出 `method mark_id`，方法 2 为最短对角、加 100 反向 | 未验证 | Python 比较两种切分的最差三角形得分，Tcl 仅对目标 quad 执行方法 2/102 |
| `*elementqualitysetup` | 官方旧版 Element Quality 命令示例使用区域 mark | 未验证 | 仅为短边塌缩建立局部上下文；修改阶段任何错误触发全任务恢复 |
| `*elementqualitycollapseedge` | 官方参考版本历史为 13.0，旧版签名 `elem_id edge_index` | 未验证 | 仅处理规划器确认的瘦长三角形或内部细长 quad 短边 |
| `*elementqualityshutdown` | 官方示例与 setup 成对 | 未验证 | 无论动作成功与否都尝试关闭上下文；关闭失败同样回退 |
| `*nodemodify` | 官方参考给出 `nodeid x y z` | 未验证 | 仅用于经二次自由边核验的细长条带协调外扩；保持几何关联开启时跳过 |
| `*hm_failed_elements_cleanup` | 原铸件模块曾调用（模块已废弃移除） | 未验证 | 不能替代 criteria 最终判定；可作为受控兼容候选 |
| 模型另存/读取快照命令 | 仓库无封装 | 未验证 | 在实现恢复功能前必须录制确认；不得用 Undo 次数恢复 |
| mask/display/current collector 快照 | 仅有零散显示函数 | 未验证 | 模块内封装并实测恢复 |

### 4.3 HM2019 必做验证步骤

在可访问 HyperMesh 2019 的机器上，使用一个小型壳网格和已知 `.criteria` 文件执行：

1. 手动读取 criteria 并运行一次 Element Quality 检查；
2. 手动将一个失败 quad 分别沿两条对角线切分；
3. 手动使用 F3/Element Quality 塌缩一个瘦长 tria 的短边；
4. 手动沿短边外延方向移动一个真实自由边节点；
5. 另存模型、修改、重新加载快照；
6. 检查 `command.cmf`，复制实际命令及完整参数；
7. 在干净会话逐条 `catch` 执行，记录返回、失败 mark、criteria 路径含空格/中文时的行为；
8. 关闭或故意传错 criteria，验证错误路径不会产生“0 个失败”的假成功；
9. 将验证结果和 HM build 号填入测试记录。

在完成上述验证前：质量检查可做 capability 检测和明确报错；实际拓扑动作不得假装成功，仍由 profile 门禁阻止修改。

静态参考：Altair 官方旧版 `*splitelements`、`*elementqualitycollapseedge`、`*nodemodify`、[`*readqualitycriteria`](https://2022.help.altair.com/2022.1/hwdesktop/hwd/topics/reference/hm/_readqualitycriteria.htm) 和 [API Programmer's Guides 索引](https://help.altair.com/hwdesktop/hwd/topics/reference/hm/api_programmers_guides.htm)。官方页面用于确定候选签名；它们不能替代目标 HM2019 build 的 `command.cmf` 和模型回退验证。

## 5. Local Mesh Optimizer 集成设计

### 5.1 Tcl 职责

- 主界面和高级设置；
- 原生选择面板；
- scope 转换为 2D element mark；
- criteria 读取和 HyperMesh 原生质量检查；
- 失败单元、连接关系、坐标、组件信息批量导出；
- 自由边/组件边界/连接节点等可由 HM 稳定获得的信息导出；
- 保存全模型备份和区域/轮次检查点；
- 按规划动作运行 quad 切分、短边塌缩和受控自由边节点外移；
- 每轮原生复检、恶化检测和回退；
- 显示失败/已优化区域；
- 最终另存新模型和恢复显示状态。

### 5.2 Python 职责

- 校验任务 JSON；
- 解析 criteria 供显示和报告使用（不做最终质量裁决）；
- 用共享完整边构建 2D 邻接；
- 构建失败连通区域；
- 邻域逐层扩展、组件/保护边阻断、区域上限和分块；
- 区域状态、进度和取消文件维护；
- 汇总 CSV/HTML/JSON 报告；
- 提供可脱离 HyperMesh 运行的纯算法测试。

Python 不移动节点、不计算最终 Jacobian/Skew/QI 合格性、不直接修改 `.hm`。

### 5.3 文件通信

任务目录使用 `task.json`、连接关系 CSV、失败/保护 ID 文本、`regions.json`、`progress.json`、`result.json` 和日志。模型文件只保留任务前 `before.hm` 与正常完成后的最终另存模型，不创建区域/轮次 checkpoints。大 ID 集合用逐行文本/CSV，不反复塞入 JSON。

Tcl 负责生成输入并执行原生命令；Python 每次只完成一个明确阶段。第一版优先采用同步阶段调用，区域修改仍在同一 HyperMesh 会话串行执行。进度百分比只由已完成阶段和区域数计算。

### 5.4 质量和回退原则

- 每个 `failed_after` 都必须来自 HyperMesh 原生复检；
- 检查命令异常或结果无法解释时状态为 `quality_check_error`，不是通过；
- 整体任务开始前保存 `before.hm`；
- 最终模型始终另存为 `<stem>_local_optimized_<timestamp>.hm`；
- 至少支持可靠恢复 `before.hm`；
- 不保存区域级或轮次级模型检查点；
- 用户取消时恢复整个任务前模型，不保留本次任务的局部修改；
- 新失败、负 Jacobian/翻转、保护节点移动、修改命令异常或超时均恢复 `before.hm` 并终止任务；尚未修改模型的区域检查错误仍可标记失败并继续。

## 6. 分阶段新增和修改文件

### 6.1 预计修改

- `hw_toolkit_core.tcl`：注册模块、关闭窗口时保存状态/清理窗口；
- `README.md`：模块入口和总体说明；
- `guide.html`：本地帮助入口；
- `build_package.sh` / `build_package.ps1`：确保 Python 子目录、文档、测试资源和空目录策略正确打包；
- `.gitignore`：忽略任务临时文件、报告和模型快照（需先检查现有规则）。

工作区中 `build_package.sh`、`guide.html`、`modules/mesh_seam_weld.tcl`、`modules/rbe2_bolt_connector.tcl` 已有用户修改。开发时必须基于现状做最小补丁，不覆盖或格式化无关内容。

### 6.2 预计新增

- `modules/local_mesh_optimizer.tcl`；
- `modules/local_mesh_optimizer/python/*.py`；
- `modules/local_mesh_optimizer/tests/*`；
- `config/local_mesh_optimizer_defaults.txt`（仅当默认规则确需独立可编辑文件；UI 状态仍使用现有 state API）；
- `README_LocalMeshOptimizer.md`；
- `doc/local_mesh_optimizer_hm2019_validation.md`；
- `tests` 所需的小型中立格式连接关系夹具、任务 JSON 和期望结果；
- 示例离线报告。

真实 `.hm` 测试模型只能在 HyperMesh 2019 中生成并验证。当前无 HyperMesh 的开发环境不能制造一个可宣称有效的 `.hm` 文件；在交付清单中必须把该项标为“待 HM2019 实机生成/验证”，不能用伪文件替代。

## 7. 风险点与控制措施

1. **HM2019 命令签名不确定**：所有候选命令先 capability probe，再通过 `command.cmf` 实录固化；无能力时禁用并提示。
2. **criteria 上下文不明确**：读取失败或质量 API 未建立 criteria 上下文时任务终止，不把空 mark 当作通过。
3. **模型恢复命令未验证**：在恢复命令实测前不开放修改型优化；备份不得覆盖原模型。
4. **Python 环境不统一**：标准库实现，启动前逐候选验证，路径全程用 Tcl list 和 UTF-8 文件协议。
5. **大模型内存/通信**：连接 CSV 流式写读、边哈希邻接、区域级数据、避免全模型 JSON 和逐单元进程通信。
6. **mark 冲突**：每个原生命令临时重建 mark 并清理，不跨回调假设 mark 内容。
7. **保护边识别能力差异**：自由边和组件边界可用拓扑计算兜底；孔边无法可靠区分时保护全部自由边并在报告说明；特征边/几何关联未经验证时禁用相关修改。
8. **刚性/焊缝类型多样**：通过 HyperMesh config/type 和模型实际 collector 规则组合识别，不只硬编码单一焊缝类型；未知连接邻域默认保护并报告。
9. **超时不可强杀 HM 命令**：时间限制在命令前后检查；单个不可中断原生命令只允许完成后取消，并在 UI 明示。
10. **回退粒度**：只保留任务前快照和最终另存模型。无法安全接受的修改会恢复整个任务并终止，避免区域/轮次检查点的时间与磁盘成本，绝不使用 Undo 次数猜测。
11. **深度拓扑风险**：默认关闭。只有经 HM2019 实测且能保持 component、连接和几何关联的动作才开放，否则区域标为人工处理。
12. **现有代码回归**：仅追加模块注册和清理钩子；用 Tcl 普通解释器做 source/语法 smoke test，用纯 Python 单元测试覆盖区域算法，最终必须在 HM2019 做集成回归。

## 8. 实施门禁与顺序

### 阶段 2：最小可用版本

只有在 HM2019 完成 criteria 检查、失败 mark、quad 切分、短边塌缩、节点移动和模型快照命令验证后，才启用修改模型的 MVP。先完成范围选择、criteria、原生检查、显示失败、规划动作、复检、另存、基础日志和全局恢复。

### 阶段 3：区域化和多轮迭代

增加标准库 Python 邻接/区域分析、邻域扩展、状态机、区域检查点、进度文件和 cancel flag。单模型内串行处理。

### 阶段 4：深度优化和报告

在元素级质量优化命令实测后开放标准/深度差异。局部拓扑动作逐项通过保护与回退测试后再启用；未通过的动作保持禁用。增加完整 HTML/CSV 报告、区域浏览和人工处理标记。

## 9. 第一阶段验收结论

- 已定位主界面、启动入口、模块注册、设置入口和快捷键机制；
- 已定位配置持久化、UI 字体/窗口、进度/取消、浏览器和 component 通用函数；
- 已确认没有运行期 Python 启动器、统一文件日志、任务临时目录或完整显示状态快照；
- 已确认现有 2D 质量实现及其不适合直接复用的宽松回退；
- 已确认当前机器无法完成 HyperMesh 2019 动态命令验证；
- 已给出保持现有架构的文件布局、职责边界、风险控制和阶段门禁。

下一步应先实现不修改模型的基础框架和纯 Python 区域算法，同时准备 HM2019 命令录制验证脚本；任何实际优化能力只在相应命令通过实机验证后启用。
