"""Atomic weld-recognition fixture cases TC021..TC030.

Coverage: borderline T angle (70/55 deg), dual/stacked target ambiguity,
self-component island, source inner boundary, non-manifold branch, very short
weld, projection jump.
"""
from __future__ import annotations

import math
from typing import Dict, List, Tuple

from geo_helpers import flat_target, vertical_web
from wfc_gt import GroundTruth, expect_weld
from wfc_model import ModelBuilder


def _web_xs(x0: float, x1: float, h: float) -> List[float]:
    count = max(1, int(round((x1 - x0) / h)))
    return [x0 + i * (x1 - x0) / count for i in range(count + 1)]


def tc021_angle_70(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Source leaning 20 deg off vertical -> T angle 70 -> REVIEW ANGLE_BORDERLINE."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC021_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    web, lattice, _ = vertical_web(b, "TC021_SRC_WEB", 50.0, 350.0, 5.0, 105.0, lean_deg=20.0)
    chain = list(lattice[0])
    gt = GroundTruth("TC021", "atomic", "borderline T angle (70 deg)",
                     "angle gating must route a 70 deg T to REVIEW, not AUTO")
    gt.add_weld(expect_weld(
        semantic_id="TC021_W01", weld_type="T", source_component="TC021_SRC_WEB",
        target_components=["TC021_TGT_BASE"], expected_decision="REVIEW",
        required_reason_codes=["ANGLE_BORDERLINE"],
        note="source plane 20 deg from vertical, bottom still on the target top skin",
    ))
    return b, gt, {"TC021_SRC_WEB": chain}


def tc022_angle_55(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Source leaning 35 deg off vertical -> T angle 55 -> REJECT (no T candidate)."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC022_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    vertical_web(b, "TC022_SRC_WEB", 50.0, 350.0, 5.0, 105.0, lean_deg=35.0)
    gt = GroundTruth("TC022", "atomic", "unsupported shallow T angle (55 deg)",
                     "a near-parallel, physically-close edge must not be welded as a T",
                     decision_policy={"expected_candidate_count": 0})
    gt.add_weld(expect_weld(
        semantic_id="TC022_W01", weld_type="T", source_component="TC022_SRC_WEB",
        target_components=["TC022_TGT_BASE"], expected_decision="REJECT",
        note="55 deg is outside the review band; no T candidate should be emitted",
    ))
    return b, gt, {}


def _stacked(ranges, tag, z_c, c_thickness, web_z0=5.0):
    b = ModelBuilder(**ranges)
    flat_target(b, "{}_B".format(tag), 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    flat_target(b, "{}_C".format(tag), 0.0, 400.0, -100.0, 100.0, z_c, c_thickness)
    web, lattice, _ = vertical_web(b, "{}_SRC_WEB".format(tag), 50.0, 350.0, web_z0, web_z0 + 100.0)
    return b, list(lattice[0])


def tc023_stacked_targets_ambiguous(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Two stacked targets with top skins 5.0 and 5.4, source bottom at 5.0."""
    b, chain = _stacked(ranges, "TC023", 0.4, 10.0)
    gt = GroundTruth("TC023", "atomic", "two stacked targets are both plausible",
                     "ambiguity gating must not weld the nearest layer without review")
    gt.add_weld(expect_weld(
        semantic_id="TC023_W01", weld_type="T", source_component="TC023_SRC_WEB",
        target_components=["TC023_B"], expected_decision="REVIEW",
        required_reason_codes=["TARGET_AMBIGUITY"],
        note="B top skin 5.0, C top skin 5.4; both within the search radius",
    ))
    return b, gt, {"TC023_SRC_WEB": chain}


def tc024_better_target_with_distractor(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Real target at zero error, worse distractor at ~8 mm error."""
    b, chain = _stacked(ranges, "TC024", 8.0, 10.0)
    gt = GroundTruth("TC024", "atomic", "a clearly better target must win over a weak distractor",
                     "over-conservative ambiguity must not downgrade an unambiguous best target")
    gt.add_weld(expect_weld(
        semantic_id="TC024_W01", weld_type="T", source_component="TC024_SRC_WEB",
        target_components=["TC024_B"], expected_decision="AUTO",
        known_gap_note="V2 REVIEWs when any sample also sees the 8 mm distractor inside the broad search "
                       "radius (ambiguity margin). Spec expects AUTO on B.",
        note="B error ~0; C error ~8 mm but still inside the broad search radius",
    ))
    return b, gt, {"TC024_SRC_WEB": chain}


def tc025_duplicate_coincident_targets(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Two fully coincident target plates below the weld line."""
    b, chain = _stacked(ranges, "TC025", 0.0, 10.0)
    gt = GroundTruth("TC025", "atomic", "fully coincident duplicate target plates are ambiguous",
                     "two identical physical targets under one weld line must go to REVIEW",
                     decision_policy={"order_independent": True})
    gt.add_weld(expect_weld(
        semantic_id="TC025_W01", weld_type="T", source_component="TC025_SRC_WEB",
        target_components=["TC025_B"], expected_decision="REVIEW",
        required_reason_codes=["TARGET_AMBIGUITY"],
        note="B and C coincide exactly; V2 REVIEWs the seam toward B and lists the "
             "coincident duplicate C only in a separate PATCH_SEAM REVIEW row, so the "
             "physical stack is never AUTO-welded even though one T row names a single target",
    ))
    return b, gt, {"TC025_SRC_WEB": chain}


def tc026_same_component_false_t(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Source and target islands inside the same component (no auto self-T)."""
    b = ModelBuilder(**ranges)
    cid, pid = b.new_component("TC026_SAME", 10.0)
    flat_target(b, "TC026_SAME", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0, reuse=(cid, pid))
    xs = _web_xs(50.0, 350.0, 10.0)
    rows = ([b.node((x, 0.0, 5.0)) for x in xs], [b.node((x, 0.0, 105.0)) for x in xs])
    for i in range(len(xs) - 1):
        b.quad(cid, pid, (rows[0][i], rows[0][i + 1], rows[1][i + 1], rows[1][i]))
    gt = GroundTruth("TC026", "atomic", "source and target islands inside one component",
                     "allow_self_component_target=false: no AUTO for a same-component T",
                     decision_policy={"allow_self_component_target": False})
    gt.add_weld(expect_weld(
        semantic_id="TC026_W01", weld_type="T", source_component="TC026_SAME",
        target_components=["TC026_SAME"], expected_decision="REJECT",
        note="web island and target island share one component; the recognizer must not AUTO a self-T",
    ))
    return b, gt, {}


def tc027_source_inner_boundary(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A closed slot whose inner rim (z=55) geometrically resembles a perfect T."""
    b = ModelBuilder(**ranges)
    # source: vertical plate x=0..400, y=0, z=0..120 with a closed horizontal
    # slot x=120..280, z=45..55.  The slot's top inner rim (z=55) lies exactly on
    # the shelf top skin, but an inner source boundary must never be AUTO.
    cid, pid = b.new_component("TC027_SRC_PLATE", 6.0)
    xs = _web_xs(0.0, 400.0, 10.0)
    zs = [z * 5.0 for z in range(0, 25)]  # 0..120 step 5
    rows = {zi: [b.node((x, 0.0, z)) for x in xs] for zi, z in enumerate(zs)}
    for zi in range(len(zs) - 1):
        for i in range(len(xs) - 1):
            if 120.0 <= xs[i] < 280.0 and 45.0 <= zs[zi] < 55.0:
                continue  # inside the closed slot footprint
            b.quad(cid, pid, (rows[zi][i], rows[zi][i + 1], rows[zi + 1][i + 1], rows[zi + 1][i]))
    # the closed slot's top inner rim (z=55) and bottom inner rim (z=45)
    slot_first_x = xs.index(120.0)
    slot_last_x = xs.index(280.0)
    top_rim = rows[zs.index(55.0)][slot_first_x:slot_last_x + 1]
    bottom_rim = rows[zs.index(45.0)][slot_first_x:slot_last_x + 1]
    # shelf: horizontal plate whose top/bottom skins (z=55 / z=45) exactly meet
    # both closed-slot rims inside the slot footprint
    flat_target(b, "TC027_TGT_SHELF", 120.0, 280.0, -100.0, 100.0, 50.0, 10.0)
    gt = GroundTruth("TC027", "atomic", "source inner boundary (closed slot rim) flush with a target",
                     "an inner source boundary must be REVIEW INNER_BOUNDARY_SOURCE, never AUTO",
                     decision_policy={"closed_loop_inner_rim": "never_auto"})
    gt.add_weld(expect_weld(
        semantic_id="TC027_W01", weld_type="T", source_component="TC027_SRC_PLATE",
        target_components=["TC027_TGT_SHELF"], expected_decision="REVIEW",
        source_path={"expected_node_ids": [int(value) for value in top_rim]},
        required_reason_any=["INNER_BOUNDARY_SOURCE"],
        note="top slot rim at z=55 lies exactly on the shelf top skin.  The edge is an inner "
             "boundary of a closed slot, so it must not be AUTO welded.",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC027_W02", weld_type="T", source_component="TC027_SRC_PLATE",
        target_components=["TC027_TGT_SHELF"], expected_decision="REVIEW",
        source_path={"expected_node_ids": [int(value) for value in bottom_rim]},
        required_reason_any=["INNER_BOUNDARY_SOURCE"],
        note="bottom slot rim at z=45 lies exactly on the shelf bottom skin; same inner-boundary policy.",
    ))
    gt.add_analytic("rim_z", {"top": 55.0, "bottom": 45.0, "slot_x": [120.0, 280.0]})
    return b, gt, {}


def tc028_non_manifold_branch(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A source free-edge chain carrying a branch junction near a target."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC028_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    cid, pid = b.new_component("TC028_SRC_BRANCH", 6.0)
    xs = _web_xs(50.0, 350.0, 10.0)
    # main vertical web (y=0, z=5..105)
    bot = [b.node((x, 0.0, 5.0)) for x in xs]
    top = [b.node((x, 0.0, 105.0)) for x in xs]
    for i in range(len(xs) - 1):
        b.quad(cid, pid, (bot[i], bot[i + 1], top[i + 1], top[i]))
    # a horizontal fin sharing the middle bottom node, making the free-edge graph branch
    mid_x = 200.0
    mid_index = xs.index(mid_x)
    fin = [b.node((mid_x - 20.0, 15.0, 5.0)), b.node((mid_x + 20.0, 15.0, 5.0))]
    # two quads from the bottom edge segment around mid to the fin edge
    left_mid = bot[mid_index - 1]
    right_mid = bot[mid_index + 1] if mid_index + 1 < len(bot) else bot[mid_index]
    b.quad(cid, pid, (left_mid, bot[mid_index], fin[1], fin[0]))
    b.quad(cid, pid, (bot[mid_index], right_mid, fin[1], fin[0]))
    run_a = [int(value) for value in bot[:mid_index]]           # x=50..190
    run_b = [int(value) for value in bot[mid_index + 1:]]       # x=210..350
    gt = GroundTruth("TC028", "atomic", "branching source free-edge chain near a target",
                     "a branched boundary must not be fused into one straight T chain")
    gt.add_weld(expect_weld(
        semantic_id="TC028_W01", weld_type="T", source_component="TC028_SRC_BRANCH",
        target_components=["TC028_TGT_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": run_a},
        note="clean run x=50..190 ending at the folded-fin zone; the boundary forks "
             "there so the run is a legitimate independent weld, not part of one long chain",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC028_W02", weld_type="T", source_component="TC028_SRC_BRANCH",
        target_components=["TC028_TGT_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": run_b},
        note="clean run x=210..350 after the branch zone; same reasoning as W01",
    ))
    gt.add_analytic("zone_notes", {
        "branch_fork_x": 200.0,
        "occupied_zone_x": [190.0, 210.0],
        "expected_candidate_gap": "no candidate may span across x=190..210 where the folded fin occupies the base",
        "branch_reason": "V2 has no NON_MANIFOLD_REGION/BOUNDARY_BRANCH reason on T rows; "
                         "the seam is instead split into two independent AUTO runs",
    })
    return b, gt, {}


def tc029_very_short_weld(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A geometrically perfect but very short (14 mm) weld candidate."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC029_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    # 14 mm is above the review floor (15 * 0.75 = 11.25) yet below the 15 mm
    # automatic length gate, so a single REVIEW SHORT_WELD row must appear.
    web, lattice, _ = vertical_web(b, "TC029_SRC_WEB", 100.0, 114.0, 5.0, 105.0, h=10.0)
    chain = list(lattice[0])
    gt = GroundTruth("TC029", "atomic", "very short weld (14 mm)",
                     "mesh notches and tiny edges must be REVIEW, not AUTO")
    gt.add_weld(expect_weld(
        semantic_id="TC029_W01", weld_type="T", source_component="TC029_SRC_WEB",
        target_components=["TC029_TGT_BASE"], expected_decision="REVIEW",
        required_reason_codes=["SHORT_WELD"],
        note="a 14 mm perfect edge is below the minimum automatic seam length but above the review floor",
    ))
    return b, gt, {"TC029_SRC_WEB": chain}


def tc030_projection_jump(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Two plausible target runs with an abrupt 10 mm skin step between them."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC030_B", 0.0, 190.0, -100.0, 100.0, 0.0, 10.0)
    flat_target(b, "TC030_C", 210.0, 400.0, -100.0, 100.0, 10.0, 10.0)
    # source web drops from z=5 over B to z=15 over C, leaving a 20 mm gap
    xs = _web_xs(50.0, 190.0, 10.0) + [200.0] + _web_xs(210.0, 350.0, 10.0)
    cid, pid = b.new_component("TC030_SRC_WEB", 6.0)
    rows = ([], [])
    for x in xs:
        z0 = 5.0 if x <= 195.0 else 15.0
        rows[0].append(b.node((x, 0.0, z0)))
        rows[1].append(b.node((x, 0.0, z0 + 100.0)))
    for i in range(len(xs) - 1):
        b.quad(cid, pid, (rows[0][i], rows[0][i + 1], rows[1][i + 1], rows[1][i]))
    run_b = [int(node_id) for x, node_id in zip(xs, rows[0]) if x <= 190.0]
    run_c = [int(node_id) for x, node_id in zip(xs, rows[0]) if x >= 210.0]
    gt = GroundTruth("TC030", "atomic", "projection jump at a target transition",
                     "a discontinuous projected path must be REVIEW, not a continuous AUTO")
    gt.add_weld(expect_weld(
        semantic_id="TC030_W01", weld_type="T", source_component="TC030_SRC_WEB",
        target_components=["TC030_B"], expected_decision="REVIEW",
        required_reason_codes=["TARGET_GAP", "PROJECTION_JUMP"],
        forbidden_reason_codes=["MULTI_TARGET_CONTINUOUS"],
        known_gap_note="V2 runs edge-level grouping per component, so the clean B-side "
                       "segment (x=50..190, continuous, no gaps) is emitted AUTO and only "
                       "the C side with the element-free gap is downgraded to REVIEW "
                       "PARTIAL_COVERAGE.  Spec wants the whole weld REVIEW because one "
                       "physical seam faces a discontinuous support step; a future V2 must "
                       "see the 20 mm dead zone between the two skins and gate the joint.",
        source_path={"expected_node_ids": [int(value) for value in run_b]},
        note="B skin at z=5 spans x=0..190 and the web bottom rides it at z=5 from x=50..190",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC030_W02", weld_type="T", source_component="TC030_SRC_WEB",
        target_components=["TC030_C"], expected_decision="REVIEW",
        required_reason_any=["TARGET_GAP", "PARTIAL_COVERAGE", "PROJECTION_JUMP"],
        forbidden_reason_codes=["MULTI_TARGET_CONTINUOUS"],
        source_path={"expected_node_ids": [int(value) for value in run_c]},
        note="C skin at z=15 spans x=210..400 and the web bottom jumps to z=15 from x=210..350",
    ))
    gt.add_analytic("zone_notes", {
        "B_skin_z": 5.0, "C_skin_z": 15.0, "dead_gap_x": [190.0, 210.0],
        "source_z": {"x<=195": 5.0, "x>=205": 15.0},
    })
    return b, gt, {"TC030_SRC_WEB": [int(value) for value in run_b + run_c]}


ATOMIC_CASES_021_030 = {
    "TC021_angle_70": tc021_angle_70,
    "TC022_angle_55": tc022_angle_55,
    "TC023_stacked_targets_ambiguous": tc023_stacked_targets_ambiguous,
    "TC024_better_target_with_distractor": tc024_better_target_with_distractor,
    "TC025_duplicate_coincident_targets": tc025_duplicate_coincident_targets,
    "TC026_same_component_false_t": tc026_same_component_false_t,
    "TC027_source_inner_boundary": tc027_source_inner_boundary,
    "TC028_non_manifold_branch": tc028_non_manifold_branch,
    "TC029_very_short_weld": tc029_very_short_weld,
    "TC030_projection_jump": tc030_projection_jump,
}
