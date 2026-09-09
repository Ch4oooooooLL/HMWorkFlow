"""End-to-end pipeline for the V2 weld-recognition fixture corpus.

Runs, in order:
    generate  ->  FEM structural validator  ->  analytical geometry validator
              ->  recognition regression

and writes one consolidated JSON report (``report.json``) under the corpus
root.  Every failure category the spec cares about is reported separately and
False AUTO is never folded into an overall-accuracy figure.

Exit status is 0 only when every stage passes: all FEM validators clean, the
geometry validator has no findings, and every recognition fixture passes.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

import run_weld_recognition_regression as regression
import validate_fixture_geometry as geometry
import validate_generated_fem as fem
from wfc_catalogue import DEFAULT_OUTPUT_ROOT


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _aggregate_counts(entries, key: str):
    counts = {}
    for entry in entries:
        row_counts = entry.get(key) or entry.get("counts") or {}
        for name, value in row_counts.items():
            counts[name] = counts.get(name, 0) + int(value or 0)
    return counts


def run(output_root: Path, regression_settings=None) -> dict:
    import generate_weld_recognition_fixtures as generator
    generate_report = generator.generate(output_root)

    fem_report = fem.run(output_root)
    geometry_report = geometry.run(output_root)
    regress_report = regression.run(output_root, settings=regression_settings)

    all_cases = regress_report["atomic"] + regress_report["composite"]
    failed_cases = [entry for entry in all_cases if entry["status"] != "PASS"]
    totals = regress_report["totals"]

    # corpus scale numbers straight from the generated manifests
    atomic_entries = generate_report["atomic"]
    composite_entries = generate_report["composite"]
    node_total = sum(e["node_count"] for e in atomic_entries + composite_entries)
    element_total = sum(e["element_count"] for e in atomic_entries + composite_entries)
    component_total = sum(e["component_count"] for e in atomic_entries + composite_entries)

    report = {
        "pipeline": "generate -> validate_fem -> validate_geometry -> regression",
        "corpus_root": ".",
        "stage": {
            "generate": {
                "atomic": len(atomic_entries),
                "composite": len(composite_entries),
                "node_count": node_total,
                "element_count": element_total,
                "component_count": component_total,
            },
            "validate_fem": {
                "fixture_count": fem_report["fixture_count"],
                "valid_count": fem_report["valid_count"],
                "invalid_count": fem_report["invalid_count"],
            },
            "validate_geometry": {
                "case_count": geometry_report["case_count"],
                "valid_case_count": geometry_report["valid_case_count"],
                "weld_count": geometry_report["weld_count"],
                "finding_count": geometry_report["finding_count"],
            },
            "regression": {
                "case_count": regress_report["summary"]["case_count"],
                "passed_count": regress_report["summary"]["passed_count"],
                "failed_count": regress_report["summary"]["failed_count"],
            },
        },
        "decisions_expected": {
            "auto": sum(e["expected_auto"] for e in atomic_entries + composite_entries),
            "review": sum(e["expected_review"] for e in atomic_entries + composite_entries),
        },
        "failure_categories": {
            # False AUTO is reported alone (never merged into overall accuracy).
            "false_auto": totals["false_auto"],
            "missed_expected_auto": totals["missed_expected_auto"],
            "expected_auto_got_review": totals["expected_auto_got_review"],
            "expected_review_got_auto": totals["expected_review_got_auto"],
            "wrong_target": totals["wrong_target"],
            "wrong_weld_type": totals["wrong_weld_type"],
            "wrong_source_subchain": totals["wrong_source_subchain"],
            "unexpected_candidate": totals["unexpected_candidate"],
            "duplicate_candidate": totals["duplicate_candidate"],
            "support_run_mismatch": totals["support_run_mismatch"],
            "missing_required_reason": totals["missing_required_reason"],
            "forbidden_reason": totals["forbidden_reason"],
        },
        "candidates": {
            "detected": totals["candidate_count"],
            "auto_rows": totals["auto_count"],
        },
        "failed_fixtures": [
            {
                "case_id": entry["case_id"],
                "kind": entry["kind"],
                "counts": entry["counts"],
                "issues": entry["issues"],
            }
            for entry in failed_cases
        ],
        "known_gaps": [
            {"case_id": entry["case_id"], "kind": entry["kind"], "items": entry["known_gap_issues"]}
            for entry in all_cases
            if entry["known_gap_issues"]
        ],
        "elapsed_seconds": totals["elapsed_seconds"],
    }

    fem_ok = fem_report["invalid_count"] == 0
    geometry_ok = geometry_report["finding_count"] == 0
    failed_ids = {entry["case_id"] for entry in failed_cases}
    regression_clean = not failed_ids
    report["status"] = "ALL_GREEN" if (fem_ok and geometry_ok and regression_clean) else "SEE_FAILURES"
    return report


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT_ROOT)
    args = parser.parse_args(argv)
    report = run(args.output)
    output_root = Path(args.output)
    report_path = output_root / "report.json"
    output_root.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["status"] == "ALL_GREEN" else 1


if __name__ == "__main__":
    raise SystemExit(main())
