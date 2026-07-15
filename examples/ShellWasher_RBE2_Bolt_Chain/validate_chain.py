#!/usr/bin/env python3
"""Run the repository's washer and bolt analyzers against the generated model."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
COMMON = ROOT / "modules" / "hybrid_core" / "python"
WASHER = ROOT / "modules" / "shell_washer_hole_rbe2" / "python"
BOLT = ROOT / "modules" / "rbe2_bolt_connector" / "python"
for directory in (str(BOLT), str(WASHER), str(COMMON), str(HERE)):
    if directory not in sys.path:
        sys.path.insert(0, directory)

from generate_fem import PLANE_Z, PLATE_COLUMNS, PLATE_ROWS, build_model  # noqa: E402
from free_edge_loops import find  # noqa: E402
from grouping import build as build_bolt_groups  # noqa: E402
from loop_geometry import calculate  # noqa: E402
from mesh_model import Component, Element, MeshModel  # noqa: E402
from pair_planner import plan as plan_bolts  # noqa: E402
from rbe2_analyzer import analyze as analyze_rbe2  # noqa: E402
from shell_topology import build as build_shell_topology  # noqa: E402
from washer_detector import validate_hole, validate_washer  # noqa: E402


def load_defaults(path: Path, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, str(path))
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return dict(module.DEFAULTS)


def run_once(washer_settings, bolt_settings):
    started = time.perf_counter()
    source = build_model()
    components = {
        component.component_id: Component(component.component_id, component.name, "SHELL")
        for component in source.components.values()
    }
    elements = {
        element.element_id: Element(element.element_id, element.property_id, element.card, element.node_ids)
        for element in source.elements.values()
    }
    shell_model = MeshModel(components, dict(source.nodes), elements)
    build_seconds = time.perf_counter() - started

    started = time.perf_counter()
    accepted = []
    for component_id in sorted(components):
        selected = shell_model.elements_for_components([component_id])
        incidence, neighbors, element_nodes = build_shell_topology(selected)
        for loop in find(incidence):
            geometry, reason = validate_hole(shell_model, loop, washer_settings)
            if geometry is None:
                continue
            washer, reason = validate_washer(shell_model, loop, geometry, incidence, neighbors, element_nodes, washer_settings)
            if washer is not None:
                accepted.append((component_id, geometry, washer))
    washer_seconds = time.perf_counter() - started

    rigid_nodes = dict(shell_model.nodes)
    rigid_elements = {}
    next_node_id = max(rigid_nodes) + 1
    for index, (_, geometry, washer) in enumerate(accepted, 1):
        center_node_id = next_node_id
        next_node_id += 1
        rigid_nodes[center_node_id] = tuple(geometry["center"])
        rigid_elements[index] = Element(index, 900, "RBE2", tuple([center_node_id] + washer["dependent_node_ids"]))
    rigid_model = MeshModel({900: Component(900, "EXPECTED_WASHER_RBE2", "RIGID")}, rigid_nodes, rigid_elements)

    started = time.perf_counter()
    records, rejected_rbe2 = analyze_rbe2(rigid_model, bolt_settings)
    groups = build_bolt_groups(records, bolt_settings)
    bolts, rejected_pairs = plan_bolts(groups, bolt_settings)
    bolt_seconds = time.perf_counter() - started

    summary = {
        "accepted_washer_holes": len(accepted),
        "analyzed_rbe2": len(records),
        "rejected_rbe2": len(rejected_rbe2),
        "coaxial_groups": len(groups),
        "planned_adjacent_bolts": len(bolts),
        "rejected_bolt_pairs": len(rejected_pairs),
        "bolt_lengths": sorted({round(item["axial_distance"], 6) for item in bolts}),
    }
    hole_count = len(PLANE_Z) * PLATE_ROWS * PLATE_COLUMNS
    stack_count = PLATE_ROWS * PLATE_COLUMNS
    expected = {
        "accepted_washer_holes": hole_count,
        "analyzed_rbe2": hole_count,
        "rejected_rbe2": 0,
        "coaxial_groups": stack_count,
        "planned_adjacent_bolts": stack_count * (len(PLANE_Z) - 1),
        "rejected_bolt_pairs": 0,
        "bolt_lengths": [20.0],
    }
    if summary != expected:
        raise ValueError("chain validation mismatch: {} != {}".format(summary, expected))
    timings = {
        "build_model_seconds": round(build_seconds, 6),
        "washer_detection_seconds": round(washer_seconds, 6),
        "bolt_planning_seconds": round(bolt_seconds, 6),
        "total_seconds": round(build_seconds + washer_seconds + bolt_seconds, 6),
    }
    return summary, timings


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeat", type=int, default=1, help="repeat the complete pure-data chain and verify identical results")
    parser.add_argument("--output", type=Path, default=HERE / "ShellWasher_RBE2_Bolt_Chain_benchmark.json")
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be at least 1")
    return args


def main() -> int:
    args = parse_args()
    washer_settings = load_defaults(WASHER / "schema.py", "chain_washer_schema")
    bolt_settings = load_defaults(BOLT / "schema.py", "chain_bolt_schema")
    summaries = []
    timings = []
    for _ in range(args.repeat):
        summary, timing = run_once(washer_settings, bolt_settings)
        summaries.append(summary)
        timings.append(timing)
    if any(summary != summaries[0] for summary in summaries[1:]):
        raise ValueError("stability failure: repeated runs produced different summaries")
    totals = [item["total_seconds"] for item in timings]
    output = {
        "repeat_count": args.repeat,
        "stable_identical_results": True,
        "result": summaries[0],
        "timings": timings,
        "total_seconds_summary": {
            "minimum": round(min(totals), 6),
            "mean": round(sum(totals) / len(totals), 6),
            "maximum": round(max(totals), 6),
        },
    }
    args.output.resolve().write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    output["benchmark_file"] = str(args.output.resolve())
    print(json.dumps(output, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
