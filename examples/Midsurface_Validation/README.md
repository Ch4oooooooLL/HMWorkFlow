# Midsurface 抽中面 + BOM 材料赋予 验证模型

本目录为 HMWorkFlow 的 **Midsurface Extraction（抽中面）** 与
**BOM Material Assignment（读取 BOM 表 / 材料赋予）** 模块提供验证模型，覆盖正常、
失败/边界场景。产物仅供识别与流程验证，**不是生产求解模型**。

## 生成命令与依赖

在仓库根目录执行：

```powershell
# STEP 几何（需系统 Python + cadquery 2.8.0；已安装于 user site）
python .\examples\Midsurface_Validation\generate_geometry.py

# FEM 对照（纯标准库，用便携 python3.8 运行）
.\runtime\python\windows-x64\python.exe .\examples\Midsurface_Validation\generate_fem.py
```

两个脚本均确定性、幂等（可重复运行；manifest 会合并且不产生重复 case）。
产物 `.step`、`.fem`、`*_manifest.json` 均在 `.gitignore` 中，不入库；只提交两个
生成器脚本与本 README。

产物：

| 文件 | 内容 |
| --- | --- |
| `Midsurface_SheetMetal_8Parts.step` | 8 件实体钣金/非钣金 STEP 装配，沿 X 轴排布 |
| `Midsurface_Imported_State.fem` | 模拟"已抽中面完成、MIDSURFED 收纳"的壳模型 |
| `Midsurface_Validation_manifest.json` | 14 个 case（G01~G08 + B01~B06）与统计 |

## 模型结构

### STEP 几何（抽中面输入）

8 个实体，间距 ≥ 300 mm，沿 +X 依次为：

| case | 组件名 | 尺寸/特征 | 厚度来源（期望） | 预期行为 |
| --- | --- | --- | --- | --- |
| G01 | `V01_PANEL_T1.5` | 平直板 200x120x1.5 | name-tag `_T1.5` | 正常：抽中面成功，厚度取名称标记 |
| G02 | `V02_BRACKET_T2.0` | L 形翻边板 150x100x2.0 + 高 100 翻边 | name-tag `_T2.0` | 正常：两平面中面 |
| G03 | `V03_REINF_T1.0` | 板 180x120x1.0 + 中央加强筋 180x12x12 | name-tag `_T1.0` | 正常：中面厚度 1.0，token 规范化为 `T1` |
| G04 | `V04_STEP_T1.2` | 台阶板，两级 1.2 平板 + 15 高竖筋 | name-tag `_T1.2` | 正常：含台阶特征的中面 |
| G05 | `V05_ARC_T1.5` | 四分之一圆弧弯板，R80、厚 1.5、宽 120 | name-tag `_T1.5` | 正常：弯曲件中面 |
| G06 | `V06_WEDGE` | 楔形变厚件，厚度 5→25（无 `_T` 标记） | measure（变厚） | 边界：厚度不唯一，模块行为需实机观察 |
| G07 | `V07_BLOCK` | 厚实块 60x40x35（非钣金） | 无 | 失败/边界：不应产出有意义中面 |
| G08 | `V08_PLATE_HOLES_T1.0` | 板 240x160x1.0，8 个 Ø12 通孔 | name-tag `_T1.0` | 边界：孔环应保留在中面曲面上 |

### FEM 对照（BOM 材料赋予输入）

6 个壳组件，均按抽中面后的命名约定，模拟已存在于 **MIDSURFED** assembly 中：

| case | 组件名 | 期望行为 |
| --- | --- | --- |
| B01 | `V01_PANEL_T1.5` | 无材料后缀 → 创建 Q355，名称加 `_Q355` |
| B02 | `V02_BRACKET_T2.0_Q355` | 已带 `_Q355` → 名称不变（skip/unchanged），材料仍赋予 |
| B03 | `V03_REINF_T1.0` | 无材料后缀 → 名称规范化为 `V03_REINF_T1_Q355` |
| B04 | `V04_NO_THICKNESS` | 名称无法解析厚度 → 仍赋 Q355，**列入复核** |
| B05 | `V05_ARC_T1.5_STEEL` | 带材料后缀 STEEL → 替换为 `V05_ARC_T1.5_Q355` |
| B06 | `V08_PLATE_HOLES_T1.0` | 无材料后缀 → 名称规范化为 `V08_PLATE_HOLES_T1_Q355` |

FEM 中**故意不预定义 Q355 材料**（只有 `STEEL`），因此第一次运行 BOM 模块必须走
“创建材料”路径，第二次运行走“复用材料”路径，可验证幂等性。

## HyperMesh 2019 操作步骤

### 抽中面（Midsurface Extraction）

1. HyperMesh 2019 OptiStruct profile，File → Import → Geometry，导入
   `Midsurface_SheetMetal_8Parts.step`（组件名按 STEP 中的 name 读入，
   即 `V01_PANEL_T1.5` 等）。
2. 打开“抽中面 / Midsurface Extraction”。
3. 选择实体几何组件（建议先选 G01~G05、G08 正常件；G06/G07 单独观察）。
4. 默认参数运行。预期：
   - 输出组件命名 `Vxx_件号_T厚度`，如 `V01_PANEL_T1.5`（G03/G08 的
     `T1.0` 规范化为 `T1`）；
   - 全部输出组件并入 **MIDSURFED** assembly；源实体组件被隐藏。
5. 对照 Model Browser 与 manifest：G01~G05、G08 应 created；
   G06 期望测量到变厚并打中位数/相对离散度警告（或 `TUNKNOWN` 回退）；
   G07 非钣金件可能不产出有效中面，模块应报错跳过（计入 skipped，不崩溃）。

### BOM 材料赋予（BOM Material Assignment）

1. 新建/载入 HyperMesh 模型，导入 `Midsurface_Imported_State.fem`。
2. 在 Model Browser 中创建 **MIDSURFED** assembly，把 6 个壳组件加入
   （HyperMesh assembly 不随 bulk 文件持久化；也可先导入 STEP 走一遍抽中面，
   让模块自动建 MIDSURFED，再把本 FEM 的壳组件并入）。
3. 打开“读取 BOM 表 / 材料赋予”，确认目标 Assembly 为 MIDSURFED、默认材料 Q355，
   点击“应用 Q355”。
4. 预期：
   - 新建 `Q355` MAT1 材料并赋给全部 6 个组件；
   - B01/B03/B06 名称追加 `_Q355`（`T1.0`→`T1`）；B02 名称不变；B05 尾部 `STEEL`
     被替换为 `Q355`；B04 名称追加 `_Q355`；
   - 再次运行应 unchanged（幂等，复用已存在的 Q355）。
5. 对照 manifest B01~B06 的 `expected_results.final_name` 逐条核对。

## 失败/边界形态验证

- **G06 楔形变厚件**：无 `_T` 标记，模块走测量路径。若中面拓扑/曲面厚度值离散度
  超过 `variableThicknessTol`（默认 0.05），日志出现 relative spread 警告并使用
  中位数；若完全测不到厚度，`formatThicknessToken` 输出 `TUNKNOWN` 后缀。记录实机行为。
- **G07 厚实块**：非钣金，`midsurface_extract_10` 可能不产出有效中面；此时
  `processComponent` 报错、计入 `stat(skipped)`，模块继续处理下一件并给出汇总，
  不应崩溃。
- **B04 无厚度名称**：BOM 模块 v0.1 不拒绝，仍赋 Q355 并追加后缀；厚度缺失应由
  下游属性赋予模块列入复核清单，本验证只确认不崩溃、可核对日志。
- **B02 重复运行**：第二次运行名称 unchanged、材料复用，验证防重复。

## 边界与注意事项

- `.step` 几何由 cadquery 按精确尺寸构造，体积/中面面积测厚理论值即标注厚度
  （如 G01 = 36000/24000 = 1.5），可复核体积法。
- G06 变厚件与 G07 厚实块的行为依赖 HyperMesh `midsurface_extract_10` 的实机表现，
  脚本与 manifest 已给出期望与观察点，实机验证后应更新本 README 的"记录实机行为"结论。
- 本模型仅用于识别/流程验证，非生产求解模型。
