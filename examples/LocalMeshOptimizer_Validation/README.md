# Local Mesh Optimizer（局部网格优化）验证模型

本目录为 `modules/local_mesh_optimizer`（局部网格优化，受控门禁模块）生成大型混合壳单元验证 FEM。
模型以 `examples/LocalMeshOptimizer_Large_Mixed/` 为基准整体重做：同样用规则网格 + 可处理缺陷簇 +
人工失败簇 + washer/RBE2 保护区，但场景矩阵按本目录 README 的 8 个 case 重新设计并全部内嵌生成器自检。

## 生成命令（仓库根目录）

```powershell
runtime\python\windows-x64\python.exe examples\LocalMeshOptimizer_Validation\generate_fem.py
```

生成三个产物（`.gitignore`，不入库）：

- `LocalMeshOptimizer_Validation.fem`：大型 OptiStruct 壳网格（约 2.5 万节点 / 2.4 万壳单元）；
- `LocalMeshOptimizer_Validation_manifest.json`：所有缺陷、washer、RBE2、固定节点的准确 ID；
- `reference.criteria`：供 HyperMesh Criteria Editor 使用的参考标准（字段格式与先例一致）。

可选 `--verify-planner` 会在写 manifest 前调用仓库内 `modules/local_mesh_optimizer/python` 的规划器，
逐组断言规划动作类型与设计一致（切分/短边合并/内部扩展/手动复核/保护）。模型为固定网格布局，
确定性生成，不需要第三方库。

## 模型结构

单位 mm，主网格间距 5.0。布局：

| 区域 | 位置 | 内容 |
| --- | --- | --- |
| 主面板（PROP 1） | x 0..1000, y 0..600 | 规则四边主体 |
| C01 可修复缺陷簇 | 左块三个横向条带 | 100 畸变 quad（扭曲/最小角 <40°）、100 瘦长 tria（双长边比 >=2.5）、100 细长内部 quad（长宽比 >=2.5） |
| C02 窄条协调区 | x 470..490, y 40..290 | 连续 4 列 x 50 行细长窄条带（列宽 0.6 mm） |
| C03 焊缝两侧节点链 | x 25..28, y 0..200 | 窄条 base（1x40）两侧焊接垂直 SEAM_T1 墙 |
| C04 washer+RBE2 | x 1080..1160, y 660..740 | 3 个双层 washer（内孔 8 mm）+ 中心 RBE2 |
| C07 criteria 边界缺陷 | 右块三个条带 + 独立小 tria | 40 边缘 quad、40 边缘瘦长 tria、40 边缘窄 quad、40 孤立小 tria |
| C08 完好区 | x 750..980, y 40..540 | 46x100 规则网格，零缺陷 |
| C05/C06 人工失败簇（PROP 4） | x 1200..1500 | 20 组：零面积 tria/quad、bowtie 自交 quad、重复 quad 对、重叠节点 sliver、RBE2 保护瘦长 tria |

组件：`BASE_AND_AUTOMATIC_DEFECTS`、`SEAM_T1`、`WASHER_RINGS`、`MANUAL_FAILURES`。

## SET3 集合

| SET3 | 类型 | 内容 |
| ---: | --- | --- |
| 1001 | ELEM | 可处理的畸变 quad 切分候选 |
| 1002 | ELEM | 可处理的瘦长 tria 合并候选 |
| 1003 | ELEM | 可处理的细长内部 quad 候选 |
| 1004 | ELEM | 窄条协调带候选（连续 4x50） |
| 1005 | ELEM | 焊缝两侧窄条 base 单元 |
| 1101 | ELEM | washer 壳单元 |
| 1102 | ELEM | washer RBE2 |
| 1201-1206 | ELEM | 各类型人工/不可安全处理缺陷 |
| 1207 | GRID | 建议固定节点（RBE2 关联，40 个） |
| 1208 | GRID | 焊缝线节点（82 个，供"固定焊缝"对比实验） |
| 1301-1304 | ELEM | criteria 边界缺陷（quad/tria/窄quad/瘦长tria） |
| 1305 | ELEM | 完好区（验证不误改） |

## HyperMesh 2019 操作步骤（OptiStruct profile）

1. 导入 `LocalMeshOptimizer_Validation.fem`（File > Import > FE Model，选 OptiStruct）。
2. 打开模块"局部网格优化"，选择 criteria 文件 `reference.criteria`。
3. 选项面板：保持 `EXCLUDE_WASHER_ELEMENTS=1`、`PROTECT_USER_NODES=1`；
   C02/C03/C07 的窄 quad 需要开启 `ALLOW_INTERNAL_QUAD_EXPANSION=1`。
4. 在 "A. 优化范围" 中先把 `SET3 1207` 的节点选为"固定节点"（对应 C06 的 RBE2 保护）。
5. 范围选 `all`，执行模式 `batch`，运行。
6. 观察报告中的候选/失败数量，对照 manifest 的 case 逐条核对；优化结果另存，不要覆盖原 FEM。

## 预期结果（对照 manifest cases）

| case | 预期 |
| --- | --- |
| C01 | 100 畸变 quad → split_quad；100 瘦长 tria → collapse_short_edge；100 细长内部 quad → expand_internal_quad |
| C02 | 窄条带全部获得协调扩展动作（链式支持，含相邻网格单元） |
| C03 | 窄条 base 两侧链扩展（weld_strip_two_side_chain_expansion），端部 2 个短边自由单元列手动复核；若把 SET3 1208 选为固定节点，base 整体转手动复核 |
| C04 | washer 网格被排除在优化范围外，不产出候选，RBE2 不动 |
| C05 | 模块不崩溃；零面积/自交/重复/sliver 缺陷被 prevalidation 拒绝或标记失败，列入复核清单 |
| C06 | 固定节点所在的瘦长 tria 短边不移动（manual_review: skinny_triangle_short_edge_protected） |
| C07 | 边缘超差单元得到对应裁决（切分/合并/扩展/短边外扩） |
| C08 | 完好区无失败单元，不被修改 |

## 失败形态的验证方式

- 零面积 quad（SET3 1202）会触发 `split_would_create_zero_area_triangle` 拒绝记录；
- 重复 quad（SET3 1204）被识别并在操作去重事件中保留来源；
- 自交 bowtie（SET3 1203）与重叠节点 sliver（SET3 1205）按失败操作进入手动复核清单；
- 已固定节点的瘦长 tria（SET3 1206 + 1207 固定）不移动。
- 最终失败集合由 HyperMesh 原生 quality 检查 + criteria 决定，生成器只保证几何/拓扑意图。

## 边界与注意事项

`MANUAL_*` 区域故意包含非法拓扑（零面积、自交、重复、重叠节点），仅用于测试，不能用于生产求解。
最终失败判定以 HyperMesh 为准；`reference.criteria` 供参考，可改用你自己的 criteria 文件。
