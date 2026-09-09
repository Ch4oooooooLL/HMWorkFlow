"""Composite weld-recognition fixtures CM001..CM004.

CM001  box rail: bottom + roof skins, two side walls, five transverse
       diaphragms with deliberately different weld conditions, a longitudinal
       stiffener, a contained roof patch plate and a near-skin bracket.
CM002  adversarial junction composite: a hand-picked set of atomic cases whose
       failure modes are known (inner-boundary, coplanar butt, web junction,
       projection jump, same-component island, borderline angle, dependency
       cycle) merged into a single FEM so interactions are exercised together.
CM003  full-corpus composite: every atomic case merged into one FEM.
CM004  performance composite: a large regular strip of flush T welds used for
       runtime and scale regression.

Each composite is emitted like an atomic case (input.fem + input_manifest.json
+ ground_truth.json under composite/<case_id>/) so the regression runner reuses
the same matching semantics.
"""
from __future__ import annotations

import math
from pathlib import Path
from typing import Callable, Dict, List, Tuple

import atomic_tc001_010 as A01
import atomic_tc011_020 as A11
import atomic_tc021_030 as A21
import atomic_tc031_040 as A31
import atomic_tc041_048 as A41
import atomic_tc049_050 as A49
from wfc_catalogue import case_id_range, composite_subdir, component_banners
from wfc_csv import write_weld_csv
from wfc_gt import GroundTruth, expect_weld, tolerated_candidate
from wfc_model import CaseModel, Component, ModelBuilder, Node, ShellElem
from wfc_writer import write_fem_bundle


def _y_web(b: ModelBuilder, name: str, x: float, y0: float, y1: float,
           z0: float, z1: float, thickness: float = 6.0, h_y: float = 10.0,
           h_z: float = 10.0, omit=None, lean_deg: float = 0.0):
    """Vertical diaphragm spanning Y at fixed X, normal +/-X.

    ``lean_deg`` tilts the top toward +X around the bottom Y-axis line, so the
    bottom row stays flush on the target while the plane normal leaves vertical.
    """
    ny = max(1, int(round((y1 - y0) / h_y)))
    nz = max(1, int(round((z1 - z0) / h_z)))
    rise = z1 - z0
    radians = math.radians(lean_deg)
    step_along = rise / nz / math.cos(radians)
    cid, lattice, cells = b.lattice_patch(
        name, (x, y0, z0),
        (0.0, (y1 - y0) / ny, 0.0),
        (step_along * math.sin(radians), 0.0, step_along * math.cos(radians)),
        ny, nz, thickness,
        omit=omit,
    )
    bottom_chain = [int(value) for value in lattice[0]]
    top_chain = [int(value) for value in lattice[-1]]
    return cid, lattice, cells, bottom_chain, top_chain


def _x_web(b: ModelBuilder, name: str, x0: float, x1: float, y: float,
           z0: float, z1: float, thickness: float = 6.0, h: float = 10.0):
    """Vertical web running along X at fixed Y (normal +/-Y)."""
    from geo_helpers import vertical_web
    cid, lattice, _cells = vertical_web(b, name, x0, x1, z0, z1, y=y, h=h,
                                        thickness=thickness)
    bottom_chain = [int(value) for value in lattice[0]]
    top_chain = [int(value) for value in lattice[-1]]
    return cid, bottom_chain, top_chain


def cm001_box_rail(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A 600x300 box rail with side walls, five diaphragms, stiffener and plates."""
    b = ModelBuilder(**ranges)
    from geo_helpers import flat_target
    # roof bottom skin at z=296, webs rise to z=295 (1 mm physical gap)
    flat_target(b, "CM001_BASE_BOTTOM", 0.0, 600.0, -150.0, 150.0, 0.0, 10.0, h=20.0)
    flat_target(b, "CM001_BASE_TOP", 0.0, 600.0, -150.0, 150.0, 300.0, 8.0, h=20.0)
    # side walls sit on the plate 4 mm inside its outer edge (inner faces y=+/-143)
    _w, bot_l, top_l = _x_web(b, "CM001_SIDE_LEFT", 40.0, 560.0, 146.0, 5.0, 295.0)
    _w2, bot_r, top_r = _x_web(b, "CM001_SIDE_RIGHT", 40.0, 560.0, -146.0, 5.0, 295.0)
    # five diaphragms across y -138..138 at x=100..500
    _d1, _l1, _c1, d1_b, d1_t = _y_web(b, "CM001_DIA_1", 100.0, -138.0, 138.0, 5.0, 295.0)
    # DIA2 has an interior manhole (y -40..40, z 90..180), clear of both chains
    manhole = set()
    for iy in range(-40, 40, 10):
        for iz in range(90, 180, 10):
            manhole.add(((iy + 138) // 10, (iz - 5) // 10))
    _d2, _l2, _c2, d2_b, d2_t = _y_web(b, "CM001_DIA_2", 200.0, -138.0, 138.0, 5.0, 295.0,
                                       omit=manhole)
    # DIA3 stands proud: bottom z=11 (6 mm above the skin)
    _d3, _l3, _c3, d3_b, d3_t = _y_web(b, "CM001_DIA_3", 300.0, -138.0, 138.0, 11.0, 295.0)
    # DIA4 short: top z=200 (far below the roof)
    _d4, _l4, _c4, d4_b, _d4_t = _y_web(b, "CM001_DIA_4", 400.0, -138.0, 138.0, 5.0, 200.0)
    # DIA5 tilted 15 deg off vertical -> borderline T angle 75 on both chains
    _d5, _l5, _c5, d5_b, d5_t = _y_web(b, "CM001_DIA_5", 500.0, -138.0, 138.0, 5.0, 295.0,
                                        lean_deg=15.0)
    # longitudinal stiffener in the open bay between DIA4 (x400) and DIA5 (x500)
    _s, s_b, _s_t = _x_web(b, "CM001_STIFF_LONG", 408.0, 492.0, 0.0, 5.0, 150.0)
    # roof equipment plate: contained above the roof top skin (z=304)
    _g_cid, g_lattice, _gcells, _geo_g = flat_target(
        b, "CM001_GUSSET_ROOF", 80.0, 280.0, -70.0, 70.0, 310.0, 6.0, h=20.0)
    gusset_ring = ([int(v) for v in g_lattice[0]] +
                   [int(v) for v in (row[-1] for row in g_lattice[1:-1])] +
                   [int(v) for v in reversed(g_lattice[-1])] +
                   [int(v) for v in reversed([row[0] for row in g_lattice[1:-1]])])
    # near-skin equipment bracket on the bottom skin (phantom weld)
    _br, br_b, _br_t = _x_web(b, "CM001_BRACKET", 60.0, 120.0, 70.0, 11.0, 45.0,
                              thickness=4.0)
    gt = GroundTruth("CM001", "composite", "box rail multi-part composite",
                     "every physical wall/diaphragm/stiffener seam plus realistic "
                     "manholes, proud plates and near-skin distractors in one model")
    for tag, bot, top in (("SIDE_LEFT", bot_l, top_l), ("SIDE_RIGHT", bot_r, top_r)):
        gt.add_weld(expect_weld(
            semantic_id="CM001_W_{}_BOT".format(tag), weld_type="T",
            source_component="CM001_{}".format(tag),
            target_components=["CM001_BASE_BOTTOM"], expected_decision="AUTO",
            source_path={"expected_node_ids": bot},
            note="side wall bottom chain flush on the bottom skin",
        ))
        gt.add_weld(expect_weld(
            semantic_id="CM001_W_{}_TOP".format(tag), weld_type="T",
            source_component="CM001_{}".format(tag),
            target_components=["CM001_BASE_TOP"], expected_decision="AUTO",
            source_path={"expected_node_ids": top},
            note="side wall top chain 1 mm under the roof bottom skin",
        ))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_DIA1_BOT", weld_type="T", source_component="CM001_DIA_1",
        target_components=["CM001_BASE_BOTTOM"], expected_decision="AUTO",
        source_path={"expected_node_ids": d1_b}, note="clean diaphragm bottom chain"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_DIA1_TOP", weld_type="T", source_component="CM001_DIA_1",
        target_components=["CM001_BASE_TOP"], expected_decision="AUTO",
        source_path={"expected_node_ids": d1_t}, note="clean diaphragm top chain"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_DIA2_BOT", weld_type="T", source_component="CM001_DIA_2",
        target_components=["CM001_BASE_BOTTOM"], expected_decision="AUTO",
        source_path={"expected_node_ids": d2_b},
        note="diaphragm with interior manhole: both weld chains stay clean"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_DIA2_TOP", weld_type="T", source_component="CM001_DIA_2",
        target_components=["CM001_BASE_TOP"], expected_decision="AUTO",
        source_path={"expected_node_ids": d2_t}, note="diaphragm 2 top chain"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_DIA3_BOT", weld_type="T", source_component="CM001_DIA_3",
        target_components=["CM001_BASE_BOTTOM"], expected_decision="REVIEW",
        source_path={"expected_node_ids": d3_b},
        required_reason_codes=["SKIN_ERROR_BORDERLINE"],
        allow_extra_targets=True,
        known_gap_note="DIA_3 stands 6 mm proud of the bottom skin, inside the recall-first "
                       "contact envelope, so V2 emits AUTO without SKIN_ERROR_BORDERLINE.  "
                       "Accepted over-detection: the creation gate rejects the row.",
        note="diaphragm 3 stands 6 mm proud of the skin: phantom, never AUTO; its rim "
             "ends 8 mm from the side-wall skin, so a tolerant recognizer may also "
             "list the wall among the targets"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_DIA3_TOP", weld_type="T", source_component="CM001_DIA_3",
        target_components=["CM001_BASE_TOP"], expected_decision="AUTO",
        source_path={"expected_node_ids": d3_t}, note="diaphragm 3 top flush under roof"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_DIA4_BOT", weld_type="T", source_component="CM001_DIA_4",
        target_components=["CM001_BASE_BOTTOM"], expected_decision="AUTO",
        source_path={"expected_node_ids": d4_b}, note="diaphragm 4 bottom chain flush"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_DIA5_BOT", weld_type="T", source_component="CM001_DIA_5",
        target_components=["CM001_BASE_BOTTOM"], expected_decision="AUTO",
        source_path={"expected_node_ids": d5_b},
        forbidden_reason_codes=["ANGLE_BORDERLINE"],
        note="diaphragm 5 tilted 15 deg off vertical -> 75 deg T, above the visible 70 deg threshold"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_DIA5_TOP", weld_type="T", source_component="CM001_DIA_5",
        target_components=["CM001_BASE_TOP"], expected_decision="AUTO",
        source_path={"expected_node_ids": d5_t},
        forbidden_reason_codes=["ANGLE_BORDERLINE"],
        note="diaphragm 5 top chain is also 75 deg and qualifies for AUTO"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_STIFF_BOT", weld_type="T", source_component="CM001_STIFF_LONG",
        target_components=["CM001_BASE_BOTTOM"], expected_decision="AUTO",
        source_path={"expected_node_ids": s_b},
        note="longitudinal stiffener flush between diaphragms 4 and 5"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_GUSSET", weld_type="PATCH", source_component="CM001_GUSSET_ROOF",
        target_components=["CM001_BASE_TOP"], expected_decision="AUTO",
        source_path={"expected_node_ids": gusset_ring},
        note="roof equipment plate fully contained above the roof top skin"))
    gt.add_weld(expect_weld(
        semantic_id="CM001_W_BRACKET", weld_type="T", source_component="CM001_BRACKET",
        target_components=["CM001_BASE_BOTTOM"], expected_decision="REVIEW",
        source_path={"expected_node_ids": br_b},
        required_reason_codes=["SKIN_ERROR_BORDERLINE"],
        allow_extra_targets=True,
        note="equipment bracket 6 mm proud of the bottom skin: phantom, never AUTO; "
             "its short length also grazes the DIA_1 side in the tolerant recognizer"))
    # recall-first tolerated rows: part end edges that stand ~5 mm clear of a
    # perpendicular partner face.  No physical weld exists (the parts never
    # touch), but the broadened contact envelope recalls them; the creation gate
    # owns the decision, so the corpus records them instead of failing.
    for diaphragm in ("CM001_DIA_1", "CM001_DIA_2", "CM001_DIA_3", "CM001_DIA_4"):
        for wall in ("CM001_SIDE_LEFT", "CM001_SIDE_RIGHT"):
            gt.add_tolerated(tolerated_candidate(
                diaphragm, wall,
                "diaphragm end edge stands ~5 mm clear of the wall inner skin; recalled by "
                "the contact envelope although no physical weld exists"))
    gt.add_tolerated(tolerated_candidate(
        "CM001_STIFF_LONG", "CM001_DIA_4",
        "stiffener end edge stands ~5 mm clear of the DIA_4 face; recalled by the contact "
        "envelope although no physical weld exists"))
    gt.add_analytic("component_roles", {
        "bottom": "CM001_BASE_BOTTOM", "roof": "CM001_BASE_TOP",
        "walls": ["CM001_SIDE_LEFT", "CM001_SIDE_RIGHT"],
        "diaphragms": ["CM001_DIA_1", "CM001_DIA_2", "CM001_DIA_3",
                       "CM001_DIA_4", "CM001_DIA_5"],
        "stiffener": "CM001_STIFF_LONG",
        "roof_patch": "CM001_GUSSET_ROOF",
        "bracket_distractor": "CM001_BRACKET",
    })
    return b, gt, {}


def _merge_composite(case_id: str, purpose: str, failure_mode: str,
                     factories: List[Tuple[str, Callable]]) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """Merge atomic factories into one collision-free model/GT.

    Atomic fixtures allocate IDs from small per-case blocks (case*1000 + ..),
    and several cases allocate more than 1000 nodes, so their raw blocks
    overlap.  Every entity id is therefore remapped onto one global ascending
    range with a 256-entry slack per case (node/element/component/property
    counters are independent).  Component and material ids travel together so
    the manifest and GT remain consistent.  Each island is also translated
    along X so independent cases never share a neighbourhood.
    """
    merged_model = CaseModel()
    gt = GroundTruth(case_id, "composite", purpose, failure_mode)
    hints: Dict[str, List[int]] = {}
    node_offset = 1
    elem_offset = 1
    comp_offset = 1
    pid_offset = 1
    for index, (case_key, factory) in enumerate(factories):
        ranges = case_id_range(int(case_key[2:5]))
        builder, sub_gt, sub_hints = factory(dict(ranges))
        # ---- collect raw ids so we can size the remap ----
        raw_nodes = sorted(builder.model.nodes)
        raw_comps = sorted(builder.model.components)
        raw_pids = sorted({comp.property_id for comp in builder.model.components.values()})
        raw_elems = sorted(builder.model.elements)
        if not raw_nodes:
            continue
        node_map = {node_id: node_offset + i for i, node_id in enumerate(raw_nodes)}
        comp_map = {comp_id: comp_offset + i for i, comp_id in enumerate(raw_comps)}
        pid_map = {pid: pid_offset + i for i, pid in enumerate(raw_pids)}
        elem_map = {elem_id: elem_offset + i for i, elem_id in enumerate(raw_elems)}
        node_offset += len(raw_nodes) + 256
        elem_offset += len(raw_elems) + 256
        comp_offset += len(raw_comps) + 64
        pid_offset += len(raw_pids) + 64
        # island X offset: every island lives in its own 1600 mm bay
        dx = float(index * 2000)
        for raw_id, node in builder.model.nodes.items():
            merged_model.nodes[node_map[raw_id]] = Node(
                node_map[raw_id], node.x + dx, node.y, node.z)
        # remap elements in place through the writer model (rebuild nodes refs)
        for elem_id, elem in builder.model.elements.items():
            merged_model.elements[elem_map[elem_id]] = ShellElem(
                element_id=elem_map[elem_id],
                component_id=comp_map[elem.component_id],
                element_type=elem.element_type,
                node_ids=[node_map[nid] for nid in elem.node_ids],
                property_id=pid_map[elem.property_id],
                zoffs=elem.zoffs,
                nodal_thickness=list(elem.nodal_thickness) if elem.nodal_thickness else None,
            )
        # components must carry the remapped component/property ids and names
        # (the writer derives names from the CaseModel.component dict)
        for comp_id, comp in builder.model.components.items():
            merged_model.components[comp_map[comp_id]] = Component(
                component_id=comp_map[comp_id],
                name=comp.name,
                thickness=comp.thickness,
                property_id=pid_map[comp.property_id],
            )
        # ---- GT: source paths point at raw node ids -> remap to merged ids ----
        # A weld's own source_path names its exact chain; a source component with
        # several seams (stiffener bottom->BASE and top->DOUBLER) therefore must
        # keep its own path and not fall back to the one-entry-per-component
        # hint chain, which only ever holds the primary seam.  Only the ids are
        # remapped here; physical start/end/length are recomputed later from the
        # merged (translated) coordinates in ``_finalise_gt_paths``.
        for weld in sub_gt.welds:
            weld = dict(weld)
            path = weld.get("source_path")
            merged_ids = None
            if path and path.get("expected_node_ids"):
                merged_ids = [node_map[int(v)] for v in path["expected_node_ids"]]
            else:
                chain = (sub_hints or {}).get(weld["source_component"])
                if chain:
                    merged_ids = [node_map[int(v)] for v in chain]
            if merged_ids:
                weld["source_path"] = {
                    "component": weld["source_component"],
                    "expected_node_ids": merged_ids,
                }
            gt.welds.append(weld)
        for forbidden in sub_gt.forbidden:
            gt.forbidden.append(dict(forbidden))
        # tolerated rows are name-based, so component names survive the remap
        for entry in sub_gt.tolerated:
            gt.tolerated.append(dict(entry))
        for key, value in sub_gt.analytic.items():
            gt.analytic["{}.{}".format(case_key, key)] = value
        for source_name, chain in (sub_hints or {}).items():
            hints[source_name] = [node_map[nid] for nid in chain]
    merged = ModelBuilder()
    merged.model = merged_model
    return merged, gt, hints


def _finalise_gt_paths(gt: GroundTruth, model: CaseModel) -> None:
    """Derive start/end/length for every weld path from the final model.

    Merged composites translate each island along X during assembly, so path
    geometry must be recomputed after the remap from the coordinates that
    actually landed in the FEM, never from a per-island pre-translation model.
    """
    for weld in gt.welds:
        path = weld.get("source_path")
        if not path or not path.get("expected_node_ids"):
            continue
        chain = [int(value) for value in path["expected_node_ids"]]
        points = [tuple(model.nodes[node_id].xyz) for node_id in chain]
        total = sum(
            sum((points[i][axis] - points[i - 1][axis]) ** 2 for axis in range(3)) ** 0.5
            for i in range(1, len(points))
        )
        path.update({
            "component": weld["source_component"],
            "expected_node_ids": chain,
            "start_xyz": list(points[0]),
            "end_xyz": list(points[-1]),
            "length": round(total, 6),
        })


def _atomic_factories() -> Dict[str, Callable]:
    registry = {}
    for module in (A01, A11, A21, A31, A41, A49):
        for attr in ("ATOMIC_CASES_001_010", "ATOMIC_CASES_011_020",
                     "ATOMIC_CASES_021_030", "ATOMIC_CASES_031_040",
                     "ATOMIC_CASES_041_048", "ATOMIC_CASES_049_050"):
            if hasattr(module, attr):
                registry.update(getattr(module, attr))
    return registry


_ADVERSARIAL = [
    "TC027_source_inner_boundary", "TC046_coplanar_butt", "TC042_web_junction",
    "TC030_projection_jump", "TC010_islands_same_component", "TC021_angle_70",
    "TC043_dependency_cycle",
]


def cm002_adversarial_composite(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    factories = [(key, _atomic_factories()[key]) for key in _ADVERSARIAL]
    return _merge_composite(
        "CM002", "adversarial junction composite",
        "interaction of the known failure modes in one model", factories)


def cm003_full_corpus(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    registry = _atomic_factories()
    factories = [(key, factory) for key, factory in sorted(registry.items())]
    return _merge_composite(
        "CM003", "full-corpus composite",
        "every atomic case merged into one FEM; the recognizer must reproduce every "
        "expected weld and every forbidden relation in a single detection pass",
        factories)


def cm004_performance(ranges) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    """A long base plate carrying 30 flush T webs (runtime / scale regression)."""
    b = ModelBuilder(**ranges)
    from geo_helpers import flat_target
    flat_target(b, "CM004_BASE", 0.0, 2200.0, -800.0, 800.0, 0.0, 10.0, h=20.0)
    hints: Dict[str, List[int]] = {}
    for strip in range(30):
        x0 = 20.0 + strip * 72.0
        _cid, bot, _top = _x_web(b, "CM004_WEB_{:02d}".format(strip),
                                 x0, x0 + 40.0, -700.0 + (strip % 3) * 200.0,
                                 5.0, 105.0)
        hints["CM004_WEB_{:02d}".format(strip)] = bot
    gt = GroundTruth("CM004", "composite", "performance strip of flush T welds",
                     "30 identical flush T welds over one long base: detection must return "
                     "all of them without spurious rows, in bounded time",
                     decision_policy={"performance": True, "expected_min_auto": 30})
    for strip in range(30):
        name = "CM004_WEB_{:02d}".format(strip)
        gt.add_weld(expect_weld(
            semantic_id="CM004_W_{:02d}".format(strip), weld_type="T",
            source_component=name, target_components=["CM004_BASE"],
            expected_decision="AUTO", source_path={"expected_node_ids": hints[name]},
            note="flush T strip {}".format(strip)))
    return b, gt, hints


_COMPOSITE_CASE_FACTORIES = {
    "CM001_box_rail": cm001_box_rail,
    "CM002_adversarial_composite": cm002_adversarial_composite,
    "CM003_full_corpus": cm003_full_corpus,
    "CM004_performance": cm004_performance,
}


def _build_case(case_key: str) -> Tuple[ModelBuilder, GroundTruth, Dict[str, List[int]]]:
    factory = _COMPOSITE_CASE_FACTORIES[case_key]
    base = int(case_key[2:5]) * 1000 + 200_000  # composites live far above atomics
    ranges = {
        "node_base": base,
        "elem_base": base + 1_000_000,
        "comp_base": base + 2_000_000,
        "pid_base": base + 3_000_000,
    }
    return factory(ranges)


def generate_composites(output_root: Path, selected=None) -> list:
    """Emit every composite under composite/<case_id> and return descriptors."""
    rows = []
    for case_key in sorted(_COMPOSITE_CASE_FACTORIES):
        if selected and case_key not in selected:
            continue
        builder, gt, hints = _build_case(case_key)
        _finalise_gt_paths(gt, builder.model)
        case_dir = composite_subdir(output_root, case_key)
        case_dir.mkdir(parents=True, exist_ok=True)
        manifest_path = write_fem_bundle(
            builder.model, case_dir / "input.fem", case_dir / "input_manifest.json",
            section_banners=component_banners(builder.model))
        gt_path = case_dir / "ground_truth.json"
        gt.write(gt_path)
        write_weld_csv(gt.to_dict(), case_dir / "ground_truth.csv")
        rows.append({
            "case_id": case_key,
            "kind": "composite",
            # corpus-relative paths so fixture_manifest.json stays portable
            "fem": str(case_dir.relative_to(output_root) / "input.fem"),
            "manifest": str(case_dir.relative_to(output_root) / "input_manifest.json"),
            "ground_truth": str(case_dir.relative_to(output_root) / "ground_truth.json"),
            "node_count": len(builder.model.nodes),
            "element_count": len(builder.model.elements),
            "component_count": len(builder.model.components),
            "expected_auto": sum(1 for weld in gt.welds if weld["expected_decision"] == "AUTO"),
            "expected_review": sum(1 for weld in gt.welds if weld["expected_decision"] == "REVIEW"),
        })
    return rows
