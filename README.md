# HMWorkFlow — HyperMesh 前处理工作流工具箱

HMWorkFlow 是以 HyperMesh 2019 为已验证基线、逐步兼容 HyperWorks 2022 新界面的 Tcl/Tk + Python 前处理工具集。它把车身和结构件分析中分散、重复且容易出错的操作组织到同一个入口，覆盖从几何准备、网格生成与质量优化，到连接创建和焊缝完整性复核的主要流程。

## 功能概览

| 工作阶段 | 主要功能 | 解决的问题 |
| --- | --- | --- |
| 几何准备 | 组件分类与命名、材料标识、中面抽取、倒角/圆角/沉台清理、几何焊缝 | 统一模型结构和命名，减少逐件整理、手动抽中面和重复补面的工作量。 |
| 网格处理 | 钣金 BatchMesh 与 washer、铸件 TetraMesh、网格焊缝、批量 Property、局部网格优化 | 将网格生成、属性赋予和局部质量修复串成可配置流程，只处理需要修改的区域。 |
| 连接创建 | 壳孔/实体孔 RIGIDS、CBEAM/CBAR 螺栓、CBUSH、接触、打胶、实体焊缝 | 自动识别连接位置和几何关系，批量生成可用于 OptiStruct 的连接实体。 |
| 质量复核 | 重复连接检查、结果回读校验、网格焊缝完整性检查、候选逐项审查 | 在修改模型前后保留明确的确认与校验环节，降低漏焊、重复创建和错误连接风险。 |

典型工作流是：整理组件与材料 → 抽取/清理几何 → 生成并优化网格 → 创建孔连接、螺栓、焊缝、接触或打胶 → 执行完整性复核。各模块也可独立运行，不要求必须走完整流程。

## 相较 HyperMesh 原生手动操作的提升

这里的“原版”指直接使用 HyperMesh 原生面板完成选择、识别、创建、命名、归类和检查。工具箱仍调用 HyperMesh 原生命令完成实际建模，但把原本需要工程师逐孔、逐单元、逐组件或逐连接重复执行的操作，改为“一次选择、批量识别、自动创建、统一校验”。

| 工作内容 | HyperMesh 原生手动操作 | HMWorkFlow 自动化方式 | 主要效率提升 |
| --- | --- | --- | --- |
| 组件命名、材料与 Property | 逐个判断组件类型、修改名称、查找材料、创建或选择 Property，再逐个赋予。 | 扫描全部组件，从名称解析类型、厚度和材料，批量创建/复用 PSHELL；异常项单独生成复核清单。 | 人工工作量由“逐组件处理”降为“一次执行 + 只检查异常项”。 |
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

- **一致性**：统一命名、材料库、Property 规则、输出 collector、配置文件和 OptiStruct 工程上下文，减少不同操作者之间的结果差异。
- **安全性**：增加求解器/单位制预检、重复项检测、候选预览、结果回读、失败隔离、任务快照和局部回滚。
- **可追溯性**：保留任务目录、日志、候选结果和人工审查状态，便于复核问题来源。
- **使用体验**：提供中英文界面、快捷键、进度/取消、窗口切换、Model Browser 刷新和用户状态保存。

自动化的目标是减少机械操作，不替代工程判断。`Solid Seam Connector`、`Geometry Seam`、`Adhesive Connector` 等受控功能仍要求在目标 HyperMesh 环境完成命令 profile 或 smoke test；焊缝完整性检查只提供候选，不会自动修复模型。各模块的状态和限制以 [模块状态](modules/module_status.json) 及后文说明为准。

## 运行前说明

执行任何会修改模型的入口前，请先确认 `config.yaml` 中的求解器、单位制及 `units_confirmed` 与当前项目一致。平台工程上下文、用户数据目录、任务清理策略和验证方法见 [平台服务迁移说明](doc/migration_platform_services.md)。

快捷键的首次安装、更新和恢复流程见 [快捷键安装与更新](doc/shortcut_installation.md)。请优先运行 `install_update.tcl`；`hw_toolkit.tcl` 保留为兼容入口。仓库目录边界、Git 跟踪规则和发布白名单见 [仓库目录与发布规则](doc/repository_layout.md)。本机解压的 `runtime/python/windows-x64/python38/` 只用于运行，不进入 Git 或发布 ZIP。

局部网格优化模块的集成状态、使用步骤、HM2019 运行验证和已知限制见 [README_LocalMeshOptimizer.md](doc/README_LocalMeshOptimizer.md)。该模块坚持以 HyperMesh criteria 和原生质量结果为最终判定，并保留运行时错误处理、任务快照、复检和回滚。

默认界面语言为中文。需要英文界面时，将项目根目录 `config.yaml` 中的 `workflow.language` 改为 `en_US`。

界面基础设施已统一迁移到 `hwtk`。主面板、所有模块顶层窗口和公共进度窗口通过 `modules/workflow_common.tcl` 中的统一适配层创建；在非 HyperWorks Tcl 环境中会自动回退到 Tk/ttk。2019 与 2022 的启动链和模块加载器都会显式按 UTF-8 读取仓库脚本，避免 2022 新界面进程按 Windows ANSI 代码页读取中文而产生乱码。

窗口不再使用永久 `-topmost`。调用 HyperMesh 原生实体选择面板时，只临时隐藏由工具箱登记的窗口，不影响同一 HyperMesh 进程中的其他 Tcl 窗口。HyperWorks 2022 若无法创建 panel mark，会自动改用新版选择条对应的 edit widget；原生 FEM 导入/导出则统一防重入并自动处理被遮挡的 translator 确认提示。

## 1. 快速启动

在 HyperMesh 中运行：

```text
File > Run > Tcl/Tk Script > hw_toolkit.tcl
```

运行后会打开 `HyperMesh Toolkit` 主面板。模块归类为三部分显示：

```text
Geometry
Mesh
Connection
```

主面板中的 `刷新浏览器` 用于恢复 Model Browser 更新并刷新图形窗口，不会改变已有 component 的显示/隐藏状态。

主面板底部的 `快捷键管理 / Shortcuts` 用于统一管理可见模块快捷键。每个模块行右侧会显示当前快捷键；未设置时显示 `未绑定 / Unbound`。点击该区域会打开快捷键管理器并选中对应模块。

快捷键会直接调用模块的 `proc` 执行入口，不会打开 HMWorkFlow 主界面，也不会打开模块的 `more` 配置界面。

快捷键采用抢占式窗口切换：按下主面板或模块快捷键时，工具会先保存当前面板状态并销毁本项目已经打开的窗口，待旧窗口的 `tkwait` 调用退出后再创建目标窗口。因此窗口即使位于 HyperMesh 后台，也不需要手动关闭。公共进度任务仍在执行时不会强制销毁任务窗口，以避免中断模型修改；应先等待任务完成或请求取消。

### 1.1 快捷键持久化

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

### 1.2 标准 ZIP 打包

需要分发完整工具目录（含安装入口和帮助页）时，在项目根目录运行：

```powershell
.\build_package.ps1
```

或在 Linux/macOS 环境运行 `./build_package.sh`。生成的 ZIP 包含
`install_update.tcl`、`guide.html`、模块、配置和文档。

## 2. 推荐工作流

### 2.1 准备项目配置

1. 检查 `config/materials.txt`，确认材料 key、显示名和材料参数符合当前项目。
2. 在 `BatchMesher 自动网格划分` 中配置 HyperMesh 2019 `hmbatch.exe` 及用户维护的 `.criteria` / `.param` 预设；washer 行为完全由 `.param` 文件控制。
3. 检查 `config/casting_mesh_rules.txt`，确认铸件三角面网格、质量迭代和 TetraMesh 参数。
4. 检查 `config/seam_rules.txt`、`config/geometry_cleanup_rules.txt`、`config/contact_rules.txt`，确认焊缝面、几何清理和接触默认参数。

这些配置文件都是 `|` 分隔文本，模块面板中修改参数后，部分模块会把最新 UI 状态保存到 `config/*_state.txt`。

### 2.2 建立组件命名和材料基础

先在 `Organize` 中完成模型基础整理：

1. 运行 `Component Classification`。
2. 选择 `SHELL`、`SOLID` 或 `CASTING`，再选择对应 component。
3. 点击 `应用类型`，组件会被重命名为 `CATEGORY_NAME`，例如 `SHELL_BRACKET`。
4. 运行 `Material Assignment`。
5. 从材料库选择材料 key，选择已分类 component。
6. 点击 `应用材料标识`，组件会被重命名为 `CATEGORY_NAME_MATERIAL` 或保留已有厚度信息，例如 `SHELL_BRACKET_T2.0_Q235`。

建议所有后续模块都基于这套命名继续处理，因为中面厚度、焊缝面厚度、washer 和连接输出都会读取或延续这些信息。

### 2.3 处理钣金件

钣金件建议按下面顺序执行：

1. `Midsurface Extraction`：选择钣金几何 component，抽取中面。
2. `Geometry Cleanup: Chamfer/Recess`：对倒角、圆角、沉台等影响中面或网格质量的位置做连续清理。
3. `Seam Surface Creation`：在需要焊接的位置创建 `SEAM_Tx` 焊缝面。
4. `Sheet BatchMesh and Washer`：对中面或壳 component 执行 BatchMesh，并按孔径规则生成 washer。
5. `Shell Washer-Hole RBE2`：识别标准 washer 孔并创建 RBE2。
6. `RBE2 Bolt Connector`：将成组 RBE2 中心节点连接为 CBEAM/CBAR 螺栓段。
7. `Contact Setup`：分两次选择相向 Face 单元，创建 contact surface 和接触 group。
8. `Adhesive Connector`：以 elems 定义打胶 location、以 comps 定义连接目标，清洗越界单元后创建 Area adhesives。

典型输出包括：

```text
midsurf assembly
SEAM_T2.0
AUTO_RBE2_<source>
BOLT_D12_CBEAM
AUTO_CONTACT_*
```

### 2.4 处理实体件和铸件

实体件和铸件建议按下面顺序执行：

1. `Component Classification`：将 component 标记为 `SOLID` 或 `CASTING`。
2. `Material Assignment`：追加材料 key。
3. `Geometry Cleanup: Chamfer/Recess`：按需要清理小特征、倒角或沉台。
4. `Casting TetraMesh`：对铸件执行 surface 清理、三角面网格质量迭代和 TetraMesh。
5. `Solid Through-Hole RBE2`：对实体网格圆柱贯通孔创建 RBE2。
6. `RBE2 Bolt Connector`：在上下层或多层 RBE2 中心节点之间生成螺栓连接。
7. `Contact Setup`：基于两次 Face 单元选择建立相向接触。

### 2.5 中断、返回和刷新

- 每个模块窗口都支持 `返回主页 / Back to Home`。
- 多数模块按 `Esc` 可关闭当前窗口；连续选择类模块在 HyperMesh 选择面板中按 `ESC` 退出连续模式。
- 如果脚本创建了 component 但左侧 Model Browser 未立即显示，点击主面板 `刷新浏览器`。
- 普通 Tcl 解释器只能做基础语法检查；所有 HyperMesh 命令必须在 HyperMesh 内运行。

## 3. 目录结构

```text
.
|-- hw_toolkit.tcl
|-- hw_toolkit_core.tcl
|-- shortcut_bootstrap.tcl
|-- config.yaml
|-- config/
|   |-- materials.txt
|   |-- washer_rules.txt
|   |-- seam_rules.txt
|   |-- geometry_cleanup_rules.txt
|   |-- casting_mesh_rules.txt
|   `-- contact_rules.txt
`-- modules/
    |-- workflow_common.tcl
    |-- shortcut_manager.tcl
    |-- component_workflow.tcl
    |-- midsurf.tcl
    |-- geometry_cleanup.tcl
    |-- seam_surface.tcl
    |-- batch_mesher.tcl
    |-- batch_mesher/
    |-- casting_tetramesh.tcl
    |-- batch_property_assignment.tcl
    |-- local_mesh_optimizer.tcl
    |-- local_mesh_optimizer/
    |   |-- python/
    |   `-- tests/
    |-- auto_hole_rbe2.tcl
    |-- shell_washer_hole_rbe2.tcl
    |-- rbe2_bolt_connector.tcl
    |-- cbush_creator.tcl
    |-- contact_setup.tcl
    |-- adhesive_connector.tcl
    |-- solid_seam_connector.tcl
    `-- solid_seam/
        |-- tcl/
        |-- python/
        |-- config/
        |-- command_profiles/
        `-- tests/
```

## 4. 全局配置

`config.yaml` 保存主配置：

```yaml
workflow:
  language: zh_CN
```

支持值：

| 值 | 说明 |
| --- | --- |
| `zh_CN` | 简体中文界面。 |
| `en_US` | 英文界面。 |

`config/` 下的模块配置：

| 文件 | 用途 |
| --- | --- |
| `materials.txt` | 材料标识库，供 Material Assignment 读取。 |
| `washer_rules.txt` | 孔径与 washer 规则。 |
| `seam_rules.txt` | Seam Surface Creation 默认参数。 |
| `geometry_cleanup_rules.txt` | Geometry Cleanup 默认参数。 |
| `casting_mesh_rules.txt` | Casting TetraMesh 默认参数。 |
| `contact_rules.txt` | Contact Setup 默认参数。 |
| `*_state.txt` | 模块 UI 状态缓存，由脚本自动生成。 |

## 5. 命名约定

推荐组件名称保留类型、厚度和材料信息：

```text
SHELL_PARTNAME_T2.0_Q235
SOLID_PARTNAME_Q235
CASTING_PARTNAME_QT500
SEAM_T2.0
```

命名规则：

- 类型前缀来自 `SHELL`、`SOLID`、`CASTING`。
- 钣金厚度使用 `_T<value>`，例如 `_T2.0`。
- 材料后缀来自 `config/materials.txt` 中的 `key`。
- Material Assignment 会识别材料库中已有 key，并替换组件名中已有的材料后缀。
- Midsurface Extraction 优先读取源组件名中的 `_Tx`，无法读取时会尝试从中面拓扑或体积/面积测量厚度。
- Midsurface Extraction 与 Mesh Seam Weld 共用厚度标记规则；中面输出中的 `_Tx` 可直接被网格焊缝读取并生成 `SEAM_Tx`。
- Seam Surface Creation 输出 `SEAM_Tx`，其中 `x` 优先取相邻组件名中较薄的厚度。

`Batch Property and Material Assignment` 位于主界面的 `Mesh / 网格` 页，扫描全部 component，并使用以下规则创建或复用 OptiStruct `PSHELL`：

```text
Vxx_..._Txx任意后缀_..._材料  ->  材料_Txx
包含 SEAM 且其后存在 Txx      ->  SEAM_Txx（材料固定为 Steel）
```

普通件只读取 `T` 后紧跟的数字作为厚度，并把最后一个下划线字段作为材料；例如 `V01_xxxx_T10aaa_355` 生成 `355_T10`。焊缝名称的其余后缀会被忽略，例如 `SEAM_T10_dff` 和 `SEAM_T10.surf` 都生成 `SEAM_T10`。

材料必须已由用户创建。模块会先调用 HyperMesh 原生的 `*EntityPreviewEmpty` 一次性识别空 component；这些 component 不再检查 Property、解析名称或进入人工复核。已经关联 Property 的 component，以及名称中包含 `BEAM`、`RBE`、`BUSH`、`SPRING`（不区分大小写）的 1D component 也会直接跳过。无法识别、找不到材料、Property 创建失败或赋予校验失败的非空 component 不会被移动；模块只会在 `PROPERTY_ASSIGNMENT_REVIEW` assembly 中创建名为 `PROPERTY_REVIEW__<原component名>` 的空 component collector，作为人工复核名称清单，不复制网格、节点或几何。

## 6. 模块功能和用法

### 6.1 Component Classification

入口：`::CompWorkflow::runCategory`

功能：将组件分类为 `SHELL`、`SOLID` 或 `CASTING`，规范化组件名称，并组织到对应装配中。

用法：

1. 在主面板运行 `Component Classification`。
2. 在 `类型 / Category` 中选择目标类型。
3. 点击 `选择组件`，在 HyperMesh 中选择 component。
4. 点击 `应用类型`。

输出：

- `NAME` 会变为 `CATEGORY_NAME`。
- 如果已有类型前缀，会替换为当前选择的类型。
- 组件会加入对应类型装配。

### 6.2 Material Assignment

入口：`::CompWorkflow::runMaterial`

功能：从 `config/materials.txt` 选择材料 key，追加或替换组件名称中的材料后缀，并按材料装配归类。

用法：

1. 在主面板运行 `Material Assignment`。
2. 在材料列表中选择材料 key。
3. 点击 `选择组件`，选择已经带有类型前缀的 component。
4. 点击 `应用材料标识`。
5. 需要调整材料库时，点击模块中的 `编辑 TXT`，保存后点击 `重新加载`。

输出：

- `SHELL_PART_T2.0` 可变为 `SHELL_PART_T2.0_Q235`。
- 组件会加入材料装配，例如 `SHELL_Q235`。

材料文件格式：

```text
key|display|density|E|nu|yield|ultimate|note
Q235|Q235|7.85e-9|210000|0.30|235|370|steel
```

### 6.3 Midsurface Extraction

入口：`::MidSurf::run`

功能：批量抽取钣金几何中面，按 `CATEGORY_NAME_Tx_MATERIAL` 规则命名输出 component。

用法：

1. 在主面板运行 `Midsurface Extraction`。
2. 点击 `选择/重选组件`，选择需要抽中面的几何 component。
3. 检查抽取方法、阶梯对齐步数、中面位置、R/T 比等参数。
4. 点击 `开始抽取`。

输出：

- 生成新的 midsurface component。
- 输出 component 统一放入 `midsurf` assembly。
- 源几何保留并隐藏。
- 厚度优先读取源 component 名称中的 `_Tx`；名称中没有厚度时，尝试读取中面拓扑点厚度，仍不可用时按实体体积/中面面积自动测量。

### 6.4 Geometry Cleanup: Chamfer/Recess

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

### 6.5 Seam Surface Creation

入口：`::SeamSurf::run`

功能：通过线-面或线-线方式创建 `SEAM_Tx` 焊缝面，并对焊缝面及两侧接触面执行 equivalence。

用法：

1. 在主面板运行 `Seam Surface Creation`。
2. 选择模式：
   - `Line-Surface`：先选择源线，再选择投影目标面。
   - `Line-Line`：依次选择两条焊缝边界线。
3. 检查特征转角、基础采样分段数和 equivalence 容差。
4. 点击 `进入连续创建`。
5. 每次创建完成后继续选择下一条线或下一组线；在选择面板按 `ESC` 退出。

输出：

- 生成 `SEAM_Tx` component。
- `x` 优先取相邻 component 名称中较薄的 `_T` 厚度。
- 若厚度无法读取，会提示手动输入。
- Line-Surface 模式会投影源线、trim 目标面，再以原始线和投影线创建 ruled 焊缝。
- Line-Line 模式会按两侧特征点对应关系切分曲线段，并逐段创建 ruled 焊缝。
- 单次失败时撤销本次几何修改并等待下一次选择。

### 6.6 BatchMesher 自动网格划分

入口：`::BatchMesher::runAction`

功能：以用户选择的 Surface ID 为执行数据，使用 HyperMesh 2019 `by attached` 提取最终几何拓扑连通域，并逐域顺序调用 BatchMesher。不会按 component 拆分，也不会生成或覆盖 criteria/param/washer 参数。

用法：

1. 在主面板运行 `BatchMesher 自动网格划分`。
2. 配置并保存 criteria/param 预设以及 HyperMesh 2019 `hmbatch.exe`，并执行测试启动。
3. 手动选择、选择当前显示或选择全部 surfaces。
4. 点击 `分析几何连通性`，复核连通域、涉及 component 和诊断提示。
5. 运行任务；失败任务可单独重试，运行前会重新验证 Surface ID 与模型 Surface 集合。

输出：

- 每个不可拆分的 Surface 拓扑连通域对应一个任务；单一连通域自动整体执行。
- 每个任务记录状态、耗时、Surface IDs、原始 Tcl 错误和独立日志。
- 报告位于共享任务存储的 `batch_mesher/<run-id>/`，包含 `run.json`、`result.json`、`run.log` 和逐任务日志。

### 6.7 Casting TetraMesh

入口：`::CastingTetMesh::run`

功能：执行铸件 surface 清理、三角面网格质量迭代和 TetraMesh 体网格填充。

用法：

1. 在主面板运行 `Casting TetraMesh`。
2. 点击 `选择/重选组件`，选择铸件几何 component。
3. 检查删除 solid、surface 清理、三角面网格、2D 质量迭代和 TetraMesh 选项。
4. 检查 criteria、cleanup 参数、`tet_string` 和 `pars_string`。
5. 点击开始执行。

输出：

- 可删除 solid 并保留边界 surface。
- 可清理小孔、小圆角、短边等微小特征。
- 创建三角面网格并进行 2D 质量迭代。
- 质量通过后执行 TetraMesh 体网格填充。
- 可将失败壳单元组织到 `AUTO_CASTING_FAILED_2D`。

### 6.8 Shell Washer-Hole RBE2

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

### 6.9 Solid Through-Hole RBE2

入口：`::AutoHoleRBE2::run`

功能：识别实体网格中的圆柱贯通孔，并创建中心节点和 RBE2。

用法：

1. 在主面板运行 `Solid Through-Hole RBE2`。
2. 点击 `选择/重选组件`，选择实体网格 component。
3. 检查光顺面片角度、圆柱拟合容差、端部环容差和孔半径范围。
4. 设置结果 component 名称。
5. 点击开始执行。

输出：

- 生成临时自由面 component，用于识别孔壁面片。
- 对有效贯通孔创建中心节点和 RBE2。
- 输出到指定结果 component。
- 运行结束后可自动删除临时自由面 component。

### 6.10 RBE2 Bolt Connector

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

### 6.11 CBUSH Creator

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

### 6.12 Adhesive Connector

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

### 6.13 Contact Setup

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

### 6.14 Solid Seam Connector

入口：`::SolidSeam::run`

功能：从选中 Solid Components 的外表面边界边或特征边中识别焊缝候选，支持双组件 Solid–Shell / Solid–Solid 和多组件 Solid×Shell 模式，并推荐 `PENTA_MIG_T/L/B` 或通用 `PENTA_MIG` realization。

用法：

1. 在主面板运行 `实体焊缝 / Solid Seam Connector`。
2. 设置搜索距离、最短焊缝长度、特征角和有效采样比例。
3. 点击 `选择组件并识别`，在 HyperMesh 原生 Components 面板中选择两个或更多组件。
4. 在候选页预览节点、接受/拒绝候选、修改 PENTA 类型或反转 nodelist。
5. 只对已接受候选执行创建。每条失败独立记录，不中断后续候选。

识别结果和日志写入 `temp/solid_seam/<run_id>/`。为防止未经验证的 connector 参数修改模型，仓库默认关闭 realization；必须先按 [模块说明](modules/solid_seam/README.md) 从目标 HM2019 Command File 制作并启用 profile。

完整识别验证可运行 `examples/SolidSeam_Validation/generate_fem.py`，并导入生成的单一组合模型 `SolidSeam_Combined_Validation.fem`。对应 manifest 给出了每组应选组件、参数和预期结果。

### 6.15 网格焊缝完整性检查

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

当前限制：只支持 Shell–Shell；距离搜索是自由边节点到目标网格节点的近似，不读取 CAD，不自动识别所有已有焊缝，不自动创建或修复焊缝。所有候选都需要工程人员在 HyperMesh 中确认。

## 7. 公共机制

`modules/workflow_common.tcl` 提供跨模块共享能力：

- 全局语言配置读取。
- 材料库读取。
- component 命名、重命名和装配组织。
- Model Browser 创建、同步和刷新。
- 进度窗口、取消状态和日志。
- 模块 UI 状态保存与读取。

脚本创建 component 后会尽量通过 HyperMesh 2019 的 Browser API 同步登记；内部 Browser API 不可用时回退到普通 `*createentity`。如果 Browser 未立即更新，使用主面板 `刷新浏览器` 即可。

## 8. 开发和验证说明

- 目标环境：HyperMesh 2019 Tcl/Tk（已验证基线）和 HyperWorks 2022 新界面（迁移兼容目标）。
- 2022 当前覆盖启动、hwtk/Tk 窗口和 UTF-8 中文显示；各模块的 HyperMesh 原生命令仍需按模块在 2022 实机模型上逐步回归。
- 本项目不依赖普通 Tcl 以外的第三方运行时，但核心命令依赖 HyperMesh。
- 普通 Tcl 解释器可用于基础语法检查，不能验证 HyperMesh 命令行为。
- 修改模块后，建议在 HyperMesh 中至少验证对应模块的窗口打开、选择流程、输出 component 和 Model Browser 刷新。
