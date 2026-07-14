#!/usr/bin/env python3
"""File-protocol controller for Local Mesh Optimizer."""

from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
import traceback
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Dict, Mapping, Optional, Sequence

# The Windows embeddable distribution uses a restrictive pythonXY._pth file.
# Add the controller directory explicitly so sibling modules remain importable
# without enabling site-packages or installing anything on the user machine.
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from adjacency import read_connectivity
from batch_planner import plan_batches, prevalidate_operation, write_batch_artifacts
from criteria_parser import parse_criteria_metadata
from io_utils import atomic_write_json, atomic_write_text, read_id_file, read_json
from mesh_state import MeshState
from operation_model import adapt_existing_actions, deduplicate_operations
from optimization_planner import plan_optimization_actions
from performance_metrics import PerformanceMetrics
from region_builder import (
    build_regions,
    feature_edges,
    merge_independent_regions,
    read_blocked_edges,
    read_node_coordinates,
)
from report_generator import generate_report

EXIT_SUCCESS = 0
EXIT_PARTIAL = 1
EXIT_CANCELLED = 2
EXIT_INPUT = 3
EXIT_HYPERMESH = 4
EXIT_INTERNAL = 5


def _plan_one_region(arguments: Dict[str, object]) -> list:
    """Process-pool entry; inputs contain only pickle-safe standard objects."""
    return plan_optimization_actions(**arguments)


def _regions_have_disjoint_nodes(regions: Sequence[dict], elements: Mapping[int, object]) -> bool:
    claimed = set()
    for region in regions:
        nodes = {
            node
            for element_id in region["expanded_elements"]
            if element_id in elements
            for node in elements[element_id].nodes
        }
        if claimed.intersection(nodes):
            return False
        claimed.update(nodes)
    return True


def _path(task_dir: Path, task: Dict[str, object], key: str, default: str) -> Path:
    value = str(task.get(key, default))
    path = Path(value)
    return path if path.is_absolute() else task_dir / path


def _configure_logging(task_dir: Path) -> None:
    # pythonw.exe intentionally has no console and may expose sys.stderr as
    # None. Keep the task log authoritative; the Tcl launcher reserves its
    # redirected stderr file for interpreter/bootstrap failures.
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] [Python] %(message)s",
        handlers=[logging.FileHandler(str(task_dir / "optimizer_python.log"), encoding="utf-8")],
    )


def _progress(task_dir: Path, stage: str, percent: float, message: str) -> None:
    atomic_write_json(
        task_dir / "progress.json",
        {"stage": stage, "percent": percent, "message": message, "cancelled": False},
    )


def _write_performance_report(task_dir: Path, report_dir: Path, task: Dict[str, object]) -> None:
    python_path = task_dir / "python_performance_metrics.json"
    tcl_path = task_dir / "tcl_performance_metrics.json"
    python_metrics = read_json(python_path) if python_path.exists() else {"timings_seconds": {}, "counters": {}}
    tcl_metrics = read_json(tcl_path) if tcl_path.exists() else {"timings_seconds": {}, "counters": {}}
    operation_total = int(tcl_metrics.get("counters", {}).get("operation_total", 0))
    topology_seconds = float(tcl_metrics.get("timings_seconds", {}).get("hm_topology_operations", 0.0))
    payload = {
        "execution_mode": str(task.get("execution_mode", "batch")),
        "python": python_metrics,
        "tcl_hypermesh": tcl_metrics,
        "derived": {
            "average_hm_seconds_per_operation": (
                topology_seconds / operation_total if operation_total else 0.0
            ),
            "live_hypermesh_measurement_available": bool(tcl_path.exists()),
        },
    }
    atomic_write_json(report_dir / "performance_metrics.json", payload)
    rows = ["layer,kind,name,value"]
    for layer, metrics in (("python", python_metrics), ("tcl_hypermesh", tcl_metrics)):
        for kind in ("timings_seconds", "counters"):
            for name, value in sorted(metrics.get(kind, {}).items()):
                rows.append("{},{},{},{}".format(layer, kind, name, value))
    rows.append(
        "derived,metric,average_hm_seconds_per_operation,{}".format(
            payload["derived"]["average_hm_seconds_per_operation"]
        )
    )
    atomic_write_text(report_dir / "performance_metrics.csv", "\n".join(rows) + "\n")


def build(task_path: Path) -> int:
    task_path = task_path.resolve()
    task_dir = task_path.parent
    _configure_logging(task_dir)
    metrics = PerformanceMetrics()
    metrics.increment("python_starts")
    task = read_json(task_path)
    _progress(task_dir, "validating", 5.0, "正在验证区域构建输入")
    criteria = Path(str(task.get("criteria_path", "")))
    if not criteria.is_absolute():
        criteria = (task_dir / criteria).resolve()
    with metrics.measure("criteria_parse"):
        metadata = parse_criteria_metadata(criteria)
    atomic_write_json(task_dir / "criteria_metadata.json", metadata)
    if (task_dir / "cancel.flag").exists():
        _progress(task_dir, "cancelled", 100.0, "用户已取消")
        return EXIT_CANCELLED
    with metrics.measure("topology_read"):
        elements = read_connectivity(_path(task_dir, task, "connectivity_file", "element_connectivity.csv"))
    failed = read_id_file(_path(task_dir, task, "failed_elements_file", "failed_elements.txt"))
    if not failed:
        atomic_write_json(task_dir / "regions.json", [])
        atomic_write_text(task_dir / "region_tasks.csv", "region_id,failed_elements,expanded_elements,components,anchor_nodes\n")
        atomic_write_text(
            task_dir / "optimization_actions.csv",
            "region_id,action_id,action_type,element_id,edge_index,node_a,node_b,reference_a,reference_b,target_distance,split_method,reason\n",
        )
        write_batch_artifacts(task_dir, [], [], [])
        atomic_write_json(task_dir / "python_performance_metrics.json", metrics.to_dict())
        _progress(task_dir, "ready", 100.0, "没有失败单元")
        return EXIT_SUCCESS
    _progress(task_dir, "building_regions", 35.0, "正在按共享边划分失败区域")
    with metrics.measure("topology_read"):
        blocked_edges = read_blocked_edges(_path(task_dir, task, "protected_edges_file", "protected_edges.csv"))
        coordinates = read_node_coordinates(_path(task_dir, task, "node_coordinates_file", "node_coordinates.csv"))
    user_anchor_nodes = set(read_id_file(_path(task_dir, task, "protected_nodes_file", "protected_nodes.txt")))
    protect_features = bool(task.get("protection", {}).get("feature_edges", True))
    if protect_features:
        blocked_edges.update(feature_edges(elements, coordinates, float(task.get("feature_angle", 30.0))))
    with metrics.measure("region_build"):
        regions = build_regions(
            elements=elements,
            failed_ids=failed,
            layers=int(task.get("adjacency_layers", 2)),
            max_region_elements=int(task.get("max_region_elements", 50000)),
            blocked_edges=blocked_edges,
            cross_components=not bool(task.get("protection", {}).get("no_cross_component_movement", True)),
            coordinates=coordinates,
            user_anchor_nodes=user_anchor_nodes,
            protect_feature_edges=False,
            feature_angle=float(task.get("feature_angle", 30.0)),
        )
    metrics.increment("source_regions", len(regions))
    if (
        str(task.get("execution_mode", "batch")) == "batch"
        and bool(task.get("enable_macro_batching", True))
        and len(regions) > 1
    ):
        with metrics.measure("macro_region_packing"):
            regions = merge_independent_regions(
                regions,
                elements,
                coordinates,
                max_source_regions=int(task.get("macro_max_regions", 200)),
                max_failed_elements=int(task.get("macro_max_failures", 500)),
                max_expanded_elements=int(task.get("macro_max_elements", 10000)),
            )
    metrics.increment("execution_regions", len(regions))
    with metrics.measure("candidate_generation"):
        planner_common = {
            "elements": elements,
            "coordinates": coordinates,
            "blocked_edges": blocked_edges,
            "user_anchor_nodes": user_anchor_nodes,
            "allow_free_edge_move": (
                bool(task.get("allow_controlled_free_edge_move", True))
                and str(task.get("optimization_level", "standard")) != "quick"
            ),
            "skinny_triangle_ratio": float(task.get("skinny_triangle_ratio", 2.5)),
            "narrow_quad_ratio": float(task.get("narrow_quad_ratio", 2.5)),
            "narrow_target_aspect": float(task.get("narrow_target_aspect", 1.5)),
        }
        requested_workers = max(1, min(8, int(task.get("analysis_workers", 1))))
        can_parallelize = (
            requested_workers > 1
            and len(regions) > 1
            and _regions_have_disjoint_nodes(regions, elements)
        )
        if can_parallelize:
            jobs = []
            for region in regions:
                job = dict(planner_common)
                job["failed_ids"] = list(region["failed_elements"])
                job["regions"] = [region]
                jobs.append(job)
            with ProcessPoolExecutor(max_workers=min(requested_workers, len(jobs))) as executor:
                actions = [action for result in executor.map(_plan_one_region, jobs) for action in result]
            action_priority = {"collapse_short_edge": 0, "expand_free_edge": 1, "split_quad": 2, "manual_review": 3}
            actions.sort(
                key=lambda action: (
                    str(action["region_id"]),
                    action_priority[str(action["action_type"])],
                    int(action["element_id"]),
                )
            )
            for index, action in enumerate(actions, 1):
                action["action_id"] = "{}_A{:06d}".format(action["region_id"], index)
            metrics.increment("parallel_region_jobs", len(jobs))
        else:
            actions = plan_optimization_actions(
                failed_ids=failed,
                regions=regions,
                **planner_common
            )
            metrics.increment("serial_region_planning")
    actions_by_region: Dict[str, list] = {}
    for action in actions:
        actions_by_region.setdefault(str(action["region_id"]), []).append(action)
    # Preserve the existing controlled-free-edge exception: region perimeter
    # anchors remain protected except for explicitly planned moving nodes.
    for region in regions:
        region_actions = actions_by_region.get(str(region["region_id"]), [])
        controlled_nodes = {
            int(node)
            for action in region_actions
            if action["action_type"] == "expand_free_edge"
            for node in (action["node_a"], action["node_b"])
        }
        region["anchor_nodes"] = sorted(
            set(region["anchor_nodes"]).difference(controlled_nodes.difference(user_anchor_nodes))
        )
    with metrics.measure("mesh_state_build"):
        mesh_state = MeshState(coordinates, elements)
    with metrics.measure("operation_adaptation_and_deduplication"):
        all_operations = adapt_existing_actions(actions, mesh_state)
        operations, dedupe_events = deduplicate_operations(all_operations)
    region_anchors = {
        str(region["region_id"]): set(region.get("anchor_nodes", [])).union(user_anchor_nodes)
        for region in regions
    }
    presimulation = bool(task.get("enable_presimulation", True))
    with metrics.measure("candidate_presimulation"):
        for operation in operations:
            if presimulation:
                valid, reason = prevalidate_operation(
                    operation,
                    mesh_state,
                    region_anchors.get(str(operation.metadata.get("region_id", "")), user_anchor_nodes),
                )
            else:
                valid, reason = (operation.operation_type != "manual_review", "disabled")
            operation.validation = {"valid": valid, "reason": reason, "layer": "python_precheck"}
            if not valid and operation.operation_type != "manual_review":
                operation.status = "validation_failed"
    with metrics.measure("conflict_analysis_and_batching"):
        batches, conflicts = plan_batches(
            operations,
            max_operations=int(task.get("batch_max_operations", 200)),
        )
    write_batch_artifacts(task_dir, all_operations, batches, conflicts)
    atomic_write_json(task_dir / "deduplication_events.json", dedupe_events)
    metrics.increment("candidate_operations", len(all_operations))
    metrics.increment("deduplicated_operations", len(all_operations) - len(operations))
    metrics.increment("validation_failed_operations", sum(1 for operation in operations if operation.status == "validation_failed"))
    metrics.increment("executable_batches", len(batches))
    metrics.increment("executable_operations", sum(len(batch.operations) for batch in batches))
    metrics.increment("conflict_edges", len(conflicts))
    for region in regions:
        region_actions = actions_by_region.get(str(region["region_id"]), [])
        region["planned_actions"] = region_actions
        region["manual_review_count"] = sum(
            1 for action in region_actions if action["action_type"] == "manual_review"
        )
        region["planned_batch_count"] = sum(1 for batch in batches if batch.region_id == region["region_id"])
    atomic_write_json(task_dir / "regions.json", regions)
    rows = ["region_id,failed_elements,expanded_elements,components,anchor_nodes"]
    for region in regions:
        rows.append(
            ",".join(
                [
                    region["region_id"],
                    ";".join(str(value) for value in region["failed_elements"]),
                    ";".join(str(value) for value in region["expanded_elements"]),
                    ";".join(str(value) for value in region["components"]),
                    ";".join(str(value) for value in region["anchor_nodes"]),
                ]
            )
        )
    atomic_write_text(task_dir / "region_tasks.csv", "\n".join(rows) + "\n")
    action_fields = (
        "region_id", "action_id", "action_type", "element_id", "edge_index",
        "node_a", "node_b", "reference_a", "reference_b", "target_distance",
        "split_method", "reason",
    )
    action_rows = [",".join(action_fields)]
    for action in actions:
        action_rows.append(",".join(str(action[field]) for field in action_fields))
    atomic_write_text(task_dir / "optimization_actions.csv", "\n".join(action_rows) + "\n")
    atomic_write_json(task_dir / "python_performance_metrics.json", metrics.to_dict())
    _progress(task_dir, "ready", 100.0, "区域构建完成：{} 个".format(len(regions)))
    logging.info("Built %d regions from %d failed elements", len(regions), len(failed))
    return EXIT_SUCCESS


def finalize(task_path: Path) -> int:
    task_path = task_path.resolve()
    task_dir = task_path.parent
    _configure_logging(task_dir)
    task = read_json(task_path)
    regions = read_json(task_dir / "regions.json")
    updates = {}
    updates_path = task_dir / "region_results.csv"
    if updates_path.exists():
        with updates_path.open("r", encoding="utf-8-sig", newline="") as stream:
            for row in csv.DictReader(stream):
                updates[row["region_id"]] = row
    for region in regions:
        row = updates.get(region["region_id"])
        if not row:
            continue
        for key in ("status", "message"):
            if row.get(key, ""):
                region[key] = row[key]
        for source, target in (
            ("final_failed_count", "current_failed_count"),
            ("rounds", "rounds"),
            ("rollback_count", "rollback_count"),
        ):
            if row.get(source, ""):
                region[target] = int(row[source])
        if row.get("elapsed_seconds", ""):
            region["elapsed_seconds"] = float(row["elapsed_seconds"])
        if row.get("optimization_methods", ""):
            region["optimization_methods"] = [
                value for value in row["optimization_methods"].split(";") if value
            ]
    atomic_write_json(task_dir / "regions.json", regions)
    result_path = task_dir / "result.json"
    result = read_json(result_path) if result_path.exists() else {}
    result.setdefault("checked_elements", int(task.get("checked_elements", 0)))
    result.setdefault("failed_before", int(task.get("failed_before", 0)))
    result.setdefault(
        "failed_after", sum(int(region.get("current_failed_count", 0)) for region in regions)
    )
    atomic_write_json(result_path, result)
    report_dir = _path(task_dir, task, "report_dir", "report")
    _write_performance_report(task_dir, report_dir, task)
    generate_report(report_dir, task, result, regions, task_dir=task_dir)
    _progress(task_dir, "reported", 100.0, "结果汇总和报告生成完成")
    return EXIT_CANCELLED if result.get("cancelled") else EXIT_SUCCESS


def report(task_path: Path) -> int:
    task_path = task_path.resolve()
    task_dir = task_path.parent
    _configure_logging(task_dir)
    task = read_json(task_path)
    regions_path = task_dir / "regions.json"
    result_path = task_dir / "result.json"
    regions = read_json(regions_path) if regions_path.exists() else []
    result = read_json(result_path) if result_path.exists() else {}
    report_dir = _path(task_dir, task, "report_dir", "report")
    _write_performance_report(task_dir, report_dir, task)
    generate_report(report_dir, task, result, regions, task_dir=task_dir)
    _progress(task_dir, "reported", 100.0, "报告生成完成")
    return EXIT_CANCELLED if result.get("cancelled") else EXIT_SUCCESS


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task", required=True, type=Path)
    parser.add_argument("--stage", choices=("build-regions", "finalize", "report"), default="build-regions")
    parser.add_argument("--status-file", type=Path, help="Atomic completion status written for the Tcl launcher")
    arguments = parser.parse_args(argv)
    exit_code = EXIT_INTERNAL
    status_message = ""
    try:
        if arguments.stage == "build-regions":
            exit_code = build(arguments.task)
        elif arguments.stage == "finalize":
            exit_code = finalize(arguments.task)
        else:
            exit_code = report(arguments.task)
    except (OSError, ValueError, KeyError, TypeError) as error:
        status_message = str(error)
        try:
            task_dir = arguments.task.resolve().parent
            atomic_write_json(task_dir / "result.json", {"status": "input_error", "message": str(error)})
        except Exception:
            pass
        logging.error("Input error: %s", error)
        exit_code = EXIT_INPUT
    except Exception as error:
        status_message = str(error)
        logging.error("Internal error: %s\n%s", error, traceback.format_exc())
        try:
            task_dir = arguments.task.resolve().parent
            atomic_write_json(task_dir / "result.json", {"status": "internal_error", "message": str(error)})
        except Exception:
            pass
        exit_code = EXIT_INTERNAL
    finally:
        if arguments.status_file is not None:
            try:
                atomic_write_json(
                    arguments.status_file.resolve(),
                    {
                        "stage": arguments.stage,
                        "exit_code": exit_code,
                        "message": status_message,
                        "pid": os.getpid(),
                    },
                )
            except Exception:
                logging.error("Could not write Python completion status:\n%s", traceback.format_exc())
                if exit_code == EXIT_SUCCESS:
                    exit_code = EXIT_INTERNAL
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
