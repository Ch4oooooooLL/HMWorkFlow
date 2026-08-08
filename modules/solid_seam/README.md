# Solid Seam Connector

This module implements the `solid_seam_connector_spec.md` workflow inside the existing HyperMesh 2019 toolkit.

## Implemented path

1. Tcl opens the native Components selector. One component opens a second selector; a multi-component first selection proceeds immediately.
2. The pure-Tcl detector (`tcl/auto_detect.tcl`) finds the junction node chains between each component pair (coordinate loop; `*markdistance` does not exist on HM2019/2022), classifies the joint (T / LAP / BUTT / ANGLED -> PENTA_MIG_T / L / B / MIG) from component average normals, and derives width/spacing (default 6, clamped to the local mesh) plus an adaptive realization tolerance.
3. Each candidate is realized through the native 1D connector seam flow: `*createlist nodes 1 ...` + `*createmark comps 2 ...` + `*createstringarray 45 ...` + `*CE_ConnectorCreateByListAndRealizeWithDetails nodes 1 "seam" 2 comps 2 "optistruct" 1001 <feType> <tol> 1 45`.
4. Realization output (PENTA6 config 206 + RBE3 config 56) is moved into the `SEAM_SOLID` component (color 3); empty auto-generated components are removed.
5. Every item fails independently and the batch continues; `realization_result.json` and `operation.log` are written to the run directory.
6. The realization tolerance is adaptive: `max(6.0, 1.5 * mesh_size, maximum_gap + mesh_size)` so the native search always covers the local mesh and joint gap (tolerances of 1-2 mm fail realization on real models; 3 mm and above succeed).

The Python detection pipeline is retained as legacy (`python/`, `python_bridge.tcl`) and is not used by the main flow.

Runtime output is written below `temp/solid_seam/<run_id>` and is intentionally ignored by Git.

## Dual-version verification

Verified headless on the installed builds with the F03 curved-T fixture from
`examples/AutoShellSeamBackend/test_fem/combined_all_cases.fem`:

| Build | candidates | realization | PENTA6 | RBE3 | output |
| --- | --- | --- | --- | --- | --- |
| 2019.0.0.70 | 2 (T_JOINT) | PASS | 48 | 147 | SEAM_SOLID |
| 2022.0.0.33 | 2 (T_JOINT) | PASS | 49 | 150 | SEAM_SOLID |

See `docs/solid_seam_dual_version_alignment_2026-08-08.md`.  Run the harness
with:

```
hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_solid_seam_harness.tcl
```

## Offline test

```powershell
.\runtime\python\windows-x64\python.exe -m unittest discover -s modules\solid_seam\tests -v
```
