# Geometry seam dual-version alignment (2019.0.0.70 / 2022.0.0.33)

Date: 2026-08-07; current-tree rerun and correction: 2026-08-11

## 2026-08-12 installed-machine recalibration

The available installations were re-discovered instead of relying on the
historical paths below. HyperMesh 2019.0.0.70 is installed at
`D:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe`. HyperMesh
2022.0.0.33 is installed under the vendor directory named `2020`, at
`D:\Program Files\Altair\2020\hwdesktop\hm\bin\win64\hmbatch.exe`;
`hm_info` is used as the authoritative version rather than that directory
name.

All 12 public geometry-seam strategies were rerun on both versions in
separate clean hmbatch processes against the current repository tree. Every
strategy passed on both versions, and the per-strategy success, created IDs,
areas, bounding boxes, edge-owner topology, messages, warnings, and final
surface sets were identical. The T_LIST result surface shared one edge with
the source surface and one edge with both split target fragments, and L_SURF
retained only the four faces in the selected overlap envelope.

The rerun also repaired two calibration-harness defects.  The T_LIST logging
wrapper now forwards the current optional matching-mode and tolerance
arguments, so it exercises the strict production selector instead of causing
an artificial fallback.  The command audit now creates a line list from a
live post-`*edgesmarkaddpoints` line ID; HyperMesh renumbers that line during
point insertion, so the old audit produced a false `*createlist` error.

Offline suite: `python -m pytest modules/seam_surface/tests -q` - 58 passed,
18 subtests passed.

## 2026-08-11 current-tree correction

The 2026-08-07 `12/12 PASS` statement was no longer true on the current
tree. A clean rerun of every strategy in a fresh hmbatch process reproduced
the same two failures on both installed builds:

- `T_PATH`: the non-interactive executor called
  `::hmtoolkit::seam::selector::duplicate_ids`, although the hmbatch executor
  harness intentionally does not load the interactive selector.
- `T_LIST`: trimming created the complete boundaries of two target fragments.
  The seven new lines formed one graph with two degree-3 junctions, so the old
  selector rejected the entire graph as branched instead of extracting the
  internal projected edge. If the selection gate was bypassed, the ruled
  surface was free-standing: all four of its edge lines had only the seam
  surface as owner.

The current implementation removes the executor-to-selector dependency,
enumerates simple routes through branched fragment-boundary graphs, ranks
them against the selected source path, and rejects score ambiguity. After
ruled creation it merges/stitches under the configured cleanup and topology
tolerances and verifies the real edge owners. On the shared fixture, the
final T_LIST seam has one edge owned by source+seam and one edge owned by both
target fragments+seam. Both installed builds now pass all 12 strategies in
separate fresh processes with identical result IDs.

The settings surface was aligned with the parameters actually consumed by
the executor. It now includes projected-path matching, documented EXTEND
offset/trim/distance controls, replace-point projection distance, all
topology/quality tolerances, thickness override, and the local mark-slot and
diagnostic switches. Obsolete recognition-era `distance_tolerance` was
removed. `config/seam_rules.txt` records the same defaults and preserves
descriptive notes when the panel saves it.

The first HM2019 GUI pass on the generated STEP then exposed two gaps that a
pre-supplied-thickness hmbatch fixture could not show. T Surface stopped in
the selector when imported CAD had no readable thickness; it now prompts for
one. Lap Surface reported success but moved all nine surviving solid-offset
faces into the result, including construction faces extending 48-50 mm away
from the selected plates. The executor now filters results against the
original two-surface bounding envelope (`lap_result_envelope_tolerance`,
default 0.5), leaving the four faces that bridge the selected plates. The
output component is explicitly shown and synchronized after a successful
transaction. T Surface, Lap Surface, and T List were rerun successfully on
both installed builds after these corrections.

## Scope

The geometry seam module (`modules/seam_surface`) was probed and aligned
against the two HyperMesh builds installed on the development machine:

| Install | hmbatch path | version |
| --- | --- | --- |
| HyperMesh 2019 | D:\Program Files\Altair\2019\hm\bin\win64 | 2019.0.0.70 |
| HyperMesh 2022 | D:\Program Files\Altair\2020\hwdesktop\hm\bin\win64 | 2022.0.0.33 |

Every finding below was produced headless with
`hmbatch -nocommand -nouserprofiledialog -tcl`, one hmbatch process per
probe, on a fresh model. The two builds behaved identically on every probed
command.

## Command-level evidence

- Mark slots: only 1, 2 and 3 are valid. Slots 4-10, 20, 99 fail with
  "Invalid mark id found in file". Mark 5 - used by the module since the
  HM2019 mark-99 fix - is invalid on both local builds.
- `hm_info currentcomponent` returns the component NAME (`auto1`), not an id.
- `*offset_surfaces_and_modify`: signature is
  `entity_type mark_id surf_mark_id line_mark offset_type offset` with the
  signed distance LAST. Measured: `surfaces 2 0 1 -3 -12` moved the surface
  to z=-12, while the previous `surfaces 2 2 1 -12 2` layout moved it to
  z=+2. `surf_mark_id` must be 0 or an empty mark.
- `*connect_surfaces_11` (mode 3, advanced_options=59): creates the seam
  strips AND consumes the source surface (the kernel rebuilds the source with
  a new id). The strips share the target's edge lines; the rebuilt source
  does not. Identical on 2019 and 2022.
- `*projectpointstoedges 2 1 -1 0`: accepted; the -1 distance works.
- `*linearsurfacebetweenlines 1 1 2 2 1`, `*surfacemarksplitwithlines 1 2 0 13 0`
  and `*multi_surfs_lines_merge 1 0 0`: accepted and functional on both.
- `*verticescombine`: the second argument is a mark id; both points must be
  real surface vertices.
- `hm_getcurrentcollector`: missing on both builds (module already downgraded
  gracefully).
- `hm_getlinesfromsurface`, `hm_getedgesfromsurface`,
  `hm_getsurfacesfromline`, `hm_getvalue ... dataname=surfs`: missing or
  invalid on both; the module has catch fallbacks.

## Fixes applied

1. `modules/seam_surface/entity.tcl` - runtime internal mark slot detection
   (`entity::internal_slot`, probes 5 then 3, overridable with config key
   `internal_mark_slot`). All snapshot/existence/component queries use the
   detected slot. Without this every strategy failed at validation with
   "entity does not exist" because mark 5 is invalid on both local builds.
2. `modules/seam_surface/native_compat.tcl` - `current_component` converts
   the name returned by `hm_info currentcomponent` to an id so the post-set
   collector verification actually runs.
3. `modules/seam_surface/executor.tcl` - EXTEND now calls
   `*offset_surfaces_and_modify surfaces 2 0 1 2 -<distance>`; the previous
   layout silently ignored the configured `extend_offset_distance` and
   hard-coded a +2 offset on both builds.
4. `modules/seam_surface/executor.tcl` - T_PATH/L_LIST adapt to the
   kernel's source-replacement behaviour: after `*connect_surfaces_11` the
   seam strips are identified by shared target edge lines, re-homed into the
   seam component, and the rebuilt source becomes the source-side topology
   partner. A warning reports the source renumbering.
5. `modules/seam_surface/config.tcl` - new `internal_mark_slot` key
   (0 = auto-detect).
6. `modules/seam_surface/tests/test_geometry_seam.py` updated for the
   documented offset layout and the internal-slot detection.
7. `modules/seam_surface/candidate.tcl` and `executor.tcl` now extract the
   projected T_LIST route from split-fragment boundary graphs and require the
   ruled surface to share topology with both contacting sides.
8. EXTEND now uses the documented `trim_mode` domain (baseline 1 instead of
   the former undocumented 2) and reads its offset type, offset distance,
   trim mode, distance and angle controls from settings. Both local builds
   pass the resulting baseline call.

## Full-function harness results

`tools/probe_geometry_seam_harness.tcl` drives the module's own executor
dispatch headless, one strategy per fresh fixture (gapped T-joint: vertical
source plate, horizontal target plate, split plate, lap plate, vertex plate).
All 12 strategies pass on both builds with identical created-entity ids:

| Strategy | 2019.0.0.70 | 2022.0.0.33 |
| --- | --- | --- |
| T_PATH / T_LIST / L_LIST | PASS (T_LIST owner topology verified; L_LIST source renumber warning) | PASS (same) |
| L_SURF | PASS | PASS |
| CONNECT | PASS | PASS |
| PROJECT / SPLIT | PASS | PASS |
| EXTEND | PASS | PASS |
| COMBINE | PASS (no-op warning) | PASS |
| DISTRIBUTE_POINTS | PASS (4 points) | PASS |
| REPLACE_POINT | PASS | PASS |
| DELETE | PASS | PASS |

Offline suite: `python -m pytest modules/seam_surface/tests -q` - 44 passed,
16 subtests passed.

## Reproducing

- `tools/probe_geometry_seam_commands.tcl` - parametric per-command probes
  (`HM_PROBE_TEST=marks|connect_tlist|offset_repo|...`).
- `tools/probe_geometry_seam_harness.tcl` - per-strategy module harness
  (`HM_REPO=<repo>`, `HM_STRATEGY=<strategy>`; run one hmbatch per strategy
  from an empty workdir).

## Notes

- The module fix history claimed mark 5 was usable on the offline HM2019
  baseline; the locally installed 2019.0.0.70 rejects it (slots 1-3 only).
  The runtime probe makes the module correct on both machines without
  assuming one slot.
- A T flow on a fully closed joint (target exactly touching the source)
  creates no seam strips and fails with "The native extension created no seam
  surface" - expected: there is no gap to bridge.
- The old EXTEND offset layout's hard-coded +2 offset was geometrically
  favourable in some legacy models, which is why it appeared to "work" on the
  2019 baseline. With the documented layout the configured
  `extend_offset_distance` now actually applies, so seam size may change on
  models that relied on the accidental 2 mm offset.

## Repository-wide command audit (same day)

Beyond the geometry seam module, every HyperMesh Tcl command used by the
production modules was audited against the two local builds.

Method:
1. `tools/audit_hm_commands.py` extracts every `*command` / `hm_command`
   token from `modules/**/*.tcl` and the root Tcl files, filters repo-defined
   procs, and emits `tools/probe_hm_commands_existence.tcl`.
2. The existence probe runs one hmbatch per build (238 native candidates);
   results: 2022 and 2019 agree on every command except `*surface_patch`
   (2022 only).
3. `tools/check_hm_command_signatures.py` compares each production call site
   with the installed 2022 Help signature.

Fixes applied (all commands are invalid on both local builds unless noted):
- `*viewfit` -> `hm_viewfit` (documented GUI command): fem_auto_seam and
  mesh_seam_weld auto_ui, weld_integrity_check review, local_mesh_optimizer
  (3 sites). `*viewfit` exists on neither build; `hm_viewfit` is documented
  but GUI-only (not registered in hmbatch), so the calls remain catch-guarded
  no-ops in batch and become functional in interactive sessions.
- `*redraw` -> `hm_redraw` (documented, present on both builds):
  batch_temp_nodes (2 sites), cbush_creator.
- `*shownumbers` removed (exists on neither build; `*numbersmark elems 1 1`
  already displayed the labels): local_mesh_optimizer (3 sites).
- `*contactsurfremoveelems` removed from the fallback chain (exists on
  neither build; `*removeelemsfromcontactsurf` is the documented command and
  is present on both): contact_setup.
- `hm_getsurfacesfromline` removed from a fallback chain (exists on neither
  build; `hm_getsurfacesfromedge` is present on both): geometry_cleanup.
- `*surface_patch` guarded by `info commands` (2022 only): geometry_cleanup
  no longer attempts the invalid command on 2019.

Signature verification: all documented commands matched their production call
sites, including the complex ones (`*hm_batchmesh2`, `*midsurface_extract_10`,
`*surfacecreateruled`, `*surfacemarkfeatures`, `*tetmesh`, `*springos`,
`*rbe3`, `*feoutputwithdata`, `*barelementcreatewithoffsets`,
`*beamsectionsetdataroot`, `*beamsectionsetdatastandard`,
`*interactiveremeshelems`, `*getqualitysummary`, `*hm_failed_elements_cleanup`,
`*set_meshfaceparams`, `hm_findprojected`, `hm_getelementsqualityinfo`, ...).

Commands that are present on both builds but undocumented in the installed
2022 Help (kept, catch-guarded or isolated): `*createnode`, `*propertyupdate`,
`*elementorder`, `*dictionaryload`, `*displayimporterrors`, `*featureangleset`,
`*linefromsurfedge`, `*edgesmarkaddpoints`, `*trim_solids_by_surfaces`,
`hm_nodevalue`, `hm_nodelist`, `hm_pushpanel`, `hm_getsolidboundsforsurfaces`,
`hm_private_frwk`.

GUI-only commands (documented, present in interactive sessions but not in
hmbatch; calls are existence-guarded or catch-wrapped, so batch behaviour is a
no-op): `hm_viewfit`, `hm_registerkeyproc`, `hm_blockbrowserupdate`.

Regression: offline suites for the touched modules pass (batch_temp_nodes,
contact_setup, local_mesh_optimizer, cbush_creator, weld_integrity_check,
solid_seam, fem_auto_seam, auto_hole_rbe2, rbe2_bolt_connector, seam_surface:
382 passed, 1 skipped, 16 subtests). The mesh_seam_weld suite has a
pre-existing order-dependent failure pair (2 tests fail only when the full
module suite runs; the failing names vary between runs and it reproduces
without any of these changes).
