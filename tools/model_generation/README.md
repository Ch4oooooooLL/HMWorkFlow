# HMWorkFlow 验证模型生成系统（tools/model_generation）

为 HMWorkFlow 全部 19 个业务模块**全新生成**复杂大型验证模型（2026 重构版，
不复用 examples/ 下旧生成脚本）。系统组成：

| 文件 | 作用 |
|---|---|
| `femlib.py` | OptiStruct bulk-data (.fem) 构建库：节点/单元/组件/材料/属性、washer 环、六面体带孔网格、自由边/质量分析、FEM 写入与回读校验 |
| `steplib.py` | cadquery（OCCT 内核）STEP 生成库：钣金实体（L/Z/U/帽形/阶梯/翻边/圆弧/筋板）、倒角/圆角/沉台块、开放曲面；产品名注入（导入 HyperMesh 后组件名 = 部件名） |
| `common.py` | 输出目录约定（examples/model_suite/）、manifest/README/setup.tcl 写入 |
| `gen_*.py` | 19 个模块各自的模型生成器（见 generate_all.py 清单） |
| `generate_all.py` | 一键全量重建 + 自动生成套件索引 README |
| `model_cli.py` | **交互式 CLI**：便携 Python 驱动生成器，全量/指定模型选择，输出到独立且被 git 忽略的目录 |
| `verify_suite.py` | 全套产物交叉校验（FEM 卡数/STEP 回读/manifest 一致性） |
| `audit_fem_components.py` | **组件归属审计**：校验所有单元都在 `$HMCOMP ID` 段内、且每个被引用的属性 id 都有同 id 组件（HyperMesh 导入按"属性→同 id 组件"分配单元，id 不一致时单元全部落入 misc） |

## 组件归属约定（重要）

HyperMesh 导入 OptiStruct .fem 时，**单元跟随其属性归属组件，属性与组件按同 id 关联**
（`$HMNAME PROP 1001` ↔ `$HMNAME COMP 1001`）。因此：

- 每个组件必须有**独立属性且属性 id == 组件 id**（`femlib.add_component` 自动 rebind，
  并拒绝共享属性）；单元卡第 3 字段引用该 id；
- `$HMCOMP ID` 分组注释保留（RBE2 等无属性单元的分组线索）；
- 属性 id 与组件 id 不一致会导致属性挂到 misc 组件、全部单元随之落入 misc
  （本套件曾出现并已修复，`audit_fem_components.py` 持续防回归）。

## 运行

```text
python tools/model_generation/generate_all.py            # 全量（输出 examples/model_suite/）
python tools/model_generation/generate_all.py --only gen_shell_washer   # 单个

python tools/model_generation/model_cli.py               # 交互式菜单（推荐）
python tools/model_generation/model_cli.py --list        # 列出 19 个生成器
python tools/model_generation/model_cli.py --all         # 全量
python tools/model_generation/model_cli.py --only gen_temp_nodes,gen_midsurf
runtime\python\windows-x64\python.exe tools\model_generation\model_cli.py --all   # 便携 Python 启动

# PowerShell 一键启动（自动选解释器 + UTF-8 控制台）
powershell -ExecutionPolicy Bypass -File tools\model_generation\launch_cli.ps1
.\tools\model_generation\launch_cli.ps1 -List
.\tools\model_generation\launch_cli.ps1 -All -Yes
.\tools\model_generation\launch_cli.ps1 -Only gen_temp_nodes,gen_midsurf
.\tools\model_generation\launch_cli.ps1 -All -Outdir D:\models -Runner system
```

CLI 输出根目录默认 `tools/generated_models/`（与 `tools/model_generation/` 同级的新文件夹，
已被 `.gitignore` 忽略，`/tools/generated_models/`），可用 `--outdir` 覆盖；生成器通过
环境变量 `HMW_MODEL_OUTPUT` 感知输出位置（直接运行 `gen_*.py` 时仍输出到
`examples/model_suite/`，保持旧约定）。解释器策略（`--runner`）：

- `auto`（默认）：15 个 FEM 生成器（纯标准库）用**便携 Python 3.8**
  （`runtime/python/windows-x64/python.exe`）；4 个 STEP 生成器（需 cadquery/OCCT）
  用启动 CLI 的解释器；
- `portable` / `system` / `--python PATH`：强制单一解释器。

输出根目录：`examples/model_suite/<模块>_<场景>/`（模型文件 + `<模型>_manifest.json` + `README.md`）。
全部产物已被 `.gitignore` 覆盖（`/examples/**`、`/tools/generated_models/`），不进入仓库与发布包。

## 设计原则

1. **网格类模块 → .fem**（OptiStruct bulk：GRID/CQUAD4/CTRIA3/CHEXA/CPENTA/CTETRA/
   RBE2/RBE3/CBEAM/CBAR/CBUSH，`$HMNAME COMP/PROP/MAT` 组件命名，`$HMCOMP ID` 分组）；
2. **几何类模块 → .step**（OCCT 精确 B-Rep：实体钣金 / 倒角沉台实体 / 开放曲面；
   每个文件一个实体/面，产品名 = 组件名 Vxx 规范）；
3. **确定性**：无随机数，同一次生成结果逐字节一致（STEP 时间戳归一化）；
4. **规模大**：单模型数万至十余万单元、数百孔/特征，覆盖模块验收/拒绝矩阵的同时压测批量性能；
5. **自检**：每个生成器内置断言（自由边环数、无退化单元、孔壁径向偏差、STEP 回读
   solids/faces 数），失败即报错，防止生成"坏模型"；
6. **HM-only 实体**：assembly（MIDSURFED/USELESS）不随 .fem 持久化，需要时配套
   `setup.tcl` 并在 README 写明手工步骤。

## 模块 → 输入类型 → 生成器

| 模块 | 输入 | 生成器 |
|---|---|---|
| midsurf 抽中面 | STEP 实体钣金 | gen_midsurf.py |
| geometry_cleanup 几何清理 | STEP 倒角/沉台实体 | gen_geom_cleanup.py |
| seam_surface 几何焊缝 | STEP 开放曲面 | gen_seam_surface.py |
| batch_mesher | STEP 曲面 | gen_batch_mesher.py |
| geometry_preprocess / bom / batch_property | FEM 组件 | gen_preprocess / gen_bom_material / gen_batch_property |
| mesh_seam_weld / fem_auto_seam / weld_integrity / local_mesh_optimizer | FEM 壳 | gen_mesh_seam_weld / gen_fem_auto_seam / gen_weld_integrity / gen_local_mesh_opt |
| shell_washer_hole_rbe2 / auto_hole_rbe2 / rbe2_bolt_connector / cbush_creator / batch_temp_nodes / contact_setup / adhesive_connector / solid_seam_connector | FEM | gen_shell_washer / gen_solid_hole / gen_bolt_chain / gen_cbush / gen_temp_nodes / gen_contact_setup / gen_adhesive / gen_solid_seam |

## 单元与命名

- 单位：mm / N / tonne（与 `config.yaml` 一致）；材料 MAT1 钢 E=210000 MPa、nu=0.3。
- 组件命名：`Vxx_件号_T厚度[_材料]`（厚度 token `T1.5` 等）；输出组件按模块约定
  （`AUTO_RBE2_<源>`、`BOLT_Dxx_CBEAM`、`SEAM_Tx`、`SEAM_SOLID`、`CBUSH_<源>`）。
- 装配语义：不同件之间**不共享节点**（焊缝/完整性/连接类模块的触发前提）；
  共享节点的焊接带仅出现在"已焊负向"场景。
