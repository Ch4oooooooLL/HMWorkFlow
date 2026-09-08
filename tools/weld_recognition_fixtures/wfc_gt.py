"""Ground-truth construction helpers for the V2 weld-recognition fixtures.

Ground truth is produced only from the analytical case definitions in the
generator.  The production recognizer is never consulted to build these
expectations, so an actual-vs-expected mismatch reports a recognizer defect
instead of a self-fulfilling answer.
"""
from __future__ import annotations

import json
from typing import Any, Dict, List, Optional, Sequence

SOURCE_PATH_TEMPLATE = {
    "expected_node_ids": [],
    "start_xyz": [],
    "end_xyz": [],
    "length": 0.0,
}


def expect_weld(
    *,
    semantic_id: str,
    weld_type: str,
    source_component: str,
    expected_decision: str,
    required_reason_codes: Optional[Sequence[str]] = None,
    required_reason_any: Optional[Sequence[str]] = None,
    forbidden_reason_codes: Optional[Sequence[str]] = None,
    target_components: Optional[Sequence[str]] = None,
    support_runs: Optional[Sequence[Dict[str, Any]]] = None,
    source_path: Optional[Dict[str, Any]] = None,
    forbidden_targets: Optional[Sequence[str]] = None,
    allow_extra_targets: bool = False,
    overlap_axis: str = "X",
    allowed_realization_segments: int = 1,
    geometry_parallel: bool = True,
    known_gap_note: str = "",
    note: str = "",
) -> Dict[str, Any]:
    """One expected physical weld (may span several target components).

    ``geometry_parallel`` declares that the weld chain is expected to run
    parallel to its (flat) target face at a constant gap, which the analytical
    geometry validator asserts.  Welds that legitimately do not (variable
    target thickness, curved / rolled target, an end-edge seam standing against
    a perpendicular plate) set it to False so the validator does not flag the
    intentional topology.

    ``known_gap_note`` documents a *deliberate* mismatch between the spec
    expectation and the current recognizer.  The regression runner reports
    these as informational KNOWN_GAP items instead of failing the fixture, so
    the corpus can encode "this is what V2 must eventually do" without
    pretending the current implementation already does it.
    """
    return {
        "semantic_id": semantic_id,
        "weld_type": weld_type,
        "source_component": source_component,
        "expected_decision": expected_decision,
        "required_reason_codes": list(required_reason_codes or []),
        "required_reason_any": list(required_reason_any or []),
        "forbidden_reason_codes": list(forbidden_reason_codes or []),
        "target_components": list(target_components or []),
        "forbidden_targets": list(forbidden_targets or []),
        "allow_extra_targets": bool(allow_extra_targets),
        "support_runs": [dict(run) for run in (support_runs or [])],
        "source_path": dict(source_path) if source_path else None,
        "overlap_axis": overlap_axis,
        "allowed_realization_segments": int(allowed_realization_segments),
        "geometry_parallel": bool(geometry_parallel),
        "known_gap_note": known_gap_note,
        "note": note,
    }


def forbidden_candidate(
    source_component: str,
    target_component: str,
    severity: str = "FALSE_AUTO_CRITICAL",
    note: str = "",
) -> Dict[str, Any]:
    return {
        "source_component": source_component,
        "target_component": target_component,
        "severity": severity,
        "note": note,
    }


class GroundTruth:
    """Aggregates the expected welds and forbidden relations of one fixture."""

    def __init__(self, case_id: str, case_kind: str, purpose: str, failure_mode: str,
                 decision_policy: Optional[Dict[str, Any]] = None):
        self.case_id = case_id
        self.case_kind = case_kind
        self.purpose = purpose
        self.failure_mode = failure_mode
        self.decision_policy = dict(decision_policy or {})
        self.welds: List[Dict[str, Any]] = []
        self.forbidden: List[Dict[str, Any]] = []
        self.analytic: Dict[str, Any] = {}

    def add_weld(self, weld: Dict[str, Any]) -> "GroundTruth":
        self.welds.append(weld)
        return self

    def add_forbidden(self, row: Dict[str, Any]) -> "GroundTruth":
        self.forbidden.append(row)
        return self

    def add_analytic(self, key: str, value: Any) -> "GroundTruth":
        self.analytic[key] = value
        return self

    def set_source_path(self, semantic_id: str, node_ids: Sequence[int], model,
                        xyz=lambda model, node_id: tuple(model.nodes[node_id].xyz)) -> "GroundTruth":
        """Fill source_path geometry from the ordered node chain built here."""
        for weld in self.welds:
            if weld["semantic_id"] != semantic_id:
                continue
            start = xyz(model, node_ids[0])
            end = xyz(model, node_ids[-1])
            total = 0.0
            for first, second in zip(node_ids, node_ids[1:]):
                a = xyz(model, first)
                b = xyz(model, second)
                total += sum((b[axis] - a[axis]) ** 2 for axis in range(3)) ** 0.5
            weld["source_path"] = {
                "component": weld["source_component"],
                "expected_node_ids": [int(value) for value in node_ids],
                "start_xyz": [float(value) for value in start],
                "end_xyz": [float(value) for value in end],
                "length": round(total, 6),
            }
        return self

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": "1.0",
            "case_id": self.case_id,
            "case_kind": self.case_kind,
            "purpose": self.purpose,
            "failure_mode": self.failure_mode,
            "decision_policy": self.decision_policy,
            "welds": self.welds,
            "forbidden_candidates": self.forbidden,
            "analytic": self.analytic,
        }

    def write(self, path) -> None:
        import os
        Path = __import__("pathlib").Path
        path = Path(path)
        path.write_text(json.dumps(self.to_dict(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
