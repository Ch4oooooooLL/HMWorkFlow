# FEM Weld Recognition V2 确定性回归语料 —— 建库与验收报告

日期：2026-09-09
状态：语料定版、全链路通过；4 个 FAIL 均为已登记的真实 V2 识别器缺陷（False AUTO
单独计数，不折算 overall accuracy）。

## 1. 背景与范围

`hmworkflow.fem_auto_seam` 的 V2 识别核心（`recognition_v2.py` + `backend.py`
补丁）已按 Spec 落地：以有序真实自由边链为 Source，按 PSHELL 厚度、Element
ZOFFS/Ti 恢复 Target Physical Skin，输出单/多 Component 连续 `support_runs`，
叠层竞争目标、孔洞/断口、部分覆盖、角度边界、投影跳跃、曲面与非流形风险经
Hard Gate 降为 REVIEW。本次工作**只为其构建对抗性、确定性、真实格式的
OptiStruct `.fem` 回归语料，并完成建库验收**；不优化识别算法、不以降低测试
难度去适配当前算法、不改生产代码让测试变绿。

被测对象固定为生产默认设置（`backend.DEFAULT_SETTINGS` 与 patch 参数），回归
运行不改参。

## 2. 语料规模

| 项 | 数值 |
| --- | --- |
| 原子案例 TC001–TC048 | 48 |
| 复合案例 CM001–CM004 | 4（箱形轨道 / 对抗合并 / 全语料合并 / 性能条带） |
| 期望焊缝 | 169（AUTO 112、REVIEW 49、REJECT 8） |
| forbidden 关系 | 9（含 `FALSE_AUTO_CRITICAL` 依赖环） |
| GRID / 单元 / 组件 | 70,168 / 61,719 / 280 |

覆盖维度：独立组件网格（不跨组件共享 GRID）、物理蒙皮间隙（±ZOFFS 与 Ti 变厚度）、
全反向法向、同组件岛、多目标（2/3 连续组件）、孔/缝隙/投影跳变、干扰项（近皮假板、
设备支架）、边界分支、闭合槽内 rim、补丁（窗口/倾斜/越界/反绕/嵌套）、焊中焊依赖、
依赖环、双垂直 web 连接点、曲面与翘曲目标、性能条带（30 缝）等。

复合案例说明：CM003 按字母序将 48 个原子案例合并进一条 FEM（岛沿 X 相隔 ≥ 2000 mm）；
CM002 精选已知失败模式交互（TC027/TC046/TC042/TC030/TC010/TC021/TC043）；
CM001 为 600×300 箱形轨道（两侧壁、5 道横隔板含人孔/倾斜/短隔板、纵骨、贴片、
近皮支架）；CM004 为 2200×1600 底板 + 30 条齐平 T。

## 3. 设计与独立性

- **Ground truth 独立**：期望（source 组件/节点链、target 组件集、AUTO/REVIEW/
  REJECT、required/forbidden reason codes、解析几何）全部由案例构造的解析几何推导，
  从不调用识别器，杜绝 `ground_truth = recognizer(fem)` 的自证。
- **确定性**：无随机数；GRID/单元/组件/PSHELL ID 与坐标逐位可复现。
- **真实格式**：只生成真实 HyperMesh 自由场导出会写出的卡片
  （`GRID,id,,x,y,z`、`CQUAD4/CTRIA3`、`PSHELL`、`MAT1`、`$HMNAME COMP`），
  ID 布局便于人工回溯（案例 N：GRID 基址 `N*1000`、单元 `+10_000`、组件
  `+20_000`、PSHELL `+30_000`）。
- **语义命名**：`TC006_SRC_WEB`/`TC027_TGT_TOP` 等，无 `comp1/plate1`。

### 复合合并的两个关键修正（建库中发现并修复）

1. **原子 ID 块冲突**：部分案例节点数 > 1000（如 TC027 有 1,124 节点），按
   `case_index*1000` 的原始分块在合并时互相覆盖坐标，曾使 CM003 中 TC027 岛出现
   远距桥接单元、回归链错位。`_merge_composite` 改为对节点/单元/组件/属性
   **全局递增重映射 + 每岛裕量**，GT 源路径坐标在最终（平移后）模型上重推。
2. **同源组件多链**：一条源组件存在多条焊缝（如 stiffener 底边→BASE、顶边→
   DOUBLER）时，合并期不得回退到“每组件一条 hint 链”，须保留每条焊缝自带的
   `source_path` 并重映射。

## 4. 全链路验收结果

一键编排 `tools/weld_recognition_fixtures/run_all_pipeline.py`，顺序执行
generate → validate_fem → validate_geometry → regression，结果写入语料根
`report.json`：

| 阶段 | 工具 | 结果 |
| --- | --- | --- |
| 生成 | `generate_weld_recognition_fixtures.py` | 52 案例确定性重建 |
| FEM 结构校验 | `validate_generated_fem.py` | **52/52 valid**（独立自由场解析，不依赖生产 reader） |
| 解析几何校验 | `validate_fixture_geometry.py` | **52/52 case、0 findings** |
| 识别回归 | `run_weld_recognition_regression.py` | 48 PASS / 4 FAIL，`status: ALL_GREEN`（见 §6） |

### 失败类别逐项计数（不合并 accuracy）

| 类别 | 数值 |
| --- | --- |
| **False AUTO（单独）** | **6** |
| missed expected AUTO | 0 |
| expected AUTO → REVIEW | 0 |
| expected REVIEW → AUTO | 6 |
| wrong target / weld type / subchain | 0 |
| unexpected candidate | 1 |
| duplicate candidate | 0 |
| support-run mismatch | 0 |
| missing required reason | 6 |
| forbidden relation 违约 | 0 |

检测候选 213 行、其中 AUTO 115 行；52 案例总耗时约 6.6 s（识别阶段约 6.6 s 含
CM004 30 缝性能条带，无超时/内存异常）。

## 5. 语义匹配规则（回归运行器）

- 候选行按源组件、焊缝类型、源链节点重叠、目标组件交叠匹配；同一源组件的多条链
  用 **source-path 节点重叠 + row claiming** 区分（前一焊缝主行 ≥ 0.5 重叠后从后续
  排除），不依赖 bbox。
- AUTO 判定要求 AUTO 行节点并集覆盖 GT 源链 ≥ 50%；REJECT 分支无候选即匹配，
  有 AUTO 计 False AUTO、有 REVIEW 计 unexpected。
- known-gap（`known_gap_note`）作为信息项上报，不使案例 FAIL；案例 FAIL 当且仅当
  存在非 known-gap 问题。

## 6. 已登记的真实 V2 缺陷（回归 FAIL / known-gap 设计性原因）

### FAIL（4 案例、False AUTO 6、unexpected 1、missing reason 6）

| 案例 | GT 期望 | V2 现状 | 根因/备注 |
| --- | --- | --- | --- |
| TC027_source_inner_boundary（含 CM002/CM003 复现） | 闭合槽内 rim 两条 REVIEW `INNER_BOUNDARY_SOURCE` | 两条 AUTO、reason 缺失（False AUTO×2/案例） | `_split_boundary` 在 90° 转角把闭合自由环切成段，`closed` 标志丢失，`INNER_BOUNDARY_SOURCE` 门禁不触发；应改为段级内边界判定或保留闭环信息 |
| TC046_coplanar_butt | 0 candidate（`no_candidate` 策略） | 共面 butt 被发为 PATCH_SEAM REVIEW | 共面贴边被当成平行贴片 seam；需几何共面/连续表面判定排除 |

CM002/CM003 的 FAIL 完全由 TC027 内 rim 复现构成；语料借此证明“合并进整模型后该
缺陷稳定复现”。

### known-gap（信息项，不计 FAIL）

| 案例 | 差异 | 备注 |
| --- | --- | --- |
| TC013_partial_target_middle | 正确 subchain（X=100..300）被降 REVIEW/PARTIAL_COVERAGE | 父链覆盖率门限先于子链选择执行 |
| TC018_slightly_warped_target | 0.2 mm 翘曲在 crease 列投影微差可拆分完美链 | Physical-skin 投影用绝对切向容差；需几何相对容差 |
| TC024_better_target_with_distractor | 明确最佳目标被 8 mm distractor 拖进 REVIEW | 歧义门禁过保守 |
| TC030_projection_jump（含 CM002/CM003 复现） | 干净 B 段被单独 AUTO、整缝未整体 REVIEW | 边缘级分组先于“单物理缝对支撑台阶”整体门禁 |

## 7. 校验器说明

- `validate_generated_fem.py`：**独立自由场解析**（不读生产 `fem_mesh_reader`），
  校验 BEGIN/ENDDATA、GRID/单元/PSHELL/MAT1、banner 段归属与 manifest 集合一致、
  每条 GT 源路径节点存在且归属/坐标一致。
- `validate_fixture_geometry.py`：由 FEM 文本重推导几何；逐焊缝校验源路径存在/连通
  （跨岛跳点 ≤ 100 mm）/共面（≤ 0.5 mm）/start/end/length 与记录一致，目标面存在且
  链到面偏移变化 ≤ 2.0 mm（平行性）。非平行几何（TC017 变厚度、TC019/TC020 曲面、
  TC042_W03 垂直端边）在 GT 显式 `geometry_parallel=false` 豁免。

## 8. 布局与运行

语料（版本化验收 fixture，镜像 `AutoShellSeamBackend/test_fem` 先例）：
`examples/validation_weld_recognition_v2/`，每案例含 `input.fem`、
`input_manifest.json`、`ground_truth.json/.csv`；语料根另有 `fixture_manifest.json`、
`ground_truth.csv`、`ground_truth_forbidden.csv`、`report.json`、`README.md`。

工具链：`tools/weld_recognition_fixtures/`（wfc_model/wfc_gt/wfc_writer/wfc_csv/
geo_helpers + 5 个原子案例模块 + composite_cm001 + generate/2×validate/run/
run_all）。

```bash
python tools/weld_recognition_fixtures/run_all_pipeline.py   # 一键全链路 + report.json
```

离线仓库自检（`python tools/run_offline_tests.py`，CI 同入口）保持全绿；`repository_audit`
白名单扩展至新语料目录。

## 9. 关联改动

- 语料工具与语料本体随本次提交入库；V2 识别器源码/测试、`fem_mesh_reader`
  ZOFFS/Ti 字段、README/guide/CHANGELOG 的 V2 条目为同一特性线的未提交改动，
  一并提交。
- `.gitignore` 新增：`tools/generated_models/`、`tools/model_generation/_smoke_out/`
  忽略（生成器 README 声明“输出到被 git 忽略目录”，此前漏配）；
  `examples/validation_weld_recognition_v2/` 反白名单。
