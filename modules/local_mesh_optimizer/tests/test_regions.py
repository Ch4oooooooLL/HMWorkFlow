import csv
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

PYTHON_DIR = Path(__file__).resolve().parents[1] / "python"
sys.path.insert(0, str(PYTHON_DIR))

from adjacency import ShellElement, build_adjacency, connected_components, expand_region
from batch_planner import plan_batches, prevalidate_operation, write_batch_artifacts
from criteria_parser import parse_criteria_metadata
from mesh_state import MeshState
from operation_model import adapt_existing_actions, deduplicate_operations
from optimization_planner import plan_optimization_actions
from optimizer_controller import _presimulation_groups
import quality_simulator
from quality_simulator import optimize_operation_candidate, optimize_operation_group
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

    def test_tcl_workflow_uses_region_checkpoints_and_incremental_final_rollback(self):
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
        self.assertIn('set pythonMessage ""', source)
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
        self.assertIn("region_checkpoints", source)
        self.assertIn("restoreSnapshot $regionCheckpointPath", source)
        self.assertIn("rolling back latest accepted region", source)
        core = source.split("proc ::LocalMeshOptimizer::startOptimizationCore {}", 1)[1]
        self.assertNotIn("restoreSnapshot $runtime(backupPath)", core)
        worsened = source.split("if {[::LocalMeshOptimizer::qualityWorsened", 1)[1]
        worsened = worsened.split("}", 1)[0]
        self.assertNotIn("set taskRolledBack 1", worsened)
        self.assertNotIn("restoring pre-task model", worsened)

    def test_advanced_settings_initializes_layout_without_profile_gate(self):
        source = (Path(__file__).resolve().parents[2] / "local_mesh_optimizer.tcl").read_text(
            encoding="utf-8"
        )
        advanced = source.split("proc ::LocalMeshOptimizer::showAdvanced {}", 1)[1]
        advanced = advanced.split("proc ::LocalMeshOptimizer::closeWindow {}", 1)[0]
        self.assertLess(advanced.index("set row 0"), advanced.index("grid $w.main.mode -row $row"))
        self.assertIn("if {![winfo exists $w.btn.close]}", advanced)
        self.assertNotIn("internalquad", advanced)

        panel = source.split("proc ::LocalMeshOptimizer::showPanel {}", 1)[1]
        panel = panel.split("proc ::LocalMeshOptimizer::runAction {}", 1)[0]
        self.assertIn(
            '{ALLOW_INTERNAL_QUAD_EXPANSION "允许中部超窄四边形向两侧最小幅度扩展（默认关闭）"',
            panel,
        )

        start = source.split("proc ::LocalMeshOptimizer::startOptimization {}", 1)[1]
        start = start.split("proc ::LocalMeshOptimizer::startOptimizationCore {}", 1)[0]
        self.assertIn("optimizationPlanCurrent", start)
        self.assertNotIn("profileStatus", start)
        self.assertNotIn("showAdvanced", start)
        self.assertNotIn("HM2019_PROFILE", source)
        self.assertNotIn("hm2019_recorded", source)

    def test_tcl_declares_disabled_internal_expansion_and_exact_symmetric_move(self):
        import tkinter

        module = Path(__file__).resolve().parents[2] / "local_mesh_optimizer.tcl"
        source = module.read_text(encoding="utf-8")
        self.assertIn("ALLOW_INTERNAL_QUAD_EXPANSION 0", source)
        self.assertIn("allow_internal_quad_expansion", source)
        self.assertIn('} elseif {$type eq "expand_internal_quad"} {', source)
        self.assertIn('set moveMode [dict get $action moveMode]', source)
        self.assertIn('} elseif {$moveMode == 1} {', source)
        self.assertIn('targetCoordinateFromReference $referenceA $nodeA', source)
        self.assertIn('} elseif {$type eq "expand_triangle_short_edge"} {', source)

        interpreter = tkinter.Tcl()
        interpreter.eval("source -encoding utf-8 {{{}}}".format(module.as_posix()))
        interpreter.eval("rename ::LocalMeshOptimizer::nodeCoordinate ::LocalMeshOptimizer::savedNodeCoordinate")
        interpreter.eval(
            "proc ::LocalMeshOptimizer::nodeCoordinate {nodeId} { "
            "if {$nodeId == 1} {return {0 0 0}}; return {0.2 0 0} }"
        )
        targets = interpreter.splitlist(
            interpreter.eval("::LocalMeshOptimizer::symmetricExpansionTargets 1 2 1.0")
        )
        first = tuple(float(value) for value in interpreter.splitlist(targets[0]))
        second = tuple(float(value) for value in interpreter.splitlist(targets[1]))
        self.assertAlmostEqual(first[0], -0.4)
        self.assertAlmostEqual(second[0], 0.6)

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

    def test_controller_rejects_internal_quad_expansion_that_harms_neighbors(self):
        with tempfile.TemporaryDirectory() as directory:
            task_dir = Path(directory)
            criteria = task_dir / "rules.criteria"
            criteria.write_text(
                " 1 min length         1 1.0  5.0 4.0 3.0 1.0 0.5 1\n"
                " 3 aspect ratio       1 1.0  1.0 2.0 4.0 5.0 10.0 0\n",
                encoding="utf-8",
            )
            elements, coordinates, _ = self._internal_narrow_quad_case()
            connectivity = ["element_id,component_id,n1,n2,n3,n4"]
            for element in elements.values():
                connectivity.append(
                    ",".join(str(value) for value in (
                        element.element_id, element.component_id, *element.nodes
                    ))
                )
            (task_dir / "element_connectivity.txt").write_text(
                "\n".join(connectivity) + "\n", encoding="utf-8"
            )
            coordinate_rows = ["node_id,x,y,z"] + [
                "{},{},{},{}".format(node, *point)
                for node, point in sorted(coordinates.items())
            ]
            (task_dir / "node_coordinates.txt").write_text(
                "\n".join(coordinate_rows) + "\n", encoding="utf-8"
            )
            (task_dir / "failed_elements.txt").write_text("10\n", encoding="utf-8")
            (task_dir / "protected_edges.txt").write_text("n1,n2\n", encoding="utf-8")
            (task_dir / "protected_nodes.txt").write_text("", encoding="utf-8")
            task = task_dir / "task.json"
            task.write_text(
                json.dumps({
                    "criteria_path": str(criteria),
                    "adjacency_layers": 1,
                    "max_region_elements": 100,
                    "allow_internal_quad_expansion": True,
                    "protection": {"no_cross_component_movement": True, "feature_edges": False},
                }),
                encoding="utf-8",
            )

            completed = subprocess.run(
                [sys.executable, str(PYTHON_DIR / "optimizer_controller.py"), "--task", str(task)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
            regions = json.loads((task_dir / "regions.json").read_text(encoding="utf-8"))
            action = regions[0]["planned_actions"][0]
            self.assertEqual(action["action_type"], "expand_internal_quad")
            self.assertAlmostEqual(action["target_distance"], 1.0)
            operations = json.loads((task_dir / "operations.json").read_text(encoding="utf-8"))
            self.assertFalse(operations[0]["validation"]["valid"])
            self.assertEqual(
                operations[0]["validation"]["reason"],
                "quality_simulation_would_add_failure",
            )
            tcl_actions = (task_dir / "optimization_actions.txt").read_text(encoding="utf-8")
            self.assertNotIn("expand_internal_quad", tcl_actions)

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

    def test_criteria_parser_extracts_enabled_failure_limits(self):
        with tempfile.TemporaryDirectory() as directory:
            criteria = Path(directory) / "quality.criteria"
            criteria.write_text(
                " #    Criterion     On  Wt   Ideal  Good  Warn  Fail  Worst  Solver\n"
                " 1 min length         1 1.0  5.0    4.0   3.0   2.5   1.0    1\n"
                " 3 aspect ratio       1 1.0  1.0    2.0   4.0   5.0   10.0   0\n"
                " 8 min angle tria     1 1.0 60.0   50.0  34.0  30.0   15.0   0\n",
                encoding="utf-8",
            )

            metadata = parse_criteria_metadata(criteria)

            self.assertEqual(metadata["quality_limits"]["minimum_length"], 2.5)
            self.assertEqual(metadata["quality_limits"]["maximum_aspect_ratio"], 5.0)
            self.assertEqual(metadata["quality_limits"]["minimum_angle_tria"], 30.0)

    def test_internal_narrow_quad_expansion_is_disabled_by_default(self):
        elements, coordinates, regions = self._internal_narrow_quad_case()

        action = plan_optimization_actions(elements, [10], coordinates, regions)[0]

        self.assertEqual(action["action_type"], "manual_review")
        self.assertEqual(action["reason"], "internal_quad_expansion_disabled")

    def test_internal_narrow_quad_expands_both_sides_by_minimum_amount(self):
        elements, coordinates, regions = self._internal_narrow_quad_case()

        action = plan_optimization_actions(
            elements,
            [10],
            coordinates,
            regions,
            allow_internal_quad_expansion=True,
            minimum_length=1.0,
            maximum_aspect_ratio=5.0,
        )[0]

        self.assertEqual(action["action_type"], "expand_internal_quad")
        self.assertEqual(
            {action["node_a"], action["node_b"], action["reference_a"], action["reference_b"]},
            {1, 2, 3, 4},
        )
        # Current width is 0.2 and the minimum passing width is 1.0. Tcl derives
        # the symmetric 0.4 displacement on each side from this final width.
        self.assertAlmostEqual(action["target_distance"], 1.0)

        operation = adapt_existing_actions([action], MeshState(coordinates, elements))[0]
        valid, reason = prevalidate_operation(operation, MeshState(coordinates, elements))
        self.assertTrue(valid, reason)

    def test_internal_quad_keeps_each_side_at_its_own_minimum_target(self):
        elements, coordinates, regions = self._internal_narrow_quad_case()
        coordinates[3] = (5.0, 0.4, 0.0)

        action = plan_optimization_actions(
            elements,
            [10],
            coordinates,
            regions,
            allow_internal_quad_expansion=True,
            minimum_length=0.3,
            maximum_aspect_ratio=100.0,
        )[0]

        self.assertEqual(action["action_type"], "expand_internal_quad")
        self.assertAlmostEqual(action["target_distance"], 0.3)
        self.assertAlmostEqual(action["target_distance_b"], 0.4)

    def test_moderate_triangle_expands_short_edge_to_criteria_minimum(self):
        elements = {20: ShellElement(20, 1, (1, 2, 3))}
        coordinates = {
            1: (0.0, 0.0, 0.0),
            2: (0.5, 0.0, 0.0),
            3: (0.0, 1.0, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [20], "anchor_nodes": []}]

        action = plan_optimization_actions(
            elements,
            [20],
            coordinates,
            regions,
            minimum_length=1.0,
            maximum_aspect_ratio=5.0,
        )[0]

        self.assertEqual(action["action_type"], "expand_triangle_short_edge")
        self.assertEqual({action["node_a"], action["node_b"]}, {1, 2})
        self.assertAlmostEqual(action["target_distance"], 1.0)
        operation = adapt_existing_actions([action], MeshState(coordinates, elements))[0]
        valid, reason = prevalidate_operation(operation, MeshState(coordinates, elements))
        self.assertTrue(valid, reason)

    def test_triangle_with_extreme_long_short_ratio_is_not_expanded(self):
        elements = {20: ShellElement(20, 1, (1, 2, 3))}
        coordinates = {
            1: (0.0, 0.0, 0.0),
            2: (0.5, 0.0, 0.0),
            3: (100.0, 0.1, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [20], "anchor_nodes": []}]

        action = plan_optimization_actions(
            elements, [20], coordinates, regions, minimum_length=1.0
        )[0]

        self.assertEqual(action["action_type"], "collapse_short_edge")

    def test_python_precheck_rejects_triangle_expansion_that_flips_a_neighbor(self):
        elements = {
            20: ShellElement(20, 1, (1, 2, 3)),
            21: ShellElement(21, 1, (1, 4, 5)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0),
            2: (0.5, 0.0, 0.0),
            3: (0.0, 1.0, 0.0),
            4: (-0.1, 0.0, 0.0),
            5: (0.0, 0.1, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [20], "anchor_nodes": []}]
        action = plan_optimization_actions(
            elements, [20], coordinates, regions, minimum_length=1.0
        )[0]
        operation = adapt_existing_actions([action], MeshState(coordinates, elements))[0]

        valid, reason = prevalidate_operation(operation, MeshState(coordinates, elements))

        self.assertFalse(valid)
        self.assertEqual(reason, "triangle_expansion_would_invert_or_collapse_shell")

    def test_python_quality_simulation_reduces_step_until_no_new_failure(self):
        elements = {
            20: ShellElement(20, 1, (1, 2, 3)),
            21: ShellElement(21, 1, (1, 4, 5)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0), 2: (0.5, 0.0, 0.0), 3: (0.0, 1.0, 0.0),
            4: (-1.5, 0.0, 0.0), 5: (-1.5, 1.5, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [20], "anchor_nodes": []}]
        action = plan_optimization_actions(elements, [20], coordinates, regions, minimum_length=1.0)[0]
        state = MeshState(coordinates, elements)
        operation = adapt_existing_actions([action], state)[0]

        valid, reason, detail = optimize_operation_candidate(
            operation, state, {"minimum_length": 1.0, "minimum_angle_tria": 40.0}
        )

        self.assertTrue(valid, detail)
        self.assertEqual(reason, "quality_simulation_safe_step")
        self.assertAlmostEqual(operation.legacy_action["target_distance"], 0.875)
        self.assertAlmostEqual(detail["accepted_scale"], 0.75)

    def test_python_quality_simulation_rejects_when_every_step_adds_failure(self):
        elements = {
            20: ShellElement(20, 1, (1, 2, 3)),
            21: ShellElement(21, 1, (1, 4, 5)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0), 2: (0.5, 0.0, 0.0), 3: (0.0, 1.0, 0.0),
            4: (-1.27, 0.0, 0.0), 5: (-1.27, 1.5, 0.0),
        }
        regions = [{"region_id": "Region_0001", "failed_elements": [20], "anchor_nodes": []}]
        action = plan_optimization_actions(elements, [20], coordinates, regions, minimum_length=1.0)[0]
        state = MeshState(coordinates, elements)
        operation = adapt_existing_actions([action], state)[0]

        valid, reason, detail = optimize_operation_candidate(
            operation, state, {"minimum_length": 1.0, "minimum_angle_tria": 40.0}
        )

        self.assertFalse(valid, detail)
        self.assertEqual(reason, "quality_simulation_would_add_failure")

    def test_quality_simulation_copies_only_the_affected_submesh(self):
        elements = {}
        coordinates = {}
        for index in range(1000):
            base = index * 4 + 1
            x = float(index * 3)
            nodes = (base, base + 1, base + 2, base + 3)
            coordinates.update({
                nodes[0]: (x, 0.0, 0.0), nodes[1]: (x + 1.0, 0.0, 0.0),
                nodes[2]: (x + 1.0, 1.0, 0.0), nodes[3]: (x, 1.0, 0.0),
            })
            elements[index + 1] = ShellElement(index + 1, 1, nodes)
        state = MeshState(coordinates, elements)
        action = {
            "region_id": "Region_0001", "action_id": "A1",
            "action_type": "split_quad", "element_id": 1, "edge_index": 0,
            "node_a": 0, "node_b": 0, "reference_a": 0, "reference_b": 0,
            "target_distance": 0.0, "target_distance_b": 0.0,
            "split_method": 2, "reason": "test",
        }
        operation = adapt_existing_actions([action], state)[0]
        copied_sizes = []
        real_mesh_state = quality_simulator.MeshState

        class RecordingMeshState(real_mesh_state):
            def __init__(self, nodes, candidate_elements):
                copied_sizes.append(len(candidate_elements))
                super().__init__(nodes, candidate_elements)

        with patch.object(quality_simulator, "MeshState", RecordingMeshState):
            valid, reason, detail = optimize_operation_candidate(
                operation, state, {"maximum_aspect_ratio": 10.0}
            )

        self.assertTrue(valid, (reason, detail))
        self.assertTrue(copied_sizes)
        self.assertLessEqual(max(copied_sizes), len(operation.affected_elements))

    def test_split_prevalidation_uses_node_signature_index_not_full_scan(self):
        elements = {
            1: ShellElement(1, 1, (1, 2, 3, 4)),
            2: ShellElement(2, 1, (5, 6, 7, 8)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0), 2: (1.0, 0.0, 0.0),
            3: (1.0, 1.0, 0.0), 4: (0.0, 1.0, 0.0),
            5: (3.0, 0.0, 0.0), 6: (4.0, 0.0, 0.0),
            7: (4.0, 1.0, 0.0), 8: (3.0, 1.0, 0.0),
        }
        state = MeshState(coordinates, elements)
        action = {
            "region_id": "Region_0001", "action_id": "A1",
            "action_type": "split_quad", "element_id": 1, "edge_index": 0,
            "node_a": 0, "node_b": 0, "reference_a": 0, "reference_b": 0,
            "target_distance": 0.0, "target_distance_b": 0.0,
            "split_method": 2, "reason": "test",
        }
        operation = adapt_existing_actions([action], state)[0]

        class NoFullScanDict(dict):
            def values(self):
                raise AssertionError("split validation scanned the full model")

        state.elements = NoFullScanDict(state.elements)
        valid, reason = prevalidate_operation(operation, state)

        self.assertTrue(valid, reason)

    @staticmethod
    def _internal_narrow_quad_case():
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
        return elements, coordinates, regions

    def test_planner_expands_internal_narrow_quad_when_enabled(self):
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
        actions = plan_optimization_actions(
            elements, [10], coordinates, regions,
            allow_internal_quad_expansion=True,
        )
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["action_type"], "expand_internal_quad")
        self.assertEqual(
            {
                actions[0]["node_a"], actions[0]["node_b"],
                actions[0]["reference_a"], actions[0]["reference_b"],
            },
            {1, 2, 3, 4},
        )

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
        self.assertEqual(len(actions), 2)
        self.assertEqual(
            {action["action_type"] for action in actions},
            {"collapse_short_edge", "manual_review"},
        )
        state = MeshState(coordinates, elements)
        unique, events = deduplicate_operations(adapt_existing_actions(actions, state))
        self.assertEqual(len(unique), 2)
        self.assertEqual(len(events), 0)

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
        self.assertEqual(by_element[21]["reason"], "narrow_quad_not_fully_internal")

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
        self.assertEqual(len(_presimulation_groups(operations)), 1)
        batches, conflicts = plan_batches(operations, max_operations=1)
        self.assertEqual(conflicts, [])
        self.assertEqual(len(batches), 1)
        self.assertEqual(len(batches[0].operations), 3)

    def test_python_simulates_connected_free_edge_chain_as_one_move(self):
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
        actions = plan_optimization_actions(
            elements, [1, 2, 3], coordinates, regions,
            minimum_length=1.0, maximum_aspect_ratio=10.0,
        )
        state = MeshState(coordinates, elements)
        operations = adapt_existing_actions(actions, state)

        valid, reason, detail = optimize_operation_group(
            operations,
            state,
            {
                "minimum_length": 1.0,
                "maximum_aspect_ratio": 10.0,
                "minimum_angle_quad": 30.0,
                "maximum_angle_quad": 150.0,
            },
        )

        self.assertTrue(valid, (reason, detail))

    def test_connected_internal_expansion_chain_uses_one_coordinated_batch(self):
        elements = {
            1: ShellElement(1, 1, (1, 2, 6, 5)),
            2: ShellElement(2, 1, (2, 3, 7, 6)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0), 2: (5.0, 0.0, 0.0), 3: (10.0, 0.0, 0.0),
            5: (0.0, 0.2, 0.0), 6: (5.0, 0.2, 0.0), 7: (10.0, 0.2, 0.0),
        }
        actions = []
        for element_id, nodes in ((1, (1, 2, 5, 6)), (2, (2, 3, 6, 7))):
            actions.append({
                "region_id": "Region_0001", "action_id": "A{}".format(element_id),
                "action_type": "expand_internal_quad", "element_id": element_id,
                "edge_index": 1, "node_a": nodes[0], "node_b": nodes[1],
                "reference_a": nodes[2], "reference_b": nodes[3],
                "target_distance": 1.0, "target_distance_b": 1.0,
                "move_mode": 2, "split_method": 1, "reason": "test_chain",
            })
        operations = adapt_existing_actions(actions, MeshState(coordinates, elements))

        batches, conflicts = plan_batches(operations, max_operations=1)

        self.assertEqual(conflicts, [])
        self.assertEqual(len(batches), 1)
        self.assertEqual(len(batches[0].operations), 2)

    @staticmethod
    def _weld_strip_case(both_sides_perpendicular=False):
        elements = {
            10: ShellElement(10, 10, (1, 2, 3, 4)),
            11: ShellElement(11, 20, (5, 6, 2, 1)),
            12: ShellElement(12, 30, (4, 3, 8, 7)),
            13: ShellElement(13, 10, (9, 1, 4, 10)),
            14: ShellElement(14, 10, (2, 11, 12, 3)),
        }
        coordinates = {
            1: (0.0, 0.0, 0.0), 2: (5.0, 0.0, 0.0),
            3: (5.0, 0.2, 0.0), 4: (0.0, 0.2, 0.0),
            5: (0.0, 0.0, -1.0), 6: (5.0, 0.0, -1.0),
            9: (-1.0, 0.0, 0.0), 10: (-1.0, 0.2, 0.0),
            11: (6.0, 0.0, 0.0), 12: (6.0, 0.2, 0.0),
        }
        if both_sides_perpendicular:
            coordinates.update({7: (0.0, 0.2, 1.0), 8: (5.0, 0.2, 1.0)})
        else:
            coordinates.update({7: (0.0, 1.2, 0.0), 8: (5.0, 1.2, 0.0)})
        regions = [{"region_id": "Region_0001", "failed_elements": [10], "anchor_nodes": []}]
        return elements, coordinates, regions

    def test_weld_strip_with_one_perpendicular_attachment_moves_junction_chain(self):
        elements, coordinates, regions = self._weld_strip_case(False)
        blocked = {(1, 2), (3, 4)}

        action = plan_optimization_actions(
            elements, [10], coordinates, regions,
            blocked_edges=blocked,
            allow_internal_quad_expansion=True,
            minimum_length=1.0,
            maximum_aspect_ratio=10.0,
        )[0]

        self.assertEqual(action["action_type"], "expand_internal_quad")
        self.assertEqual(action["move_mode"], 1)
        self.assertEqual(action["reason"], "weld_strip_single_side_chain_translation")
        valid, reason, detail = optimize_operation_group(
            adapt_existing_actions([action], MeshState(coordinates, elements)),
            MeshState(coordinates, elements),
            {"minimum_length": 1.0, "maximum_aspect_ratio": 10.0, "maximum_warpage": 15.0},
        )
        self.assertTrue(valid, (reason, detail))

    def test_weld_strip_with_two_perpendicular_attachments_expands_both_sides(self):
        elements, coordinates, regions = self._weld_strip_case(True)

        action = plan_optimization_actions(
            elements, [10], coordinates, regions,
            blocked_edges={(1, 2), (3, 4)},
            allow_internal_quad_expansion=True,
            minimum_length=1.0,
            maximum_aspect_ratio=10.0,
        )[0]

        self.assertEqual(action["action_type"], "expand_internal_quad")
        self.assertEqual(action["move_mode"], 0)
        self.assertEqual(action["reason"], "weld_strip_two_side_chain_expansion")
        valid, reason, detail = optimize_operation_group(
            adapt_existing_actions([action], MeshState(coordinates, elements)),
            MeshState(coordinates, elements),
            {"minimum_length": 1.0, "maximum_aspect_ratio": 10.0, "maximum_warpage": 15.0},
        )
        self.assertTrue(valid, (reason, detail))

    def test_controller_does_not_disable_expansion_for_geometry_association(self):
        source = (PYTHON_DIR / "optimizer_controller.py").read_text(encoding="utf-8")
        setting = source.split('"allow_free_edge_move": (', 1)[1].split("),", 1)[0]
        self.assertIn("allow_controlled_free_edge_move", setting)
        self.assertNotIn("preserve_geometry_association", setting)

    def test_mesh_state_updates_only_local_indices(self):
        coordinates = {node: (float(node), 0.0, 0.0) for node in range(1, 11)}
        state = MeshState(coordinates, self.elements)
        self.assertEqual(state.element_neighbors[1], {2})
        signature = tuple(sorted(self.elements[2].nodes))
        self.assertEqual(state.node_signature_to_elements[signature], {2})
        removed = state.remove_element(2)
        self.assertEqual(removed.element_id, 2)
        self.assertEqual(state.element_neighbors[1], set())
        self.assertNotIn(signature, state.node_signature_to_elements)
        state.add_element(removed)
        self.assertEqual(state.element_neighbors[1], {2})
        self.assertEqual(state.node_signature_to_elements[signature], {2})
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
