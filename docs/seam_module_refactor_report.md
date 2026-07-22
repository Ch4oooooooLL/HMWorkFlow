# Geometry Seam Module Refactor Report

## Outcome

The previous hidden, single-file seam-surface implementation was removed and replaced by one Geometry Seam module. The toolkit entry is now visible as **几何焊缝 / Geometry Seam**. It provides local analysis, candidate classification, explicit confirmation, precise creation, editing, deletion, centralized cleanup, and legacy entry compatibility.

The implementation targets Windows and HyperMesh 2019 Tcl/Tk. It does not require Python at runtime and never scans or modifies the full model automatically.

## Files and responsibilities

- `modules/seam_surface.tcl`: lightweight module loader; the previous duplicate implementation is gone.
- `modules/seam_surface/config.tcl`: configuration and runtime state.
- `modules/seam_surface/log.tcl`: lightweight session log under `logs/`.
- `modules/seam_surface/entity.tcl`: entity existence, snapshots, differences, component/surface queries.
- `modules/seam_surface/temp.tcl`: transaction-owned, uniquely named temporary components and entities.
- `modules/seam_surface/state.tcl`: transaction boundary, paired history calls, cleanup, undo, and readable-state restoration.
- `modules/seam_surface/validation.tcl`: input and created-surface validation.
- `modules/seam_surface/candidate.tcl`: local edge extraction, geometric measurements, normals, and path graph analysis.
- `modules/seam_surface/classifier.tcl`: joint classification, strategy routing, confidence, reasons, and warnings.
- `modules/seam_surface/executor.tcl`: non-interactive geometry mutation strategies.
- `modules/seam_surface/selector.tcl`: all HyperMesh selection panels and structured input conversion.
- `modules/seam_surface/legacy.tcl`: compatibility-only forwarding procedures.
- `modules/seam_surface/ui.tcl`: unified analysis, review, precise operation, locate/isolate, and restore UI.
- `modules/seam_surface/main.tcl`: public entry points and toolkit callback aliases.
- `modules/seam_surface/tests/test_geometry_seam.py`: Tcl loading, graph/classifier, compatibility, and safety regression tests.
- `config/seam_rules.txt`: centralized defaults.
- `hw_toolkit_core.tcl`: visible Geometry Seam module registration.
- `modules/module_status.json`: controlled HM2019 validation status.

## Project review and old call relationships

The toolkit loads `modules/<module-key>.tcl` from `hw_toolkit_core.tcl`. The only repository GUI registration for the old seam surface feature was the hidden `seam_surface` entry, calling `::SeamSurf::runAction` and `::SeamSurf::runSettings`. No reviewed helper such as `Get_max_id`, `Get_min_thickness`, `Current_entity`, or `Del_entity` exists in this repository, so the refactor uses existing `::HWFlow` component, naming, assembly, configuration, and browser APIs instead of duplicating missing helpers.

The reviewed source confirms that `T` uses a source edge against target surfaces. The so-called `L surface` implementation creates offset solids and extracts overlap geometry, so its unambiguous internal meaning is `LAP_JOINT`; perpendicular cases with two terminating edge groups are represented as `CORNER_JOINT`. `Connect`, `Project`, and `Extend` retain their observed native command sequences.

| Old entry | New interactive entry | Executor strategy | Main model changes | Risk |
|---|---|---|---|---|
| `Create_seam_surface_T_path` | `interactive::create_t_path` | `T_PATH` | seam surfaces | medium |
| `Create_seam_surface_T_list` | `interactive::create_t_list` | `T_LIST` | seam surfaces | medium |
| `Create_seam_surface_L_surf` | `interactive::create_l_surface` | `L_SURF` | temporary solids, seam surfaces | high |
| `Create_seam_surface_L_list` | `interactive::create_l_list` | `L_LIST` | seam surfaces | medium |
| `Create_seam_connect` | `interactive::connect_edges` | `CONNECT` | ruled seam surfaces | medium |
| `Create_seam_project` | `interactive::project_lines` | `PROJECT` | split target surface | high |
| `Create_seam_combine` | `interactive::combine_surfaces` | `COMBINE` | merged surfaces/lines | medium |
| `Split_surface` | `interactive::split_surface` | `SPLIT` | split target surfaces | high |
| `Create_seam_dist_points` | `interactive::distribute_points` | `DISTRIBUTE_POINTS` | fixed points | low |
| `Create_seam_replace` | `interactive::replace_point` | `REPLACE_POINT` | projected/combined point | medium |
| `Create_seam_extend` | `interactive::extend_surface` | `EXTEND` | extended seam surfaces | high |
| `Del_seam_surf` | `interactive::delete_seam_surface` | `DELETE` | deleted seam surfaces, untrim attempt | high |

Both global names and `::altair::pmgr::pm_common::*` names are retained as forwarding wrappers. They contain no geometry implementation.

## Classification and strategy rules

Only user-selected component pairs or surface groups are analyzed. Boundary lines whose endpoint/midpoint samples lie within `distance_tolerance` of the opposite surface set become candidates. Surface normals are conservatively approximated from non-collinear boundary geometry; unavailable normals yield `UNKNOWN`, never a forced type.

- Normal angle at or below `angle_parallel_max`, with paired nearby edges: `LAP_JOINT`, normally `L_SURF` or `L_LIST`.
- Normal angle at or above `angle_perpendicular_min`, with nearby edges on both sides: `CORNER_JOINT`, normally `CONNECT`.
- The same perpendicular condition with a terminating edge only on one side: `T_JOINT`, normally `T_PATH` or `T_LIST`.
- Angles between the two bands, missing geometry, a branched path, or insufficient evidence: `UNKNOWN`/`REVIEW`.

Line topology is built from endpoint coordinates using `endpoint_merge_tolerance`; it does not depend on entity IDs or selection order. One unbranched component is `PATH`, multiple components are `LIST`, and any node degree above two is `BRANCH` and forces review.

Confidence currently weights angle (25%), distance (25%), measured boundary overlap (20%), path topology (20%), and length (10%). The thickness field remains in the candidate schema for later enrichment. Version 1 always requires user confirmation regardless of confidence (`auto_create_enabled=0`).

## Default configuration

| Setting | Default |
|---|---:|
| parallel angle maximum | 15 degrees |
| perpendicular angle minimum | 75 degrees |
| distance tolerance | 1.0 |
| endpoint merge tolerance | 0.1 |
| minimum seam length | 5.0 |
| distributed point spacing | 7.0 |
| area / volume tolerance | 1e-6 |
| lap construction offset | 50.0 |
| extension construction offset | 12.0 |
| auto-accept / review confidence | 0.85 / 0.60 |

## Safety fixes and behavior changes

- Entity creation is detected by complete before/after ID-set differences. Maximum IDs and contiguous IDs are not used.
- Temporary components use `__HMWF_SEAM_TMP_<time>_<counter>` and are removed by transaction-owned component IDs. A user's similarly named object is never selected for cleanup.
- The lap executor only deletes solid IDs created and registered by its transaction and uses a configured volume tolerance.
- Every high-risk operation passes through one history transaction. Start/end calls are paired, errors are logged, temporary entities are cleaned, and the operation is undone when possible.
- Topology display and fixed-point modes are not forced. Component visibility/current component are restored only when their original values can be read safely on HM2019.
- Distributed point counts are calculated independently for each line. Short lines create warnings, and one failed line does not abort the batch.
- Seam names are normalized as `SEAM_T3_Surf`, `SEAM_T3.5_Surf`, reuse the same-thickness component, and are placed under `Seam_Comps`.
- The old continuous line-surface/line-line panel no longer exists. Its duplicate implementation was removed; equivalent precise operations are available in the unified panel.

## Use

Open **Geometry > 几何焊缝**. For recognition, choose two components or two surface groups, click **分析**, inspect the type, strategy, confidence, reasons, and warnings, optionally override the type/strategy, then click **确认创建**. Use **定位/孤立** and **恢复显示** during review. The lower section runs precise creation, editing, and deletion workflows.

## Validation

Offline tests cover Tcl source loading, all compatibility names, order-independent path/list/branch recognition, T/corner/lap/unknown routing, centralized history, absence of interactive panels in executors, and absence of maximum/continuous-ID tracking.

Results on 2026-07-22:

- 9 new Geometry Seam tests passed, including configuration loading, per-surface-pair candidates, component-scoped post-validation, shortcut routing, and incoming-context precision workflows.
- 298 existing repository tests passed; 1 POSIX-only path-resolution test was skipped on Windows.
- Repository tracking audit, Markdown link check, Tcl source loading, and `git diff --check` passed.
- `tools/run_offline_tests.py` ran all six built-in `unittest` wrappers successfully, then could not launch its four `pytest` commands because `pytest` is not installed in this worktree environment. Those four directories were run directly with standard-library `unittest` discovery (and the repository `python/` path where required), producing the passing results above.

After the Geometry Seam work was completed, the 15 unstaged changes from the original main worktree were imported unchanged by normalized Git patch. Their patch IDs match exactly. Regression tests for all affected executable areas then passed: Geometry Seam 9/9, Local Mesh Optimizer 32 passed plus one Windows-only skip, Mesh Seam Weld 88/88, and Shell Washer/RBE2 30/30.

Runtime corrections from HyperMesh feedback:

- Candidate extraction now emits one candidate per actual source/target surface pair. This prevents a recognized lap candidate containing an entire component's surfaces from being rejected by the single-pair `L_SURF` executor.
- T and edge-connect post-validation now compares surfaces inside the intended seam component, with a global-ID-difference fallback filtered by owner. Target-surface rebuilds and helper topology no longer cause a successful creation to be misclassified and undone.
- Original source/target surface IDs are no longer required to survive commands that legitimately split or rebuild topology.
- Missing component-name thickness is resolved before the executor: a positive configured override is used first, otherwise the interactive layer prompts for thickness.
- The main page captures valid component/surface marks as incoming context. Precise creation buttons analyze that context without opening another selector; without context they retain the interactive selector workflow.
- Geometry Seam shortcuts use `runShortcut` instead of opening the full module directly. `PANEL` mode opens a compact scope selector where component/surface scope can be switched; `CONFIG` mode immediately opens the native selector using the saved `shortcut_scope`.

HyperMesh 2019 smoke validation remains required for native geometry commands:

1. Open a disposable model and enable the module.
2. Run the 30 scenarios in the supplied refactor specification, beginning with standard T path, disjoint T list, corner, lap, project, extend, delete, cancellation, and command-failure rollback.
3. For each operation, compare entity snapshots, component visibility/current component, undo history, and temporary components before and after.
4. Confirm no `__HMWF_SEAM_TMP_*` component remains and non-target components are unchanged.
5. Run legacy names from the Tcl console and confirm they enter the new selector/executor path.

The module is marked `controlled` until that native HM2019 smoke matrix is signed off. The main known limitation is conservative surface-normal estimation from boundary points; curved or degenerate boundaries may remain `UNKNOWN` and require precise mode. Automatic full-model scan and unattended creation are intentionally out of scope.

## Rollback

The implementation is isolated on branch `codex/geometry-seam-refactor`. To roll back before integration, remove its worktree/branch. After integration, revert the integration commit; no data migration or persistent schema conversion is required. Existing `config/seam_rules.txt` can be restored independently if desired.
