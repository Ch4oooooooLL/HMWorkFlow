# Solid Seam 组合验证模型

生成模型：

```powershell
.\runtime\python\windows-x64\python.exe .\examples\SolidSeam_Validation\generate_fem.py
```

脚本会在同一个 `SolidSeam_Combined_Validation.fem` 中生成 12 组互相隔离的验证场景，并同步生成 manifest。模型遵循以下规则：

- T 型场景中，实体板在目标 Shell 平面上的完整投影均位于 Shell 边界内，并留有余量。
- 实体均为板状，两个主要尺寸大于厚度。
- CHEXA、CPENTA、CTETRA、CPYRA 实体均由多个体单元组成。
- Shell 使用规则多单元网格，不使用单个 CQUAD4 代表整块板。
- 默认实体到目标面的间距为 5 mm；不同场景之间的距离大于默认搜索距离。

使用方法：

1. 在 HyperMesh 2019 的 OptiStruct profile 中导入 FEM。
2. 打开“实体焊缝 / Solid Seam Connector”。
3. 按 manifest 中各 case 的 `component_names` 选择组件。
4. 除 C07 外使用默认参数；C07 将 `max_chain_turn_angle_deg` 改为 `100`。
5. 对照 manifest 的 `expected_mode`、`expected_results`、候选节点和运行目录中的 JSON/日志。

模型覆盖单实体 + Shell T 型、双实体 + 公共 Shell、CPENTA + L 截面 Shell、实体四侧 Shell、Solid-Solid、超距无候选、闭合边链、CTETRA、CPYRA、Shell-Shell 拦截、Mixed Component 拦截和多组件矩阵等场景。

该 FEM 用于识别与流程验证，不是生产求解模型。PENTA + RBE3 创建配置已在 HyperMesh 2019.0.0.70 / OptiStruct profile 中完成批处理验证。
