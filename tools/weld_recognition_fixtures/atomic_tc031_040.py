"""Atomic weld-recognition fixture cases TC031..TC040.

Coverage: within-source normal disorder recovery (TC031), reversed-normal
adjacent targets (TC032), near-skin counterfeit web (TC033), strongly
non-uniform source mesh (TC034), and the PATCH_SEAM family (TC035..TC040).
"""
from __future__ import annotations

from typing import Dict, List, Tuple

from geo_helpers import flat_target, vertical_web
from wfc_gt import GroundTruth, expect_weld
from wfc_model import ModelBuilder


def _web_rows_xz(b, component_id, property_id, xs, z0, z1, y=0.0):
    """Quad web spanning X x [z0..z1]; returns (bottom_chain, top_chain)."""
    bottom = [b.node((x, y, z0)) for x in xs]
    top = [b.node((x, y, z1)) for x in xs]
    for i in range(len(xs) - 1):
        b.quad(component_id, property_id, (bottom[i], bottom[i + 1], top[i + 1], top[i]))
    return bottom, top


def tc031_source_normal_disorder(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A web whose upper half is wound opposite its lower half (normal disorder)."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC031_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    cid, pid = b.new_component("TC031_SRC_WEB", 6.0)
    xs = [50.0 + 10.0 * i for i in range(31)]
    z_bands = [5.0, 55.0, 105.0]
    rows = [[b.node((x, 0.0, z)) for x in xs] for z in z_bands]
    for band in range(len(z_bands) - 1):
        lo, hi = rows[band], rows[band + 1]
        flipped = band == 1
        for i in range(len(xs) - 1):
            if flipped:
                # reversed winding (normal flips to +Y) for the top band
                b.quad(cid, pid, (lo[i], hi[i], hi[i + 1], lo[i + 1]))
            else:
                b.quad(cid, pid, (lo[i], lo[i + 1], hi[i + 1], hi[i]))
    gt = GroundTruth("TC031", "atomic", "within-source element normal disorder",
                     "a normal-inconsistent source shell must still produce its real weld",
                     decision_policy={"normal_disorder": "recover"})
    gt.add_weld(expect_weld(
        semantic_id="TC031_W01", weld_type="T", source_component="TC031_SRC_WEB",
        target_components=["TC031_TGT_BASE"], expected_decision="AUTO",
        note="the top band is wound with reversed normals; the flush bottom run at z=5 is a "
             "perfect T and the recognizer's orientation recovery must keep it AUTO",
    ))
    return b, gt, {"TC031_SRC_WEB": rows[0]}


def tc032_reversed_adjacent_targets(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A single web run over a target with an inverted-normal strip inside it."""
    b = ModelBuilder(**ranges)
    cid, pid = b.new_component("TC032_TGT_PLANE", 10.0)
    xs = [-100.0 + 20.0 * i for i in range(27)]   # -100..420, covers the whole web
    ys = [-100.0 + 20.0 * i for i in range(11)]   # -100..100
    lattice = [[b.node((x, y, 0.0)) for x in xs] for y in ys]
    for j in range(len(ys) - 1):
        for i in range(len(xs) - 1):
            # invert a Y strip far from the weld so the web samples (Y=0) never
            # land on a reversed facet, yet the plane still carries the disorder
            reversed_winding = 40.0 <= ys[j] < 80.0
            a, bb, cc, dd = lattice[j][i], lattice[j][i + 1], lattice[j + 1][i + 1], lattice[j + 1][i]
            nodes = (a, dd, cc, bb) if reversed_winding else (a, bb, cc, dd)
            b.quad(cid, pid, nodes)
    # web bottom z=5 rides the +Z top skin across the whole plane
    cid_web, pid_web = b.new_component("TC032_SRC_WEB", 6.0)
    xs_web = [50.0 + 10.0 * i for i in range(31)]
    bottom, _ = _web_rows_xz(b, cid_web, pid_web, xs_web, 5.0, 105.0)
    gt = GroundTruth("TC032", "atomic", "reversed-normal strip inside one target plane",
                     "a physical skin is a plane; its mesh winding must not change the weld",
                     decision_policy={"reversed_normal": "same_decision"})
    gt.add_weld(expect_weld(
        semantic_id="TC032_W01", weld_type="T", source_component="TC032_SRC_WEB",
        target_components=["TC032_TGT_PLANE"], expected_decision="AUTO",
        note="the plane is one component whose Y=40..80 strip is wound -Z while the weld "
             "samples (Y=0) stay on +Z facets; one continuous flush seam",
    ))
    return b, gt, {"TC032_SRC_WEB": bottom}


def tc033_near_skin_counterfeit(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A flush weld plus a second web standing proud of the skin (false weld)."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC033_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0)
    cid_a, pid_a = b.new_component("TC033_SRC_FLUSH", 6.0)
    xs_a = [50.0 + 10.0 * i for i in range(14)]  # x=50..180
    bottom_a, _ = _web_rows_xz(b, cid_a, pid_a, xs_a, 5.0, 105.0)
    cid_b, pid_b = b.new_component("TC033_SRC_PROUD", 6.0)
    xs_b = [220.0 + 10.0 * i for i in range(14)]  # x=220..350
    # bottom 4 mm above the skin: never a real fillet weld
    bottom_b, _ = _web_rows_xz(b, cid_b, pid_b, xs_b, 9.0, 109.0)
    gt = GroundTruth("TC033", "atomic", "near-skin counterfeit web",
                     "an edge 4 mm proud of the target skin must never be AUTO",
                     decision_policy={"false_weld_never_auto": True})
    gt.add_weld(expect_weld(
        semantic_id="TC033_W01", weld_type="T", source_component="TC033_SRC_FLUSH",
        target_components=["TC033_TGT_BASE"], expected_decision="AUTO",
        note="flush bottom run, perfect T",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC033_W02", weld_type="T", source_component="TC033_SRC_PROUD",
        target_components=["TC033_TGT_BASE"], expected_decision="REVIEW",
        forbidden_reason_codes=[],
        required_reason_codes=["SKIN_ERROR_BORDERLINE"],
        known_gap_note="recall-first contact envelope (half source thickness + weld-toe "
                       "setback) reaches a web standing 4 mm proud of the skin, so V2 emits "
                       "AUTO without SKIN_ERROR_BORDERLINE.  Accepted over-detection: the "
                       "creation gate rejects the row, the recognizer stays recall-first.",
        note="bottom 4 mm above the skin: physically not a weld, must be routed to REVIEW "
             "(SKIN_ERROR_BORDERLINE) at most, never AUTO",
    ))
    return b, gt, {"TC033_SRC_FLUSH": bottom_a, "TC033_SRC_PROUD": bottom_b}


def tc034_nonuniform_source_mesh(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A web whose X columns alternate 5/15 mm spacing with a coarse target."""
    b = ModelBuilder(**ranges)
    flat_target(b, "TC034_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0, h=40.0)
    cid, pid = b.new_component("TC034_SRC_WEB", 6.0)
    xs = []
    cursor = 50.0
    while cursor < 350.0 - 1e-9:
        xs.append(cursor)
        cursor += 5.0
        xs.append(cursor)
        cursor += 15.0
    xs.append(350.0)
    bottom, _ = _web_rows_xz(b, cid, pid, xs, 5.0, 105.0)
    gt = GroundTruth("TC034", "atomic", "strongly non-uniform source mesh on a coarse target",
                     "edge-length variation inside one chain must not fragment a clean seam",
                     decision_policy={"nonuniform_mesh": "whole_chain"})
    gt.add_weld(expect_weld(
        semantic_id="TC034_W01", weld_type="T", source_component="TC034_SRC_WEB",
        target_components=["TC034_TGT_BASE"], expected_decision="AUTO",
        note="x spacings alternate 5/15 mm while the target uses h=40; the chain is one "
             "continuous flush seam and must stay one AUTO row",
    ))
    return b, gt, {"TC034_SRC_WEB": bottom}


def _patch_plate(b, tag, big_box, small_box, small_z, *,
                 big_t=10.0, small_t=6.0, big_h=40.0, small_h=10.0,
                 omit=None, flip=None, big_z=0.0):
    """Base plate (midplane big_z, +Z normal) + a parallel patch plate above.

    Returns ``(base_component, patch_component, patch_lattice, patch_cells)``.
    The patch midplane sits at ``small_z`` so its bottom skin clears the base
    top skin (``big_z + big_t/2``) by a controlled gap.
    """
    base_cid, _base_lattice, _base_cells, _geo = flat_target(
        b, "{}_BASE".format(tag), big_box[0], big_box[1], big_box[2], big_box[3],
        big_z, big_t, h=big_h)
    nx = _divisible(small_box[1] - small_box[0], small_h)
    ny = _divisible(small_box[3] - small_box[2], small_h)
    patch_cid, patch_lattice, patch_cells = b.lattice_patch(
        "{}_PATCH".format(tag),
        (small_box[0], small_box[2], small_z),
        ((small_box[1] - small_box[0]) / nx, 0.0, 0.0),
        (0.0, (small_box[3] - small_box[2]) / ny, 0.0),
        nx, ny, small_t,
        omit=omit, flip=flip,
    )
    return base_cid, patch_cid, patch_lattice, patch_cells


def _divisible(length: float, size: float) -> int:
    return max(1, int(round(length / float(size))))


def _ring(lattice) -> List[int]:
    """Outer boundary node ids of a lattice patch, ordered as a closed loop."""
    ring = list(lattice[0])
    for j in range(1, len(lattice)):
        ring.append(lattice[j][-1])
    ring.extend(reversed(lattice[-1][:-1]))
    for j in range(len(lattice) - 2, 0, -1):
        ring.append(lattice[j][0])
    return [int(value) for value in ring]


def _inner_rect_ring(lattice, u0: int, u1: int, v0: int, v1: int) -> List[int]:
    """Clockwise lattice-node ring around an omitted rectangular cell block."""
    ring = [lattice[v0][u] for u in range(u0, u1 + 1)]
    ring.extend(lattice[v][u1] for v in range(v0 + 1, v1 + 1))
    ring.extend(lattice[v1][u] for u in range(u1 - 1, u0 - 1, -1))
    ring.extend(lattice[v][u0] for v in range(v1 - 1, v0, -1))
    return [int(value) for value in ring]


def tc035_patch_auto(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A small plate fully contained above a larger plate -> AUTO patch."""
    b = ModelBuilder(**ranges)
    # big target midplane z=0 top skin z=5; small midplane z=10 bottom skin z=7 => 2 mm gap
    base_cid, patch_cid, _lat, _cells = _patch_plate(
        b, "TC035", (-200.0, 200.0, -150.0, 150.0), (80.0, 120.0, -15.0, 15.0), 10.0)
    gt = GroundTruth("TC035", "atomic", "contained parallel patch plate",
                     "a smaller shell fully projected inside a larger parallel shell is a "
                     "real patch seam and may AUTO",
                     decision_policy={"patch": "auto"})
    gt.add_weld(expect_weld(
        semantic_id="TC035_W01", weld_type="PATCH", source_component="TC035_PATCH",
        target_components=["TC035_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": _ring(_lat)},
        note="40x30 patch plate 2 mm above the base top skin, fully inside its footprint",
    ))
    return b, gt, {}


def tc036_patch_small_window(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A patch plate carrying a weldable 40x40 mm central opening."""
    b = ModelBuilder(**ranges)
    _base, _patch, lattice, _cells = _patch_plate(
        b, "TC036", (-200.0, 200.0, -150.0, 150.0), (60.0, 140.0, -40.0, 40.0), 10.0,
        small_h=10.0,
        omit={(i, j) for i in range(2, 6) for j in range(2, 6)},
    )
    gt = GroundTruth("TC036", "atomic", "patch plate with a central opening",
                     "a qualified exposed patch opening is welded together with its outer perimeter",
                     decision_policy={"patch_opening": "outer_and_inner_auto"})
    gt.add_weld(expect_weld(
        semantic_id="TC036_W01", weld_type="PATCH", source_component="TC036_PATCH",
        target_components=["TC036_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": _ring(lattice)},
        note="outer 80x80 frame ring fully inside the base footprint: its perimeter is the "
             "real patch seam and may AUTO",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC036_W02", weld_type="PATCH", source_component="TC036_PATCH",
        target_components=["TC036_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": _inner_rect_ring(lattice, 2, 6, 2, 6)},
        note="the 40x40 exposed inner boundary projects completely onto the base and is a real patch seam",
    ))
    gt.add_analytic("inner_window", {
        "x": [80.0, 120.0], "y": [-20.0, 20.0], "span": 40.0,
        "expected_decision": "AUTO",
        "verified": "V2 emits the inner loop as a separate AUTO patch row; fastener-sized openings "
                    "below small_hole_diameter remain excluded rather than becoming weld paths.",
    })
    return b, gt, {}


def tc037_patch_tilted_not_parallel(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A plate tilted 35 deg over a base: no patch, but its low edge lands on the base."""
    b = ModelBuilder(**ranges)
    import math
    flat_target(b, "TC037_BASE", -200.0, 200.0, -150.0, 150.0, 0.0, 10.0, h=40.0)
    rad = math.radians(35.0)
    b.lattice_patch(
        "TC037_TILT",
        (80.0, -40.0, 10.0),
        (20.0, 0.0, 0.0),
        (0.0, 20.0 * math.cos(rad), 20.0 * math.sin(rad)),
        3, 4, 6.0,
    )
    gt = GroundTruth("TC037", "atomic", "tilted plate over a base",
                     "a 35 deg tilted plate is no patch, but its lower edge still lands on "
                     "the base and is recalled as a 55 deg generalized T in REVIEW")
    gt.add_weld(expect_weld(
        semantic_id="TC037_W01", weld_type="T", source_component="TC037_TILT",
        target_components=["TC037_BASE"], expected_decision="REVIEW",
        required_reason_codes=["ANGLE_BORDERLINE"],
        geometry_parallel=False,
        note="plate 35 deg from parallel: the low edge is a 55 deg generalized T on the base "
             "top skin, recalled as REVIEW ANGLE_BORDERLINE, never AUTO",
    ))
    return b, gt, {}


def tc038_patch_partial_overlap(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A patch plate hanging beyond the base footprint -> REVIEW not AUTO."""
    b = ModelBuilder(**ranges)
    _base, _patch, _lat, _cells = _patch_plate(
        b, "TC038", (-200.0, 200.0, -150.0, 150.0), (100.0, 320.0, -40.0, 40.0), 10.0)
    gt = GroundTruth("TC038", "atomic", "patch partially outside the target footprint",
                     "a loop that extends beyond the target footprint is not proven contained",
                     decision_policy={"patch": "review_when_partial"})
    gt.add_weld(expect_weld(
        semantic_id="TC038_W01", weld_type="PATCH", source_component="TC038_PATCH",
        target_components=["TC038_BASE"], expected_decision="REVIEW",
        source_path={"expected_node_ids": _ring(_lat)},
        note="patch x=100..320 extends past the base x=200 edge; partial containment must review",
    ))
    return b, gt, {}


def tc039_patch_reversed_normal(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Two parallel stacked plates where the top one is wound opposite."""
    b = ModelBuilder(**ranges)
    _base, _patch, _lat, _cells = _patch_plate(
        b, "TC039", (-200.0, 200.0, -150.0, 150.0), (80.0, 120.0, -15.0, 15.0), 10.0,
        flip=lambda i, j: True)
    gt = GroundTruth("TC039", "atomic", "parallel patch with reversed mesh winding",
                     "winding is a modelling accident and must not change the physical seam",
                     decision_policy={"reversed_normal_patch": "recover_to_auto"})
    gt.add_weld(expect_weld(
        semantic_id="TC039_W01", weld_type="PATCH", source_component="TC039_PATCH",
        target_components=["TC039_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": _ring(_lat)},
        note="same physical stack as TC035 but the patch is wound -Z; orientation recovery "
             "must treat the parallel contained plate as the real seam it is",
    ))
    return b, gt, {}


def tc040_patch_nested_stack(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Three stacked plates: small on medium on large, each interface a patch."""
    b = ModelBuilder(**ranges)
    _base, _l0, _lat0, _cells0 = _patch_plate(
        b, "TC040", (-200.0, 200.0, -150.0, 150.0), (-80.0, 80.0, -60.0, 60.0), 10.0)
    _l1, _l1_lat, _l1_cells = b.lattice_patch(
        "TC040_L1_PATCH",
        (-30.0, -25.0, 20.0),
        (10.0, 0.0, 0.0), (0.0, 10.0, 0.0),
        6, 5, 6.0,
    )
    gt = GroundTruth("TC040", "atomic", "nested patch hierarchy",
                     "a 3-plate stack has two real interfaces; the recognizer must not skip a "
                     "level nor collapse the stack into one ambiguous weld",
                     decision_policy={"nested_patch": "per_interface"})
    gt.add_weld(expect_weld(
        semantic_id="TC040_W01", weld_type="PATCH", source_component="TC040_PATCH",
        target_components=["TC040_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": _ring(_lat0)},
        note="medium plate 160x120 fully inside the base at 2 mm skin gap: clean patch",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC040_W02", weld_type="PATCH", source_component="TC040_L1_PATCH",
        target_components=["TC040_PATCH"], expected_decision="AUTO",
        source_path={"expected_node_ids": _ring(_l1_lat)},
        note="small plate 60x50 fully inside the medium plate: its nearest skin is the medium "
             "plate, so the base must not steal this interface",
    ))
    return b, gt, {}


ATOMIC_CASES_031_040 = {
    "TC031_source_normal_disorder": tc031_source_normal_disorder,
    "TC032_reversed_adjacent_targets": tc032_reversed_adjacent_targets,
    "TC033_near_skin_counterfeit": tc033_near_skin_counterfeit,
    "TC034_nonuniform_source_mesh": tc034_nonuniform_source_mesh,
    "TC035_patch_auto": tc035_patch_auto,
    "TC036_patch_small_window": tc036_patch_small_window,
    "TC037_patch_tilted_not_parallel": tc037_patch_tilted_not_parallel,
    "TC038_patch_partial_overlap": tc038_patch_partial_overlap,
    "TC039_patch_reversed_normal": tc039_patch_reversed_normal,
    "TC040_patch_nested_stack": tc040_patch_nested_stack,
}
