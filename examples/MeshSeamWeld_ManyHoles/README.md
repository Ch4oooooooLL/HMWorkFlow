# Mesh Seam Weld 大量闭合边界性能模型

`generate_fem.py` 生成一个 OptiStruct/HyperMesh 可导入的 `.fem`：

- 上层 `PERFORATED_SOURCE_SHELL`：已有 `CQUAD4` 网格；每个孔具有真正位于圆周上的孔边节点，并通过环形四边形过渡区接回外围规则网格。每个孔都是独立、闭合、流形的自由边环。
- 下层 `COMPLETE_TARGET_SHELL`：完整规则网格，位于上层下方，作为所有孔环共同的 imprint/焊缝目标组件。
- 两层节点互不共享，默认间距为 8 mm。
- 同时生成 JSON 清单，记录参数、孔位置、单元数量和实际校验出的闭合自由边环数量。

## 生成默认性能模型

在仓库根目录执行：

```powershell
runtime\python\windows-x64\python.exe examples\MeshSeamWeld_ManyHoles\generate_fem.py
```

默认模型为 1800 x 1200 mm、5 mm 背景网格，包含 30 x 20 = 600 个大小圆孔。每个圆孔默认使用 40 段圆周边和 2 层径向过渡网格。脚本会在写出前验证上层确实存在 600 个孔环；外轮廓不计入孔数。

## 调整负载

例如生成一个较小的 120 孔模型：

```powershell
runtime\python\windows-x64\python.exe examples\MeshSeamWeld_ManyHoles\generate_fem.py `
  --output temp\MeshSeamWeld_120.fem `
  --manifest temp\MeshSeamWeld_120_manifest.json `
  --width 1000 --height 600 --mesh-size 5 `
  --holes-x 15 --holes-y 8 --min-radius 5 --max-radius 18
```

常用参数：

- `--holes-x` / `--holes-y`：孔阵列列数和行数，总孔数为两者乘积。
- `--min-radius` / `--max-radius`：名义孔半径范围；实际边界是规则网格形成的阶梯状闭环。
- `--mesh-size`：两层平面的网格尺寸。
- `--gap`：两层平面间距。
- `--seed`：控制孔径分布；相同参数与 seed 会得到相同模型。
- `--clearance`：相邻圆孔过渡方区之间的最小间距。参数不足以保持过渡区独立时脚本会直接报错。
- `--circle-segments`：每个圆孔的圆周分段数，必须至少为 16 且能被 8 整除；越大越接近圆形，但模型规模也越大。
- `--radial-layers`：圆孔边到规则背景网格之间的径向四边形过渡层数。

## 在 Mesh Seam Weld 中测试

1. 导入生成的 `.fem`，确认求解器模板为 OptiStruct。
2. 在上层每个待测孔环上选择一个种子节点；这些种子彼此不连续，因此模块进入批量闭环模式。
3. 目标组件只选择 `COMPLETE_TARGET_SHELL`。圆形源边界投影到下层规则网格后，会触发局部 imprint 和 remesh，因而能覆盖本性能测试关注的重画开销。
4. 记录从提交到完成的耗时，并核对完成提示中的闭合边界数、新建焊缝单元数。

建议先用 20~100 个种子做冒烟测试，再逐步增加到 600 个。该模型主要用于闭合边界批处理速度测试，不用于求解结果验证。
