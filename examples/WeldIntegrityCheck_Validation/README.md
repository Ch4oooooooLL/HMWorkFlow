# 网格焊缝完整性检查（Weld Integrity Check）验证模型

本目录为 `modules/weld_integrity_check`（review_only 门禁：只出候选不改模型）生成装配壳 FEM。
模型模拟"主要网格已完成但可能漏焊"的场景：多组件、规则网格，包含正常漏焊候选、
应排除的已焊接/远距/共节点区域，以及多组件对矩阵。

## 生成命令（仓库根目录）

```powershell
runtime\python\windows-x64\python.exe examples\WeldIntegrityCheck_Validation\generate_fem.py
```

生成两个产物（`.gitignore`，不入库）：

- `WeldIntegrityCheck_Validation.fem`：多组件 OptiStruct 壳网格（约 1.3 万节点 / 1.2 万壳单元）；
- `WeldIntegrityCheck_Validation_manifest.json`：场景、组件、推荐参数、自检模拟结果。

可选 `--verify-detector` 会用仓库内 `modules/hybrid_core/python/shell_weld_detection.py`（模块实际使用的
共享检测器）对生成网格做权威交叉验证，把 `verified: true` 写入 manifest。生成器本身也在写文件前
用内嵌的等价检测逻辑自检：模拟结果必须与 manifest 设计的 Pair 集合完全一致，否则抛错。

## 模型结构

单位 mm，网格 5.0，19 个组件。布局：

| 区域 | 组件 | 场景 |
| --- | --- | --- |
| C01 | 101 `C01_TJ_BASE`（60x30 水平板）+ 102 `C01_TJ_FLANGE`（垂直法兰） | T 型漏焊：法兰自由底边距底板顶面 0.5 mm |
| C02 | 103 `C02_LAP_BOTTOM`（60x30）+ 104 `C02_LAP_TOP`（30x20，z=0.2） | 搭接漏焊：上层板完全叠在下层板上方 0.2 mm |
| C03 | 105 `C03_NEAR_LEFT` + 106 `C03_NEAR_RIGHT` | 邻近自由边：边到边 4.5 mm |
| C03b | 107 `C03B_NEAR8_LEFT` + 108 `C03B_NEAR8_RIGHT` | 邻近自由边 8 mm（需 max_search_distance>=8） |
| C04 | 109 `C04_SEAM_BASE` + 110 `C04_SEAM_T1`（垂直壳带）+ 111 `C04_SEAM_FLANGE` | 已焊接：SEAM 带与两板各共享整条节点线 |
| C05 | 112 `C05_FAR_LEFT` + 113 `C05_FAR_RIGHT` | 远距：自由边间距 40 mm |
| C06 | 114 `C06_ONEPIECE_A` + 115 `C06_ONEPIECE_B` | 共节点一体：两组件连续网格共享交界节点线 |
| C07 | 116 `C07_HUB` + 117/118/119 `C07_NEIGHBOR_LEFT/RIGHT/TOP` | 多组件对矩阵：hub 同时邻近 3 个组件 |

## HyperMesh 2019 操作步骤（OptiStruct profile）

1. 导入 `WeldIntegrityCheck_Validation.fem`（File > Import > FE Model，选 OptiStruct）。
2. 打开模块"网格焊缝完整性检查"，点击"使用当前可见组件"或全选 19 个组件。
3. 设置参数（manifest `recommended_settings`）：`max_search_distance=12`、`min_contact_length=20`、
   `min_continuous_nodes=3`、勾选"优先检测 Shell 自由边"与"忽略已直接共节点连接的组件对"。
4. 点击"开始检测"，等待 Python 检测完成，打开报告窗口。
5. 对照 manifest 逐 case 核对 Pair 列表与候选区数量。

## 预期结果（对照 manifest cases）

| case | 预期 |
| --- | --- |
| C01 | 1 个候选 Pair (101,102)，法兰底边整条为候选区 |
| C02 | 1 个候选 Pair (103,104)，上层板周界整圈为候选区 |
| C03 | 1 个候选 Pair (105,106) |
| C03b | 1 个候选 Pair (107,108)，仅在 max_search_distance>=8 时出现 |
| C04 | 无候选（SEAM 带与两板共享 >=3 节点，被 ignore_shared_nodes 跳过） |
| C05 | 无候选（40 mm 间距被 AABB 粗筛排除） |
| C06 | 无候选（共享整条节点线） |
| C07 | 3 个候选 Pair：(116,117)、(116,118)、(116,119) |

`--verify-detector` 生成的 manifest 中 `simulation.repository_detector.verified=true` 即为
模块实际检测器对同一网格的交叉验证通过。

## 失败形态的验证方式

- 已焊接区（C04）：报告窗口应不出现 (109,110)、(110,111)、(109,111) 等 Pair；
- 远距（C05）与共节点一体（C06）：应出现"检测完成，未发现候选 Component Pair"提示；
- 阈值演示（C03b）：把 `max_search_distance` 从 12 改回默认 5.0 重跑，(107,108) 消失；
  调回 8 以上重新出现。

## 边界与注意事项

该模型仅用于识别/流程验证，不含求解边界条件，不用于生产求解。模块是 review_only：
只生成候选与显示集合，不创建/修改焊缝、网格或 Component。恢复按钮会还原进入模块前的显示状态。
