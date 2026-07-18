# HMWorkFlow changelog

## Unreleased - platform stabilization

- Stabilize persistent-worker startup, heartbeat, shutdown, log compaction, and diagnostics.
- Move user state to `%APPDATA%` and cache/task data to `%LOCALAPPDATA%` or an explicit scratch directory.
- Add task tokens, metadata, success/failure retention, pinning, quota cleanup, detached cancellation, timeout, and process-tree termination.
- Add explicit OptiStruct engineering context and block model mutations when project units are not confirmed.
- Migrate Local Mesh Optimizer and Solid Seam Connector to shared HybridCore task/result services while retaining their legacy compatibility paths.
- Add a safe, size-limited sidecar loader and a binary result envelope for migrated production paths.
- Add the `hmworkflow` Python namespace so all module tests can be collected together without same-name import collisions.
- Correct HM2019 PBEAM/PBAR HyperBeam association and verify it through real `hmbatch.exe` import.
- Add module capability metadata and a repeatable four-case HM2019 integration matrix.
- Add release metadata, whitelist packaging, archive auditing, offline test gates, and markdown-link checks.
