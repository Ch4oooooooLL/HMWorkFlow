# 实体孔 RIGIDS 验证模型（Solid Through-Hole RIGIDS）

`generate_fem.py` 生成一个 OptiStruct/HyperMesh 可导入的 `.fem`（纯 Python 标准库，
便携运行时 Python 3.8 可直接运行），覆盖实体孔 RIGIDS（auto_hole_rbe2）模块的
识别/拒绝/观察矩阵：规则圆柱贯通孔、多孔径、沉孔、倒角孔、长圆孔、盲孔、
已有 RIGIDS 跳过、40° 斜孔。

## 生成

在仓库根目录执行：

```powershell
runtime\python\windows-x64\python.exe examples\SolidHoleRBE2_Validation\generate_fem.py
```

产物：`SolidHoleRBE2_Validation.fem` + `SolidHoleRBE2_Validation_manifest.json`
（gitignore，不入库）。

## 模型结构

8 组场景沿全局 X 轴排布（间距 400 mm）；实体板为 120x120 mm 多单元 HEXA/CPENTA
网格，孔壁为 16 节点圆柱环（环间径向过渡 5/12/22/34 mm），板厚 40 mm（6 层）。
共 31,072 节点 / 32,896 体单元。孔壁节点全部精确落在圆柱面上，自由面圆柱拟合
余量充足（径向偏差 < cylFitTol 0.25）。

| 场景 | 结构 | 预期 |
|---|---|---|
| C01 | 同轴双层板 2x(4x4=16) 个 D16 贯通孔阵列 | 32 个候选 RBE2（每板 16） |
| C02 | D10 / D16 / D24 单孔板 | 3 个候选 |
| C03 | 沉孔：上段 D18 + 下段 D10，锥环过渡 | 自适细分恢复 2 段圆柱 → 2 个候选（观察） |
| C04 | 45° 倒角贯通孔 D16 | 自适细分恢复圆柱壁 → 1 个候选（观察） |
| C05 | 失败：长圆孔（圆角矩形，非圆柱面） | CYLINDER_FIT 拒绝 → 0 候选 |
| C06 | 观察：未贯通盲孔（平底） | 孔壁识别为 D12 圆柱 → 1 候选；孔底端面拒绝 |
| C07 | 跳过：预置 RBE2（依赖节点 = 孔壁 96 节点） | SKIP_EXISTING 不创建 |
| C08 | 失败：40° 斜孔（法线与轴夹角 > loopNormalTolDeg 35） | LOOP_NORMAL_MISMATCH → 0 候选 |

## HyperMesh 2019 / 2022 验证步骤

1. OptiStruct profile 导入 `SolidHoleRBE2_Validation.fem`。
2. 打开「实体孔 RIGIDS / Solid Through-Hole RIGIDS」，按 manifest 的 cases 选择组件：
   - `B1_THROUGH_ARRAY_L1`/`L2` → 每板 16 孔，共 32 RBE2；
   - `B2_D10`/`B2_D16`/`B2_D24` → 各 1 RBE2（孔径正确）；
   - `B3_COUNTERBORE` → 观察自适细分恢复 2 段圆柱；
   - `B4_CHAMFER` → 观察恢复圆柱壁；
   - `B5_SLOT`/`B8_TILTED_40` → 0 候选（拒绝原因见日志）；
   - `B6_BLIND` → 1 候选（孔壁）+ 孔底端面拒绝；
   - `B7_EXISTING_RBE2` → 跳过。
3. 模块使用的临时 `^faces` 组件应在运行后自动清理。

### 负向/观察场景应观察到的行为

- **C03/C04**：自适应细分（featureAngleDeg 78° 向下扫描）恢复子圆柱，日志含
  ADAPTIVE_PATCH_REFINEMENT 警告。
- **C05**：长圆孔径向偏差超 cylFitTol → CYLINDER_FIT；细分后子面片
  BOUNDARY_LOOP_COUNT:1。
- **C06**：盲孔孔壁两端环（孔口 + 孔底边）→ 仍识别为圆柱；孔底平端面拒绝。
- **C08**：|dot|=cos40°=0.766 < cos35°=0.819 → LOOP_NORMAL_MISMATCH。
  （30° 斜孔 |dot|=0.866 在容差内会被接受，可作对照。）

## 与既有示例的关系

- 与 `examples/ShellWasher_RBE2_Bolt_Chain/` 互补：那是壳 washer 链路压力模型，
  本模型聚焦实体贯通孔的识别/拒绝矩阵。
- 输出组件命名遵循 `AUTO_RBE2_<source>` 约定。

该 FEM 用于识别与流程验证，不是生产求解模型。
