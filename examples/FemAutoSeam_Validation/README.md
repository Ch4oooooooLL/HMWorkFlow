# FEM 自动焊缝验证模型（FEM Automatic Seam）

`generate_fem.py` 生成一个 OptiStruct/HyperMesh 可导入的 `.fem`（纯 Python 标准库，
便携运行时 Python 3.8 可直接运行），覆盖 FEM 自动焊缝模块的全部候选分类与负向控制。
与 `examples/AutoShellSeamBackend/test_fem/` 的验收夹具不同，本模型场景隔离更开、
网格规模更大（5,475 节点 / 4,750 壳单元），用于实机流程验证。

## 生成

在仓库根目录执行：

```powershell
runtime\python\windows-x64\python.exe examples\FemAutoSeam_Validation\generate_fem.py
```

产物：`FemAutoSeam_Combined_Validation.fem` + `FemAutoSeam_Combined_Validation_manifest.json`
（gitignore，不入库）。

## 模型结构

10 组场景沿全局 X 轴排布，间距 300 mm。壳组件默认厚度 1.0~2.0 mm（`_T1`/`_T2` 命名），
网格单元 3 mm。焊缝处源/目标组件不共享节点（装配语义），F10 为共享节点负向对照。
默认间隙 3 mm（< `search_distance` 12）。

| 场景 | 结构 | 预期 |
|---|---|---|
| F01 | 直 T：底板 90x60 + 筋板 60x20（gap 3） | 1 高置信 T 候选，自动 |
| F02 | 斜 T：筋板沿 +y 倾斜 45° | 1 T 候选，自动 |
| F03 | 弧线 T：正弦曲线筋板 | 1 T 候选，自动 |
| F04 | 部分重叠 T：100 mm 筋板只覆盖 34 mm 底板区间 | 仅公共区间候选，review |
| F05 | 贴片：50x30 贴片完全落在 80x60 目标内 | 1 贴片候选，自动 |
| F06 | 贴片带 ~20 mm 内孔（< 30 mm 阈值） | 贴片 review only |
| F07 | 邻近自由边：间隙 2 mm 但 y 向错位 12 mm（投影覆盖不足） | review only |
| F08 | 多目标：1 根 140 mm 筋板跨越 3 块 40 mm 底板 | 3 个 T 候选（每目标 1），自动 |
| F09 | 负向：两板间距 100 mm（> search_distance 12） | 无候选 |
| F10 | 负向：连续 T 型一体网格（web 与 base 共享 7 节点） | 无候选（无独立源自由边） |

`expected_results` 为拓扑预测；auto/review 判定依据 `auto_accept_confidence=0.88`、
`review_confidence=0.60` 及投影覆盖/距离变异性阈值，最终由 HyperMesh 2019/2022
实机裁决。

## HyperMesh 2019 / 2022 验证步骤

1. OptiStruct profile 导入 `FemAutoSeam_Combined_Validation.fem`。
2. 打开「FEM 自动焊缝 / FEM Automatic Seam」，选择全部壳组件。
3. 对照 manifest 的 `cases`：F01/F02/F03/F05/F08 应进入"高置信直接创建"，
   F04/F06/F07 应进入待处理复核表，F09/F10 应不产生候选。
4. 确认 before.hm 备份生成、规划写回与重新打开模型后按连通区域分批 automesh、
   质量由原生 criteria 裁决。

### 负向场景应观察到的行为

- **F09**：无候选（间距 100 mm 远超 `search_distance` 12）。
- **F10**：共享节点一体网格，不存在独立的源自由边，无候选；
  用于验证模块不会对"已由共享节点焊接"的接头重复建模。
- **F04**：只对 34 mm 公共区间创建焊缝（其余部分无目标支撑），进入 review。
- **F06**：贴片内孔 < 30 mm，贴片候选转入 review 供人工确认。

## 与 AutoShellSeamBackend 夹具的区别

- 场景间距 300 mm（夹具 500 mm 间隔但网格更稀疏）；本模型网格单元 3 mm、节点 5,475；
- 新增 F10 共享节点负向对照（夹具没有）；
- F02 斜 T 使用 45° 实斜筋板（夹具用 30° 斜边）；
- 本模型不带 Python 后端规划结果，完全交给实机 HyperMesh 流程判定。

该 FEM 用于识别与流程验证，不是生产求解模型。
