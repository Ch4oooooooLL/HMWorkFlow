# Solid Seam Weld — Large Validation Model

## 用途
`SolidSeam_10joints.fem` 用于 `solid_seam_connector`（实体焊缝）的大规模验证：
10 组接头、每组两个 6mm 六面体实体组件（两组件零共享节点、间有小间隙）。
默认参数：search_distance=15、max_search_distance=25、min_weld_length=20、宽度/间距 6。

## 场景（按组）
| id | 类型 | 间隙 | 预期 |
|---|---|---|---|
| J01..J03 | T | 2mm | 立板底边焊地板 → PENTA6+RBE3 入 SEAM_SOLID（PENTA_MIG_T） |
| J04..J05 | 搭接 LAP | 2mm | 两平行板叠放错位 → PENTA_MIG_L |
| J06..J07 | 对接 BUTT | 1.5mm | 两板端面相对 → PENTA_MIG_B |
| J08..J09 | 斜接 ANGLED | 2mm | 30°/40° 斜接 → PENTA_MIG |
| J10 | 负向 | 30mm | 间隙 > max_search_distance → 无焊缝候选 |

## 操作
1. 导入 `SolidSeam_10joints.fem`（20 个 hexa 组件，约 2 万单元）。
2. 逐组选择两个组件运行模块（或批量）；核对每组检测出交界链并按类型建焊缝到 `SEAM_SOLID`。
3. 核对 J10（30mm 间隙）应无候选。

## 设计说明
- 两组件**不共享节点**（存在 1.5~2mm 间隙），模拟装配界面。
- 每个块 6mm 网格，块体积/单元数 ~1000 hexa。
- 模块按组件平均法向分类接头；PENTA6+RBE3 焊缝与 SEAM_SOLID 组件由模块运行时创建。
