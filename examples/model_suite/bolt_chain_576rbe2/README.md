# Coaxial RBE2 Bolt-Chain — Large Validation Model

## 用途
`BoltChain_576rbe2.fem` 用于 `rbe2_bolt_connector`（RBE2 共轴分组建段）的大规模验证。
四层壳板各带 12x12 预置 RBE2（孔环+第一层 washer 环为依赖、孔中心节点为独立），隔层
120mm 共轴堆叠，576 个 RBE2 折叠成 144 个共轴组，每组 4 个 RBE2 -> 模块应创建 D 段 CBEAM。

## 场景
| 区域 / 组件 | 内容 | 机器预期 |
|---|---|---|
| V01..V04_BOLT_L0..L3_T1.5 | 4 层 x 12x12 孔，孔内预置平面 RBE2 | 144 共轴组 -> 432 段 CBEAM |
| V05_BOLT_NEG_T1.5 | 3 组横向偏移 10mm 的 RBE2 对 + 2 个孤立 RBE2 | 全部拒绝，不建段 |

柱径分配（每个柱四层同径，保证直径投票输出干净的多组件）：
- col 0,6 - D10；col 1,7 - D16；col 2,8 - D22；其余 col 3,4,5,9,10,11 - D12。
- 各产出 `BOLT_D10_CBEAM` / `BOLT_D16_CBEAM` / `BOLT_D22_CBEAM` / `BOLT_D12_CBEAM`。

## 操作
1. HyperMesh 导入 `BoltChain_576rbe2.fem`。
2. 选择 RBE2 或含 RBE2 的组件（默认参数：gapTol=100、offsetTol=5、minGroupSize=2、
   radialAbsTol=0.5/radialRelTol=0.08、elemType=CBEAM、axisMode=AUTO）。
3. 核对：144 组 -> 432 段；按直径分入 4 个输出组件；3 个偏移对与 2 个孤立 RBE2 被拒绝。

## 设计说明
- 预置 RBE2 是**输入**；输出 CBEAM/PBEAM/BOLT_Dxx 组件由模块运行时创建，不在本文件预置。
- 依赖节点 = 孔环 + 第一层 washer 环；独立节点 = 孔中心（浮动 GRID）。
- 只有平面 RBE2 组参与建段；纯空间组被拒绝（SPATIAL_ONLY）。
- washer 密度按 `config/washer_rules.txt`（D10/D12=10 段，D16/D22=12 段）。
