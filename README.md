# HyperMesh Preprocess Workflow Toolkit

Tcl/Tk workflow scripts for HyperMesh 2019 preprocessing.

Run `hw_toolkit.tcl` from HyperMesh with `File > Run > Tcl/Tk Script`.

## Structure

```text
.
|-- hw_toolkit.tcl
|-- config/
|   |-- materials.txt
|   |-- seam_rules.txt
|   |-- *_state.txt
|   `-- washer_rules.txt
`-- modules/
    |-- workflow_common.tcl
    |-- component_workflow.tcl
    |-- midsurf.tcl
    |-- seam_surface.tcl
    |-- auto_hole_rbe2.tcl
    |-- rbe2_bolt_connector.tcl
    `-- shell_washer_hole_rbe2.tcl
```

## Workflow Modules

| Module | Entry | Purpose |
| --- | --- | --- |
| `hw_toolkit.tcl` | `::HWToolkit::run` | Main workflow launcher. |
| `modules/workflow_common.tcl` | shared helpers | Config, material library, naming, assembly and browser helpers. |
| `modules/component_workflow.tcl` | `::CompWorkflow::runCategory` | Classify components into `SHELL`, `SOLID`, `CASTING`, rename them, and organize category assemblies. |
| `modules/component_workflow.tcl` | `::CompWorkflow::runMaterial` | Assign material names from `config/materials.txt`, replace existing material suffixes, and organize material assemblies. |
| `modules/midsurf.tcl` | `::MidSurf::run` | Extract midsurfaces and name outputs as `CATEGORY_NAME_Tx_MATERIAL`. Source geometry is kept and hidden by default. |
| `modules/seam_surface.tcl` | `::SeamSurf::run` | Create `SEAM_Tx` geometry surfaces with Line-Surface or Line-Line workflows, using the thinner adjacent shell thickness. |
| `modules/auto_hole_rbe2.tcl` | `::AutoHoleRBE2::run` | Create RBE2 elements for cylindrical through-holes in solid meshes. |
| `modules/shell_washer_hole_rbe2.tcl` | `::RB2W::run` | Create RBE2 elements for shell washer holes. |
| `modules/rbe2_bolt_connector.tcl` | `::RB2Bolt::run` | Group RBE2 elements and create CBEAM/CBAR bolt segments. |

## Naming Rules

Component names should carry the full workflow information:

```text
SHELL_PARTNAME_T2.0_Q235
SOLID_PARTNAME_Q235
CASTING_PARTNAME_QT500
SEAM_T2.0
```

Material reassignment replaces the existing material suffix when it matches a key from `config/materials.txt`.

## Configuration

`config/materials.txt` is a pipe-delimited text file:

```text
key|display|density|E|nu|yield|ultimate|note
Q235|Q235|7.85e-9|210000|0.30|235|370|steel
```

The material editor in `Material Assignment` edits this file directly.

`config/seam_rules.txt` stores seam defaults such as max projection gap, topology stitch tolerance and component grouping mode. The seam module reads and saves this file directly.

`config/*_state.txt` files are generated automatically. They remember workflow UI settings such as selected options, text fields and numeric fields for the next run. Model-specific entity selections are not stored because component, element, line and surface IDs are not stable between models.

`config/washer_rules.txt` is an initial placeholder for the upcoming midsurface cleanup module.

## Seam Workflow

`Seam Surface Creation` runs after midsurface extraction and before meshing/RBE2 creation.

- `Line-Surface` selects one source line and one target surface. The source line is sampled, projected to the selected surface as paired points, and the seam is created only between the source span and its matching projected span.
- `Line-Line` selects two boundary lines and creates the seam only over their nearest overlapping span. This is the normal mode for L-type welds and direct edge-to-edge bridge welds.
- Closed-loop source lines are sampled as circular sequences, so a valid seam span may cross the 0/1 parameter break without being split.
- If direct surface splitting fails in `Line-Surface`, the module falls back to sampled closest-point projection on the selected target surface. It does not switch to a target free edge; use `Line-Line` for that case.
- The output component is `SEAM_Tx`, where `x` is the thinner `_T` value read from the two adjacent component names.
- Synchronized construction lines are deleted after surface creation by default so the final shared topology can stitch to adjacent midsurfaces instead of leaving free green lines.
- If thickness cannot be read from `_T`, the module asks for a manual value.
- Construction lines are created through temporary nodes and `*linecreatefromnodes`, with a straight-line fallback, so the workflow avoids `*linecreatefromcoords`, which is not available in HyperMesh 2019.

## Notes

- The scripts are written for HyperMesh 2019 Tcl/Tk.
- Normal Tcl interpreters can source the files for syntax checks, but HyperMesh commands only run inside HyperMesh.
- Workflow module windows use `Back to Home` to return to the main launcher. Press `Esc` to close the current module without returning.
