#!/usr/bin/env python3
"""Offline smoke test for the bundled Local Mesh Optimizer Python runtime."""

from __future__ import annotations

import csv
import dataclasses
import html
import json
import logging
import os
import pathlib
import sys
import tempfile

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from adjacency import ShellElement
from optimization_planner import plan_optimization_actions
from region_builder import build_regions
from report_generator import generate_report


def main() -> int:
    elements = {
        1: ShellElement(1, 10, (1, 2, 5, 4)),
        2: ShellElement(2, 10, (2, 3, 6, 5)),
    }
    regions = build_regions(elements, [1], layers=1, max_region_elements=20)
    if len(regions) != 1 or regions[0]["expanded_elements"] != [1, 2]:
        raise RuntimeError("Region smoke test returned unexpected data")
    coordinates = {
        1: (0.0, 0.0, 0.0), 2: (1.0, 0.0, 0.0), 5: (1.0, 1.0, 0.0),
        4: (0.0, 1.0, 0.0), 3: (2.0, 0.0, 0.0), 6: (2.0, 1.0, 0.0),
    }
    actions = plan_optimization_actions(elements, [1], coordinates, regions)
    if len(actions) != 1 or actions[0]["action_type"] != "split_quad":
        raise RuntimeError("Optimization planner smoke test returned unexpected data")

    with tempfile.TemporaryDirectory(prefix="hmworkflow_python_test_") as directory:
        report_dir = pathlib.Path(directory) / "report"
        generate_report(
            report_dir,
            {"model_path": "portable_test.hm", "criteria_path": "test.criteria", "scope_type": "elements"},
            {"checked_elements": 2, "failed_before": 1, "failed_after": 1},
            regions,
        )
        for name in ("summary.html", "summary.csv", "regions.csv", "settings.json"):
            if not (report_dir / name).is_file():
                raise RuntimeError("Report smoke test did not create {}".format(name))

    print("HMWorkFlow bundled Python self-test passed: {}".format(sys.version.split()[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
