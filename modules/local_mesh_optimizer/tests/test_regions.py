import csv
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PYTHON_DIR = Path(__file__).resolve().parents[1] / "python"
sys.path.insert(0, str(PYTHON_DIR))

from adjacency import ShellElement, build_adjacency, connected_components, expand_region
from optimization_planner import plan_optimization_actions
from region_builder import build_regions
from report_generator import generate_report


class RegionTests(unittest.TestCase):
    def setUp(self):
        # 1--2 share an edge, 2--3 share an edge, 4 only touches node 3.
        self.elements = {
            1: ShellElement(1, 10, (1, 2, 5, 4)),
            2: ShellElement(2, 10, (2, 3, 6, 5)),
            3: ShellElement(3, 10, (3, 7, 8, 6)),
            4: ShellElement(4, 10, (3, 9, 10)),
        }

    def test_edge_adjacency_does_not_join_corner_touch(self):
        adjacency, _ = build_adjacency(self.elements)
        self.assertEqual(adjacency[1], {2})
        self.assertEqual(adjacency[2], {1, 3})
        self.assertEqual(adjacency[4], set())

    def test_failed_regions_and_expansion(self):
        adjacency, _ = build_adjacency(self.elements)
        self.assertEqual(connected_components([1, 3, 4], adjacency), [[1], [3], [4]])
        expanded, completed, truncated = expand_region([1], adjacency, 2, 50)
        self.assertEqual(expanded, [1, 2, 3])
        self.assertEqual(completed, 2)
        self.assertFalse(truncated)

    def test_component_boundary_is_blocked(self):
        elements = dict(self.elements)
        elements[2] = ShellElement(2, 20, elements[2].nodes)
        adjacency, _ = build_adjacency(elements, cross_components=False)
        self.assertEqual(adjacency[1], set())

    def test_limit_does_not_partially_add_a_layer(self):
        adjacency, _ = build_adjacency(self.elements)
        expanded, completed, truncated = expand_region([2], adjacency, 1, 2)
        self.assertEqual(expanded, [2])
        self.assertEqual(completed, 0)
        self.assertTrue(truncated)

    def test_region_schema(self):
        regions = build_regions(self.elements, [1, 3], 1, 50)
        self.assertEqual([region["region_id"] for region in regions], ["Region_0001", "Region_0002"])
        self.assertEqual(regions[0]["status"], "pending")
        self.assertIn(1, regions[0]["anchor_nodes"])

    def test_offline_report(self):
        regions = build_regions(self.elements, [1], 1, 50)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            summary = generate_report(
                output,
                {
                    "model_path": "中文 model.hm",
                    "criteria_path": "a.criteria",
                    "scope_type": "elements",
                    "optimizable_failed_before": 0,
                    "washer_failed_excluded": 1,
                },
                {
                    "checked_elements": 4,
                    "failed_before": 1,
                    "failed_after": 1,
                    "status": "task_rolled_back",
                },
                regions,
            )
            self.assertEqual(summary["failed_before"], 1)
            self.assertEqual(summary["task_status"], "task_rolled_back")
            self.assertEqual(summary["washer_failed_excluded"], 1)
            self.assertTrue((output / "summary.html").is_file())
            self.assertIn("HyperMesh", (output / "summary.html").read_text(encoding="utf-8"))

    def test_tcl_workflow_has_no_blocking_message_boxes_and_only_two_model_writes(self):
        source = (Path(__file__).resolve().parents[2] / "local_mesh_optimizer.tcl").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("tk_messageBox", source)
        self.assertIn("hm_answernext yes", source)
        self.assertIn("topologyFailureAllowance", source)
        self.assertIn("qualityWorsened $before $after $roundTopologyAllowance", source)
        self.assertIn("criteria context reused", source)
        self.assertIn("复用检查阶段质量结果", source)
        self.assertIn("EXCLUDE_WASHER_ELEMENTS 1", source)
        self.assertIn("washer_excluded_failed.txt", source)
        calls = [line for line in source.splitlines() if "saveModelSnapshot $" in line]
        self.assertEqual(len(calls), 2, calls)

    def test_controller_writes_atomic_completion_status(self):
        with tempfile.TemporaryDirectory() as directory:
            task_dir = Path(directory)
            criteria = task_dir / "测试 criteria.criteria"
            criteria.write_text("# metadata only\nquality = native_hypermesh\n", encoding="utf-8")
            (task_dir / "element_connectivity.csv").write_text(
                "element_id,component_id,n1,n2,n3,n4\n", encoding="utf-8"
            )
            (task_dir / "failed_elements.txt").write_text("", encoding="utf-8")
            task = task_dir / "task.json"
            task.write_text(
                json.dumps({"criteria_path": str(criteria)}, ensure_ascii=False), encoding="utf-8"
            )
            status = task_dir / "controller_status.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(PYTHON_DIR / "optimizer_controller.py"),
                    "--task",
                    str(task),
                    "--stage",
                    "build-regions",
                    "--status-file",
                    str(status),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
            payload = json.loads(status.read_text(encoding="utf-8"))
            self.assertEqual(payload["exit_code"], 0)
            self.assertEqual(payload["stage"], "build-regions")

    def test_controller_writes_topology_action_protocol(self):
        with tempfile.TemporaryDirectory() as directory:
            task_dir = Path(directory)
            criteria = task_dir / "rules.criteria"
            criteria.write_text("quality = native_hypermesh\n", encoding="utf-8")
            (task_dir / "element_connectivity.csv").write_text(
                "element_id,component_id,n1,n2,n3,n4\n10,1,1,2,3,4\n", encoding="utf-8"
            )
            (task_dir / "node_coordinates.csv").write_text(
                "node_id,x,y,z\n1,0,0,0\n2,2,0,0\n3,1.8,1,0\n4,0,1.3,0\n",
                encoding="utf-8",
            )
            (task_dir / "failed_elements.txt").write_text("10\n", encoding="utf-8")
            (task_dir / "protected_edges.csv").write_text("n1,n2\n", encoding="utf-8")
            (task_dir / "protected_nodes.txt").write_text("", encoding="utf-8")
            task = task_dir / "task.json"
            task.write_text(
                json.dumps(
                    {
                        "criteria_path": str(criteria),
                        "adjacency_layers": 1,
                        "max_region_elements": 100,
                        "optimization_level": "standard",
                        "protection": {"no_cross_component_movement": True, "feature_edges": False},
                    }
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [sys.executable, str(PYTHON_DIR / "optimizer_controller.py"), "--task", str(task)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
            actions = (task_dir / "optimization_actions.csv").read_text(encoding="utf-8")
            self.assertIn("split_quad", actions)
            regions = json.loads((task_dir / "regions.json").read_text(encoding="utf-8"))
            self.assertEqual(regions[0]["planned_actions"][0]["action_type"], "split_quad")

    def test_planner_splits_quad_using_scored_diagonal(self):
        elements = {10: ShellElement(10, 1, (1, 2, 3, 4))}
        coordinates = {
            1: (0.0, 0.0, 0.0),
            2: (2.0, 0.0, 0.0),
            3: (1.8, 1.0, 0.0),
            4: (0.0, 1.3, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [10], "anchor_nodes": []}]
        actions = plan_optimization_actions(elements, [10], coordinates, regions)
        self.assertEqual(actions[0]["action_type"], "split_quad")
        self.assertEqual(actions[0]["split_method"], 2)

    def test_planner_can_select_reverse_quad_diagonal(self):
        elements = {11: ShellElement(11, 1, (1, 2, 3, 4))}
        coordinates = {
            1: (0.0, 0.0, 0.0),
            2: (1.0, 0.0, 0.0),
            3: (1.4, 0.8, 0.0),
            4: (0.0, 1.8, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [11], "anchor_nodes": []}]
        action = plan_optimization_actions(
            elements, [11], coordinates, regions, narrow_quad_ratio=100.0
        )[0]
        self.assertEqual(action["action_type"], "split_quad")
        self.assertEqual(action["split_method"], 102)

    def test_planner_collapses_skinny_triangle_short_edge(self):
        elements = {20: ShellElement(20, 1, (1, 2, 3))}
        coordinates = {1: (0.0, 0.0, 0.0), 2: (0.1, 0.0, 0.0), 3: (0.0, 3.0, 0.0)}
        regions = [{"region_id": "Region_0001", "failed_elements": [20], "anchor_nodes": []}]
        action = plan_optimization_actions(elements, [20], coordinates, regions)[0]
        self.assertEqual(action["action_type"], "collapse_short_edge")
        self.assertEqual({action["node_a"], action["node_b"]}, {1, 2})

    def test_planner_expands_long_free_edge_of_narrow_quad(self):
        elements = {30: ShellElement(30, 1, (1, 2, 3, 4))}
        coordinates = {
            1: (0.0, 0.0, 0.0),
            2: (5.0, 0.0, 0.0),
            3: (5.0, 0.25, 0.0),
            4: (0.0, 0.25, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [30], "anchor_nodes": [1, 2, 3, 4]}]
        action = plan_optimization_actions(elements, [30], coordinates, regions)[0]
        self.assertEqual(action["action_type"], "expand_free_edge")
        self.assertGreater(action["target_distance"], 0.25)


if __name__ == "__main__":
    unittest.main()
