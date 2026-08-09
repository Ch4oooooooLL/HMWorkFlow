# Mesh Seam Weld 验证模型（网格焊缝）

`generate_fem.py` 生成一个 OptiStruct/HyperMesh 可导入的 `.fem`（纯 Python 标准库，
便携运行时 Python 3.8 可直接运行），覆盖网格焊缝（Mesh Seam Weld）的手动路径
（选节点路径 → 投影 → imprint/ruled）与 FAST_AUTO 自动路径（T 型 / 搭接候选）、
去重、以及负向控制场景。

## 生成

在仓库根目录执行：

```powershell
runtime\python\windows-x64\python.exe examples\MeshSeamWeld_Validation\generate_fem.py
```

产物：`MeshSeamWeld_Validation.fem` + `MeshSeamWeld_Validation_manifest.json`
（gitignore，不入库）。

## 模型结构

8 组场景沿全局 X 轴排布，间距 400 mm；壳网格单元 4~5 mm；组件命名
`V01_..._T1.5`（`_T` 厚度标记）。场景内源/目标组件不共享节点（装配语义），
F10 类共享节点负向对照见 `examples/FemAutoSeam_Validation/`。

| 场景 | 结构 | 预期 |
|---|---|---|
| C01 | 源板 120x100 挖 8 个圆孔（r 4~9.5mm）+ 完整目标板 160x120（z=0） | 手动路径：8 个闭合环；FAST_AUTO：8 个闭合环候选（closed_loop） |
| C02 | 源板 100x60 直边开放路径 + 目标板 140x88 | 手动投影 + imprint/ruled；FAST_AUTO 1 候选 |
| C03 | 源板五边形 45° 折线开放路径 + 目标板 140x100 | 手动投影分割；FAST_AUTO 1 候选 |
| C04 | 垂直筋板壳 140x40 + 底板壳 200x140（法向 90°） | FAST_AUTO T 候选（T_PATH），1 |
| C05 | 平行重叠壳板 120x80 @z2 叠在 160x100 @z0（法向 0°） | FAST_AUTO 搭接候选（L_SURF），1 |
| C06 | 失败：源板 80x60 与目标板 100x80 间距 30 mm（> search_distance 12） | 无候选（0） |
| C07 | 失败：翻边自由边合格区 12 mm（< min_seam_length 20） | 候选被丢弃（0） |
| C08 | 边界：V08 筋板源边距预置 `SEAM_T1` 壳带 3 mm（< 4.0 去重距离） | 候选标记 DUPLICATE 转 REVIEW，不重复创建 |

## HyperMesh 2019 / 2022 验证步骤

1. OptiStruct profile 导入 `MeshSeamWeld_Validation.fem`。
2. 打开「网格焊缝 / Mesh Seam Weld」：

   - **C01**：在源板上 8 个孔环各选一个种子节点（彼此不连续 → 批量闭环模式），
     目标组件选 `V01_PlateSolid_T2.0`；预期 8 个闭合边界与 8 条焊缝带。
   - **C02 / C03**：手动选源自由边路径节点 → 目标板 → 投影 + 局部 imprint/remesh →
     Ruled 连接带。
   - **C04 / C05**：FAST_AUTO 路径选择组件对，确认候选后导入现有边创建壳焊缝。
   - **C08**：选择 V08 组件对（不选 SEAM_T1），确认候选被标记为 DUPLICATE
     （去重距离 4.0 mm 覆盖 3 mm 间距）并转入复核表，不会重复创建。

3. 每个闭环独立撤销事务：成功批次可在主面板「撤回」一次恢复。

### 负向场景应观察到的行为

- **C06**：无候选（间距 30 mm 超出 `search_distance` 12）。
- **C07**：12 mm 合格区低于 `min_seam_length` 20，候选被丢弃。
- **C08**：候选虽被识别，但因与既有 SEAM_T1 带过近而转 DUPLICATE/REVIEW。

`expected_results` 为拓扑预测；最终焊缝带数量与质量由 HyperMesh 2019/2022
原生 criteria 裁决。

## 与既有示例的关系

- `examples/MeshSeamWeld_ManyHoles/` 是 600 孔纯性能模型；本模型场景更小但覆盖
  手动 + FAST_AUTO 双路径、去重与负向控制，用于功能验证而非性能。
- 组件命名遵循仓库 `Vxx_件号_T厚度[_材料]` / `SEAM_Tx` 约定。

该 FEM 用于识别与流程验证，不是生产求解模型。
