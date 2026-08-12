#!/usr/bin/env python3
"""Generate a large FEM and run the production FEM Automatic Seam CLI end to end."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List


ROOT = Path(__file__).resolve().parents[2]
GENERATOR = Path(__file__).with_name("generate_fem.py")
BACKEND = ROOT / "modules" / "fem_auto_seam" / "python" / "main.py"
DEFAULT_OUTPUT = ROOT / "runtime" / "tasks" / "fem_auto_seam" / "large_cli_validation"


def write_json(path: Path, payload: Dict[str, object]) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run_checked(arguments: List[str], label: str) -> float:
    started = time.perf_counter()
    process = subprocess.run(arguments, cwd=str(ROOT), text=True, encoding="utf-8")
    elapsed = time.perf_counter() - started
    if process.returncode:
        raise RuntimeError("{} failed with exit code {}".format(label, process.returncode))
    return elapsed


def backend_arguments(task_dir: Path, request: Path, output: Path, tcl_output: Path) -> List[str]:
    return [
        sys.executable, str(BACKEND),
        "--request", str(request),
        "--mesh", str(task_dir / "input" / "model_manifest.json"),
        "--existing", str(task_dir / "input" / "existing.json"),
        "--output", str(output),
        "--tcl-output", str(tcl_output),
        "--log", str(task_dir / "output" / "operation.log"),
    ]


def request_payload(manifest: Dict[str, object], mode: str, workers: int) -> Dict[str, object]:
    components = manifest["components"]
    statistics = manifest["statistics"]
    payload: Dict[str, object] = {
        "schema_version": "1.0",
        "module": "fem_auto_seam",
        "run_id": "FEM_AUTO_SEAM_LARGE_CLI",
        "hypermesh_version": "2019",
        "selected_component_ids": [row["component_id"] for row in components],
        "settings": {
            "mode": mode,
            "search_distance": 12.0,
            "min_seam_length": 20.0,
            "parallel_angle_max": 15.0,
            "perpendicular_angle_min": 70.0,
            "max_distance_variation_ratio": 0.35,
            "near_edge_distance": 8.0,
            "small_hole_diameter": 30.0,
            "max_weld_tria_ratio": 0.75,
            "max_new_failed_elements": 1000,
            "existing_weld_search_distance": 4.0,
            "auto_accept_confidence": 0.88,
            "review_confidence": 0.60,
            "criteria_path": str((ROOT / "modules" / "fem_auto_seam" / "defaults" / "fem_auto_seam_default.criteria").resolve()),
            "remesh_element_size": 8.0,
            "remesh_expand_layers": 2,
            "remesh_feature_angle": 30.0,
            "python_workers": workers,
        },
        "options": {"debug": False, "keep_runtime_files": True},
    }
    if mode == "plan":
        payload["id_state"] = {
            "max_node_id": statistics["nodes"],
            "max_element_id": statistics["elements"],
            "max_property_id": len(components),
            "max_material_id": 1,
            "max_component_id": max(row["component_id"] for row in components),
        }
        payload["entity_registry"] = {"components": {}, "properties": {}, "materials": {}}
    return payload


def run(task_dir: Path, copies: int, workers: int, max_seconds: float) -> Dict[str, object]:
    task_dir = task_dir.resolve()
    input_dir = task_dir / "input"
    output_dir = task_dir / "output"
    input_dir.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir(parents=True, exist_ok=True)
    fem_path = input_dir / "model.fem"
    manifest_path = input_dir / "model_manifest.json"

    generate_seconds = run_checked([
        sys.executable, str(GENERATOR), "--copies", str(copies),
        "--output", str(fem_path), "--manifest", str(manifest_path),
    ], "large FEM generation")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    (input_dir / "existing.json").write_text('{"schema_version":"1.0","seams":[]}\n', encoding="utf-8")

    detect_request = request_payload(manifest, "detect", workers)
    detect_request_path = input_dir / "request_detect.json"
    write_json(detect_request_path, detect_request)
    detect_result_path = output_dir / "detect_result.json"
    detect_seconds = run_checked(
        backend_arguments(task_dir, detect_request_path, detect_result_path, output_dir / "detect_result.tcl"),
        "production detect CLI",
    )
    detect_result = json.loads(detect_result_path.read_text(encoding="utf-8"))
    candidates = detect_result.get("candidates", [])
    accepted = [row["candidate_id"] for row in candidates if row.get("auto_eligible")]
    if not candidates or not accepted:
        raise RuntimeError("detection returned no usable automatic candidates")

    plan_request = request_payload(manifest, "plan", workers)
    plan_request["accepted_candidate_ids"] = accepted
    plan_request_path = input_dir / "request_plan.json"
    write_json(plan_request_path, plan_request)
    plan_result_path = output_dir / "plan_result.json"
    plan_seconds = run_checked(
        backend_arguments(task_dir, plan_request_path, plan_result_path, output_dir / "plan_result.tcl"),
        "production plan CLI",
    )
    plan_result = json.loads(plan_result_path.read_text(encoding="utf-8"))
    summary = plan_result.get("summary", {})
    required_files = (
        output_dir / "backend_result.fem",
        output_dir / "backend_result_manifest.json",
        output_dir / "creation_plan.json",
        output_dir / "remesh_plan.json",
        output_dir / "transfer_manifest.json",
    )
    missing = [str(path) for path in required_files if not path.is_file() or path.stat().st_size == 0]
    if missing:
        raise RuntimeError("plan CLI did not create required artifacts: {}".format(", ".join(missing)))
    if int(summary.get("ready_count", 0)) < 1:
        raise RuntimeError("plan CLI produced no READY creation plans")
    if not plan_result.get("performance", {}).get("candidate_cache_hit"):
        raise RuntimeError("plan CLI did not reuse the detect candidate cache")

    backend_seconds = detect_seconds + plan_seconds
    status = "PASS" if max_seconds <= 0 or backend_seconds <= max_seconds else "FAIL"
    report: Dict[str, object] = {
        "schema_version": "1.0",
        "status": status,
        "copies": copies,
        "workers_requested": workers,
        "statistics": manifest["statistics"],
        "candidate_count": len(candidates),
        "accepted_candidate_count": len(accepted),
        "ready_plan_count": summary.get("ready_count", 0),
        "created_weld_element_count": summary.get("created_weld_element_count", 0),
        "candidate_cache_hit": True,
        "timing_seconds": {
            "generation": round(generate_seconds, 6),
            "detect_cli": round(detect_seconds, 6),
            "plan_cli": round(plan_seconds, 6),
            "backend_total": round(backend_seconds, 6),
        },
        "performance_limit_seconds": max_seconds,
        "artifacts": {"input_fem": str(fem_path), "task_dir": str(task_dir)},
    }
    if status != "PASS":
        report["error"] = "backend runtime {:.3f}s exceeded {:.3f}s".format(backend_seconds, max_seconds)
    write_json(task_dir / "validation_report.json", report)
    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--copies", type=int, default=100, help="10-case matrix copies; default creates about 40k shell elements")
    parser.add_argument("--workers", type=int, default=0, help="Python detection workers; 0 selects automatically")
    parser.add_argument("--max-seconds", type=float, default=120.0, help="detect+plan performance gate; <=0 disables it")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.copies < 1 or args.workers < 0:
        raise ValueError("--copies must be positive and --workers must not be negative")
    report = run(args.output, args.copies, args.workers, args.max_seconds)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
