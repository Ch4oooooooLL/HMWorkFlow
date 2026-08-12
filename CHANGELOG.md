# HMWorkFlow changelog

## Unreleased - platform stabilization

- 对齐新安装的 HyperMesh 2022.0.0.33：BatchMesher 安装发现不再假定目录名必须为 `2022`，支持实际存在的 `Altair/2020/hwdesktop/hm` 布局，并将 Default 自动规格迁移到该安装自带的 `general_8mm.criteria/.param`；2019 经典布局和自定义预设继续保留。

- 按当前实机重新对齐几何焊缝的 HyperMesh 2019.0.0.70 与 2022.0.0.33：两版分别在 12 个独立 hmbatch 进程中跑完全部公开功能，创建 ID、面积、包围盒、边归属拓扑、消息、警告与最终 Surface 集合逐项一致；命令审计同时通过。修复 T_LIST 校准包装器未转发匹配模式/容差、以及 `*edgesmarkaddpoints` 重编号后审计仍使用旧 Line ID 导致 `*createlist` 假失败的问题。

- 修复 BatchMesher 首次使用时因 `hmbatch.exe`、Criteria 和 Param 均为空而无法调用的问题：面板现在自动发现本机受支持的 HyperWorks 2019/2022，并使用安装自带的 `general_8mm.criteria` / `general_8mm.param` 默认规格；已有有效自定义规格保持不变。

- 优化 FEM 自动焊缝的 Python 规划阶段：候选复核后的创建规划复用同一任务检测阶段已生成且按模型、现有焊缝、所选组件和检测参数校验的候选缓存，不再对完整 FEM 重复执行一次候选检测；缓存缺失或输入不一致时仍安全回退到完整检测。

- 修复 T 列表/连接边线在跨 Surface line list 上执行 ruled 后无结果：共享 Connect Edges 执行器现在与 HyperMesh 手动 Ruled 面板一致，在创建 line list 和调用 `*linearsurfacebetweenlines` 前显式执行 `*surfacemode 4`（surface only），不再继承此前残留的 automesh/surfaceless 全局模式。

- T 列表的 Project/Split 与 Connect Edges 现在使用两个独立的原生 history action：切分阶段一旦开始，无论后续候选筛选、排序或 ruled 连接成功与否，本次 trim 都会提交并保留；连接失败只回滚连接阶段。连接准备改为“严格匹配 → 多目标面 trim 片段沿投影轨迹排序 → 本次 trim 集合内最佳匹配”的分层链路；投影参考不可读时也会在本次 trim 集合内继续执行与手动 Connect Edges 相同的路径判断，不再直接停止。切分阶段确定的两组 line ID 顺序会原样写入 `*createlist lines 1/2`，连接阶段不再二次重排。

- Project/Split 现在在每一次 `*surfacemarksplitwithlines` 内部单独开启 `hm_entityrecorder lines`，并记录该目标面切分前后的边线差集。T 列表的第二组候选只由“本次 trim 新建且属于该目标分片的 Lines”与“本次 trim 后新附着到该目标的 Lines”组成，不再使用整个模型的新 Line 差集。Ruled 前将最终 `list1/list2` 顺序写入日志便于核对。

- 继续收紧 T 列表交给 Connect Edges 的两组 lines：严格阶段要求第二组候选覆盖投影前记录的目标面落点；若 HyperMesh 实际 trim 与最近点参考存在差异，则只在本次 trim 记录集内按全路径误差选取最佳 ruled 兼容路径。多目标面产生的非拓扑连续片段按投影弧长统一排序，并排除只在交点附近横穿投影轨迹的边界线。两组路径的方向/循环起点不再只用首尾判定，而是沿完整路径按弧长等比采样，比较正向、反向及闭合路径所有循环起点的全路径对应误差，再将最优 ID 顺序写入 line list 1/2。

- T 列表仅组织现有 Project/Split 与 Connect Edges 两个流程，不改动两者的原生执行方式。T 列表通过现有 `_split_surface ... PROJECT` 执行完整切分和 no-op 判定；切分前记录源线在所选目标面上的预期投影点，切分后依据这些目标面落点识别第二组 lines，避免误选源线附近或远处的其他新边。在交给 Connect Edges 前，分别按端点连续关系重排两组 lines，并根据两组起点/终点的几何距离统一行进方向；重排结果按顺序写入 HyperMesh line list 1/2。投影仍直接修改原 Surface，整个 T 列表保留原生 history action 供 `Ctrl+Z` 撤销。

- 根据第二轮 HM2019 手工日志澄清搭接曲面的输入边界：C03 与 C04 均已成功；两次所谓“部分失败”都来自把 C06 投影/切分几何送入搭接曲面，候选面未同时连接两侧，严格拓扑门禁正确回滚。按钮、原生选择提示和错误信息现在明确要求“两张近似平行且投影区域重叠的面”，并引导边到面改用“搭接边线”、投影几何改用“投影切分”，不通过放宽门禁保留游离曲面。

- 根据 HM2019 验证模型的首轮手工反馈修复几何焊缝 T 曲面与搭接曲面：导入 CAD 无 Property/`_Txx` 厚度时，T 曲面不再在 selector 层静默停止，而是与其他创建功能一致弹出厚度输入；搭接曲面不再把 50 mm 实体偏置产生的远端构造盖板/侧壁全部移入 `SEAM_T*_Surf`，新增原始两面包络过滤（可调 `lap_result_envelope_tolerance`），本机两版本均由原 9 张混杂面收敛为间隙内 4 张真实连接面。成功后统一显式显示并同步输出 component，避免“日志成功但图形/Browser 看不到”。T 曲面、搭接曲面、T 列表在 HM2019.0.0.70/HW2022.0.0.33 重新通过。

- 重新按本机 HyperMesh 2019.0.0.70 与 HyperWorks 2022.0.0.33 逐策略验证“几何焊缝”：修复非交互执行器对 UI selector 的错误依赖；T 列表不再把切分后完整目标面边界形成的分支图整体拒绝，而是枚举无分支路径、按源路径几何覆盖评分选出真实投影边，并在 ruled 创建后执行 merge/equivalence，验证焊缝边同时归属源面与目标面，杜绝游离曲面假成功。EXTEND 改用帮助文档规定的 trim mode 1，并将 offset type、偏置/搜索距离、投影距离等真实可调参数接入设置；设置面板补齐投影路径、拓扑、质量、T/搭接、延伸、点编辑、厚度、兼容与诊断参数，配置文件保存时保留参数说明。两版本各 12/12 策略独立 hmbatch 通过，模块离线测试 44 passed + 16 subtests。

- 在几何板块新增独立的 `预处理` 面板：支持将当前显示组件按全局 X +90°、全局 Z -90° 转为车辆坐标系；按所选 component 的基础名称归档本体及 `.数字` 重名族；以及归档名称中包含 `SKELL` 的骨架组件。归档统一进入 `USELESS` Assembly 并隐藏，不删除模型实体。

- 提交 2026-08-08 跨模块原生指令审计的探针脚本：`tools/audit_*.tcl`（103 个，每模块一组，见 `docs/module_command_audit_2026-08-08.md` §7 证据清单）、`tools/fix_probe_bolt_*.tcl`（修复探针）、`tools/fix_probe_geometry_cleanup22.tcl` 及实机探针 `tools/probe_*.tcl`（rbe2/bolt/adhesive/solid_seam/quadratic 等），可复用于修复验证。`.gitignore` 同步覆盖探针运行产物：`runtime/` 下的导出模型与 KEY=VALUE 日志（`*.fem/*.hm/*.inp/*.txt/*.tcl` 及 `audit_batch_mesher_work_*/`）不入库；一次性调试文件 `tools/diag_*.tcl` 与根目录临时探针（`_probe_asm*`、`command1.tcl`、求解器 .msg）按约定忽略；`/.zcode/` 本地记忆目录忽略。

- 新增验证模型生成体系：`doc/validation_model_generation_conventions.md` 定义全项目验证模型统一约定（FEM 格式、manifest schema、自检要求、正常+失败双覆盖）；`examples/` 下新增 13 个验证目录（GeometryCleanup / Midsurface+BOM / SeamSurface / SolidSeam_Extended / MeshSeamWeld / FemAutoSeam / WasherHoleRBE2 / SolidHoleRBE2 / BoltConnector / LocalMeshOptimizer / WeldIntegrityCheck / AdhesiveConnector / ContactSetup）。全部为确定性生成器（网格纯 stdlib 便携 python38；几何 cadquery 开发期工具），内嵌拓扑自检，产物 .fem/.step/_manifest.json/.criteria 遵循 gitignore 约定不入库，仅提交生成器与中文 README。

- 实体焊缝节点源改为显式的第一组件：选择流程拆为“节点来源组件”和“几何/连接目标组件”两次单选；Shell 按平行边界或最近边线取节点，Solid 按距第二组件最近外表面的边线取节点，并阻止组件 ID 排序颠倒两者角色。

- Fix the cross-module command audit findings (docs/module_command_audit_2026-08-08.md,
  probes verified headless on 2019.0.0.70 and 2022.0.0.33):
  (1) fem_auto_seam: the batch remesh loop guarded on `hm_getmeshfaceparams`,
  which reports "entity not found" on both builds right after a successful
  `*set_meshfaceparams`, so `faceCount` always reached 0 and every remesh
  failed with "automesh did not produce any temporary face mesh" - the
  unused diagnostic read and its empty-check break are removed; the two
  dead `hm_viewfit` calls in the review UI are removed as well.
  (2) geometry_cleanup: `*surfacefilletremove` works on 2019 but errors on
  2022, and the old `*surfacemarkremovelinefillets` fallback errors on both
  builds - the 2022 branch now queries `hm_getfilletfacesfrommark` on the
  chamfer-chain mark and deletes the found faces via `*deletemark surfs`
  (both commands verified on both builds; the 2019 path is unchanged).
  (3) rbe2_bolt_connector: `verifyEndpointCoordinates` read
  `dataname=coordinates`, which is not a valid node dataname on either
  build - it now reads x/y/z like the main path; `replaceOneNode` no longer
  errors when the native merge is unavailable, because five probes on both
  builds proved `*replacenodes`, `*equivalence` and
  `*replacentitywithentity(mark)` never merge coincident free nodes headless
  - coincident pairs now count as replaced (callers only invoke it with
  coordinate-identical nodes) and `forceBeamEndpointNodes` accepts the
  coincident originals in its final check.
  (4) Dead-command cleanup across modules: all 17 `hm_viewfit` /
  `hmbr_signals` / `hm_blockbrowserupdate` calls removed from
  workflow_common, midsurf, fem_auto_seam, mesh_seam_weld, seam_surface,
  auto_hole_rbe2, geometry_cleanup, rbe2_bolt_connector,
  shell_washer_hole_rbe2, local_mesh_optimizer and weld_integrity_check.
  (5) Audit rating corrections backed by probes: batch_temp_nodes
  (`*deletemark nodes "by id only"` works on 2019 for free nodes, undo is
  functional), contact_setup (5-arg `*adjustcontactsurfacenormal` works on
  both builds; group dataname fallback already in place) and auto_hole_rbe2
  (`*findfaces` + `*feoutputwithdata` export verified on both builds) are
  healthy; the `^faces` and deletemark findings were false positives.
  Verification: 13 edited files pass Tcl syntax checks; the offline suite
  passes (34 tests + 9 subtests; the sole batch_mesher failure is a
  pre-existing flaky test interaction, it passes in isolation); the
  geometry_cleanup 22 branch was replayed headless on both builds with
  tools/fix_verify_geometry_cleanup22.tcl (19 keeps the original path,
  22 takes the new branch, both without errors).
- Fix the adhesive area connector (打胶连接) on the installed HyperMesh builds
  (2019.0.0.70 / 2022.0.0.33).  The module now reliably creates a realized
  1D Connector of type Area with realization type `adhesives` (OptiStruct
  FE type 121, realized as RBE3 + HEXA8) using the constrained options
  (tolerance 50, 1 coat, constant thickness 1.0).  Three defects fixed:
  (1) the pure-Tcl location cleaning fallback evaluated the dominant normal
  axis with the literal string `abs(...)` instead of `expr {abs(...)}`, so
  every polygon grid expanded by the tolerance on the wrong axis and all
  location elements were rejected; (2) `primeGeometryCache` assumed
  `hm_getvalue ... mark=N` returns rows in mark-creation order, but rows are
  ordered by entity ID on both builds - element/node caches were misaligned,
  corrupting coordinates for elements whose IDs are not contiguous with the
  mark (98/2400 elements rejected in the 10k-element scale model);
  (3) the polygon spatial grid used the tolerance as cell size, collapsing a
  large plate into a handful of cells with up to 10k polygons each - the
  cell size is now derived from the local mesh density (2x typical in-plane
  span) with the tolerance applied only along the normal axis.  Verified
  headless on both builds: the 10k-element scale model cleans 2400 location
  elements to exactly 2000 kept / 400 rejected in ~9-10 s (was 847 s), the
  15 offline unit tests pass, and the full end-to-end probe (dialog flow
  through `createAdhesive` with connector realization) passes on 2019 and
  2022.
- Fix the solid seam connector (实体焊缝) creation on the installed HyperMesh
  builds: the native seam realization requires a tolerance large enough to
  cover the local mesh and joint gap.  A tolerance of 1-2 mm fails
  (`connector_state=failed`, no elements) while 3 mm and above realize
  PENTA6+RBE3 on the same model; the command profile now computes an adaptive
  tolerance floor `max(6.0, 1.5*mesh_size, max_gap+mesh_size)` from the model
  instead of trusting the candidate value.  The main flow no longer goes
  through the Python pipeline: the user picks two components and a new pure
  Tcl detector (`modules/solid_seam/tcl/auto_detect.tcl`) finds the junction
  node chains taken from the first selected component with a mutual-nearest + largest-gap layer filter (the manual node list matches the user's 239-247 exactly; a fixed tolerance cut the curved seam's ends),
  classifies the joint (T/LAP/BUTT/ANGLED -> PENTA_MIG_T/L/B/MIG) from
  component normals, and derives width/spacing (default 6, clamped to the
  mesh) and the adaptive tolerance.  Weld nodes always come from the FIRST
  selected component and are restricted to its boundary: free-edge nodes for
  shells; for solid components the boundary of the outer face layer closest
  to the target (pitch-adaptive bands + per-face facing dot test so a curved
  contact face keeps its whole outline while perpendicular side faces stay
  excluded; pyramid5 now emits its full 5-face set and the solid free-edge
  threshold was fixed from 1 to 2).  Chain building ranks candidates by
  distance with the turn penalty applied after the gap gate, so ring-shaped
  contact outlines stay a single chain.  Verified headless on 2019.0.0.70
  and 2022.0.0.33: F03 curved-T with the web picked first picks exactly the
  manual node list 239-247 (9 nodes, T_JOINT, 14 PENTA6 + 45 RBE3, PASS,
  output SEAM_SOLID); with the base picked first the strict first-component
  rule yields the base-side contact rows (2 x 3 nodes, REALIZED PASS).  The
  C01 solid-plate validation case now finds the full 20-node bottom ring as
  one LAP_JOINT chain (30 PENTA6 + 90 RBE3, PASS on both builds); see
  docs/solid_seam_dual_version_alignment_2026-08-08.md.  The Python
  detection pipeline and its tests are kept as legacy and are not used by
  the main flow.  module_status solid_seam_connector.runtime = native.
- Fix the repository tracking audit vs `.gitignore` conflict: the audit tool
  (tools/repository_audit.py) now exempts the versioned acceptance fixtures
  under `examples/AutoShellSeamBackend/test_fem/` exactly like the `.gitignore`
  `!/examples/AutoShellSeamBackend/test_fem/` negation rules, so
  `python tools/run_offline_tests.py` no longer aborts at the audit step and
  the CI "Run offline tests" step and hybrid_core
  `test_git_tracking_policy_is_clean` pass again. Doc note added to
  doc/repository_layout.md.
- Record the five modules that were missing from `modules/module_status.json`
  (batch_mesher, fem_auto_seam, midsurf, geometry_cleanup, cbush_creator); the
  file now covers all 18 registered modules. batch_mesher is production
  (dual-version verified with hmbatch smoke tests), fem_auto_seam is controlled
  (HM2019 validation protocol pending), the legacy Tcl modules are production.
- Remove the deprecated casting_tetramesh module (its registration, module
  file, `config/casting_mesh_rules.txt`, and all documentation references).
- Add the FEM Automatic Seam section to the offline guide (guide.html): new
  sidebar entry, dashboard card, and a full module section (function,
  steps, parameter table with defaults, safety notes) mirroring the Mesh
  Seam Weld layout; it was the only module missing from the guide.
- Point the stale `modules/batch_mesh_washer.tcl` reference in
  doc/INTEGRATION_ANALYSIS.md at the current `modules/batch_mesher/`
  location (the old file was merged into the BatchMesher module).
- Align the geometry seam module with the locally installed HyperMesh builds
  (2019.0.0.70 and 2022.0.0.33, verified headless with the same fixtures on
  both; see docs/geometry_seam_dual_version_alignment_2026-08-07.md). Both
  builds accept only mark slots 1/2/3, so the mark-5 internal snapshots used
  since the mark-99 fix silently returned empty on every strategy; the module
  now detects a usable internal slot at runtime (`internal_mark_slot` config
  override, probes 5 then 3). `hm_info currentcomponent` returns the
  component name on both builds, so `native::current_component` converts it
  to an id before the collector re-read verification. `*offset_surfaces_and_modify`
  parses with the signed distance last on both builds (measured z=+2 for the
  previous "recorded" layout vs z=-12 documented); EXTEND now calls
  `surfaces 2 0 1 2 -<distance>` so the configured `extend_offset_distance`
  actually applies. `*connect_surfaces_11` extend-mode-3 consumes the source
  surface (rebuilds it with a new id) and creates seam strips sharing the
  target's edge lines; T_PATH/T_LIST/L_LIST identify the strips, re-home them
  into the seam component and use the rebuilt source as the source-side
  topology partner. A headless 12-strategy harness
  (tools/probe_geometry_seam_harness.tcl) passes all functions on both
  versions with identical created-entity ids; offline suite 40 passed.
- Audit every HyperMesh Tcl command used by the production modules against
  the two local builds (238 native candidates probed headless on both;
  tools/audit_hm_commands.py + tools/check_hm_command_signatures.py). All
  documented commands match their call sites. Corrected commands that exist
  on neither build: `*viewfit` -> `hm_viewfit` (fem_auto_seam, mesh_seam_weld,
  weld_integrity_check, local_mesh_optimizer), `*redraw` -> `hm_redraw`
  (batch_temp_nodes, cbush_creator), `*shownumbers` removed (local_mesh_optimizer,
  `*numbersmark` already covers it), `*contactsurfremoveelems` fallback
  removed (contact_setup; `*removeelemsfromcontactsurf` is the documented
  command), `hm_getsurfacesfromline` fallback removed (geometry_cleanup),
  and `*surface_patch` is now guarded by an existence check because it exists
  on 2022 but not on 2019 (geometry_cleanup). GUI-only commands that cannot
  be verified headless (hm_viewfit, hm_registerkeyproc, hm_blockbrowserupdate)
  remain catch/existence-guarded. The mesh_seam_weld offline suite keeps a
  pre-existing order-dependent failure pair unrelated to these changes.
- Fix the geometry seam "everything succeeds but nothing appears" failure on
  HyperMesh 2019. The on-machine diagnostic showed mark 99 is rejected by
  HM2019 (`hm_getmark: markmask should be ...`), and the module used mark 99
  for every internal snapshot/existence/component-surface fallback query, so
  those queries silently returned empty: REPLACE_POINT reported success
  without moving anything, DISTRIBUTE_POINTS reported failure even when points
  were created, and creation flows lost their model-wide new-entity
  detection. All internal mark 99 uses now use mark 5 (business marks 1/2 are
  untouched). `set_current_component_checked` no longer hard-fails when the
  current component cannot be re-read after `*currentcollector` (HM2019 has
  no `hm_getcurrentcollector`); it logs a warning and continues, while the
  created-surface owner check still catches wrong-component results. The
  diagnostic gained probes for `hm_info currentcomponent`, component
  surface-list datanames (`surfaces`/`surfs`), `collector.id`, list creation
  and a mark-slot sweep (slots 1/2/3/5/9/10/20/99) so the supported mark
  range can be confirmed directly on the target machine.
- Add a built-in command diagnostic to the geometry seam module (new
  `modules/seam_surface/diagnose.tcl`, "诊断" button on the panel). It probes
  every HyperMesh Tcl command the module relies on (62 commands): read-only
  queries are exercised with safe arguments and reported as OK/ERR with the
  returned value or error; destructive, panel and history commands are
  checked for existence only (EXIST/MISS) so the diagnostic never modifies
  the model. The compact per-line report is shown in a narrow Tk window sized
  for a phone photo, echoed to the HyperMesh command window, and saved to
  `%APPDATA%\HMWorkFlow\logs\geometry_seam_diagnose_*.log` for sharing.
- Remove every geometry seam feature that depended on behavior verified only
  on HyperMesh 2022.3, because the target workstations run 2019 and 2022.2:
  the projection + ruled T_LIST pipeline (`*surfacemarksplitwithlines` normal
  trim, path matching, `*surfacemode 4` + `*linearsurfacebetweenlines`,
  endpoint-gap repair) and its candidate helpers are deleted; the
  two-surface-group T Surface flow (`*connect_surfaces_11 1 2 1 ... 59 0`) is
  deleted; the `hm_entityinfo geometryvisible/elementsvisible` display queries
  and `hm_entityinfo exist -byid` existence query fall back to the legacy
  `hm_getvalue ... dataname=visible/displayed` and mark-based lookups;
  `suggest_extend_distance` (adaptive T extend distance) is deleted. The
  settings panel no longer offers the 2022.3-only knobs (adaptive extend
  distance, extend offset type, extend connect trim mode, point projection
  tolerance, public query API switch) and its validation list matches the
  retained 2019/2022.2 configuration keys. Tests were reduced to the baseline
  routes (38 geometry seam tests, all passing).
- Restore the geometry seam module's HM2019 baseline native calls. The
  2026-08-07 audit corrected `*connect_surfaces_11`, `*offset_surfaces_and_modify`
  and `*projectpointstoedges` argument layouts against the HM2022.3
  documentation, but the project baseline (and the offline workstations) is
  HyperMesh 2019.0.0.70, where the legacy layouts are the ones that produced
  results. The T Path / T List entries now route through the line-based
  `*connect_surfaces_11 1 2 3 ... 59 0` flow again (seam lines + target
  surfaces, thickness prompt restored), EXTEND uses the recorded
  `*offset_surfaces_and_modify surfaces 2 2 1 <dist> 2` + `*connect_surfaces_11
  1 1 3 2 ...` layout, and REPLACE_POINT uses the legacy `-1` projection
  distance. The projection + ruled pipeline and the audit-corrected wrappers
  are retained in the codebase (with their tests) for later HM2022 validation,
  but are no longer the active 2019 route. Settings that only apply to the
  retained 2022 flows (adaptive extend distance, extend offset type, extend
  connect trim mode) were removed from the settings panel so users are not
  misled by knobs that do not affect the 2019 baseline.
- Fix geometry seam operations that previously reported success while producing
  no usable result: EXTEND now fails when the native extension created no seam
  surface and left the source surface untouched (previously it returned the
  unchanged source surfaces as the "extended" result); DISTRIBUTE_POINTS now
  fails when no point was created instead of completing with zero points;
  PROJECT/SPLIT now fails when the split command neither created nor modified
  the selected surfaces; the T Surface flow now runs the same topology
  equivalence gate as the other creation flows so a disconnected seam is
  rejected (or downgraded to a warning with `topology_connection_required=0`)
  instead of being reported as a success. The module panel is reopened after
  each precise operation (and after leaving continuous mode) so the result
  message and warnings are actually visible, and operation warnings are now
  appended to the status message instead of being silently dropped.
- Complete the geometry seam `T_LIST` connection stage and repair projected-path endpoint gaps. The ruled surface creation keeps the HyperMesh kernel API (`*surfacemode 4` + `*linearsurfacebetweenlines 1 1 2 2 1`), but the post-processing now reuses the CONNECT strategy's verified connection chain: the preliminary ruled surfaces are merged with `*multi_surfs_lines_merge 1 0 0` under the pinned session cleanup tolerance (shared `merge_ruled_surfaces` helper, CONNECT and T_LIST both use it) before topology equivalence, so the seam is topologically connected instead of a free-standing sheet. When one source path is trimmed across adjacent Target Surfaces and the kernel leaves nearly-coincident-but-not-identical segment endpoints at the surface transition, the pipeline now detects those gaps (configurable `projected_path_merge_tolerance`, default 0.5) and merges each pair through the existing Replace Seam Point flow (`*projectpointstoedges` + `*verticescombine`), then rebuilds the projected candidate paths so one source path maps to one continuous path before the ruled call. Add tests for the merge step and the endpoint-gap repair (tests 78 -> 80).
- Replace the geometry seam `T_LIST` algorithm with the projection + ruled pipeline from the 2026-08-07 refactor spec: source lines are partitioned into connected unbranched paths (branches rejected, disconnected groups handled independently), all selected Target Surfaces are trimmed in one grouped `*surfacemarksplitwithlines 1 2 0 13 0` call (Normal to Surface + Entire Surface + Keep Line Endpoints), the projected trim path is re-identified from the real post-trim target fragments via edge-diff + owner topology + multi-sample arc-length coverage scoring (ambiguous matches are refused), the target path is aligned with same/reverse multi-sample orientation scoring, and one ruled surface per path pair is created with `*surfacemode 4` + `*linearsurfacebetweenlines 1 1 2 2 1` (kernel bow-tie protection). `*connect_surfaces_11` is no longer used on the T_LIST code path (L_LIST keeps the old extend route via `_create_t`), topology equivalence runs against the surviving fragments instead of stale target IDs, and every fatal stage (NORMAL_TRIM_FAILED / PROJECTED_PATH_NOT_FOUND / PROJECTED_PATH_AMBIGUOUS / BRANCHED_SOURCE_PATH / RULED_CREATION_FAILED / TOPOLOGY_EQUIVALENCE_FAILED) rolls the whole transaction back. Add `split_connected_line_paths`, `simple_paths_from_lines`, `sample_ordered_path`, `path_distance_score`, `path_orientation_scores` and `align_ruled_paths` to candidate.tcl, and rewrite the T_LIST unit tests around projection, path ordering, different segmentation counts, reversal, branches, ambiguity, fragment re-identification and rollback.
- Remove the undocumented `*setoption block_browser_update` calls from the shared browser-reset path (`workflow_common.tcl`) and the Auto Hole RBE2 / RBE2 Bolt bulk-create paths, so HyperMesh no longer prints `setoption: Invalid option specified` in the status bar on every run regardless of module outcome; browser throttling now uses the documented `hm_blockbrowserupdate` command exclusively.
- Fix the geometry seam module's HyperMesh API usage found by the 2026-08-07 audit: correct `*offset_surfaces_and_modify` argument order in EXTEND (reserved `surf_mark_id`/`line_mark`, legal `offset_type`, real signed offset), restore distinct source/target marks and a legal `trim_mode` for `*connect_surfaces_11`, verify the Current Component before every native call instead of swallowing `*currentcollector` failures, fail fast on critical `*createmark` failures, source plate thickness from `hm_getthickness` with the Component-name `_Txx` parser as a logged fallback, pin and restore the session `cleanup_tolerance` around `*multi_surfs_lines_merge`, make T-surface distance/angles configuration-driven with an optional gap-adaptive distance, and report global surface diffs with owner/area diagnostics so "nothing was created" is distinguishable from "created in the wrong component". L_SURF's Boolean error message no longer claims an intersection for the reviewed Union opcode (switch via `lap_boolean_opcode` after real-kernel Experiment 1), undocumented commands (`*trim_solids_by_surfaces`, `*edgesmarkaddpoints`, `hm_private_frwk`) are isolated in the new `native_compat.tcl`, state restore uses `hm_entityinfo geometryvisible/elementsvisible` and only touches pre-existing components, `*projectpointstoedges` uses an explicit positive tolerance, component creation no longer opens nested history blocks under the seam transaction, and candidate-mode failures surface through `show_result`. Add API-contract, EXTEND wrapper, mark-ownership, current-component, thickness-source and cleanup-tolerance tests (43 -> 56).
- Remove the geometry seam module's automatic recognition and automatic seam-building flows (analyze/candidate/classifier UI, auto-confidence settings, forced joint/strategy, shortcut scope selector); only precise, manually confirmed creation remains. Extend the settings panel with the remaining audit-configurable parameters: `extend_offset_type`, `extend_connect_trim_mode`, `t_surface_trim_mode`, `topology_connection_required`, `private_history_api` and `use_public_query_apis` for HM2019/HM2022 behavior comparison, plus judgement-strictness controls (`area_tolerance`, `volume_tolerance`, `cleanup_tolerance`, `endpoint_merge_tolerance`) and geometry parameters (`geometry_offset_distance`, `connect_*`, `lap_connect_distance`, `replace_point_projection_distance`, `diagnostic_preserve_failed_geometry`) (tests 56 -> 64).
- Replace FEM Automatic Seam's incremental import-merge with a file-level pipeline: the standalone `before.hm` backup is the only rollback point, the whole model is exported once, Python edits the FEM file itself (shell topology plus verbatim passthrough of non-shell cards), HyperMesh reopens the modified FEM with File > Open semantics to replace the current model, and the ordered chunked native remesh runs directly on the new model. Detection stays scoped to the selected components even though the input FEM now covers the complete model, per-candidate delta files and the combined delta are no longer written, and the second full-model snapshot during execution was removed.
- Add a Batch Temporary Nodes module with multiline `X,Y,Z` input, full-batch validation, rollback on creation failure, and undo for the most recent batch.
- Accelerate FEM Automatic Seam detection with component AABB pruning plus conservative uniform-grid indexes for ray/element and free-edge searches, while retaining the original exact geometry tests and deterministic candidate ordering. Record mesh read, detection, duplicate-check, planning and artifact-write timings separately.
- Scale FEM Automatic Seam to whole-vehicle selections: discover T targets from each free-edge sweep, run large detection jobs in configurable multi-process partitions, cap pathological spatial-index expansion, keep the HyperMesh UI event loop and cancellation active while Python runs, force-terminate timed-out worker trees without blocking on pipe close, and remesh connected regions in bounded native chunks. Remove the redundant whole-model restore after planning/transfer failures and the second restore after native execution has already rolled back.
- Make post-detection FEM Automatic Seam planning linear in vehicle size plus local candidate work: clone the selected model once, realize all accepted candidates sequentially in that single accumulated model, journal and roll back only each candidate's local source edits, preserve per-candidate delta rows at creation time, and maintain the component-element index incrementally instead of copying, set-differencing and rescanning the complete vehicle for every candidate.
- Launch FEM Automatic Seam multiprocessing children through the bundled `pythonw.exe` on Windows so parallel detection no longer flashes CMD windows. Publish the actual worker count through a task-local stage file and show it with continuously updating elapsed time in the existing progress command stream.
- Make FEM Automatic Seam candidate imports resilient to HM2019 partial reads: retry only missing GRID/shell cards through a focused repair FEM; reject degenerate shells and connectivity duplicates against both the current model and the same candidate during Python planning; verify all external GRID dependencies before mutation; and report the candidate/FEM/card/component/connectivity details if the focused retry still fails. Preserve the complete failed-task diagnostics for the configured 30-day failure-retention window instead of immediately deleting everything except `before.hm`; the task-level snapshot remains the final safety boundary.
- Replace FEM Automatic Seam's Python neighborhood smoothing and per-candidate checkpoints with topology-only Python planning followed by one task-scoped HyperMesh element automesh batch. Expand replacement-shell seeds in the live model, fix seam/interface and patch-boundary nodes, commit all temporary faces once, retain native criteria validation, and restore only the task-level `before.hm` on failure.
- Advance BatchMesher to 2.6 and standardize every HM2019/2022 launch on Altair's non-interactive `-nocommand -nouserprofiledialog -tcl` form. The ordinary Validate action and every production run now execute a real hmbatch Tcl/API preflight before any connectivity worker can launch, recording the reported version, actual executable and working directory; warn when a saved concurrency above the two-process live-validation limit is reused.
- Make `install_update.tcl` perform a verified live-session replacement: terminate known BatchMesher children and the persistent Python worker, cancel old HMWorkFlow callbacks, remove stale module namespaces, reload all modules from the selected update root, validate the current BatchMesher launch/profile fixes, and write a per-HyperMesh `install_update.log`. Mark BatchMesher hmbatch children so `shortcut_bootstrap.tcl` skips interactive shortcuts and the unrelated warm Python worker.
- Fix the HyperMesh 2022 worker profile initializer so it reads the shared worker configuration from its Tcl namespace before loading the OptiStruct template and quality criteria; previously every 2022 task failed before `*hm_batchmesh2`, while the 2019 path bypassed the faulty branch.
- Start every BatchMesher hmbatch process from its own worker directory, distinguish an Altair launcher PID from the real worker state handshake, allow HM2022 up to 120 seconds to initialize, and always write manager-side `launch.log` / `manager_failure.log` diagnostics even when hmbatch stdout and stderr remain empty.
- Move BatchMesher execution to detached HyperMesh workers with polled per-group progress, actionable failure summaries, real process-tree cancellation, and one-shot automatic import of the complete merged result with delta verification and rollback.
- Fix the Windows background-process liveness regex so Tcl does not interpret the `[^0-9]` character class as command substitution during progress polling.
- Give hmbatch a startup grace period and make the generated launcher persist pre-worker source errors to `launcher_error.log` and `background.state` instead of reporting only a missing FEM.
- Restore the proven direct Tcl launch path for `hmbatch.exe -tcl ...`, without a PowerShell wrapper or PID handshake.
- Show one optional consolidated CMD monitor for the entire run; it refreshes phase/PIDs/task counts and closes automatically three seconds after completion without controlling worker lifetime.
- Execute independent Surface connectivity groups in isolated parallel hmbatch workers with a configurable concurrency limit, retain each task FEM, combine the results into one archival FEM, and automatically import the complete result once.
- Integrate the real-machine findings: accept `22.000000`, support 2019/2022 worker releases, initialize the 2022 OptiStruct profile and quality criteria, track the actual hmopengl PID, default to two workers, and detect configuration changes. Every worker strips its native model to the newly created mesh without re-importing FEM; `*mergefile` combines those models, exports `batchmesh_result.fem`, and merges the native result into the current session once. Remove the HM2019 FEM translator fallback after it returned zero imported elements, and prevent embedded hmbatch `exit` behavior from overwriting failed states with false completion.
- Decouple the selected hmbatch release from the interactive HyperMesh release. Accept any supported 2019/2022 pairing, detect the worker release inside hmbatch, and use that installation's OptiStruct template and profile initialization.
- Rebuild BatchMesher result handling around native semantics: any newly created elements are a usable mesh even when quality optimization reports a warning; meshing, native packaging and FEM archival statuses are independent; workers no longer delete geometry, nodes or collectors; and every successful task uses the same native merge stage.
- Replace full-snapshot HM aggregation after a production HM2019 run proved that the second `*mergefile` can terminate hmbatch outside Tcl error handling. Aggregate each independently valid worker FEM in a blank model with documented `overwrite_flag=0` ID offsetting, verify every Element delta, save a clean merged HM, export one final FEM, and retain worker HM files only for recovery.
- Fix worker decks that imported only GRID cards in HM2019: replace per-entity `*feoutput_select` with custom Component-state `*feoutputwithdata`, verify the created-element mark before export, use the OptiStruct reader's default property handling during aggregation, and log the selected export/import modes explicitly.
- Replace end-of-poll batch replenishment with a fixed-capacity sliding worker pool. A terminal or dead worker now releases its slot and launches the next pending connectivity group immediately, before slower process-liveness checks for the remaining workers; expose active/target/queued pool counts in the CMD monitor.
- Add the reviewed `FAST_AUTO` mesh-seam mode: shared shell topology detection, T/CONNECT/lap classification, existing/optionally adjusted edge paths, bounded node movement with geometry guards, quad-dominant zipper planning, per-candidate incremental FEM creation and checkpoints, native-quality baseline verification, rollback, reports, and the Weld Integrity Check creation bridge. The legacy imprint/ruled workflow remains available as `LEGACY_MANUAL`; target-node movement and local split are default-off pending HM2019 validation.
- Add the default-off V3 conservative local split for a single planar CTRIA3/CQUAD4 crossed between two unshared boundary edges. It emits stable GRID/replacement/weld IDs, preserves mother PID/component and area/winding, validates stale connectivity before deletion, and participates in candidate rollback. Add execution timing/cancellation audit, richer HTML output, three generated smoke cases, and a JSON/memory benchmark. Multi-shell split propagation remains manual and real HM2019 verification is still required.
- Local Mesh Optimizer now grows narrow-quad expansion plans from failed seeds across non-failed contiguous strip cells, exports one-ring shell topology context for cross-component weld classification, and allows prevalidated support cells to execute in the coordinated Tcl move batch.
- Add HyperWorks 2022 new-interface detection and explicit UTF-8 Tcl loading across startup and nested module loaders to prevent Chinese UI mojibake.
- Make HyperWorks 2022 entity selection fall back to the guide-bar edit widget when panel-mark creation fails, and serialize native FEM import/export while handling hidden translator prompts and stale output files.
- Stabilize persistent-worker startup, heartbeat, shutdown, log compaction, and diagnostics.
- Move user state to `%APPDATA%` and cache/task data to `%LOCALAPPDATA%` or an explicit scratch directory.
- Add task tokens, metadata, success/failure retention, pinning, quota cleanup, detached cancellation, timeout, and process-tree termination.
- Add explicit OptiStruct engineering context and block model mutations when project units are not confirmed.
- Migrate Local Mesh Optimizer and Solid Seam Connector to shared HybridCore task/result services while retaining their legacy compatibility paths.
- Add Local Mesh Optimizer criteria-based Python quality simulation, minimum-step narrow-cell expansion, and region-by-region rollback instead of whole-task rollback.
- Bound Local Mesh Optimizer quality simulation to each candidate's local submesh, index duplicate triangle lookups, and expose detailed Python build-stage progress for large models.
- Coordinate continuous boundary and weld-strip quad expansion as whole node chains; detect one-sided versus two-sided weld movement from adjacent component shell normals.
- Add a safe, size-limited sidecar loader and a binary result envelope for migrated production paths.
- Add the `hmworkflow` Python namespace so all module tests can be collected together without same-name import collisions.
- Correct HM2019 PBEAM/PBAR HyperBeam association and verify it through real `hmbatch.exe` import.
- Add module capability metadata and a repeatable four-case HM2019 integration matrix.
- Add release metadata, whitelist packaging, archive auditing, offline test gates, and markdown-link checks.
- Audit the Git tracking list, remove generated Local Mesh fixtures and a machine-specific runtime validation script from the index, and enforce repository hygiene in the offline test gate.
- Package portable Python from approved file levels only; the locally unpacked `python38/` directory is rejected by both staging and release audit.
