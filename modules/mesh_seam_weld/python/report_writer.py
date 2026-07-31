"""Stable JSON and self-contained engineering audit reports."""
from __future__ import annotations

import html
import json
from pathlib import Path


def write_report(path, report):
    path=Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(report,ensure_ascii=False,sort_keys=True,indent=2)+"\n",encoding="utf-8")


def _value(value): return html.escape(str(value),quote=True)


def _table(mapping):
    return "<table><tbody>{}</tbody></table>".format("".join("<tr><th>{}</th><td>{}</td></tr>".format(_value(key),_value(value)) for key,value in sorted(mapping.items())))


def write_html(path, report):
    rows=[]
    for candidate in report.get("candidates",[]):
        warnings=list(candidate.get("warnings",[]))+list(candidate.get("plan_warnings",[]))
        rows.append("<tr><td>{}</td><td>{}</td><td>{:.3f}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(_value(candidate.get("candidate_id","")),_value(candidate.get("joint_type","")),float(candidate.get("confidence",0.0)),_value(candidate.get("duplicate_status","")),_value(candidate.get("realization_mode","")),_value(candidate.get("plan_status","")),_value("; ".join(warnings))))
    document="""<!doctype html><html><head><meta charset="utf-8"><title>HMWorkFlow Auto Shell Seam</title><style>body{{font-family:Segoe UI,Arial,sans-serif;margin:28px;color:#1f2937}}h1{{margin-bottom:4px}}h2{{margin-top:28px}}table{{border-collapse:collapse;width:100%}}th,td{{border:1px solid #d1d5db;padding:7px 9px;text-align:left;vertical-align:top}}th{{background:#f3f4f6}}code{{background:#f3f4f6;padding:2px 4px}}.note{{color:#6b7280}}</style></head><body><h1>Auto Shell Seam Report</h1><p class="note">Planning audit. HyperMesh execution outcomes are stored in <code>execution_report.json</code>.</p><h2>Summary</h2>{summary}<h2>Python performance (seconds)</h2>{performance}<h2>Candidates</h2><table><thead><tr><th>Candidate</th><th>Type</th><th>Confidence</th><th>Duplicate</th><th>Mode</th><th>Status</th><th>Warnings</th></tr></thead><tbody>{rows}</tbody></table></body></html>""".format(summary=_table(report.get("summary",{})),performance=_table(report.get("performance",{})),rows="".join(rows))
    Path(path).write_text(document,encoding="utf-8")
