# HyperMesh 前处理工作流工具集 / HyperMesh Preprocess Workflow Toolkit

面向 HyperMesh 2019 的 Tcl/Tk 前处理工作流工具集，覆盖组件分类、材料标识分配、中面抽取、几何倒角/沉台清理、焊缝面创建、钣金 BatchMesh + washer、孔位 RBE2 创建以及 RBE2 螺栓连接生成等流程。

This repository contains Tcl/Tk workflow scripts for HyperMesh 2019 preprocessing, covering component classification, material tagging, midsurface extraction, chamfer/recess geometry cleanup, seam-surface creation, sheet-metal BatchMesh + washer creation, hole RBE2 creation, and RBE2 bolt connector generation.

默认界面语言为中文。可在项目根目录的 `config.yaml` 中将 `workflow.language` 切换为 `en_US`。

The default UI language is Chinese. Change `workflow.language` in the root `config.yaml` to `en_US` to switch the workflow UI to English.

## 中文

### 启动方式

在 HyperMesh 中通过 `File > Run > Tcl/Tk Script` 运行项目根目录下的 `hw_toolkit.tcl`，进入统一工作流主面板。

### 全局配置

项目根目录的 `config.yaml` 用于工作流级全局配置。当前仅启用语言配置：

```yaml
workflow:
  language: zh_CN
```

支持的语言值：

| 值 | 说明 |
| --- | --- |
| `zh_CN` | 简体中文，默认值。 |
| `en_US` | 英文界面。 |

语言配置会作用于主面板、模块窗口、选择提示、校验提示、执行结果弹窗和状态消息。当前配置保持轻量化，后续可继续扩展网格标准、RBE2 规则、washer 规则等全局参数。

### 目录结构

```text
.
|-- hw_toolkit.tcl
|-- config.yaml
|-- config/
|   |-- casting_mesh_rules.txt
|   |-- materials.txt
|   |-- mesh_rules.txt
|   |-- seam_rules.txt
|   |-- *_state.txt
|   `-- washer_rules.txt
`-- modules/
    |-- workflow_common.tcl
    |-- component_workflow.tcl
    |-- midsurf.tcl
    |-- geometry_cleanup.tcl
    |-- seam_surface.tcl
    |-- batch_mesh_washer.tcl
    |-- casting_tetramesh.tcl
    |-- auto_hole_rbe2.tcl
    |-- rbe2_bolt_connector.tcl
    `-- shell_washer_hole_rbe2.tcl
```

### 工作流模块

| 模块 | 入口 | 功能 |
| --- | --- | --- |
| `hw_toolkit.tcl` | `::HWToolkit::run` | 工作流主面板与模块调度入口。 |
| `modules/workflow_common.tcl` | shared helpers | 全局配置、语言切换、材料库、命名规则、装配与浏览器辅助函数。 |
| `modules/component_workflow.tcl` | `::CompWorkflow::runCategory` | 将组件分类为 `SHELL`、`SOLID`、`CASTING`，并按类型规则重命名和组织装配。 |
| `modules/component_workflow.tcl` | `::CompWorkflow::runMaterial` | 从 `config/materials.txt` 读取材料库，对已分类组件分配材料标识并替换既有材料后缀。 |
| `modules/midsurf.tcl` | `::MidSurf::run` | 抽取钣金中面，并按 `CATEGORY_NAME_Tx_MATERIAL` 规则命名输出组件。源几何默认保留并隐藏。 |
| `modules/geometry_cleanup.tcl` | `::GeomCleanup::run` | 选择一个倒角面或沉台底面，自动判断并执行 solid 倒角清理或纯 surface 沉台补平。 |
| `modules/seam_surface.tcl` | `::SeamSurf::run` | 基于线-面或线-线焊缝流程创建 `SEAM_Tx` 几何面，并按较薄相邻壳厚度命名。 |
| `modules/batch_mesh_washer.tcl` | `::BatchMeshWasher::run` | 对钣金中面/壳组件执行 BatchMesh，不修改几何，并按孔径标准忽略小孔或生成 washer。 |
| `modules/casting_tetramesh.tcl` | `::CastingTetMesh::run` | 对铸件执行删除 solid、surface 微小特征清理、三角面网格质量迭代和 CFD/TetraMesh 体填充。 |
| `modules/auto_hole_rbe2.tcl` | `::AutoHoleRBE2::run` | 识别实体网格贯通圆孔并创建 RBE2。 |
| `modules/shell_washer_hole_rbe2.tcl` | `::RB2W::run` | 针对壳单元 washer 孔创建 RBE2，并将结果归集到输出组件。 |
| `modules/rbe2_bolt_connector.tcl` | `::RB2Bolt::run` | 对 RBE2 进行分组，并生成 CBEAM/CBAR 螺栓连接段。 |

### 命名规则

组件名称应携带完整流程信息：

```text
SHELL_PARTNAME_T2.0_Q235
SOLID_PARTNAME_Q235
CASTING_PARTNAME_QT500
SEAM_T2.0
```

材料标识分配会识别并替换已在 `config/materials.txt` 中定义的既有材料后缀。

### 模块配置

`config/materials.txt` 为管道符分隔的材料库：

```text
key|display|density|E|nu|yield|ultimate|note
Q235|Q235|7.85e-9|210000|0.30|235|370|steel
```

材料标识分配模块中的“编辑 TXT”会直接编辑该文件。

`config/seam_rules.txt` 保存焊缝面创建默认参数，例如最大投影间隙、拓扑缝合容差和组件归集模式。

`config/*_state.txt` 为自动生成的模块状态文件，用于记忆上一次运行的选项、文本框和数值字段。由于组件、单元、线和面的 ID 在不同模型间不稳定，模型实体选择不会被持久化。

`config/mesh_rules.txt` 保存钣金 BatchMesh 默认参数，例如目标单元尺寸、最小/最大单元尺寸、`params_generate_mode`、`no_geomcleanup`、是否禁用 BatchMesh 默认 washer、surface 分块数量和 washer 孔识别范围等。默认不修改几何，保留 HyperMesh/Tk 消息刷新，按 surface 小批次执行 BatchMesh，并只识别 6-30mm 孔。

`config/casting_mesh_rules.txt` 保存铸件网格默认参数，包括删除 solid 并保留边界 surface、微小孔/小圆角清理阈值、三角面网格尺寸、2D 质量迭代次数、`*tetmesh` 原始参数和 3D 质量摘要 criteria。默认流程为：删除选中组件内 solid 但保留其边界 surface、清理 surface 小特征、生成 tria 面网格、质量合格后执行 TetraMesh 体填充。

`config/geometry_cleanup_rules.txt` 保存倒角/沉台几何清理默认参数。默认入口只要求选择一个面：自动模式优先通过 HyperMesh 圆角识别和相邻小面扩展尝试清除 solid 倒角/圆角，并在可形成闭合边界时尝试重建/补充 solid；若不匹配或失败，则按沉台底面处理，只做纯 surface 操作：删除底面与外圈竖直连接面，使用外圈顶面边界和内部边界线环创建补平 surface，并与保留的内部竖直面缝合。

`config/washer_rules.txt` 保存钣金孔 washer 规则。当前默认规则来自用户提供的标准图片：

```text
D < 6mm       ignore after meshing; geometry is not modified
6 < D <= 9    washer: hole_density=8,  layers=2, widths=4,6
9 < D <= 13   washer: hole_density=10, layers=2, widths=4,6
13 < D <= 20  washer: hole_density=12, layers=2, widths=6,8
20 < D <= 30  washer: hole_density=16, layers=2, widths=8,8
D > 30mm      keep
```

### 焊缝面流程

`焊缝面创建` 位于中面抽取之后、网格划分/RBE2 创建之前。

- `线-面`：选择一条源边线和一个目标中面，将源边线采样投影到目标面，并仅在源跨度与匹配投影跨度之间生成焊缝面。
- `线-线`：选择两条边界线，仅在两者最近的重叠跨度内生成焊缝面，适用于 L 型焊缝和边-边桥接焊缝。
- 闭合源线按环向序列采样，允许有效焊缝区间跨越 0/1 参数断点。
- 输出组件命名为 `SEAM_Tx`，其中 `x` 来自相邻组件名中较薄的 `_T` 厚度值。
- 若无法从 `_T` 读取厚度，流程会提示手动输入厚度。

### 注意事项

- 脚本面向 HyperMesh 2019 Tcl/Tk 环境编写。
- 普通 Tcl 解释器可用于基础语法检查，但 HyperMesh 命令只能在 HyperMesh 内运行。
- 模块窗口使用“返回主页”回到主面板；按 `Esc` 可关闭当前模块窗口。

## English

### Launch

In HyperMesh, run `hw_toolkit.tcl` from the repository root through `File > Run > Tcl/Tk Script` to open the unified workflow launcher.

### Global Configuration

The root `config.yaml` stores workflow-level global settings. It currently contains only the UI language setting:

```yaml
workflow:
  language: zh_CN
```

Supported values:

| Value | Description |
| --- | --- |
| `zh_CN` | Simplified Chinese, default. |
| `en_US` | English UI. |

The language setting applies to the launcher, module dialogs, selection prompts, validation messages, result dialogs, and status messages. The file is intentionally small for now and can later host global meshing standards, RBE2 rules, washer rules, and other workflow-level parameters.

### Structure

```text
.
|-- hw_toolkit.tcl
|-- config.yaml
|-- config/
|   |-- casting_mesh_rules.txt
|   |-- materials.txt
|   |-- mesh_rules.txt
|   |-- seam_rules.txt
|   |-- *_state.txt
|   `-- washer_rules.txt
`-- modules/
    |-- workflow_common.tcl
    |-- component_workflow.tcl
    |-- midsurf.tcl
    |-- geometry_cleanup.tcl
    |-- seam_surface.tcl
    |-- batch_mesh_washer.tcl
    |-- casting_tetramesh.tcl
    |-- auto_hole_rbe2.tcl
    |-- rbe2_bolt_connector.tcl
    `-- shell_washer_hole_rbe2.tcl
```

### Workflow Modules

| Module | Entry | Purpose |
| --- | --- | --- |
| `hw_toolkit.tcl` | `::HWToolkit::run` | Main workflow launcher and module dispatcher. |
| `modules/workflow_common.tcl` | shared helpers | Global configuration, language switching, material library, naming rules, assembly helpers, and browser helpers. |
| `modules/component_workflow.tcl` | `::CompWorkflow::runCategory` | Classify components into `SHELL`, `SOLID`, and `CASTING`, then rename and organize category assemblies. |
| `modules/component_workflow.tcl` | `::CompWorkflow::runMaterial` | Assign material tags from `config/materials.txt`, replace existing material suffixes, and organize material assemblies. |
| `modules/midsurf.tcl` | `::MidSurf::run` | Extract midsurfaces and name outputs as `CATEGORY_NAME_Tx_MATERIAL`. Source geometry is kept and hidden by default. |
| `modules/geometry_cleanup.tcl` | `::GeomCleanup::run` | Select one chamfer face or recessed floor face, then auto-detect solid chamfer cleanup or surface-only recess filling. |
| `modules/seam_surface.tcl` | `::SeamSurf::run` | Create `SEAM_Tx` geometry surfaces through Line-Surface or Line-Line workflows, using the thinner adjacent shell thickness. |
| `modules/batch_mesh_washer.tcl` | `::BatchMeshWasher::run` | Run BatchMesh on sheet-metal midsurface/shell components without modifying geometry, then ignore small holes or create washers by hole diameter rules. |
| `modules/casting_tetramesh.tcl` | `::CastingTetMesh::run` | Run casting solid removal, surface defeaturing, tria quality iterations, and CFD/TetraMesh volume fill. |
| `modules/auto_hole_rbe2.tcl` | `::AutoHoleRBE2::run` | Detect cylindrical through-holes in solid meshes and create RBE2 elements. |
| `modules/shell_washer_hole_rbe2.tcl` | `::RB2W::run` | Create RBE2 elements for shell washer holes and organize results into output components. |
| `modules/rbe2_bolt_connector.tcl` | `::RB2Bolt::run` | Group RBE2 elements and create CBEAM/CBAR bolt segments. |

### Naming Rules

Component names should carry complete workflow information:

```text
SHELL_PARTNAME_T2.0_Q235
SOLID_PARTNAME_Q235
CASTING_PARTNAME_QT500
SEAM_T2.0
```

Material assignment replaces an existing material suffix when it matches a key from `config/materials.txt`.

### Module Configuration

`config/materials.txt` is a pipe-delimited material library:

```text
key|display|density|E|nu|yield|ultimate|note
Q235|Q235|7.85e-9|210000|0.30|235|370|steel
```

The `Edit TXT` command in Material Assignment edits this file directly.

`config/seam_rules.txt` stores seam defaults such as maximum projection gap, topology stitch tolerance, and component grouping mode.

`config/*_state.txt` files are generated automatically. They remember workflow UI settings such as selected options, text fields, and numeric fields for the next run. Model-specific entity selections are not stored because component, element, line, and surface IDs are not stable between models.

`config/mesh_rules.txt` stores default sheet-metal BatchMesh parameters, such as target/min/max element size, `params_generate_mode`, `no_geomcleanup`, whether BatchMesh's default washer handling is disabled, surface batch size, and washer hole detection range. Geometry is not modified by default, HyperMesh/Tk message updates are kept enabled, BatchMesh runs in small surface batches, and only 6-30mm holes are detected.

`config/casting_mesh_rules.txt` stores casting mesh defaults, including solid deletion while keeping boundary surfaces, small pinhole/fillet cleanup thresholds, tria surface mesh size, 2D quality iteration count, raw `*tetmesh` strings, and 3D quality summary criteria. The default flow deletes selected solid CAD entities while keeping their boundary surfaces, cleans small surface features, creates a tria shell mesh, and runs TetraMesh volume fill after the shell quality gate.

`config/geometry_cleanup_rules.txt` stores chamfer/recess cleanup defaults. The default entry needs one selected face: Auto mode first tries HyperMesh fillet recognition and adjacent small-face chaining for solid chamfer/fillet cleanup, then attempts solid recreation from closed bounds when possible. When that does not match or fails, it treats the face as a recessed pocket floor and performs surface-only cleanup: remove the floor and outer wall faces, create a fill surface from the upper outer boundary plus inner boundary loops, and stitch it back to retained inner wall surfaces.

`config/washer_rules.txt` stores sheet-metal hole washer rules. The current defaults are extracted from the provided standard image:

```text
D < 6mm       ignore after meshing; geometry is not modified
6 < D <= 9    washer: hole_density=8,  layers=2, widths=4,6
9 < D <= 13   washer: hole_density=10, layers=2, widths=4,6
13 < D <= 20  washer: hole_density=12, layers=2, widths=6,8
20 < D <= 30  washer: hole_density=16, layers=2, widths=8,8
D > 30mm      keep
```

### Seam Workflow

`Seam Surface Creation` runs after midsurface extraction and before meshing/RBE2 creation.

- `Line-Surface`: selects one source line and one target midsurface. The source line is sampled and projected to the selected surface, and the seam is created only between the source span and its matching projected span.
- `Line-Line`: selects two boundary lines and creates the seam only over their nearest overlapping span. This is the normal mode for L-type welds and direct edge-to-edge bridge welds.
- Closed-loop source lines are sampled as circular sequences, so a valid seam span may cross the 0/1 parameter break without being split.
- The output component is `SEAM_Tx`, where `x` is the thinner `_T` value read from the two adjacent component names.
- If thickness cannot be read from `_T`, the module asks for a manual value.

### Notes

- The scripts target HyperMesh 2019 Tcl/Tk.
- Normal Tcl interpreters can source the files for syntax checks, but HyperMesh commands only run inside HyperMesh.
- Workflow module windows use `Back to Home` to return to the main launcher. Press `Esc` to close the current module window.
