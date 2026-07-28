# HMWorkFlow changelog

## Unreleased - platform stabilization

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
