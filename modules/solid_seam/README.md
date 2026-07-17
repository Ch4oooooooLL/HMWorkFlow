# Solid Seam Connector

This module implements the `solid_seam_connector_spec.md` workflow inside the existing HyperMesh 2019 toolkit.

## Implemented path

1. Tcl opens the native Components selector. One component opens a second selector; a multi-component first selection proceeds immediately.
2. Tcl exports each selected component to its own native OptiStruct FEM file, preserving selection order separately from solver property IDs.
3. Bundled Python reads and classifies the FEM meshes. Supported inputs are two solid components, two shell components, or a mixed multi-component selection containing at least one solid.
4. Python extracts source boundary/feature nodes, target surfaces, distance-valid chains, penta realization type, adaptive parameters, confidence, and duplicate annotations.
5. Solid/solid and shell/shell pairs are accepted and created directly. Mixed selections use the existing candidate preview/editor before batch creation.
6. Every model write passes preflight validation and a verified HyperMesh Command File profile. Each item fails independently and the batch continues.
7. The run directory contains `request.json`, `component_<id>.fem`, `candidates.json`, `accepted_candidates.csv` when exported, `operation.log`, and `realization_result.json` after creation.

Runtime output is written below `temp/solid_seam/<run_id>` and is intentionally ignored by Git.

## Required HM2019 verification before creation

Candidate recognition is usable immediately. Connector creation is deliberately blocked by default because this repository does not contain a captured target-machine Command File for PENTA MIG realization. Follow `command_profiles/README.md`, add the four verified profiles, then set their `verified` flags in `config/realization_profiles.json`.

This gate prevents guessed connector parameters from modifying a model.

## Offline test

```powershell
.\runtime\python\windows-x64\python.exe -m unittest discover -s modules\solid_seam\tests -v
```
