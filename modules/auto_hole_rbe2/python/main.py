"""CLI entry for solid through-hole recognition."""
from __future__ import annotations

import argparse
import importlib.util
import sys
import time
from collections import Counter
from pathlib import Path

MODULE_DIR = Path(__file__).resolve().parent
COMMON_DIR = MODULE_DIR.parents[1] / "hybrid_core" / "python"
for directory in (str(MODULE_DIR), str(COMMON_DIR)):
    if directory not in sys.path:
        sys.path.insert(0, directory)

try:
    from .duplicate_detector import annotate, build_index
    from .face_segmentation import segment_faces
    from .hole_evaluator import evaluate
    from .result_validator import validate
    from .solid_surface import extract
    from hmworkflow.core.fem_delta import write_rigid_incremental_fem
    from hmworkflow.core.logging_utils import close_logger, create_logger
    from hmworkflow.core.mesh_model import load_json, read_mesh
    from hmworkflow.core.result_writer import write_result
    from hmworkflow.core.hybrid_schema import new_result
except ImportError:  # Standalone HM2019 entry compatibility.
    from duplicate_detector import annotate, build_index
    from fem_delta import write_rigid_incremental_fem
    from face_segmentation import segment_faces
    from hole_evaluator import evaluate
    from logging_utils import close_logger, create_logger
    from mesh_model import load_json, read_mesh
    from result_validator import validate
    from result_writer import write_result
    from hybrid_schema import new_result
    from solid_surface import extract

SPEC = importlib.util.spec_from_file_location("auto_hole_schema", str(MODULE_DIR / "schema.py"))
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load auto_hole_rbe2 schema")
AUTO_SCHEMA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTO_SCHEMA)
validate_existing = AUTO_SCHEMA.validate_existing
validate_request = AUTO_SCHEMA.validate_request

MAX_REJECT_SAMPLES = 100
MAX_REJECT_FACE_IDS = 50


def detect(request, model, existing, logger):
    settings = request["settings"]
    faces, warnings = extract(model, request["selected_component_ids"], settings["eps"])
    segments, _ = segment_faces(faces, settings["featureAngleDeg"])
    faces_by_id = {face.face_id: face for face in faces}
    candidates, rejected_samples = [], []
    rejected_count = 0
    reject_reason_counts = Counter()
    duplicate_index = build_index(existing)

    def record_rejection(segment, reason):
        nonlocal rejected_count
        rejected_count += 1
        reject_reason_counts[reason] += 1
        if len(rejected_samples) < MAX_REJECT_SAMPLES:
            rejected_samples.append({
                "segment_face_ids": list(segment[:MAX_REJECT_FACE_IDS]),
                "segment_face_count": len(segment),
                "reject_reasons": [reason],
            })

    for segment in segments:
        try:
            candidate, reason = evaluate(model, segment, faces_by_id, settings)
        except Exception as exc:
            logger.exception("segment evaluation failed face_count=%d sample=%s", len(segment), segment[:10])
            record_rejection(segment, "ERROR:{}".format(exc))
            continue
        if candidate is None:
            record_rejection(segment, reason)
            continue
        candidate["candidate_id"] = "H{:04d}".format(len(candidates) + 1)
        component_ids = sorted({model.elements[faces_by_id[face_id].element_id].component_id for face_id in segment})
        candidate["component_id"] = component_ids[0] if len(component_ids) == 1 else 0
        annotate(candidate, duplicate_index)
        candidates.append(candidate)
    validate(candidates, model)
    rejection_summary = {
        "count": rejected_count,
        "samples": rejected_samples,
        "reason_counts": dict(sorted(reject_reason_counts.items())),
    }
    return faces, segments, candidates, rejection_summary, warnings


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True, type=Path)
    parser.add_argument("--mesh", required=True, type=Path)
    parser.add_argument("--existing", required=True, type=Path)
    parser.add_argument("--delta", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tcl-output", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    args = parser.parse_args(argv)
    logger = create_logger("auto_hole_rbe2", args.log)
    try:
        read_started = time.perf_counter()
        request = validate_request(load_json(args.request))
        model = read_mesh(args.mesh)
        existing = validate_existing(load_json(args.existing))
        read_seconds = time.perf_counter() - read_started
        detect_started = time.perf_counter()
        faces, segments, candidates, rejection_summary, warnings = detect(request, model, existing, logger)
        detect_seconds = time.perf_counter() - detect_started
        result = new_result("auto_hole_rbe2", request["run_id"])
        result["summary"] = {
            "exterior_face_count": len(faces),
            "segment_count": len(segments),
            "candidate_count": len(candidates),
            "create_count": sum(row["recommended_action"] == "CREATE" for row in candidates),
            "existing_count": sum(row["recommended_action"] == "SKIP_EXISTING" for row in candidates),
            "rejected_count": rejection_summary["count"],
            "reject_reason_counts": rejection_summary["reason_counts"],
            "rejected": rejection_summary["samples"],
        }
        result["candidates"] = candidates
        result["warnings"] = warnings
        result["performance"]["read_seconds"] = round(read_seconds, 6)
        result["performance"]["detect_seconds"] = round(detect_seconds, 6)
        write_started = time.perf_counter()
        manifest = write_rigid_incremental_fem(args.delta, candidates, request)
        result["summary"].update(manifest)
        write_seconds = time.perf_counter() - write_started
        result["performance"]["write_seconds"] = round(write_seconds, 6)
        write_result(args.output, args.tcl_output, "::AutoHoleRBE2::pythonResult", result)
        logger.info(
            "complete candidates=%d rejected=%d write_seconds=%.6f",
            len(candidates), rejection_summary["count"], write_seconds,
        )
        return 0
    except Exception as exc:
        logger.exception("auto_hole_rbe2 failed")
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 2
    finally:
        close_logger(logger)


if __name__ == "__main__":
    raise SystemExit(main())
