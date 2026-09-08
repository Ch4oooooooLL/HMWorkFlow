# weld_integrity_check — Large Missing-Weld Validation Model

## 用途
`WeldIntegrity_30pairs.fem` 用于 `weld_integrity_check`（漏焊核验）的大规模验证：
T 型漏焊、搭接漏焊、邻近自由边（含 8mm 边界）、已焊忽略、远距不触发、
hub-and-spoke 多组件对。规模 >=2.5 万壳单元 / >=25 组件。

## 场景表
| ID | 类别 | 内容 | 预期 |
|---|---|---|---|
| WT01..WT12 | T 漏焊（12） | 间隙 0.5~4.5mm、接触长 30~140mm | 候选（间隙<=5） |
| WL01..WL08 | 搭接漏焊（8） | 两平行板间隙 0.2~3mm | 候选 |
| WN01..WN06 | 邻近自由边（6） | 间隙 4~8mm，其中 3 组 8mm 边界 | 候选 |
| WD01..WD02 | 已焊（2） | 共享 >=3 节点 SEAM_T 带 | 被忽略（ignore_shared_nodes） |
| WF01..WF02 | 远距（2） | 40mm | 不触发（>5） |
| H01..H02 | hub-and-spoke（2） | 1 中心板邻 4~6 小板 | 多组件对候选 |

## 操作
1. HyperMesh 导入 `WeldIntegrity_30pairs.fem`。
2. 全选壳单元运行漏焊核验（阈值：search 5 / contact 20 / nodes 3 / shared 忽略）。
3. 核对候选数量、已焊 SEAM 忽略、远距不触发、hub 多对。

## 设计说明
- 候选对组件通常不共享节点；已焊 WD 对通过 SEAM 带共享 >=3 节点序列。
- 确定性生成；网格 5mm；生成时自检间距/接触长/共享节点数/无退化单元。
