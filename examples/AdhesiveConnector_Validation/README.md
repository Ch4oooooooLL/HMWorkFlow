# Adhesive Connector（打胶）组合验证模型

## 生成命令

```powershell
.\runtime\python\windows-x64\python.exe .\examples\AdhesiveConnector_Validation\generate_fem.py
```

依赖：仅 Python 3.8+ 标准库，确定性（无随机数），可在无 HyperMesh 的机器上完整运行并自检。
脚本在生成前会对每个场景做投影自检（复刻 `modules/adhesive_connector.tcl` 中
`cleanLocationElemsFallback` 的取样点、点内测试与 tolerance 判定），校验不通过则 `raise ValueError`。

产物（`.fem` / `_manifest.json` 已 gitignore，不入库）：

- `AdhesiveConnector_Combined_Validation.fem`
- `AdhesiveConnector_Combined_Validation_manifest.json`

## 模型结构

单一 FEM、OptiStruct bulk 格式、单位 mm/N/MPa。8 个场景沿全局 X 依次排布（场景间距 ≥ 300 mm，
互不干扰），场景编号即组件名前缀 `A0x_`。每个场景由两块平行壳板 + 一个独立的打胶区域
（glue PATCH）组件构成，PATCH 位于两板中间平面（与 `runtime/adhesive_probe_model.fem` 的
参考几何一致）：

- 壳网格：10 mm 规则 CQUAD4（板 200~500 mm、数百至千余单元，禁止单单元代表整板）；
- 打胶条带：多单元条带（矩形 / L 形 / 全宽贴边等），位于 gap/2 平面；
- 每个 CQUAD4 节点仅属于一块板，胶区单元与板单元不共享节点；
- 组件命名：`A0x_PLATE_*`（目标板）、`A0x_LOCATION*`（打胶区域）。

## 导入与操作步骤（HyperMesh 2019，OptiStruct profile）

1. 新建 HyperMesh 2019 会话，切到 OptiStruct profile，File → Import 导入 FEM。
2. 打开「打胶连接 / Adhesive Connector」面板（主面板 → Adhesive Connector）。
3. 按 manifest 每个 case 的 `component_names` 依次操作：
   - 点「选择 elems + comps」；
   - 先选 `*_LOCATION*` 组件的打胶单元（elems，中键确认）；
   - 再选两个目标 `*_PLATE*` 组件（comps，中键确认）；
   - 保持默认参数：Tolerance=50、Coats=1、厚度类型 CONST_THICKNESS、厚度 1.0；
   - 点「创建打胶」。
4. 对照 manifest 的 `expected_results`（kept/rejected 单元数、连接器数量）与模块消息/弹窗验证。

## 预期结果（对照 manifest）

| case | 场景 | 操作选择 | 预期结果 |
| --- | --- | --- | --- |
| A01 | 矩形打胶带（间隙 2 mm，完整落在目标板） | loc=103，links=101,102 | 保留 240/240 单元，realize 成功，RBE3+HEXA8 |
| A02 | L 形打胶带（L 形目标板） | loc=203，links=201,202 | 保留 120/120 单元，realize 成功 |
| A03 | 多胶带（同一 loc 连 3 个 link） | loc=304，links=301,302,303 | 保留 240/240，link 数=3，realize 成功 |
| A04 | 小间隙变体（0.5 mm 与 3 mm 各一对） | 两对分别运行 | 各保留 192/192，均 realize 成功 |
| A05 | 胶区越界（80 mm 悬出目标板） | loc=503，links=501,502 | 保留 256/384，剔除 128 个越界单元，realize 仍成功 |
| A06 | 间隙过大（150 mm > tolerance 50） | loc=603，links=601,602 | 清洗后 0 单元，弹窗 "No elements remain after cleaning"，不创建 |
| A07 | 胶区贴边（与目标板边缘平齐） | loc=703，links=701,702 | 边界样本被 epsilon 容差接受，保留 512/512，realize 成功 |
| A08 | 空 location 组件（只选 links） | 仅选 801,802，不选 elems | picker 拒绝："请选择 location 单元和至少两个目标组件"，模型不改 |

## 失败形态的验证方式

- **A05 越界**：创建成功的消息/弹窗会显示「保留 256 个 location 单元；清洗 128 个」。
  被剔除单元不会传给 HyperMesh，连接器只在足印内生成。
- **A06 间隙过大**：出现警告弹窗「No elements remain after cleaning...」，不创建连接器，
  Model Browser 无新增 Connector/comp。
- **A08 空 location**：选择面板提示「请选择 location 单元和至少两个目标组件」，无任何模型修改。
- 判定标准：模块不崩溃、明确拒绝/剔除、消息中的 kept/rejected 数量与 manifest 一致。

## 边界与注意事项

- 该 FEM 仅用于识别与流程验证，不是生产求解模型。
- A05 的越界量、A06 的间隙、各场景 kept/rejected 数量均由生成器内置的投影自检锁定
  （与 `cleanLocationElemsFallback` 同款算法），实机 HyperMesh 行为应与其一致。
- 连接器 realize（RBE3 + HEXA8 adhesives）依赖实机 HyperMesh 2019/2022 的 connector
  命令链，需在实机环境复核；`module_status.json` 中 adhesive_connector 已标记 verified。
