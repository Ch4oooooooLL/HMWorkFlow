"""Atomic weld-recognition fixture cases TC041..TC048.

Coverage: weld-on-weld dependency (TC041), multi-web junction (TC042),
dependency-cycle trap (TC043), parallel near-skin plate (TC044), oblique /
diagonal weld line (TC045), coplanar butt joint (TC046), wrap-around L corner
(TC047), and a near-skin equipment bracket distractor (TC048).
"""
from __future__ import annotations

import math
from typing import Dict, List, Tuple

from geo_helpers import flat_target, vertical_web
from wfc_gt import GroundTruth, expect_weld, forbidden_candidate
from wfc_model import ModelBuilder


def _web_rows_xz(b, component_id, property_id, xs, z0, z1, y=0.0):
    bottom = [b.node((x, y, z0)) for x in xs]
    top = [b.node((x, y, z1)) for x in xs]
    for i in range(len(xs) - 1):
        b.quad(component_id, property_id, (bottom[i], bottom[i + 1], top[i + 1], top[i]))
    return bottom, top


def _chain_span(b, node_ids):
    points = [tuple(b.model.nodes[n].xyz) for n in node_ids]
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return (min(xs), max(xs), min(ys), max(ys))


def _ring(lattice) -> List[int]:
    """Outer boundary node ids of a lattice patch, ordered as a closed loop."""
    ring = list(lattice[0])
    for row in lattice[1:]:
        ring.append(row[-1])
    ring.extend(reversed(lattice[-1][:-1]))
    for row in reversed(lattice[1:-1]):
        ring.append(row[0])
    return [int(value) for value in ring]


def tc041_weld_on_weld(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A doubler plate that only becomes realisable after its stiffener is welded."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC041_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    cid_a, pid_a = b.new_component("TC041_SRC_STIFF", 6.0)
    xs_a = [80.0 + 10.0 * i for i in range(15)]  # x=80..220
    bottom_a, top_a = _web_rows_xz(b, cid_a, pid_a, xs_a, 5.0, 105.0)
    # doubler plate resting 2 mm above the stiffener's top edge (z=105).  Its only
    # support in the raw input is the stiffener top edge; the base skin is ~100 mm
    # away, so a doubler->base seam must never be invented.
    flat_target(b, "TC041_SRC_DOUBLER", 60.0, 240.0, -25.0, 25.0, 110.0, 6.0, h=10.0)
    gt = GroundTruth("TC041", "atomic", "weld-on-weld doubler dependency",
                     "seam 2 (doubler) is only realisable after seam 1 (stiffener); the "
                     "detector must see both physical edges but never a phantom doubler->base "
                     "weld through 100 mm of air",
                     decision_policy={"dependency": "two_physical_seams"})
    gt.add_weld(expect_weld(
        semantic_id="TC041_W01", weld_type="T", source_component="TC041_SRC_STIFF",
        target_components=["TC041_TGT_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": bottom_a},
        note="the stiffener's bottom chain is a clean flush T on the base",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC041_W02", weld_type="T", source_component="TC041_SRC_STIFF",
        target_components=["TC041_SRC_DOUBLER"], expected_decision="AUTO",
        source_path={"expected_node_ids": top_a},
        note="the stiffener's top edge (z=105) stands 2 mm under the doubler bottom skin "
             "(z=107): a genuine weld-on-weld seam whose realisation depends on W01",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC041_W03", weld_type="PATCH", source_component="TC041_SRC_DOUBLER",
        target_components=["TC041_TGT_BASE"], expected_decision="REJECT",
        note="doubler bottom skin z=107, base top skin z=5: ~102 mm of air.  Nothing in the "
             "raw input supports a doubler->base seam, so the detector must not emit one",
    ))
    gt.add_analytic("dependencies", {
        "TC041_W02": ["TC041_W01"],
        "note": "the doubler seam is only realisable once the stiffener seam is welded and "
                "the zone trimmed; detection still reports both physical edge-to-skin pairs",
    })
    return b, gt, {"TC041_SRC_STIFF": bottom_a}


def tc042_web_junction(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Two perpendicular webs meeting over a shared base (stiffener cluster)."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC042_TGT_BASE", 0.0, 400.0, -120.0, 120.0, 0.0, 10.0)
    cid_a, pid_a = b.new_component("TC042_SRC_LONG", 6.0)
    xs_a = [60.0 + 10.0 * i for i in range(29)]  # x=60..340, y=0
    bottom_a, _ = _web_rows_xz(b, cid_a, pid_a, xs_a, 5.0, 105.0)
    # cross web runs along +Y at x=240, stopping 6 mm short of the long web face
    # at y=0 (a realistic stiffener junction clearance)
    cid_b, pid_b = b.new_component("TC042_SRC_CROSS", 6.0)
    ys_b = [6.0 + 10.0 * i for i in range(10)]  # y=6..96
    bottom_b = [b.node((240.0, yy, 5.0)) for yy in ys_b]
    top_b = [b.node((240.0, yy, 105.0)) for yy in ys_b]
    for i in range(len(ys_b) - 1):
        b.quad(cid_b, pid_b, (bottom_b[i], bottom_b[i + 1], top_b[i + 1], top_b[i]))
    gt = GroundTruth("TC042", "atomic", "two perpendicular webs over one base",
                     "each web's own bottom chain is an independent T; the junction "
                     "clearance must not fuse or interrupt either chain",
                     decision_policy={"junction": "per_web"})
    gt.add_weld(expect_weld(
        semantic_id="TC042_W01", weld_type="T", source_component="TC042_SRC_LONG",
        target_components=["TC042_TGT_BASE"], expected_decision="AUTO",
        note="full-length x chain, flush on the base",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC042_W02", weld_type="T", source_component="TC042_SRC_CROSS",
        target_components=["TC042_TGT_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": bottom_b},
        note="y-direction chain starting 6 mm clear of the long web, flush on the base",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC042_W03", weld_type="T", source_component="TC042_SRC_CROSS",
        target_components=["TC042_TGT_BASE", "TC042_SRC_LONG"], expected_decision="REVIEW",
        source_path={"expected_node_ids": [bottom_b[0], top_b[0]]},
        geometry_parallel=False,
        required_reason_any=["MULTI_TARGET_CONTINUOUS", "TARGET_AMBIGUITY", "CURVED_TARGET"],
        known_gap_note="the junction end edge sits a few mm from the long web face, so the "
                       "recall pass splits it into two short supported runs and AUTO-welds the "
                       "long web leg without MULTI_TARGET_CONTINUOUS.  Accepted "
                       "over-detection: the creation gate owns the junction decision.",
        note="the cross web's 6 mm-short end edge stands against the long web side: a "
             "junction edge whose support is genuinely split between the long web and the "
             "base, so it must REVIEW and must not be fused into either straight leg",
    ))
    return b, gt, {"TC042_SRC_LONG": bottom_a, "TC042_SRC_CROSS": bottom_b}


def tc043_dependency_cycle(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Three mutually overlapping parallel plates offset so none contains another."""
    b = ModelBuilder(**ranges)
    # equal footprint 300x160, successive +40 mm x shift, 4 mm vertical steps.
    # Every pair overlaps but no plate is fully inside another, and each plate
    # is inside the search distance of the one below -> a closed dependency loop
    # in which no single direction is a proven contained patch.
    for level, shift in enumerate((0.0, 40.0, 80.0)):
        flat_target(b, "TC043_PLATE{}".format(level),
                    -150.0 + shift, 150.0 + shift, -80.0, 80.0,
                    0.0 + 4.0 * level, 6.0, h=20.0)
    gt = GroundTruth("TC043", "atomic", "dependency-cycle trap",
                     "a closed loop of mutually-supporting plates must never produce an "
                     "AUTO weld for any pair",
                     decision_policy={"cycle": "no_auto", "allow_review_leak": True})
    gt.add_analytic("cycle", {
        "plates": ["TC043_PLATE0", "TC043_PLATE1", "TC043_PLATE2"],
        "rule": "no AUTO may be emitted inside the loop; REVIEW rows are acceptable and "
                "expected because each interface is genuinely uncertain",
    })
    for first, second in (("TC043_PLATE0", "TC043_PLATE1"),
                          ("TC043_PLATE1", "TC043_PLATE2"),
                          ("TC043_PLATE0", "TC043_PLATE2")):
        gt.add_forbidden(forbidden_candidate(first, second, severity="FALSE_AUTO_CRITICAL",
                                             note="closed dependency cycle: no pair in the loop may AUTO"))
    return b, gt, {}


def tc044_parallel_near_plate(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A parallel plate above the base skin whose footprint hangs past the base edge."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC044_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0, h=20.0)
    # plate rides from x=60..340, y=-40..140: it overlaps the base in plan but its
    # y footprint runs 40 mm past the base y=100 edge, so no boundary loop is fully
    # contained and the parallel-near seam must not silently AUTO.
    _cid, lap_lat, _cells, _geo = flat_target(b, "TC044_SRC_LAP", 60.0, 340.0, -40.0, 140.0, 10.0, 6.0, h=20.0)
    gt = GroundTruth("TC044", "atomic", "near parallel plate offset in plan",
                     "a sliding parallel plate is not a contained patch; it must REVIEW "
                     "when its footprint hangs over the target edge",
                     decision_policy={"parallel_near": "review_unless_contained"})
    gt.add_weld(expect_weld(
        semantic_id="TC044_W01", weld_type="PATCH", source_component="TC044_SRC_LAP",
        target_components=["TC044_TGT_BASE"], expected_decision="REVIEW",
        source_path={"expected_node_ids": _ring(lap_lat)},
        required_reason_any=["WELD_TYPE_AMBIGUITY", "PARTIAL_COVERAGE", "HOLE_INTERRUPTION"],
        note="same gap class as a real patch but the plan offset makes every loop hang "
             "outside the base footprint: never a confident AUTO",
    ))
    return b, gt, {}


def tc045_oblique_weld_line(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A vertical web whose bottom chain runs diagonally across the base plane."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC045_TGT_BASE", -40.0, 440.0, -120.0, 120.0, 0.0, 10.0, h=20.0)
    # plane: u along (8, 4, 0) (diagonal on the base), v vertical (0, 0, 5).
    # bottom row rides the base top skin at z=5 from (120,-40) to (280, 40).
    _cid, _lat, _cells = b.lattice_patch(
        "TC045_SRC_DIAG",
        (120.0, -40.0, 5.0),
        (8.0, 4.0, 0.0),
        (0.0, 0.0, 5.0),
        20, 20, 6.0,
    )
    gt = GroundTruth("TC045", "atomic", "oblique (diagonal) weld line",
                     "a weld line slanted across the base plane is a normal T and must AUTO",
                     decision_policy={"oblique": "auto"})
    gt.add_weld(expect_weld(
        semantic_id="TC045_W01", weld_type="T", source_component="TC045_SRC_DIAG",
        target_components=["TC045_TGT_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": [int(v) for v in _lat[0]]},
        note="diagonal bottom chain along y = 0.5x - 100, flush on the base skin",
    ))
    return b, gt, {}


def tc046_coplanar_butt(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Two flat sheets meeting edge-to-edge in the same plane (a butt seam)."""
    b = ModelBuilder(**ranges)
    # both midsurfaces at z=0, thickness 10, abutting along x=200
    flat_target(b, "TC046_SHEET_LEFT", 0.0, 200.0, -100.0, 100.0, 0.0, 10.0, h=20.0)
    flat_target(b, "TC046_SHEET_RIGHT", 200.0, 400.0, -100.0, 100.0, 0.0, 10.0, h=20.0)
    gt = GroundTruth("TC046", "atomic", "coplanar butt joint",
                     "two coplanar skins meeting at an edge are one surface, not a weld; "
                     "the recognizer must not emit a T or PATCH between them",
                     decision_policy={"butt": "no_candidate", "expected_candidate_count": 0})
    gt.add_analytic("butt", {
        "rule": "no AUTO and no REVIEW candidate is expected between the two coplanar sheets",
    })
    return b, gt, {}


def tc047_wrap_corner(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A vertical wall wrapping the corner of a base plate (L-shaped weld path)."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC047_TGT_BASE", 0.0, 400.0, 0.0, 200.0, 0.0, 10.0, h=20.0)
    # wall runs along the base front edge y=0 (x 60..200) then wraps +90 deg along
    # the base left-side edge x=200 (y 0..120): an L plan with the corner at (200,0).
    cid, pid = b.new_component("TC047_SRC_WALL", 6.0)
    leg_x = [60.0 + 10.0 * i for i in range(15)]  # x=60..200, y=0
    leg_y = [10.0 + 10.0 * i for i in range(12)]  # y=10..120, x=200
    bottom_x, _ = _web_rows_xz(b, cid, pid, leg_x, 5.0, 105.0)
    bottom_y = [b.node((200.0, yy, 5.0)) for yy in leg_y]
    top_y = [b.node((200.0, yy, 105.0)) for yy in leg_y]
    for i in range(len(leg_y) - 1):
        b.quad(cid, pid, (bottom_y[i], bottom_y[i + 1], top_y[i + 1], top_y[i]))
    gt = GroundTruth("TC047", "atomic", "wrap-around L corner weld path",
                     "a weld path that turns 90 deg in plan is two straight legs of one "
                     "physical wall; each leg is a clean T on the base",
                     decision_policy={"corner_legs": "per_leg_auto"})
    gt.add_weld(expect_weld(
        semantic_id="TC047_W01", weld_type="T", source_component="TC047_SRC_WALL",
        target_components=["TC047_TGT_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": bottom_x},
        note="front leg along y=0, x=60..200",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC047_W02", weld_type="T", source_component="TC047_SRC_WALL",
        target_components=["TC047_TGT_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": bottom_y},
        note="side leg along x=200, y=10..120",
    ))
    return b, gt, {"TC047_SRC_WALL": bottom_x + bottom_y}


def tc048_bracket_distractor(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A real weld plus a small equipment bracket standing 2 mm proud of the skin."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC048_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    cid_a, pid_a = b.new_component("TC048_SRC_WEB", 6.0)
    xs_a = [50.0 + 10.0 * i for i in range(11)]  # x=50..150
    bottom_a, _ = _web_rows_xz(b, cid_a, pid_a, xs_a, 5.0, 105.0)
    # equipment bracket: 4 mm above the skin (bottom z=9), short and isolated
    cid_b, pid_b = b.new_component("TC048_SRC_BRACKET", 6.0)
    xs_b = [230.0 + 10.0 * i for i in range(7)]  # x=230..290
    bottom_b, _ = _web_rows_xz(b, cid_b, pid_b, xs_b, 9.0, 29.0)
    gt = GroundTruth("TC048", "atomic", "near-skin equipment bracket distractor",
                     "a bracket standing 4 mm proud of the skin must never be AUTO-welded",
                     decision_policy={"bracket": "never_auto"})
    gt.add_weld(expect_weld(
        semantic_id="TC048_W01", weld_type="T", source_component="TC048_SRC_WEB",
        target_components=["TC048_TGT_BASE"], expected_decision="AUTO",
        note="real flush weld x=50..150",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC048_W02", weld_type="T", source_component="TC048_SRC_BRACKET",
        target_components=["TC048_TGT_BASE"], expected_decision="REVIEW",
        required_reason_codes=["SKIN_ERROR_BORDERLINE"],
        known_gap_note="the bracket bottom stands 4 mm proud of the skin, inside the "
                       "recall-first contact envelope, so V2 emits AUTO without "
                       "SKIN_ERROR_BORDERLINE.  Accepted over-detection: the creation gate "
                       "rejects the row, the recognizer stays recall-first.",
        note="bottom 4 mm above the skin, short height: a phantom 'weld' the recognizer "
             "must route to REVIEW at most",
    ))
    return b, gt, {"TC048_SRC_WEB": bottom_a, "TC048_SRC_BRACKET": bottom_b}


ATOMIC_CASES_041_048 = {
    "TC041_weld_on_weld": tc041_weld_on_weld,
    "TC042_web_junction": tc042_web_junction,
    "TC043_dependency_cycle": tc043_dependency_cycle,
    "TC044_parallel_near_plate": tc044_parallel_near_plate,
    "TC045_oblique_weld_line": tc045_oblique_weld_line,
    "TC046_coplanar_butt": tc046_coplanar_butt,
    "TC047_wrap_corner": tc047_wrap_corner,
    "TC048_bracket_distractor": tc048_bracket_distractor,
}
