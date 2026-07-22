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
from batch_planner import plan_batches, prevalidate_operation, write_batch_artifacts
from mesh_state import MeshState
from operation_model import adapt_existing_actions, deduplicate_operations
from optimization_planner import plan_optimization_actions
from region_builder import build_regions, merge_independent_regions
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

    def test_macro_regions_pack_only_node_disjoint_sources(self):
        elements = {
            1: ShellElement(1, 1, (1, 2, 3, 4)),
            2: ShellElement(2, 1, (3, 4, 5, 6)),
            3: ShellElement(3, 1, (10, 11, 12, 13)),
        }
        sources = [
            {
                "region_id": "Region_0001", "failed_elements": [1],
                "expanded_elements": [1], "components": [1], "anchor_nodes": [1, 2],
                "requested_layers": 1, "completed_layers": 1, "expansion_truncated": False,
            },
            {
                "region_id": "Region_0002", "failed_elements": [2],
                "expanded_elements": [2], "components": [1], "anchor_nodes": [5, 6],
                "requested_layers": 1, "completed_layers": 1, "expansion_truncated": False,
            },
            {
                "region_id": "Region_0003", "failed_elements": [3],
                "expanded_elements": [3], "components": [1], "anchor_nodes": [10, 13],
                "requested_layers": 1, "completed_layers": 1, "expansion_truncated": False,
            },
        ]
        packed = merge_independent_regions(
            sources, elements, max_source_regions=10,
            max_failed_elements=10, max_expanded_elements=10,
        )
        self.assertEqual(len(packed), 2)
        self.assertEqual(packed[0]["source_region_ids"], ["Region_0001", "Region_0003"])
        self.assertEqual(packed[1]["source_region_ids"], ["Region_0002"])

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
            report = (output / "summary.html").read_text(encoding="utf-8")
            self.assertIn("HyperMesh", report)
            self.assertIn("局部网格优化报告", report)
            self.assertIn("任务文件与报告产物", report)
            self.assertIn("</html>", report)
            self.assertNotIn("灞€", report)

    def test_tcl_view_report_prefers_current_and_falls_back_to_latest(self):
        source = (Path(__file__).resolve().parents[2] / "local_mesh_optimizer.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn("proc ::LocalMeshOptimizer::openReport {}", source)
        self.assertIn("proc ::LocalMeshOptimizer::latestReportPath {}", source)
        self.assertIn("runtime(currentReportPath)", source)
        self.assertIn("LocalMeshOptimizer_Report_* summary.html", source)
        self.assertIn('"View Report" ::LocalMeshOptimizer::openReport', source)

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
        self.assertIn('created_elements\\":\\[\\]', source)
        self.assertIn("progress_suppressed", source)
        self.assertIn("proc ::LocalMeshOptimizer::flushLog", source)
        self.assertIn("proc ::LocalMeshOptimizer::currentShellEdgeByNodes", source)
        self.assertIn("currentShellEdgeByNodes $nodeA $nodeB $elementId", source)
        self.assertIn('$type ne "collapse_short_edge"', source)
        self.assertIn("*replacenodes $nodeA $nodeB 1 1", source)
        self.assertNotIn("*elementqualitycollapseedge", source)
        replace_block = source.split("set actionCode [catch {uplevel #0 [list *replacenodes", 1)[0]
        self.assertTrue(replace_block.rstrip().endswith("hm_answernext yes"))
        self.assertIn("proc ::LocalMeshOptimizer::existingNodeIds", source)
        self.assertIn("discarded stale automatic anchors before region execution", source)
        self.assertIn("user-protected anchor nodes disappeared", source)
        self.assertIn("*translatemark nodes 1 1 $distance", source)
        self.assertIn("direction_blocks=$moveBlockCount", source)
        expand_block = source.split('} elseif {$type eq "expand_free_edge"} {', 1)[1]
        expand_block = expand_block.split('} elseif', 1)[0]
        self.assertNotIn("PRESERVE_GEOMETRY_ASSOCIATION", expand_block)
        calls = [line for line in source.splitlines() if "saveModelSnapshot $" in line]
        self.assertEqual(len(calls), 2, calls)

    def test_advanced_settings_initializes_layout_without_profile_gate(self):
        source = (Path(__file__).resolve().parents[2] / "local_mesh_optimizer.tcl").read_text(
            encoding="utf-8"
        )
        advanced = source.split("proc ::LocalMeshOptimizer::showAdvanced {}", 1)[1]
        advanced = advanced.split("proc ::LocalMeshOptimizer::closeWindow {}", 1)[0]
        self.assertLess(advanced.index("set row 0"), advanced.index("grid $w.main.mode -row $row"))
        self.assertIn("if {![winfo exists $w.btn.close]}", advanced)

        start = source.split("proc ::LocalMeshOptimizer::startOptimization {}", 1)[1]
        start = start.split("proc ::LocalMeshOptimizer::startOptimizationCore {}", 1)[0]
        self.assertIn("optimizationPlanCurrent", start)
        self.assertNotIn("profileStatus", start)
        self.assertNotIn("showAdvanced", start)
        self.assertNotIn("HM2019_PROFILE", source)
        self.assertNotIn("hm2019_recorded", source)

    def test_tcl_python_runtime_path_handling_is_directory_aware(self):
        source = (Path(__file__).resolve().parents[2] / "local_mesh_optimizer.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn("proc ::LocalMeshOptimizer::appendPythonCommandCandidates", source)
        self.assertIn("proc ::LocalMeshOptimizer::appendPythonPathCandidate", source)
        self.assertIn("if {[file isdirectory $clean]}", source)
        self.assertIn("foreach name {pythonw.exe python.exe pythonw python}", source)
        self.assertIn("set runtime(pythonCommand) \"\"", source)

    def test_tcl_python_command_accepts_portable_python_directory(self):
        if sys.platform == "win32":
            self.skipTest("POSIX executable shim is required for this path-resolution test")
        try:
            import tkinter
        except ModuleNotFoundError:
            self.skipTest("tkinter Tcl interpreter is not available")

        module = Path(__file__).resolve().parents[2] / "local_mesh_optimizer.tcl"
        with tempfile.TemporaryDirectory() as directory:
            runtime_dir = Path(directory) / "Portable Python"
            runtime_dir.mkdir()
            pythonw = runtime_dir / "pythonw.exe"
            pythonw.write_text("#!/bin/sh\nmarker=\"$3\"\nprintf '3.8' > \"$marker\"\n", encoding="utf-8")
            pythonw.chmod(pythonw.stat().st_mode | 0o111)
            task_dir = Path(directory) / "task"
            task_dir.mkdir()

            interp = tkinter.Tcl()
            interp.eval(f"source {{{module}}}")
            original_platform = interp.eval("set ::tcl_platform(platform)")
            try:
                interp.eval("set ::tcl_platform(platform) windows")
                interp.eval(f"set ::LocalMeshOptimizer::ui(PYTHON_COMMAND) {{{runtime_dir}}}")
                interp.eval(f"set ::LocalMeshOptimizer::runtime(taskDir) {{{task_dir}}}")
                resolved = interp.eval("lindex [::LocalMeshOptimizer::resolvePython] 0")
            finally:
                interp.eval(f"set ::tcl_platform(platform) {{{original_platform}}}")

            self.assertEqual(Path(resolved), pythonw)
            cached = interp.eval("lindex $::LocalMeshOptimizer::runtime(pythonCommand) 0")
            self.assertEqual(Path(cached), pythonw)

    def test_controller_writes_atomic_completion_status(self):
        with tempfile.TemporaryDirectory() as directory:
            task_dir = Path(directory)
            criteria = task_dir / "测试 criteria.criteria"
            criteria.write_text("# metadata only\nquality = native_hypermesh\n", encoding="utf-8")
            (task_dir / "element_connectivity.txt").write_text(
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
            self.assertIn("task_token", json.loads(status.read_text(encoding="utf-8")))
            self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
            payload = json.loads(status.read_text(encoding="utf-8"))
            self.assertEqual(payload["exit_code"], 0)
            self.assertEqual(payload["stage"], "build-regions")
            for name in ("region_tasks.txt", "optimization_actions.txt", "batch_tasks.txt"):
                self.assertTrue((task_dir / name).is_file(), name)
            self.assertEqual(list(task_dir.glob("*.csv")), [])

    def test_controller_writes_topology_action_protocol(self):
        with tempfile.TemporaryDirectory() as directory:
            task_dir = Path(directory)
            criteria = task_dir / "rules.criteria"
            criteria.write_text("quality = native_hypermesh\n", encoding="utf-8")
            (task_dir / "element_connectivity.txt").write_text(
                "element_id,component_id,n1,n2,n3,n4\n10,1,1,2,3,4\n", encoding="utf-8"
            )
            (task_dir / "node_coordinates.txt").write_text(
                "node_id,x,y,z\n1,0,0,0\n2,2,0,0\n3,1.8,1,0\n4,0,1.3,0\n",
                encoding="utf-8",
            )
            (task_dir / "failed_elements.txt").write_text("10\n", encoding="utf-8")
            (task_dir / "protected_edges.txt").write_text("n1,n2\n", encoding="utf-8")
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
            actions = (task_dir / "optimization_actions.txt").read_text(encoding="utf-8")
            self.assertIn("split_quad", actions)
            regions = json.loads((task_dir / "regions.json").read_text(encoding="utf-8"))
            self.assertEqual(regions[0]["planned_actions"][0]["action_type"], "split_quad")

            (task_dir / "region_results.txt").write_text(
                "region_id,final_failed_count,rounds,optimization_methods,elapsed_seconds,status,rollback_count,message\n"
                "Region_0001,0,1,split_quad,0.25,complete,0,done\n",
                encoding="utf-8",
            )
            finalized = subprocess.run(
                [
                    sys.executable,
                    str(PYTHON_DIR / "optimizer_controller.py"),
                    "--task",
                    str(task),
                    "--stage",
                    "finalize",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(finalized.returncode, 0, finalized.stderr.decode(errors="replace"))
            regions = json.loads((task_dir / "regions.json").read_text(encoding="utf-8"))
            self.assertEqual(regions[0]["current_failed_count"], 0)
            self.assertEqual(regions[0]["message"], "done")
            self.assertFalse((task_dir / "region_results.csv").exists())

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

    def test_planner_collapses_both_internal_short_edges_of_narrow_quad(self):
        elements = {
            10: ShellElement(10, 1, (1, 2, 3, 4)),
            11: ShellElement(11, 1, (5, 1, 4, 6)),
            12: ShellElement(12, 1, (2, 7, 8, 3)),
            13: ShellElement(13, 1, (9, 10, 2, 1)),
            14: ShellElement(14, 1, (4, 3, 12, 11)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0), 2: (5.0, 0.0, 0.0),
            3: (5.0, 0.2, 0.0), 4: (0.0, 0.2, 0.0),
            5: (-1.0, 0.0, 0.0), 6: (-1.0, 0.2, 0.0),
            7: (6.0, 0.0, 0.0), 8: (6.0, 0.2, 0.0),
            9: (0.0, -1.0, 0.0), 10: (5.0, -1.0, 0.0),
            11: (0.0, 1.2, 0.0), 12: (5.0, 1.2, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [10], "anchor_nodes": []}]
        actions = plan_optimization_actions(elements, [10], coordinates, regions)
        self.assertEqual(len(actions), 2)
        self.assertEqual({action["action_type"] for action in actions}, {"collapse_short_edge"})
        self.assertEqual(
            {frozenset((action["node_a"], action["node_b"])) for action in actions},
            {frozenset((1, 4)), frozenset((2, 3))},
        )
        self.assertEqual(len({action["action_id"] for action in actions}), 2)

    def test_skinny_triangle_edge_duplicates_paired_quad_edge_only_once(self):
        elements = {
            10: ShellElement(10, 1, (1, 2, 3, 4)),
            11: ShellElement(11, 1, (5, 1, 4, 6)),
            13: ShellElement(13, 1, (9, 10, 2, 1)),
            14: ShellElement(14, 1, (4, 3, 12, 11)),
            20: ShellElement(20, 1, (2, 7, 3)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0), 2: (5.0, 0.0, 0.0),
            3: (5.0, 0.2, 0.0), 4: (0.0, 0.2, 0.0),
            5: (-1.0, 0.0, 0.0), 6: (-1.0, 0.2, 0.0),
            7: (8.0, 0.1, 0.0), 9: (0.0, -1.0, 0.0),
            10: (5.0, -1.0, 0.0), 11: (0.0, 1.2, 0.0),
            12: (5.0, 1.2, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [10, 20], "anchor_nodes": []}]
        actions = plan_optimization_actions(elements, [10, 20], coordinates, regions)
        self.assertEqual(len(actions), 3)
        self.assertEqual({action["action_type"] for action in actions}, {"collapse_short_edge"})
        state = MeshState(coordinates, elements)
        unique, events = deduplicate_operations(adapt_existing_actions(actions, state))
        self.assertEqual(len(unique), 2)
        self.assertEqual(len(events), 1)

    def test_planner_allows_skinny_triangle_collapse_on_shared_failed_edge(self):
        elements = {
            20: ShellElement(20, 1, (1, 2, 3)),
            21: ShellElement(21, 1, (2, 4, 5, 3)),
            30: ShellElement(30, 1, (2, 6, 7, 4)),
            31: ShellElement(31, 1, (3, 5, 8, 9)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0),
            2: (1.0, 0.0, 0.0),
            3: (1.0, 0.05, 0.0),
            4: (6.0, 0.0, 0.0),
            5: (6.0, 0.05, 0.0),
            6: (1.0, -1.0, 0.0),
            7: (6.0, -1.0, 0.0),
            8: (6.0, 1.05, 0.0),
            9: (1.0, 1.05, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [20, 21], "anchor_nodes": []}]
        actions = plan_optimization_actions(elements, [20, 21], coordinates, regions)
        by_element = {action["element_id"]: action for action in actions}
        self.assertEqual(by_element[20]["action_type"], "collapse_short_edge")
        self.assertEqual({by_element[20]["node_a"], by_element[20]["node_b"]}, {2, 3})
        self.assertEqual(by_element[21]["action_type"], "manual_review")
        self.assertEqual(by_element[21]["reason"], "narrow_quad_requires_two_internal_short_edges")

    def test_planner_collapses_ultra_thin_triangle_beside_failed_quad(self):
        elements = {
            39907: ShellElement(39907, 1, (40040, 40041, 40342)),
            39909: ShellElement(39909, 1, (40041, 40042, 40343, 40342)),
        }
        coordinates = {
            40040: (30.0, 665.0, 0.0),
            40041: (35.0, 665.0, 0.0),
            40042: (40.0, 665.0, 0.0),
            40342: (35.0, 665.2, 0.0),
            40343: (40.0, 670.0, 0.0),
        }
        regions = [{
            "region_id": "Region_0001",
            "failed_elements": [39907, 39909],
            "anchor_nodes": [],
        }]
        actions = plan_optimization_actions(elements, [39907, 39909], coordinates, regions)
        by_element = {action["element_id"]: action for action in actions}
        self.assertEqual(by_element[39907]["action_type"], "collapse_short_edge")
        self.assertEqual(
            {by_element[39907]["node_a"], by_element[39907]["node_b"]},
            {40041, 40342},
        )
        self.assertEqual(by_element[39909]["action_type"], "manual_review")
        self.assertEqual(by_element[39909]["reason"], "adjacent_to_planned_edge_collapse")

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

    def test_connected_free_edge_chain_uses_one_coordinated_batch(self):
        elements = {
            1: ShellElement(1, 1, (1, 2, 6, 5)),
            2: ShellElement(2, 1, (2, 3, 7, 6)),
            3: ShellElement(3, 1, (3, 4, 8, 7)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0), 2: (5.0, 0.0, 0.0),
            3: (10.0, 0.0, 0.0), 4: (15.0, 0.0, 0.0),
            5: (0.0, 0.2, 0.0), 6: (5.0, 0.2, 0.0),
            7: (10.0, 0.2, 0.0), 8: (15.0, 0.2, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [1, 2, 3], "anchor_nodes": []}]
        actions = plan_optimization_actions(elements, [1, 2, 3], coordinates, regions)
        self.assertEqual({action["action_type"] for action in actions}, {"expand_free_edge"})
        self.assertEqual(len({action["split_method"] for action in actions}), 1)
        operations = adapt_existing_actions(actions, MeshState(coordinates, elements))
        batches, conflicts = plan_batches(operations, max_operations=1)
        self.assertEqual(conflicts, [])
        self.assertEqual(len(batches), 1)
        self.assertEqual(len(batches[0].operations), 3)

    def test_controller_does_not_disable_expansion_for_geometry_association(self):
        source = (PYTHON_DIR / "optimizer_controller.py").read_text(encoding="utf-8")
        setting = source.split('"allow_free_edge_move": (', 1)[1].split("),", 1)[0]
        self.assertIn("allow_controlled_free_edge_move", setting)
        self.assertNotIn("preserve_geometry_association", setting)

    def test_mesh_state_updates_only_local_indices(self):
        coordinates = {node: (float(node), 0.0, 0.0) for node in range(1, 11)}
        state = MeshState(coordinates, self.elements)
        self.assertEqual(state.element_neighbors[1], {2})
        removed = state.remove_element(2)
        self.assertEqual(removed.element_id, 2)
        self.assertEqual(state.element_neighbors[1], set())
        state.add_element(removed)
        self.assertEqual(state.element_neighbors[1], {2})
        dirty = state.dirty_region({2}, {1}, rings=1)
        self.assertIn(2, dirty.elements)
        self.assertIn((2, 5), dirty.edges)

    def test_operation_adapter_deduplicates_shared_edge(self):
        elements = {
            1: ShellElement(1, 1, (1, 2, 3)),
            2: ShellElement(2, 1, (2, 1, 4)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0), 2: (0.1, 0.0, 0.0),
            3: (0.0, 1.0, 0.0), 4: (0.1, 1.0, 0.0),
        }
        actions = []
        for index, element_id in enumerate((1, 2), 1):
            actions.append(
                {
                    "region_id": "Region_0001", "action_id": "A{}".format(index),
                    "action_type": "collapse_short_edge", "element_id": element_id,
                    "edge_index": 1, "node_a": 1, "node_b": 2,
                    "reference_a": 0, "reference_b": 0, "target_distance": 0.0,
                    "split_method": 0, "reason": "test",
                }
            )
        state = MeshState(coordinates, elements)
        operations = adapt_existing_actions(actions, state)
        unique, events = deduplicate_operations(operations)
        self.assertEqual(len(unique), 1)
        self.assertEqual(events[0]["kept_operation_id"], "OP_000001")

    def test_conflicting_operations_are_put_in_stable_batches(self):
        elements = {
            1: ShellElement(1, 1, (1, 2, 3, 4)),
            2: ShellElement(2, 1, (2, 5, 6, 3)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0), 2: (1.0, 0.0, 0.0),
            3: (1.0, 1.0, 0.0), 4: (0.0, 1.0, 0.0),
            5: (2.0, 0.0, 0.0), 6: (2.0, 1.0, 0.0),
        }
        actions = []
        for index, element_id in enumerate((1, 2), 1):
            actions.append(
                {
                    "region_id": "Region_0001", "action_id": "A{}".format(index),
                    "action_type": "split_quad", "element_id": element_id,
                    "edge_index": 0, "node_a": 0, "node_b": 0,
                    "reference_a": 0, "reference_b": 0, "target_distance": 0.0,
                    "split_method": 2, "reason": "test",
                }
            )
        state = MeshState(coordinates, elements)
        operations = adapt_existing_actions(actions, state)
        for operation in operations:
            valid, reason = prevalidate_operation(operation, state)
            operation.validation = {"valid": valid, "reason": reason}
        batches, conflicts = plan_batches(operations, max_operations=100)
        self.assertEqual([len(batch.operations) for batch in batches], [1, 1])
        self.assertEqual(conflicts[0]["reason"], "delete_read_element")

    def test_controller_writes_unified_operations_and_tcl_batches(self):
        with tempfile.TemporaryDirectory() as directory:
            task_dir = Path(directory)
            criteria = task_dir / "规则.criteria"
            criteria.write_text("quality = native_hypermesh\n", encoding="utf-8")
            (task_dir / "element_connectivity.txt").write_text(
                "element_id,component_id,n1,n2,n3,n4\n10,1,1,2,3,4\n", encoding="utf-8"
            )
            (task_dir / "node_coordinates.txt").write_text(
                "node_id,x,y,z\n1,0,0,0\n2,2,0,0\n3,1.8,1,0\n4,0,1.3,0\n",
                encoding="utf-8",
            )
            (task_dir / "failed_elements.txt").write_text("10\n", encoding="utf-8")
            (task_dir / "protected_edges.txt").write_text("n1,n2\n", encoding="utf-8")
            (task_dir / "protected_nodes.txt").write_text("", encoding="utf-8")
            task = task_dir / "task.json"
            task.write_text(
                json.dumps(
                    {
                        "criteria_path": str(criteria), "adjacency_layers": 1,
                        "max_region_elements": 100, "batch_max_operations": 50,
                        "protection": {"no_cross_component_movement": True, "feature_edges": False},
                    }, ensure_ascii=False
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [sys.executable, str(PYTHON_DIR / "optimizer_controller.py"), "--task", str(task)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
            operations = json.loads((task_dir / "operations.json").read_text(encoding="utf-8"))
            self.assertEqual(operations[0]["operation_type"], "split_quad")
            self.assertIn("read_set", operations[0])
            batches = json.loads((task_dir / "batches.json").read_text(encoding="utf-8"))
            self.assertEqual(batches[0]["operation_count"], 1)
            batch_file = next((task_dir / "batches").glob("*.tcl"))
            batch_text = batch_file.read_text(encoding="utf-8")
            self.assertIn("generatedBatchOperations", batch_text)
            self.assertIn('actionType "split_quad"', batch_text)
            metrics = json.loads((task_dir / "python_performance_metrics.json").read_text(encoding="utf-8"))
            self.assertEqual(metrics["counters"]["executable_batches"], 1)

    def test_parallel_disjoint_region_planning_matches_serial_actions(self):
        outputs = []
        region_counts = []
        for workers in (1, 2):
            with tempfile.TemporaryDirectory() as directory:
                task_dir = Path(directory)
                criteria = task_dir / "rules.criteria"
                criteria.write_text("quality = native_hypermesh\n", encoding="utf-8")
                (task_dir / "element_connectivity.txt").write_text(
                    "element_id,component_id,n1,n2,n3,n4\n"
                    "10,1,1,2,3,4\n20,2,5,6,7,8\n",
                    encoding="utf-8",
                )
                (task_dir / "node_coordinates.txt").write_text(
                    "node_id,x,y,z\n"
                    "1,0,0,0\n2,2,0,0\n3,1.8,1,0\n4,0,1.3,0\n"
                    "5,10,0,0\n6,12,0,0\n7,11.8,1,0\n8,10,1.3,0\n",
                    encoding="utf-8",
                )
                (task_dir / "failed_elements.txt").write_text("10\n20\n", encoding="utf-8")
                (task_dir / "protected_edges.txt").write_text("n1,n2\n", encoding="utf-8")
                (task_dir / "protected_nodes.txt").write_text("", encoding="utf-8")
                task = task_dir / "task.json"
                task.write_text(
                    json.dumps(
                        {
                            "criteria_path": str(criteria), "adjacency_layers": 1,
                            "max_region_elements": 100, "analysis_workers": workers,
                            "protection": {"no_cross_component_movement": True, "feature_edges": False},
                        }
                    ),
                    encoding="utf-8",
                )
                completed = subprocess.run(
                    [sys.executable, str(PYTHON_DIR / "optimizer_controller.py"), "--task", str(task)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
                outputs.append((task_dir / "optimization_actions.txt").read_text(encoding="utf-8"))
                regions = json.loads((task_dir / "regions.json").read_text(encoding="utf-8"))
                region_counts.append(len(regions))
        self.assertEqual(outputs[0], outputs[1])
        self.assertEqual(region_counts, [1, 1])


if __name__ == "__main__":
    unittest.main()
