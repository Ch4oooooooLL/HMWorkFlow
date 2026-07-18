# Local Mesh Optimizer performance comparison

## 2026-07-14 live pressure-model baseline and A/B projection

The 62k-shell pressure model produced 11,592 optimizable failures. The live
HM2019 task ran from 21:30:54 to 21:58:43 before a guarded rollback. Its Tcl
metrics recorded 42,691 progress writes (830.32 s), 19,729 log writes
(491.72 s), 6,049 operations (190.04 s topology time), 3,608 local rechecks
(47.91 s) and 30.98 s Tcl/Python communication.

The A implementation now rate-limits progress updates, shows only WARN/ERROR
lines in the live command stream and buffers the complete file log. The B
implementation packs only node-disjoint source regions, batches their split
marks and rechecks, and optionally reuses one Element Quality session for all
conflict-free collapses in a batch.

A read-only replan of the same exported task reduced 5,425 source regions to 33
execution regions and projected 7,065 generated batches down to 112 (98.41%).
This is a scheduling-count projection, not a replacement for the next live
wall-clock run.

## Status

The batch architecture is implemented and covered by offline regression tests. This workstation does not expose a verified HyperMesh 2019 runtime, so no HM wall-clock number is invented here. A live run writes `tcl_performance_metrics.json` in the task directory and `performance_metrics.json` / `performance_metrics.csv` in the report directory.

## Repeatable offline benchmark

Command:

```text
runtime/python/windows-x64/python.exe modules/local_mesh_optimizer/tests/benchmark_batch_planner.py --elements 2000 --batch-size 200
```

Recorded artifact: `doc/local_mesh_optimizer_batch_benchmark.json`.

| Metric | Recorded value |
|---|---:|
| synthetic failed quads | 2,000 |
| batch size | 200 |
| mesh-state construction | 0.0101 s |
| operation adaptation | 0.0233 s |
| presimulation + sparse conflict analysis + packing | 0.1388 s |
| total Python batch planning | 0.1722 s |
| generated batches | 10 |
| legacy split command projection | 2,000 |
| batch split command projection | 10 |

The command counts are structural projections from the Tcl executor: legacy mode invokes `*splitelements` once per quad, while batch mode creates one element mark and invokes it once for all same-method, nonconflicting splits in a batch. They are not claimed as HyperMesh elapsed-time measurements.

An initial all-pairs conflict implementation took about 2.19 seconds for the same 2,000-operation input. Replacing it with resource-indexed sparse candidate generation reduced the conflict/batch stage to about 0.139 seconds on this run. Benchmark times vary by machine and load; the JSON artifact is the current local record.

## HM2019 live comparison record

Run the same saved input model, criteria and settings once in `legacy` mode and once in `batch` mode. Copy the two report-side `performance_metrics.json` files into the test record and complete this table.

| Metric | Legacy | Batch | Source |
|---|---:|---:|---|
| total elapsed | pending HM2019 run | pending HM2019 run | `result.json` |
| Python analysis | pending | pending | `python.timings_seconds` |
| Tcl/Python communication | pending | pending | `tcl_hypermesh.timings_seconds.tcl_python_communication` |
| HM topology operation time | pending | pending | `tcl_hypermesh.timings_seconds.hm_topology_operations` |
| HM command calls | pending | pending | `tcl_hypermesh.counters.hm_command_calls` |
| full-scope rechecks | pending | pending | `full_model_rechecks` |
| local rechecks | pending | pending | `local_rechecks` |
| Python starts | pending | pending | `python_starts` |
| progress writes | pending | pending | `progress_writes` |
| Tcl sources | pending | pending | `tcl_sources` |
| operations attempted | pending | pending | `operation_total` |
| successful/skipped/failed operations | pending | pending | `batch_results/*.json` |

## Equivalence acceptance checklist

- Initial failed-element set matches.
- Operation types proposed by `optimization_actions.csv` match; `operations.json` is an adapter, not a replacement planner.
- Protected nodes and protected boundaries are unchanged.
- Batch failures remain distinguishable (`skipped`, `validation_failed`, `entity_missing`, `hm_command_failed`, `cancelled`/rollback at task level).
- Final failed count and abnormal topology are no worse than legacy mode.
- The final whole-scope guard passes and the model saves/solves normally.
- Any local ID differences caused by HM-created entities are recorded but are not treated as semantic failure by themselves.

## Remaining live-validation boundary

The broader HM2019 test matrix in `doc/local_mesh_optimizer_test_record.md` remains useful for performance coverage across sparse defects, adjacent defects, continuous regions, multiple independent regions, protected nodes, washer regions, RBE2/RBE3 or weld connections, and a large shell model. Runtime validation, snapshots, quality guards, and rollback remain in force; no manual profile token is required to start optimization.
