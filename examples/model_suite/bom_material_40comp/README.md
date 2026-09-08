# bom_material_assignment — 大模型验证（40 组件 / 统一赋 Q355）

## 用途
`BomMaterial_40comp.fem` + `setup.tcl` 用于 `bom_material_assignment` 的规模验证：
扫描 **MIDSURFED** assembly 内的组件 → 统一赋材料 Q355（`MAT1 E=206000 NU=0.30 RHO=7.85e-9`）、
组件名追加/替换为 `_Q355` 后缀。

## 场景（40 组件 / 每板 8×10=80 单元）
| 类别 | 数量 | 命名 | 模块预期 |
|---|---|---|---|
| 厚度件（目标，入 MIDSURFED） | 30 | `Vxx_Part_T1.0~T3.0`，其中 10 个已带材料后缀（_STEEL/_Q235/_AL6061） | 已带后缀 → 替换为 `_Q355`；无后缀 → 追加 `_Q355` |
| 无厚度件（目标） | 5 | `V21_PART`~`V25_PART`（不含 _T） | 列入复核清单但照常赋 Q355 → `_Q355` |
| 焊缝件（非目标） | 5 | `SEAM_T1.0`~`SEAM_T3.0`（在 MIDSURFED 外） | **不处理** |

## 操作
1. HyperMesh 导入 `BomMaterial_40comp.fem`，然后运行 `setup.tcl` 重建 **MIDSURFED**
   assembly 并把 35 个目标组件加入（`*createentity assemblies name=MIDSURFED` +
   `*assemblyaddmembers MIDSURFED comps <ids>`）。
   > 若你的 HM 版本命令名不符，请手工在 Model Browser 建 MIDSURFED assembly 并把
   > 35 个目标组件拖入（见 manifest target_components）。
2. 运行 bom_material_assignment（目标：MIDSURFED assembly）。
3. 核对 35 个目标组件统一赋 Q355 且名字尾随 `_Q355`；5 个 SEAM 组件保持不动。

## 设计说明
- assembly 是 HM 专属实体，.fem 不持久化 → 必须用 setup.tcl 在每次导入后重建。
- 10 个已带非 Q355 材料后缀的组件用于验证"材料后缀替换"逻辑。
- 5 个无厚度件验证复核路径；5 个 SEAM 件验证 assembly 外组件不处理。
- 规模自检：40 组件、3200 单元、目标/非目标清单与 `_Q355` 期望写入 manifest。
