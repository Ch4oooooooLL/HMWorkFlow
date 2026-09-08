# mesh_seam_weld FAST_AUTO — Large Shell Validation Model

## 用途
`MeshSeamWeld_Large.fem` 用于 `mesh_seam_weld`（FAST_AUTO 自动焊缝）的大规模
接受/拒绝验证。规模 >=3.5 万壳单元，含 T 型、搭接、CONNECT、600 孔性能板、
负向与预置 SEAM 去重场景。

## 场景表
| ID | 类别 | 内容 | 预期 |
|---|---|---|---|
| T01..T08 | T 型（8） | 源板垂直立于目标板，法向夹角 ~90°，间隙 1~8mm，自由边 60~200mm，网格 5mm | 识别 T_PATH，焊缝路径 40..200mm |
| L01..L06 | 搭接（6） | 两平行板重叠（平行 <=15°），间隙 1~5mm | 识别 L_SURF |
| C01..C04 | CONNECT（4）| 共面近边平行，间隙 3~10mm | 识别 CONNECT |
| PERF | 性能（1） | 30x20=600 孔源板 + 2 目标板 | 批量闭环候选性能压测 |
| NEG1 | 负向 | 间隙 30mm（>12 不触发） | 不识别 |
| NEG2 | 负向 | 源板自由边 12mm（<20 丢弃） | 候选丢弃 |
| SEAM | 预置 | 两板间共享节点 SEAM_T1.5 焊缝带 | existing-weld 去重（DUPLICATE） |

## 操作
1. HyperMesh 导入 `MeshSeamWeld_Large.fem`。
2. 全选壳单元，运行 FAST_AUTO（阈值与 manifest/defaults 一致）。
3. 核对 T/L/C 候选数量、600 孔板批量候选、NEG 不触发、SEAM 去重。
4. 检查生成组件（`SEAM_T1.5` 等）与 Model Browser。

## 设计说明
- 组件间不共享节点（除 SEAM 带）；每对独立成组、X 向 300mm 间距。
- 确定性生成；单元尺寸 5mm，部分板 4~6mm。
- 生成时自检：每对间隙/角度范围、自由边环数与孔数吻合、无退化单元。
