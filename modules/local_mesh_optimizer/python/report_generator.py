"""Offline CSV and HTML reports for Local Mesh Optimizer."""

from __future__ import annotations

import csv
import html
import io
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Sequence

from io_utils import atomic_write_json, atomic_write_text


SUMMARY_FIELDS = [
    "model_name", "criteria_file", "scope_type", "checked_elements",
    "failed_before", "failed_after", "failure_rate_before", "failure_rate_after",
    "optimizable_failed_before", "washer_failed_excluded",
    "regions_total", "regions_success", "regions_partial", "regions_failed",
    "elapsed_seconds", "cancelled", "task_status", "output_model",
]

REGION_FIELDS = [
    "region_id", "component_ids", "initial_failed_count", "expanded_element_count",
    "final_failed_count", "rounds", "optimization_methods", "elapsed_seconds",
    "planned_action_count", "manual_review_count", "status", "rollback_count", "message",
]


def _csv_text(fieldnames: Sequence[str], rows: Iterable[Mapping[str, object]]) -> str:
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)
    return buffer.getvalue()


def _region_row(region: Mapping[str, object]) -> Dict[str, object]:
    return {
        "region_id": region.get("region_id", ""),
        "component_ids": ";".join(str(value) for value in region.get("components", [])),
        "initial_failed_count": region.get("failed_count", 0),
        "expanded_element_count": region.get("expanded_count", 0),
        "final_failed_count": region.get("current_failed_count", region.get("failed_count", 0)),
        "rounds": region.get("rounds", 0),
        "optimization_methods": ";".join(region.get("optimization_methods", [])),
        "elapsed_seconds": region.get("elapsed_seconds", 0.0),
        "planned_action_count": len(region.get("planned_actions", [])),
        "manual_review_count": region.get("manual_review_count", 0),
        "status": region.get("status", "pending"),
        "rollback_count": region.get("rollback_count", 0),
        "message": region.get("message", ""),
    }


def _summary(task: Mapping[str, object], result: Mapping[str, object], regions: Sequence[Mapping[str, object]]) -> Dict[str, object]:
    checked = int(result.get("checked_elements", 0))
    failed_before = int(result.get("failed_before", 0))
    failed_after = int(result.get("failed_after", failed_before))
    statuses = [region.get("status", "pending") for region in regions]
    model_path = Path(str(task.get("model_path", "")))
    return {
        "model_name": model_path.name,
        "criteria_file": task.get("criteria_path", ""),
        "scope_type": task.get("scope_type", ""),
        "checked_elements": checked,
        "failed_before": failed_before,
        "failed_after": failed_after,
        "failure_rate_before": (100.0 * failed_before / checked) if checked else 0.0,
        "failure_rate_after": (100.0 * failed_after / checked) if checked else 0.0,
        "optimizable_failed_before": task.get("optimizable_failed_before", failed_before),
        "washer_failed_excluded": task.get("washer_failed_excluded", 0),
        "regions_total": len(regions),
        "regions_success": statuses.count("success"),
        "regions_partial": statuses.count("partial_success"),
        "regions_failed": sum(
            status in ("failed", "rolled_back", "task_rolled_back", "manual")
            for status in statuses
        ),
        "elapsed_seconds": result.get("elapsed_seconds", 0.0),
        "cancelled": bool(result.get("cancelled", False)),
        "task_status": result.get("status", "complete"),
        "output_model": result.get("output_model", ""),
    }


def generate_report(
    report_dir: Path,
    task: Mapping[str, object],
    result: Mapping[str, object],
    regions: Sequence[Mapping[str, object]],
) -> Dict[str, object]:
    report_dir.mkdir(parents=True, exist_ok=True)
    summary = _summary(task, result, regions)
    region_rows = [_region_row(region) for region in regions]
    atomic_write_text(report_dir / "summary.csv", _csv_text(SUMMARY_FIELDS, [summary]))
    atomic_write_text(report_dir / "regions.csv", _csv_text(REGION_FIELDS, region_rows))
    atomic_write_json(report_dir / "settings.json", task)

    table_rows = "\n".join(
        "<tr>{}</tr>".format("".join("<td>{}</td>".format(html.escape(str(row[field]))) for field in REGION_FIELDS))
        for row in region_rows
    )
    summary_rows = "\n".join(
        "<tr><th>{}</th><td>{}</td></tr>".format(html.escape(field), html.escape(str(summary[field])))
        for field in SUMMARY_FIELDS
    )
    document = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>Local Mesh Optimizer Report</title>
<style>body{{font:14px Arial,"Microsoft YaHei",sans-serif;margin:24px;color:#222}}h1,h2{{color:#244d75}}table{{border-collapse:collapse;width:100%;margin:12px 0}}th,td{{border:1px solid #bbb;padding:6px 8px;text-align:left}}th{{background:#edf3f8}}code{{background:#f3f3f3;padding:2px 4px}}.note{{padding:10px;background:#fff8df;border-left:4px solid #d6a800}}</style></head>
<body><h1>Local Mesh Optimizer / 局部网格优化</h1>
<p class="note">最终质量集合由 HyperMesh 产生；本报告不会用 Python 质量计算替代 HyperMesh 判定。</p>
<h2>Summary</h2><table>{summary_rows}</table>
<h2>Regions</h2><table><thead><tr>{headers}</tr></thead><tbody>{table_rows}</tbody></table>
</body></html>""".format(
        summary_rows=summary_rows,
        headers="".join("<th>{}</th>".format(html.escape(field)) for field in REGION_FIELDS),
        table_rows=table_rows,
    )
    atomic_write_text(report_dir / "summary.html", document)
    return summary
