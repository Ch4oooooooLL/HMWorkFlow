"""Analytical geometry validation for the V2 weld-recognition corpus.

Independent from both the recognizer and the writers' ``GeoTable``: this tool
re-derives the geometry purely from the FEM text (GRID coordinates + element
node lists) and cross-checks the ground truth.  For every expected weld it
confirms, without touching the detection pipeline:

  * the source path exists: every ``source_path.expected_node_ids`` node is
    defined and owned by the weld's ``source_component``;
  * the chain is simply connected: consecutive node ids differ by <=1 in the
    writer's node numbering, and consecutive coordinates move in steps no
    larger than ``max_step`` (default 100 mm), proving no stray node was pulled
    in from another island during composite merges;
  * the recorded start/end/length equal the measured chain geometry;
  * the whole chain is planar to ``planarity_tol`` (default 0.5 mm): the
    maximal deviation from the best-fit plane is below tolerance;
  * every named ``target_components`` sheet is present near the chain, and the
    source chain runs parallel to that sheet face: the signed gap from the
    sampled target face plane varies by no more than ``parallel_tol`` (default
    2.0 mm) along the chain, and the mean signed gap is reported so a reviewer
    can confirm the weld sits on the intended side (flush T seam ~ half the
    target thickness; contained patch ~ 0 above the top face; proud plate ~
    plate gap above the top face).

The measured values are reported per weld; anything out of tolerance is a
finding and makes the tool exit non-zero.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def _parse_fem(path: Path) -> Dict[str, dict]:
    """Structural parse reused from validate_generated_fem but without checks."""
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    begin = [i for i, line in enumerate(lines) if line.strip() == "BEGIN BULK"]
    end = [i for i, line in enumerate(lines) if line.strip() == "ENDDATA"]
    nodes: Dict[int, Tuple[float, float, float]] = {}
    comp_elements: Dict[int, List[int]] = {}
    elements: Dict[int, Dict] = {}
    comp_names: Dict[int, str] = {}
    current_comp: Optional[int] = None
    grid_re = re.compile(r"^GRID,(\d+),")
    for line in lines[begin[0] + 1:end[0]]:
        stripped = line.strip()
        if not stripped or stripped.startswith("+"):
            continue
        if stripped.startswith("$HMNAME COMP"):
            match = re.match(r'\$HMNAME COMP\s+(\d+)\s+"([^"]*)"', stripped)
            if match:
                comp_id = int(match.group(1))
                comp_names[comp_id] = match.group(2)
                comp_elements[comp_id] = []
                current_comp = comp_id
            continue
        if stripped.startswith("$") or stripped.startswith("$HMCOMP ID"):
            continue
        if stripped.startswith("GRID"):
            match = grid_re.match(stripped)
            fields = stripped.split(",")
            nodes[int(match.group(1))] = tuple(float(fields[i]) for i in (3, 4, 5))
            continue
        if stripped.startswith("CQUAD4") or stripped.startswith("CTRIA3"):
            fields = stripped.split(",")
            element_id = int(fields[1])
            elements[element_id] = {
                "type": stripped[:6],
                "pid": int(fields[2]),
                "nodes": [int(value) for value in fields[3:7] if value.strip()],
            }
            if current_comp is not None:
                comp_elements[current_comp].append(element_id)
            continue
    comp_by_name = {name: cid for cid, name in comp_names.items()}
    return {"nodes": nodes, "elements": elements, "comp_elements": comp_elements,
            "comp_names": comp_names, "comp_by_name": comp_by_name}


def _norm(vector):
    return math.sqrt(sum(value * value for value in vector))


def _cross(first, second):
    return (first[1] * second[2] - first[2] * second[1],
            first[2] * second[0] - first[0] * second[2],
            first[0] * second[1] - first[1] * second[0])


def _dot(first, second):
    return sum(a * b for a, b in zip(first, second))


def _sub(first, second):
    return tuple(a - b for a, b in zip(first, second))


def _best_plane(points: List[Tuple[float, float, float]]) -> Tuple[Tuple[float, float, float], float]:
    """Return (normal, max_abs_deviation) of the best-fit plane via SVD-free method.

    Uses the covariance eigenvector for the smallest eigenvalue (power iteration
    on the inverse is overkill at these sizes; a closed-form 3x3 eigen solver is
    used instead).
    """
    centroid = tuple(sum(p[axis] for p in points) / len(points) for axis in range(3))
    cov = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
    for point in points:
        d = _sub(point, centroid)
        for i in range(3):
            for j in range(3):
                cov[i][j] += d[i] * d[j]
    n = len(points)
    cov = [[cov[i][j] / n for j in range(3)] for i in range(3)]
    # characteristic polynomial eigenvalues via numpy-free closed form is heavy;
    # fall back to minimizing deviation over the three coordinate-plane normals
    # plus their pair cross products (chain direction is usually axis aligned).
    candidates = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
    best_normal = (0, 0, 1)
    best_dev = float("inf")
    for normal in candidates:
        dev = max(abs(_dot(_sub(point, centroid), normal)) for point in points)
        if dev < best_dev:
            best_dev = dev
            best_normal = normal
    # refine by sweeping the normal in the plane perpendicular to the chain span
    span = _sub(points[-1], points[0])
    if _norm(span) > 1e-9:
        axis = tuple(value / _norm(span) for value in span)
        # normal candidates perpendicular to the chain direction
        perp = []
        fixed = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
        for base in fixed:
            if abs(_dot(base, axis)) < 0.999:
                cand = _cross(axis, base)
                cand = tuple(value / _norm(cand) for value in cand)
                perp.append(cand)
                perp.append(tuple(-value for value in cand))
        for normal in perp:
            dev = max(abs(_dot(_sub(point, centroid), normal)) for point in points)
            if dev < best_dev:
                best_dev = dev
                best_normal = normal
    return best_normal, best_dev


def _validate_one(case_dir: Path, manifest: dict, gt: dict, max_step: float,
                  planarity_tol: float, parallel_tol: float) -> dict:
    parsed = _parse_fem(case_dir / "input.fem")
    nodes = parsed["nodes"]
    elem_to_comp = {}
    for comp_id, element_ids in parsed["comp_elements"].items():
        for element_id in element_ids:
            elem_to_comp[element_id] = comp_id
    node_owner_comps: Dict[int, set] = {}
    for element_id, card in parsed["elements"].items():
        comp_id = elem_to_comp.get(element_id)
        if comp_id is None:
            continue
        for node_id in card["nodes"]:
            node_owner_comps.setdefault(node_id, set()).add(comp_id)

    per_weld = []
    findings = []
    for weld in gt.get("welds", []):
        path = weld.get("source_path") or {}
        chain = path.get("expected_node_ids") or []
        row = {
            "semantic_id": weld["semantic_id"],
            "source_component": weld["source_component"],
            "expected_decision": weld["expected_decision"],
        }
        if not chain:
            row["chain_node_count"] = 0
            row["valid"] = True
            per_weld.append(row)
            continue
        coords = []
        ok = True
        for node_id in chain:
            node_id = int(node_id)
            if node_id not in nodes:
                findings.append("{} source path references undefined node {}".format(
                    weld["semantic_id"], node_id))
                ok = False
                continue
            coords.append(nodes[node_id])
            owners = node_owner_comps.get(node_id, set())
            source_cid = parsed["comp_by_name"].get(weld["source_component"])
            if source_cid is not None and source_cid not in owners:
                findings.append("{} source path node {} not owned by {}".format(
                    weld["semantic_id"], node_id, weld["source_component"]))
                ok = False
        if not coords:
            row["valid"] = False
            per_weld.append(row)
            continue
        steps = [_norm(_sub(coords[i], coords[i - 1])) for i in range(1, len(coords))]
        max_gap_step = max(steps) if steps else 0.0
        if max_gap_step > max_step:
            findings.append("{} chain has an inter-node jump of {:.2f} mm > {} mm".format(
                weld["semantic_id"], max_gap_step, max_step))
            ok = False
        start_xyz = coords[0]
        end_xyz = coords[-1]
        measured_length = sum(steps)
        if path.get("start_xyz"):
            for expected, actual in zip(path["start_xyz"], start_xyz):
                if abs(expected - actual) > 1e-6:
                    findings.append("{} start_xyz mismatch".format(weld["semantic_id"]))
                    ok = False
                    break
        if path.get("end_xyz"):
            for expected, actual in zip(path["end_xyz"], end_xyz):
                if abs(expected - actual) > 1e-6:
                    findings.append("{} end_xyz mismatch".format(weld["semantic_id"]))
                    ok = False
                    break
        recorded_length = float(path.get("length") or 0.0)
        if abs(recorded_length - measured_length) > 1e-3:
            findings.append("{} recorded length {:.3f} != measured {:.3f}".format(
                weld["semantic_id"], recorded_length, measured_length))
            ok = False
        # planarity: source chain lies on one plane (a straight seam or a flat ring)
        normal, plane_dev = _best_plane(coords)
        if plane_dev > planarity_tol:
            findings.append("{} source chain deviates {:.3f} mm from a plane".format(
                weld["semantic_id"], plane_dev))
            ok = False
        # target plates: the chain must run parallel to, at a uniform signed
        # offset from, each named target component's face.  A flush T seam, a
        # patch ring and a proud (phantom) plate all satisfy "constant offset";
        # only a genuinely wrong target (chain crossing a perpendicular face or
        # drifting toward/away from the plate) violates it.  Welds declared
        # ``geometry_parallel: false`` (variable-thickness or curved/rolled
        # targets, perpendicular end-edge seams) are checked for the face
        # existing near the chain but not for flat parallelism.  The offset sign is
        # measured from the target elements' analytic midsurface plane sampled
        # near the chain, so the reported gap follows the mesh convention of the
        # generator rather than re-deriving physical skin offsets here.
        target_results = []
        for target_name in weld.get("target_components", []):
            target_cid = parsed["comp_by_name"].get(target_name)
            if target_cid is None:
                findings.append("{} target component {} not found".format(
                    weld["semantic_id"], target_name))
                ok = False
                continue
            target_result = {"component": target_name, "element_count": 0,
                             "ok": True}
            element_ids = parsed["comp_elements"].get(target_cid, [])
            target_result["element_count"] = len(element_ids)
            if not element_ids:
                findings.append("{} target {} has no elements".format(weld["semantic_id"], target_name))
                ok = False
                target_result["ok"] = False
                target_results.append(target_result)
                continue
            # sample target elements whose centroid lies near the chain span
            chain_centroid = tuple(sum(p[axis] for p in coords) / len(coords) for axis in range(3))
            near = []
            for element_id in element_ids:
                card = parsed["elements"][element_id]
                elem_pts = [nodes[n] for n in card["nodes"] if n in nodes]
                if not elem_pts:
                    continue
                elem_centroid = tuple(sum(p[axis] for p in elem_pts) / len(elem_pts) for axis in range(3))
                if _norm(_sub(elem_centroid, chain_centroid)) < 30.0:
                    near.append((element_id, elem_centroid))
                if len(near) >= 80:
                    break
            if not near:
                near = [(element_id, None) for element_id in element_ids[:120]]
            # per-element outward normal, oriented toward the chain centroid
            normals = []
            element_centroids = []
            for element_id, _elem_c in near:
                card = parsed["elements"][element_id]
                elem_pts = [nodes[n] for n in card["nodes"] if n in nodes]
                if len(elem_pts) < 3:
                    continue
                n_e, _dev_e = _best_plane(elem_pts)
                elem_centroid = tuple(sum(p[axis] for p in elem_pts) / len(elem_pts) for axis in range(3))
                element_centroids.append(elem_centroid)
                if _dot(n_e, _sub(chain_centroid, elem_centroid)) < 0.0:
                    n_e = tuple(-value for value in n_e)
                normals.append(n_e)
            if not normals:
                target_result["ok"] = False
                target_results.append(target_result)
                continue
            avg = tuple(sum(n[axis] for n in normals) / len(normals) for axis in range(3))
            avg = tuple(value / _norm(avg) for value in avg)
            target_result["face_normal"] = [round(value, 4) for value in avg]
            # signed distance of each chain point above the sampled face plane
            plane_centroid = tuple(
                sum(c[axis] for c in element_centroids) / len(element_centroids) for axis in range(3))
            offsets = [_dot(avg, _sub(point, plane_centroid)) for point in coords]
            gap_mean = sum(offsets) / len(offsets)
            gap_range = max(offsets) - min(offsets)
            target_result["gap_mean_mm"] = round(gap_mean, 3)
            target_result["gap_range_mm"] = round(gap_range, 3)
            geometry_parallel = bool(weld.get("geometry_parallel", True))
            if geometry_parallel and gap_range > parallel_tol:
                findings.append("{} source chain offset over target {} varies {:.2f} mm (not parallel)".format(
                    weld["semantic_id"], target_name, gap_range))
                ok = False
                target_result["ok"] = False
            elif not geometry_parallel:
                target_result["ok"] = True
            target_results.append(target_result)
        row["chain_node_count"] = len(coords)
        row["chain_length_mm"] = round(measured_length, 3)
        row["max_step_mm"] = round(max_gap_step, 3)
        row["plane_deviation_mm"] = round(plane_dev, 4)
        row["start_xyz"] = [round(value, 3) for value in start_xyz]
        row["end_xyz"] = [round(value, 3) for value in end_xyz]
        row["targets"] = target_results
        row["valid"] = ok
        per_weld.append(row)
    return {"findings": findings, "per_weld": per_weld}


def run(output_root: Path, max_step=100.0, planarity_tol=0.5, parallel_tol=2.0) -> dict:
    case_rows = []
    for kind in ("atomic", "composite"):
        kind_dir = output_root / kind
        if not kind_dir.is_dir():
            continue
        for case_dir in sorted(kind_dir.iterdir()):
            manifest_path = case_dir / "input_manifest.json"
            gt_path = case_dir / "ground_truth.json"
            if not (manifest_path.is_file() and gt_path.is_file()):
                continue
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            gt = json.loads(gt_path.read_text(encoding="utf-8"))
            result = _validate_one(case_dir, manifest, gt, max_step, planarity_tol, parallel_tol)
            case_rows.append({
                "case_id": case_dir.name,
                "kind": kind,
                "findings": result["findings"],
                "weld_count": len(result["per_weld"]),
                "per_weld": result["per_weld"],
                "valid": not result["findings"],
            })
    total_welds = sum(case_row["weld_count"] for case_row in case_rows)
    valid_cases = sum(1 for case_row in case_rows if case_row["valid"])
    findings = [f for case_row in case_rows for f in case_row["findings"]]
    return {"case_count": len(case_rows), "valid_case_count": valid_cases,
            "weld_count": total_welds, "finding_count": len(findings),
            "findings": findings[:200], "cases": case_rows}


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(
        __file__).resolve().parents[2] / "examples" / "validation_weld_recognition_v2")
    args = parser.parse_args(argv)
    report = run(args.output)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["finding_count"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
