from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
import time
from pathlib import Path

MODULE_DIR = Path(__file__).resolve().parent
REPO_PYTHON_DIR = MODULE_DIR.parents[2] / "python"
COMMON_DIR = MODULE_DIR.parents[1] / "hybrid_core" / "python"
MESH_SEAM_SHARED_DIR = MODULE_DIR.parents[1] / "mesh_seam_weld" / "python"
for directory in reversed((REPO_PYTHON_DIR, MODULE_DIR, COMMON_DIR, MESH_SEAM_SHARED_DIR)):
    text = str(directory)
    while text in sys.path:
        sys.path.remove(text)
    sys.path.insert(0, text)

try:
    from .backend import detect_candidates, plan_candidate_deltas, write_fem_bundle
    from .delta_writer import write_manifest, write_plan_delta_files, write_shell_weld_delta
    from .schema import validate_request
except ImportError:
    # persistent_worker loads this entry under a private module name.  Import
    # through the public package namespace so module-local schema.py files from
    # previously executed tools cannot shadow hybrid_core dependencies.
    from hmworkflow.fem_auto_seam.backend import detect_candidates, plan_candidate_deltas, write_fem_bundle
    from hmworkflow.fem_auto_seam.delta_writer import write_manifest, write_plan_delta_files, write_shell_weld_delta
    from hmworkflow.fem_auto_seam.schema import validate_request

try:
    from hmworkflow.core.hybrid_schema import new_result
    from hmworkflow.core.logging_utils import close_logger, create_logger
    from hmworkflow.core.mesh_model import load_json
    from hmworkflow.core.result_writer import write_result
    from hmworkflow.mesh_seam_weld.fem_mesh_reader import read_shell_fem_bundle
except ImportError:
    from hybrid_schema import new_result
    from logging_utils import close_logger, create_logger
    from mesh_model import load_json
    from result_writer import write_result
    from fem_mesh_reader import read_shell_fem_bundle


def _backend_settings(settings, request=None):
    result = dict(settings)
    result.update({
        "minimum_t_length": float(settings["min_seam_length"]),
        "minimum_patch_length": float(settings["min_seam_length"]),
        "minimum_t_normal_angle": max(0.0, 90.0 - float(settings["perpendicular_angle_min"])),
        "maximum_patch_normal_angle": float(settings["parallel_angle_max"]),
        "maximum_distance_variation_ratio": float(settings["max_distance_variation_ratio"]),
        "near_edge_distance": float(settings["near_edge_distance"]),
        "small_hole_diameter": float(settings["small_hole_diameter"]),
        "maximum_weld_triangle_ratio": float(settings["max_weld_tria_ratio"]),
    })
    if request is not None:
        result["id_state"] = dict(request.get("id_state", {}))
    return result


def _mark_duplicates(candidates, model, existing, maximum):
    centers = [tuple(float(value) for value in row.get("center", ())) for row in existing if len(row.get("center", ())) >= 3]
    if not centers:
        return candidates
    for row in candidates:
        points = [tuple(float(value) for value in point) for point in row.get("target_projection_points", [])]
        if not points:
            points = [model.nodes[node_id] for node_id in row.get("source_node_ids", []) if node_id in model.nodes]
        if not points:
            continue
        midpoint = tuple(sum(point[axis] for point in points) / len(points) for axis in range(3))
        distance = min(math.sqrt(sum((midpoint[axis] - center[axis]) ** 2 for axis in range(3))) for center in centers)
        if distance <= float(maximum):
            row["duplicate_status"] = "POSSIBLE_DUPLICATE"
            row["auto_eligible"] = False
            row["status"] = "REVIEW_REQUIRED"
            row.setdefault("warnings", []).append("existing SEAM element is within {:.6g} of the candidate midpoint".format(distance))
    return candidates


def calculate(request, model, existing):
    settings = request["settings"]
    candidates = detect_candidates(model, _backend_settings(settings, request))
    candidates = _mark_duplicates(candidates, model, existing.get("seams", []), settings["existing_weld_search_distance"])
    if settings["mode"] == "detect":
        return {"candidates": candidates}
    accepted = set(str(value) for value in request.get("accepted_candidate_ids", []))
    selected = [row for row in candidates if row["candidate_id"] in accepted]
    planned = plan_candidate_deltas(
        model, selected, _backend_settings(settings, request),
        settings.get("criteria_path") or None, settings.get("param_path") or None,
    )
    planned["detected_candidates"] = candidates
    return planned


def _artifact(path, root):
    path = Path(path).resolve()
    root = Path(root).resolve()
    return {
        "path": str(path),
        "relative_path": str(path.relative_to(root)).replace("\\", "/"),
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def _write_transfer_manifest(path, request, artifacts, plans):
    payload = {
        "schema_version": "1.0",
        "module": "fem_auto_seam",
        "run_id": request["run_id"],
        "status": "READY_FOR_HYPERMESH_IMPORT",
        "artifacts": artifacts,
        "candidates": [
            {
                key: row[key]
                for key in (
                    "candidate_id", "candidate_type", "confidence", "auto_eligible",
                    "source_component_id", "target_component_id", "source_node_ids",
                    "target_node_ids", "length", "status", "delta_fem",
                    "output_component_id", "output_component_name",
                    "delete_element_ids", "read_elements", "write_nodes",
                )
                if key in row
            }
            for row in plans
        ],
    }
    Path(path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return payload


def main(argv=None):
    parser = argparse.ArgumentParser()
    for name in ("request", "mesh", "existing", "output", "tcl-output", "log"):
        parser.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args(argv)
    logger = create_logger("fem_auto_seam", args.log)
    try:
        started = time.perf_counter()
        request = validate_request(load_json(args.request))
        model = read_shell_fem_bundle(args.mesh)
        existing = load_json(args.existing)
        calculated = calculate(request, model, existing)
        result = new_result("fem_auto_seam", request["run_id"])
        if request["settings"]["mode"] == "detect":
            result["candidates"] = calculated["candidates"]
            result["summary"] = {"mode": "detect", "candidate_count": len(result["candidates"])}
            (args.output.parent / "candidates.json").write_text(json.dumps(calculated, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        else:
            plans = calculated["plans"]
            ready = [row for row in plans if row["status"] == "READY"]
            result["candidates"] = plans
            result["summary"] = {
                "mode": "plan",
                "candidate_count": len(plans),
                "ready_count": len(ready),
                "created_weld_element_count": sum(len(row["weld_elements"]) for row in ready),
                "replaced_mother_element_count": sum(len(row["replacement_elements"]) for row in ready),
                "moved_node_count": sum(len(row["move_nodes"]) for row in ready),
            }
            manifest = write_shell_weld_delta(args.output.parent / "delta.fem", plans, request)
            delta_files = write_plan_delta_files(args.output.parent / "deltas", plans)
            for row in manifest["plans"]:
                row["delta_fem"] = delta_files[row["candidate_id"]]
            write_manifest(args.output.parent / "delta_manifest.json", manifest)
            (args.output.parent / "creation_plan.json").write_text(json.dumps({key: value for key, value in calculated.items() if key != "result_model"}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            (args.output.parent / "optimization_report.json").write_text(json.dumps(calculated["optimization"], ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            backend_manifest = write_fem_bundle(
                calculated["result_model"],
                args.output.parent / "backend_result.fem",
                args.output.parent / "backend_result_manifest.json",
            )
            artifact_paths = {
                "backend_result_fem": args.output.parent / "backend_result.fem",
                "backend_result_manifest": backend_manifest,
                "combined_delta_fem": args.output.parent / "delta.fem",
                "delta_manifest": args.output.parent / "delta_manifest.json",
                "creation_plan": args.output.parent / "creation_plan.json",
                "optimization_report": args.output.parent / "optimization_report.json",
            }
            artifacts = {name: _artifact(path, args.output.parent) for name, path in artifact_paths.items()}
            transfer_path = args.output.parent / "transfer_manifest.json"
            _write_transfer_manifest(transfer_path, request, artifacts, plans)
            artifacts["transfer_manifest"] = _artifact(transfer_path, args.output.parent)
            result["artifacts"] = artifacts
            result["transfer"] = {
                "status": "READY_FOR_HYPERMESH_IMPORT",
                "manifest": str(transfer_path.resolve()),
                "candidate_count": len(plans),
                "ready_count": len(ready),
            }
        result["performance"]["total_seconds"] = round(time.perf_counter() - started, 6)
        write_result(args.output, args.tcl_output, "::FemAutoSeam::pythonResult", result)
        return 0
    except Exception as exc:
        logger.exception("FEM automatic seam failed")
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 2
    finally:
        close_logger(logger)


if __name__ == "__main__":
    raise SystemExit(main())
