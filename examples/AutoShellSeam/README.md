# AutoShellSeam examples

Run `generate_cases.py` with the bundled Python 3.8 runtime to generate three
small deterministic FEM decks:

- Case 1 uses an existing continuous target edge (`EXISTING_EDGE_PATH`).
- Case 2 uses a bounded target-edge offset (`ADJUSTED_EDGE_PATH`).
- Case 3 crosses one target quad (`LOCAL_SPLIT_PATH` when explicitly enabled).

The decks are generated artifacts and are intentionally not committed. They
cover offline planning; model mutation, native quality and rollback must still
be exercised by the real HyperMesh 2019 smoke checklist.
