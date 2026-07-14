"""Self-contained CSV and modular HTML reports for Local Mesh Optimizer."""

from __future__ import annotations

import csv
import html
import io
import json
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence

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

LABELS = {
    "model_name": "模型", "criteria_file": "Criteria 文件", "scope_type": "检查范围",
    "checked_elements": "检查单元", "failed_before": "优化前失败", "failed_after": "优化后失败",
    "failure_rate_before": "优化前失败率", "failure_rate_after": "优化后失败率",
    "optimizable_failed_before": "可自动优化失败", "washer_failed_excluded": "Washer 人工处理",
    "regions_total": "区域总数", "regions_success": "成功区域", "regions_partial": "部分成功区域",
    "regions_failed": "失败/回滚区域", "elapsed_seconds": "耗时（秒）", "cancelled": "是否取消",
    "task_status": "任务状态", "output_model": "输出模型",
}


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
    checked = int(result.get("checked_elements", task.get("checked_elements", 0)))
    failed_before = int(result.get("failed_before", task.get("failed_before", 0)))
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
        "regions_failed": sum(status in ("failed", "rolled_back", "task_rolled_back", "manual") for status in statuses),
        "elapsed_seconds": result.get("elapsed_seconds", 0.0),
        "cancelled": bool(result.get("cancelled", False)),
        "task_status": result.get("status", "complete"),
        "output_model": result.get("output_model", ""),
    }


def _escape(value: object) -> str:
    return html.escape(str(value), quote=True)


def _format_value(key: str, value: object) -> str:
    if key.startswith("failure_rate"):
        return "{:.2f}%".format(float(value))
    if isinstance(value, bool):
        return "是" if value else "否"
    return str(value)


def _file_uri(path: Path) -> str:
    try:
        return path.resolve().as_uri()
    except (OSError, ValueError):
        return ""


def _human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024.0 or unit == "GB":
            return "{:.0f} {}".format(value, unit) if unit == "B" else "{:.1f} {}".format(value, unit)
        value /= 1024.0
    return "{} B".format(size)


def _read_json_if_present(path: Path) -> Mapping[str, object]:
    if not path.is_file():
        return {}
    try:
        with path.open("r", encoding="utf-8-sig") as stream:
            value = json.load(stream)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _settings_rows(task: Mapping[str, object]) -> str:
    hidden = {"model_path", "criteria_path", "report_dir", "protection"}
    return "\n".join(
        "<tr><th>{}</th><td>{}</td></tr>".format(_escape(key), _escape(_format_value(key, value)))
        for key, value in task.items() if key not in hidden
    )


def _artifact_rows(task_dir: Optional[Path], report_dir: Path) -> str:
    paths: List[Path] = []
    if task_dir and task_dir.is_dir():
        paths.extend(path for path in task_dir.iterdir() if path.is_file())
    paths.extend(path for path in report_dir.iterdir() if path.is_file() and path.name != "summary.html")
    unique = {str(path.resolve()).lower(): path for path in paths}
    rows = []
    for path in sorted(unique.values(), key=lambda item: item.name.lower()):
        try:
            size = _human_size(path.stat().st_size)
        except OSError:
            size = "-"
        uri = _file_uri(path)
        name = _escape(path.name)
        link = '<a href="{}">{}</a>'.format(_escape(uri), name) if uri else name
        category = "报告" if path.parent == report_dir else "任务产物"
        rows.append("<tr><td>{}</td><td>{}</td><td>{}</td></tr>".format(link, category, size))
    return "\n".join(rows) or '<tr><td colspan="3" class="muted">未发现可列出的任务文件。</td></tr>'


def _performance_rows(task_dir: Optional[Path], report_dir: Path) -> str:
    payload: Dict[str, object] = {}
    for path in (
        report_dir / "performance_metrics.json",
        (task_dir / "tcl_performance_metrics.json") if task_dir else Path("__missing__"),
        (task_dir / "python_performance_metrics.json") if task_dir else Path("__missing__"),
    ):
        data = _read_json_if_present(path)
        if data:
            payload[path.stem] = data
    if not payload:
        return '<p class="muted">本次任务没有可用的性能统计文件。</p>'
    return '<pre class="json">{}</pre>'.format(_escape(json.dumps(payload, ensure_ascii=False, indent=2)))


def generate_report(
    report_dir: Path,
    task: Mapping[str, object],
    result: Mapping[str, object],
    regions: Sequence[Mapping[str, object]],
    task_dir: Optional[Path] = None,
) -> Dict[str, object]:
    report_dir.mkdir(parents=True, exist_ok=True)
    summary = _summary(task, result, regions)
    region_rows = [_region_row(region) for region in regions]
    atomic_write_text(report_dir / "summary.csv", _csv_text(SUMMARY_FIELDS, [summary]))
    atomic_write_text(report_dir / "regions.csv", _csv_text(REGION_FIELDS, region_rows))
    atomic_write_json(report_dir / "settings.json", task)

    summary_rows = "\n".join(
        "<tr><th>{}</th><td>{}</td></tr>".format(
            _escape(LABELS.get(field, field)), _escape(_format_value(field, summary[field]))
        ) for field in SUMMARY_FIELDS
    )
    protection = task.get("protection", {})
    protection_rows = "\n".join(
        "<tr><th>{}</th><td>{}</td></tr>".format(_escape(key), _escape(_format_value(key, value)))
        for key, value in protection.items()
    ) if isinstance(protection, dict) else ""
    table_rows = "\n".join(
        '<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td><span class="status {}">{}</span></td><td>{}</td></tr>'.format(
            _escape(row["region_id"]), _escape(row["component_ids"]), row["initial_failed_count"],
            row["expanded_element_count"], row["final_failed_count"], row["rounds"],
            _escape(row["optimization_methods"]), row["manual_review_count"],
            _escape(row["status"]), _escape(row["status"]), _escape(row["message"]),
        ) for row in region_rows
    ) or '<tr><td colspan="10" class="muted">本次任务没有生成优化区域。</td></tr>'
    delta = int(summary["failed_before"]) - int(summary["failed_after"])
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    document = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>局部网格优化报告</title>
<style>
:root{{--bg:#f4f7fb;--panel:#fff;--ink:#172033;--muted:#667085;--line:#dbe3ee;--brand:#245b96;--good:#157347;--warn:#9a6700;--bad:#b42318}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 Arial,"Microsoft YaHei",sans-serif}}
.page{{max-width:1440px;margin:auto;padding:28px}}header{{color:#fff;background:linear-gradient(120deg,#173d68,#2771b8);padding:28px;border-radius:14px;box-shadow:0 8px 24px #173d6824}}
h1{{margin:0 0 6px;font-size:28px}}h2{{margin:0 0 14px;color:var(--brand);font-size:19px}}.sub,.muted{{color:var(--muted)}}header .sub{{color:#dcecff}}
.cards{{display:grid;grid-template-columns:repeat(5,minmax(140px,1fr));gap:12px;margin:18px 0}}.card,.module{{background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:0 3px 12px #2538580a}}
.card{{padding:16px}}.card b{{display:block;font-size:25px;color:var(--brand)}}.module{{padding:20px;margin:16px 0;overflow:auto}}
.two{{display:grid;grid-template-columns:1fr 1fr;gap:16px}}table{{border-collapse:collapse;width:100%}}th,td{{border-bottom:1px solid var(--line);padding:8px 10px;text-align:left;vertical-align:top}}th{{background:#f7f9fc;white-space:nowrap}}a{{color:var(--brand)}}
.note{{padding:12px 14px;background:#fff8df;border-left:4px solid #d6a800;border-radius:4px}}.status{{display:inline-block;padding:2px 7px;border-radius:10px;background:#eef2f6}}.status.success{{color:var(--good);background:#e9f7ef}}.status.partial_success{{color:var(--warn);background:#fff5d6}}.status.failed,.status.rolled_back,.status.task_rolled_back{{color:var(--bad);background:#fdecec}}
.json{{max-height:430px;overflow:auto;background:#111827;color:#d7e2f1;border-radius:8px;padding:14px;white-space:pre-wrap}}footer{{padding:8px;text-align:center;color:var(--muted)}}
@media(max-width:900px){{.cards{{grid-template-columns:repeat(2,1fr)}}.two{{grid-template-columns:1fr}}.page{{padding:12px}}}}
</style></head><body><main class="page">
<header><h1>局部网格优化报告</h1><div class="sub">Local Mesh Optimizer · 生成时间 {generated_at}</div></header>
<section class="cards">
<div class="card"><span>检查单元</span><b>{checked}</b></div><div class="card"><span>优化前失败</span><b>{before}</b></div>
<div class="card"><span>优化后失败</span><b>{after}</b></div><div class="card"><span>失败减少</span><b>{delta}</b></div>
<div class="card"><span>任务状态</span><b>{status}</b></div></section>
<p class="note">最终质量集合由 HyperMesh 产生；本报告只组织任务产物和运行信息，不使用 Python 质量计算替代 HyperMesh 判定。</p>
<section class="module"><h2>1. 任务摘要</h2><table>{summary_rows}</table></section>
<div class="two"><section class="module"><h2>2. 运行设置</h2><table>{settings_rows}</table></section>
<section class="module"><h2>3. 保护策略</h2><table>{protection_rows}</table></section></div>
<section class="module"><h2>4. 优化区域</h2><table><thead><tr><th>区域</th><th>组件</th><th>初始失败</th><th>扩展单元</th><th>最终失败</th><th>轮次</th><th>优化方法</th><th>人工复核</th><th>状态</th><th>说明</th></tr></thead><tbody>{region_rows}</tbody></table></section>
<section class="module"><h2>5. 性能与过程统计</h2>{performance}</section>
<section class="module"><h2>6. 任务文件与报告产物</h2><table><thead><tr><th>文件</th><th>类型</th><th>大小</th></tr></thead><tbody>{artifacts}</tbody></table></section>
<footer>Local Mesh Optimizer · Offline self-contained report</footer>
</main></body></html>
""".format(
        generated_at=_escape(generated_at), checked=summary["checked_elements"], before=summary["failed_before"],
        after=summary["failed_after"], delta=delta, status=_escape(summary["task_status"]), summary_rows=summary_rows,
        settings_rows=_settings_rows(task), protection_rows=protection_rows or '<tr><td class="muted">未配置</td></tr>',
        region_rows=table_rows, performance=_performance_rows(task_dir, report_dir),
        artifacts=_artifact_rows(task_dir, report_dir),
    )
    atomic_write_text(report_dir / "summary.html", document)
    return summary
