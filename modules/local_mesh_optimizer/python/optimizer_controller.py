#!/usr/bin/env python3
"""File-protocol controller for Local Mesh Optimizer."""

from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
import traceback
from pathlib import Path
from typing import Dict, Optional, Sequence

# The Windows embeddable distribution uses a restrictive pythonXY._pth file.
# Add the controller directory explicitly so sibling modules remain importable
# without enabling site-packages or installing anything on the user machine.
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from adjacency import read_connectivity
from criteria_parser import parse_criteria_metadata
from io_utils import atomic_write_json, atomic_write_text, read_id_file, read_json
from optimization_planner import plan_optimization_actions
from region_builder import build_regions, feature_edges, read_blocked_edges, read_node_coordinates
from report_generator import generate_report

EXIT_SUCCESS = 0
EXIT_PARTIAL = 1
EXIT_CANCELLED = 2
EXIT_INPUT = 3
EXIT_HYPERMESH = 4
EXIT_INTERNAL = 5


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


def build(task_path: Path) -> int:
    task_path = task_path.resolve()
    task_dir = task_path.parent
    _configure_logging(task_dir)
    task = read_json(task_path)
    _progress(task_dir, "validating", 5.0, "正在验证区域构建输入")
    criteria = Path(str(task.get("criteria_path", "")))
    if not criteria.is_absolute():
        criteria = (task_dir / criteria).resolve()
    metadata = parse_criteria_metadata(criteria)
    atomic_write_json(task_dir / "criteria_metadata.json", metadata)
    if (task_dir / "cancel.flag").exists():
        _progress(task_dir, "cancelled", 100.0, "用户已取消")
        return EXIT_CANCELLED
    elements = read_connectivity(_path(task_dir, task, "connectivity_file", "element_connectivity.csv"))
    failed = read_id_file(_path(task_dir, task, "failed_elements_file", "failed_elements.txt"))
    if not failed:
        atomic_write_json(task_dir / "regions.json", [])
        _progress(task_dir, "ready", 100.0, "没有失败单元")
        return EXIT_SUCCESS
    _progress(task_dir, "building_regions", 35.0, "正在按共享边划分失败区域")
    blocked_edges = read_blocked_edges(_path(task_dir, task, "protected_edges_file", "protected_edges.csv"))
    coordinates = read_node_coordinates(_path(task_dir, task, "node_coordinates_file", "node_coordinates.csv"))
    user_anchor_nodes = set(read_id_file(_path(task_dir, task, "protected_nodes_file", "protected_nodes.txt")))
    protect_features = bool(task.get("protection", {}).get("feature_edges", True))
    if protect_features:
        blocked_edges.update(feature_edges(elements, coordinates, float(task.get("feature_angle", 30.0))))
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
    actions = plan_optimization_actions(
        elements=elements,
        failed_ids=failed,
        coordinates=coordinates,
        regions=regions,
        blocked_edges=blocked_edges,
        user_anchor_nodes=user_anchor_nodes,
        allow_free_edge_move=(
            bool(task.get("allow_controlled_free_edge_move", True))
            and str(task.get("optimization_level", "standard")) != "quick"
            and not bool(task.get("protection", {}).get("preserve_geometry_association", True))
        ),
        skinny_triangle_ratio=float(task.get("skinny_triangle_ratio", 2.5)),
        narrow_quad_ratio=float(task.get("narrow_quad_ratio", 2.5)),
        narrow_target_aspect=float(task.get("narrow_target_aspect", 1.5)),
    )
    actions_by_region: Dict[str, list] = {}
    for action in actions:
        actions_by_region.setdefault(str(action["region_id"]), []).append(action)
    for region in regions:
        region_actions = actions_by_region.get(str(region["region_id"]), [])
        region["planned_actions"] = region_actions
        region["manual_review_count"] = sum(
            1 for action in region_actions if action["action_type"] == "manual_review"
        )
        controlled_nodes = {
            int(node)
            for action in region_actions
            if action["action_type"] == "expand_free_edge"
            for node in (action["node_a"], action["node_b"])
        }
        region["anchor_nodes"] = sorted(
            set(region["anchor_nodes"]).difference(controlled_nodes.difference(user_anchor_nodes))
        )
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
    generate_report(report_dir, task, result, regions)
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
    generate_report(report_dir, task, result, regions)
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
