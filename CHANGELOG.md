# HMWorkFlow changelog

## Unreleased - platform stabilization

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
