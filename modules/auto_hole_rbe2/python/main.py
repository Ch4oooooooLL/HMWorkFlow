"""CLI entry for solid through-hole recognition."""
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

from duplicate_detector import annotate, build_index
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


def detect(request, model, existing, logger):
    settings = request["settings"]
    faces, warnings = extract(model, request["selected_component_ids"], settings["eps"])
    segments, _ = segment_faces(faces, settings["featureAngleDeg"])
    faces_by_id = {face.face_id: face for face in faces}
    candidates, rejected = [], []
    duplicate_index = build_index(existing)
    for segment in segments:
        try:
            candidate, reason = evaluate(model, segment, faces_by_id, settings)
        except Exception as exc:
            logger.exception("segment evaluation failed faces=%s", segment)
            rejected.append({"segment_face_ids": segment, "reject_reasons": ["ERROR:{}".format(exc)]})
            continue
        if candidate is None:
            rejected.append({"segment_face_ids": segment, "reject_reasons": [reason]})
            continue
        candidate["candidate_id"] = "H{:04d}".format(len(candidates) + 1)
        component_ids = sorted({model.elements[faces_by_id[face_id].element_id].component_id for face_id in segment})
        candidate["component_id"] = component_ids[0] if len(component_ids) == 1 else 0
        annotate(candidate, duplicate_index)
        candidates.append(candidate)
    validate(candidates, model)
    return faces, segments, candidates, rejected, warnings


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
        model = read_mesh(args.mesh)
        existing = validate_existing(load_json(args.existing))
        read_seconds = time.perf_counter() - read_started
        detect_started = time.perf_counter()
        faces, segments, candidates, rejected, warnings = detect(request, model, existing, logger)
        detect_seconds = time.perf_counter() - detect_started
        result = new_result("auto_hole_rbe2", request["run_id"])
        result["summary"] = {
            "exterior_face_count": len(faces),
            "segment_count": len(segments),
            "candidate_count": len(candidates),
            "create_count": sum(row["recommended_action"] == "CREATE" for row in candidates),
            "existing_count": sum(row["recommended_action"] == "SKIP_EXISTING" for row in candidates),
            "rejected_count": len(rejected),
            "rejected": rejected,
        }
        result["candidates"] = candidates
        result["warnings"] = warnings
        result["performance"]["read_seconds"] = round(read_seconds, 6)
        result["performance"]["detect_seconds"] = round(detect_seconds, 6)
        write_started = time.perf_counter()
        write_result(args.output, args.tcl_output, "::AutoHoleRBE2::pythonResult", result)
        result["performance"]["write_seconds"] = round(time.perf_counter() - write_started, 6)
        # Rewrite once to persist measured write time.
        write_result(args.output, args.tcl_output, "::AutoHoleRBE2::pythonResult", result)
        logger.info("complete candidates=%d rejected=%d", len(candidates), len(rejected))
        return 0
    except Exception as exc:
        logger.exception("auto_hole_rbe2 failed")
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 2
    finally:
        close_logger(logger)


if __name__ == "__main__":
    raise SystemExit(main())
