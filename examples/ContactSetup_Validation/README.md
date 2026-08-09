# Contact Setup（接触创建）组合验证模型

## 生成命令

```powershell
.\runtime\python\windows-x64\python.exe .\examples\ContactSetup_Validation\generate_fem.py
```

依赖：仅 Python 3.8+ 标准库，确定性（无随机数），可在无 HyperMesh 的机器上完整运行并自检。
脚本内置 `selectNearestContactFaces` 的复刻（质心双向邻近筛选、bboxGap、medianSpan、
searchTol = max(gap + 2.5*medianSpan, 2.5*medianSpan)），为每个场景预测 kept 单元数、
搜索容差、主面与 CONTACT 类型，校验不通过则 `raise ValueError`。

产物（`.fem` / `_manifest.json` 已 gitignore，不入库）：

- `ContactSetup_Combined_Validation.fem`
- `ContactSetup_Combined_Validation_manifest.json`

## 模型结构

单一 FEM、OptiStruct bulk 格式、单位 mm/N/MPa。8 个场景沿全局 X 依次排布（场景间距 ≥ 300 mm），
场景编号即组件名前缀 `B0x_`。每个场景是一对或多对平行/偏移/倾斜壳板：

- 壳网格：10 mm 规则 CQUAD4，单板 300x200 ~ 500x300 mm、600~1500 单元；
- 相向对（B01/B02/B03/B04/B06/B07）：A 板朝 +Z，B 板朝 -Z（法向相对）；
- B05 背向对：两块板法向同为 +Z（法向不相向）；
- B08 斜对置：B 板绕 Y 轴转 20°，中心 z=50 mm，左端下倾到 z≈-18.4 mm、右端升到 z≈118.4 mm；
- 相邻场景 pitch ≥ 400 mm，跨场景质心距离 ≥ 100 mm > 搜索容差（≈40 mm），不会跨场景匹配。

## 导入与操作步骤（HyperMesh 2019，OptiStruct profile）

1. 新建 HyperMesh 2019 会话，切到 OptiStruct profile，File → Import 导入 FEM。
2. 打开「Contact Setup」面板（主面板 → Contact Setup）。
3. 按 manifest 每个 case 的 `component_names` 选择：
   - 点「分两次选择 Face」；
   - 第一侧选 A 组件面（原生 Face 选择器，中键确认）；
   - 第二侧选 B 组件相向面（中键确认）；
   - 接触类型选 manifest `settings.contact_type`（默认 STICK），主面 AUTO，结果名前缀默认
     `AUTO_CONTACT`，勾选「创建接触 group」；
   - 点「创建接触」。
4. 对照 manifest 的 `expected_results`（kept_A/kept_B、搜索容差、group 名）与模块状态消息验证。

## 预期结果（对照 manifest）

| case | 场景 | 操作选择 | 预期结果 |
| --- | --- | --- | --- |
| B01 | 大面积平行对（500x300、间隙 5 mm、完全对位） | A=101，B=102 | 公共区域 A=1500/1500、B=1500/1500，1 个 STICK group |
| B02 | 部分重叠对（面内重叠 40%） | A=201，B=202 | 公共区域 A=720、B=720（重叠区+邻近余量），1 个 STICK group |
| B03 | STICK / SLIDE / FREEZE 三类型 | 三对分别运行（每对选对应类型） | 3 个 group，CONTACT_PROP_TYPE=1/0/2 |
| B04 | 多对同时（4 对） | 一次全选 A 面（401..407）+ B 面（402..408） | 公共区域 2400/2400，1 个 group（主/从 SURF 各含 4 块板） |
| B05 | 背向面（两法向同为 +Z） | A=501，B=502 | 仍创建 1 个 group：反向标记 A=0/B=1，表面被导向相向 |
| B06 | 超距（间距 100 mm） | A=601，B=602 | 仍创建 1 个 group：searchTol = 100 + 35.4 = 135.4 mm |
| B07 | 两遍相同单元 | A 与 B 均选同一组件（701） | validateSelectedFaces 拒绝「两次选择包含相同单元」，0 个 group |
| B08 | 斜对置（20°） | A=801，B=802 | 1 个 group，公共区域 A=480、B=480，法向夹角 20° |

## 失败形态的验证方式

- **B07 两遍相同单元**：点「创建接触」立即弹错「两次选择包含相同单元 <id>；请分别选择相向的
  两侧。」，不创建任何 SURF/group，模型不改。
- **判定标准**：模块不崩溃；正常场景的公共区域 kept 数与 manifest 一致；失败场景明确拒绝并给出
  可核对日志。

## 边界与注意事项

- **法向与筛选逻辑（重要）**：模块的公共区域筛选只按单元质心距离（双向邻近），不校验法向。
  因此：
  - B05（法向同向）和 B06（100 mm 超距）都会被处理并创建 group——`referenceOrientations`
    按中心连线点积计算反向标记把表面导向相向；搜索容差随 bbox 间距自适应增长。
  - 若预期"背向/超距不创建接触"，需要在模块中增加法向相向预检或固定最大搜索距离，本场景
    用于如实记录当前行为，可作需求变更的对照。
- B04 逐对运行 4 次会得到 4 个 group；一次性全选 A/B 得到 1 个 group（主/从 SURF 各含 4 板）。
- 该 FEM 仅用于识别与流程验证，不是生产求解模型；SURF/CONTACT 创建链
  （`*contactsurfcreatewithshells`、`*dictionaryload SURF`、CONTACT group）需在实机
  HyperMesh 2019/2022 OptiStruct profile 中复核。
