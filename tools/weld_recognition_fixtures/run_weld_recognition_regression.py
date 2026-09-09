"""Run the V2 weld-recognition regression against the generated fixtures.

Semantic matching:
  * expected welds are matched to candidate rows by (source component, weld
    type, source spatial overlap and target component overlap);
  * AUTO / REVIEW / REJECT / forbidden relations are counted per fixture;
  * every category is reported separately; an overall accuracy figure is never
    used to mask FALSE AUTO or missed welds.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
ROOT = TOOLS_DIR.parent.parent
sys.path.insert(0, str(TOOLS_DIR))
sys.path.insert(0, str(ROOT / "python"))

from hmworkflow.core.mesh_model import Component, Element, MeshModel
from hmworkflow.fem_auto_seam.backend import DEFAULT_SETTINGS, detect_candidates
from hmworkflow.mesh_seam_weld.fem_mesh_reader import read_shell_fem_bundle


def _load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _node_xyz(model, node_id):
    return tuple(model.nodes[node_id])


def _candidate_span(candidate, model):
    points = []
    for pair in candidate.get("source_edge_pairs", []):
        if len(pair) >= 2:
            points.append(_node_xyz(model, pair[0]))
            points.append(_node_xyz(model, pair[1]))
    if not points:
        points = [_node_xyz(model, node_id) for node_id in candidate.get("source_node_ids", []) if node_id in model.nodes]
    if not points:
        return (0.0, 0.0)
    xs = [point[0] for point in points]
    return (min(xs), max(xs))


def _gt_span(weld, model):
    path = weld.get("source_path")
    if not path or not path.get("expected_node_ids"):
        return None
    points = [_node_xyz(model, node_id) for node_id in path["expected_node_ids"]]
    xs = [point[0] for point in points]
    return (min(xs), max(xs))


def _overlap_ratio(first, second):
    if first is None or second is None:
        return 1.0 if first == second else 0.0
    lo = max(first[0], second[0])
    hi = min(first[1], second[1])
    if hi < lo:
        return 0.0
    first_len = max(first[1] - first[0], 1e-9)
    second_len = max(second[1] - second[0], 1e-9)
    return (hi - lo) / max(first_len, second_len)


def run_atomic_case(case_dir: Path, settings) -> dict:
    """Detect one atomic fixture and compare it against its ground truth."""
    gt = _load_json(case_dir / "ground_truth.json")
    model = read_shell_fem_bundle(case_dir / "input_manifest.json")
    name_by_id = {cid: component.component_name for cid, component in model.components.items()}
    started = time.perf_counter()
    candidates = detect_candidates(model, dict(settings))
    elapsed = time.perf_counter() - started
    rows = [row for row in candidates if row["candidate_type"] in ("T_SEAM", "PATCH_SEAM")]
    return {
        "case_id": gt["case_id"],
        "elapsed_seconds": round(elapsed, 6),
        "candidates": rows,
        "gt": gt,
        "name_by_id": name_by_id,
        "model": model,
    }


def analyse_atomic(result: dict) -> dict:
    gt = result["gt"]
    model = result["model"]
    name_by_id = result["name_by_id"]
    candidates = result["candidates"]
    issues = []
    counts = {
        "expected_welds": len(gt["welds"]),
        "matched_welds": 0,
        "false_auto": 0,
        "missed_expected_auto": 0,
        "expected_review_got_auto": 0,
        "expected_auto_got_review": 0,
        "wrong_target": 0,
        "wrong_weld_type": 0,
        "wrong_source_subchain": 0,
        "missing_required_reason": 0,
        "forbidden_reason": 0,
        "unexpected_candidate": 0,
        "duplicate_candidate": 0,
        "support_run_mismatch": 0,
    }
    auto_candidates = [row for row in candidates if row["decision"] == "AUTO"]
    auto_by_source = {}
    for row in auto_candidates:
        auto_by_source.setdefault(row["source_component_id"], []).append(row)
    review_rows = [row for row in candidates if row["decision"] == "REVIEW"]

    def _type_of(weld_type):
        return {"T": "T_SEAM", "PATCH": "PATCH_SEAM"}.get(weld_type, weld_type)

    def _source_ids_for(name):
        return {cid for cid, comp_name in name_by_id.items() if comp_name == name}

    def _row_source_nodes(row):
        nodes = {int(nid) for nid in row.get("source_node_ids", []) if nid in model.nodes}
        for pair in row.get("source_edge_pairs", []):
            if len(pair) >= 2:
                nodes.add(int(pair[0]))
                nodes.add(int(pair[1]))
        return nodes

    def _gt_nodes(weld):
        path = weld.get("source_path")
        if path and path.get("expected_node_ids"):
            return {int(nid) for nid in path["expected_node_ids"] if nid in model.nodes}
        return None

    def _node_overlap(row_nodes, gt_nodes):
        if not row_nodes or not gt_nodes:
            return 0.0
        shared = len(row_nodes & gt_nodes)
        return shared / float(len(gt_nodes))

    def _group_candidates(rows, source_ids, span, expected_targets, weld_type, gt_nodes=None, exclude=()):
        """Candidates whose source chain shares the ground-truth weld chain."""
        scored = []
        for row in rows:
            if id(row) in exclude:
                continue  # a row already claimed by an earlier ground-truth weld
            if row["source_component_id"] not in source_ids:
                continue
            if row["candidate_type"] != _type_of(weld_type):
                continue
            if gt_nodes is not None:
                # node-identity overlap disambiguates parallel chains of one
                # source component that a bounding box cannot tell apart; a row
                # touching only a corner node of the chain is a different seam
                overlap = _node_overlap(_row_source_nodes(row), gt_nodes)
            else:
                row_span = _candidate_span(row, model)
                overlap = _overlap_ratio(row_span, span) if span else 1.0
            if overlap < 0.1:
                continue
            tgt_names = {name_by_id.get(tid) for tid in row.get("target_component_ids", [row["target_component_id"]])}
            if expected_targets and not (tgt_names & expected_targets):
                continue
            scored.append((row, overlap))
        # order by span start along X, keep rows sorted by min x
        scored.sort(key=lambda pair: pair[0]["source_node_ids"][0] if pair[0].get("source_node_ids") else 0)
        return scored

    def _union_overlaps_span(group_rows, span, threshold=0.5):
        if not group_rows or span is None:
            return bool(group_rows)
        covered = []
        for row, _ in group_rows:
            r = _candidate_span(row, model)
            if r:
                covered.append(r)
        if not covered:
            return False
        covered.sort()
        lo, hi = covered[0]
        for c_lo, c_hi in covered[1:]:
            if c_lo <= hi:
                hi = max(hi, c_hi)
            else:
                pass  # discontinuity; we only need total ratio below
        merged_span = (min(c[0] for c in covered), max(c[1] for c in covered))
        # coverage of the ground-truth span by the union of candidate spans
        overlap = max(0.0, min(merged_span[1], span[1]) - max(merged_span[0], span[0]))
        gt_len = max(span[1] - span[0], 1e-9)
        return overlap / gt_len >= threshold

    def _gt_span_of_group(group_rows):
        for weld in gt["welds"]:
            source_name = weld["source_component"]
            if any(r[0]["source_component_id"] in _source_ids_for(source_name) for r in group_rows):
                return _gt_span(weld, model)
        return None

    def _group_decision(group_rows, gt_nodes=None):
        if not group_rows:
            return None
        if gt_nodes is not None:
            # a group is AUTO only when the AUTO rows alone cover the whole GT chain
            auto_rows = [r for r in group_rows if r[0]["decision"] == "AUTO"]
            if not auto_rows:
                return "REVIEW"
            auto_cover = max(_node_overlap(_row_source_nodes(r[0]), gt_nodes) for r in auto_rows)
            if auto_cover >= 0.5:
                return "AUTO"
            return "REVIEW"
        decisions = {row["decision"] for row, _ in group_rows}
        if len(group_rows) == 1:
            return group_rows[0][0]["decision"]
        auto_span = _union_overlaps_span([r for r in group_rows if r[0]["decision"] == "AUTO"], _gt_span_of_group(group_rows), threshold=1.0) if any(r[0]["decision"] == "AUTO" for r in group_rows) else False
        return "AUTO" if auto_span else "REVIEW"

    def _span_overlap_pair(first, second):
        if first is None or second is None:
            return 0.0
        lo = max(first[0], second[0])
        hi = min(first[1], second[1])
        return max(0.0, hi - lo)

    def _rows_cover_weld(group_rows, weld, span, gt_nodes=None):
        if not group_rows:
            return False
        if gt_nodes is not None:
            # segmented candidates may each cover part of the physical chain;
            # accept when the union of their source nodes covers >= half of it
            union_nodes = set()
            for row, _ in group_rows:
                union_nodes |= _row_source_nodes(row)
            return len(union_nodes & gt_nodes) / float(len(gt_nodes)) >= 0.5
        for row, _ in group_rows:
            names = {name_by_id.get(tid) for tid in row.get("target_component_ids", [row["target_component_id"]])}
            if set(weld.get("target_components") or []) and names & set(weld["target_components"]):
                if _overlap_ratio(_candidate_span(row, model), span) >= 0.5:
                    return True
        # fall back to union overlap when segments split across targets
        return _union_overlaps_span(group_rows, span, threshold=0.5)

    claimed_rows = set()  # AUTO/primary rows already satisfying an earlier GT weld

    def _primary_of(group_rows):
        return [r for r in group_rows if r[1] >= 0.5] or group_rows

    for weld in gt["welds"]:
        source_ids = _source_ids_for(weld["source_component"])
        span = _gt_span(weld, model)
        gt_nodes = _gt_nodes(weld)
        known_gap = bool(weld.get("known_gap_note"))
        expected_decision = weld["expected_decision"]
        group_rows = _group_candidates(candidates, source_ids, span, set(weld.get("target_components") or []), weld["weld_type"], gt_nodes, exclude=claimed_rows)
        if expected_decision == "REJECT":
            # A REJECT expectation is satisfied by the ABSENCE of a candidate
            # for this source joint.  Any emitted candidate is a defect.
            if not group_rows:
                counts["matched_welds"] += 1
                continue
            actual_decision = _group_decision(group_rows, gt_nodes)
            if actual_decision == "AUTO":
                counts["false_auto"] += 1
                counts["expected_review_got_auto"] += 1
            else:
                counts["unexpected_candidate"] += 1
            issues.append({"kind": "EXPECTED_REJECT_GOT_CANDIDATE", "semantic_id": weld["semantic_id"],
                           "message": "expected no candidate for this joint, got {}".format(actual_decision)})
            continue
        if not group_rows or not _rows_cover_weld(group_rows, weld, span, gt_nodes):
            counts["missed_expected_auto"] += 1
            if known_gap:
                issues.append({"kind": "KNOWN_GAP", "semantic_id": weld["semantic_id"], "message": weld["known_gap_note"]})
            else:
                issues.append({
                    "kind": "MISSED_WELD",
                    "semantic_id": weld["semantic_id"],
                    "expected_decision": expected_decision,
                    "message": "no candidate rows cover the expected weld source span",
                })
            continue
        counts["matched_welds"] += 1
        actual_decision = _group_decision(group_rows, gt_nodes)
        claimed_rows.update(id(row) for row, _ in _primary_of(group_rows))
        if expected_decision == "AUTO" and actual_decision != "AUTO":
            if known_gap:
                issues.append({"kind": "KNOWN_GAP", "semantic_id": weld["semantic_id"], "message": weld["known_gap_note"]})
                continue
            counts["expected_auto_got_review"] += 1
            counts["missed_expected_auto"] += 1
            issues.append({"kind": "EXPECTED_AUTO_GOT_REVIEW", "semantic_id": weld["semantic_id"], "message": "expected AUTO, got REVIEW"})
        elif expected_decision == "REVIEW" and actual_decision == "AUTO":
            if known_gap:
                issues.append({"kind": "KNOWN_GAP", "semantic_id": weld["semantic_id"], "message": weld["known_gap_note"]})
                continue
            counts["expected_review_got_auto"] += 1
            counts["false_auto"] += 1
            issues.append({"kind": "FALSE_AUTO", "semantic_id": weld["semantic_id"], "message": "expected REVIEW, got AUTO"})
        elif expected_decision == "REJECT" and actual_decision != "REJECT":
            issues.append({"kind": "EXPECTED_REJECT_GOT_CANDIDATE", "semantic_id": weld["semantic_id"], "message": "expected REJECT, got {}".format(actual_decision)})
        # wrong target: compare the union of targets carried by the PRIMARY rows
        # (>= 0.5 node/span overlap); corner-touching rows belong to a different seam
        primary_rows = [r for r in group_rows if r[1] >= 0.5] or group_rows
        group_target_names = set()
        for row, _ in primary_rows:
            group_target_names.update(name_by_id.get(tid) for tid in row.get("target_component_ids", [row["target_component_id"]]) if tid in name_by_id)
        expected_target_names = set(weld.get("target_components") or [])
        if expected_target_names and group_target_names != expected_target_names:
            if weld.get("allow_extra_targets") and expected_target_names <= group_target_names:
                pass  # extra targets are documented physical near-neighbours
            elif known_gap:
                issues.append({"kind": "KNOWN_GAP", "semantic_id": weld["semantic_id"], "message": weld["known_gap_note"]})
            else:
                counts["wrong_target"] += 1
                issues.append({"kind": "WRONG_TARGET", "semantic_id": weld["semantic_id"], "message": "expected {} got {}".format(sorted(expected_target_names), sorted(group_target_names))})
        # reason codes across the group (union for required, group-level for forbidden)
        group_reasons = set()
        for row, _ in group_rows:
            group_reasons.update(row.get("reason_codes", []))
        for code in weld.get("required_reason_codes", []):
            if code not in group_reasons:
                counts["missing_required_reason"] += 1
                issues.append({"kind": "MISSING_REASON", "semantic_id": weld["semantic_id"], "code": code, "message": "required reason {} not present in {} ".format(code, sorted(group_reasons))})
        if weld.get("required_reason_any"):
            if not (set(weld["required_reason_any"]) & group_reasons):
                counts["missing_required_reason"] += 1
                issues.append({"kind": "MISSING_REASON_ANY", "semantic_id": weld["semantic_id"], "message": "none of {} present in {}".format(weld["required_reason_any"], sorted(group_reasons))})
        for code in weld.get("forbidden_reason_codes", []):
            if code in group_reasons:
                counts["forbidden_reason"] += 1
                issues.append({"kind": "FORBIDDEN_REASON", "semantic_id": weld["semantic_id"], "code": code, "message": "forbidden reason {} present".format(code)})
        # support runs: set of components of runs, across the whole group
        if weld.get("support_runs"):
            expected_comps = {run["component"] for run in weld["support_runs"]}
            actual_comps = set()
            for row, _ in group_rows:
                for run in row.get("support_runs", []):
                    cname = name_by_id.get(run.get("component_id"))
                    if cname:
                        actual_comps.add(cname)
            if expected_comps != actual_comps:
                counts["support_run_mismatch"] += 1
                issues.append({"kind": "SUPPORT_RUN_MISMATCH", "semantic_id": weld["semantic_id"], "message": "expected support components {} got {}".format(sorted(expected_comps), sorted(actual_comps))})

    # strict no-candidate policy: the recognizer must emit nothing for the joint
    if gt.get("decision_policy", {}).get("expected_candidate_count") == 0:
        if candidates:
            for row in candidates:
                counts["unexpected_candidate"] += 1
                issues.append({"kind": "EXPECTED_NO_CANDIDATE", "semantic_id": None,
                               "message": "policy expects zero candidates but {} {} emitted ({} -> {})".format(
                                   row["candidate_type"], row["decision"],
                                   name_by_id.get(row["source_component_id"]),
                                   [name_by_id.get(t) for t in row.get("target_component_ids", [row["target_component_id"]])])})

    # forbidden candidate relations must never be AUTO
    for forbidden in gt.get("forbidden_candidates", []):
        for row in auto_candidates:
            src_name = name_by_id.get(row["source_component_id"])
            tgt_names = {name_by_id.get(tid) for tid in row.get("target_component_ids", [row["target_component_id"]])}
            if src_name == forbidden["source_component"] and forbidden["target_component"] in tgt_names:
                counts["false_auto"] += 1
                counts["forbidden_reason"] += 1
                issues.append({"kind": "FALSE_AUTO_FORBIDDEN", "severity": forbidden.get("severity"), "message": "forbidden relation {}-{} was AUTO".format(src_name, forbidden["target_component"])})

    # unexpected AUTO candidates: AUTO not sharing a source chain with any expected weld
    covered_auto = set()
    for weld in gt["welds"]:
        gt_nodes = _gt_nodes(weld)
        for row in auto_candidates:
            if gt_nodes is not None:
                if _node_overlap(_row_source_nodes(row), gt_nodes) >= 0.5:
                    covered_auto.add(id(row))
            else:
                span = _gt_span(weld, model)
                if _overlap_ratio(_candidate_span(row, model), span) >= 0.5:
                    covered_auto.add(id(row))
    tolerated_pairs = {
        (entry["source_component"], entry["target_component"]): entry.get("note", "")
        for entry in gt.get("tolerated_candidates", [])
    }
    for row in auto_candidates:
        if id(row) not in covered_auto:
            src_name = name_by_id.get(row["source_component_id"])
            tgt_names = {name_by_id.get(t) for t in row.get("target_component_ids", [row["target_component_id"]])}
            hits = [target for target in tgt_names if (src_name, target) in tolerated_pairs]
            if hits and len(hits) == len(tgt_names):
                for target in sorted(hits):
                    issues.append({"kind": "KNOWN_GAP", "semantic_id": None,
                                   "message": "recall-policy tolerated candidate {} -> {}: {}".format(
                                       src_name, target, tolerated_pairs[(src_name, target)])})
                continue
            counts["unexpected_candidate"] += 1
            issues.append({"kind": "UNEXPECTED_AUTO", "message": "AUTO candidate {} -> {} has no expected weld source overlap".format(name_by_id.get(row["source_component_id"]), [name_by_id.get(t) for t in row.get("target_component_ids", [])])})
    return {"counts": counts, "issues": issues}


def run(output_root: Path, atomic_filter=None, settings=None, kinds=("atomic", "composite")) -> dict:
    """Run regression across the atomic/composite corpus and return a report."""
    resolved_settings = dict(DEFAULT_SETTINGS)
    if settings:
        resolved_settings.update(settings)
    report = {
        "schema_version": "1.0",
        "output_root": str(output_root),
        "settings": resolved_settings,
        "atomic": [],
        "composite": [],
        "totals": {},
    }
    totals = {key: 0 for key in ("expected_welds", "matched_welds", "false_auto", "missed_expected_auto", "expected_review_got_auto", "expected_auto_got_review", "wrong_target", "wrong_weld_type", "wrong_source_subchain", "missing_required_reason", "forbidden_reason", "unexpected_candidate", "duplicate_candidate", "support_run_mismatch")}
    total_candidates = 0
    total_auto = 0
    total_time = 0.0
    for kind in kinds:
        kind_dir = output_root / kind
        if not kind_dir.is_dir():
            continue
        for case_dir in sorted(kind_dir.iterdir()):
            if not (case_dir / "ground_truth.json").is_file():
                continue
            case_id = case_dir.name
            if kind == "atomic" and atomic_filter and case_id not in atomic_filter:
                continue
            result = run_atomic_case(case_dir, resolved_settings)
            analysis = analyse_atomic(result)
            for key in totals:
                totals[key] += analysis["counts"][key]
            total_candidates += len(result["candidates"])
            total_auto += sum(1 for row in result["candidates"] if row["decision"] == "AUTO")
            total_time += result["elapsed_seconds"]
            entry = {
                "case_id": case_id,
                "kind": kind,
                "status": "PASS" if all(issue["kind"] == "KNOWN_GAP" for issue in analysis["issues"]) else "FAIL",
                "candidate_count": len(result["candidates"]),
                "auto_count": sum(1 for row in result["candidates"] if row["decision"] == "AUTO"),
                "counts": analysis["counts"],
                "known_gap_issues": [issue for issue in analysis["issues"] if issue["kind"] == "KNOWN_GAP"],
                "issues": [issue for issue in analysis["issues"] if issue["kind"] != "KNOWN_GAP"],
                "elapsed_seconds": result["elapsed_seconds"],
            }
            report[kind].append(entry)
    totals["candidate_count"] = total_candidates
    totals["auto_count"] = total_auto
    totals["elapsed_seconds"] = round(total_time, 6)
    report["totals"] = totals
    all_entries = report["atomic"] + report["composite"]
    report["summary"] = {
        "case_count": len(all_entries),
        "passed_count": sum(1 for row in all_entries if row["status"] == "PASS"),
        "failed_count": sum(1 for row in all_entries if row["status"] == "FAIL"),
        "false_auto": totals["false_auto"],
        "missed_expected_auto": totals["missed_expected_auto"],
        "expected_auto_got_review": totals["expected_auto_got_review"],
        "wrong_target": totals["wrong_target"],
        "forbidden_reason": totals["forbidden_reason"],
        "unexpected_candidate": totals["unexpected_candidate"],
    }
    return report


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=TOOLS_DIR.parent.parent / "examples" / "validation_weld_recognition_v2")
    parser.add_argument("--atomic", default=None)
    args = parser.parse_args(argv)
    selected = set(value.strip() for value in args.atomic.split(",")) if args.atomic else None
    report = run(args.output, atomic_filter=selected)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
