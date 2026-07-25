import json
import math
import tempfile
import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:
    tkinter = None

from main import main as cli_main
from shell_fem_reader import read_shell_fem_bundle


def write_two_component_annuli(root):
    nodes = {}
    elements = []
    node_id = 1
    element_id = 1
    component_elements = {10: [], 20: []}
    for component_id, x_offset in ((10, 0.0), (20, 25.0)):
        rings = []
        for radius in (5.0, 7.0):
            ring = []
            for index in range(8):
                angle = 2.0 * math.pi * index / 8
                nodes[node_id] = (
                    x_offset + radius * math.cos(angle),
                    radius * math.sin(angle),
                    0.0,
                )
                ring.append(node_id)
                node_id += 1
            rings.append(ring)
        for index in range(8):
            next_index = (index + 1) % 8
            elements.append((
                element_id,
                999,
                rings[0][index], rings[0][next_index],
                rings[1][next_index], rings[1][index],
            ))
            component_elements[component_id].append(element_id)
            element_id += 1

    fem_path = root / "selected_components.fem"
    lines = ["BEGIN BULK"]
    lines.extend(
        "GRID,{0},,{1:.12g},{2:.12g},{3:.12g}".format(node_id, *xyz)
        for node_id, xyz in sorted(nodes.items())
    )
    lines.extend("CQUAD4,{},{},{},{},{},{}".format(*row) for row in elements)
    lines.extend(("ENDDATA", ""))
    fem_path.write_text("\n".join(lines), encoding="utf-8")

    manifest_path = root / "selected_components_manifest.json"
    manifest_path.write_text(json.dumps({
        "schema_version": "1.0",
        "format": "hm_selected_components_fem",
        "fem_path": fem_path.name,
        "components": [
            {"component_id": 10, "component_name": "SHELL_A", "element_ids": component_elements[10]},
            {"component_id": 20, "component_name": "SHELL_B", "element_ids": component_elements[20]},
        ],
    }), encoding="utf-8")
    return manifest_path, nodes, elements


class SelectedFemReaderTests(unittest.TestCase):
    def test_combined_fem_restores_component_ownership_without_using_pid(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, _, _ = write_two_component_annuli(Path(directory))
            model = read_shell_fem_bundle(manifest)
            self.assertEqual(set(model.components), {10, 20})
            self.assertEqual(
                {element.component_id for element in model.elements.values()},
                {10, 20},
            )
            self.assertEqual({element.element_type for element in model.elements.values()}, {"CQUAD4"})

    def test_missing_component_mapping_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, _, _ = write_two_component_annuli(root)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["components"][1]["element_ids"].pop()
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "no HyperMesh component mapping"):
                read_shell_fem_bundle(manifest)


class SelectedFemCliTests(unittest.TestCase):
    def test_cli_processes_one_combined_fem_and_writes_incremental_rigids(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, nodes, elements = write_two_component_annuli(root)
            settings = {
                "MIN_HOLE_DIAMETER": 6.0, "MAX_HOLE_DIAMETER": 30.0,
                "CIRCULARITY_TOL": 0.08, "ALLOW_OVAL_HOLES": True,
                "MAX_OVAL_AXIS_RATIO": 3.5, "OVAL_RADIAL_FIT_TOL": 0.45,
                "MIN_HOLE_EDGE_NODES": 8, "MAX_HOLE_EDGE_NODES": 200,
                "INNER_WASHER_NODE_LOOPS": 2, "OUTER_RING_CIRCULARITY_TOL": 0.2,
                "OUTER_OVAL_RADIAL_FIT_TOL": 0.55, "OUTER_OVAL_AXIS_RATIO_TOL": 0.45,
                "CENTER_OFFSET_TOL": 0.2, "MIN_WASHER_WIDTH_ABS": 0.3,
                "MIN_WASHER_WIDTH_RATIO": 0.05, "WASHER_ELEM_COUNT_TOL": 0.5,
                "MIN_OUTER_NODE_RATIO": 0.5, "MAX_OUTER_NODE_RATIO": 2.5,
                "rigidType": "RBE2", "dof": "123456",
                "outputComponentNames": {"10": "AUTO_RBE2_SHELL_A", "20": "AUTO_RBE2_SHELL_B"},
            }
            request = root / "request.json"
            request.write_text(json.dumps({
                "schema_version": "1.0", "module": "shell_washer_hole_rbe2",
                "run_id": "selected-fem-batch", "hypermesh_version": "2019",
                "selected_component_ids": [10, 20], "settings": settings,
                "id_state": {
                    "max_node_id": max(nodes), "max_element_id": max(row[0] for row in elements),
                    "max_component_id": 20,
                },
                "entity_registry": {"components": {}, "properties": {}, "materials": {}},
                "options": {"debug": False, "keep_runtime_files": True},
            }), encoding="utf-8")
            existing = root / "existing.json"
            existing.write_text(json.dumps({"rbe2": []}), encoding="utf-8")
            delta, result, sidecar, log = (
                root / "rigid_import.fem", root / "result.json",
                root / "result.tcl", root / "operation.log",
            )
            code = cli_main([
                "--request", str(request), "--mesh", str(manifest),
                "--existing", str(existing), "--delta", str(delta),
                "--output", str(result), "--tcl-output", str(sidecar), "--log", str(log),
            ])
            self.assertEqual(code, 0)
            payload = json.loads(result.read_text(encoding="utf-8"))
            self.assertEqual(payload["summary"]["planned_create_count"], 2)
            self.assertEqual({row["source_component_id"] for row in payload["candidates"]}, {10, 20})
            deck = delta.read_text(encoding="utf-8")
            self.assertIn('"AUTO_RBE2_SHELL_A"', deck)
            self.assertIn('"AUTO_RBE2_SHELL_B"', deck)


class SelectedFemTclContractTests(unittest.TestCase):
    def test_tcl_exports_one_native_fem_instead_of_binary_mesh(self):
        root = Path(__file__).resolve().parents[1]
        exporter = (root / "tcl" / "exporter.tcl").read_text(encoding="utf-8")
        bridge = (root / "tcl" / "bridge.tcl").read_text(encoding="utf-8")
        self.assertIn("*feoutput_select", exporter)
        self.assertIn("selected_components.fem", exporter)
        self.assertIn("selected_components_manifest.json", exporter)
        self.assertNotIn("writeBinaryMesh", exporter)
        self.assertIn("--mesh [dict get $paths manifest]", bridge)

    @unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
    def test_tcl_exports_all_selected_components_in_one_feoutput_call(self):
        module = Path(__file__).resolve().parents[2] / "shell_washer_hole_rbe2.tcl"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            interp = tkinter.Tcl()
            interp.eval("source {{{}}}".format(module.as_posix()))
            interp.call("set", "::test_export_template", (root / "optistruct.tpl").as_posix())
            interp.eval("proc ::RB2W::unusedRBE2ExportTemplate {} {return $::test_export_template}")
            interp.eval("proc *clearmark {args} {}")
            interp.eval("proc *createmark {entity mark args} {set ::marked($entity) $args}")
            interp.eval("proc hm_getmark {entity mark} {expr {$entity eq {elems} ? {101 202} : {1 2 3 4}}}")
            interp.eval("set ::feoutput_calls 0")
            interp.eval(
                "proc *feoutput_select {template output mark reserved1 reserved2} {"
                "incr ::feoutput_calls; set channel [open $output w]; "
                "puts $channel {BEGIN BULK}; puts $channel {GRID,1,,0.,0.,0.}; "
                "puts $channel {ENDDATA}; close $channel}"
            )
            interp.eval("proc ::RB2W::getElemsByComp {id} {expr {$id == 10 ? {101} : {202}}}")
            interp.eval("proc ::RB2W::getComponentName {id} {return COMP_$id}")
            interp.eval("proc hm_getsolverid {entity id mode} {return [list [expr {$id + 1000}] SHELL_POOL]}")
            result = interp.eval(
                "::RB2W::exportSelectedComponentsFem {{{}}} run-1 {{10 20}}".format(root.as_posix())
            )
            manifest_path = Path(interp.eval("dict get {{{}}} manifest".format(result)))
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(interp.eval("set ::feoutput_calls"), "1")
            self.assertEqual(
                [entry["element_ids"] for entry in manifest["components"]],
                [[1101], [1202]],
            )


if __name__ == "__main__":
    unittest.main()
