# Offline Auto Shell Seam Backend

This directory validates the FEM-level automatic shell-seam backend and its
criteria/param-driven finite-neighborhood optimizer.  The same backend is now
available as the independent **FEM Automatic Seam** tool in HyperMesh 2019.

Run the complete fixture matrix from the repository root:

```powershell
python examples\AutoShellSeamBackend\run_backend.py
```

Ready-to-import acceptance FEM files are versioned under `test_fem/`; no
generator run is required before manual testing.  Start with
`case_02_angled_t/input.fem` for the complete backup/plan/import/export flow,
then use the other nine cases for classification and boundary coverage.

For one-pass testing, import `test_fem/combined_all_cases.fem` and select all
of its shell Components.  The ten scenarios are separated by 500 mm and every
Component name starts with `F01_` through `F10_`.  `combined_cases.json` maps
each scenario to its Component and entity-ID ranges.  With default settings the
combined model produces 18 candidates: 10 T seams, 3 patch seams and 5 nearby
free-edge candidates; 11 are automatically eligible and 7 remain for review.

The default output is written below
`runtime/tasks/fem_auto_seam/offline_backend/`.  Each case contains:

- `input.fem` and `input_manifest.json`;
- `candidates.json` with confidence, type and automatic eligibility;
- `realization.json` with deleted/replacement/weld entity IDs;
- `optimization.json` with parsed criteria/param metadata, protected nodes,
  accepted moves, and before/after quality summaries;
- `result.fem` and `result_manifest.json`;
- `validation.json` with round-trip and connectivity checks.

The deterministic matrix covers:

1. straight T seam;
2. angled T seam;
3. curved T seam;
4. partial-overlap T seam (only the common source interval is created);
5. one identical source path reaching two stacked target components;
6. one web reaching four independent target components;
7. fully contained parallel patch seam;
8. patch with an internal hole below 30 mm (review only);
9. nearby free edges (detected, review only);
10. far-apart negative control.

Auto realization uses a coplanar multi-element constraint split.  Existing
target edge paths are reused.  Otherwise, only crossed target mother shells are
deleted and replaced with first-order triangles that share the inserted target
constraint path.  A quad-dominant zipper then connects the source free edge to
that path.  Result FEMs are read back through the production shell FEM reader.

The local optimizer protects seam-interface nodes, free boundaries, feature
edges, and nodes shared with elements outside the selected neighborhood.  A
move is accepted only when it adds no Python-side criteria failure, does not
worsen the worst penalty, and improves the local objective.  The live workflow
loads the selected criteria in HyperMesh and applies the native quality guard
before accepting the imported delta.

The criteria and param fields are optional. Blank fields resolve to the
versioned defaults under `modules/fem_auto_seam/defaults/`; the default element
size is `auto`, derived from the finite seam neighborhood. A user-supplied file
overrides only its corresponding default.

The current geometric boundary remains planar first-order target patches.  A
curved source free-edge path is supported, but non-planar target remeshing is a
future extension.

Prepare the production `main.py` result used by the live HM2019 apply test:

```powershell
python examples\AutoShellSeamBackend\prepare_stage2_pipeline.py
```

During execution the production plan uses candidate-scoped FEM deltas and
transaction checkpoints.  They are transient.  A completed task directory is
reduced to exactly two deliverables:

- `before.hm`: the pre-task HyperMesh model used for rollback/undo;
- `result.fem`: the selected scope plus successfully imported SEAM components.

After the HM2019 apply stage, compare every node and element in the Python
result against the FEM exported back from HyperMesh:

```powershell
python examples\AutoShellSeamBackend\verify_completed_pipeline.py <task-dir>
```

High-confidence eligible rows are created immediately after detection.  Only
the remaining low-confidence, review-only, planning-failed, or rolled-back
items are shown afterward. Selecting a row isolates and fits its source/target
pair; **Open Mesh Seam Weld** hands that pair to the existing manual module.

One generated result can also be checked with the installed HyperMesh 2019
solver reader by setting `HMWF_OFFLINE_RESULT_FEM` and
`HMWF_OFFLINE_VERIFY_REPORT`, then running `hmbatch.exe -tcl
hm2019_import_verify.tcl`.
