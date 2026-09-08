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
patch boundary nodes are fixed. An empty patch or changed boundary edges raises
a staged error for the existing per-path history rollback.

The previous structured/ruled executor remains available in code for comparison,
but the manual workflow dispatches to the native patch executor. FAST_AUTO is
independent of this route. Geometry-surface output and the old ruled element-type
controls do not apply to this validation route.

Validation: 157 module tests passed using Python with Tcl/Tk, including native
patch execution order, remesh scope, mixed/size parameters, empty output and
attachment-edge change rejection. Native HyperMesh model validation remains
pending: open path, sharp corner, closed loop, variable gap, cross-component
support, and multiple paths sharing the same SEAM_T component. Check actual
shared-node attachment, missing segments, mesh quality and rollback in HM2019
and the deployed newer version before adopting this route as production default.
