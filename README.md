# HMWorkFlow

> 面向 HyperMesh 的工程前处理自动化工具箱：将几何处理、网格生成、连接建模与质量复核组织为可配置、可验证、可追溯的工作流。

HMWorkFlow 基于 **Tcl/Tk + Python** 构建，以 HyperMesh 2019 为实机验证基线，并持续适配 HyperWorks 2022。项目聚焦车身及结构件有限元前处理，把依赖人工经验的重复操作转化为“批量识别—规则决策—受控执行—结果校验”的标准流程，同时保留工程师对高风险候选的最终确认权。

当前版本：`0.9.0-stabilization` · 求解器基线：`OptiStruct` · 默认工程单位：`mm–N–s–tonne`

[快速开始](#快速开始) · [核心能力](#核心能力) · [系统架构](#系统架构) · [工程质量](#工程质量) · [模块手册](#模块功能和用法) · [更新记录](CHANGELOG.md)

## 项目亮点

- **覆盖完整前处理链路**：从中面抽取、几何清理、并行 BatchMesh，到 RBE2、螺栓、接触、打胶、焊缝及完整性检查，模块既可组合为流程，也可独立使用。
- **兼顾性能与宿主兼容性**：Tcl 负责 HyperMesh API、模型事务和 Tk 交互，Python 负责 FEM 解析、几何算法、并行规划与报告生成，通过稳定的文件协议隔离两侧运行时。
- **面向工程风险设计**：统一执行前检查、候选预览、重复项检测、快照、回读校验、失败隔离与局部回滚，避免把“命令执行成功”误判为“模型结果正确”。
- **支持大模型后台任务**：以拓扑连通域拆分 BatchMesh，使用固定容量调度多个 `hmbatch` worker；主会话保持响应，任务状态、PID、日志与中间产物均可追踪。
- **具备可交付的工程体系**：包含离线单元测试、HyperMesh smoke test、验证模型、跨平台打包脚本及 GitHub Actions 自动测试和发布流程。

## 核心能力

| 工作阶段 | 代表模块 | 自动化能力 |
| --- | --- | --- |
| 几何准备 | Midsurface、Geometry Cleanup、Geometry Seam | 批量抽中面，清理倒角/圆角/沉台，创建并校验焊缝几何。 |
| 网格处理 | BatchMesher、Local Mesh Optimizer、Property Assignment | 并行划分网格，按 criteria 定位并修复局部质量问题，批量匹配材料与属性。 |
| 连接建模 | Hole RBE2、Bolt、CBUSH、Contact、Adhesive、Solid Seam | 识别孔、节点链与相对面，批量创建 OptiStruct 连接实体并回读状态。 |
| 载荷建模 | Batch Temp Nodes、Batch Load Application | 解析多工况文本、映射节点并生成 Force、Moment、Load Collector 与 Subcase。 |
| 质量复核 | Weld Integrity Check、FEM Automatic Seam | 筛选潜在漏焊区域，支持候选审查、受控创建、质量复检与任务级恢复。 |

典型流程：

```text
组件规范化 → 中面与几何清理 → 网格生成与质量优化
           → Property/材料赋予 → 连接与载荷建模 → 完整性复核
```

## 系统架构

```text
┌──────────────────────────────────────────────────────────┐
│ HyperMesh / Tcl/Tk                                       │
│ 主界面 · 原生选择器 · 模型读写 · Undo/回滚 · 结果回读     │
└───────────────────────┬──────────────────────────────────┘
                        │ FEM / JSON / manifest / task state
┌───────────────────────▼──────────────────────────────────┐
│ HybridCore                                               │
│ 任务隔离 · 工程上下文 · Worker 调度 · 增量校验 · 日志协议  │
└───────────────────────┬──────────────────────────────────┘
                        │ detached Python worker
┌───────────────────────▼──────────────────────────────────┐
│ Python                                                   │
│ 拓扑解析 · 几何识别 · 候选规划 · 并行计算 · 报告生成       │
└──────────────────────────────────────────────────────────┘
```

| 层级 | 技术 | 职责 |
| --- | --- | --- |
| 宿主集成 | Tcl/Tk、HyperMesh Tcl API | UI、实体选择、原生命令调用、模型事务与跨版本适配。 |
| 计算后端 | Python 3.8 | FEM 数据解析、孔/边界/焊缝识别、局部网格规划和自动化测试。 |
| 任务协议 | JSON、FEM、CSV、manifest | 跨进程传输、执行状态、输入输出校验及结果追溯。 |
| 交付体系 | PowerShell、Bash、pytest、GitHub Actions | 离线测试、用户手册生成、白名单打包和自动发布。 |

核心设计原则是：**HyperMesh 对模型拥有最终解释权**。Python 只生成可审查的候选与执行计划；涉及模型修改时，由 Tcl 在宿主环境中执行，并以新增实体、连接关系、realization 状态和原生质量标准完成复核。

## 相较 HyperMesh 原生手动操作的提升

这里的“原版”指直接使用 HyperMesh 原生面板完成选择、识别、创建、命名、归类和检查。工具箱仍调用 HyperMesh 原生命令完成实际建模，但把原本需要工程师逐孔、逐单元、逐组件或逐连接重复执行的操作，改为“一次选择、批量识别、自动创建、统一校验”。

| 工作内容 | HyperMesh 原生手动操作 | HMWorkFlow 自动化方式 | 主要效率提升 |
| --- | --- | --- | --- |
| 组件命名、材料与 Property | 逐个修改名称、查找材料、创建或选择 Property，再逐个赋予。 | 扫描全部组件，从统一名称解析厚度和材料，批量创建/复用 PSHELL；异常项单独生成复核清单。 | 人工工作量由“逐组件处理”降为“一次执行 + 只检查异常项”。 |
| 中面与几何清理 | 反复选择组件或局部面，设置参数，执行后再手动重命名和整理 collector。 | 保留原生几何能力，并自动读取厚度、连续处理局部特征、命名输出、归入 assembly，单次失败可撤销后继续。 | 省去重复设置、命名、归类和失败后的流程重启。 |
| 壳孔/实体孔 RIGIDS | 逐孔识别边界或圆柱面，创建中心节点，选择从属节点并创建 RBE2/RIGIDS。 | 对选中组件批量识别有效孔、中心和节点环，自动跳过或合并重复连接并按源组件输出。 | 人工创建轮次由“孔数量 H 次”降为“每批 1 次”。 |
| CBEAM/CBAR 螺栓 | 逐组查找 RIGIDS 中心节点、判断方向和孔径，再逐段创建并配置属性。 | 自动分组、排序和配对中心节点，按孔径创建/复用 PBEAM/PBAR，并批量生成连接段。 | 人工创建轮次由“连接段数量 S 次”降为“每批 1 次”。 |
| 焊缝、接触和打胶 | 反复选择两侧实体、创建 connector/contact surface、设置参数、检查投影范围和 realization 状态。 | 自动识别或筛选候选区域，批量规划连接，清除越界位置，创建后回读状态并把失败项单独报告。 | 把多面板、多轮选择压缩为一次候选选择和一次结果复核。 |
| 局部网格质量修复 | 运行 quality check 后逐个定位失败单元，判断可移动节点，反复调整并重新检查。 | 读取 criteria，只分析失败区域，在局部子网格中模拟修改，按区域执行、复检和回滚。 | 将人工逐单元试错改为自动规划，工程师主要处理无法安全自动修复的例外。 |
| 漏焊检查 | 手动隐藏/显示组件，逐对观察自由边附近是否存在漏焊，并记录检查进度。 | 自动提取自由边和邻近组件 Pair，只把候选区域送入逐项孤立、定位和完成人工确认。 | 检查量由“全部组件组合”缩小到“算法筛出的候选 Pair”。 |

### 效率如何量化

对于批量任务，最直观的指标是**人工交互轮次**。如果原生操作需要对 `N` 个对象重复执行，而工具箱可一次批量完成，则：

```text
人工交互轮次缩减率 = (N - 1) / N × 100%
人工交互效率倍数   = N / 1 = N 倍
```

例如，批量处理 50 个孔时，原生方式通常需要完成 50 轮孔识别与 RIGIDS 创建；工具箱将其合并为 1 轮组件选择和批量执行，重复交互轮次减少约 **98%**。批量生成 30 段螺栓时，重复创建轮次减少约 **96.7%**。这里衡量的是人工操作量，不等同于计算运行时间。

漏焊检查可按候选压缩率衡量。`C` 个组件最多需要人工检查 `C × (C - 1) / 2` 个组合；若工具最终筛出 `K` 个候选 Pair，则：

```text
人工检查量缩减率 = 1 - K / (C × (C - 1) / 2)
```

实际工时提升建议用同一模型分别计时，并按下面的统一口径记录：

```text
工时节省率 = (HyperMesh 原生手动工时 - HMWorkFlow 工时) / HyperMesh 原生手动工时 × 100%
效率倍数   = HyperMesh 原生手动工时 / HMWorkFlow 工时
```

计时应同时包含选择、参数设置、创建、命名整理、结果检查和错误返工。README 中不直接给出未经实测的固定工时倍数；不同模型规模、网格质量和候选通过率会明显影响结果。

### 除效率之外的改进

- **一致性**：统一命名、材料实体匹配、Property 规则、输出 collector、配置文件和 OptiStruct 工程上下文，减少不同操作者之间的结果差异。
- **安全性**：增加求解器/单位制预检、重复项检测、候选预览、结果回读、失败隔离、任务快照和局部回滚。
- **可追溯性**：保留任务目录、日志、候选结果和人工审查状态，便于复核问题来源。
- **使用体验**：提供中英文界面、快捷键、进度/取消、窗口切换、Model Browser 刷新和用户状态保存。

自动化的目标是减少机械操作，不替代工程判断。`Solid Seam Connector`、`Geometry Seam`、`Adhesive Connector` 等受控功能仍要求在目标 HyperMesh 环境完成命令 profile 或 smoke test；焊缝完整性检查只提供候选，不会自动修复模型。各模块的状态和限制以 [模块状态](modules/module_status.json) 及后文说明为准。

## 工程质量

HMWorkFlow 将“算法正确”和“HyperMesh 中可安全落地”分开验证：

| 验证层级 | 覆盖内容 | 执行方式 |
| --- | --- | --- |
| 离线测试 | FEM 解析、几何算法、命名规则、协议、打包边界及兼容性逻辑 | `python tools/run_offline_tests.py` |
| 集成验证 | Tcl/Python 桥接、任务状态、增量 FEM、worker 生命周期 | HybridCore 测试与验证脚本 |
| 宿主 smoke test | HyperMesh 原生命令、选择器、实体创建、回读和跨版本行为 | `modules/**/tests/*.tcl` |
| 场景验收 | 孔连接、接触、焊缝、网格优化等典型和负向案例 | `examples/*_Validation/` |
| 持续交付 | 测试、中文 PDF 手册、发布白名单校验、ZIP 构建 | `.github/workflows/build-release.yml` |

模块按风险与验证程度标记为 `production`、`controlled` 或 `review_only`。最新状态、验证基线及额外 smoke-test 要求以 [modules/module_status.json](modules/module_status.json) 为准，不能用离线测试替代目标 HyperMesh 版本的实机验证。

## 运行环境与安全边界

| 项目 | 支持情况 |
| --- | --- |
| HyperMesh | 2019.0.0.70（验证基线）；HyperWorks 2022 按模块持续回归 |
| Solver profile | OptiStruct |
| UI runtime | HyperMesh 内置 Tcl/Tk |
| Python | 随发布包提供便携式 Python 3.8，无需系统级安装 |
| 平台 | Windows 为主要运行环境；打包脚本同时支持 PowerShell 与 Bash |

执行任何会修改模型的入口前，请先确认 `config.yaml` 中的求解器、单位制及 `units_confirmed` 与当前项目一致。平台工程上下文、用户数据目录、任务清理策略和验证方法见 [平台服务迁移说明](doc/migration_platform_services.md)。

快捷键的首次安装、更新和恢复流程见 [快捷键安装与更新](doc/shortcut_installation.md)。请优先运行 `install_update.tcl`；`hw_toolkit.tcl` 保留为兼容入口。仓库目录边界、Git 跟踪规则和发布白名单见 [仓库目录与发布规则](doc/repository_layout.md)。本机解压的 `runtime/python/windows-x64/python38/` 只用于运行，不进入 Git 或发布 ZIP。

局部网格优化模块的集成状态、使用步骤、HM2019 运行验证和已知限制见 [README_LocalMeshOptimizer.md](doc/README_LocalMeshOptimizer.md)。该模块坚持以 HyperMesh criteria 和原生质量结果为最终判定，并保留运行时错误处理、任务快照、复检和回滚。

默认界面语言为中文。需要英文界面时，将项目根目录 `config.yaml` 中的 `workflow.language` 改为 `en_US`。

界面基础设施使用统一的经典 Tk 后端（进度条等少量控件用 ttk），配色直接采用 HyperMesh 原生系统色板（面板灰、输入框白、选择蓝），因此 2019 与 2022 的窗口外观和布局完全一致。`modules/workflow_common.tcl` 提供共享构建器（分组标题、操作条、表单行、滚动容器、窗口居中）。2019 与 2022 的启动链和模块加载器都会显式按 UTF-8 读取仓库脚本，避免 2022 新界面进程按 Windows ANSI 代码页读取中文而产生乱码。

窗口不再使用永久 `-topmost`。调用 HyperMesh 原生实体选择面板时，只临时隐藏由工具箱登记的窗口，不影响同一 HyperMesh 进程中的其他 Tcl 窗口。HyperWorks 2022 若无法创建 panel mark，会自动改用新版选择条对应的 edit widget；原生 FEM 导入/导出则统一防重入并自动处理被遮挡的 translator 确认提示。

## 快速开始

### 安装与启动

首次安装或更新时，在 HyperMesh 中运行：

```text
File > Run > Tcl/Tk Script > install_update.tcl
```

也可以直接运行兼容入口：

```text
File > Run > Tcl/Tk Script > hw_toolkit.tcl
```

运行后会打开 `HyperMesh Toolkit` 主面板。2019 与 2022 使用相同的扁平单层布局：所有工具按分类分组、一屏列出，点击工具名称直接运行，无需先选分类再选工具。模块归类为三部分显示：

```text
Geometry
Mesh
Connection
```

每个工具一行：名称（点击即运行，悬停高亮）＋ 一句话说明 ＋ `设置` / `绑定快捷键` 两个按钮。未提供设置项的模块其 `设置` 按钮自动置灰；无快捷键绑定时按钮显示 `绑定快捷键`，已绑定时直接显示快捷键。窗口可拉伸，工具较多或屏幕较小时自动出现滚动条。模块运行结束后会自动刷新 Model Browser 并刷新图形窗口，不会改变已有 component 的显示/隐藏状态。

主面板底部的 `工具箱设置 / Toolbox Settings` 统一管理主入口、模块快捷键和非模块功能。页面将“模块快捷键”和“功能快捷键”分区显示；每个工具行的 `绑定快捷键` 按钮会直接打开设置页并选中对应模块，按钮上同时显示当前绑定状态。

功能快捷键当前包含 `By Face`、`By Attached` 和 `By Path Mode`。它们不是主页面模块，不会打开独立选择窗口，而是直接作用于 HyperMesh 2019/2022 当前活动的原生 Entity Selector。设置页还可整体启用/停用快速选择、打开调试记录，以及显式允许 By Path 在原位切换失败时使用 HyperMesh 原生 Path widget（默认关闭）。模块与功能使用同一按键映射、冲突检测和持久化文件，但在页面中保持独立分区。

快捷键会直接调用模块的 `proc` 执行入口，不会打开 HMWorkFlow 主界面，也不会打开模块的 `more` 配置界面。

快捷键采用抢占式窗口切换：按下主面板或模块快捷键时，工具会先保存当前面板状态并销毁本项目已经打开的窗口，待旧窗口的 `tkwait` 调用退出后再创建目标窗口。因此窗口即使位于 HyperMesh 后台，也不需要手动关闭。公共进度任务仍在执行时不会强制销毁任务窗口，以避免中断模型修改；应先等待任务完成或请求取消。

### 快捷键持久化

快捷键配置保存到当前 Windows 用户目录，不写入项目目录：

```text
%APPDATA%\HMWorkFlow\shortcuts.cfg
```

如果没有 `APPDATA` 环境变量，则保存到：

```text
~/.hmworkflow/shortcuts.cfg
```

首次成功应用快捷键时，工具会尝试在用户 Home 目录的 `hmcustom.tcl` 中安装 HMWorkFlow 专用加载块：

```text
# >>> HMWorkFlow shortcut loader >>>
...
# <<< HMWorkFlow shortcut loader <<<
```

工具只维护这两个标记之间的内容，不会覆盖 `hmcustom.tcl` 中的其他用户代码。项目目录移动后，快捷键管理器会显示 `路径失效`，点击 `修复自动加载` 可更新为当前项目路径。点击 `禁用自动加载` 只删除 HMWorkFlow 标记块，不删除用户快捷键配置。

HyperMesh 2019 会在读取 `hmcustom.tcl` 时直接恢复快捷键；HyperMesh 2022 的建模上下文和快捷键接口建立较晚，启动加载器会自动等待接口就绪，并在上下文切换后重新应用绑定。因此安装或更新一次后即可在后续启动中直接使用，不需要每次重新加载 `install_update.tcl`。

### 构建发布包

需要分发完整工具目录（含安装入口和帮助页）时，在项目根目录运行：

```powershell
.\build_package.ps1
```

或在 Linux/macOS 环境运行 `./build_package.sh`。生成的 ZIP 包含
`install_update.tcl`、`guide.html`、模块、配置和文档。

## 推荐工作流

### 准备项目配置

1. 确认源组件保留 `Vxx_件号` 基础名称；中面完成后可运行 `读取 BOM 表` 模块，当前版本会给 `MIDSURFED` Assembly 中所有 component 统一赋予 Q355。
2. 在 `BatchMesher 自动网格划分` 中配置受支持的 HyperMesh 2019 或 2022 `hmbatch.exe` 及用户维护的 `.criteria` / `.param` 预设；hmbatch 可以与当前主会话版本不同，washer 行为完全由 `.param` 文件控制。
3. 检查 `config/seam_rules.txt`、`config/geometry_cleanup_rules.txt`、`config/contact_rules.txt`，确认焊缝面、几何清理和接触默认参数。

这些配置文件都是 `|` 分隔文本，模块面板中修改参数后，部分模块会把最新 UI 状态保存到 `config/*_state.txt`。

### 建立组件基础

抽中面前只需保证源组件名称保留 `Vxx_件号`，例如 `V01_BRACKET`；抽中面会根据名称和几何结果生成厚度字段。中面完成后，`读取 BOM 表` 模块当前会扫描 `MIDSURFED` Assembly 并统一设置 Q355，真实 BOM 文件读取将在后续版本实现。

几何导入后可先打开 `预处理` 面板：`转为车辆坐标系` 对当前显示组件依次执行绕全局 X 轴 +90°、绕全局 Z 轴 -90°；`清理无关部件` 可一次选择多个 component，并把各自同名本体及 `.数字` 重名组件去重后统一归入 `USELESS` Assembly 并隐藏；`移除骨架` 会对名称中包含 `SKELL`（不区分大小写）的组件执行相同归档。两项清理都会显示处理进度，且都不删除组件。

### 处理钣金件

钣金件建议按下面顺序执行：

1. `Midsurface Extraction`：选择钣金几何 component，抽取中面。
2. `读取 BOM 表`：扫描 `MIDSURFED` Assembly，当前统一设置 Q355 并补充组件名材料后缀。
3. `Geometry Cleanup: Chamfer/Recess`：对倒角、圆角、沉台等影响中面或网格质量的位置做连续清理。
4. `Seam Surface Creation`：在需要焊接的位置创建 `SEAM_Tx` 焊缝面。
5. `Sheet BatchMesh and Washer`：对中面或壳 component 执行 BatchMesh，并按孔径规则生成 washer。
6. `Shell Washer-Hole RBE2`：识别标准 washer 孔并创建 RBE2。
7. `RBE2 Bolt Connector`：将成组 RBE2 中心节点连接为 CBEAM/CBAR 螺栓段。
8. `Contact Setup`：分两次选择相向 Face 单元，创建 contact surface 和接触 group。
9. `Adhesive Connector`：以 elems 定义打胶 location、以 comps 定义连接目标，清洗越界单元后创建 Area adhesives。

典型输出包括：

```text
MIDSURFED assembly
SEAM_T2.0
AUTO_RBE2_<source>
BOLT_D12_CBEAM
AUTO_CONTACT_*
```

### 处理实体件和铸件

实体件和铸件的前置组织由后续重构模块负责；当前工具箱从已有的统一组件命名开始执行：

1. `Geometry Cleanup: Chamfer/Recess`：按需要清理小特征、倒角或沉台。
2. `Solid Through-Hole RBE2`：对实体网格圆柱贯通孔创建 RBE2。
3. `RBE2 Bolt Connector`：在上下层或多层 RBE2 中心节点之间生成螺栓连接。
4. `Contact Setup`：基于两次 Face 单元选择建立相向接触。

### 中断、返回和刷新

- 每个模块窗口都支持 `返回主页 / Back to Home`。
- 多数模块按 `Esc` 可关闭当前窗口；连续选择类模块在 HyperMesh 选择面板中按 `ESC` 退出连续模式。
- 如果脚本创建了 component 但左侧 Model Browser 未立即显示，可再次运行相关模块，模块结束后会自动刷新 Model Browser。
- 普通 Tcl 解释器只能做基础语法检查；所有 HyperMesh 命令必须在 HyperMesh 内运行。

## 仓库结构

```text
.
├── hw_toolkit.tcl           # 兼容启动入口
├── hw_toolkit_core.tcl      # 主界面、模块注册与加载
├── install_update.tcl       # 推荐安装/更新入口
├── config.yaml              # 语言、求解器、单位制与任务存储
├── config/                  # 可版本化的工程规则
├── modules/
│   ├── workflow_common.tcl  # 公共 UI 与 HyperMesh 平台服务
│   ├── hybrid_core/         # Tcl/Python 任务桥、协议和运行时
│   ├── batch_mesher/        # 后台网格任务与 worker 调度
│   ├── local_mesh_optimizer/# 局部网格分析、规划、报告
│   ├── *_connector/         # RBE2、螺栓、打胶与焊缝连接
│   └── */tests/             # 离线测试及 HyperMesh smoke test
├── python/hmworkflow/       # 共享 Python 包
├── examples/                # 可生成的验证模型与预期结果
├── doc/、docs/              # 架构、协议、迁移和验证记录
├── tools/                   # 测试、审计与实机验证工具
├── runtime/                 # 随包运行时；任务输出不进入版本控制
└── build_package.{ps1,sh}   # 跨平台白名单打包
```

## 全局配置

`config.yaml` 保存语言、工程上下文和任务存储策略。任何写模型操作开始前都会以这里的求解器与单位制作为安全边界：

```yaml
workflow:
  language: zh_CN
project:
  unit_system: mm_N_s_tonne
  solver_profile: OptiStruct
  units_confirmed: true
storage:
  scratch_dir: ""
  success_retention_days: 7
  failure_retention_days: 30
```

支持值：

`workflow.language` 支持 `zh_CN` 和 `en_US`。切换项目或单位体系时，必须同步更新 `project` 并重新确认 `units_confirmed`。`scratch_dir` 留空时，任务写入 `%LOCALAPPDATA%/HMWorkFlow/runtime`，成功与失败任务按独立策略保留。

`config/` 下的模块配置：

| 文件 | 用途 |
| --- | --- |
| `washer_rules.txt` | 孔径与 washer 规则。 |
| `seam_rules.txt` | Seam Surface Creation 默认参数。 |
| `geometry_cleanup_rules.txt` | Geometry Cleanup 默认参数。 |
| `contact_rules.txt` | Contact Setup 默认参数。 |
| `*_state.txt` | 模块 UI 状态缓存，由脚本自动生成。 |

## 命名约定

组件名称统一使用版本/件号/厚度格式，材料字段可由后续网格模块追加：

```text
V01_PARTNAME_T2.0_Q235
V02_PARTNAME_T1.2_AL6061
V03_PARTNAME_T1.5
SEAM_T2.0
```

命名规则：

- `Vxx` 为版本/车型前缀，`Name` 为件号或部件名称。
- 钣金厚度使用 `_T<value>`，例如 `_T2.0`。
- 材料后缀不是抽中面的必需字段；批量 Property 模块会从后续组件名称和 HyperMesh 材料实体中识别材料。
- HyperMesh 重复导入产生的 `.1`、`.2` 等后缀不会改变部件或材料归类。
- Midsurface Extraction 优先读取源组件名中的 `_Tx`，无法读取时会尝试从中面拓扑或体积/面积测量厚度。
- Midsurface Extraction 与 Mesh Seam Weld 共用厚度标记规则；中面输出中的 `_Tx` 可直接被网格焊缝读取并生成 `SEAM_Tx`。
- Seam Surface Creation 输出 `SEAM_Tx`，其中 `x` 优先取相邻组件名中较薄的厚度。

`Batch Property and Material Assignment` 位于主界面的 `Mesh / 网格` 页，扫描全部 component，并使用以下规则创建或复用 OptiStruct `PSHELL`：

```text
Vxx_..._Txx任意后缀_..._材料  ->  材料_Txx
包含 SEAM 且其后存在 Txx      ->  SEAM_Txx（材料固定为 Steel）
```

普通件只读取 `T` 后紧跟的数字作为厚度；存在材料字段时把最后一个下划线字段作为材料，例如 `V01_xxxx_T10_355` 生成 `355_T10`。没有材料字段的中面组件会留待后续材料识别或人工补充。

材料必须已由用户创建。模块会先调用 HyperMesh 原生的 `*EntityPreviewEmpty` 一次性识别空 component；这些 component 不再检查 Property、解析名称或进入人工复核。已经关联 Property 的 component，以及名称中包含 `BEAM`、`RBE`、`BUSH`、`SPRING`（不区分大小写）的 1D component 也会直接跳过。无法识别、找不到材料、Property 创建失败或赋予校验失败的非空 component 不会被移动；模块只会在 `PROPERTY_ASSIGNMENT_REVIEW` assembly 中创建名为 `PROPERTY_REVIEW__<原component名>` 的空 component collector，作为人工复核名称清单，不复制网格、节点或几何。

## 模块功能和用法

### Midsurface Extraction

入口：`::MidSurf::run`

功能：批量抽取钣金实体中面；同一源 component 中的多个不连续 solids 会逐实体抽取，生成的 surfaces 分别放入独立输出 component。仅当源 component 确实没有 solid 时才使用 surface 兼容回退。输出从 `V01_Name_Tx[_MATERIAL]` 开始版本化命名。

用法：

1. 在主面板运行 `Midsurface Extraction`。
2. 点击 `选择/重选组件`，选择需要抽中面的几何 component。
3. 检查抽取方法、阶梯对齐步数、中面位置、R/T 比等参数。
4. 点击 `开始抽取`。

输出：

- 生成新的 midsurface component。
- 单一面域首次命名为 `V01_Name_T<厚度>`；一个源 component 含多个离散面域时分别命名为 `V01_Name.1_T<厚度>`、`V01_Name.2_T<厚度>`……。同一面域的同名结果已存在时才递增为 `V02`、`V03`……，不覆盖既有中面。
- 输出 component 统一放入 `MIDSURFED` assembly。
- 源几何保留并隐藏。
- 厚度优先读取源 component 名称中的 `_Tx`；名称中没有厚度时，尝试读取中面拓扑点厚度，仍不可用时按实体体积/中面面积自动测量。

### Geometry Cleanup: Chamfer/Recess

入口：`::GeomCleanup::run`

功能：连续处理倒角、圆角和沉台补面等几何清理任务。

用法：

1. 在主面板运行 `Geometry Cleanup: Chamfer/Recess`。
2. 检查模式、圆角半径范围、缝合容差、邻接扩展层数等参数。
3. 点击 `进入连续清洗`。
4. 在 HyperMesh 选择面板中选择一个倒角面、圆角面或沉台底面，按中键执行。
5. 继续选择下一个面；取消选择时退出连续清洗。

输出：

- 对匹配的 solid 倒角/圆角执行清理。
- 对沉台识别内边、外边和基准边，按相邻壁面高度优先选择较短的小竖直面作为外边侧。
- 基准边只从小竖直面与基准平面共享的边收集；若该边被特征点分割，会收集这些分段，但不会扩展到基准平面的其他边界。
- 失败时撤销本次几何修改，不影响继续处理下一个区域。
- 清理完成后刷新 Model Browser 和图形窗口。

### 几何焊缝（Geometry Seam）

入口：`::SeamSurf::run`；主面板行尾“设置”入口为 `::SeamSurf::runSettings`。

功能：提供 12 个经过 HM2019/HW2022 双版本 hmbatch 验证的精确操作。创建类结果统一进入 `SEAM_T<厚度>_Surf`，需要连接的焊缝面会与两侧接触面执行拓扑等价检查；严格模式下游离曲面会回滚，不再把“命令未报错”当作成功。

用法：

1. 在主面板运行“几何焊缝”，按任务选择操作：
   - `T 曲面`：先选待延伸曲面组，再选目标曲面组。
   - `T 列表`：先选一条连续、无分支的源边线路径，再选一个或多个目标曲面；工具执行法向投影、切分、投影路径识别、ruled 曲面创建和两侧拓扑连接。
   - `搭接曲面` / `搭接边线`：创建 L 型搭接焊缝。
   - `连接边线`、`投影切分`、`延伸`、`合并`、`拆分`、`替换点`、`分布点`、`删除`：执行对应的几何编辑。
2. 连续创建类操作完成一次后可继续选择；在原生选择面板取消即可退出并回到结果面板。
3. 厚度优先读取 Property，其次读取 component 名称中的 `_Txx`；仍不可用时，除 T 曲面外会提示输入。也可用 `thickness_override` 固定本次规则厚度。
4. 通过主面板行尾“设置”调整参数并保存。距离/容差使用当前模型单位；本机双版本基线为：
   - 路径与质量：`endpoint_merge_tolerance`、`projected_path_merge_tolerance`、`projected_path_ambiguity_tolerance`、`min_seam_length`、`area_tolerance`、`volume_tolerance`。
   - 拓扑：`stitch_tolerance`、`cleanup_tolerance`、`topology_connection_required`。
   - T/搭接：`connect_extend_distance`、`connect_min_angle_to_target`、`connect_max_angle_edge_to_surf`、`connect_guide_angle`、`t_surface_trim_mode`、`geometry_offset_distance`、`lap_connect_distance`、`lap_result_envelope_tolerance`、`lap_boolean_opcode`。
   - 延伸/点编辑：`extend_offset_distance`、`extend_offset_type`、`extend_connect_trim_mode`、`extend_connect_distance`、`point_spacing`、`replace_point_projection_distance`。
   - 兼容/诊断：`internal_mark_slot`、`private_history_api`、`diagnostic_preserve_failed_geometry`。
5. 建议保留默认值开始调试；`extend_offset_type=2`、`extend_connect_trim_mode=1`、`internal_mark_slot=0`（自动回退到槽位 3）和 `replace_point_projection_distance=-1` 是本机 HM2019.0.0.70/HW2022.0.0.33 已验证组合。

输出与失败处理：

- 创建、编辑、删除均位于统一撤销事务中；失败默认恢复几何和显示状态。
- `T 列表` 会从切分后的完整边界图中提取与源路径最匹配的投影路径，拒绝等分歧义，并检查最终焊缝边是否同时属于源面和目标面。
- `合并` 在输入已经等价时返回明确的 no-op 警告；`删除` 返回被删除曲面清单；`分布点` 返回真实新建点 ID。
- 诊断保留几何和放宽拓扑门禁只用于定位问题，不是推荐生产设置。

### BatchMesher 自动网格划分

入口：`::BatchMesher::runAction`

功能：支持 HyperMesh 2019 与实机验证的 HyperWorks 2022。以 Surface ID 为执行数据，使用 `by attached` 提取最终拓扑连通域，并启动相互隔离、数量可控的并行 hmbatch。2022 外部 worker 会加载 OptiStruct profile 和 criteria；版本探测覆盖 `19`、`19.x`、`2019.x` 和实机返回的 `22.000000`。

用法：

1. 在主面板运行 `BatchMesher 自动网格划分`。
2. 配置并保存 criteria/param 预设以及任一受支持的 2019/2022 `hmbatch.exe`，并执行测试启动；不要求与当前会话版本一致。
3. 手动选择、选择当前显示或选择全部 surfaces。
4. 点击 `分析几何连通性`，复核连通域、涉及 component 和诊断提示。
5. 设置并行进程数后点击“启动后台划分”；每个活动连通域对应一个独立 hmbatch 和真实 PID，主 HyperMesh 与进度窗口保持响应。调度采用固定容量滑动窗口，任一任务结束就立即补充下一个任务，不等待同批全部结束。整次运行只打开一个汇总 CMD 窗口，显示目标/活动 worker 数、等待队列、阶段、PID 和任务统计；结束后三秒自动关闭。
6. 后台结束后，2019/2022 均在空白 hmbatch 中聚合各 worker 的有效 FEM，自动偏移冲突 ID，保存干净的合并 HM 并统一导出最终 FEM，再一次性自动导入当前模型；完成提示会报告新增单元。失败时可点击“手动重试完整结果导入”，网格失败任务仍可单独后台重试。

输出：

- 每个不可拆分的 Surface 拓扑连通域对应一个任务；单一连通域自动整体执行。
- 每个任务记录状态、耗时、Surface IDs、Component 名称、原始 Tcl 错误和独立日志；失败默认不阻止后续任务。
- `*hm_batchmesh2` 后只要新增了 Elements，任务就视为有可用结果；质量或迭代问题作为警告保留，不会删除网格。成功任务保存原生 HM 作为恢复文件，并按结果 Component 使用 `*feoutputwithdata` 输出包含完整 Elements/依赖的 FE-only FEM。合并 worker 在空白模型中用默认 OptiStruct reader 和 `overwrite_flag=0` 逐个导入 FEM、验证 Element 增量，再保存 `merged_result.hm` 和导出 `batchmesh_result.fem`。主会话优先导入完整原生 FE，跨版本不兼容时回退到唯一的最终合并 FEM。网格状态与结果封装状态相互独立。
- 报告位于共享任务存储的 `batch_mesher/<run-id>/`，包含汇总状态、`monitor_batchmesher.cmd`、`monitor_status.txt`、各 worker 的 `launch.log`、必要时生成的 `manager_failure.log`、stdout/stderr、`run.json`、`result.json` 和逐任务日志。即使 Altair launcher 没有输出，管理端日志也会记录实际命令、独立工作目录、PID 和启动握手超时诊断。关闭汇总监视窗口不会终止后台任务。

### Shell Washer-Hole RBE2

入口：`::RB2W::run`

功能：识别壳单元标准 washer 孔，并在孔中心创建 RBE2。

用法：

1. 在主面板运行 `Shell Washer-Hole RBE2`。
2. 点击 `选择/重选组件`，选择已经带有标准 washer 网格的壳 component。
3. 检查孔径范围、圆度/椭圆容差、washer 节点圈数和 RBE2 自由度。
4. 选择执行模式：
   - `开始创建 RBE2`：只对未创建过 RBE2 的孔创建。
   - `重建模式`：先删除已有输出 component，再重新创建。
   - `合并重复节点`：清理输出 component 中重复 RBE2 的中心节点和重复单元。
5. 点击对应按钮执行。

输出：

- 每个源 component 对应一个 `AUTO_RBE2_<source>` 输出 component。
- RBE2 只移动到输出 component，不移动源节点。
- 模块会检查已有 RBE2，避免重复创建。

### Solid Through-Hole RBE2

入口：`::AutoHoleRBE2::run`

功能：识别实体网格中的圆柱贯通孔，并创建中心节点和 RBE2。

用法：

1. 在主面板运行 `Solid Through-Hole RBE2`。
2. 点击 `选择/重选组件`，选择实体网格 component。
3. 检查光顺面片角度、圆柱拟合容差、端部环容差和孔半径范围。
   默认启用内壁法向检查，以排除实体外圆柱面；仅在旧模型自由面法向不可靠时临时关闭。
4. 设置结果 component 名称。
5. 点击开始执行。

输出：

- 生成临时自由面 component，用于识别孔壁面片。
- 对有效贯通孔创建中心节点和 RBE2。
- 输出到指定结果 component。
- 运行结束后可自动删除临时自由面 component。

### RBE2 Bolt Connector

入口：`::RB2Bolt::run`

功能：读取 RBE2 中心节点，沿 X/Y/Z 方向分组，并在相邻中心节点之间创建 CBEAM 或 CBAR 螺栓连接段。

用法：

1. 在主面板运行 `RBE2 Bolt Connector`。
2. 选择 RBE2 来源：
   - `elements`：直接选择 RBE2 单元。
   - `components`：选择包含 RBE2 的 component。
3. 设置搜索轴向、最大轴向连接距离、横向中心偏移容差和最小分组数量。
4. 选择输出类型 `CBEAM` 或 `CBAR`。
5. `1D 属性名称` 留空时，工具会按孔径自动创建/复用 `PBEAM`/`PBAR` 属性和默认 `MAT1` 材料；填写时使用指定属性。
6. 可先勾选预览模式检查分组，再取消预览创建连接段。
7. 点击确定执行。

输出：

- 对符合条件的 RBE2 中心节点分组。
- 沿识别轴向连接相邻 RBE2，CBEAM/CBAR 端点会强制使用 RBE2 中心节点 ID，避免同坐标重复节点造成 free 1D。
- 输出 component 按孔径和单元类型命名，例如 `BOLT_D12_CBEAM`。
- 输出属性按孔径和属性卡命名，例如 `BOLT_D12_PBEAM`，避免 CBEAM/CBAR 只有几何线而没有求解刚度。
- 只组织新建的一维连接单元，不移动源节点。

### CBUSH Creator

入口：`::CBushCreator::runAction`

功能：选择一个或多个已有节点，分别在相同 X/Y、全局 Z 坐标增加 5 的位置创建临时节点，并使用 `Spring config 21 / CBUSH type 6` 连接每组节点。

用法：

1. 在主面板运行 `创建 CBUSH`。
2. 在原生节点选择器中选择一个或多个源节点并点击中键确认。
3. 工具逐个创建临时节点和 CBUSH；某个节点失败时会继续处理其余节点，并在结果中列出失败原因。

输出：

- 临时节点坐标为 `(源 X, 源 Y, 源 Z + 5)`。
- CBUSH 输出 component 命名为 `CBUSH_<源节点所属 component 名称>`。
- 同一 source component 中的多个节点逐次执行时，会复用同一个 CBUSH 输出 component，不会创建带序号的重复 component。
- 如果没有可识别的源 component，或源节点同时归属多个 component，工具会停止并提示，不会猜测名称。
- 如果 CBUSH 创建失败，工具会删除本次新建的临时节点。

### 批量添加临时节点

入口：`::BatchTempNodes::runAction`

功能：在多行文本框中按每行 `X,Y,Z` 输入坐标，并在当前 component 中一次性创建对应节点。空行会被忽略，支持小数、负数、科学计数法以及中文逗号。

- 创建前会校验全部行并标出错误行号；存在任意格式错误时不会修改模型。
- 创建过程中任一节点失败，会删除本批次已创建的节点。
- “撤销上一批”可删除当前会话中最近一次成功创建的整批节点。
- `Ctrl+Enter` 可直接执行创建。

### 载荷批量施加

入口：`::BatchLoadApplication::runAction`

功能：作为“批量添加临时节点”旁边的独立模块，选择多个 TXT 后汇总所有工况使用的点位，逐行展示英文名、中文名、完成状态、详情和定位操作。

- “选择 TXT 文件”只建立待处理文件列表，不会立即读取；确认列表后点击“开始解析”，解析期间显示文件和记录进度。
- 每个点位提供“删除”按钮，可从当前解析结果中删除该点及全部工况载荷，并同步移除 CSV 映射；不会删除模型节点或恢复其 Node ID，重新解析文件可恢复数据。
- “清除当前列表”会清空待处理文件、点位、载荷记录和映射，但不删除模型中的节点或已经创建的工况实体。
- “工况名称映射”按顺序对 case 中文说明做关键词包含匹配，并可在模块内添加、修改、删除、调整优先级或恢复默认。内置“左转弯/左转 → left_turn”和“加速 → acceleration”；自定义列表持久化到 `%APPDATA%/HMWorkFlow/batch_load_case_name_mappings.txt`。
- “创建所有工况”只使用已完成点位：Load Collector 和 Subcase 共用带编号的英文名（例如 `case14_left_turn`），未命中映射时回退为 `case14`。在映射 Node 上分别创建 `FX/FY/FZ` Force 和 `TX/TY/TZ` Moment，再创建同名线性静力 Subcase 并绑定该 Load Collector。未完成点位会跳过；模型中存在同名 Load Collector/Subcase 时整批停止，避免覆盖。
- 解析前忽略空行、整行只有逗号的转换噪声以及首个工况前的不相关内容；以行首 `case数字` 作为工况边界，直到下一个 `case数字` 出现。
- 表头文字和列位置不参与判断。每条数据从行尾反向读取固定的 13 列：`X Y Z 英文名 中文名 序号 时间 FX FY FZ TX TY TZ`，自动容忍首条记录中的 case/分组字段及后续记录中的前导空列。
- 详情列出该点被哪些工况引用，以及各工况的 `FX/FY/FZ/TX/TY/TZ`。
- “Node ID 重排”把模型中的全部节点从指定正整数开始连续重排，并清空本模块中已失效的映射。
- “定位”先在文件坐标创建临时节点，再打开原生 Node 选择器。用户确认一个模型节点后，节点按完成顺序从 `1001` 开始编号，点位状态更新为已完成。
- 每次完成映射都会更新 `%APPDATA%/HMWorkFlow/runtime/batch_load_application/node_mapping.csv`；“保存映射”可另存包含中英文名和 Node ID 的 CSV。

### Adhesive Connector

入口：`::AdhesiveConnector::runAction`

功能：按 HyperMesh `1D Connector > Area` 流程创建并实现 `adhesives`。第一次选择器选择 `elems` 作为 location，第二次选择器选择至少两个 `comps` 作为 links；固定使用 `no/skip post script`。

用法：

1. 在主面板运行 `模型打胶 / Adhesive Connector`。
2. 点击 `选择 elems + comps`，先选择打胶区域壳单元并中键确认，再选择需要连接的组件并确认。
3. 设置 `Tolerance`（默认 `50`）、`Coats`（默认 `1`）和 `Const thickness`（默认 `1`）。厚度类型固定为 `const_thickness`。
4. 点击 `创建打胶`。模块先清洗 location elems，再调用 OptiStruct Area/adhesives realization。

清洗规则：

- 使用 HyperMesh 原生多线程投影搜索检查 location elem 的全部节点，不再把目标组件完整网格读入 Tcl。
- 全部节点必须在 tolerance 内投影到每个非自身目标 component；任一节点失败时，整个 location elem 会被剔除，不会传给 connector 命令。
- 原生投影直接以目标 component 的 shell/solid faces 为目标，与 connector 的投影规则保持一致。

模块会从当前 HyperMesh `feconfig.cfg` 动态解析 OptiStruct 的精确 `adhesives` 类型 ID，创建后回读 connector state；未生成连接或存在非 `REALIZED` 连接时会报错。首次投产前仍需在目标 HM2019 环境完成一次 smoke test。

### Contact Setup

入口：`::ContactSetup::run`

功能：调用 HyperMesh 原生 Face 单元选择器，连续分两次选择候选区域，筛选两侧空间公共部分后创建相向 contact surface 和 OptiStruct `CONTACT` group，并支持按单元修剪多余接触。创建过程不再遍历整个 component。

用法：

1. 在主面板运行 `Contact Setup`。
2. 点击 `分两次选择 Face`，先选择 A 侧 Face 单元并中键确认，再选择相向的 B 侧 Face 单元。
3. 选择接触类型：`SLIDE`、`STICK` 或 `FREEZE`；默认值为 `STICK`。
4. 设置主面：
   - `AUTO`：按 contact surface 单元数量自动选择较大侧。
   - `FIRST`：第一次选择的 Face 作为主面。
   - `SECOND`：第二次选择的 Face 作为主面。
5. 设置结果名前缀和是否创建 contact group。
6. 点击 `创建接触`。
7. 如需删除多余接触，点击 `修改接触`，连续选择需要从 contact surface 中移除的单元后中键确认。
8. 修改完成后点击 `恢复视图`。

输出：

- 对两次选中的 Face 候选集进行双向邻近筛选，仅保留空间公共覆盖区域。
- 分别创建 `contactsurfs`。
- 创建 OptiStruct `CONTACT` group，以 contact surface 定义主/从侧，写入 `TYPE=SLIDE/STICK/FREEZE` 后回读校验。
- contact surface 创建时直接写入计算所得 `reverse_normals`；节点和坐标通过 mark 批量读取，不扫描整个 component。
- 修改模式只会从当前 contact surface 中移除所选单元，不删除源 component 原始网格。

### Solid Seam Connector

入口：`::SolidSeam::run`

功能：通过子面板设置并批量创建 `PENTA6 + RBE3` 实体焊缝，结果归入 `SEAM_SOLID`。

**AutoGroup**：点击“开始”后一次选择所有待处理 comps，自动识别配对及源/目标方向，再按 Auto 参数批量创建。支持一个组件连接多个邻接组件；显示进度条和滚动命令流，结束后保留窗口及完整日志。以下两次选择流程适用于其他三种模式。

1. 选择 `nodes+comps`、`comps+comps` 或 `Auto`。手动模式设置 T/B/L、spacing、tolerance、width 和创建侧；Auto 自动推导类型、数值参数及创建侧；侧向不明确时回退到用户设置，显式双侧保持不变。
2. 点击“开始”后两两一组收集。`nodes+comps` 默认使用原生 node path，支持多个有序节点或一个闭环种子点，然后选择目标 comp，源 comp 自动确定；其他模式依次选择源 comp 和目标 comp。
3. 完整组先缓存。第一步空选提交全部缓存；第二步空选仅取消当前未完成组。提交前不创建焊缝。
4. 先计算所有组的路径及参数，再逐组创建；各组源/目标保持选择顺序，失败不阻断后续组。执行后恢复子面板并显示结果。
5. 各组结果写入 HybridCore 任务目录下的 `realization_result.json` 与 `operation.log`。默认位于 `%LOCALAPPDATA%/HMWorkFlow/runtime/tasks/solid_seam/`，也支持配置的运行目录。

单点闭环、Auto 几何判定和验证说明见 [实体焊缝模块说明](modules/solid_seam/README.md)。Auto 根据局部网格尺度推导参数；手动输入按显式数值执行，复杂几何仍需复核结果。

双版本实机验证（2019.0.0.70 / 2022.0.0.33）见 `docs/solid_seam_dual_version_alignment_2026-08-08.md`。

### 网格焊缝完整性检查

入口：`::WeldIntegrityCheck::runAction`

用途：在主要网格和连接完成后，识别可能存在遗漏焊缝的 Shell Component Pair，并提供逐组孤立、局部高亮和人工完成确认。模块不自动建焊缝，也不修改现有网格。

参数：

- `最大搜索距离`：自由边节点与另一组件节点进入候选的最大距离，单位跟随当前模型。
- `最小有效接近长度`：连续候选自由边链的最短累计长度。
- `最小连续节点数`：过滤单角点和少量零散近邻。
- `优先检测 Shell 自由边`：首版算法以壳自由边为候选源。
- `忽略已直接共节点连接的组件对`：共享节点达到连续节点阈值时跳过该 Pair。

操作：选择至少两个待检查组件，可另选排除组件；检测后在 Pair 列表中按名称或 ID 筛选。`孤立` 会只显示当前两个组件并高亮当前候选区域；区域按钮可逐个定位。`完成` 将结果标记为 `completed` 并从待检查列表隐藏，切换到 `completed` 可重新打开。`恢复进入模块前显示` 会恢复模块启动时的可见组件集合，而不是简单显示全部。

结果保存在 `runtime/tasks/weld_integrity_check/<run_id>/`：检查范围由 HyperMesh 原生导出为 `input/selected_components.fem`，轻量 Component/Element 归属保存在 `input/mesh_manifest.json`；FEM 拓扑解析、自由边提取和候选检测均由 Python 完成。JSON 与 Python 日志位于 `output/`，审查进度位于 `state/review_state.json`。关闭报告会自动清理 mark/编号并恢复显示；同一 HyperMesh 会话再次进入模块可继续上次审查。

当前限制：完整性检查本身只支持 Shell–Shell 和人工审查；距离搜索是自由边节点到目标网格节点的近似，不读取 CAD。审查页的“创建焊缝”会显式转入下述自动壳焊缝流程，仍需工程人员再次确认后才修改模型。

### 自动壳焊缝与快速创建

`Mesh Seam Weld` 新增 `FAST_AUTO`，与原 `LEGACY_MANUAL` 手动路径并存。自动模式原生导出所选 Shell Component，由便携式 Python 识别并分类 `T_PATH/T_LIST/CONNECT/L_SURF/L_LIST/REVIEW`，用户明确接受后才生成创建计划。自动规划优先复用已有连续目标网格边，也可在显式开启后执行受控节点微调，或对单个 CTRIA3/CQUAD4 母单元执行保守局部切分；快速路径不调用 imprint、ruled surface、automesh 或 connector。

应用前会写入任务安全快照，每个候选还会建立独立检查点；导入后复核新增 ID、connectivity 和相对原始基线新增的 HyperMesh 质量失败，单个候选失败只回滚该候选。结果位于 `runtime/tasks/mesh_seam_weld/<run_id>/output/`，包含 candidate、creation plan、候选独立增量 FEM、manifest、规划 JSON/HTML 报告及执行报告。焊缝 Property 无法可靠复用时会明确标记 `property_assignment_required`，可随后使用批量 Property 模块。受控节点微调和保守单母单元局部切分均已实现但默认关闭；模块状态为 `controlled`，仍需按 [协议与 HM2019 清单](doc/mesh_seam_auto_protocol.md) 完成真实 HyperMesh 验证。

### FEM 自动焊缝（独立模块）

`FEM Automatic Seam` 与 `Mesh Seam Weld` 是两个独立工具。前者用于几何清理、抽中面和孤立 BatchMesher 完成之后，从多个互不共节点的壳 Component 中检测 T 型、贴片型和邻近自由边候选，并在 FEM 层面切分母单元、插入节点和创建焊缝壳；后者继续处理用户已经明确选择的网格焊缝路径。

该模块使用独立配置与任务目录。检测前固定生成独立的 `before.hm` 备份（唯一的回滚/撤销恢复点），随后把完整模型导出为 `input/model.fem`；整车规模检测按源 Component 多进程并行，但候选始终限制在用户选择的 Component 内。创建规划只复制一次所选模型，在同一累积模型中顺序处理候选，并把修改后的完整模型直接写回 FEM 文件；HyperMesh 以 File > Open 语义重新打开该文件替换当前模型（不再做任何增量导入/合并，非壳卡片原样保留）。替换后以 replacement mother elements 为种子向外扩展，将焊缝路径、新增切分节点及每批重绘区域外围节点设为固定节点，并按连通区域和单批单元上限在新模型上分批执行 element automesh。完成后导出 `result.fem` 并删除过程文件，因此成功任务目录严格只保留 `before.hm` 和 `result.fem`。可直接导入的十组验收模型位于 `examples/AutoShellSeamBackend/test_fem/`。

`Criteria file` 可留空，此时使用 `modules/fem_auto_seam/defaults/` 中的内置 HM2019 质量标准。Python 并行进程数设为 `0` 时自动使用最多 8 个进程，也可按工作站核心数显式提高；Windows 子进程通过无控制台的 `pythonw.exe` 启动，实际进程数和持续时间显示在现有进度窗口的命令流中。重绘单元尺寸、邻域扩展层数、特征角和单批重绘单元上限由模块设置直接控制。

检测、后台规划、FEM 替换、原生 automesh、质量检查和完成态导出均显示进度。高置信度 T 型/贴片型候选直接创建；其余候选以及规划失败项在完成后进入待处理表。选择条目会隔离并适配源/目标 Component 视角，也可直接调用现有 `Mesh Seam Weld` 继续手工创建。

该模块使用独立配置 `fem_auto_seam` 和独立任务目录 `runtime/tasks/fem_auto_seam/`。设置页可单独配置搜索距离、置信度、小孔阈值、`.criteria`、Python 并行进程数、重绘尺寸、扩展层数、特征角和单批重绘上限。Python 不再移动节点或优化网格；HyperMesh 使用实机录制的 `*interactiveremeshelems`、`*automesh` 和 `*storemeshtodatabase 1` 流程分批重绘，并以原生 criteria 进行最终质量裁决。执行过程不建立候选 checkpoint，也不在 HyperMesh 内做任何增量导入；只有模型已经进入替换/重绘阶段且发生错误时，才使用任务级 `before.hm` 恢复一次整个批次。

## 公共机制

`modules/workflow_common.tcl` 提供跨模块共享能力：

- 全局语言配置读取。
- 项目级窗口置顶开关、状态持久化，以及对当前和后续项目窗口的统一应用。
- HyperMesh 材料实体名称匹配和重复后缀归一化。
- component 命名、重命名和装配组织。
- Model Browser 创建、同步和刷新。
- 进度窗口、取消状态和日志。
- 模块 UI 状态保存与读取。

脚本创建 component 后会尽量通过 HyperMesh 2019 的 Browser API 同步登记；内部 Browser API 不可用时回退到普通 `*createentity`。如果 Browser 未立即更新，重新运行相关模块即可触发自动刷新。

## 开发和验证

运行完整离线测试：

```powershell
python tools/run_offline_tests.py
```

构建与 CI 使用相同边界的发布包：

```powershell
.\build_package.ps1
```

普通 Tcl 解释器只能用于基础语法检查，无法验证 HyperMesh 命令行为。修改写模型模块后，还应在目标 HyperMesh 版本中验证窗口打开、实体选择、结果 collector、连接关系、Model Browser 刷新以及撤销/恢复路径；`controlled` 模块需完成状态文件声明的额外验证。

进一步阅读：

- [文档索引](doc/README.md)：安装、使用及模块说明。
- [Python/Tcl Bridge Protocol](doc/python_tcl_bridge_protocol.md)：跨运行时通信和错误语义。
- [Local Mesh Optimizer Architecture](doc/local_mesh_optimizer_batch_architecture.md)：区域规划与批处理架构。
- [Mesh Seam Auto Protocol](doc/mesh_seam_auto_protocol.md)：自动壳焊缝候选、执行和校验协议。
- [Platform Services Migration](doc/migration_platform_services.md)：工程上下文、任务存储和平台服务。
- [Repository Layout](doc/repository_layout.md)：版本控制边界与发布白名单。
