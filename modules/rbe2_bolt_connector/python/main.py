from __future__ import annotations

import argparse
import importlib.util
import sys
import time
from pathlib import Path


MODULE_DIR = Path(__file__).resolve().parent
COMMON_DIR = MODULE_DIR.parents[1] / "hybrid_core" / "python"
for directory in (str(MODULE_DIR), str(COMMON_DIR)):
    if directory not in sys.path:
        sys.path.insert(0, directory)

try:
    from .duplicate_detector import annotate
    from .fem_io import read_fem
    from .grouping import build
    from .incremental_fem import write_incremental_fem
    from .pair_planner import plan
    from .rbe2_analyzer import analyze
    from .result_validator import validate
    from hmworkflow.core.hybrid_schema import new_result
    from hmworkflow.core.logging_utils import close_logger, create_logger
    from hmworkflow.core.mesh_model import load_json
    from hmworkflow.core.result_writer import write_result
except ImportError:  # Standalone HM2019 entry compatibility.
    from duplicate_detector import annotate
    from fem_io import read_fem
    from grouping import build
    from hybrid_schema import new_result
    from incremental_fem import write_incremental_fem
    from logging_utils import close_logger, create_logger
    from mesh_model import load_json
    from pair_planner import plan
    from rbe2_analyzer import analyze
    from result_validator import validate
    from result_writer import write_result


SPEC = importlib.util.spec_from_file_location("bolt_schema", str(MODULE_DIR / "schema.py"))
SCHEMA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCHEMA)


def calculate(request, model, existing):
    records, rejected = analyze(model, request["settings"])
    groups = build(records, request["settings"])
    plans, group_rejected = plan(groups, request["settings"])
    annotate(plans, existing)
    validate(plans, model)
    used = {plan["rbe2_a"]["element_id"] for plan in plans} | {
        plan["rbe2_b"]["element_id"] for plan in plans
    }
    unused = [
        record["element_id"]
        for record in records
        if record["planar"] and record["element_id"] not in used
    ]
    return records, groups, plans, rejected + group_rejected, unused


def _arguments(argv=None):
    parser = argparse.ArgumentParser()
    for name in ("request", "mesh", "delta", "output", "tcl-output", "log"):
        parser.add_argument("--" + name, required=True, type=Path)
    return parser.parse_args(argv)


def main(argv=None):
    arguments = _arguments(argv)
    logger = create_logger("rbe2_bolt_connector", arguments.log)
    try:
        started = time.perf_counter()
        request = SCHEMA.validate_request(load_json(arguments.request))
        snapshot = read_fem(arguments.mesh)
        read_seconds = time.perf_counter() - started

        started = time.perf_counter()
        records, groups, plans, rejected, unused = calculate(
            request, snapshot.model, snapshot.existing_segments
        )
        detect_seconds = time.perf_counter() - started

        started = time.perf_counter()
        manifest = write_incremental_fem(arguments.delta, plans, request)
        write_seconds = time.perf_counter() - started

        result = new_result("rbe2_bolt_connector", request["run_id"])
        result["candidates"] = plans
        result["summary"] = {
            "record_count": len(records),
            "group_count": len(groups),
            "pair_count": len(plans),
            "create_count": len(manifest["created_element_ids"]),
            "unused_shell_rbe2_ids": unused,
            "rejected": rejected,
            **manifest,
        }
        result["performance"]["read_seconds"] = round(read_seconds, 6)
        result["performance"]["detect_seconds"] = round(detect_seconds, 6)
        result["performance"]["write_seconds"] = round(write_seconds, 6)
        write_result(
            arguments.output,
            getattr(arguments, "tcl_output"),
            "::RB2Bolt::pythonResult",
            result,
        )
        return 0
    except Exception as exc:
        logger.exception("bolt FEM planning failed")
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 2
    finally:
        close_logger(logger)


if __name__ == "__main__":
    raise SystemExit(main())
