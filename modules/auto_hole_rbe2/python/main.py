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
    from .surface_fem_reader import read_surface_fem_bundle
    from hmworkflow.core.logging_utils import close_logger, create_logger
    from hmworkflow.core.mesh_model import load_json, read_mesh
    from hmworkflow.core.result_writer import write_result
    from hmworkflow.core.hybrid_schema import new_result
except ImportError:  # Standalone HM2019 entry compatibility.
    from duplicate_detector import annotate, build_index
    from face_segmentation import segment_faces
    from hole_evaluator import evaluate
    from logging_utils import close_logger, create_logger
    from mesh_model import load_json, read_mesh
    from result_validator import validate
    from result_writer import write_result
    from hybrid_schema import new_result
    from solid_surface import extract
    from surface_fem_reader import read_surface_fem_bundle

SPEC = importlib.util.spec_from_file_location("auto_hole_schema", str(MODULE_DIR / "schema.py"))
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load auto_hole_rbe2 schema")
AUTO_SCHEMA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTO_SCHEMA)
validate_existing = AUTO_SCHEMA.validate_existing
validate_request = AUTO_SCHEMA.validate_request

MAX_REJECT_SAMPLES = 100
MAX_REJECT_FACE_IDS = 50


def _refinement_angles(feature_angle):
    """Scan densely enough to retain narrow mesh-dependent separation windows."""
    minimum_angle = 8.0
    step = 2.0
    values = []
    angle = feature_angle - step
    while angle >= minimum_angle:
        values.append(round(angle, 6))
        angle -= step
    if not values or values[-1] > minimum_angle:
        values.append(minimum_angle)
    return values


def _can_refine(reason):
    return reason.startswith("BOUNDARY_LOOP_COUNT:") or reason in {
        "INVALID_LOOP_NORMAL",
        "LOOP_NORMAL_MISMATCH",
        "LOOP_RADIUS_MISMATCH",
        "CYLINDER_FIT",
    }


def read_analysis_mesh(path):
    if path.suffix.lower() == ".json":
        header = load_json(path)
        if header.get("format") == "hm_surface_faces_fem":
            return read_surface_fem_bundle(path)
    return read_mesh(path)


def _evaluate_with_refinement(model, segment, faces_by_id, settings):
    """Evaluate one patch, recursively splitting rejected blended patches."""
    candidate, reason = evaluate(model, segment, faces_by_id, settings)
    if candidate is not None:
        return [(segment, candidate, settings["featureAngleDeg"])], []
    if not _can_refine(reason):
        return [], [(segment, reason)]

    accepted = []
    terminal_rejections = []
    rejected = [(segment, reason)]
    for angle in _refinement_angles(settings["featureAngleDeg"]):
        next_rejected = []
        for parent, parent_reason in rejected:
            parent_faces = [faces_by_id[face_id] for face_id in parent]
            children, _ = segment_faces(parent_faces, angle)
            if len(children) == 1 and children[0] == parent:
                next_rejected.append((parent, parent_reason))
                continue
            for child in children:
                child_candidate, child_reason = evaluate(model, child, faces_by_id, settings)
                if child_candidate is None:
                    target = next_rejected if _can_refine(child_reason) else terminal_rejections
                    target.append((child, child_reason))
                else:
                    child_candidate["detection_feature_angle_deg"] = angle
                    child_candidate["warnings"].append("ADAPTIVE_PATCH_REFINEMENT")
                    accepted.append((child, child_candidate, angle))
        rejected = next_rejected
        if not rejected:
            break
    return accepted, terminal_rejections + rejected


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
            accepted, rejected = _evaluate_with_refinement(model, segment, faces_by_id, settings)
        except Exception as exc:
            logger.exception("segment evaluation failed face_count=%d sample=%s", len(segment), segment[:10])
            record_rejection(segment, "ERROR:{}".format(exc))
            continue
        for rejected_segment, reason in rejected:
            record_rejection(rejected_segment, reason)
        for candidate_segment, candidate, _angle in accepted:
            candidate["candidate_id"] = "H{:04d}".format(len(candidates) + 1)
            component_ids = sorted({
                model.elements[faces_by_id[face_id].element_id].component_id
                for face_id in candidate_segment
            })
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
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tcl-output", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    args = parser.parse_args(argv)
    logger = create_logger("auto_hole_rbe2", args.log)
    try:
        read_started = time.perf_counter()
        request = validate_request(load_json(args.request))
        model = read_analysis_mesh(args.mesh)
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
            "adaptive_candidate_count": sum(
                "ADAPTIVE_PATCH_REFINEMENT" in row["warnings"] for row in candidates
            ),
            "rejected_count": rejection_summary["count"],
            "reject_reason_counts": rejection_summary["reason_counts"],
            "rejected": rejection_summary["samples"],
        }
        result["candidates"] = candidates
        result["warnings"] = warnings
        result["performance"]["read_seconds"] = round(read_seconds, 6)
        result["performance"]["detect_seconds"] = round(detect_seconds, 6)
        result["performance"]["write_seconds"] = 0.0
        write_result(args.output, args.tcl_output, "::AutoHoleRBE2::pythonResult", result)
        logger.info(
            "complete candidates=%d adaptive=%d rejected=%d reasons=%s",
            len(candidates),
            result["summary"]["adaptive_candidate_count"],
            rejection_summary["count"],
            rejection_summary["reason_counts"],
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
