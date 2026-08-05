# HyperMesh Toolkit

快捷键的首次安装、更新和恢复流程见 [快捷键安装与更新](shortcut_installation.md)。请优先运行 `install_update.tcl`；`hw_toolkit.tcl` 保留为兼容入口。

面向 HyperMesh 2019 的 Tcl/Tk 前处理工具集。项目把常用的车身/结构件前处理动作组织成一个主入口：中面抽取、几何清理、焊缝面、钣金网格与 washer、局部网格优化、铸件四面体网格、RBE2、螺栓连接和接触设置。

局部网格优化模块的集成状态、使用步骤、HM2019 运行验证和已知限制见 [README_LocalMeshOptimizer.md](README_LocalMeshOptimizer.md)。该模块坚持以 HyperMesh criteria 和原生质量结果为最终判定，并保留运行时错误处理、任务快照、复检和回滚。

默认界面语言为中文。需要英文界面时，将项目根目录 `config.yaml` 中的 `workflow.language` 改为 `en_US`。

界面基础设施已统一迁移到 HyperWorks 2019 内置的 `hwtk 1.0`。主面板、所有模块顶层窗口和公共进度窗口通过 `modules/workflow_common.tcl` 中的统一适配层创建；在非 HyperWorks Tcl 环境中会自动回退到 Tk/ttk。第一阶段保留各模块内部的既有参数控件和业务逻辑，后续可以按模块逐步替换为 hwtk 控件。

窗口不再使用永久 `-topmost`。调用 HyperMesh 原生实体选择面板时，只临时隐藏由工具箱登记的窗口，不影响同一 HyperMesh 进程中的其他 Tcl 窗口。

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

1. 在 `BatchMesher 自动网格划分` 中配置 HyperMesh 2019 `hmbatch.exe` 及用户维护的 `.criteria` / `.param` 预设；washer 行为由 `.param` 文件控制。
2. 检查 `config/casting_mesh_rules.txt`，确认铸件三角面网格、质量迭代和 TetraMesh 参数。
3. 检查 `config/seam_rules.txt`、`config/geometry_cleanup_rules.txt`、`config/contact_rules.txt`，确认焊缝面、几何清理和接触默认参数。

这些配置文件都是 `|` 分隔文本，模块面板中修改参数后，部分模块会把最新 UI 状态保存到 `config/*_state.txt`。

### 2.2 组件命名基础

前置组织模块正在重构，当前工具箱不再提供组件分类和材料标识入口。运行抽中面前只需保证源组件名称保留 `Vxx_件号`；材料可以尚未赋予，由后续网格模块识别和处理。HyperMesh 重复导入产生的 `.1`、`.2` 等后缀按同一部件或材料归类。

### 2.3 处理钣金件

钣金件建议按下面顺序执行：

1. `Midsurface Extraction`：选择钣金几何 component，抽取中面。
2. `Geometry Cleanup: Chamfer/Recess`：对倒角、圆角、沉台等影响中面或网格质量的位置做连续清理。
3. `Seam Surface Creation`：在需要焊接的位置创建 `SEAM_Tx` 焊缝面。
4. `Sheet BatchMesh and Washer`：对中面或壳 component 执行 BatchMesh，并按孔径规则生成 washer。
5. `Shell Washer-Hole RBE2`：识别标准 washer 孔并创建 RBE2。
6. `RBE2 Bolt Connector`：将成组 RBE2 中心节点连接为 CBEAM/CBAR 螺栓段。
7. `Contact Setup`：在两个 component 的相对区域创建 contact surface 和接触 group。

典型输出包括：

```text
MIDSURFED assembly
SEAM_T2.0
AUTO_RBE2_<source>
BOLT_D12_CBEAM
AUTO_CONTACT_*
```

### 2.4 处理实体件和铸件

实体件和铸件建议按下面顺序执行：

1. `Geometry Cleanup: Chamfer/Recess`：按需要清理小特征、倒角或沉台。
2. `Casting TetraMesh`：对铸件执行 surface 清理、三角面网格质量迭代和 TetraMesh。
3. `Solid Through-Hole RBE2`：对实体网格圆柱贯通孔创建 RBE2。
4. `RBE2 Bolt Connector`：在上下层或多层 RBE2 中心节点之间生成螺栓连接。
5. `Contact Setup`：为实体/壳或实体/实体的相对面建立接触。

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
|   |-- washer_rules.txt
|   |-- seam_rules.txt
|   |-- geometry_cleanup_rules.txt
|   |-- casting_mesh_rules.txt
|   `-- contact_rules.txt
`-- modules/
    |-- workflow_common.tcl
    |-- shortcut_manager.tcl
    |-- midsurf.tcl
    |-- geometry_cleanup.tcl
    |-- seam_surface.tcl
    |-- batch_mesher.tcl
    |-- batch_mesher/
    |-- casting_tetramesh.tcl
    |-- local_mesh_optimizer.tcl
    |-- local_mesh_optimizer/
    |   |-- python/
    |   `-- tests/
    |-- auto_hole_rbe2.tcl
    |-- shell_washer_hole_rbe2.tcl
    |-- rbe2_bolt_connector.tcl
    |-- contact_setup.tcl
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
| `washer_rules.txt` | 孔径与 washer 规则。 |
| `seam_rules.txt` | Seam Surface Creation 默认参数。 |
| `geometry_cleanup_rules.txt` | Geometry Cleanup 默认参数。 |
| `casting_mesh_rules.txt` | Casting TetraMesh 默认参数。 |
| `contact_rules.txt` | Contact Setup 默认参数。 |
| `*_state.txt` | 模块 UI 状态缓存，由脚本自动生成。 |

## 5. 命名约定

推荐组件名称统一保留版本、件号和厚度；材料字段在后续网格模块处理时追加：

```text
V01_PARTNAME_T2.0
V01_PARTNAME_T2.0_Q235
SEAM_T2.0
```

命名规则：

- `Vxx` 为版本/车型前缀，`Name` 为件号或部件名称。
- 钣金厚度使用 `_T<value>`，例如 `_T2.0`。
- 材料后缀是可选字段；抽中面时可以没有材料，后续网格模块从组件名称或 HyperMesh 材料实体识别并赋予材料。
- HyperMesh 重复导入产生的 `.1`、`.2` 等后缀不改变部件或材料归类。
- Midsurface Extraction 优先读取源组件名中的 `_Tx`，无法读取时会尝试从中面拓扑或体积/面积测量厚度。
- Midsurface Extraction 与 Mesh Seam Weld 共用厚度标记规则；中面输出中的 `_Tx` 可直接被网格焊缝读取并生成 `SEAM_Tx`。
- Seam Surface Creation 输出 `SEAM_Tx`，其中 `x` 优先取相邻组件名中较薄的厚度。

## 6. 模块功能和用法

### 6.1 Midsurface Extraction

入口：`::MidSurf::run`

功能：批量抽取钣金几何中面，按 `Vxx_Name_Tx[_材料]` 规则命名输出 component；抽中面时材料可为空。

用法：

1. 在主面板运行 `Midsurface Extraction`。
2. 点击 `选择/重选组件`，选择需要抽中面的几何 component。
3. 检查抽取方法、阶梯对齐步数、中面位置、R/T 比等参数。
4. 点击 `开始抽取`。

输出：

- 生成新的 midsurface component。
- 输出 component 命名为 `Vxx_Name_T<厚度>`；源名称已有材料字段时才保留该字段。
- 输出 component 统一放入 `MIDSURFED` assembly。
- 源几何保留并隐藏。
- 厚度优先读取源 component 名称中的 `_Tx`；名称中没有厚度时，尝试读取中面拓扑点厚度，仍不可用时按实体体积/中面面积自动测量。

### 6.2 Geometry Cleanup: Chamfer/Recess

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

### 6.3 Seam Surface Creation

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

### 6.4 BatchMesher 自动网格划分

入口：`::BatchMesher::runAction`

功能：按 Surface 最终拓扑连通域顺序执行 HyperMesh 2019 BatchMesher，完整使用用户选择的 criteria/param 文件。

用法：

1. 在主面板运行 `BatchMesher 自动网格划分`。
2. 配置 criteria/param 预设并选择目标 surfaces。
3. 分析 `by attached` 几何连通域并复核诊断信息。
4. 顺序运行任务；失败任务可单独重试。

输出：

- 每个 Surface 拓扑连通域对应一个不可自动拆分的任务。
- 每个任务记录状态、耗时、Surface IDs、Tcl 错误和独立日志。
- washer 继续由用户 `.param` 文件控制，工具不传入覆盖参数。

### 6.5 Casting TetraMesh

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

### 6.6 Shell Washer-Hole RBE2

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

### 6.7 Solid Through-Hole RBE2

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

### 6.8 RBE2 Bolt Connector

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

### 6.9 Contact Setup

入口：`::ContactSetup::run`

功能：选择两个 component，自动识别相对方向，创建 contact surface 和接触 group，并支持按单元修剪多余接触。

用法：

1. 在主面板运行 `Contact Setup`。
2. 点击 `选择两个组件`，在 HyperMesh 中选择需要建立接触关系的两个 component。
3. 选择接触类型：`SLIDE`、`TIE`、`STICK`、`FREEZE`、`FRICTIONLESS` 或 `FRICTION`。
4. 设置主面：
   - `AUTO`：按 contact surface 单元数量自动选择较大侧。
   - `FIRST`：第一个选择的 component 作为主面。
   - `SECOND`：第二个选择的 component 作为主面。
5. 设置结果名前缀、是否创建 contact group、是否保留实体自由面临时组件。
6. 点击 `创建接触`。
7. 如需删除多余接触，点击 `修改接触`，连续选择需要从 contact surface 中移除的单元后中键确认。
8. 修改完成后点击 `恢复视图`。

输出：

- 自动识别两个 component 之间相对的外侧面。
- 分别创建 `contactsurfs`。
- 自动创建接触 group，并尝试写入主/从 contact surface。
- 实体 component 会先生成自由面临时组件；壳 component 直接使用壳单元。
- 修改模式只会从当前 contact surface 中移除所选单元，不删除源 component 原始网格。

### 6.10 Solid Seam Connector

入口：`::SolidSeam::run`

功能：从选中 Solid Components 的外表面边界边或特征边中识别焊缝候选，支持双组件 Solid–Shell / Solid–Solid 和多组件 Solid×Shell 模式，并推荐 `PENTA_MIG_T/L/B` 或通用 `PENTA_MIG` realization。

用法：

1. 在主面板运行 `实体焊缝 / Solid Seam Connector`。
2. 设置搜索距离、最短焊缝长度、特征角和有效采样比例。
3. 点击 `选择组件并识别`，在 HyperMesh 原生 Components 面板中选择两个或更多组件。
4. 在候选页预览节点、接受/拒绝候选、修改 PENTA 类型或反转 nodelist。
5. 只对已接受候选执行创建。每条失败独立记录，不中断后续候选。

识别结果和日志写入 `temp/solid_seam/<run_id>/`。为防止未经验证的 connector 参数修改模型，仓库默认关闭 realization；必须先按 [模块说明](../modules/solid_seam/README.md) 从目标 HM2019 Command File 制作并启用 profile。

完整识别验证可运行 `examples/SolidSeam_Validation/generate_fem.py`，并导入生成的单一组合模型 `SolidSeam_Combined_Validation.fem`。对应 manifest 给出了每组应选组件、参数和预期结果。

### 6.11 网格焊缝完整性检查

入口：`::WeldIntegrityCheck::runAction`

用途：在主要网格和连接完成后，识别可能存在遗漏焊缝的 Shell Component Pair，并提供逐组孤立、局部高亮和人工完成确认。模块不自动建焊缝，也不修改现有网格。

参数：

- `最大搜索距离`：自由边节点与另一组件节点进入候选的最大距离，单位跟随当前模型。
- `最小有效接近长度`：连续候选自由边链的最短累计长度。
- `最小连续节点数`：过滤单角点和少量零散近邻。
- `优先检测 Shell 自由边`：首版算法以壳自由边为候选源。
- `忽略已直接共节点连接的组件对`：共享节点达到连续节点阈值时跳过该 Pair。

操作：选择至少两个待检查组件，可另选排除组件；检测后在 Pair 列表中按名称或 ID 筛选。`孤立` 会只显示当前两个组件并高亮当前候选区域；区域按钮可逐个定位。`完成` 将结果标记为 `completed` 并从待检查列表隐藏，切换到 `completed` 可重新打开。`恢复进入模块前显示` 会恢复模块启动时的可见组件集合，而不是简单显示全部。

结果保存在 `runtime/tasks/weld_integrity_check/<run_id>/`：输入位于 `input/`，JSON 与 Python 日志位于 `output/`，审查进度位于 `state/review_state.json`。关闭报告会自动清理 mark/编号并恢复显示；同一 HyperMesh 会话再次进入模块可继续上次审查。

当前限制：只支持 Shell–Shell；距离搜索是自由边节点到目标网格节点的近似，不读取 CAD，不自动识别所有已有焊缝，不自动创建或修复焊缝。所有候选都需要工程人员在 HyperMesh 中确认。

## 7. 公共机制

`modules/workflow_common.tcl` 提供跨模块共享能力：

- 全局语言配置读取。
- HyperMesh 材料实体名称匹配和重复后缀归一化。
- component 命名、重命名和装配组织。
- Model Browser 创建、同步和刷新。
- 进度窗口、取消状态和日志。
- 模块 UI 状态保存与读取。

脚本创建 component 后会尽量通过 HyperMesh 2019 的 Browser API 同步登记；内部 Browser API 不可用时回退到普通 `*createentity`。如果 Browser 未立即更新，使用主面板 `刷新浏览器` 即可。

## 8. 开发和验证说明

- 目标环境：HyperMesh 2019 Tcl/Tk。
- 本项目不依赖普通 Tcl 以外的第三方运行时，但核心命令依赖 HyperMesh。
- 普通 Tcl 解释器可用于基础语法检查，不能验证 HyperMesh 命令行为。
- 修改模块后，建议在 HyperMesh 中至少验证对应模块的窗口打开、选择流程、输出 component 和 Model Browser 刷新。
