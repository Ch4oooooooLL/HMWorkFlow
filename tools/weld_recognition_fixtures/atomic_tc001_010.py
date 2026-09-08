"""Atomic weld-recognition fixture cases TC001..TC010.

Each builder returns ``(model, ground_truth, source_chain_hints)`` where
``source_chain_hints`` is a dict mapping semantic source names to the ordered
node-id chain(s) of the intended weld line so the runner can attach the
``source_path`` record without depending on production topology code.
"""
from __future__ import annotations

import math
from typing import Dict, List, Optional, Sequence, Tuple

from geo_helpers import flat_target, vertical_web
from wfc_catalogue import case_id_range
from wfc_gt import GroundTruth, expect_weld, forbidden_candidate
from wfc_model import ModelBuilder


def _source_bottom_x(nx_nodes: int, step: float, x0: float = 50.0) -> List[float]:
    return [x0 + i * step for i in range(nx_nodes)]


def tc001_standard_t(ranges: Dict[str, int]) -> Tuple[object, GroundTruth, Dict[str, List[int]]]:
    """Single standard T on one target: the spec baseline AUTO."""
    b = ModelBuilder(**ranges)
    target, _, _, target_geo = flat_target(b, "TC001_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    web, web_lattice, web_geo = vertical_web(b, "TC001_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    bottom_chain = list(web_lattice[0])
    gt = GroundTruth("TC001", "atomic", "baseline single-target T", "regression canary; the V2 recognizer must auto one clean T")
    gt.add_analytic("target_top_skin_z", target_geo["top_skin_z"])
    gt.add_analytic("source_bottom_z", 5.0)
    gt.add_analytic("expected_physical_gap", 0.0)
    gt.add_weld(expect_weld(
        semantic_id="TC001_W01", weld_type="T", source_component="TC001_SRC_WEB",
        target_components=["TC001_TGT_BASE"], expected_decision="AUTO",
        source_path={"component": "TC001_SRC_WEB", "expected_node_ids": bottom_chain,
                     "start_xyz": list(b.xyz(bottom_chain[0])), "end_xyz": list(b.xyz(bottom_chain[-1])),
                     "length": 300.0},
        note="single continuous target support",
    ))
    return b, gt, {"TC001_SRC_WEB": bottom_chain}


def tc002_midsurface_gap_physical_skin(ranges) -> Tuple[object, GroundTruth, Dict[str, List[int]]]:
    """5 mm midsurface gap but physical skins touch: AUTO."""
    b = ModelBuilder(**ranges)
    target, _, _, target_geo = flat_target(b, "TC002_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    web, web_lattice, _ = vertical_web(b, "TC002_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    bottom_chain = list(web_lattice[0])
    gt = GroundTruth("TC002", "atomic", "physical skin vs midsurface distance",
                     "recognizer using raw midsurface distance would downgrade a perfectly mated T")
    gt.add_weld(expect_weld(
        semantic_id="TC002_W01", weld_type="T", source_component="TC002_SRC_WEB",
        target_components=["TC002_TGT_BASE"], expected_decision="AUTO",
        source_path=None, note="midsurface gap 5 mm; physical gap 0",
    ))
    return b, gt, {"TC002_SRC_WEB": bottom_chain}


def tc003_positive_zoffs(ranges) -> Tuple[object, GroundTruth, Dict[str, List[int]]]:
    """Target ZOFFS +2 with node plane at Z=0: top skin = +7, web bottom at 7."""
    b = ModelBuilder(**ranges)
    target, _, _, target_geo = flat_target(b, "TC003_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0, zoffs=2.0)
    web, web_lattice, _ = vertical_web(b, "TC003_SRC_WEB", 50.0, 350.0, 7.0, 107.0)
    bottom_chain = list(web_lattice[0])
    gt = GroundTruth("TC003", "atomic", "positive ZOFFS places the physical skin off the node plane",
                     "skin offset must follow ZOFFS sign toward the +normal side")
    gt.add_analytic("target_top_skin_z", 7.0)
    gt.add_weld(expect_weld(
        semantic_id="TC003_W01", weld_type="T", source_component="TC003_SRC_WEB",
        target_components=["TC003_TGT_BASE"], expected_decision="AUTO",
        note="top skin = node 0 + ZOFFS 2 + t/2 5 = 7",
    ))
    return b, gt, {"TC003_SRC_WEB": bottom_chain}


def tc004_negative_zoffs(ranges) -> Tuple[object, GroundTruth, Dict[str, List[int]]]:
    """Target ZOFFS -2: top skin = +3, web bottom at 3."""
    b = ModelBuilder(**ranges)
    target, _, _, target_geo = flat_target(b, "TC004_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0, zoffs=-2.0)
    web, web_lattice, _ = vertical_web(b, "TC004_SRC_WEB", 50.0, 350.0, 3.0, 103.0)
    bottom_chain = list(web_lattice[0])
    gt = GroundTruth("TC004", "atomic", "negative ZOFFS places the physical skin below the node plane",
                     "skin offset must follow ZOFFS sign toward the -normal side")
    gt.add_analytic("target_top_skin_z", 3.0)
    gt.add_weld(expect_weld(
        semantic_id="TC004_W01", weld_type="T", source_component="TC004_SRC_WEB",
        target_components=["TC004_TGT_BASE"], expected_decision="AUTO",
        note="top skin = node 0 - 2 + 5 = 3",
    ))
    return b, gt, {"TC004_SRC_WEB": bottom_chain}


def tc005_reversed_target_normals(ranges) -> Tuple[object, GroundTruth, Dict[str, List[int]]]:
    """TC001 geometry with every target element connectivity reversed."""
    b = ModelBuilder(**ranges)
    target, _, _, _ = flat_target(b, "TC005_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0, flip=lambda i, j: True)
    web, web_lattice, _ = vertical_web(b, "TC005_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    bottom_chain = list(web_lattice[0])
    gt = GroundTruth("TC005", "atomic", "all target element normals reversed",
                     "T angle uses abs normal dot; reversed normals must not flip the decision")
    gt.add_weld(expect_weld(
        semantic_id="TC005_W01", weld_type="T", source_component="TC005_SRC_WEB",
        target_components=["TC005_TGT_BASE"], expected_decision="AUTO",
        note="normal sign is irrelevant for the 90 deg T",
    ))
    return b, gt, {"TC005_SRC_WEB": bottom_chain}


def _removed_helper():
    raise NotImplementedError


def tc006_weld_across_two_targets(ranges) -> Tuple[object, GroundTruth, Dict[str, List[int]]]:
    b = ModelBuilder(**ranges)
    flat_target(b, "TC006_TGT_B_A", 0.0, 200.0, -100.0, 100.0, 0.0, 10.0)
    flat_target(b, "TC006_TGT_B_B", 200.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    web, web_lattice, _ = vertical_web(b, "TC006_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    bottom_chain = list(web_lattice[0])
    gt = GroundTruth("TC006", "atomic", "one physical weld across two continuous target components",
                     "must stay one physical weld with two support runs, not two independent welds")
    gt.add_weld(expect_weld(
        semantic_id="TC006_W01", weld_type="T", source_component="TC006_SRC_WEB",
        target_components=["TC006_TGT_B_A", "TC006_TGT_B_B"], expected_decision="AUTO",
        required_reason_codes=["MULTI_TARGET_CONTINUOUS"],
        support_runs=[
            {"component": "TC006_TGT_B_A", "s0": 0.0, "s1": 150.0},
            {"component": "TC006_TGT_B_B", "s0": 150.0, "s1": 300.0},
        ],
        note="B 0-200, C 200-400, shared boundary at X=200",
    ))
    return b, gt, {"TC006_SRC_WEB": bottom_chain}


def tc007_weld_across_three_targets(ranges) -> Tuple[object, GroundTruth, Dict[str, List[int]]]:
    b = ModelBuilder(**ranges)
    flat_target(b, "TC007_TGT_B_A", 0.0, 140.0, -100.0, 100.0, 0.0, 10.0)
    flat_target(b, "TC007_TGT_B_B", 140.0, 260.0, -100.0, 100.0, 0.0, 10.0)
    flat_target(b, "TC007_TGT_B_C", 260.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    web, web_lattice, _ = vertical_web(b, "TC007_SRC_WEB", 40.0, 360.0, 5.0, 105.0)
    bottom_chain = list(web_lattice[0])
    gt = GroundTruth("TC007", "atomic", "one physical weld across three continuous target components",
                     "must not assume at most two targets per source chain")
    gt.add_weld(expect_weld(
        semantic_id="TC007_W01", weld_type="T", source_component="TC007_SRC_WEB",
        target_components=["TC007_TGT_B_A", "TC007_TGT_B_B", "TC007_TGT_B_C"], expected_decision="AUTO",
        required_reason_codes=["MULTI_TARGET_CONTINUOUS"],
        support_runs=[
            {"component": "TC007_TGT_B_A", "s0": 0.0, "s1": 100.0},
            {"component": "TC007_TGT_B_B", "s0": 100.0, "s1": 220.0},
            {"component": "TC007_TGT_B_C", "s0": 220.0, "s1": 320.0},
        ],
        note="targets 0-140 / 140-260 / 260-400; web 40-360",
    ))
    return b, gt, {"TC007_SRC_WEB": bottom_chain}


def tc008_small_gap_1mm(ranges) -> Tuple[object, GroundTruth, Dict[str, List[int]]]:
    """1 mm gap between target components; V2 has no small-gap AUTO bridge."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC008_TGT_B_B", 0.0, 199.5, -100.0, 100.0, 0.0, 10.0)
    flat_target(b, "TC008_TGT_B_C", 200.5, 400.0, -100.0, 100.0, 0.0, 10.0)
    web, web_lattice, _ = vertical_web(b, "TC008_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    bottom_chain = list(web_lattice[0])
    gt = GroundTruth("TC008", "atomic", "1 mm inter-target gap must not merge into a false AUTO",
                     "distance rules must not bridge an element-free void without an explicit policy",
                     decision_policy={"small_gap_auto_bridge": False,
                                      "small_gap_auto_max_mm": 1.0,
                                      "note": "V2 does not emit BRIDGED_SMALL_GAP yet; flip to AUTO once implemented"})
    gt.add_weld(expect_weld(
        semantic_id="TC008_W01", weld_type="T", source_component="TC008_SRC_WEB",
        target_components=["TC008_TGT_B_B", "TC008_TGT_B_C"], expected_decision="REVIEW",
        required_reason_any=["TARGET_GAP", "PARTIAL_COVERAGE"],
        forbidden_reason_codes=["MULTI_TARGET_CONTINUOUS", "BRIDGED_SMALL_GAP"],
        note="1.0 mm element-free void splits the path into two partial REVIEW runs",
    ))
    return b, gt, {"TC008_SRC_WEB": bottom_chain}


def tc009_large_gap(ranges) -> Tuple[object, GroundTruth, Dict[str, List[int]]]:
    """40 mm true fracture splits support: overall candidate must be REVIEW."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC009_TGT_B_B", 0.0, 180.0, -100.0, 100.0, 0.0, 10.0)
    flat_target(b, "TC009_TGT_B_C", 220.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    web, web_lattice, _ = vertical_web(b, "TC009_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    bottom_chain = list(web_lattice[0])
    gt = GroundTruth("TC009", "atomic", "40 mm real fracture must prevent a false AUTO",
                     "overall coverage averaging must not mask a real target gap",
                     decision_policy={"large_gap_auto_bridge": False})
    gt.add_weld(expect_weld(
        semantic_id="TC009_W01", weld_type="T", source_component="TC009_SRC_WEB",
        target_components=["TC009_TGT_B_B", "TC009_TGT_B_C"], expected_decision="REVIEW",
        required_reason_codes=["TARGET_GAP"],
        forbidden_reason_codes=["MULTI_TARGET_CONTINUOUS"],
        note="gap 180..220 = 40 mm; two REVIEW runs must not merge into AUTO",
    ))
    return b, gt, {"TC009_SRC_WEB": bottom_chain}


def tc010_islands_same_component(ranges) -> Tuple[object, GroundTruth, Dict[str, List[int]]]:
    """Two target islands inside the SAME component must be detected as a gap."""
    b = ModelBuilder(**ranges)
    comp_id, _, _, _ = flat_target(b, "TC010_TGT_BASE", 0.0, 180.0, -100.0, 100.0, 0.0, 10.0)
    property_id = b.model.components[comp_id].property_id
    flat_target(b, "TC010_TGT_BASE", 220.0, 400.0, -100.0, 100.0, 0.0, 10.0, reuse=(comp_id, property_id))
    web, web_lattice, _ = vertical_web(b, "TC010_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    bottom_chain = list(web_lattice[0])
    gt = GroundTruth("TC010", "atomic", "two shell islands in one component are not one continuous surface",
                     "same-component != continuous surface; spatial continuity is what matters")
    gt.add_weld(expect_weld(
        semantic_id="TC010_W01", weld_type="T", source_component="TC010_SRC_WEB",
        target_components=["TC010_TGT_BASE"], expected_decision="REVIEW",
        required_reason_any=["TARGET_GAP", "HOLE_INTERRUPTION"],
        forbidden_reason_codes=["MULTI_TARGET_CONTINUOUS"],
        note="40 mm element-free full-width void splits one component into two islands; "
             "current V2 labels it HOLE_INTERRUPTION (taxonomy note, decision REVIEW is the gate)",
    ))
    return b, gt, {"TC010_SRC_WEB": bottom_chain}


ATOMIC_CASES_001_010 = {
    "TC001_standard_t": tc001_standard_t,
    "TC002_midsurface_gap_physical_skin": tc002_midsurface_gap_physical_skin,
    "TC003_positive_zoffs": tc003_positive_zoffs,
    "TC004_negative_zoffs": tc004_negative_zoffs,
    "TC005_reversed_target_normals": tc005_reversed_target_normals,
    "TC006_weld_across_two_targets": tc006_weld_across_two_targets,
    "TC007_weld_across_three_targets": tc007_weld_across_three_targets,
    "TC008_small_gap_1mm": tc008_small_gap_1mm,
    "TC009_large_gap": tc009_large_gap,
    "TC010_islands_same_component": tc010_islands_same_component,
}
