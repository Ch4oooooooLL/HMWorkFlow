# FEM Weld Recognition V2 — 对抗性回归语料库

本目录是**版本化验收 fixture**（随仓库跟踪），由确定性生成器产出的 OptiStruct
`.fem` 焊缝识别回归语料。目标是被测程序是 `hmworkflow.fem_auto_seam` 的 **V2**
识别器(`recognition_v2.py` + `backend.py` 补丁),产出用于**回归验收**,而
**不是**为了把测试做容易以适配当前算法。

- 生成器、校验器与回归运行器位于 `tools/weld_recognition_fixtures/`。
- 布局:`atomic/TC*_<name>/` 与 `composite/CM*_<name>/`,每案例含
  `input.fem`(自由场 bulk)、`input_manifest.json`、`ground_truth.json`、
  `ground_truth.csv`;语料根另有 `fixture_manifest.json`、
  `ground_truth.csv`(合并)、`ground_truth_forbidden.csv` 与
  `ground_truth_tolerated.csv`。

## 语料构成与设计原则

**50 个原子案例 TC001–TC050 + 4 个复合案例 CM001–CM004**,合计 177 条
期望焊缝(AUTO 131 / REVIEW 42 / REJECT 4)、9 条 forbidden 关系。覆盖:独立
组件网格(不跨组件共享 GRID)、物理蒙皮间隙(±ZOFFS 与 Ti)、反向法向、多目标、
孔/缝隙、孤岛、干扰项、边界分支、补丁、焊中焊依赖、连接点、性能条带、
共享 GRID 的连续网格(必须 0 候选)与同腹板斜交广义 T 并存等。

1. **Ground truth 独立生成**——期望由案例的解析几何构造推导,从不调用
   识别器,避免“ground_truth = recognizer(fem)”的自证。
2. **确定性**——无随机数;网格与扰动全部解析定义;重复运行逐位一致
   (GRID/元素/组件/属性 ID 与坐标均确定)。
3. **真实 FEM 格式**——只生成真实 HyperMesh 自由场导出会写出的卡片
   (`GRID,id,,x,y,z`、`CQUAD4/CTRIA3`、`PSHELL`、`MAT1`、`$HMNAME
   COMP`),不伪造生产解析器读不到的格式。
4. **诚实失败**——识别器的真实缺陷照实记录为 FAIL/known-gap,不改生产
   代码去“刷绿”。
5. **可读命名**——语义化组件名(如 `TC006_SRC_WEB`、`TC027_TGT_TOP`),
   没有 `comp1/plate1`。

## ID 布局(便于人工回溯)

- 原子案例索引 `N = case_index`:GRID 基址 `N*1000`,元素 `N*1000+10_000`,
  组件 `N*1000+20_000`,PSHELL `N*1000+30_000`。某些案例节点数 > 1000,
  因此**复合案例做全局重映射**(每案例自 `1` 起的递增区段 + 裕量),以保证
  无碰撞;组件/属性随之重映射。
- 复合案例按字母序合并原子工厂到同一条 FEM,岛与岛沿 X 相隔 ≥ 2000 mm,
  互不干扰。CM003 中可见的坐标因此带有约 `island_index*2000 + 案例原始
  X` 的偏移;GT 的 `source_path` 坐标始终来自合并后的最终模型。

## 案例分类速查

| 类别 | 案例 | 关注点 |
| --- | --- | --- |
| 基线/校准 | TC001–TC005 | 单目标 T、midsurface vs 物理 skin、±ZOFFS、全反向法向 |
| 多目标/连续 | TC006–TC009 | 一条链跨 2/3 连续组件;1 mm 缝隙桥接;40 mm 断裂不得 AUTO |
| 孤岛/孔/缝隙 | TC010–TC013 | 同组件两岛非连续;矩形孔;拓扑槽 HOLE_INTERRUPTION;悬挑 subchain |
| 网格非一致 | TC014–TC018 | 粗/细目标、quad→tria、可变 Ti、翘曲、曲率 |
| 角度/歧义 | TC021–TC026 | 70° AUTO（界面阈值含边界）、55° 广义 T REVIEW `ANGLE_BORDERLINE`、双层叠板、distractor 歧义、重合板、同组件自目标 |
| 边界/分支 | TC027–TC030 | 闭合槽内 rim、分支链、14 mm 短缝、投影跳变（两侧各自 AUTO，禁止融合） |
| 法向/补丁 | TC031–TC040 | 源法向紊乱、目标内反绕条、近皮假板、非均匀源网格、补丁 AUTO/窗口/越界/反绕/嵌套、倾斜板→广义 T REVIEW |
| 依赖/连接 | TC041–TC048 | 焊中焊、双垂直 web、依赖环、滑动平行板、斜缝、共面 butt、L 角、近皮支架 |
| 连续网格/广义 T | TC049–TC050 | 共享 GRID 节点的连续网格必须 0 候选；同一腹板上 60° 广义 T 与方形 T 并存 |
| 复合 | CM001 箱形轨道 / CM002 对抗合并 / CM003 全语料 / CM004 性能 | 见下文 |

## V2 边界场景状态

回归运行器**永远不把 False AUTO 折算进 overall accuracy**;每类单独计数。
以下为当前实现的真实差异,均已复核确认:

| 缺陷/策略差异 | 位置 | GT 期望 | V2 现状 | 状态 |
| --- | --- | --- | --- | --- |
| 闭合槽内 rim | TC027 (W01/W02) 及其在 CM002、CM003 的复现 | REVIEW `INNER_BOUNDARY_SOURCE` | 保留父闭环内边界分类 | **PASS** |
| 共面 butt | TC046 | 0 candidate(`no_candidate` 策略) | 低覆盖贴边不再构成 PATCH | **PASS** |
| 分段边界 | TC013 (W01) | AUTO(正确 subchain X=100..300) | 连续完整受支撑子链独立判定 | **PASS** |
| 近翘曲 crease 行投影 | TC018 | AUTO | 网格相关切向容差 | **PASS** |
| 投影跳变 | TC030 (及其 CM002/CM003 复现) | 两段各自 AUTO,禁止融合 | 跨目标断层不并成一条连续缝 | **PASS** |
| 斜腹板 55° 广义 T | TC022 (及其 CM003 复现) | REVIEW `ANGLE_BORDERLINE` | 召回窗口内候选,不 AUTO | **PASS** |
| 倾斜板 | TC037 | REVIEW `ANGLE_BORDERLINE`(广义 T) | 低边落在底板上的 55° 广义 T | **PASS** |
| distractor 歧义过严 | TC024 (及其 CM003 复现) | AUTO(B 为明确最佳) | 8 mm distractor 拖入 REVIEW | known-gap |
| 近皮假焊 | TC033/TC048/CM001_W_DIA3_BOT | REVIEW `SKIN_ERROR_BORDERLINE` | 接触包络(半厚+坡脚余量)误纳→AUTO | known-gap |
| 连接端边 | TC042_W03 (及其 CM002/CM003 复现) | REVIEW 多目标 | 端边被拆成两段短支撑 | known-gap |
| 贴壁端边 | CM001 四道隔板端边、纵骨端边 | 非焊缝(5 mm 间隙) | 召回包络仍产 AUTO 行 | tolerated |
| 共享 GRID 连续网格 | TC049 | 0 candidate(`mesh_continuous` 策略) | 链级共享节点判定后不产候选 | **PASS** |
| 同腹板斜交广义 T | TC050 (W03) | REVIEW 多目标(`MULTI_TARGET_CONTINUOUS`) | 端边整链由部分链补扫召回 | **PASS** |

已知 gap 用 `known_gap_note` 记录在每条焊缝上、召回优先允许但非真实焊缝的
多识别行用 `tolerated_candidates` 记录在案例上,回归中均作为信息项上报而
不使案例 FAIL。案例 FAIL **当且仅当**存在非 known-gap、非 tolerated 的问题。

召回补扫的两条约束:① 组件对在链级共享 GRID 节点(`mesh_continuous`)时属于
同一连续网格,FEM 已在该处传力,不再作为焊缝 target;② 严格扫描只覆盖链长
不足 `t_recall_min_coverage`(默认 0.5)时,该链用放宽包络重扫(部分链补扫),
补扫行须达到同一覆盖率下限,并按 ≥50% 节点重叠与严格行去重,避免端部擦碰
碎片掩盖真实接缝、同时不把真实断口重新粘成一条连续缝。

## 运行

```bash
# 1) 生成(确定性;覆盖 atomic/ 与 composite/)
python tools/weld_recognition_fixtures/generate_weld_recognition_fixtures.py

# 2) FEM 结构校验(独立自由场解析,不依赖生产 reader)
python tools/weld_recognition_fixtures/validate_generated_fem.py
#   期望:valid 54/54

# 3) 解析几何校验(source_path 存在/连通/共面,目标面平行与间隙)
python tools/weld_recognition_fixtures/validate_fixture_geometry.py
#   期望:54/54 case,0 findings(TC017/019/020/042 等经 geometry_parallel=false
#   声明为非平行几何)

# 4) 识别回归(atomic + composite,True AUTO/REVIEW/REJECT/forbidden 语义匹配)
python tools/weld_recognition_fixtures/run_weld_recognition_regression.py
#   期望:54 PASS / 0 FAIL;失败类别全零,仅剩上表 known-gap / tolerated 信息项

# 或一键串联四步并写出 report.json(退出码 0 当且仅当 ALL_GREEN)
python tools/weld_recognition_fixtures/run_all_pipeline.py
```

四步串联的退出码:任一 validator 或回归报告含非 known-gap 缺陷即非零。

## 语义匹配规则(回归运行器)

- 候选行按源组件、焊缝类型、源节点链重叠、目标组件交叠进行匹配。
- 同源组件的多条链用 **source-path 节点重叠 + row claiming** 区分
  (前一条 GT 焊缝的主行 ≥ 0.5 重叠后从后续焊缝排除),不依赖 bbox。
- AUTO 分组须由 AUTO 行单独覆盖 ≥ 50% 的 GT 源链才算 AUTO;REJECT 分支
  无候选即匹配,有 AUTO 计 False AUTO,有 REVIEW 计 unexpected。
- 案例可登记 `tolerated_candidates`(source→target 对 + 说明):召回优先
  策略允许、但解析几何不构成真实焊缝的 AUTO 行作为信息项上报,不使案例 FAIL。
- 报告类别:**False AUTO(单独)、missed AUTO、wrong target、wrong
  decision、wrong type、wrong subchain、unexpected/duplicate candidate、
  support-run mismatch、missing required reason、forbidden relation**。
- 严重度:forbidden 关系违约标 `FALSE_AUTO_CRITICAL`。

## 几何事实与容差

- 通用坐标系:X=焊缝方向,Y=横向,Z=垂直(复合案例整体沿 X 平移)。
- 标准目标板:x 0..400、y ±100、z=0、t=10(顶部物理 skin z=+5);标准
  web:x 50..350、y=0、z 5..105、t=6、法向 ±Y。
- 几何校验容差:`max_step` 100 mm(链内无跨岛跳点)、`planarity_tol`
  0.5 mm、平行目标偏移变化 `parallel_tol` 2.0 mm。非平行几何(变厚度
  TC017、曲面 TC019/TC020、垂直端边 TC042_W03)显式
  `geometry_parallel=false`。
- 识别器默认阈值见 `backend.DEFAULT_SETTINGS`(search_distance 10、
  minimum_t_length 15、t_angle_auto 70/100、t_coverage_auto 0.98 等)与
  patch 参数(minimum_patch_length 15、small_hole_diameter 30 等),回归固定
  使用生产默认,不改参去适配案例。
