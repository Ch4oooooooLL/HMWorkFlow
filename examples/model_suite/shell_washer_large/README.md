# Shell Washer-Hole RIGIDS — Large Validation Model

## 用途
`ShellWasher_Large.fem` 用于 `shell_washer_hole_rbe2`（壳孔 RIGIDS）的大规模
验收/拒绝矩阵验证，规模约 **8 万单元 / 400 孔**，远超原 36 孔样例。

## 场景（按组件）
| 组件 | 内容 | 预期 |
|---|---|---|
| V01_WASHER_ARRAY_T1.5 | 12x10=120 孔，D8/D12/D18/D26 循环（各 30） | 创建 120 个 RBE2 |
| V02_OVAL_RBE3_T1.5 | 24 圆孔 + 24 椭圆长孔（2:1） | 创建 48 个 RIGID（RBE2 或切 RBE3） |
| V03_SPECIAL_T1.5 | 4 特殊孔（D4/D40/矩形/贴边）+ 3 预置 RBE2 + 24 正常 | 24 创建 + 3 跳过 + 4 拒绝 |
| V04_PERF_T1.5 | 16x12=192 孔 D12 | 创建 192 个 RBE2（性能压测） |
| AUTO_RBE2_V03_SPECIAL_T1.5 | 预置 RBE2 输出组件 | 供 SKIP_EXISTING 检测 |

## 操作
1. HyperMesh 导入 `ShellWasher_Large.fem`。
2. 选择组件（可全选 4 块板），模块默认参数（孔径 6~30、RBE2、DOF 123456）。
3. 执行创建；核对各组件输出 `AUTO_RBE2_<组件>` 的 RBE2 数量与拒绝日志。
4. 对 V02 可切 rigidType=RBE3 再跑一次。

## 设计说明
- washer 环密度严格按 `config/washer_rules.txt`（8/10/12/16 节点，层宽 4,6 / 4,6 / 6,8 / 8,8）。
- 贴边孔（V03 第 8 列）washer 环被板边截断 → 应被外环校验拒绝。
- 预置 RBE2 依赖节点 = 孔环 + 第一层 washer 环，模块应识别为 SKIP_EXISTING。
- 单元尺寸 3.75~10mm 渐变，无零面积/退化单元（生成时自检）。
