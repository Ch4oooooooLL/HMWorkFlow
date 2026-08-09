# 验证模型生成约定（Validation Model Generation Conventions）

本文档定义 HMWorkFlow 各模块验证模型（`examples/<Module>_Validation/`）的生成规范。
所有子代理与后续维护者生成模型时必须遵守。仓库现有先例：`examples/SolidSeam_Validation/`、
`examples/MeshSeamWeld_ManyHoles/`、`examples/ShellWasher_RBE2_Bolt_Chain/`、
`examples/LocalMeshOptimizer_Large_Mixed/`、`examples/AutoShellSeamBackend/`。

## 1. 目录与文件

每个验证场景一个目录：`examples/<ModuleGroup>_Validation/`，包含：

- `generate_fem.py` 或 `generate_geometry.py`：确定性生成器（固定 seed，std 库）。
- `README.md`：中文，说明模型结构、导入/操作步骤、预期结果与失败形态。
- 生成产物：`*.fem`、`*.step`、`*_manifest.json`（gitignore，不入库）。
- 生成器顶部 docstring 注明生成的命令（仓库根目录执行）与依赖。

产物一律 `.gitignore`（`/examples/**/*.fem`、`*_manifest.json`、`*.step`、`*.iges`）。
只提交生成器脚本与 README。

## 2. Python 运行环境

- **网格模型（FEM）生成器**：纯 Python 标准库（Python 3.8+），必须能被便携运行时
  `runtime/python/windows-x64/python.exe`（3.8.10）直接运行。禁止第三方依赖。
- **几何模型（STEP）生成器**：开发期工具，用系统 Python（3.14 + cadquery 2.8.0，
  `import cadquery` 提供 OCCT）。README 必须注明"几何生成需系统 Python + cadquery，产物 .step 为交付物"。
- 生成器必须可在无 HyperMesh 的机器上完整运行并自检。

## 3. FEM 格式规范（OptiStruct bulk）

- 文件结构：`BEGIN BULK` ... `ENDDATA`（末尾空行）。顶部 `$` 注释说明用途与生成脚本。
- 卡片：`GRID`、`CQUAD4`/`CTRIA3`、`CHEXA`/`CPENTA`/`CTETRA`/`CPYRA`、`RBE2`/`RBE3`、
  `CBEAM`/`CBAR`、`CROD`、`MAT1`、`PSHELL`、`PSOLID`、`PBEAM`/`PROD`、`$HMNAME`/`$HWCOLOR`/`$HMCOMP`。
- 行宽遵守 8 字符字段格式（可用 16 位字段放宽，但保持可被 HyperMesh 读取）。
- 组件命名遵循仓库约定：`Vxx_件号_T厚度[_材料]`、`SEAM_Tx`、`AUTO_RBE2_<source>`、
  `BOLT_D12_CBEAM`/`BOLT_D12_PBEAM`、`CBUSH_<source>`、`MIDSURFED` assembly。
- **工程性硬性要求**：
  - 实体件必须由多个体单元组成（板件：多 CHEXA/CTETRA/CPENTA；禁止单个单元代表整板）。
  - 壳件必须为规则多单元网格（禁止单个 CQUAD4 代表整块板）。
  - 模型规模应接近真实零部件级（数百到数万单元），同一 FEM 可含多个隔离场景。

## 4. 生成器自检（必须在脚本内完成）

写文件前校验拓扑与数据，不通过则 `raise ValueError`：

- 自由边环数量与期望一致（壳）；封闭候选环数量与 manifest 一致。
- 单元非退化：四/三角形面积 > 0、无反转、无重复单元。
- 共节点/不共节点关系符合场景设计（焊缝场景两层不共享节点时校验确实无共享）。
- 数值：坐标在期望范围、间隙/孔径与场景定义一致。
- 输出统计（节点/单元/组件数）写入 manifest。

## 5. manifest 结构（schema_version 1.0）

```json
{
  "schema_version": "1.0",
  "purpose": "<模块与用途>",
  "generator": "examples/<dir>/generate_*.py",
  "fem": "examples/<dir>/<name>.fem",
  "parameters": { "<生成参数>" },
  "statistics": { "nodes": 0, "elements": 0, "...": 0 },
  "components": { "<id>": "<NAME>", "...": "" },
  "cases": [
    {
      "case_id": "C01",
      "title": "<场景说明>",
      "component_ids": [101, 102],
      "component_names": ["C01_...", "C01_..."],
      "expected": "<模块应识别的结果描述>",
      "expected_results": {"candidate_count": 0, "...": 0},
      "settings": {"<模块参数>": "<值>"},
      "notes": "<失败形态说明>"
    }
  ]
}
```

## 6. 正常 + 失败模型要求

每个模块的验证目录必须同时覆盖：

- **正常场景**：模块设计意图内的典型输入，应成功产出预期结果（焊缝、RIGIDS、优化、属性等）。
- **失败/边界场景**：模块明确不支持或应被跳过/拒绝的输入，例如：
  - 间隙/距离超过容差（无候选）。
  - 异形孔/沉孔/倒角（实体孔 RBE2 不支持）。
  - 已存在 RIGIDS 的孔（应跳过防重复）。
  - 空间型 RIGIDS 分组（bolt 应跳过）。
  - 名称无法解析（property 分配应列出复核）。
  - 混入不支持单元类型/混合组件（应被拦截）。
- 失败场景的"预期"是：模块不崩溃、明确拒绝/跳过/列入复核，并给出可核对的日志或清单。

## 7. README.md 内容（中文）

1. 生成命令（仓库根目录）与依赖。
2. 模型结构：场景布局、组件/集合/命名。
3. 导入与操作步骤（HyperMesh 2019/2022 OptiStruct profile）。
4. 预期结果：对照 manifest 的 case 逐条说明。
5. 失败形态的验证方式（应看到什么拒绝/跳过行为）。
6. 边界与注意事项（如"仅用于识别/流程验证，非生产求解模型"）。
