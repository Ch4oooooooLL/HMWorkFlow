"""CLI orchestrator for solid seam candidate recognition."""
from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

# The bundled Windows Python runtime uses python38._pth isolation and does not
# automatically add the executed script's directory to sys.path. HyperMesh
# launches this file directly, so make sibling modules importable explicitly
# before importing any solid_seam module.
MODULE_DIR = str(Path(__file__).resolve().parent)
if MODULE_DIR not in sys.path:
    sys.path.insert(0, MODULE_DIR)

from candidate_detector import detect_edges
from confidence import calculate
from duplicate_detector import classify as classify_duplicate
from edge_chain_builder import build_chains
from fem_mesh_reader import read_fem
from geometry import bbox, expanded_bbox_intersects
from joint_classifier import classify as classify_joint
from mesh_reader import load_json, read_mesh
from result_validator import validate_results
from result_writer import write_json, write_tcl
from realization_parameter_selector import select as select_realization_parameters
from schema import SchemaError, validate_request
from schema import MeshModel
from solid_edge_extractor import extract_candidate_edges
from solid_surface_extractor import extract_surface_faces
from shell_surface_extractor import extract_shell_faces
from spatial_index import TriangleIndex
from target_surface_builder import build_target_surface


def component_pairs(request):
    solids, shells = request["solid_component_ids"], request["shell_component_ids"]
    if request["mode"] == "SOLID_SOLID_PAIR":
        return [(request.get("source_component_ids", solids)[0], request.get("target_component_ids", solids[1:])[0])]
    if request["mode"] == "SHELL_SHELL_PAIR":
        return [(request["source_component_ids"][0], request["target_component_ids"][0])]
    return [(solid, shell) for solid in solids for shell in shells]


def classify_workflow(request, model):
    selected = request["selected_component_ids"]
    missing = set(selected) - set(model.components)
    if missing:
        raise SchemaError(f"selected components are missing from FEM: {sorted(missing)}")
    solids = [cid for cid in selected if model.components[cid].mesh_class == "SOLID"]
    shells = [cid for cid in selected if model.components[cid].mesh_class == "SHELL"]
    if len(selected) == 2 and len(solids) == 2:
        mode, review = "SOLID_SOLID_PAIR", False
    elif len(selected) == 2 and len(shells) == 2:
        mode, review = "SHELL_SHELL_PAIR", False
    elif solids and shells:
        mode, review = "MIXED_COMPONENTS", True
    else:
        raise SchemaError("selection must be two solids, two shells, or mixed components containing a solid")
    primary = request.get("primary_component_ids", selected)
    secondary = request.get("secondary_component_ids", [])
    ordered = primary + secondary
    result = dict(request)
    result.update(mode=mode, requires_review=review, solid_component_ids=solids, shell_component_ids=shells)
    if not review:
        result.update(source_component_ids=[ordered[0]], target_component_ids=[ordered[1]])
    return result


def read_selected_mesh(paths, selected_component_ids):
    if len(paths) == 1 and paths[0].suffix.lower() not in {".fem", ".bdf", ".dat"}:
        return read_mesh(paths[0])
    if len(paths) != len(selected_component_ids):
        raise SchemaError("one FEM file is required for each selected component")
    components, nodes, elements = {}, {}, []
    for path, component_id in zip(paths, selected_component_ids):
        part = read_fem(path, component_id=component_id)
        components.update(part.components)
        for node_id, xyz in part.nodes.items():
            if node_id in nodes and nodes[node_id] != xyz:
                raise SchemaError(f"GRID {node_id} has inconsistent coordinates across FEM files")
            nodes[node_id] = xyz
        elements.extend(part.elements)
    return MeshModel(components, nodes, elements, [])


def detect(request, model, logger):
    settings = request["settings"]
    surface_cache, edge_cache, target_cache = {}, {}, {}
    candidates = []
    for source_id, target_id in component_pairs(request):
        if source_id not in surface_cache:
            surface_cache[source_id] = (extract_surface_faces(model, source_id) if model.components[source_id].mesh_class == "SOLID" else extract_shell_faces(model, source_id))
            edge_cache[source_id] = extract_candidate_edges(model, surface_cache[source_id][0], float(settings["feature_angle_deg"]), model.components[source_id].mesh_class)
            for warning in surface_cache[source_id][1]:
                logger.warning("source=%s %s", source_id, warning)
        if target_id not in target_cache:
            target_cache[target_id] = build_target_surface(model, target_id)
        triangles, target_bbox = target_cache[target_id]
        edges = edge_cache[source_id]
        if not triangles or not edges:
            continue
        source_bbox = bbox(model.nodes[node] for edge in edges for node in edge.node_ids)
        if not expanded_bbox_intersects(source_bbox, target_bbox, float(settings["max_search_distance"])):
            logger.info("skip pair %s->%s: bounding boxes do not intersect", source_id, target_id)
            continue
        detected = detect_edges(model, edges, TriangleIndex(triangles), settings)
        for chain in build_chains(model, detected, settings):
            if chain["is_closed"] and not settings.get("allow_closed_loop", True):
                continue
            joint, realization, joint_score = classify_joint(chain)
            oriented_nodes, realization_parameters = select_realization_parameters(model, source_id, chain, settings, joint)
            confidence, level, average, maximum, ratio = calculate(chain, settings, joint_score)
            edge_classes = {item.edge.edge_class for item in chain["items"]}
            candidate = {
                "candidate_id": f"C{len(candidates) + 1:04d}",
                "source_solid": {"component_id": source_id, "component_name": model.components[source_id].component_name},
                "target_component": {"component_id": target_id, "component_name": model.components[target_id].component_name, "mesh_class": model.components[target_id].mesh_class},
                "connection_mode": f"{model.components[source_id].mesh_class}_{model.components[target_id].mesh_class}",
                "edge_class": "MIXED" if len(edge_classes) > 1 else next(iter(edge_classes)),
                "node_ids": oriented_nodes,
                "edge_ids": [list(item.edge.node_ids) for item in chain["items"]],
                "is_closed": chain["is_closed"], "joint_type": joint, "suggested_realization": realization,
                "length": round(chain["length"], 6), "average_distance": round(average, 6), "maximum_distance": round(maximum, 6), "valid_ratio": round(ratio, 6),
                "confidence": round(confidence, 6), "confidence_level": level, "duplicate_state": "NONE", "warnings": list(chain["warnings"]), "status": "PENDING",
                "realization_parameters": realization_parameters,
            }
            duplicate = classify_duplicate(candidate, model.existing_connectors, candidates) if settings.get("detect_duplicates", True) else "NONE"
            candidate["duplicate_state"] = duplicate
            if duplicate != "NONE":
                candidate["warnings"].append("DUPLICATE_" + duplicate)
                candidate["confidence"] = round(max(0.0, candidate["confidence"] - (0.35 if duplicate == "CONFIRMED" else 0.15)), 6)
                candidate["confidence_level"] = "LOW" if duplicate == "CONFIRMED" else candidate["confidence_level"]
            candidates.append(candidate)
    validate_results(candidates, model)
    return candidates


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True, type=Path)
    parser.add_argument("--mesh", required=True, type=Path, action="append")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tcl-output", type=Path)
    parser.add_argument("--log", type=Path)
    args = parser.parse_args(argv)
    logger = logging.getLogger("solid_seam")
    handler = logging.FileHandler(str(args.log), encoding="utf-8") if args.log else logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.setLevel(logging.INFO)
    logger.propagate = False
    logger.addHandler(handler)
    try:
        request = validate_request(load_json(args.request))
        model = read_selected_mesh(args.mesh, request["selected_component_ids"])
        if "requires_review" not in request:
            request = classify_workflow(request, model)
        candidates = detect(request, model, logger)
        summary = {"candidate_count": len(candidates), "high_confidence_count": sum(c["confidence_level"] == "HIGH" for c in candidates), "review_count": sum(c["confidence_level"] == "REVIEW" for c in candidates), "low_confidence_count": sum(c["confidence_level"] == "LOW" for c in candidates)}
        payload = {"schema_version": "1.0", "run_id": request["run_id"], "mode": request["mode"], "requires_review": request.get("requires_review", request["mode"] in {"MIXED_COMPONENTS", "MULTI_SOLID_SHELL"}), "summary": summary, "candidates": candidates}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        write_json(args.output, payload)
        write_tcl(args.tcl_output or args.output.with_suffix(".tcl"), candidates, payload)
        logger.info("complete candidates=%d", len(candidates))
        return 0
    except Exception as exc:
        logger.exception("solid seam detection failed")
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    finally:
        logger.removeHandler(handler)
        handler.close()


if __name__ == "__main__":
    raise SystemExit(main())
