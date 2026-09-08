# FEM Weld Recognition V2 — 对抗性回归语料库

本目录(默认被 `.gitignore` 排除)是由确定性生成器产出的 OptiStruct `.fem`
焊缝识别回归语料。目标是被测程序是 `hmworkflow.fem_auto_seam` 的 **V2**
识别器(`recognition_v2.py` + `backend.py` 补丁),产出用于**回归验收**,而
**不是**为了把测试做容易以适配当前算法。

- 生成器、校验器与回归运行器位于 `tools/weld_recognition_fixtures/`。
- 布局:`atomic/TC*_<name>/` 与 `composite/CM*_<name>/`,每案例含
  `input.fem`(自由场 bulk)、`input_manifest.json`、`ground_truth.json`、
  `ground_truth.csv`;语料根另有 `fixture_manifest.json`、
  `ground_truth.csv`(合并)与 `ground_truth_forbidden.csv`。

## 语料构成与设计原则

**48 个原子案例 TC001–TC048 + 4 个复合案例 CM001–CM004**,合计 169 条
期望焊缝、9 条 forbidden 关系。覆盖:独立组件网格(不跨组件共享 GRID)、
物理蒙皮间隙(±ZOFFS 与 Ti)、反向法向、多目标、孔/缝隙、孤岛、干扰项、
边界分支、补丁、焊中焊依赖、连接点、性能条带等。

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
| 角度/歧义 | TC021–TC026 | 70° REVIEW、55° REJECT、双层叠板、distractor 歧义、重合板、同组件自目标 |
| 边界/分支 | TC027–TC030 | 闭合槽内 rim、分支链、14 mm 短缝、投影跳变 |
| 法向/补丁 | TC031–TC040 | 源法向紊乱、目标内反绕条、近皮假板、非均匀源网格、补丁 AUTO/窗口/倾斜/越界/反绕/嵌套 |
| 依赖/连接 | TC041–TC048 | 焊中焊、双垂直 web、依赖环、滑动平行板、斜缝、共面 butt、L 角、近皮支架 |
| 复合 | CM001 箱形轨道 / CM002 对抗合并 / CM003 全语料 / CM004 性能 | 见下文 |

## 已记录的 V2 已知缺陷(回归 FAIL 的设计性原因)

回归运行器**永远不把 False AUTO 折算进 overall accuracy**;每类单独计数。
以下为当前实现的真实差异,均已复核确认:

| 缺陷 | 位置 | GT 期望 | V2 现状 | 状态 |
| --- | --- | --- | --- | --- |
| 闭合槽内 rim 被 AUTO | TC027 (W01/W02) 及其在 CM002、CM003 的复现 | REVIEW `INNER_BOUNDARY_SOURCE` | AUTO,reason 缺失 | **FAIL**(False AUTO×2/案例) |
| 共面 butt 幽灵 seam | TC046 | 0 candidate(`no_candidate` 策略) | PATCH_SEAM REVIEW | **FAIL** |
| 分段边界 REVIEW | TC013 (W01) | AUTO(正确 subchain X=100..300) | REVIEW `PARTIAL_COVERAGE`(父链覆盖率门限先于子链) | known-gap |
| 近翘曲 crease 行投影 | TC018 | AUTO | 微差越界→降级 | known-gap |
| distractor 歧义过严 | TC024 | AUTO(B 为明确最佳) | 见 8 mm distractor→REVIEW | known-gap |
| 边缘分组切分链 | TC030 (及其 CM002/CM003 复现) | REVIEW 整链 | 干净 B 段被单独 AUTO,C 段降级 | known-gap |

已知 gap 用 `known_gap_note` 记录在每条焊缝上,回归中作为信息项上报而
不使案例 FAIL。案例 FAIL **当且仅当**存在非 known-gap 的问题。

## 运行

```bash
# 1) 生成(确定性;覆盖 atomic/ 与 composite/)
python tools/weld_recognition_fixtures/generate_weld_recognition_fixtures.py

# 2) FEM 结构校验(独立自由场解析,不依赖生产 reader)
python tools/weld_recognition_fixtures/validate_generated_fem.py
#   期望:valid 52/52

# 3) 解析几何校验(source_path 存在/连通/共面,目标面平行与间隙)
python tools/weld_recognition_fixtures/validate_fixture_geometry.py
#   期望:52/52 case,0 findings(TC017/019/020/042 等经 geometry_parallel=false
#   声明为非平行几何)

# 4) 识别回归(atomic + composite,True AUTO/REVIEW/REJECT/forbidden 语义匹配)
python tools/weld_recognition_fixtures/run_weld_recognition_regression.py
#   期望(截至本语料定版):48 PASS / 4 FAIL,6 False AUTO —— 全数源于上表
#   TC027/TC046/CM002/CM003;False AUTO 单独计数,不并入 overall。
```

四步串联的退出码:任一 validator 或回归报告含非 known-gap 缺陷即非零。

## 语义匹配规则(回归运行器)

- 候选行按源组件、焊缝类型、源节点链重叠、目标组件交叠进行匹配。
- 同源组件的多条链用 **source-path 节点重叠 + row claiming** 区分
  (前一条 GT 焊缝的主行 ≥ 0.5 重叠后从后续焊缝排除),不依赖 bbox。
- AUTO 分组须由 AUTO 行单独覆盖 ≥ 50% 的 GT 源链才算 AUTO;REJECT 分支
  无候选即匹配,有 AUTO 计 False AUTO,有 REVIEW 计 unexpected。
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
  minimum_t_length 15、t_angle_auto 80/100、t_coverage_auto 0.98 等)与
  patch 参数(minimum_patch_length 15、small_hole_diameter 30 等),回归固定
  使用生产默认,不改参去适配案例。
