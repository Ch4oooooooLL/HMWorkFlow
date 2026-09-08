# BatchMesher — 曲面输入大型验证模型（12 部件 / >100 面）

## 用途
`batch_mesher_surfaces_12parts/` 提供 **12 个独立 STEP 曲面文件**，用于
`batch_mesher` 模块的 by-attached 连通域分组与批量网格生成验证。
BatchMesher 输入是曲面几何（非网格），故本套件输出 *.step 开放曲面面片。

## 场景表
| 部件 | 几何 | 孔/槽 | 面数（含孔环） |
|---|---|---|---|
| V01_RECT_8HOLES  | 矩形 | 8 孔   | 9  |
| V02_RECT_14HOLES | 矩形 | 14 孔  | 15 |
| V03_RECT_20HOLES | 矩形 | 20 孔  | 21 |
| V04_RECT_16HOLES | 矩形 | 16 孔  | 17 |
| V05_SLOTS_6      | 矩形 | 6 槽   | 7  |
| V06_SLOTS_5      | 矩形 | 5 槽   | 6  |
| V07_LSHAPE       | L 形 | 0      | 1  |
| V08_LSHAPE_HOLES | L 形 | 4 孔   | 5  |
| V09_USHAPE       | U 形缺口 | 0  | 1  |
| V10_NOTCHED      | 侧缺口 | 0   | 1  |
| V11_DENSE_HOLES  | 矩形 | 40 孔  | 41 |
| V12_PLAIN        | 矩形 | 0      | 1  |

## 操作
1. HyperMesh 导入 12 个 `.step`（产品名即组件名，见 manifest `components`）。
2. 全选所有 surfaces，运行 BatchMesher，默认按 by-attached 分组。
3. 预期 **连通域 = 12**，即 12 个批量任务；总面数 100+。
4. 核对每个任务生成的组件名与部件名一致。

## 设计说明
- 部件沿 X 以 220mm 间距排布，互不接触 → 每个文件恰 1 个连通域。
- 前 4 块多孔矩形面（孔距 >=30mm、孔径 8~16）；11 为 40 孔密集大板。
- 5/6 用长圆槽（闭合环缺口）模拟槽特征。
- 确定性生成（无随机）；manifest 记录每部件面数/孔数/bbox。
