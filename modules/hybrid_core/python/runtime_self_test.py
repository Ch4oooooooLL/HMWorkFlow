"""Offline self-test for the bundled Python 3.8 hybrid runtime."""
from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

MODULE_DIR = Path(__file__).resolve().parent
if str(MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(MODULE_DIR))

from edge_graph import EdgeGraph
from geometry import centroid, point_line_distance
from result_writer import write_result
from schema import new_result, validate_request


def run(output_dir: Path) -> None:
    request = {
        "schema_version": "1.0",
        "module": "hybrid_core_self_test",
        "run_id": "SELF_TEST",
        "hypermesh_version": "offline",
        "selected_component_ids": [],
        "settings": {},
        "options": {"debug": False, "keep_runtime_files": True},
    }
    validate_request(request, "hybrid_core_self_test")
    if centroid([(0, 0, 0), (2, 2, 2)]) != (1.0, 1.0, 1.0):
        raise RuntimeError("geometry centroid self-test failed")
    if abs(point_line_distance((1, 2, 0), (0, 0, 0), (1, 0, 0)) - 2.0) > 1.0e-9:
        raise RuntimeError("point-line distance self-test failed")
    paths = EdgeGraph([(3, 1), (1, 2), (2, 3)]).ordered_paths()
    if paths != [{"nodes": [1, 2, 3], "closed": True, "branched": False}]:
        raise RuntimeError("edge graph self-test failed: {!r}".format(paths))
    result = new_result("hybrid_core_self_test", "SELF_TEST")
    result["summary"] = {"checks": 3}
    result["candidates"] = [
        {"candidate_id": "SELF0001", "text": "中文 $ [safe] {value}", "node_ids": [1, 2]}
    ]
    write_result(
        output_dir / "result.json",
        output_dir / "result.tcl",
        "::HybridCore::selfTestResult",
        result,
    )


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.output_dir:
            args.output_dir.mkdir(parents=True, exist_ok=True)
            run(args.output_dir)
        else:
            with tempfile.TemporaryDirectory(prefix="hw_hybrid_core_") as directory:
                run(Path(directory))
        print("Hybrid core self-test passed: Python {}".format(sys.version.split()[0]))
        return 0
    except Exception as exc:
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
