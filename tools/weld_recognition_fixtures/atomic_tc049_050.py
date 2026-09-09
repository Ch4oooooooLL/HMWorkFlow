"""Atomic weld-recognition fixture cases TC049..TC050.

Coverage: two components already merged into one continuous mesh across the
seam (TC049), and a generalized T seam standing beside a square T on the same
source component (TC050).
"""
from __future__ import annotations

import math
from typing import Dict, List, Tuple

from geo_helpers import flat_target, vertical_web
from wfc_gt import GroundTruth, expect_weld
from wfc_model import ModelBuilder


def tc049_mesh_continuous_seam(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A web whose bottom row reuses the base plate's GRID nodes.

    The two components are already connected: the solver transfers load through
    the shared nodes, so the interface is not a weld seam and must not become a
    candidate.  Detection must return nothing for the model.
    """
    b = ModelBuilder(**ranges)
    _base_cid, lattice, _cells, _geo = flat_target(
        b, "TC049_TGT_BASE", 0.0, 400.0, -100.0, 100.0, 0.0, 10.0, h=20.0)
    seam = lattice[5][5:16]  # x=100..300 at y=0: the base plate's midsurface row
    web_cid, web_pid = b.new_component("TC049_SRC_WEB", 6.0)
    top = [b.node((b.xyz(node_id)[0], 0.0, 100.0)) for node_id in seam]
    for index in range(len(seam) - 1):
        b.quad(web_cid, web_pid, (seam[index], seam[index + 1], top[index + 1], top[index]))
    gt = GroundTruth(
        "TC049", "atomic", "mesh-continuous components (shared GRID nodes)",
        "a web merged into the base mesh through shared GRID nodes transfers load "
        "directly: no weld seam exists there, so no candidate may be emitted",
        decision_policy={"mesh_continuous": "no_candidate", "expected_candidate_count": 0})
    gt.add_analytic("mesh_continuity", {
        "shared_node_ids": [int(value) for value in seam],
        "rule": "shared GRID nodes on the seam mean one continuous mesh; the "
                "recognizer must not offer the pair as a weld candidate",
    })
    return b, gt, {}


def tc050_generalized_t_beside_square_t(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A 60-degree junction web beside a flush web over one base plate.

    The cross web's own bottom chain is a clean flush T (AUTO), which is what
    makes its second chain interesting: the end column standing 6 mm clear of
    the long web face is a genuine generalized T at 60 degrees.  The strict
    envelope rejects the angle and only a two-node grazing fragment against the
    base survives it, so the chain must still be re-evaluated with the recall
    envelope instead of being dropped.
    """
    b = ModelBuilder(**ranges)
    flat_target(b, "TC050_TGT_BASE", 0.0, 400.0, -120.0, 120.0, 0.0, 10.0, h=20.0)
    _long_cid, long_lattice, _long_cells = vertical_web(
        b, "TC050_SRC_LONG", 60.0, 340.0, 5.0, 105.0, y=0.0, h=10.0, thickness=6.0)
    angle = math.radians(60.0)
    direction = (math.cos(angle), math.sin(angle), 0.0)
    x_end, y_end = 240.0, 6.0
    cross_cid, cross_pid = b.new_component("TC050_SRC_CROSS", 6.0)
    n_along, n_up, step = 10, 10, 10.0
    grid = [
        [b.node((x_end + j * step * direction[0], y_end + j * step * direction[1],
                 5.0 + k * step))
         for j in range(n_along + 1)]
        for k in range(n_up + 1)
    ]
    for k in range(n_up):
        for j in range(n_along):
            b.quad(cross_cid, cross_pid,
                   (grid[k][j], grid[k][j + 1], grid[k + 1][j + 1], grid[k + 1][j]))
    bottom_cross = [grid[0][j] for j in range(n_along + 1)]
    end_column = [grid[k][0] for k in range(n_up + 1)]
    gt = GroundTruth(
        "TC050", "atomic", "generalized T beside a square T on one source",
        "a source component may own several weldable free-edge chains: the cross "
        "web's flush bottom chain AUTO-welds the base while its 60-degree end "
        "column against the long web must still be reported as a candidate",
        decision_policy={"per_chain_recall": "report_every_supported_chain"})
    gt.add_weld(expect_weld(
        semantic_id="TC050_W01", weld_type="T", source_component="TC050_SRC_LONG",
        target_components=["TC050_TGT_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": long_lattice[0]},
        note="long web bottom chain flush on the base skin",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC050_W02", weld_type="T", source_component="TC050_SRC_CROSS",
        target_components=["TC050_TGT_BASE"], expected_decision="AUTO",
        source_path={"expected_node_ids": bottom_cross},
        note="cross web bottom chain flush on the base skin",
    ))
    gt.add_weld(expect_weld(
        semantic_id="TC050_W03", weld_type="T", source_component="TC050_SRC_CROSS",
        target_components=["TC050_SRC_LONG"], expected_decision="REVIEW",
        source_path={"expected_node_ids": end_column},
        allow_extra_targets=True,
        required_reason_any=["ANGLE_BORDERLINE", "PARTIAL_COVERAGE", "TARGET_NORMAL_JUMP"],
        note="the cross web's end column stands 6 mm clear of the long web face at "
             "60 degrees: a generalized T whose angle fails the strict envelope, so "
             "only the per-chain recall pass can report it",
    ))
    gt.add_analytic("generalized_t", {
        "dihedral_deg": 60.0,
        "clearance_mm": y_end,
        "rule": "the strict pass reports the cross web's bottom chain only; the end "
                "column must be recovered by the recall pass on the same component",
    })
    return b, gt, {"TC050_SRC_LONG": long_lattice[0], "TC050_SRC_CROSS": bottom_cross}


ATOMIC_CASES_049_050 = {
    "TC049_mesh_continuous_seam": tc049_mesh_continuous_seam,
    "TC050_generalized_t_beside_square_t": tc050_generalized_t_beside_square_t,
}
