# Solid Seam 的 HM2019 realization 参数

本文记录 HyperMesh 2019 `penta (mig)` 系列 seam connector 参数的含义，以及模块采用的自适应规则。字段对应关系来自 HM2019 自带连接器脚本和实际 Command File。

## 界面中的主要参数

| 界面参数 | Command File 字段 | 含义与当前策略 |
|---|---|---|
| location: node list | `*createlist nodes` | 焊缝中心线的有序节点。模块会根据目标面法向和实体内部方向自动决定节点顺序。 |
| spacing | `line_spacing` | 沿焊缝重新采样后的 PENTA 间距。取局部边网格尺寸的约 60%，并受焊缝宽度约束。 |
| retain nodes | `line_preserve_nodes` | 是否强制保留原节点位置。默认关闭，让 HM 按 spacing 均匀布置焊缝。 |
| connect what: comps / elems | link mark + `link_elems_geom=elems` | 用两个组件限定连接对象，同时在组件内连接有限元网格。不会搜索第三个组件。 |
| tolerance | `tol` | 连接器寻找两个 link 的最大容差。根据实际间隙、焊缝宽度和局部网格尺寸计算，并受识别最大距离限制。 |
| type | custom config + FE type | T/L/B/普通接头分别使用 HM2019 seam FE type 118/117/119/125。 |
| positive/negative side | `seam_area_group` | PENTA 相对有向焊缝线生成在哪一侧。模块统一使用 positive side，并在必要时反转 node list，使正侧始终朝向实体内部。 |
| width | `ce_fedepth` | HM2019 界面中的 Width 实际写入 `ce_fe_depth`。模块取实体板厚约 80%，同时用局部网格尺寸限制上下界。 |
| right-angled | `ce_fe_tapered_t_input` | 强制使用直角 T 型截面。仅在接近 90°且间隙不超过板厚 25%时开启；普通有间隙 T 型保持关闭。 |
| mesh dependent | `ce_connectivity=2` | realization 依赖现有网格节点。适合当前“实体网格 + Shell 网格”的输入。 |
| adjust realization | connectivity mode 2 | 使用 ensure projection 调整新生成的焊缝，而不重划原始实体或 Shell 网格。 |
| no property | `ce_prop_opt=1`, `ce_propertyid=0` | 不强制分配现有 Property，避免错误继承模型属性。 |

## 自适应计算

模块对每条候选独立计算：

- `mesh_size`：候选边链相邻节点距离的中位数。
- `source_thickness`：对实体组件节点做主方向分析后得到的最小包围尺寸，可处理旋转放置的板件。
- `weld_width`：以 `0.6 × source_thickness` 为基准，并限制在 `0.25～0.8 × mesh_size`；粗网格不会再把焊缝截面放大。
- `line_spacing`：以 `0.5 × mesh_size` 为基准，限制在 `0.65 × weld_width` 到 `1.15 × weld_width`。
- `realization_tolerance`：取“最大实际间隙 + 1.25 × width”和“1.5 × mesh_size”的较大值，但不超过两倍识别最大距离。
- `right_angled`：仅对严格近似直角且小间隙的 T 接头启用。
- `orientation_reversed`：当 positive side 背离实体内部时自动反转节点顺序。

这些值会写入 `candidates.json`、`candidates.tcl`、导出的候选 CSV 和 `operation.log`，便于复核每条焊缝最终采用的参数。

## 输出组件与颜色

所有新生成的 PENTA 和 RBE3 都归并到同一个 `SEAM_SOLID` component。该 component 使用颜色 ID 3（红色），不会再保留灰色的 `Realize...` 临时 component。批量创建完成后，模块会清除 1、2 号工作 mark，原先用于识别的 source/target components 不再保持选择高亮。

## 其他高级字段

`ce_fe_factor_a/b`、edge snapping、offset angle、cap/runoff angle、strips、rows、non-normal projection 等字段沿用 HM2019 手工面板生成的稳定默认值。它们控制投影、端部封口和复杂局部网格处理，不作为第一层几何自适应变量；如果后续质量校验表明某类模型需要专门规则，可以按接头类型扩展 profile，而不修改识别算法。
