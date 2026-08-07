# Geometry seam dual-version alignment (2019.0.0.70 / 2022.0.0.33)

Date: 2026-08-07

## Scope

The geometry seam module (`modules/seam_surface`) was probed and aligned
against the two HyperMesh builds installed on the development machine:

| Install | hmbatch path | version |
| --- | --- | --- |
| HyperMesh 2019 | C:\Program Files\Altair\2019\hm\bin\win64 | 2019.0.0.70 |
| HyperMesh 2022 | D:\Program Files\Altair\hwdesktop\hm\bin\win64 | 2022.0.0.33 |

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
4. `modules/seam_surface/executor.tcl` - T_PATH/T_LIST/L_LIST adapt to the
   kernel's source-replacement behaviour: after `*connect_surfaces_11` the
   seam strips are identified by shared target edge lines, re-homed into the
   seam component, and the rebuilt source becomes the source-side topology
   partner. A warning reports the source renumbering.
5. `modules/seam_surface/config.tcl` - new `internal_mark_slot` key
   (0 = auto-detect).
6. `modules/seam_surface/tests/test_geometry_seam.py` updated for the
   documented offset layout and the internal-slot detection.

## Full-function harness results

`tools/probe_geometry_seam_harness.tcl` drives the module's own executor
dispatch headless, one strategy per fresh fixture (gapped T-joint: vertical
source plate, horizontal target plate, split plate, lap plate, vertex plate).
All 12 strategies pass on both builds with identical created-entity ids:

| Strategy | 2019.0.0.70 | 2022.0.0.33 |
| --- | --- | --- |
| T_PATH / T_LIST / L_LIST | PASS (seam strips; source renumber warning) | PASS (same) |
| L_SURF | PASS | PASS |
| CONNECT | PASS | PASS |
| PROJECT / SPLIT | PASS | PASS |
| EXTEND | PASS | PASS |
| COMBINE | PASS (no-op warning) | PASS |
| DISTRIBUTE_POINTS | PASS (4 points) | PASS |
| REPLACE_POINT | PASS | PASS |
| DELETE | PASS | PASS |

Offline suite: `python -m pytest modules/seam_surface/tests -q` - 40 passed,
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
