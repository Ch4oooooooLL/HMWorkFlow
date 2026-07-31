# Automatic shell seam protocol

`mesh_seam_weld/python/main.py` adds `auto_detect` and `auto_plan` modes without
changing the legacy modes. Inputs are a selected-component native FEM bundle,
request JSON, and existing-seam JSON. Stable task outputs are:

- `candidates.json`: classified `T_PATH`, `T_LIST`, `CONNECT`, `L_SURF`,
  `L_LIST`, or `REVIEW` candidates;
- `creation_plan.json`: explicit user-reviewed realization plans;
- `delta.fem` and `delta_manifest.json`: newly allocated shell entities only;
- `report.json` and `report.html`: summary and audit trail.

V1 creates `EXISTING_EDGE_PATH` plans. V2 optionally creates
`ADJUSTED_EDGE_PATH` plans by moving a strictly bounded set of target-path
nodes. Any ambiguous, duplicate, branched, over-limit, poor-quality, or
unaccepted candidate remains review-only. The fast path never invokes imprint,
ruled surfaces, automesh, or connectors.

## Implemented scope and known limits

- `T_PATH`, grouped `T_LIST`, and `CONNECT` are detected and can be created
  when the target is an existing continuous edge path.
- `L_SURF/L_LIST` classification is available; creation uses the same
  conservative existing-edge condition and otherwise remains manual review.
- unequal open paths use a quad-dominant zipper with a configured triangle
  ratio limit; unequal closed paths, branches, and three-way junctions are
  review-only.
- `ADJUSTED_EDGE_PATH` is implemented behind `allow_target_node_move` and is
  disabled by default. It protects shared/feature/explicitly protected nodes,
  enforces absolute and local-edge-relative movement limits, checks affected
  shell area/normals/aspect, and backs off to 75/50/25 percent when needed.
- execution validates stale references, saves a task snapshot and a checkpoint
  for every accepted candidate, applies grouped node translations, imports a
  candidate-specific delta, compares native HyperMesh quality with the
  pre-change baseline, and rolls back only the failed candidate. If checkpoint
  recovery fails, the task snapshot is restored and execution stops.
- `LOCAL_SPLIT_PATH` is implemented behind `allow_local_split` and disabled by
  default. Its validated offline scope is deliberately narrow: one planar
  first-order CTRIA3/CQUAD4 mother shell, one open projected path, and endpoints
  strictly inside two distinct unshared boundary edges. It triangulates both
  sides of the constraint path, preserves the mother PID/component, checks
  area, winding and aspect, then emits new GRID and replacement cards. Shared
  edge propagation, multi-element traversal, vertex endpoints and interior-only
  endpoints remain manual review.
- V3 execution validates original connectivity, deletes the old mother only
  after the candidate checkpoint, verifies new GRID/shell IDs, coordinates,
  connectivity, PID/component and native quality, and restores the checkpoint
  on failure.
- existing `SEAM_T*` centroids are exported for conservative duplicate checks.
  Partial-overlap editing and candidate split/merge are not automated.
- a real HyperMesh 2019 smoke test and a model-specific timing comparison with
  legacy imprint/ruled have not yet been performed.

Planning writes a self-contained HTML audit plus JSON manifest. Model execution
writes `execution_report.json` with per-candidate CREATED/ROLLED_BACK/CANCELLED
status and snapshot, node-move, delete, import, native-quality, rollback and
total timings. `examples/AutoShellSeam/benchmark_detector.py` emits a stable JSON
benchmark including peak Python memory; HyperMesh export/import and the legacy
comparison must be measured in the target installation.

## HM2019 smoke checklist

Use HyperMesh 2019.0.0.70 with the OptiStruct profile. Verify module load,
component selection, FEM export, candidate isolation/review, explicit
acceptance, snapshot creation, delta import, `SEAM_Tx` organization,
connectivity, element normals, free edges, native quality criteria, rollback,
cancellation, and a second consecutive run. Do not promote the module from
`controlled` until this checklist is completed on a real installation.
