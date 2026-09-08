# batch_property_assignment — 大模型验证（50 组件 / 按名建 PSHELL）

## 用途
`BatchProperty_50comp.fem` 用于 `batch_property_assignment` 的名称→属性批量赋值：
按 `Vxx_Part_T<厚度>_<材料>` 解析 → PSHELL(<材料>_T<厚度>)；SEAM 名 → SEAM_Txx
（材料固定 Steel）；含 BEAM/RBE/BUSH/SPRING 的 1D 名、空组件、已有属性组件 → 跳过；
无法解析 → 建空 collector `PROPERTY_REVIEW__<原名>`（assembly `PROPERTY_ASSIGNMENT_REVIEW`）。

## 场景（50 组件 / 每板 6×8=48 单元，10mm 网格）
| 类别 | 数量 | 示例 | 模块预期 |
|---|---|---|---|
| 有效普通件 | 25 | `V01_PANEL_T1.0_Q355`、`V02_BRACKET_T1.02_STEEL`（Q355/STEEL/Q235/AL6061） | PSHELL(材料_T厚度) |
| SEAM 件 | 8 | `SEAM_T1.5`、`V26_SEAM_T1.0_Q355` | PSHELL(STEEL_T1.5)（材料固定 Steel） |
| 无法解析 | 5 | `V31_PART_T`、`V32_PART`、乱名 | 建 `PROPERTY_REVIEW__*` collector |
| 1D 名 | 6 | `BEAM_X`、`RBE_Y`、`BUSH_Z`、`SPRING_W`、`BEAM2`、`RBE3_A` | 跳过（名称含 BEAM/RBE/BUSH/SPRING） |
| 空组件 | 4 | `EMPTY_01`~`EMPTY_04`（无单元） | 跳过 |
| 已有属性 | 2 | `V41_PROP_T2.0_Q355`（预置 PSHELL） | 跳过 |

## 操作（重要：运行模块前先解除属性）
1. HyperMesh 导入 `BatchProperty_50comp.fem`（所有组件自带同 id PSHELL，导入后单元归属正确）。
2. 模块要求输入组件**无属性**（有属性会跳过）——导入后运行 `setup.tcl`
   （best-effort：全选组件 → `*propertyupdate` 清空属性，**保留
   `V41_PROP_T2.0_Q355` / `V42_PROP_T2.5_STEEL` 两个组件不动**，
   它们验证"已有属性跳过"路径；若命令不生效请用 GUI：Model Browser
   全选组件 → 属性列清空）。
3. batch_property_assignment 选择全部组件运行。
4. 核对：25 个普通件按名字建 `材料_T厚度` PSHELL；8 个 SEAM 记为 STEEL；5 个无法解析进
   `PROPERTY_REVIEW__*`；6 个 1D + 4 空 + 2 已属性被跳过；`PROPERTY_ASSIGNMENT_REVIEW`
   assembly 由模块自建。

## 设计说明
- 组件带同 id PSHELL 是 .fem 导入归属的必要条件（HyperMesh 按"属性→同 id 组件"
  分配单元，属性 id ≠ 组件 id 时单元落入 misc）；模块的"无属性输入"状态由
  setup.tcl 在导入后一步达成。
- `PROPERTY_ASSIGNMENT_REVIEW` assembly 与 `PROPERTY_REVIEW__*` collector 为 HM 专属实体，
  .fem 不持久化，由模块在运行期自建（无需 setup.tcl）。
- 规模自检：50 组件、2208 单元；manifest 记录每组件期望行为与分类计数。
