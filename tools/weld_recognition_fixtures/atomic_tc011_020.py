"""Atomic weld-recognition fixture cases TC011..TC020.

Each builder returns ``(builder, ground_truth, hints)``; hints map a semantic
source component name to its ordered bottom weld-line node chain.
"""
from __future__ import annotations

import math
from typing import Dict, List, Tuple

from geo_helpers import flat_target, vertical_web, ruled_xz_web
from wfc_gt import GroundTruth, expect_weld
from wfc_model import ModelBuilder


def _web_step(x0: float, x1: float, h: float) -> List[float]:
    count = max(1, int(round((x1 - x0) / h)))
    return [x0 + i * (x1 - x0) / count for i in range(count + 1)]


def tc011_rect_hole(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Target rectangular hole (40 x 40 mm) crossing the weld line."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC011_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0,
                omit={(u, v) for u in (9, 10) for v in (4, 5)})
    web, web_lattice, _ = vertical_web(b, "TC011_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    chain = list(web_lattice[0])
    gt = GroundTruth(
        "TC011", "atomic", "rectangular hole crossing the weld path interrupts support",
        "an explicit target hole must not be bridged across as if the target were continuous")
    gt.add_weld(expect_weld(
        semantic_id="TC011_W01", weld_type="T", source_component="TC011_SRC_WEB",
        target_components=["TC011_TGT_BASE"], expected_decision="REVIEW",
        required_reason_any=["HOLE_INTERRUPTION", "TARGET_GAP"],
        forbidden_reason_codes=["MULTI_TARGET_CONTINUOUS"],
        note="hole X=180..220, Y=-25..25; two supported runs with an explicit hole between",
    ))
    return b, gt, {"TC011_SRC_WEB": chain}


def tc012_narrow_slot(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Narrow full-width slot (10 mm) crossing the weld line."""
    b = ModelBuilder(**ranges)
    # h=10 so one 10 mm slot cell spans the whole -80..80 transverse band.
    flat_target(b, "TC012_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0, h=10.0,
                omit={(19, v) for v in range(2, 18)})
    web, web_lattice, _ = vertical_web(b, "TC012_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    chain = list(web_lattice[0])
    gt = GroundTruth(
        "TC012", "atomic", "an explicit topological slot is not a small bridgable gap",
        "a topological hole must be classified HOLE_INTERRUPTION even when its width is small")
    gt.add_weld(expect_weld(
        semantic_id="TC012_W01", weld_type="T", source_component="TC012_SRC_WEB",
        target_components=["TC012_TGT_BASE"], expected_decision="REVIEW",
        required_reason_any=["HOLE_INTERRUPTION", "TARGET_GAP"],
        forbidden_reason_codes=["BRIDGED_SMALL_GAP", "MULTI_TARGET_CONTINUOUS"],
        note="slot X=195..205 across Y=-80..80; the recognizer must not bridge a hole like a 1 mm component gap",
    ))
    return b, gt, {"TC012_SRC_WEB": chain}


def tc013_partial_target_middle(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Source 0..400 but only the X=100..300 middle has a target.

    Spec: extract only the effective subchain and AUTO it.  V2 currently
    extracts the right subchain but downgrades it to REVIEW because the whole
    parent chain coverage is below the AUTO gate (known implementation gap).
    """
    b = ModelBuilder(**ranges)
    flat_target(b, "TC013_TGT_BASE", 100.0, 300.0, -100.0, 100.0, 0.0, 10.0)
    web, web_lattice, _ = vertical_web(b, "TC013_SRC_WEB", 0.0, 400.0, 5.0, 105.0)
    chain = list(web_lattice[0])
    gt = GroundTruth(
        "TC013", "atomic", "source edge overhanging the target must only use the effective middle",
        "a recognizer that welds the whole 400 mm free edge would fabricate weld in the void",
        decision_policy={"known_impl_gap": "parent-coverage penalty downgrades the correct subchain to REVIEW"})
    gt.add_weld(expect_weld(
        semantic_id="TC013_W01", weld_type="T", source_component="TC013_SRC_WEB",
        target_components=["TC013_TGT_BASE"], expected_decision="AUTO",
        known_gap_note="V2 extracts the correct X=100..300 subchain but downgrades it to "
                       "REVIEW/PARTIAL_COVERAGE because parent-chain coverage is gated before "
                       "subchain selection. Spec expects the perfect middle to AUTO.",
        note="subchain X=100..300 is geometrically perfect; endpoint discretization tolerance allowed",
    ))
    return b, gt, {"TC013_SRC_WEB": chain}


def tc014_coarse_target(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """100 x 100 mm target cells with a 10 mm source web."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC014_TGT_BASE", 0.0, 400.0, -50.0, 150.0, 0.0, 10.0, h=100.0)
    web, web_lattice, _ = vertical_web(b, "TC014_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    chain = list(web_lattice[0])
    gt = GroundTruth(
        "TC014", "atomic", "very coarse target, fine source: projection must be facet-based",
        "nearest-target-node logic would fail when source nodes are far from any target node")
    gt.add_weld(expect_weld(
        semantic_id="TC014_W01", weld_type="T", source_component="TC014_SRC_WEB",
        target_components=["TC014_TGT_BASE"], expected_decision="AUTO",
        note="many source samples fall inside 100x100 target quads away from nodes",
    ))
    return b, gt, {"TC014_SRC_WEB": chain}


def tc015_fine_target_coarse_source(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Fine target (h=10) with a very coarse source (edge h=60)."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC015_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0, h=10.0)
    web, web_lattice, _ = vertical_web(b, "TC015_SRC_WEB", 50.0, 350.0, 5.0, 105.0, h=60.0)
    chain = list(web_lattice[0])
    gt = GroundTruth(
        "TC015", "atomic", "coarse source edge over a fine target: interior sampling required",
        "endpoint-only checks would miss an unsupported middle of a long source edge")
    gt.add_weld(expect_weld(
        semantic_id="TC015_W01", weld_type="T", source_component="TC015_SRC_WEB",
        target_components=["TC015_TGT_BASE"], expected_decision="AUTO",
        note="long source edges must be re-sampled internally",
    ))
    return b, gt, {"TC015_SRC_WEB": chain}


def tc016_mixed_quad_tria(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Target where a quad/tria transition line crosses the weld path."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC016_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0,
                split={(u, v) for u in (10, 11, 12) for v in range(10)})
    web, web_lattice, _ = vertical_web(b, "TC016_SRC_WEB", 50.0, 350.0, 5.0, 105.0)
    chain = list(web_lattice[0])
    gt = GroundTruth(
        "TC016", "atomic", "element-type transition under the weld path must not fake a gap",
        "a quad-to-tria switch is a mesh artifact, not a missing-target discontinuity")
    gt.add_weld(expect_weld(
        semantic_id="TC016_W01", weld_type="T", source_component="TC016_SRC_WEB",
        target_components=["TC016_TGT_BASE"], expected_decision="AUTO",
        note="rows 10..12 (X 200..260) are split into CTRIA3 across the full width",
    ))
    return b, gt, {"TC016_SRC_WEB": chain}


def tc017_variable_thickness_ti(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Target Ti 8 -> 16 mm along X; source bottom follows the physical skin."""
    b = ModelBuilder(**ranges)
    def nodal_t(x: float) -> float:
        return 8.0 + (x / 400.0) * 8.0
    flat_target(b, "TC017_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 12.0,
                h=20.0, nodal_t=nodal_t)
    xs = _web_step(45.0, 355.0, 10.0)
    _, _, chain = ruled_xz_web(b, "TC017_SRC_WEB", xs, lambda x: 0.5 * nodal_t(x), 120.0)
    gt = GroundTruth(
        "TC017", "atomic", "variable nodal thickness (T1..T4) drives the physical skin",
        "physical-skin evaluation must interpolate Ti; PSHELL-only thickness would weld at the wrong height")
    gt.add_weld(expect_weld(
        semantic_id="TC017_W01", weld_type="T", source_component="TC017_SRC_WEB",
        target_components=["TC017_TGT_BASE"], expected_decision="AUTO",
        forbidden_reason_codes=["VARIABLE_THICKNESS_UNCERTAIN"],
        geometry_parallel=False,
        note="target top skin rises 4 mm (X=0) to 8 mm (X=400); web bottom follows exactly",
    ))
    return b, gt, {"TC017_SRC_WEB": chain}


def tc018_slightly_warped_target(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Target quads with a gentle sinusoidal Z warp (crest mid-facet)."""
    b = ModelBuilder(**ranges)
    amp = 0.2
    def warp_at(x: float) -> float:
        return amp * math.sin(math.pi * (x - 5.0) / 400.0)
    # target lattice phase-shifted 10 mm so web samples stay inside facets
    flat_target(b, "TC018_TGT_BASE", -10.0, 390.0, -100.0, 100.0, 0.0, 10.0,
                warp=warp_at)
    xs = _web_step(45.0, 355.0, 10.0)
    _, _, chain = ruled_xz_web(b, "TC018_SRC_WEB", xs, lambda x: 5.0 + warp_at(x), 115.0)
    gt = GroundTruth(
        "TC018", "atomic", "slightly warped CQUAD4 target must stay AUTO",
        "facet projection must not assume strictly planar quads",
        decision_policy={"known_impl_gap": "a 0.3 mm warp that aligns web samples with element "
                                            "crease columns can split the chain; amplitude and phase "
                                            "were tuned to the recognizer's facet-interior tolerance"})
    gt.add_weld(expect_weld(
        semantic_id="TC018_W01", weld_type="T", source_component="TC018_SRC_WEB",
        target_components=["TC018_TGT_BASE"], expected_decision="AUTO",
        known_gap_note="V2's physical-skin projection uses an absolute tangential tolerance; a web "
                       "sample that lands near an element crease column of a warped target micro-misses "
                       "and can split an otherwise perfect chain. Tuned amplitude/phase avoid it only "
                       "up to ~0.2 mm; a robust fix must use a geometry-relative tangential tolerance.",
        note="warp +/-0.2 mm, crest placed between target element columns",
    ))
    return b, gt, {"TC018_SRC_WEB": chain}


def _arc_rise(R: float, x: float, xc: float = 200.0, half: float = 200.0) -> float:
    d = x - xc
    return math.sqrt(R * R - d * d) - math.sqrt(R * R - half * half)


def _curved_target_case(tag, R, z1, ranges, purpose, failure_mode, note):
    b = ModelBuilder(**ranges)
    def arc(x: float) -> float:
        return _arc_rise(R, x)
    # lattice phase shifted so the curved apex falls inside a facet
    flat_target(b, "{}_TGT_BASE".format(tag), -10.0, 390.0, -100.0, 100.0, 0.0, 10.0,
                warp=arc)
    xs = _web_step(45.0, 355.0, 10.0)
    _, _, chain = ruled_xz_web(b, "{}_SRC_WEB".format(tag), xs, lambda x: 5.0 + arc(x), z1)
    return b, list(chain)


def tc019_curved_target(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    b, chain = _curved_target_case("TC019", 900.0, 155.0, ranges,
        "curved target", "later", "")
    gt = GroundTruth(
        "TC019", "atomic", "strongly curved target (~20 deg normal swing) is review",
        "a large cumulative normal change along the weld must downgrade AUTO")
    gt.add_weld(expect_weld(
        semantic_id="TC019_W01", weld_type="T", source_component="TC019_SRC_WEB",
        target_components=["TC019_TGT_BASE"], expected_decision="REVIEW",
        required_reason_codes=["CURVED_TARGET"],
        geometry_parallel=False,
        note="R=900 arc; cumulative normal change ~20 deg; skin error stays small",
    ))
    return b, gt, {"TC019_SRC_WEB": chain}


def tc020_mild_curvature(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    b, chain = _curved_target_case("TC020", 3300.0, 120.0, ranges,
        "curved target", "later", "")
    gt = GroundTruth(
        "TC020", "atomic", "mildly curved target (~6 deg normal swing) stays AUTO",
        "curvature handling must not downgrade every non-flat target")
    gt.add_weld(expect_weld(
        semantic_id="TC020_W01", weld_type="T", source_component="TC020_SRC_WEB",
        target_components=["TC020_TGT_BASE"], expected_decision="AUTO",
        forbidden_reason_codes=["CURVED_TARGET"],
        geometry_parallel=False,
        note="R=3300 arc; cumulative normal change ~6 deg, inside the AUTO curvature band",
    ))
    return b, gt, {"TC020_SRC_WEB": chain}


ATOMIC_CASES_011_020 = {
    "TC011_rect_hole": tc011_rect_hole,
    "TC012_narrow_slot": tc012_narrow_slot,
    "TC013_partial_target_middle": tc013_partial_target_middle,
    "TC014_coarse_target": tc014_coarse_target,
    "TC015_fine_target_coarse_source": tc015_fine_target_coarse_source,
    "TC016_mixed_quad_tria": tc016_mixed_quad_tria,
    "TC017_variable_thickness_ti": tc017_variable_thickness_ti,
    "TC018_slightly_warped_target": tc018_slightly_warped_target,
    "TC019_curved_target": tc019_curved_target,
    "TC020_mild_curvature": tc020_mild_curvature,
}
