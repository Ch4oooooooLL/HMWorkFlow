# Solid Seam Connector

This module implements the `solid_seam_connector_spec.md` workflow inside the existing HyperMesh 2019 toolkit.

## Implemented path

1. Tcl opens the native Components selector.
2. Tcl classifies the selection and enforces the two-component and multi-component mode rules.
3. Tcl exports only selected component topology to versioned JSON.
4. Bundled Python extracts supported solid exterior faces, boundary/feature edges, target triangles, distance-valid segments, edge chains, joint recommendations, confidence, and duplicate annotations.
5. Tcl displays candidates, previews node marks, permits acceptance/rejection/type changes/reversal, and performs batch creation.
6. Every model write passes preflight validation and a verified HyperMesh Command File profile. Each item fails independently and the batch continues.
7. The run directory contains `request.json`, `mesh_data.json`, `candidates.json`, `accepted_candidates.csv` when exported, `operation.log`, and `realization_result.json` after creation.

Runtime output is written below `temp/solid_seam/<run_id>` and is intentionally ignored by Git.

## Required HM2019 verification before creation

Candidate recognition is usable immediately. Connector creation is deliberately blocked by default because this repository does not contain a captured target-machine Command File for PENTA MIG realization. Follow `command_profiles/README.md`, add the four verified profiles, then set their `verified` flags in `config/realization_profiles.json`.

This gate prevents guessed connector parameters from modifying a model.

## Offline test

```powershell
.\runtime\python\windows-x64\python.exe -m unittest discover -s modules\solid_seam\tests -v
```
