# RIGIDS 螺栓连接验证模型（RIGIDS Bolt Connector）

`generate_fem.py` 生成一个 OptiStruct/HyperMesh 可导入的 `.fem`（纯 Python 标准库，
便携运行时 Python 3.8 可直接运行），覆盖 RIGIDS Bolt Connector（rbe2_bolt_connector）
模块的完整分组逻辑：同轴平面 RBE2 链、多直径、空间型拒绝、偏移超差、单环孤立、
offsetTol 边界。FEM 只含 `GRID` + `RBE2`（模块读取的卡片）。

## 生成

在仓库根目录执行：

```powershell
runtime\python\windows-x64\python.exe examples\BoltConnector_Validation\generate_fem.py
```

产物：`BoltConnector_Validation.fem` + `BoltConnector_Validation_manifest.json`
（gitignore，不入库）。生成器内置仓库 `rbe2_bolt_connector` Python pipeline 的
验证调用，`--verify` 模式会加载模块源码断言每个场景的分组与拒绝原因。

## 模型结构

6 组场景（组件 `B1_`~`B6_`）；每个 RBE2 的依赖节点为 8 节点平面环（半径按螺栓头
washer），或 8 角点立方（空间型）。共 171 节点 / 19 个 RBE2。默认参数：
`axisMode=AUTO`、`gapTol=100`、`offsetTol=5`、`minGroupSize=2`、`elemType=CBEAM`、
`radialAbsTol=0.5`、`radialRelTol=0.08`、`planeAbsTol=0.5`、`planeFlatRatio=0.12`。

| 场景 | 结构 | 预期 |
|---|---|---|
| C01 | 同轴平面 RBE2 链（4 环 z=0/20/40/60，D16，间距 20） | 1 组 → 3 段 CBEAM，组件 `BOLT_D16_CBEAM` |
| C02 | 多直径：D12 组 + D20 组 | 2 组 → 4 段螺栓，`BOLT_D12_CBEAM`/`BOLT_D20_CBEAM` |
| C03 | 失败：空间型（8 角点立方）同轴 RBE2 对 | 分组成功但 plan 拒绝 SPATIAL_ONLY → 0 螺栓 |
| C04 | 失败：横向偏移 10 mm（> offsetTol 5）的两平面 RBE2 | 不分组 → 0 螺栓 |
| C05 | 失败：孤立单一平面 RBE2 | 低于 minGroupSize 2 → 不分组 |
| C06 | 边界：偏移 5.0 mm（匹配 → 1 段）与 5.1 mm（不匹配 → 0 段） | 1 段螺栓，验证 offsetTol 边界 |

## HyperMesh 2019 / 2022 验证步骤

1. OptiStruct profile 导入 `BoltConnector_Validation.fem`。
2. 打开「螺栓连接 / RIGIDS Bolt Connector」，选择全部 RBE2 组件，
   参数 `axisMode=AUTO`、`gapTol=100`、`offsetTol=5`、`elemType=CBEAM`。
3. 对照 manifest 各 case：C01 预期 1 组 3 段、C02 预期 2 组 4 段；
   C03~C05 不产生螺栓（拒绝原因见运行日志）；C06 只有偏移 5.0 的一对成组。
4. 直径推导：C01 按依赖环半径 8 mm → 直径 16（向下取偶）；核对组件名
   `BOLT_D16_CBEAM` 与属性材料自动创建/复用。

### 负向场景应观察到的行为

- **C03**：`pair_planner` 拒绝 `SPATIAL_ONLY`（无平面 RBE2 的组）。
- **C04**：`grouping.matches` 的 `offsetTol` 横向偏移检查不通过 → 不分组。
- **C05**：组内成员数 < `minGroupSize` 2 → 丢弃。
- **C06**：`transverse_offset <= offsetTol`（5.0 边界）精确匹配，5.1 拒绝。

该 FEM 用于识别与流程验证，不是生产求解模型。
