# HyperMesh RBE2/Bolt Parallel Batch Generation Research

## Scope

This note records the investigation result for adding batch or parallel generation to the current HyperMesh 2019 Tcl/Tk workflow toolkit, especially for:

- Solid through-hole RBE2 generation.
- Shell washer-hole RBE2 generation.
- RBE2-based bolt CBEAM/CBAR generation.
- BatchMesh + washer generation.

No implementation changes were made as part of this research.

## Short Conclusion

The project can support stronger batch processing, but true multithreaded generation inside one HyperMesh session is not recommended.

Recommended execution model:

1. Use single-session batching, chunking, caching, and reduced UI refresh for one open model.
2. Use multiple independent `hmbatch` processes only when jobs can be split into independent models or safe model partitions.

Avoid running multiple Tcl threads that write to the same HyperMesh database at the same time.

## Why Same-Session Multithreading Is Risky

The current scripts rely heavily on HyperMesh session-global state:

- Global marks: `*createmark`, `hm_getmark`, `*clearmark`.
- Current collector/component changes.
- Fixed temporary component names.
- Fixed output component naming rules.
- Namespace-level arrays and caches.
- Tk windows and progress UI state.

These are not isolated per worker. If two workers create nodes, RBE2 elements, beams, or temporary free faces at the same time in one HyperMesh session, they can overwrite marks, move entities to the wrong component, delete another worker's temporary component, or corrupt duplicate checks.

## Evidence From Current Code

### Solid Through-Hole RBE2

File: `modules/auto_hole_rbe2.tcl`

Key observations:

- `::AutoHoleRBE2::runCore` processes all selected components as one job.
- It creates a component mark from all selected components, then calls `*findfaces components 1`.
- It uses a fixed temporary free-face component name from `cfg(faceCompName)`, default `^faces`.
- It can delete the old temporary component before processing and delete it again after processing.
- It writes all output RBE2 elements to `cfg(resultCompName)`, default `RBE2_HOLE_AUTO`.

Important locations:

- `runCore`: `modules/auto_hole_rbe2.tcl:1183`
- selected component mark and source element collection: `modules/auto_hole_rbe2.tcl:1207`
- old `^faces` cleanup: `modules/auto_hole_rbe2.tcl:1224`
- free-face generation: `modules/auto_hole_rbe2.tcl:1237`
- fixed result component duplicate index: `modules/auto_hole_rbe2.tcl:1292`
- RBE2 creation loop: `modules/auto_hole_rbe2.tcl:1306`
- final `^faces` cleanup: `modules/auto_hole_rbe2.tcl:1347`

Assessment:

This module is not safe for same-session parallel execution without substantial isolation work. The fixed `^faces` component alone is enough to cause worker interference.

### Shell Washer-Hole RBE2

File: `modules/shell_washer_hole_rbe2.tcl`

Key observations:

- `::RB2W::main` loops over selected components serially.
- `::RB2W::processComponent` is already a component-level unit of work.
- It builds per-component free-edge graphs and creates RBE2 elements.
- It has performance-oriented options such as node coordinate cache, progress throttling, and batch organization.
- Created RBE2 elements can be batch-moved to output components through `BATCH_ORGANIZE_RBE2`.

Important locations:

- per-component worker function: `modules/shell_washer_hole_rbe2.tcl:1618`
- loop over selected components: `modules/shell_washer_hole_rbe2.tcl:1832`
- RBE2 creation for each accepted hole: `modules/shell_washer_hole_rbe2.tcl:1717`
- batch organization of created RBE2 elements: `modules/shell_washer_hole_rbe2.tcl:1747`

Assessment:

This is the best candidate for stronger single-session batching, because its logical unit is already a component. It still should not run multiple component workers concurrently in one HyperMesh database, because marks, output components, caches, and RBE2 candidate indexes are shared.

### RBE2 Bolt Connector

File: `modules/rbe2_bolt_connector.tcl`

Key observations:

- It first collects candidate RBE2 records, groups them, and then loops through groups to create adjacent CBEAM/CBAR segments.
- Output component names are based on prefix, estimated diameter, and element type, for example `BOLT_Dxx_CBEAM`.
- Duplicate segment detection depends on component-level indexes and namespace-level state.

Important locations:

- bolt group creation loop: `modules/rbe2_bolt_connector.tcl:1129`
- output component naming: `modules/rbe2_bolt_connector.tcl:1164`
- beam/bar creation per pair: `modules/rbe2_bolt_connector.tcl:1173`
- GUI-driven entry: `modules/rbe2_bolt_connector.tcl:1198`

Assessment:

This stage should remain single-session serial. It has global grouping behavior and cross-RBE2 relationships. Parallelizing individual groups inside one model would risk duplicate or inconsistent beam creation unless the grouping and write phase are completely separated.

### BatchMesh + Washer

File: `modules/batch_mesh_washer.tcl`

Key observations:

- The module already uses chunking rather than one huge command.
- Surface BatchMesh runs in chunks controlled by `surface_batch_size`.
- Washer creation can group holes with identical rules and run them in batches controlled by `washer_batch_size`.
- `config/mesh_rules.txt` already exposes related knobs.

Important locations:

- surface chunk loop: `modules/batch_mesh_washer.tcl:533`
- washer batch chunking: `modules/batch_mesh_washer.tcl:882`
- main workflow: `modules/batch_mesh_washer.tcl:1001`
- config keys: `config/mesh_rules.txt:10`

Assessment:

This module already implements the right kind of single-session batching. Further improvements should focus on tuning chunk sizes, reducing progress refresh, and improving failure fallback, not same-session threading.

## Recommended Architecture

### Level 1: Improve Single-Session Batch Performance

Use this for one open model.

Recommended improvements:

- Keep component-level serial loops.
- Increase batch sizes where safe:
  - `washer_batch_size`
  - `surface_batch_size`
  - RBE2 organization batch size
- Reduce UI refresh frequency.
- Avoid browser refresh until the end of a module.
- Prefer one mark/move operation for many created elements rather than per-element organization.
- Keep duplicate checks object-level but cache indexes per source component or output component.

This is the safest and highest-priority path.

### Level 2: Add Headless Module APIs

Current modules are mostly GUI-first. To run in `hmbatch`, add non-GUI entry points that accept IDs/options directly:

```tcl
::RB2W::runHeadless $compIds $options
::AutoHoleRBE2::runHeadless $compIds $options
::RB2Bolt::runHeadlessByComponents $compIds $options
::BatchMeshWasher::runHeadless $compIds $options
```

Each headless entry should:

- Skip `showPanel`.
- Load config/state only if requested.
- Accept component IDs, component names, or include names.
- Write a log file.
- Return a structured summary list or dict.
- Avoid `tk_messageBox`.
- Avoid GUI-only progress windows.

### Level 3: Multi-Process Batch With `hmbatch`

Use this only when jobs are independent.

Recommended model:

```text
controller
  -> creates job_001.tcl, job_002.tcl, ...
  -> starts several hmbatch processes
  -> each process opens one model or one isolated model partition
  -> each process runs headless module APIs
  -> each process saves independent output
  -> controller collects logs and summaries
```

Example shape:

```bat
<altair_home>\hm\bin\<platform>\hmbatch.exe -tcl jobs\job_001.tcl
<altair_home>\hm\bin\<platform>\hmbatch.exe -tcl jobs\job_002.tcl
```

Parallel process count should be limited by:

- HyperMesh license availability.
- RAM usage.
- Disk I/O.
- Whether the model can be safely split.

## When Multi-Process Parallelism Is Suitable

Good cases:

- Many independent `.hm` files.
- One assembly that can be split by include/subsystem and saved into independent temporary models.
- Shell washer-hole RBE2 generation where components are independent and final outputs do not need cross-component duplicate checks.
- Batch meshing independent sheet-metal components where final merging is not needed or can be controlled.

Poor cases:

- One monolithic model that must stay open and be modified in place.
- RBE2 bolt connector generation requiring global grouping across all RBE2 center nodes.
- Jobs that use fixed temporary component names in the same database.
- Jobs where output components may collide by name.

## Model Splitting And Merging Concerns

If one large model is split for multi-process work, merging results is the hard part.

Risks:

- Entity ID collisions.
- Component name collisions.
- Duplicate RBE2 or bolt elements at partition boundaries.
- Lost organization metadata.
- Include file ownership issues.
- Material/property/card-image inconsistencies.

Safer merge approach:

- Assign unique output component prefixes per job.
- Reserve ID ranges per job if the solver/profile supports this cleanly.
- Export only generated connector entities when possible.
- Import generated connector entities into a master model.
- Run final duplicate and dependency checks in the master model.

## Recommended Implementation Roadmap

### Phase 1: No Parallelism, Better Batch Throughput

- Tune existing batch settings.
- Add a global "performance mode" policy for RBE2/bolt modules.
- Delay browser refresh until module completion.
- Expand structured summaries and logs.

### Phase 2: Headless APIs

- Split each target module into:
  - GUI parameter collection.
  - Pure execution core.
  - Summary/report layer.
- Replace message boxes in core paths with errors or result dictionaries.
- Add test job Tcl scripts for `hmbatch`.

### Phase 3: Multi-Process Runner

- Add a controller script that writes job Tcl files.
- Add per-job temp directories and logs.
- Add process count limit.
- Add job summary aggregation.

### Phase 4: Optional Model Partition Support

- Add include/subsystem/component partitioning rules.
- Add output component prefix and ID range strategy.
- Add final merge/check workflow.

## Practical Recommendation

For the current project, the next engineering step should not be Tcl threads. The next step should be to add headless APIs and keep single-session writes serial.

After that, use multiple `hmbatch` processes only for independent files or carefully isolated model partitions.

