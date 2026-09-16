# Native imprint patch validation branch

Branch: `codex/validate-native-imprint-patch`

The manual Mesh Seam Weld workflow now resolves the existing thickness-based
output component before imprint, switches the current component, and calls
`*imprint_nodelist` with `remain 3 create_joint_elems 1`. Thickness selection
retains the existing minimum parsed parent-component thickness rule and the
configured output-component fallback when no thickness tag is available.

Only the elements added to that component by this path are passed to element
Automesh (`*defaultremeshelems`). Both mapped and free mesh types are mixed (2),
and size is `weld_mesh_size`. Component organization and connectivity are kept;
patch boundary nodes are fixed. A closed source rail may also be represented as
an embedded edge loop of the generated patch instead of as part of its exterior
boundary. Source nodes are fixed together with the exterior boundary whenever
they participate in the patch. An empty patch raises a staged error for the
per-path history rollback. The exterior attachment boundary is then validated
topologically: every original boundary node must keep its boundary attachment,
every original boundary edge must be kept or replaced by a chain of newly
inserted nodes, each inserted node must still be closest to the original edge it
subdivides, and no after-remesh boundary edge may fall outside the original
attachment. This accepts in-place subdivision of a long boundary edge, including
on curved rails, where the mesher inserts the new node on the curve and off the
chord by the chord sagitta (0.366-0.377 mm on 16.9-17.4 mm chords at R=97/100 in
HM 2019). Lost attachment nodes, sideways reconnections and unreadable
coordinates fail closed and roll the path back.

Native success is not accepted as proof of attachment. HyperMesh 2019 may
rebuild the native source rail so that the original adjacent source IDs are no
longer an exact element edge; that rebuilt rail is validated against the complete
ordered source path and any difference is logged as a `native_rebuilt` warning
instead of rejecting an otherwise sound native result. A non-manifold edge inside
the new patch is tolerated in the default relaxed mode with a WARN and the mod-2
exterior boundary - the same topology the manual workflow accepts - and rejected
only when `strict_patch_boundary_check` is enabled, which additionally keeps the
exact per-edge equality check described above.

Every failed path is rolled back as one transaction. Imprint, target remesh and
weld creation are committed together or not at all: a failure no longer keeps
the imprint on the target mesh (the former `KEEP_IMPRINT` retention is gone), and
the weld elements, their output component and the mother-mesh mutation are all
undone by the path's own history state. The rollback is verified against the
snapshot taken before the path: component element IDs, shell connectivity and
node coordinates must all come back. An unverified rollback marks the path
`rollback_ok 0` and stops the remaining batch (`executeSeedJobs`) instead of
continuing on a possibly damaged model. A path can only start after the native
Tcl undo recorder is enabled; when the transaction cannot be started, the path
is skipped before it touches the mesh.

## Creation first: retry before blocking

The operator selects an edge because that location is meant to carry a weld, so
the executor is expected to *create* it. A failed attempt is therefore retried
before the path is reported:

- only `AUTOMESH`-stage failures are retried (strip quality, patch attachment,
  non-manifold patch, empty remesh) - an `IMPRINT` failure keeps its existing
  local-T fallback, and a transaction failure is never retried;
- each of the two retries runs with an adjusted weld mesh size (0.6x and 1.5x of
  `weld_mesh_size`) in its own undo transaction, on the model the previous
  rollback restored and verified;
- the retry loop stops immediately when an attempt fails with structural damage,
  when a rollback could not be verified, or when the output component could not
  be cleaned up.

Only genuine damage to the surrounding mesh blocks a path. A failure counts as
structural damage when it reports a changed structural boundary or area, a
duplicated structural shell (shared connectivity or identical coordinates), a
missing or dragged attachment node, a weld strip that is disconnected from the
mother mesh, or a rollback that could not be verified; everything else is a
creation problem and is retried. Those blocks are
reported with a machine-readable `block_kind` (`structural_damage` versus
`creation`), a `PERF ... block_kind=` log line, and a diagnosis that states what
the creation algorithm has to change, so a block is a work item for the creation
algorithm rather than a dead end for the operator.

The number of undone entries comes from the undo stack itself: undo entries are
listed newest first, so the stack captured before the path must still be the tail
of the stack afterwards and exactly the entries above it are undone. Comparing
that tail - instead of searching for the newest label - keeps the count correct
when a rerun pushes an identically named entry, which is what a repeated weld
does. When the failed operation recorded nothing - the HM2022 duplicate-weld
case, where a failing `*imprint_nodelist` leaves the model untouched and pushes
no entry - no undo is issued at all and the model is only verified. Undoing
unconditionally would remove the previously created weld instead of the failed
path. When the pre-path stack was evicted by the history limit, the count is
unknown; the path then falls back to a single undo and relies on the same
verification. Failure records and the plain-text report keep `imprint_kept` for
compatibility; it is always 0 now.

## Mother-mesh (target and source) protection

`*imprint_nodelist` is fed only elements of the selected target components
(`constrainTargetShells` is applied to the by-adjacent halo as well), so the halo
can no longer pull a perpendicular web or flange into the local remesh. After the
weld mesh exists, `validateStructuralMesh` compares the surrounding structural
mesh with the snapshot taken before the path. Only the outcomes that mean the
mesh was destroyed are errors:

- a deleted face, a hole or a sideways reconnection: the component's free-edge
  attachment boundary must survive, accepting in-place refinement and renumbering
  of unprotected free-boundary nodes (the same attachment-preservation test that
  guards the weld patch is reused for the mother mesh);
- a missing or overlapping face: the total shell area of an affected component
  may drift by at most 15 percent. A drift above 2 percent is logged as a WARN
  instead of failing;
- a duplicated face: identical connectivity and coincident-node duplicates are
  rejected when this path introduced them; a duplicate that already existed
  before the path is left alone;
- a destroyed element: collapsed connectivity or coincident nodes, a shell
  without area (all of its nodes on one line), or a shell whose boundary
  crosses itself (a bow-tie or a folded shell);
- a dragged attachment node: shared nodes, source-rail nodes and imprint
  boundary nodes may move by at most a quarter of their local shell edge;
  smaller movement is reported as a WARN;
- a detached weld strip: none of its boundary edges lies on the mother mesh, or
  a rail only coincides with a structural edge while sharing no node with it.

Everything a local remesh legitimately produces stays a warning: needle and
sliver corners (down to 1 degree), aspect ratios from 20 to 100 and beyond,
concave corners, warps beyond 30 degrees, area drift up to 15 percent, small
attachment-node movement, refined rails, hulled patch boundaries and additional
free boundary chains. The limits are checked without
the user's active HyperMesh quality criteria
(`hm_getelementsqualityinfo` terminates HM2019 when no criteria file is loaded,
so it is deliberately not used on this path).

Element *shape* is never fatal on a created patch. The patch is the constrained
remesh of a fixed source rail, so HyperMesh itself produces the same needles,
slivers, concave corners and warps by hand and reports nothing; blocking a weld
for one of them would contradict the creation-first policy. The 2026-09-10
field repro (`tools/audit_mesh_seam_weld_geometry_audit.tcl`, HyperMesh
2019.0.0.70) blocked three of four batch paths with "Near-collapsed shell
corner" (a patch quad with a 179 degree corner that a closed 20 node free-edge
loop forced), "Collapsed shell aspect ratio" (the 0.02 mm node pair of a source
rail forced 0.02 mm patch edges, aspect 125-250) and "Folded, twisted or
self-intersecting shell" (a concave quad on a dense rail); with the audit
recording instead of failing, all four welds were created and their mother mesh
verified, matching the manual Create Patch result. The audit therefore reports
distorted-but-usable shells (one WARN per path, with the worst aspect and worst
corner) and blocks only a shell without usable geometry.


Finally the weld strip itself is checked against the real structural edges
(`validateWeldAttachment`): its boundary must be attached to the mother mesh, and
a rail that merely coincides with a structural edge while using duplicated nodes
is rejected as a detached weld. Free ends and refined rail chains are counted and
reported as a WARN instead of blocking the weld, so curved and multi-segment
welds are no longer rejected by the end-cap chain rule.

The previous structured/ruled executor remains available in code for comparison,
but the manual workflow dispatches to the native patch executor. FAST_AUTO is
independent of this route. Geometry-surface output and the old ruled element-type
controls do not apply to this validation route.

## Existing weld mesh protection

`patch_expand_layers` (default 2, settings key "imprint 局部重绘扩展层数") drives
two things: the by-adjacent mark carried into the imprint, and the
`*imprint_nodelist` `remesh_layers` of the native Create Patch chain.  With the
default 2, the imprint no longer degrades to a plain split: it applies
HyperMesh's own mesh-quality remesh to the rings around the seam, which is what
keeps the mesh around the web-to-base junction from distorting.  Setting 0 keeps
the old split-only behaviour (`tools/audit_mesh_seam_weld_remesh_layers.tcl`
measured on HyperMesh 2019: 41/176 scope elements reworked at layers 0 versus
225/276 at layers 2).  The by-adjacent halo of the patch deliberately crosses
component boundaries to build a valid local remesh ring, so it can reach the
shells of a neighbouring weld strip (`SEAM_T*`, the configured
`MESH_SEAM_WELD*` fallback, or a temporary `^MSWE*` collector). Passing those
elements into `*imprint_nodelist` would remesh and replace an existing weld.

`allow_break_existing_weld` (default **off**) controls this - it is the
"是否允许对现有网格单元进行增删" setting. When it is off, the
expansion result is filtered by element ownership: any element whose collector
matches `isWeldComponentName` is removed from the imprint scope, and the path
continues with the remaining target shells. The weld therefore still takes part
in the local remesh through the nodes it shares with the target — its nodes may
still move with the surrounding mesh — but its own elements are never deleted,
split, or replaced. The filter is applied both to the native `by adjacent`
result and to the bounded Tcl fallback traversal inside
`expandTargetElementPatch`, and again after the component filter in
`markRefreshedLocalTargetElements` (which matters when a `SEAM_*` collector is
itself one of the selected target components). Each removal writes a WARN with
the removed/kept counts, and the patch log line carries a `protected` count.
When nothing but existing weld elements would remain, the path fails with a
staged error instead of silently remeshing the weld. Enabling the option
restores the previous behaviour and lets the halo include weld shells. The same
key is exported to the automatic workflow through `autoJsonSettings` and
`AUTO_DEFAULTS`.

The exclusion is best-effort because the native remesh rings walk by adjacency
and can reach elements beyond the mark: on HyperMesh 2019 the probe above shows
a neighbouring SEAM strip (one base row away) loses 43 of 48 original element
IDs even though it was filtered out of the mark. `protectedWeldElementsChanged`
records that native rebuild as a warning, then `validateStructuralMesh` checks
the resulting boundary, area, duplicate faces, shell geometry and attachment.
An equivalent local rebuild is kept so creation is not blocked by element-ID
replacement; an actual hole, detached rail, duplicate or unusable shell still
rolls the path back. Boundary and protected attachment nodes may likewise be
renumbered or smoothed: comparison uses the pre-remesh coordinate snapshot
rather than querying a deleted ID. Individual old node IDs and coordinates are
diagnostics only; the post-remesh boundary, area, shell geometry and actual
shared-node attachment decide acceptance. A strip two rows away remains
untouched (48/48 intact).

In relaxed mode, a native remesh may also replace a complete local structural
boundary chain instead of preserving or merely subdividing every old edge.
That identity change is warned and the result proceeds to area, duplicate,
geometry and shared-attachment validation. Setting
`strict_patch_boundary_check` restores exact per-edge rejection when required.

Validation: 232 module tests for Mesh Seam Weld and 71 for the automatic FEM
seam recognizer pass using Python with Tcl/Tk, including native patch execution
order, remesh scope, mixed/size parameters, empty output, the curved-rail
subdivision acceptance, the wrong-rail insertion rejection, the strict-mode
equality rejection, the relaxed three-owner-edge tolerance, the rebuilt-source-
rail diagnostic, the structural-mesh damage guards (missing, duplicate and
coincident faces, attachment-node changes reported as warnings, destroyed geometry - self-
intersecting, zero-area and coincident-node shells - versus needles, slivers,
concave corners and warps that stay warnings), the
coordinate-renumbering tolerance of free boundary nodes, the adjusted-size retry
transactions, the undo-count boundary, the verified full rollback, the
existing-weld halo protection, and the delivery gates of the automatic route.
The real-machine geometry probe
(`tools/audit_mesh_seam_weld_geometry_audit.tcl`) reproduces the 2026-09-10
field blocks on HyperMesh 2019.0.0.70 and verifies that every case creates the
weld once the audit reports the shape instead of failing. A
real HyperMesh smoke test
(`modules/mesh_seam_weld/tests/hm2019_mesh_safety_smoke.tcl`) passes on
HyperMesh 2019.0.0.70 and on HM2022 (22.0): the imprint halo stays inside the
selected target component, an injected post-imprint failure is rolled back with
the mother mesh and the weld verified identical, and a repeated weld on the same
rail is rejected without damaging the model. The remaining manual checks are
listed in `doc/mesh_seam_auto_protocol.md`.
