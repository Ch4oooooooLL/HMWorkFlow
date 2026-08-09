# 壳 Washer 孔 RIGIDS 验证模型（Shell Washer-Hole RIGIDS）

`generate_fem.py` 生成一个 OptiStruct/HyperMesh 可导入的 `.fem`（纯 Python 标准库，
便携运行时 Python 3.8 可直接运行），覆盖壳孔 RIGIDS（shell_washer_hole_rbe2）模块
的完整识别矩阵：多尺寸 washer 孔、椭圆长孔、RBE3 变体、以及小孔/大孔/已有
RIGIDS/贴边孔/矩形孔的拒绝与跳过行为。

## 生成

在仓库根目录执行：

```powershell
runtime\python\windows-x64\python.exe examples\WasherHoleRBE2_Validation\generate_fem.py
```

产物：`WasherHoleRBE2_Validation.fem` + `WasherHoleRBE2_Validation_manifest.json`
（gitignore，不入库）。

## 模型结构

8 组场景沿全局 X 轴排布；壳组件命名 `A1_...`~`A8_...`。孔边节点数与 washer 层宽
严格遵循 `config/washer_rules.txt`：D6-9→8 节点+4,6 层、D9-13→10 节点+4,6 层、
D13-20→12 节点+6,8 层、D20-30→16 节点+8,8 层。网格 10,976 节点 / 12,738 壳单元
（CQUAD4 + CTRIA3），washer 孔共 69 个。

| 场景 | 结构 | 预期 |
|---|---|---|
| C01 | D8/D12/D18/D26 圆形 washer 孔阵列（覆盖 4 个 washer 区间） | 36 孔识别 + 创建 36 个 RBE2 |
| C02 | 椭圆长孔（长短轴 2:1，20 节点） | 4 孔按 OVAL 识别 + 创建 4 RBE2 |
| C03 | 同 C01 布局，运行于 rigidType=RBE3 | 24 孔 → 24 个 RBE3 |
| C04 | 失败：D4 小孔（< 6 mm 下限） | 0 候选（DIAMETER_RANGE 拒绝） |
| C05 | 失败：D40 大孔（> 30 mm 上限） | 0 候选（拒绝） |
| C06 | 跳过：预置 RBE2（依赖节点 = 孔环 + washer 环） | 1 孔 → SKIP_EXISTING 不重复建模 |
| C07 | 边界：孔距板边 8 mm（washer 环被裁剪） | 观察行为，拒绝原因以实际日志为准 |
| C08 | 失败：矩形孔 30x6（长宽比 5.1 > 3.5） | 0 候选（NOT_CIRCULAR_OR_OVAL） |

## HyperMesh 2019 / 2022 验证步骤

1. OptiStruct profile 导入 `WasherHoleRBE2_Validation.fem`。
2. 打开「壳孔 RIGIDS / Shell Washer-Hole RIGIDS」：
   - 选 `A1_WASHER_ARRAY` 组件 → 预期识别 36 孔并创建 36 个 RBE2（输出
     `AUTO_RBE2_A1_WASHER_ARRAY`）；
   - 选 `A2_OVAL_HOLES` → 4 个椭圆孔 RBE2；
   - 选 `A3_RBE3_ARRAY` 并将刚性类型切到 RBE3 → 24 个 RBE3；
   - 选 `A6_EXISTING_RBE2` → 孔被跳过（防重复）；
   - 选 `A4`/`A5`/`A8` → 不产生候选；`A7` → 记录实际拒绝原因。

3. 对照 manifest 的 `holes` 字段核对孔中心坐标、孔径与 washer 密度。

### 负向场景应观察到的行为

- **C04/C05**：孔径超出 6-30 mm 过滤区间，模块不识别。
- **C06**：依赖节点集与既有 RBE2 一致 → SKIP_EXISTING。
- **C08**：矩形孔长宽比超过 `MAX_OVAL_AXIS_RATIO`，判为非圆/非椭圆。

## 与既有示例的关系

- `examples/ShellWasher_RBE2_Bolt_Chain/` 是 768 孔 4 层性能模型（压力测试）；
  本模型场景更全（含失败/跳过/边界形态），用于功能验证。
- 输出组件命名遵循 `AUTO_RBE2_<source>` 约定。

该 FEM 用于识别与流程验证，不是生产求解模型。
