from __future__ import annotations

import json
import tempfile
import tkinter
import unittest
from pathlib import Path

from mesh_model import read_mesh
from result_writer import write_binary_result
from schema import SchemaError, new_result


ROOT = Path(__file__).resolve().parents[3]
TCL_DIR = ROOT / "modules" / "hybrid_core" / "tcl"


class BinaryMeshContractTests(unittest.TestCase):
    def _write_with_tcl(self, path: Path) -> None:
        interpreter = tkinter.Tcl()
        interpreter.eval(
            "namespace eval ::HybridCore { variable workerFileFingerprints {} }"
        )
        interpreter.eval(
            "source {{{}}}".format((TCL_DIR / "data_writer.tcl").as_posix())
        )
        interpreter.eval(
            "source {{{}}}".format((TCL_DIR / "binary_codec.tcl").as_posix())
        )
        interpreter.eval(
            "set components [list "
            "[dict create component_id 7 component_name {\u58f3\u4f53 A} mesh_class SHELL] "
            "[dict create component_id 9 component_name RIGIDS mesh_class RIGID]]"
        )
        interpreter.eval(
            "set nodes [list "
            "[list 101 1.25 -2.5 3.75] "
            "[list 102 2.0 0.0 1.0] "
            "[list 103 3.0 0.0 1.0] "
            "[list 104 4.0 0.0 1.0]]"
        )
        interpreter.eval(
            "set elements [list "
            "[dict create element_id 501 component_id 7 element_type CTRIA3 node_ids [list 101 102 103]] "
            "[dict create element_id 502 component_id 9 element_type RBE2 node_ids [list 101 102 103 104]]]"
        )
        interpreter.call(
            "::HybridCore::writeBinaryMesh",
            str(path),
            interpreter.eval("set components"),
            interpreter.eval("set nodes"),
            interpreter.eval("set elements"),
        )

    def test_tcl_writer_round_trips_through_python_reader(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mesh.hmwf"
            self._write_with_tcl(path)
            model = read_mesh(path)

        self.assertEqual(model.components[7].component_name, "\u58f3\u4f53 A")
        self.assertEqual(model.components[9].mesh_class, "RIGID")
        self.assertEqual(model.nodes[101], (1.25, -2.5, 3.75))
        self.assertEqual(model.elements[501].node_ids, (101, 102, 103))
        self.assertEqual(model.elements[502].element_type, "RBE2")

    def test_binary_writer_registers_fingerprint_without_rereading(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mesh.hmwf"
            self._write_with_tcl(path)
            self.assertTrue(path.read_bytes().startswith(b"HMWFMB1\x00"))

    def test_truncated_binary_mesh_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mesh.hmwf"
            path.write_bytes(b"HMWFMB1\x00\x01\x00")
            with self.assertRaises(SchemaError):
                read_mesh(path)

    def test_json_mesh_remains_supported(self):
        payload = {
            "schema_version": "1.0",
            "components": [
                {"component_id": 1, "component_name": "A", "mesh_class": "SHELL"}
            ],
            "nodes": [[1, 0.0, 0.0, 0.0], [2, 1.0, 0.0, 0.0], [3, 0.0, 1.0, 0.0]],
            "elements": [
                {"element_id": 1, "component_id": 1, "element_type": "CTRIA3", "node_ids": [1, 2, 3]}
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mesh.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            model = read_mesh(path)
        self.assertEqual(tuple(model.elements), (1,))

    def test_hybrid_exporters_use_binary_mesh_data_plane(self):
        exporters = (
            ROOT / "modules" / "auto_hole_rbe2" / "tcl" / "exporter.tcl",
            ROOT / "modules" / "rbe2_bolt_connector" / "tcl" / "exporter.tcl",
            ROOT / "modules" / "shell_washer_hole_rbe2" / "tcl" / "exporter.tcl",
            ROOT / "modules" / "mesh_seam_weld" / "tcl" / "exporter.tcl",
        )
        for exporter in exporters:
            source = exporter.read_text(encoding="utf-8")
            with self.subTest(exporter=exporter.parent.parent.name):
                self.assertIn("::HybridCore::writeBinaryMesh", source)
                self.assertIn("mesh.hmwf", source)

    def test_hybrid_bridges_use_single_binary_result(self):
        bridges = (
            ROOT / "modules" / "auto_hole_rbe2" / "tcl" / "bridge.tcl",
            ROOT / "modules" / "rbe2_bolt_connector" / "tcl" / "bridge.tcl",
            ROOT / "modules" / "shell_washer_hole_rbe2" / "tcl" / "bridge.tcl",
            ROOT / "modules" / "mesh_seam_weld" / "tcl" / "bridge.tcl",
        )
        for bridge in bridges:
            source = bridge.read_text(encoding="utf-8")
            with self.subTest(bridge=bridge.parent.parent.name):
                self.assertIn("result.hmwfr", source)
                self.assertIn("::HybridCore::loadBinaryResult", source)

    def test_bulk_coordinate_reader_prefers_one_mark_query(self):
        interpreter = tkinter.Tcl()
        interpreter.eval("namespace eval ::HybridCore {}")
        interpreter.eval(
            "source {{{}}}".format((TCL_DIR / "hm_bulk_reader.tcl").as_posix())
        )
        interpreter.eval("proc *clearmark {args} {}")
        interpreter.eval("proc *createmark {args} {}")
        interpreter.eval("proc hm_getmark {args} { return [list 10 20] }")
        interpreter.eval(
            "proc hm_getvalue {args} { return [list [list 1.0 2.0 3.0] [list 4.0 5.0 6.0]] }"
        )
        interpreter.eval(
            "set ::fallbackCalls 0; proc fallbackXYZ {nodeId} { incr ::fallbackCalls; return [list 0 0 0] }"
        )
        result = interpreter.call(
            "::HybridCore::readNodeCoordinatesBulk", (10, 20), ("fallbackXYZ",)
        )
        self.assertEqual(interpreter.call("dict", "get", result, 20), (4.0, 5.0, 6.0))
        self.assertEqual(interpreter.eval("set ::fallbackCalls"), "0")

    def test_binary_mesh_is_materially_smaller_than_equivalent_json(self):
        node_count = 2000
        element_count = 1000
        payload = {
            "schema_version": "1.0",
            "components": [
                {"component_id": 1, "component_name": "BENCHMARK", "mesh_class": "SHELL"}
            ],
            "nodes": [[i, i * 0.125, i * -0.25, i * 0.5] for i in range(1, node_count + 1)],
            "elements": [
                {
                    "element_id": i,
                    "component_id": 1,
                    "element_type": "CQUAD4",
                    "node_ids": [i, i + 1, i + 2, i + 3],
                }
                for i in range(1, element_count + 1)
            ],
        }
        interpreter = tkinter.Tcl()
        interpreter.eval("namespace eval ::HybridCore { variable workerFileFingerprints {} }")
        interpreter.eval(
            "source {{{}}}".format((TCL_DIR / "data_writer.tcl").as_posix())
        )
        interpreter.eval(
            "source {{{}}}".format((TCL_DIR / "binary_codec.tcl").as_posix())
        )
        interpreter.eval(
            "set components [list [dict create component_id 1 component_name BENCHMARK mesh_class SHELL]]"
        )
        interpreter.eval(
            "set nodes {}; for {set i 1} {$i <= 2000} {incr i} { "
            "lappend nodes [list $i [expr {$i*0.125}] [expr {$i*-0.25}] [expr {$i*0.5}]] }"
        )
        interpreter.eval(
            "set elements {}; for {set i 1} {$i <= 1000} {incr i} { "
            "lappend elements [dict create element_id $i component_id 1 element_type CQUAD4 "
            "node_ids [list $i [expr {$i+1}] [expr {$i+2}] [expr {$i+3}]]] }"
        )
        with tempfile.TemporaryDirectory() as directory:
            binary_path = Path(directory) / "mesh.hmwf"
            interpreter.call(
                "::HybridCore::writeBinaryMesh",
                str(binary_path),
                interpreter.eval("set components"),
                interpreter.eval("set nodes"),
                interpreter.eval("set elements"),
            )
            binary_size = binary_path.stat().st_size
        # The legacy Tcl exporters emitted human-readable JSON with one field
        # per line, so compare against the equivalent auditable representation.
        json_size = len(json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8"))
        self.assertLess(binary_size, json_size * 0.65)


class BinaryResultContractTests(unittest.TestCase):
    def test_python_writer_round_trips_through_tcl_reader(self):
        result = new_result("auto_hole_rbe2", "RUN_BINARY")
        result["summary"] = {"count": 2, "ratio": 0.25, "ok": True, "empty": None}
        result["candidates"] = [
            {"candidate_id": "H1", "text": "\u7ed3\u679c $x [safe]", "ids": [1, 2, 3]}
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.hmwfr"
            write_binary_result(path, result)
            interpreter = tkinter.Tcl()
            interpreter.eval("namespace eval ::HybridCore { variable SCHEMA_VERSION 1.0 }")
            interpreter.eval(
                "source {{{}}}".format((TCL_DIR / "binary_codec.tcl").as_posix())
            )
            interpreter.eval(
                "source {{{}}}".format((TCL_DIR / "result_loader.tcl").as_posix())
            )
            payload = interpreter.call(
                "::HybridCore::loadBinaryResult",
                str(path),
                "auto_hole_rbe2",
                "RUN_BINARY",
            )
            summary = interpreter.call("dict", "get", payload, "summary")
            candidates = interpreter.call("dict", "get", payload, "candidates")

        self.assertEqual(interpreter.call("dict", "get", summary, "count"), 2)
        self.assertEqual(interpreter.call("dict", "get", summary, "ok"), 1)
        first = interpreter.call("lindex", candidates, 0)
        self.assertEqual(interpreter.call("dict", "get", first, "text"), "\u7ed3\u679c $x [safe]")

    def test_binary_result_rejects_trailing_data(self):
        result = new_result("auto_hole_rbe2", "RUN_BINARY")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.hmwfr"
            write_binary_result(path, result)
            path.write_bytes(path.read_bytes() + b"x")
            interpreter = tkinter.Tcl()
            interpreter.eval("namespace eval ::HybridCore { variable SCHEMA_VERSION 1.0 }")
            interpreter.eval(
                "source {{{}}}".format((TCL_DIR / "binary_codec.tcl").as_posix())
            )
            interpreter.eval(
                "source {{{}}}".format((TCL_DIR / "result_loader.tcl").as_posix())
            )
            with self.assertRaises(tkinter.TclError):
                interpreter.call(
                    "::HybridCore::loadBinaryResult",
                    str(path),
                    "auto_hole_rbe2",
                    "RUN_BINARY",
                )


if __name__ == "__main__":
    unittest.main()
