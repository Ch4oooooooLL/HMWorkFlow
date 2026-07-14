# Local Mesh Optimizer batch architecture

## Execution modes

- `batch` (default): Python adapts the existing decisions into operations, pre-validates, deduplicates, constructs a conflict graph, packs stable batches and generates Tcl batch files. Tcl sources one batch at a time and serially modifies HyperMesh.
- `legacy`: reads the unchanged `optimization_actions.csv` and uses the previous per-action executor. It exists for equivalence tests, special-model fallback and diagnosis.

Select the mode under Advanced Settings. The persisted key is `EXECUTION_MODE`; accepted values are `batch` and `legacy`.

## Flow

```text
HyperMesh whole-scope criteria check
  -> one topology/coordinate export
  -> existing Python action rules
  -> node-disjoint source-region macro packing
  -> Operation adapter + MeshState
  -> stable deduplication + conservative presimulation
  -> sparse resource-indexed conflict graph
  -> deterministic stage/priority/region batches
  -> source generated Tcl batch
  -> existing HM operation procedures/commands
  -> batch result + dirty nodes/elements
  -> dirty one-ring native recheck
  -> reuse combined incremental failure state
  -> final whole-scope native guard
```

## Operation schema

`operations.json` retains the original action in `legacy_action` and adds:

- stable `operation_id`, existing `operation_type`, `stage`, priority and status;
- source and affected nodes/elements;
- `read_set` containing read/write/delete node and element sets;
- validation layer/result/reason;
- metadata including region, original reason and whether HM owns resulting IDs.

`split_quad` records the original `split_method`. `collapse_short_edge` records the original edge endpoints and uses deterministic midpoint node replacement. `expand_free_edge` retains both moving and reference nodes and the target distance; its otherwise-unused `split_method` compatibility field carries the connected free-edge chain ID.

Connected `expand_free_edge` operations intentionally share one coordinated batch even when they overlap at boundary nodes. Tcl averages all proposals at a shared node, separates disconnected chains, quantizes similar directions and distances into blocks, and executes one marked-node translation per block. This avoids repeated movement at batch boundaries and reduces native command traffic on long straight boundaries.

## Deduplication

- Element actions: `(operation_type, element_id)`.
- Edge actions: `(operation_type, min(node_a,node_b), max(node_a,node_b))`.
- Stable first-wins follows the existing planner order. Removed duplicates are written to `deduplication_events.json`; they are never silently counted as successful.
- Replacement chains are treated conservatively through collapse endpoint read/write dependencies; the current operations do not expose a verified HM keep-node direction, so the adapter does not fabricate a replacement map.

## Presimulation

Python rejects only clearly invalid candidates: stale source entities, missing nodes, invalid/zero-area or duplicate quad splits, nonexistent collapse edges, protected collapse/move nodes, and free edges that are not one-owner edges in the exported state. HyperMesh-side existence/free-edge checks, anchor verification, native quality checks and rollback remain authoritative.

## Conflict rules and packing

An edge is added when operations share write nodes/elements, delete another operation's read/write entity, overlap affected one-rings, or a collapse endpoint invalidates another operation's input. Candidate pairs are created from inverted node/element resource indices rather than an all-pairs scan.

Before operation packing, node-disjoint source regions may be greedily combined into macro regions. The default caps are 200 source regions, 500 failed elements and 10000 expanded elements. Source regions with overlapping expanded nodes are never combined. Their anchors are unioned, so packing cannot relax an existing protection boundary.

Operation packing is stable: stage, priority, macro region and operation ID order, followed by first-compatible batch placement and `BATCH_MAX_OPERATIONS`. Same-method quad splits from different source regions inside one macro region therefore share a marked command. HyperMesh mutations never run concurrently. Optional Python process analysis (`ANALYSIS_WORKERS`, maximum 8) is used only when execution regions have disjoint node sets; otherwise planning remains serial.

## Dirty region and incremental recheck

Each action returns source elements and touched nodes. Tcl rebuilds the dirty shell set from current owners of those nodes and expands it by `DIRTY_EXPANSION_LAYERS` (0-3). It rechecks only that set, then combines the result with previously failed elements outside the dirty coverage. This preserves a comparable region-level failure state. The next round reuses that combined state instead of performing a redundant full-region precheck.

One native recheck covers the union of dirty islands in a macro region. Failure IDs are still compared against the macro region's combined pre-change state, and final completion still performs the whole-scope guard.

Within one conflict-free batch, collapse operations can reuse one `*elementqualitysetup` / `*elementqualityshutdown` session. The individual `*elementqualitycollapseedge` calls remain serial. `REUSE_ELEMENT_QUALITY_SESSION=0` restores the per-operation setup/shutdown path for HM2019 compatibility diagnosis.

Deleted source IDs remain in dirty coverage for invalidation even if they no longer exist. New HM-created shell IDs are discovered from the touched-node owners. Final completion still performs one native whole-scope guard.

## Tcl/Python files

Inputs remain UTF-8 `task.json`, line-oriented ID files and compact connectivity/coordinate CSV. New planning outputs:

- `operations.json`, `conflicts.json`, `deduplication_events.json`;
- `batches.json`, `batch_tasks.csv` and `batches/*.tcl`;
- `python_performance_metrics.json`.

Each sourced Tcl file only reconstructs a list of existing action dictionaries. It does not duplicate topology logic. Macro packing sharply reduces file count for sparse large models. Execution writes `batch_results/<batch>_round_NN.json` with operation status, dirty nodes/elements and elapsed time. Tcl aggregate timings include emitted/suppressed progress events and log line/flush counts; report-side merged metrics are JSON and CSV.

## Status and rollback

Operation results distinguish `success`, `skipped`, `validation_failed`, `entity_missing` and `hm_command_failed`. Cancellation and quality/protection failures trigger the existing task-level `cancelled` / `task_rolled_back` paths. A batch command failure is recorded before propagating the error. The pre-task snapshot and final guard remain mandatory.

## Known limitations

- HM2019 has executed the existing split/collapse path on the supplied pressure model. The new multi-collapse session reuse still requires a fresh live comparison; disable `REUSE_ELEMENT_QUALITY_SESSION` if that build rejects repeated collapse calls in one session.
- Rigid/weld automatic protection discovery remains unverified and disabled. Use explicit anchor nodes.
- Collapse-created/deleted IDs are HM-owned. Dirty topology is rediscovered from touched-node ownership rather than predicted.
- Same-method quad splits are submitted as one marked HM command per macro batch. Collapse calls remain per element but reuse their surrounding Element Quality session.
- Python multiprocessing is intentionally conservative and defaults to one worker.

## Troubleshooting

- Missing `batch_tasks.csv`: rerun Check Quality after selecting batch mode; a plan created with different settings is invalidated automatically.
- Batch identity/count mismatch: preserve the task directory and generated batch file; do not edit it manually.
- `validation_failed`: inspect `operations.json` and the operation reason; switch to legacy only for controlled equivalence diagnosis, not to bypass protection on production data.
- `hm_command_failed`: inspect `batch_results`, `optimizer.log`, the Python logs and `command.cmf`; the task should restore `before.hm`.
- Quality guard rollback: compare dirty batch results with the final failed mark and verify protection/criteria/profile assumptions.
