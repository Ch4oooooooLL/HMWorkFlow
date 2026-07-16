from __future__ import annotations

import json
import tempfile
import time
import unittest
from pathlib import Path

from edge_graph import EdgeGraph
from geometry import angle_degrees, centroid, point_line_distance
from mesh_model import read_mesh
from result_writer import write_result
from schema import SchemaError, new_result, validate_request, validate_result
from spatial_index import PointGrid
from statistics import median, mode_with_tolerance


class SchemaTests(unittest.TestCase):
    def request(self):
        return {
            "schema_version": "1.0",
            "module": "auto_hole_rbe2",
            "run_id": "RUN_1",
            "hypermesh_version": "2019",
            "selected_component_ids": [1],
            "settings": {},
            "options": {"debug": False, "keep_runtime_files": True},
        }

    def test_request_validation(self):
        self.assertEqual(validate_request(self.request())["run_id"], "RUN_1")

    def test_rejects_duplicate_ids(self):
        payload = self.request()
        payload["selected_component_ids"] = [1, 1]
        with self.assertRaises(SchemaError):
            validate_request(payload)

    def test_result_rejects_stale_run(self):
        result = new_result("auto_hole_rbe2", "RUN_1")
        with self.assertRaises(SchemaError):
            validate_result(result, "auto_hole_rbe2", "OLD_RUN")


class AlgorithmTests(unittest.TestCase):
    def test_geometry(self):
        self.assertEqual(centroid([(0, 0, 0), (2, 2, 2)]), (1.0, 1.0, 1.0))
        self.assertAlmostEqual(point_line_distance((1, 2, 0), (0, 0, 0), (1, 0, 0)), 2.0)
        self.assertAlmostEqual(angle_degrees((1, 0, 0), (0, 1, 0)), 90.0)

    def test_edge_graph_open_closed_and_branched(self):
        self.assertEqual(
            EdgeGraph([(3, 1), (1, 2), (2, 3)]).ordered_paths(),
            [{"nodes": [1, 2, 3], "closed": True, "branched": False}],
        )
        self.assertEqual(
            EdgeGraph([(3, 2), (2, 1)]).ordered_paths(),
            [{"nodes": [1, 2, 3], "closed": False, "branched": False}],
        )
        self.assertTrue(EdgeGraph([(1, 2), (2, 3), (2, 4)]).ordered_paths()[0]["branched"])

    def test_long_closed_boundary_traversal_is_linear(self):
        node_count = 20000
        edges = [(node, node + 1) for node in range(1, node_count)] + [(node_count, 1)]

        started = time.perf_counter()
        paths = EdgeGraph(edges).ordered_paths()
        elapsed = time.perf_counter() - started

        self.assertEqual(len(paths[0]["nodes"]), node_count)
        self.assertLess(elapsed, 0.5)

    def test_spatial_index_and_statistics(self):
        index = PointGrid([(1, (0, 0, 0)), (2, (2, 0, 0))], 1.0)
        self.assertEqual(index.query_radius((0, 0, 0), 1.0), [1])
        self.assertEqual(median([3, 1, 2]), 2.0)
        self.assertAlmostEqual(mode_with_tolerance([8.0, 8.1, 10.0], 0.2), 8.05)

    def test_large_mesh_validation_uses_prebuilt_node_index(self):
        node_count = 12000
        element_count = 10000
        payload = {
            "schema_version": "1.0",
            "components": [{"component_id": 1, "component_name": "LARGE", "mesh_class": "SHELL"}],
            "nodes": [[i, float(i), 0.0, 0.0] for i in range(1, node_count + 1)],
            "elements": [
                {"element_id": i, "component_id": 1, "element_type": "CQUAD4", "node_ids": [i, i + 1, i + 2, i + 3]}
                for i in range(1, element_count + 1)
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mesh.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            started = time.perf_counter()
            model = read_mesh(path)
            elapsed = time.perf_counter() - started
        self.assertEqual(len(model.elements), element_count)
        self.assertLess(elapsed, 2.5, "large mesh validation regressed to repeated full-node scans")


class ResultWriterTests(unittest.TestCase):
    def test_utf8_json_and_safe_tcl_sidecar(self):
        result = new_result("auto_hole_rbe2", "RUN_1")
        result["candidates"] = [
            {"candidate_id": "H0001", "text": '中文 $x [bad] "quote" \\ path', "ids": [1, 2]}
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_result(root / "result.json", root / "result.tcl", "::Test::result", result)
            loaded = json.loads((root / "result.json").read_text(encoding="utf-8"))
            self.assertEqual(loaded["candidates"][0]["text"].split()[0], "中文")
            sidecar = (root / "result.tcl").read_text(encoding="utf-8")
            self.assertTrue(sidecar.startswith("# HYBRID_CORE_RESULT_V1"))
            self.assertIn("\\$x", sidecar)
            self.assertIn("\\[bad\\]", sidecar)


if __name__ == "__main__":
    unittest.main()
