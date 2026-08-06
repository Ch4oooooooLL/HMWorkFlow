"""Generate, detect, realize and round-trip all offline seam fixtures."""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from generate_fixtures import generate
from hmworkflow.mesh_seam_weld.fem_mesh_reader import read_shell_fem_bundle
from hmworkflow.fem_auto_seam.backend import (
    DEFAULT_SETTINGS,
    detect_candidates,
    realize_candidates,
    write_fem_bundle,
    write_json,
)


def _validate_case(name, original, result, candidates, realization, expected):
    errors = []
    created = [row for row in realization if row["status"] == "CREATED"]
    created_ids = {row["candidate_id"] for row in created}
    by_id = {row["candidate_id"]: row for row in candidates}
    counts = {
        "candidate_count": len(candidates),
        "created_count": len(created),
        "t_count": sum(row["candidate_type"] == "T_SEAM" for row in candidates),
        "patch_count": sum(row["candidate_type"] == "PATCH_SEAM" for row in candidates),
        "patch_review_count": sum(row["candidate_type"] == "PATCH_SEAM" and not row["auto_eligible"] for row in candidates),
        "near_edge_count": sum(row["candidate_type"] == "NEAR_FREE_EDGES" for row in candidates),
    }
    checks = (
        ("minimum_created", "created_count", lambda actual, limit: actual >= limit),
        ("maximum_created", "created_count", lambda actual, limit: actual <= limit),
        ("minimum_t", "t_count", lambda actual, limit: actual >= limit),
        ("minimum_patch", "patch_count", lambda actual, limit: actual >= limit),
        ("minimum_patch_review", "patch_review_count", lambda actual, limit: actual >= limit),
        ("minimum_near_edge", "near_edge_count", lambda actual, limit: actual >= limit),
        ("maximum_candidates", "candidate_count", lambda actual, limit: actual <= limit),
    )
    for expected_key, count_key, predicate in checks:
        if expected_key in expected and not predicate(counts[count_key], expected[expected_key]):
            errors.append("{}={} does not satisfy {}={}".format(count_key, counts[count_key], expected_key, expected[expected_key]))
    if "minimum_distinct_targets" in expected:
        distinct = len({by_id[candidate_id]["target_component_id"] for candidate_id in created_ids})
        counts["distinct_created_targets"] = distinct
        if distinct < expected["minimum_distinct_targets"]:
            errors.append("distinct created targets {} < {}".format(distinct, expected["minimum_distinct_targets"]))
    if "minimum_same_source_target_count" in expected:
        grouped_targets = {}
        for candidate_id in created_ids:
            candidate = by_id[candidate_id]
            key = (candidate["source_component_id"], tuple(candidate["source_node_ids"]))
            grouped_targets.setdefault(key, set()).add(candidate["target_component_id"])
        maximum_targets = max((len(values) for values in grouped_targets.values()), default=0)
        counts["maximum_targets_for_same_source_path"] = maximum_targets
        if maximum_targets < expected["minimum_same_source_target_count"]:
            errors.append("same source path reached {} targets; expected at least {}".format(maximum_targets, expected["minimum_same_source_target_count"]))
    if "maximum_created_t_length" in expected:
        lengths = [by_id[candidate_id]["length"] for candidate_id in created_ids if by_id[candidate_id]["candidate_type"] == "T_SEAM"]
        if not lengths or max(lengths) > expected["maximum_created_t_length"]:
            errors.append("created T path does not stay inside the expected common overlap")
    if "minimum_created_t_length" in expected:
        lengths = [by_id[candidate_id]["length"] for candidate_id in created_ids if by_id[candidate_id]["candidate_type"] == "T_SEAM"]
        if not lengths or max(lengths) < expected["minimum_created_t_length"]:
            errors.append("created T path is shorter than the expected common overlap")
    if "minimum_source_inserted_nodes" in expected:
        count = sum(len(row.get("created_source_node_ids", [])) for row in created)
        counts["source_split_created_nodes"] = count
        if count < expected["minimum_source_inserted_nodes"]:
            errors.append("source boundary did not insert the required partial-overlap nodes")
    if "minimum_deleted_mother_elements" in expected:
        count = sum(len(row.get("deleted_mother_elements", [])) for row in created)
        counts["deleted_mother_elements"] = count
        if count < expected["minimum_deleted_mother_elements"]:
            errors.append("target mother-shell split was not exercised")
    if "minimum_created_nodes" in expected:
        count = sum(len(row.get("created_node_ids", [])) for row in created)
        counts["created_nodes"] = count
        if count < expected["minimum_created_nodes"]:
            errors.append("constraint split created no GRID entities")

    known_nodes = set(result.nodes)
    for element in result.elements.values():
        if not set(element.node_ids).issubset(known_nodes):
            errors.append("result element {} references missing nodes".format(element.element_id))
    for report in created:
        candidate = by_id[report["candidate_id"]]
        source_nodes = {node_id for element in result.elements_for_components([candidate["source_component_id"]]) for node_id in element.node_ids}
        target_nodes = {node_id for element in result.elements_for_components([candidate["target_component_id"]]) for node_id in element.node_ids}
        for element_id in report["created_weld_element_ids"]:
            element_nodes = set(result.elements[element_id].node_ids)
            if not element_nodes & source_nodes or not element_nodes & target_nodes:
                errors.append("weld element {} does not connect source and target components".format(element_id))
    if len(result.elements) != len(original.elements) + sum(
        len(row.get("created_mother_elements", [])) + len(row.get("created_source_elements", [])) + len(row.get("created_weld_element_ids", []))
        - len(row.get("deleted_mother_elements", [])) - len(row.get("deleted_source_elements", []))
        for row in created
    ):
        errors.append("result element accounting mismatch")
    return counts, errors


def run(output_dir):
    output_dir = Path(output_dir)
    generated = generate(output_dir)
    settings = dict(DEFAULT_SETTINGS)
    summary = []
    overall_started = time.perf_counter()
    for row in generated:
        name = row["name"]
        case_dir = Path(row["manifest"]).parent
        expected = json.loads(Path(row["expected"]).read_text(encoding="utf-8"))
        original = read_shell_fem_bundle(Path(row["manifest"]))
        started = time.perf_counter()
        candidates = detect_candidates(original, settings)
        detection_seconds = time.perf_counter() - started
        write_json(case_dir / "candidates.json", {"schema_version": "1.0", "candidates": candidates})
        started = time.perf_counter()
        result, realization = realize_candidates(original, candidates, settings)
        realization_seconds = time.perf_counter() - started
        write_json(case_dir / "realization.json", {"schema_version": "1.0", "results": realization})
        result_manifest = write_fem_bundle(result, case_dir / "result.fem", case_dir / "result_manifest.json")
        round_trip = read_shell_fem_bundle(result_manifest)
        counts, errors = _validate_case(name, original, round_trip, candidates, realization, expected)
        case_report = {
            "case": name,
            "status": "PASS" if not errors else "FAIL",
            "counts": counts,
            "timing_seconds": {"detection": round(detection_seconds, 6), "realization": round(realization_seconds, 6)},
            "errors": errors,
            "files": {
                "input": str(case_dir / "input.fem"),
                "candidates": str(case_dir / "candidates.json"),
                "realization": str(case_dir / "realization.json"),
                "result": str(case_dir / "result.fem"),
            },
        }
        write_json(case_dir / "validation.json", case_report)
        summary.append(case_report)
    report = {
        "schema_version": "1.0",
        "backend": "offline_auto_shell_seam_topology_only",
        "status": "PASS" if all(row["status"] == "PASS" for row in summary) else "FAIL",
        "case_count": len(summary),
        "passed_count": sum(row["status"] == "PASS" for row in summary),
        "elapsed_seconds": round(time.perf_counter() - overall_started, 6),
        "cases": summary,
    }
    write_json(output_dir / "validation_report.json", report)
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "runtime" / "tasks" / "fem_auto_seam" / "offline_backend")
    args = parser.parse_args()
    report = run(args.output)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2))
    return 0 if report["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
