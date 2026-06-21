# HyperMesh Toolkit

面向 HyperMesh 2019 的 Tcl/Tk 前处理工具集。项目把常用的车身/结构件前处理动作组织成一个主入口：组件分类、材料标识、中面抽取、几何清理、焊缝面、钣金网格与 washer、铸件四面体网格、RBE2、螺栓连接和接触设置。

默认界面语言为中文。需要英文界面时，将项目根目录 `config.yaml` 中的 `workflow.language` 改为 `en_US`。

## 1. 快速启动

在 HyperMesh 中运行：

```text
File > Run > Tcl/Tk Script > hw_toolkit.tcl
```

运行后会打开 `HyperMesh Toolkit` 主面板。模块按工作阶段分组显示：

```text
01. Model Setup
02. Geometry
03. Seam
04. Mesh
05. RBE2
06. Bolt
07. Contact
```

主面板中的 `刷新浏览器` 用于恢复 Model Browser 更新并刷新图形窗口，不会改变已有 component 的显示/隐藏状态。

## 2. 推荐工作流

### 2.1 准备项目配置

1. 检查 `config/materials.txt`，确认材料 key、显示名和材料参数符合当前项目。
2. 检查 `config/mesh_rules.txt` 和 `config/washer_rules.txt`，确认钣金网格尺寸、孔径范围和 washer 规则。
3. 检查 `config/casting_mesh_rules.txt`，确认铸件三角面网格、质量迭代和 TetraMesh 参数。
4. 检查 `config/seam_rules.txt`、`config/geometry_cleanup_rules.txt`、`config/contact_rules.txt`，确认焊缝面、几何清理和接触默认参数。

这些配置文件都是 `|` 分隔文本，模块面板中修改参数后，部分模块会把最新 UI 状态保存到 `config/*_state.txt`。

### 2.2 建立组件命名和材料基础

先在 `01. Model Setup` 中完成模型基础整理：

1. 运行 `Component Type Classification`。
2. 选择 `SHELL`、`SOLID` 或 `CASTING`，再选择对应 component。
3. 点击 `应用类型`，组件会被重命名为 `CATEGORY_NAME`，例如 `SHELL_BRACKET`。
4. 运行 `Material Assignment`。
5. 从材料库选择材料 key，选择已分类 component。
6. 点击 `应用材料标识`，组件会被重命名为 `CATEGORY_NAME_MATERIAL` 或保留已有厚度信息，例如 `SHELL_BRACKET_T2.0_Q235`。

建议所有后续模块都基于这套命名继续处理，因为中面厚度、焊缝面厚度、washer 和连接输出都会读取或延续这些信息。

### 2.3 处理钣金件

钣金件建议按下面顺序执行：

1. `Midsurface Extraction`：选择钣金几何 component，抽取中面。
2. `Geometry Cleanup`：对倒角、圆角、沉台等影响中面或网格质量的位置做连续清理。
3. `Seam Surface Creation`：在需要焊接的位置创建 `SEAM_Tx` 焊缝面。
4. `Sheet BatchMesh + Washer`：对中面或壳 component 执行 BatchMesh，并按孔径规则生成 washer。
5. `Shell Washer Hole RBE2`：识别标准 washer 孔并创建 RBE2。
6. `RBE2 Bolt Connector`：将成组 RBE2 中心节点连接为 CBEAM/CBAR 螺栓段。
7. `Contact Setup`：在两个 component 的相对区域创建 contact surface 和接触 group。

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

1. `Component Type Classification`：将 component 标记为 `SOLID` 或 `CASTING`。
2. `Material Assignment`：追加材料 key。
3. `Geometry Cleanup`：按需要清理小特征、倒角或沉台。
4. `Casting TetraMesh`：对铸件执行 surface 清理、三角面网格质量迭代和 TetraMesh。
5. `Solid Through-Hole RBE2`：对实体网格圆柱贯通孔创建 RBE2。
6. `RBE2 Bolt Connector`：在上下层或多层 RBE2 中心节点之间生成螺栓连接。
7. `Contact Setup`：为实体/壳或实体/实体的相对面建立接触。

### 2.5 中断、返回和刷新

- 每个模块窗口都支持 `返回主页 / Back to Home`。
- 多数模块按 `Esc` 可关闭当前窗口；连续选择类模块在 HyperMesh 选择面板中按 `ESC` 退出连续模式。
- 如果脚本创建了 component 但左侧 Model Browser 未立即显示，点击主面板 `刷新浏览器`。
- 普通 Tcl 解释器只能做基础语法检查；所有 HyperMesh 命令必须在 HyperMesh 内运行。

## 3. 目录结构

```text
.
|-- hw_toolkit.tcl
|-- config.yaml
|-- config/
|   |-- materials.txt
|   |-- mesh_rules.txt
|   |-- washer_rules.txt
|   |-- seam_rules.txt
|   |-- geometry_cleanup_rules.txt
|   |-- casting_mesh_rules.txt
|   `-- contact_rules.txt
`-- modules/
    |-- workflow_common.tcl
    |-- component_workflow.tcl
    |-- midsurf.tcl
    |-- geometry_cleanup.tcl
    |-- seam_surface.tcl
    |-- batch_mesh_washer.tcl
    |-- casting_tetramesh.tcl
    |-- auto_hole_rbe2.tcl
    |-- shell_washer_hole_rbe2.tcl
    |-- rbe2_bolt_connector.tcl
    `-- contact_setup.tcl
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
| `mesh_rules.txt` | Sheet BatchMesh 默认参数。 |
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
- Seam Surface Creation 输出 `SEAM_Tx`，其中 `x` 优先取相邻组件名中较薄的厚度。

## 6. 模块功能和用法

### 6.1 Component Type Classification

入口：`::CompWorkflow::runCategory`

功能：将组件分类为 `SHELL`、`SOLID` 或 `CASTING`，规范化组件名称，并组织到对应装配中。

用法：

1. 在主面板运行 `Component Type Classification`。
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
3. 检查抽取方法、阶梯对齐步数、中面位置、R/T 比、厚度格式等参数。
4. 点击 `开始抽取`。

输出：

- 生成新的 midsurface component。
- 输出 component 统一放入 `midsurf` assembly。
- 源几何保留并隐藏。
- 厚度优先读取源 component 名称中的 `_Tx`；名称中没有厚度时，尝试读取中面拓扑点厚度，仍不可用时按实体体积/中面面积自动测量。

### 6.4 Geometry Cleanup

入口：`::GeomCleanup::run`

功能：连续处理倒角、圆角和沉台补面等几何清理任务。

用法：

1. 在主面板运行 `Geometry Cleanup`。
2. 检查模式、圆角半径范围、缝合容差、邻接扩展层数等参数。
3. 点击 `进入连续清洗`。
4. 在 HyperMesh 选择面板中选择一个倒角面、圆角面或沉台底面，按中键执行。
5. 继续选择下一个面；取消选择时退出连续清洗。

输出：

- 对匹配的 solid 倒角/圆角执行清理。
- 对沉台识别内边、外边和基准边，删除沉台面及小竖直面后创建连接面。
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

### 6.6 Sheet BatchMesh + Washer

入口：`::BatchMeshWasher::run`

功能：对钣金中面或壳组件执行 BatchMesh，并按孔径标准忽略小孔、保留大孔或生成 washer。

用法：

1. 在主面板运行 `Sheet BatchMesh + Washer`。
2. 点击 `选择/重选组件`，选择钣金中面或壳网格 component。
3. 检查网格尺寸、孔径识别范围、BatchMesh 参数和 washer 批量参数。
4. 确认 `config/washer_rules.txt` 中的孔径规则符合项目标准。
5. 点击开始执行。

输出：

- 对选中 component 执行 BatchMesh。
- 不修改原始几何。
- 识别指定孔径范围内的孔。
- 按规则忽略小孔、保留大孔或创建 washer。
- 生成孔数量、washer 创建数量和失败数量等统计。

washer 规则格式：

```text
hole_dia_min|hole_dia_max|action|hole_density|washer_layers|width_mode|widths|note
6|9|washer|8|2|abs|4,6|6mm < D <= 9mm
```

`action` 支持：

| action | 说明 |
| --- | --- |
| `ignore` | 忽略该孔径范围，不做特殊处理。 |
| `washer` | 生成 washer。 |
| `keep` | 保留孔，不生成 washer。 |

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

### 6.8 Shell Washer Hole RBE2

入口：`::RB2W::run`

功能：识别壳单元标准 washer 孔，并在孔中心创建 RBE2。

用法：

1. 在主面板运行 `Shell Washer Hole RBE2`。
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
5. 可先勾选预览模式检查分组，再取消预览创建连接段。
6. 点击确定执行。

输出：

- 对符合条件的 RBE2 中心节点分组。
- 沿识别轴向连接相邻 RBE2。
- 输出 component 按孔径和单元类型命名，例如 `BOLT_D12_CBEAM`。
- 只组织新建的一维连接单元，不移动源节点。

### 6.11 Contact Setup

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

- 目标环境：HyperMesh 2019 Tcl/Tk。
- 本项目不依赖普通 Tcl 以外的第三方运行时，但核心命令依赖 HyperMesh。
- 普通 Tcl 解释器可用于基础语法检查，不能验证 HyperMesh 命令行为。
- 修改模块后，建议在 HyperMesh 中至少验证对应模块的窗口打开、选择流程、输出 component 和 Model Browser 刷新。
