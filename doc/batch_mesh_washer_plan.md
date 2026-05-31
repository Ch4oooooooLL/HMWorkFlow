# BatchMesh 与 Washer 自动生成方案

## 目标

使用 HyperMesh Tcl 将网格划分、孔识别、washer 生成和质量优化串成可配置流程：

```text
选择 midsurface/surface/component
  -> BatchMesh 自动划分
  -> 识别圆孔及孔径
  -> 按孔径规则生成 washer
  -> 质量检查与局部优化
  -> 输出日志和失败清单
```

核心目标不是只调用一次 BatchMesh，而是让网格结果满足项目标准：全局网格尺寸、质量指标、孔周 washer 层数、孔周节点数、层宽、是否删除小孔等都能由规则控制。

## 可行性判断

该方案可行。HyperMesh Tcl 提供了足够的基础能力：

- `*hm_batchmesh2`：对 surfaces/components 调用 BatchMesh，并支持自动生成或使用 criteria/parameter 文件。
- `*batchmesh_mc`：基于 mesh controls 批处理网格划分，适合更复杂的区域化规则。
- `hm_ce_gethmholes`：从 components 中按孔径范围识别 bolt holes，返回孔中心和孔周节点。
- `*add_multi_washer_elements`：对 shell mesh 圆孔生成多层 washer，可控制层数、孔周密度和层宽。
- Element quality 系列命令：可用于质量检查、局部移动节点、修改 hole/washer 或做 cleanup 会话。

因此建议采用“BatchMesh 负责基础网格，Tcl 规则层负责孔周 washer 和迭代优化”的结构，而不是完全依赖 BatchMesh 默认 washer。

## 推荐流程

### 1. 基础 BatchMesh

对选定 midsurface 或 shell surface 执行 BatchMesh。为了后续自己按规则生成 washer，建议第一版关闭 BatchMesh 默认 washer，同时避免小孔被自动删除：

```tcl
*createmark surfs 1 $surfaceIds
*createstringarray 2 \
    "elem_size = 5.0 min_elem_size = 2.5 max_elem_size = 8.0 params_generate_mode = shell no_washer = 1 no_remove_holes = 1" \
    "batchtempfilesmode = 1"
*hm_batchmesh2 surfs 1 1 2 "dummy" "dummy"
```

实际实现时，`elem_size`、`min_elem_size`、`max_elem_size` 和 `params_generate_mode` 应来自配置文件或 UI。

### 2. 孔识别

使用 `hm_ce_gethmholes` 按孔径范围识别孔：

```tcl
*createmark comps 1 $compIds
set holes [hm_ce_gethmholes 1 $maxDia $minDia 0 0 0]
```

返回结果包含 component id、孔中心、孔周节点。后续可以按孔径规则分桶处理。

### 3. 按孔径生成 washer

对每个孔径区间读取规则，然后调用 `*add_multi_washer_elements`：

```tcl
*createmark nodes 1 $holeNodeIds
*createstringarray 2 \
    "layer_number = 2 uniform_layers = 1 hole_density = 12" \
    "1 2.0"
*add_multi_washer_elements 1 30 1 2 0 0 0 1
```

可控项包括：

- `layer_number`：washer 层数。
- `uniform_layers`：各层宽度是否一致。
- `hole_density`：孔周方向密度，通常对应孔周一圈节点/单元数量。
- `width_flag`：层宽解释方式，`1` 表示绝对宽度，否则按孔半径比例。
- `width_value`：每层宽度或宽度比例。
- `feature_angle`：washer 附近 feature line 判定角度。
- `rigid_spider`：是否同时创建 rigid spider。
- `local_coordinate_system`：是否创建孔平面局部坐标系。

注意：标准 `*add_multi_washer_elements` 支持控制整体孔周密度，但不直接支持“第一层 8 点、第二层 12 点、第三层 16 点”这种逐层不同圆周节点数。如果必须逐层不同，需要自定义更复杂的过渡网格逻辑。

### 4. 质量检查与迭代优化

建议先使用全局 quality criteria 生成失败清单，再对失败区域做局部处理：

```tcl
*set_default_quality_criteria 5.0
*createmark elems 1 "by comp id" $compId
*getqualitysummary 1 $summaryFile 2 0
```

对于孔周问题，可考虑：

- 提高 `hole_density`。
- 增加 washer 层数。
- 调整每层宽度。
- 局部重建 washer。
- 使用 element quality cleanup 命令移动节点或修改 hole/washer。

Element quality 命令通常需要在 `*elementqualitysetup` 和 `*elementqualityshutdown` 会话内运行，自动化难度高于重新按规则生成 washer。第一版建议优先采用“识别失败 -> 调整规则 -> 重建局部 washer/局部 remesh”的方式。

## 建议规则文件

可以扩展当前 `config/washer_rules.txt`，让它从占位配置变成真正驱动网格和 washer 的规则表：

```text
hole_dia_min|hole_dia_max|action|elem_size|washer_layers|hole_density|width_mode|widths|note
0|5|delete|4|0|0|none||small holes
5|8|washer|4|2|8|ratio|0.35,0.45|small bolt holes
8|12|washer|5|2|12|ratio|0.30,0.40|normal bolt holes
12|20|washer|6|3|16|abs|2.0,2.5,3.0|large bolt holes
20|999|review|8|3|20|abs|3.0,3.5,4.0|manual review
```

字段含义：

- `hole_dia_min` / `hole_dia_max`：孔径范围。
- `action`：`delete`、`washer`、`keep`、`review`。
- `elem_size`：该孔径范围推荐全局或局部网格尺寸。
- `washer_layers`：washer 层数。
- `hole_density`：孔周方向密度。
- `width_mode`：`abs` 绝对宽度，`ratio` 按孔半径比例。
- `widths`：每层宽度列表。
- `note`：规则说明。

## 可配置项目清单

### BatchMesh 配置

- 目标实体：surfaces、components。
- `elem_size`：目标单元尺寸。
- `min_elem_size`：最小单元尺寸。
- `max_elem_size`：最大单元尺寸。
- `elem_type`：tria、quad、mixed。
- `elem_order`：一阶或二阶。
- `elem_feature_angle`：feature edge 判定角。
- `params_generate_mode`：generic、scale、midmesh、shell、solid。
- `criteria_file`：质量 criteria 文件。
- `param_file`：BatchMesh parameter 文件。
- `no_geomcleanup`：是否跳过几何清理。
- `no_remove_holes`：是否禁止小孔自动删除。
- `no_seed_holes`：是否禁止孔 seed。
- `no_washer`：是否禁止 BatchMesh 默认 washer。
- `breakconnectivity`：是否断开与未选区域的网格连接。

### Washer 配置

- 孔径分档。
- 小孔删除阈值。
- 是否保留无 washer 孔。
- washer 层数。
- 孔周密度。
- 每层宽度。
- 层宽模式：绝对宽度或半径比例。
- feature angle。
- 是否生成 rigid spider。
- 是否创建局部坐标系。

### 质量标准配置

- 最小边长。
- 最大边长。
- aspect ratio。
- warpage。
- skew。
- Jacobian。
- 最小/最大 quad angle。
- 最小/最大 tria angle。
- taper。
- chordal deviation。
- washer 周边专用标准，例如最小 washer 宽度、孔周节点数、层数、圆度。

## 推荐模块设计

建议新增一个模块：

```text
modules/batch_mesh_washer.tcl
config/mesh_rules.txt
config/washer_rules.txt
```

模块入口：

```tcl
::BatchMeshWasher::run
```

内部步骤：

```text
loadRules
pickComponentsOrSurfaces
runBatchMesh
collectHolesByDiameter
applyWasherRules
qualityCheck
iterateLocalFixes
reportSummary
```

输出内容：

- 处理 component/surface 数量。
- 识别孔数量。
- 按孔径分档统计。
- washer 创建数量。
- 删除/跳过/需人工复核的孔。
- 质量失败单元数量和失败原因。
- 每次迭代前后质量变化。

## 实现边界

第一版建议实现：

- BatchMesh 基础配置。
- 按孔径识别圆孔。
- 按规则调用 `*add_multi_washer_elements`。
- 生成日志和失败清单。
- 质量检查但不做复杂自动修复。

第二版再实现：

- 自动调整 washer density/layer width 并重试。
- 对失败孔周做局部 remesh。
- 接入 `*elementqualitysetup` 相关 cleanup 命令。
- UI 中编辑 `mesh_rules.txt` 和 `washer_rules.txt`。

不建议第一版实现：

- 每层不同圆周节点数。
- 任意异形孔自动 washer。
- 沉孔/倒角孔的完全自动规则。
- 复杂多区域 mesh control 自动推断。

这些可以做，但需要更强的几何识别和局部重网格策略，风险和验证成本都更高。

## 参考文档

- Altair HyperMesh Tcl Modify Command: `*hm_batchmesh2`
  https://help.altair.com/hwdesktop/hwd/topics/reference/hm/_hm_batchmesh2.htm
- Altair HyperMesh Tcl Modify Command: `*batchmesh_mc`
  https://help.altair.com/hwdesktop/hwd/topics/reference/hm/_batchmesh_mc.htm
- Altair HyperMesh Tcl Query Command: `hm_ce_gethmholes`
  https://help.altair.com/hwdesktop/hwd/topics/reference/hm/hm_ce_gethmholes.htm
- Altair HyperMesh Tcl Modify Command: `*add_multi_washer_elements`
  https://help.altair.com/hwdesktop/hwd/topics/reference/hm/_add_multi_washer_elements.htm
- Altair HyperMesh Tcl Modify Command: `*elementqualitymodifyhole`
  https://help.altair.com/hwdesktop/hwd/topics/reference/hm/_elementqualitymodifyhole.htm
