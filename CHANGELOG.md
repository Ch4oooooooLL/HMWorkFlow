# HMWorkFlow changelog

## Unreleased - platform stabilization

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
