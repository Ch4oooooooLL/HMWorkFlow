"""Flat CSV rendering of the V2 weld-recognition ground truth.

Each expected weld becomes one row so the corpus can be inspected, diffed and
fed into spreadsheets without loading JSON.  The JSON files remain the
authoritative ground truth for the regression runner; the CSV is a faithful
flattening produced from the same ``GroundTruth.to_dict()`` payload.

Encoding is utf-8-sig so Microsoft Excel on a zh_CN Windows code page renders
the Chinese ``note``/``known_gap_note`` fields correctly.
"""
from __future__ import annotations

import csv
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

WELD_COLUMNS = [
    "case_id",
    "case_kind",
    "semantic_id",
    "weld_type",
    "source_component",
    "expected_decision",
    "target_components",
    "required_reason_codes",
    "required_reason_any",
    "forbidden_reason_codes",
    "forbidden_targets",
    "allow_extra_targets",
    "overlap_axis",
    "allowed_realization_segments",
    "geometry_parallel",
    "source_path_node_ids",
    "source_path_start_xyz",
    "source_path_end_xyz",
    "source_path_length",
    "known_gap_note",
    "note",
]

FORBIDDEN_COLUMNS = [
    "case_id",
    "source_component",
    "target_component",
    "severity",
    "note",
]


def _join(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (list, tuple)):
        return "|".join(str(item) for item in value)
    return str(value)


def _xyz(value: Any) -> str:
    if not value:
        return ""
    return ",".join("{:g}".format(float(item)) for item in value)


def _node_ids(value: Any) -> str:
    if not value:
        return ""
    return " ".join(str(int(item)) for item in value)


def weld_row(gt: Dict[str, Any], weld: Dict[str, Any]) -> Dict[str, str]:
    path = weld.get("source_path") or {}
    row = {
        "case_id": gt.get("case_id", ""),
        "case_kind": gt.get("case_kind", ""),
        "semantic_id": weld.get("semantic_id", ""),
        "weld_type": weld.get("weld_type", ""),
        "source_component": weld.get("source_component", ""),
        "expected_decision": weld.get("expected_decision", ""),
        "target_components": _join(weld.get("target_components")),
        "required_reason_codes": _join(weld.get("required_reason_codes")),
        "required_reason_any": _join(weld.get("required_reason_any")),
        "forbidden_reason_codes": _join(weld.get("forbidden_reason_codes")),
        "forbidden_targets": _join(weld.get("forbidden_targets")),
        "allow_extra_targets": "1" if weld.get("allow_extra_targets") else "0",
        "overlap_axis": weld.get("overlap_axis", "X"),
        "allowed_realization_segments": str(weld.get("allowed_realization_segments", 1)),
        "geometry_parallel": "1" if weld.get("geometry_parallel", True) else "0",
        "source_path_node_ids": _node_ids(path.get("expected_node_ids")),
        "source_path_start_xyz": _xyz(path.get("start_xyz")),
        "source_path_end_xyz": _xyz(path.get("end_xyz")),
        "source_path_length": "{:.6g}".format(float(path.get("length") or 0.0)),
        "known_gap_note": weld.get("known_gap_note", ""),
        "note": weld.get("note", ""),
    }
    return row


def forbidden_row(gt: Dict[str, Any], forbidden: Dict[str, Any]) -> Dict[str, str]:
    return {
        "case_id": gt.get("case_id", ""),
        "source_component": forbidden.get("source_component", ""),
        "target_component": forbidden.get("target_component", ""),
        "severity": forbidden.get("severity", "FALSE_AUTO_CRITICAL"),
        "note": forbidden.get("note", ""),
    }


def write_weld_csv(gt: Dict[str, Any], path) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = [weld_row(gt, weld) for weld in gt.get("welds", [])]
    _write_rows(WELD_COLUMNS, rows, path)


def write_forbidden_csv(gt: Dict[str, Any], path) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = [forbidden_row(gt, item) for item in gt.get("forbidden_candidates", [])]
    _write_rows(FORBIDDEN_COLUMNS, rows, path)


def _write_rows(columns: List[str], rows: Iterable[Dict[str, str]], path: Path) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in columns})


def aggregate_case_csvs(case_dirs: Iterable[Path], output_path: Path,
                        csv_name: str = "ground_truth.csv") -> Dict[str, int]:
    """Combine every per-case ground_truth.csv into one corpus-wide table."""
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    aggregate: List[Dict[str, str]] = []
    forbidden: List[Dict[str, str]] = []
    for case_dir in case_dirs:
        gt_path = Path(case_dir) / "ground_truth.json"
        if not gt_path.is_file():
            continue
        import json
        gt = json.loads(gt_path.read_text(encoding="utf-8"))
        aggregate.extend(weld_row(gt, weld) for weld in gt.get("welds", []))
        forbidden.extend(forbidden_row(gt, item) for item in gt.get("forbidden_candidates", []))
    _write_rows(WELD_COLUMNS, aggregate, output_path)
    forbidden_path = output_path.with_name(
        output_path.name.replace("ground_truth", "ground_truth_forbidden"))
    _write_rows(FORBIDDEN_COLUMNS, forbidden, forbidden_path)
    return {"welds": len(aggregate), "forbidden": len(forbidden)}
