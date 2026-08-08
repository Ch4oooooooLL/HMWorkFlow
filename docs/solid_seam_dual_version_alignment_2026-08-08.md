# Solid seam dual-version alignment (2019.0.0.70 / 2022.0.0.33)

Date: 2026-08-08

## Problem

`modules/solid_seam` could not create solid seam welds on the installed
HyperMesh builds.  The module's command profile called
`*CE_ConnectorCreateByListAndRealizeWithDetails` with a realization tolerance
that was too small for the real models, so every realization ended with
`hm_ce_state` = `failed` and no PENTA6/RBE3 elements were produced.

## Evidence (headless, one hmbatch per probe)

| Install | hmbatch path | version |
| --- | --- | --- |
| HyperMesh 2019 | C:\Program Files\Altair\2019\hm\bin\win64 | 2019.0.0.70 |
| HyperMesh 2022 | D:\Program Files\Altair\hwdesktop\hm\bin\win64 | 2022.0.0.33 |

- The command surface is identical on both builds: 110 `*CE_*` commands
  exist, including `*CE_ConnectorCreateByListAndRealizeWithDetails`,
  `*CE_ConnectorCreateByMark`, `*CE_ConnectorSeamCreateUsingLines`,
  `hm_ce_state`, `hm_ce_info`, `hm_ce_getlinkentities`,
  `*CE_FE_SetDetailsAndRealize`, `*CE_AddLinkEntitiesWithArrays`.
- `*markdistance` does **not** exist on either build (junction nodes must be
  found with a coordinate loop).
- Seam connector location accepts an **ordered node list** built with
  `*createlist nodes 1 ...`; `*createmark` (unordered) produces a broken
  ring-shaped location.
- `comps` and `components` are equivalent as the link keyword.

## Root cause

Realization tolerance.  On the real validation model
(`examples/AutoShellSeamBackend/test_fem/combined_all_cases.fem`, F03 curved
T case, 10 mm mesh, 3 mm gap) a tolerance of 1.0 or 2.0 fails
(`connector_state=failed`, 0 elements); 3.0 and above succeed
(`connector_state=realized`, 14 PENTA6 + 45 RBE3 for the user-recorded
45-option call).  The module's old profile inherited a candidate tolerance
that could drop below the local mesh/gap scale.

## Fixes applied

1. `modules/solid_seam/command_profiles/hm2019_penta_mig_common.tcl`
   - `adaptiveTolerance`: computes a floor of
     `max(6.0, 1.5 * mesh_size, maximum_gap + mesh_size)` from the actual
     model (median chain spacing when `mesh_size` is missing) and raises the
     requested tolerance when needed.  The user's default width/spacing of 6
     stays the baseline.
   - The 45-option native seam set (verified from the user-recorded command
     file) plus `ce_configfile` keeps the custom (1001) FE types resolvable.
2. `modules/solid_seam/tcl/auto_detect.tcl` (new, pure Tcl)
   - Replaces the Python detection pipeline in the main flow.
   - `detectJunctionNodes`: source/target node pairs within the search
     distance (coordinate loop; `*markdistance` does not exist).  The node
     list always comes from the FIRST component; a mutual-nearest filter
     keeps only the junction layer (a thick solid's far face is within the
     search distance and would otherwise twist the chain), and a
     largest-gap layer split keeps the whole contact row of a curved seam
     (its gap varies 3.0-5.3 mm along the arc while the next row is a full
     mesh pitch away).  `*createlist` (ordered) is used for the location, as
     the native seam panel records it; unordered marks produce a broken
     ring location.
   - `autoDetectSeams` prefers the more focused side when the first side is
     a flat plate with several parallel rows inside the search distance, so
     the weld nodes follow the actual contact edge in either selection
     order.
   - `buildChains`: orders junction nodes into continuous chains with a gap
     limit adapted to the local spacing (`max(gap_jump_limit, 1.5 * spacing)`
     so a 10 mm mesh does not split every chain).
   - `classifyJoint`: T / LAP / BUTT / ANGLED from the component average
     normals, mapping to PENTA_MIG_T / L / B / MIG.
   - `deriveParameters`: mesh size (median chain spacing), width/spacing
     default 6 clamped to the mesh, tolerance floor.
3. `modules/solid_seam/tcl/main.tcl`, `seam_creator.tcl`, `ui.tcl`
   - `runAction` -> select two components -> `autoDetectAndCreate`
     (detect all pairs, accept, create batch) -> summary.
   - Parameter panel simplified: search distance / max distance / min weld
     length / chain gap / default width (6) / default spacing (6).
4. `modules/solid_seam_connector.tcl` - loads `auto_detect.tcl` instead of
   `python_bridge.tcl` in the main flow.
5. `modules/module_status.json` - `solid_seam_connector.runtime` =
   `native` (no HybridCore dependency for the main flow).

## Headless harness results

`tools/probe_solid_seam_harness.tcl` drives the module's own flow on the real
FEM: template set, `*feinputwithdata2`, `autoDetectSeams`, then
`createOneCandidate` per candidate.

| Case | 2019.0.0.70 | 2022.0.0.33 |
| --- | --- | --- |
| F03 curved T (BASE + WEB) | 1 candidate, 9 nodes (the user's manual node list 239-247), T_JOINT -> PENTA_MIG_T, grade PASS, 14 PENTA6 + 45 RBE3 into SEAM_SOLID | same, 14 PENTA6 + 45 RBE3 |
| C01 solid plate + shell base (SolidSeam_Validation.fem) | 1 candidate, 18 nodes, LAP_JOINT -> PENTA_MIG_L, grade PASS, 30 PENTA6 + 90 RBE3 | same, 31 PENTA6 + 93 RBE3 |

## Amendment 2026-08-08: weld nodes from the first component, boundary only

Requirement: the node list always comes from the FIRST selected component;
only boundary nodes are candidates; if the source component is solid, use
the boundary of the face of that solid that faces the target component
(its closest face).  Adapted in `modules/solid_seam/tcl/auto_detect.tcl`:

- `autoDetectSeams` always calls `detectJunctionNodes` with the first
  component as the source; the old forward/reverse preference heuristic
  (which could pick the second component's nodes) was removed.
- `boundaryNodesOfComponent`: solid free-edge threshold fixed from 1 to 2
  (a solid edge belongs to two faces of its own element, so body free edges
  are counted twice) - before the fix pure-solid components returned no
  boundary nodes.  `pyramid5` (108) now emits its full 5-face set (base
  quad + 4 side triangles) instead of only the base, so its silhouette is
  correct.
- `solidFacingBoundaryNodes`: keeps the outer face layer closest to the
  target with pitch-adaptive bands (faceBand = 0.3 * median edge length,
  nodeBand = 0.35 * pitch).  A face must also face the target: its outward
  normal (face centroid - owning element centroid, ring winding is not
  reliable) vs the direction to the face's own nearest target node must
  stay above dot 0.25.  Per-face direction keeps a side face's dot at ~0
  regardless of how the source/target centroids are offset (a global
  centroid-to-centroid direction leaked one side face of a thin block and
  dropped exactly one corner of the contact ring).  Face ring order is kept
  from the first encounter (a sorted face key alone turns quad diagonals
  into pseudo edges and leaks interior rows into the outline).
- `buildChains`: the turn penalty is now applied after the distance gate
  (candidate must be within the gap limit; the penalty only ranks it).  The
  old code compared the penalized score against the gap limit itself, so a
  90 deg step at the ring corner (e.g. 19->20) scored above the limit and
  was rejected - the ring outline split into stub chains and corner nodes
  vanished from the weld.

Re-verified headless on both builds with `tools/probe_solid_seam_harness.tcl`
plus the mock offline test `tools/solid_seam_detect_mock_test.tcl`
(8 checks: shell perimeter, solid silhouette, pyramid, flat/curved facing,
first-component rule; run with plain tclsh):

| Case | 2019.0.0.70 | 2022.0.0.33 |
| --- | --- | --- |
| F03 curved T, WEB first | 1 candidate, 9 nodes = manual list 239-247, T_JOINT, PASS, 14 PENTA6 + 45 RBE3 | same |
| F03 curved T, BASE first (strict first-component rule) | 2 candidates, 3 + 3 nodes (base-side contact rows), T_JOINT, both PASS, 3 + 3 PENTA6 + 12 + 12 RBE3 | same |
| C01 solid plate + shell base | 1 candidate, 20-node bottom ring (was 18 / 0 candidates), LAP_JOINT, PASS, 30 PENTA6 + 90 RBE3 | same |

The C01 bottom ring is now the full symmetric perimeter (nodes 10 and 18
included); the ring stays one chain and realizes cleanly.  The F03 9-node
web-side chain (matching the manual list) appears only when the web is
selected first, which is the expected consequence of the strict
first-component rule.

## Offline regression

`python tools/run_offline_tests.py` passes (repository audit, markdown links,
wrapper suites, pytest suites; solid_seam 19 tests).

## Notes

- The Python detection pipeline and its tests are kept as legacy and are not
  used by the main flow.
- C01-style fixtures in older command-file recordings reference component
  names that no longer exist in the current validation FEM; the harness uses
  the current `combined_all_cases.fem`.
