"""Run repeatable, blank-model HyperMesh 2019 integration smoke tests."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_HMBATCH = Path(r"C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe")
BASE_CASES = (
    "modules/hybrid_core/tests/hm_platform_services_smoke.tcl",
    "modules/hybrid_core/tests/hm_hybrid_export_smoke.tcl",
    "modules/quick_selector/tests/hm2019_api_probe.tcl",
    "modules/batch_mesher/tests/hm2019_api_smoke.tcl",
    "modules/mesh_seam_weld/tests/hm2019_shared_node_imprint_smoke.tcl",
    "modules/fem_auto_seam/tests/hm2019_module_smoke.tcl",
    "modules/contact_setup/tests/hm2019_contact_surface_smoke.tcl",
)
PERFORMANCE_CASE = "modules/contact_setup/tests/hm2019_contact_performance_smoke.tcl"


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--hmbatch",
        type=Path,
        default=Path(os.environ.get("HMWORKFLOW_HMBATCH", str(DEFAULT_HMBATCH))),
    )
    parser.add_argument("--include-performance", action="store_true")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    hmbatch = args.hmbatch.resolve()
    if not hmbatch.is_file():
        raise SystemExit(f"HyperMesh 2019 hmbatch not found: {hmbatch}")

    cases: List[str] = list(BASE_CASES)
    if args.include_performance:
        cases.append(PERFORMANCE_CASE)
    results: List[Dict[str, object]] = []
    started = time.time()
    for relative in cases:
        script = (ROOT / relative).resolve()
        case_started = time.time()
        completed = subprocess.run(
            [str(hmbatch), "-tcl", str(script)],
            cwd=str(ROOT),
            text=True,
            capture_output=True,
        )
        results.append(
            {
                "case": relative,
                "status": "PASS" if completed.returncode == 0 else "FAIL",
                "returncode": completed.returncode,
                "duration_seconds": round(time.time() - case_started, 3),
                "stdout_tail": completed.stdout[-4000:],
                "stderr_tail": completed.stderr[-4000:],
            }
        )
        print(f"{results[-1]['status']} {relative} ({results[-1]['duration_seconds']}s)")

    report = {
        "schema_version": "1.0",
        "hypermesh": str(hmbatch),
        "started_utc_epoch": started,
        "duration_seconds": round(time.time() - started, 3),
        "status": "PASS" if all(item["status"] == "PASS" for item in results) else "FAIL",
        "cases": results,
    }
    report_path = ROOT / "runtime" / "hm2019_matrix_report.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Report: {report_path}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
