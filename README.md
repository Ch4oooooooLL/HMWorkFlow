# HyperMesh Toolkit

Tcl/Tk toolkit for HyperMesh 2019 preprocessing. The toolkit provides a single launcher for component setup, material tagging, midsurface extraction, geometry cleanup, seam-surface creation, sheet-metal meshing, washer generation, RBE2 creation, and bolt connector generation.

默认界面语言为中文。可在项目根目录的 `config.yaml` 中将 `workflow.language` 切换为 `en_US`。

## 启动方式

在 HyperMesh 中运行：

```text
File > Run > Tcl/Tk Script > hw_toolkit.tcl
```

运行后打开 `HyperMesh Toolkit` 主面板。主面板中的 `刷新浏览器` 按钮用于强制恢复 Model Browser 更新并刷新图形窗口，不改变已有 component 的显示/隐藏状态。

## 配置

项目根目录的 `config.yaml` 保存全局配置：

```yaml
workflow:
  language: zh_CN
```

支持值：

| 值 | 说明 |
| --- | --- |
| `zh_CN` | 简体中文界面。 |
| `en_US` | 英文界面。 |

模块配置位于 `config/`：

| 文件 | 用途 |
| --- | --- |
| `materials.txt` | 材料标识库。 |
| `mesh_rules.txt` | Sheet BatchMesh 默认参数。 |
| `washer_rules.txt` | 孔径与 washer 规则。 |
| `seam_rules.txt` | Seam Surface Creation 默认参数。 |
| `geometry_cleanup_rules.txt` | Geometry Cleanup 默认参数。 |
| `casting_mesh_rules.txt` | Casting TetraMesh 默认参数。 |
| `*_state.txt` | 模块 UI 状态缓存，由脚本自动生成。 |

## 目录结构

```text
.
|-- hw_toolkit.tcl
|-- config.yaml
|-- config/
|   |-- casting_mesh_rules.txt
|   |-- geometry_cleanup_rules.txt
|   |-- materials.txt
|   |-- mesh_rules.txt
|   |-- seam_rules.txt
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
    |-- shell_washer_hole_rbe2.tcl
    `-- rbe2_bolt_connector.tcl
```

## 模块

| 主面板名称 | 入口 | 说明 |
| --- | --- | --- |
| Component Type Classification | `::CompWorkflow::runCategory` | 将组件分类为 `SHELL`、`SOLID`、`CASTING`，并规范化名称。 |
| Material Assignment | `::CompWorkflow::runMaterial` | 从 `materials.txt` 分配材料标识，并组织材料装配。 |
| Midsurface Extraction | `::MidSurf::run` | 抽取钣金中面，并按 `CATEGORY_NAME_Tx_MATERIAL` 命名输出组件。 |
| Geometry Cleanup | `::GeomCleanup::run` | 处理倒角、圆角和沉台连接等几何清理任务。 |
| Seam Surface Creation | `::SeamSurf::run` | 通过线-面或线-线方式创建 `SEAM_Tx` 焊缝面。 |
| Sheet BatchMesh + Washer | `::BatchMeshWasher::run` | 执行 Sheet BatchMesh，并按孔径规则生成 washer。 |
| Casting TetraMesh | `::CastingTetMesh::run` | 执行铸件 surface 清理、三角面网格质量迭代和 TetraMesh。 |
| Shell Washer Hole RBE2 | `::RB2W::run` | 识别壳单元 washer 孔并创建 RBE2。 |
| Solid Through-Hole RBE2 | `::AutoHoleRBE2::run` | 识别实体网格圆柱贯通孔并创建 RBE2。 |
| RBE2 Bolt Connector | `::RB2Bolt::run` | 对 RBE2 中心节点分组，并创建 CBEAM/CBAR 螺栓连接段。 |

## 使用教程

### Component Type Classification

用于建立组件类型前缀，并将组件归入对应装配。

1. 在主面板中运行 `Component Type Classification`。
2. 在 `Category` 中选择 `SHELL`、`SOLID` 或 `CASTING`。
3. 点击 `选择组件`，在 HyperMesh 中选择需要分类的 component。
4. 点击 `应用类型`。

输出结果：

- 组件名称会被替换为对应类型前缀，例如 `SHELL_PARTNAME`。
- 组件会加入对应类型装配。

### Material Assignment

用于给已分类组件追加或替换材料标识。

1. 在主面板中运行 `Material Assignment`。
2. 从材料列表中选择材料 key。
3. 点击 `选择组件`，选择已经带有 `SHELL`、`SOLID` 或 `CASTING` 前缀的 component。
4. 点击 `应用材料标识`。

输出结果：

- 组件名称会追加或替换材料后缀，例如 `SHELL_PART_T2.0_Q235`。
- 组件会加入材料装配，例如 `SHELL_Q235`。
- 材料库来自 `config/materials.txt`，可通过模块中的 `编辑 TXT` 修改。

### Midsurface Extraction

用于从钣金几何中抽取中面。

1. 在主面板中运行 `Midsurface Extraction`。
2. 点击 `选择/重选组件`，选择需要抽中面的几何 component。
3. 检查抽取参数，例如对齐步数和中面位置。
4. 点击开始执行。

输出结果：

- 生成新的 midsurface component。
- 输出 component 按 `CATEGORY_NAME_Tx_MATERIAL` 命名。
- 命名厚度优先读取源 component 名称中的 `_Tx`；名称中没有厚度时先读取中面拓扑点的厚度数据，仍不可用时按实体体积/中面面积自动测量，不要求用户输入。
- 所有输出 component 统一放入名为 `midsurf` 的 assembly，并隐藏对应的源实体 component。
- 源几何保留并隐藏。

### Geometry Cleanup

用于处理倒角、圆角和沉台清理。

1. 在主面板中运行 `Geometry Cleanup`。
2. 检查清理参数，例如圆角半径范围、缝合容差和邻接扩展层数。
3. 点击“进入连续清洗”。
4. 在 HyperMesh 选择面板中选择一个倒角面、圆角面或沉台底面，按中键执行。
5. 当前面处理完成后继续选择下一个面；取消选择时退出连续清洗。

输出结果：

- 对匹配的 solid 倒角/圆角执行清理。
- 对沉台面识别一个内边和一个外边，沿外边找到小竖直面及其与基准平面相连的基准边。
- 删除沉台面和小竖直面后，直接在内边与基准边之间创建连接面，并与孔壁、基准平面缝合。
- 沉台处理任一步失败时撤销本次几何修改。
- 连续处理期间不显示独立进度条，也不会因单次处理完成或失败而退出工具。
- 清理完成后刷新 Model Browser 和图形窗口。

### Seam Surface Creation

用于创建焊缝几何面。

1. 在主面板中运行 `Seam Surface Creation`。
2. 选择模式：
   - `Line-Surface`：先选择源线，再选择投影目标面。
   - `Line-Line`：依次选择两条焊缝边界线。
3. 检查最大对应间隙、特征转角、基础采样分段数和 equivalence 容差。
4. 点击“进入连续创建”。
5. 每次创建完成后继续选择下一条线或下一组线；在任一选择面板按 `ESC` 退出。

输出结果：

- 生成 `SEAM_Tx` component。
- `x` 优先取相邻 component 名称中较薄的 `_T` 厚度。
- 若厚度无法读取，会提示手动输入。
- 线-面模式先生成贴合目标面的投影线并 trim 目标面，再以原始线和投影线创建 ruled 焊缝。
- 两种模式都会识别两侧端点和曲率特征点，建立一一对应的 linking coordinates，并按特征连接线分段生成焊缝面。
- 每次完成后对焊缝面及两侧接触面强制执行 equivalence；失败时撤销本次几何修改并继续等待下一次选择。
- 连续创建期间不显示进度条，也不会在单次完成或失败后退出。

### Sheet BatchMesh + Washer

用于对钣金中面或壳组件执行 BatchMesh，并按孔径规则生成 washer。

1. 在主面板中运行 `Sheet BatchMesh + Washer`。
2. 点击 `选择/重选组件`，选择钣金中面或壳网格 component。
3. 检查网格尺寸、孔径识别范围和 washer 批量参数。
4. 确认 `config/washer_rules.txt` 中的孔径规则符合当前项目标准。
5. 点击开始执行。

输出结果：

- 对选中 component 执行 BatchMesh。
- 识别指定孔径范围内的孔。
- 按规则忽略小孔、保留大孔或生成 washer。
- 生成运行统计，包括孔数量、washer 创建数量和失败数量。

### Casting TetraMesh

用于铸件几何的 surface 清理、三角面网格和 TetraMesh。

1. 在主面板中运行 `Casting TetraMesh`。
2. 点击 `选择/重选组件`，选择铸件几何 component。
3. 检查删除 solid、surface 清理、三角面网格和 TetraMesh 选项。
4. 检查质量 criteria、cleanup 参数和 `*tetmesh` 参数。
5. 点击开始执行。

输出结果：

- 可删除 solid 并保留边界 surface。
- 可清理小孔、小圆角等微小特征。
- 创建三角面网格并进行 2D 质量迭代。
- 质量通过后执行 TetraMesh 体网格填充。

### Shell Washer Hole RBE2

用于在壳单元 washer 孔位置创建 RBE2。

1. 在主面板中运行 `Shell Washer Hole RBE2`。
2. 点击 `选择/重选组件`，选择已经带有标准 washer 网格的壳 component。
3. 检查孔径范围、圆度/椭圆容差、washer 节点圈数和 RBE2 自由度。
4. 选择执行模式：
   - `开始创建 RBE2`：只对未创建过 RBE2 的孔创建。
   - `重建模式`：先删除已有输出 component，再重新创建。
   - `合并重复节点`：清理输出 component 中重复 RBE2 的中心节点和重复单元。
5. 点击对应按钮执行。

输出结果：

- 每个源 component 对应一个 `AUTO_RBE2_<source>` 输出 component。
- RBE2 只移动到输出 component，不移动源节点。
- 模块会检查已有 RBE2，避免重复创建。

### Solid Through-Hole RBE2

用于识别实体网格圆柱贯通孔并创建 RBE2。

1. 在主面板中运行 `Solid Through-Hole RBE2`。
2. 点击 `选择/重选组件`，选择实体网格 component。
3. 检查光顺面片角度、圆柱拟合容差、端部环容差和孔半径范围。
4. 设置结果 component 名称。
5. 点击开始执行。

输出结果：

- 模块会生成临时自由面 component，识别孔壁面片。
- 对有效贯通孔创建中心节点和 RBE2。
- 输出到指定结果 component。
- 运行结束后可自动删除临时自由面 component。

### RBE2 Bolt Connector

用于根据 RBE2 中心节点创建 CBEAM/CBAR 螺栓连接段。

1. 在主面板中运行 `RBE2 Bolt Connector`。
2. 选择 RBE2 来源：
   - `elements`：直接选择 RBE2 单元。
   - `components`：选择包含 RBE2 的 component。
3. 设置搜索轴向、最大轴向连接距离、横向中心偏移容差和最小分组数量。
4. 选择输出类型 `CBEAM` 或 `CBAR`。
5. 可先勾选预览模式检查分组，再取消预览创建连接段。
6. 点击确定执行。

输出结果：

- 对符合条件的 RBE2 中心节点分组。
- 沿识别轴向连接相邻 RBE2。
- 输出 component 按孔径和单元类型命名，例如 `BOLT_D12_CBEAM`。

## 命名约定

组件名称建议保留流程信息：

```text
SHELL_PARTNAME_T2.0_Q235
SOLID_PARTNAME_Q235
CASTING_PARTNAME_QT500
SEAM_T2.0
```

材料标识模块会识别 `materials.txt` 中定义的材料 key，并替换组件名称中已有的材料后缀。

## Washer 规则

默认 washer 规则位于 `config/washer_rules.txt`：

```text
hole_dia_min|hole_dia_max|action|hole_density|washer_layers|width_mode|widths|note
0|6|ignore|0|0|abs||D < 6mm ignored after meshing; geometry is not modified
6|9|washer|8|2|abs|4,6|6mm < D <= 9mm
9|13|washer|10|2|abs|4,6|9mm < D <= 13mm
13|20|washer|12|2|abs|6,8|13mm < D <= 20mm
20|30|washer|16|2|abs|8,8|20mm < D <= 30mm
30|999|keep|0|0|abs||D > 30mm no special handling
```

## Seam Surface Creation

Seam Surface Creation 位于中面抽取之后、网格划分和 RBE2 创建之前。

- `Line-Surface`：先选择一条源线，再选择目标中面；源线投影并 trim 目标面后，与投影线创建 ruled 焊缝。
- `Line-Line`：依次选择两条边界线，按两侧特征点的一一对应关系创建 ruled 焊缝。
- ruled 使用显式 linking coordinates 在端点和曲率特征点处分段，避免曲线与曲面投影组合时发生扭转。
- 每次创建后对焊缝面和两侧接触面执行跨 component equivalence。
- 工具会连续等待下一次选择，直到用户在选择面板按 `ESC`。
- 输出组件命名为 `SEAM_Tx`，其中 `x` 来自相邻组件名中较薄的 `_T` 厚度值。
- 若无法读取厚度，模块会提示手动输入。

## Model Browser 刷新

脚本创建 component 后会调用统一刷新逻辑：

- 恢复 browser/redraw/message block。
- 停止 browser signal buffer。
- HyperMesh 2019 中优先通过 `hmbr::operation perform hmbr::createonly` 创建新 component，使 Model Browser 同步登记；内部 Browser API 不可用时回退到 `*createentity comps includeid=0 name=...`。
- Shell Washer Hole RBE2 在性能模式下创建输出 component 时会临时恢复 Browser 更新，登记完成后再继续缓冲后续批处理。
- 保持已有 component 的显示/隐藏状态。
- 刷新 Model Browser 和图形窗口。

如果左侧 Model Browser 没有立即显示新 component，可点击主面板中的 `刷新浏览器`。

## Notes

- Target environment: HyperMesh 2019 Tcl/Tk.
- Normal Tcl interpreters can be used for basic syntax checks only. HyperMesh commands must run inside HyperMesh.
- Module windows use `返回主页 / Back to Home` to return to the launcher. Press `Esc` to close the current module window.
