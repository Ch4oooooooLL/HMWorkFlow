# Local Mesh Optimizer performance refactor analysis

## 1. Scope and invariants

This document records the implementation that existed before the batch refactor. The code, rather than the task examples, is the functional baseline. HyperMesh remains the pass/fail and model-modification authority; Python may plan and pre-validate work but must not redefine criteria semantics.

The refactor must preserve:

- HyperMesh 2019-compatible commands and the existing UI workflow.
- Native `*readqualitycriteria` plus `hm_getelementsqualityinfo` quality authority.
- The existing operation trigger thresholds and action ordering.
- User anchors, region boundary anchors, component boundaries, feature/free-edge rules, and the current conservative manual-review fallbacks.
- Protected-node post-checks, the pre-task snapshot, cancellation recovery, failure recovery, and the final whole-scope guard.
- Output-by-save-as behavior; the source model is never intentionally overwritten.

## 2. Current call chain

| Step | File | Procedure/function | Responsibility |
|---|---|---|---|
| Main toolbox entry | `hw_toolkit_core.tcl` | module descriptor `local_mesh_optimizer` | Routes Run/Settings to the module. |
| Tcl UI | `modules/local_mesh_optimizer.tcl` | `showPanel`, `showAdvanced`, `runAction` | Scope, criteria, thresholds, protection and execution controls. |
| Tcl controller | same | `checkQuality`, `startOptimization`, `startOptimizationCore` | Builds the task, coordinates Python, executes changes, rechecks and reports. |
| Native criteria/quality | same | `readCriteria`, `nativeQualityCheck` | Loads criteria once per unchanged file and gets the failed-element mark from HyperMesh. |
| Topology export | same | `exportScope` | Writes shell connectivity and node coordinates. Current HM queries are per element/node. |
| Python entry | `modules/local_mesh_optimizer/python/optimizer_controller.py` | `build`, `finalize`, `report` | File-protocol stages, planning and report orchestration. |
| Connectivity/regions | `adjacency.py`, `region_builder.py` | `build_adjacency`, `build_regions` | Shared-edge topology, connected failure regions, layer expansion and anchors. |
| Candidate generation | `optimization_planner.py` | `plan_optimization_actions`, `_quad_action` | Applies the existing geometry rules to HyperMesh-failed elements. |
| Tcl action execution | `modules/local_mesh_optimizer.tcl` | `runPlannedActions` | Calls the existing HM2019 topology commands; coordinates free-edge moves. |
| Local refresh/recheck | same | `currentRegionElements`, `nativeQualityCheck` | Refreshes the affected region and performs native post-change quality checks. |
| Rollback/final guard | same | `saveModelSnapshot`, `restoreSnapshot`, `qualityWorsened`, final block in `startOptimizationCore` | Restores the pre-task model on command, protection, recheck or final-guard failure. |
| Report | `report_generator.py` | `generate_report` | Writes CSV/HTML summaries from task/result/region files. |

Current execution flow:

```text
UI -> native whole-scope check -> per-entity topology export
   -> one Python planning process -> region loop -> round loop
   -> action loop -> per-action HM command/log/progress
   -> region topology refresh -> region native recheck
   -> final native whole-scope guard -> save-as -> Python report process
```

## 3. Complete implemented operation inventory

HyperMesh first classifies failures using the selected criteria. Python does not infer the criteria failure category; it selects a conservative repair from element arity and local geometry only after HyperMesh has declared the element failed.

| Operation | Applicable element | Trigger in existing code | Prohibitions/fallback | Entities changed | Implementation |
|---|---|---|---|---|---|
| `collapse_short_edge` (tria) | 3-node shell | Both other edge lengths divided by the shortest edge are at least `SKINNY_TRIANGLE_RATIO`. | Short edge touches a region/user protected node; missing coordinates; the element is no longer failed; a planned collapse already claims either endpoint. Falls back to `manual_review`. | HM may replace connectivity, remove the collapsed node and remove/replace affected elements and IDs. | Planner `plan_optimization_actions`; Tcl `*elementqualitysetup`, `*elementqualitycollapseedge`, `*elementqualityshutdown`. |
| `collapse_short_edge` (narrow quad) | 4-node shell | Opposite-edge average aspect is at least `NARROW_QUAD_RATIO`, there is no selected movable long free edge, and the chosen short edge has two owners. | The short edge is protected; no internal short edge; stale/nonfailed element; node conflict. Falls back to `manual_review`. | Same HM-managed collapse effects as above. | Planner `_quad_action`; same Tcl commands. |
| `expand_free_edge` | narrow 4-node shell | Opposite-edge average aspect is at least `NARROW_QUAD_RATIO`; a long-direction edge is a true one-owner edge; controlled movement is enabled; mandatory anchors do not touch it. Target distance is long average / `NARROW_TARGET_ASPECT`, capped per round by `CONTROLLED_EDGE_GROWTH`. | Disabled in quick mode; `PRESERVE_GEOMETRY_ASSOCIATION`; explicit anchors; edge is no longer truly free; mandatory protected edge endpoint. Falls back/skips as manual. | Moves the two edge nodes with coordinated averaged `*nodemodify`; no intentional ID change. | Planner `_quad_action`; Tcl `targetCoordinateFromReference`, `isTrueFreeEdge`, `*nodemodify`. |
| `split_quad` | non-narrow 4-node shell | Compares the minimum normalized triangle score for both diagonals and chooses the better diagonal. | Missing coordinates; stale/nonfailed element; proximity to a claimed collapse endpoint. Falls back to manual. | Deletes/replaces the original quad and creates two trias; HM chooses resulting IDs. | Planner `_quad_action`; Tcl `*splitelements` method `2` or `102`. |
| `manual_review` | failed tria/quad not meeting a safe automatic rule | Missing coordinates, protected edge/nodes, unmatched tria geometry, no valid narrow-quad repair, or a planner conflict. | Never auto-executed. | None. | Planner and `runPlannedActions`. |
| Washer exclusion | washer-region failed shells | `EXCLUDE_WASHER_ELEMENTS` is enabled and the external washer graph procedures are available. | Detection failure conservatively aborts/defers; excluded failures are not sent to automatic planning. | None; reserved for manual processing. | Tcl `washerElementsInScope` and check-stage filtering. |

Operation order is deterministic and currently fixed by `optimization_planner.py`:

```text
collapse_short_edge -> expand_free_edge -> split_quad -> manual_review
```

Within a type, region and element IDs stabilize order. Regions run sequentially; rounds run sequentially; HyperMesh mutations are always single-threaded.

## 4. Protection, validation, stopping and rollback

- Region anchors are built from the expanded-region perimeter, blocked edges and component boundaries. User anchors are always mandatory. Feature edges may be added to blocked edges from dihedral angle.
- Automatic rigid/weld-node discovery is explicitly unverified and disabled; users must select those nodes as anchors. This limitation must remain visible rather than being claimed as implemented.
- Before a round, anchor coordinates are captured. After mutation, every anchor is checked with a `1e-9` tolerance. Any movement triggers task rollback.
- Candidates are executed only while their source element is still in the authoritative failed set. Free edges are revalidated in HyperMesh immediately before movement.
- A region stops on zero failures, no remaining safe actions, max rounds, timeout, cancellation, missing region shells, a command/check failure, or no measurable improvement.
- The existing implementation has one durable pre-task `.hm` snapshot. Any command, topology refresh, protected-node, recheck, cancellation or final-guard failure restores it. There is not yet a durable per-batch snapshot.
- Completion always performs a final whole-scope native quality check. New failures outside optimized regions or growth beyond the topology-replacement allowance restores the pre-task model.

## 5. Data and ID dependencies

| Operation | Deletes/creates | Connectivity/ID dependency | Safe batching implication |
|---|---|---|---|
| `split_quad` | Replaces one quad with two trias; resulting IDs are HM-owned. | Reads the source element ID and its four nodes. Invalidates candidates reading/writing that element or its one-ring. | Batch only with operations having disjoint source/affected one-rings. |
| `collapse_short_edge` | May delete a node and degenerate elements and replace connectivity/IDs in the marked region. | Reads source element, edge index, edge nodes and region mark. Broadest invalidation domain. | Conflicts on shared endpoints, affected elements, one-ring overlap, or replacement chains; serial HM execution remains mandatory. |
| `expand_free_edge` | Moves nodes only. | Reads source element, moving/reference nodes and current one-owner edge status. | Can share a batch only when read/write sets and affected one-rings do not conflict. Multiple proposals for the same moving node must be deduplicated or coordinated exactly once. |
| `manual_review` | None. | Diagnostic only. | Excluded from executable batches. |

## 6. Measured/instrumentable performance hotspots

The pre-refactor code already times native quality calls, Python stage duration and individual topology actions in logs, but it does not aggregate all required counters. The refactor baseline instrumentation must add an authoritative `performance_metrics.json` without changing algorithm decisions.

Ranked static hotspots confirmed from the call sites:

1. `exportScope`: one `hm_getvalue` per element, then one coordinate query per unique node.
2. `nativeQualityCheck`: a native quality database pass before planning, after every mutated region round, and once for the final guard.
3. `runPlannedActions`: one HM topology command sequence per split/collapse and one `*nodemodify` per unique moved node.
4. `currentRegionElements`: repeated entity-existence/connectivity/component queries after each round.
5. Progress/log I/O in the action loop (throttled to about 20 UI updates per action list, but logs remain per executed topology action).
6. Python process startup: build and finalize are separate processes; criteria/config/topology are reparsed on each relevant process.
7. Model I/O: one pre-task save and one result save in a successful task; restore reads the snapshot on failure.

Required aggregate measurements:

| Metric | Baseline source / instrumentation point |
|---|---|
| topology export | around `exportScope` |
| criteria parsing/loading | `parse_criteria_metadata`; `readCriteria` |
| whole-scope quality | initial and final `nativeQualityCheck` |
| classification/candidate generation | Python build-stage sub-timers |
| Tcl/Python communication | `runPython` |
| HM topology commands | action executor counter and timer |
| local recheck | region/batch `nativeQualityCheck` |
| UI/log writes | centralized progress/log counters |
| model save/restore | `saveModelSnapshot` / `restoreSnapshot` |
| operation/source/process counts | centralized counters plus generated batch metadata |

Live HyperMesh timings cannot be fabricated in an offline test. The delivered comparison report therefore separates repeatable Python synthetic measurements from fields that must be populated by an HM2019 validation run.

## 7. Refactor boundary and compatibility strategy

The new architecture will adapt the existing planner output into a richer `Operation` object, then deduplicate, pre-validate, construct read/write/delete sets, create a conflict graph and generate deterministic batches. It will not replace `_quad_action`, the tria rule, thresholds, or HyperMesh-side validation.

Batch mode will be the default while retaining legacy mode for equivalence and incident isolation. Generated Tcl batches will call the existing Tcl operation executor; they will not duplicate topology mathematics. Python analysis may later use processes for demonstrably independent regions, but HyperMesh mutation remains serial.
