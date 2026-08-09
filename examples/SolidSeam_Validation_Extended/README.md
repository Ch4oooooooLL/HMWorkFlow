# Solid Seam 扩展验证模型（Extended Validation）

`generate_fem.py` 生成一个 OptiStruct/HyperMesh 可导入的 `.fem`（纯 Python 标准库，
便携运行时 Python 3.8 可直接运行），覆盖实体焊缝（Solid Seam Connector）的完整接头
分类与全部负向控制场景。模型基于 `examples/SolidSeam_Validation/` 的既有验证模型扩展，
场景数 13（原 12），额外覆盖 LAP/BUTT/ANGLED 明确分类、90° 折角链拆分、亚最小焊缝长度。

## 生成

在仓库根目录执行：

```powershell
runtime\python\windows-x64\python.exe examples\SolidSeam_Validation_Extended\generate_fem.py
```

产物：`SolidSeam_Extended_Validation.fem` + `SolidSeam_Extended_Validation_manifest.json`
（gitignore，不入库）。

## 模型结构

13 组场景沿全局 X 轴排布，场景间距 320 mm；所有实体为多体单元板件（板厚方向
2~5 层），壳为目标面规则多单元网格。焊缝处组件间不共享节点（装配语义）。
默认间隙 5 mm；实体验证规则：完整投影必须落在目标壳面内（T 型）或按场景设计。

| 场景 | 结构 | 预期接头类型 | 预期候选 |
|---|---|---|---|
| S01 | CHEXA 立板 + 壳底板 | T_JOINT | 2 |
| S02 | 两层水平实体板 40x40 搭接 | LAP_JOINT | 1 |
| S03 | 两块垂直板 1 mm 间隙端对端 | BUTT_JOINT | 1 |
| S04 | 水平板 + 30° 斜板 | ANGLED_JOINT | 1 |
| S05 | 实体基板 + 实体立板 | T_JOINT | 2 |
| S06 | 水平实体板 + 壳（闭合周界，`max_chain_turn_angle_deg=100`） | 闭合环 | 1（closed） |
| S07 | 2 实体立板 × 1 壳 | 2×T | 4 |
| S08 | CTETRA 水平板 + 壳（默认转角限制→周界拆为 4 边） | SOLID_SHELL | 4 |
| S09 | CPENTA+CPYRA 混合板 + 壳 | SOLID_SHELL | 4 |
| S10 | 失败：立板与壳间隙 60 mm（> `max_search_distance` 25） | 无候选 | 0 |
| S11 | 失败：同一组件混有实体+壳单元 | BLOCKED（识别不启动） | — |
| S12 | 失败：立板底边 12 mm（< `min_weld_length` 20） | 无候选 | 0 |
| S13 | L 形折角立板（90° 转角 > `max_chain_turn_angle_deg` 60 → 链拆分） | 2 段候选 | 2 |

`expected_results` 为拓扑预测值，实际候选数以 HyperMesh 2019/2022 运行结果为准
（manifest 中 `warning` 字段同义说明）。

## HyperMesh 2019 / 2022 验证步骤

1. OptiStruct profile 导入 `SolidSeam_Extended_Validation.fem`。
2. 打开「实体焊缝 / Solid Seam Connector」，按 manifest 各 case 的
   `component_names` 选择组件对。
3. S06 使用默认设置并在面板将 `max_chain_turn_angle_deg` 改为 `100`
   （其余场景用默认参数）。
4. 对照 manifest 的 `expected_mode`、`expected_results` 检查候选数量与
   接头类型；创建后确认 `SEAM_SOLID` 组件中 PENTA6 + RBE3 的数量与
   `realization_result.json`、`operation.log`。

### 负向场景应观察到的行为

- **S10**：无候选（gap 60 mm 超出 `max_search_distance` 25）。
- **S11**：组件 1101 被标记为 MIXED，流程在选择阶段即拦截，不进入检测。
- **S12**：12 mm 短边被 `min_weld_length` 过滤，无候选。
- **S13**：默认参数下 L 形链在 90° 折角处拆分为 2 段候选；若把
  `max_chain_turn_angle_deg` 提高到 100，两段会合并为一条 L 链。

## 与既有 SolidSeam_Validation 的区别

- 新增明确的 LAP（S02）、BUTT（S03）、ANGLED（S04，30° 斜板）分类场景；
- 新增亚最小焊缝长度（S12）与折角链拆分（S13）边界场景；
- S09 在一个组件内混合 CPENTA 与 CPYRA 单元，检验混合单元集合分类；
- 其余场景类型与先例一致（T 型、闭合环、CTETRA、超距、混合组件拦截）。

该 FEM 用于识别与流程验证，不是生产求解模型。PENTA + RBE3 创建配置已在
HyperMesh 2019.0.0.70 / OptiStruct profile 中完成批处理验证。
