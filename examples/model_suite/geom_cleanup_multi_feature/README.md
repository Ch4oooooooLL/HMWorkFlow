# geometry_cleanup — 大模型验证（CHAMFER + POCKET 两个场景）

## 用途
两个独立 .step（各含 1 个实体，导入后组件名 = 文件名），覆盖几何清理模块的
两大识别/修复场景：

| 文件 | 内容 | 预期 |
|---|---|---|
| GeomCleanup_ChamferComplex.step | 铸件风支架（100×80×30 主体 + 4 凸台 + 3 筋 + 底座法兰），边倒角 1~3mm、边圆角 r=0.5~5 混合，边缘含 1 处 r=7mm（>5）超范围负向；6 个通孔 | 种子面 → 链式扩展 → 删圆角/倒角面 → 可重建实体；r>5 边缘被拒绝 |
| GeomCleanup_PocketComplex.step | pocket_plate 200×150×6：32 沉台（深 1.0~2.5 < 3、沉孔半径 4~12 > 通孔半径 2~6，规则梯度）+ 10 普通通孔 + 2 个深 4mm（>3）负向 | 32 沉台+10 孔接受；2 深邃沉台被分类器拒绝 |

## 模块参数（生成时对齐）
`fillet_max_r=5`、`max_chain_depth=6`、`area_growth_ratio=2.5`、
`stitch_tolerance=0.2`。

## 操作
1. HyperMesh 逐个导入 `*.step`（单位 mm）。
2. geometry_cleanup 选择组件跑 CHAMFER 模式 / POCKET 模式。
3. 核对沉台数量、深邃负向组件是否被拒绝、修复后实体可重建。

## 设计说明
- 沉台 `cb_depth < t/2`（6/2=3）且 `cb_d > hole_d` 才被接受；深邃 cb_depth=4 > 3 应为 REJECT。
- ChamferComplex 含 >5mm 圆角负向；所有特征经逐边 try/except（半径递减）保证实体稳健且 solids==1。
- 每文件自检 solids==1；ChamferComplex 面数 ≥60。
