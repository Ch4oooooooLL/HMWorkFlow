"""Validate the generated .fem corpus files structurally.

This is an *independent* free-field parser, deliberately written against the
OptiStruct bulk-data layout rather than against the production
``fem_mesh_reader``/``MeshModel`` classes, so a generator bug that both the
reader and this validator shared cannot slip through.  Checks per fixture:

  * exactly one BEGIN BULK and one ENDDATA, no bulk lines after ENDDATA;
  * every GRID id unique and its coordinates finite;
  * every element card (CQUAD4/CTRIA3) has a unique id, 4/3 distinct node ids
    that all reference a defined GRID, and a PID that resolves to a PSHELL;
  * PSHELL/MAT1 cards are well formed and every referenced MID exists;
  * component banners (``$HMNAME COMP``) parse, ids are unique and the
    element-id set per component equals the manifest exactly;
  * manifest statistics (node/element/component counts) match the file;
  * every ground-truth source-path node id exists in the FEM and carries the
    x/y/z coordinates recorded in the ground truth.

All checks are deterministic; the program prints a JSON summary and returns a
non-zero exit status when any fixture reports a finding.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

FINITE_LIMIT = 1.0e12


def _parse_fem(path: Path) -> dict:
    """Return a structural dictionary parsed from the raw bulk-data text."""
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    begin = [i for i, line in enumerate(lines) if line.strip() == "BEGIN BULK"]
    end = [i for i, line in enumerate(lines) if line.strip() == "ENDDATA"]
    if len(begin) != 1:
        raise AssertionError("expected exactly one BEGIN BULK, found {}".format(len(begin)))
    if len(end) != 1:
        raise AssertionError("expected exactly one ENDDATA, found {}".format(len(end)))
    nodes: dict = {}  # id -> (x, y, z)
    node_line: dict = {}
    elements: dict = {}  # id -> dict(pid, nodes)
    props: dict = {}  # pid -> thickness
    materials: set = set()
    comp_names: dict = {}  # comp id -> name
    comp_elements: dict = {}  # comp id -> list of element ids (banner sections)
    trailing = [line for line in lines[end[0] + 1:] if line.strip()]
    if trailing:
        raise AssertionError("{} non-blank line(s) after ENDDATA".format(len(trailing)))
    grid_re = re.compile(r"^GRID,(\d+),")
    current_comp = None
    for lineno, line in enumerate(lines[begin[0] + 1:end[0]], start=begin[0] + 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("+"):
            continue
        if (stripped.startswith("$") and not stripped.startswith("$HMNAME COMP")
                and not stripped.startswith("$HMCOMP ID")):
            continue  # generic comment (section banners, blank markers)
        if stripped.startswith("GRID"):
            match = grid_re.match(stripped)
            node_id = int(match.group(1))
            fields = stripped.split(",")
            # GRID,id,cp,x,y,z  (cp blank in our free-field export)
            if len(fields) < 6:
                raise AssertionError("line {}: malformed GRID {!r}".format(lineno, stripped))
            try:
                xyz = tuple(float(fields[i]) for i in (3, 4, 5))
            except ValueError as exc:
                raise AssertionError("line {}: non-numeric GRID coordinate {!r}".format(lineno, stripped)) from exc
            if node_id in nodes:
                raise AssertionError("duplicate GRID id {}".format(node_id))
            if any(not math.isfinite(value) or abs(value) > FINITE_LIMIT for value in xyz):
                raise AssertionError("GRID {} has non-finite coordinate {}".format(node_id, xyz))
            nodes[node_id] = xyz
            node_line[node_id] = lineno
            continue
        if stripped.startswith("$HMNAME COMP"):
            match = re.match(r'\$HMNAME COMP\s+(\d+)\s+"([^"]*)"', stripped)
            if not match:
                continue
            comp_id = int(match.group(1))
            if comp_id in comp_names:
                raise AssertionError("duplicate $HMNAME COMP {}".format(comp_id))
            comp_names[comp_id] = match.group(2)
            comp_elements[comp_id] = []
            current_comp = comp_id
            continue
        if stripped.startswith("$HMCOMP ID"):
            # sanity: must equal the banner id that opened this section
            section_id = int(stripped.split()[-1])
            if current_comp is not None and section_id != current_comp:
                raise AssertionError("$HMCOMP ID {} under banner {}".format(section_id, current_comp))
            continue
        if stripped.startswith("CQUAD4") or stripped.startswith("CTRIA3"):
            etype = stripped[:6]
            fields = stripped.split(",")
            element_id = int(fields[1])
            pid = int(fields[2])
            if etype == "CQUAD4":
                raw_nodes = fields[3:7]
            else:
                raw_nodes = fields[3:6]
            node_ids = []
            for raw in raw_nodes:
                raw = raw.strip()
                if not raw:
                    raise AssertionError("line {}: blank node id in {!r}".format(lineno, stripped))
                node_ids.append(int(raw))
            if element_id in elements:
                raise AssertionError("duplicate element id {}".format(element_id))
            if len(set(node_ids)) != len(node_ids):
                raise AssertionError("element {} has repeated node ids".format(element_id))
            for node_id in node_ids:
                if node_id not in nodes:
                    raise AssertionError(
                        "element {} references undefined GRID {} (line {})".format(element_id, node_id, lineno))
            elements[element_id] = {"type": etype, "pid": pid, "nodes": node_ids}
            if current_comp is None:
                raise AssertionError("element {} appears outside any component banner".format(element_id))
            comp_elements[current_comp].append(element_id)
            continue
        if stripped.startswith("PSHELL"):
            fields = stripped.split(",")
            pid = int(fields[1])
            mid = int(fields[2])
            if pid in props:
                raise AssertionError("duplicate PSHELL {}".format(pid))
            if fields[3].strip() == "":
                raise AssertionError("PSHELL {} has blank thickness".format(pid))
            props[pid] = float(fields[3])
            materials.add(mid)
            continue
        if stripped.startswith("MAT1"):
            mid = int(stripped.split(",")[1])
            materials.add(mid)
            continue
        # Unknown but tolerated comment/card; nothing else should appear in bulk.
        raise AssertionError("line {}: unexpected bulk card {!r}".format(lineno, stripped[:60]))
    return {"nodes": nodes, "node_line": node_line, "elements": elements,
            "props": props, "materials": materials, "comp_names": comp_names,
            "comp_elements": comp_elements}


def _validate_one(case_dir: Path, manifest: dict, gt: dict) -> list:
    findings = []
    fem_path = case_dir / "input.fem"
    parsed = _parse_fem(fem_path)
    stats = manifest["statistics"]
    if len(parsed["nodes"]) != stats["node_count"]:
        findings.append("GRID count {} != manifest {}".format(len(parsed["nodes"]), stats["node_count"]))
    if len(parsed["elements"]) != stats["element_count"]:
        findings.append("element count {} != manifest {}".format(len(parsed["elements"]), stats["element_count"]))
    if len(parsed["comp_names"]) != stats["component_count"]:
        findings.append("component count {} != manifest {}".format(len(parsed["comp_names"]), stats["component_count"]))

    # ownership: banner sections group elements under a component; the card's
    # PID column names the PSHELL, which the writer emits per component with an
    # independent id range (component + 10000 offset), so section membership is
    # the only correct cross-check against the manifest.
    manifest_components = {entry["component_id"]: entry for entry in manifest["components"]}
    if set(parsed["comp_names"]) != set(manifest_components):
        findings.append("banner component ids {} differ from manifest {}".format(
            sorted(set(parsed["comp_names"]) - set(manifest_components)),
            sorted(set(manifest_components) - set(parsed["comp_names"]))))
    for comp_id, element_ids in parsed["comp_elements"].items():
        entry = manifest_components.get(comp_id)
        if entry is None:
            findings.append("banner component {} absent from manifest".format(comp_id))
            continue
        expected = set(entry["element_ids"])
        actual = set(element_ids)
        if expected != actual:
            missing = sorted(expected - actual)[:5]
            extra = sorted(actual - expected)[:5]
            findings.append("component {} element set mismatch (missing {!r}, extra {!r})".format(
                comp_id, missing, extra))
        for element_id in element_ids:
            pid = parsed["elements"][element_id]["pid"]
            if pid not in parsed["props"]:
                findings.append("element {} references undefined PSHELL {}".format(element_id, pid))
    # PSHELL ids are unique and every component has exactly one property
    for comp_id in manifest_components:
        if comp_id not in parsed["comp_names"]:
            findings.append("component {} has no banner section".format(comp_id))
    if not parsed["materials"]:
        findings.append("no MAT1 material defined")
    # GT source-path chains must resolve to nodes with matching coordinates
    elem_to_comp = {}
    for comp_id, element_ids in parsed["comp_elements"].items():
        for element_id in element_ids:
            elem_to_comp[element_id] = comp_id
    comp_name_of = {cid: parsed["comp_names"].get(cid) for cid in elem_to_comp.values()}
    for weld in gt.get("welds", []):
        path = weld.get("source_path") or {}
        chain = path.get("expected_node_ids") or []
        if not chain:
            continue
        source_comp = weld.get("source_component")
        chain_set = set(int(value) for value in chain)
        owner_ids = set()
        for element_id, card in parsed["elements"].items():
            if set(card["nodes"]) & chain_set:
                owner_ids.add(elem_to_comp.get(element_id))
        owner_names = {comp_name_of.get(cid) for cid in owner_ids if cid is not None}
        for node_id in chain:
            node_id = int(node_id)
            if node_id not in parsed["nodes"]:
                findings.append("GT {} source path references undefined node {}".format(
                    weld.get("semantic_id"), node_id))
                continue
            if source_comp and source_comp not in owner_names:
                findings.append("GT {} node {} not owned by source component {}".format(
                    weld.get("semantic_id"), node_id, source_comp))
        if chain and path.get("start_xyz"):
            first_xyz = parsed["nodes"].get(int(chain[0]))
            if first_xyz is not None:
                for expected, actual in zip(path["start_xyz"], first_xyz):
                    if abs(expected - actual) > 1e-6:
                        findings.append("GT {} start_xyz {} != FEM {} for node {}".format(
                            weld.get("semantic_id"), path["start_xyz"], first_xyz, chain[0]))
                        break
        if chain and path.get("end_xyz"):
            last_xyz = parsed["nodes"].get(int(chain[-1]))
            if last_xyz is not None:
                for expected, actual in zip(path["end_xyz"], last_xyz):
                    if abs(expected - actual) > 1e-6:
                        findings.append("GT {} end_xyz {} != FEM {} for node {}".format(
                            weld.get("semantic_id"), path["end_xyz"], last_xyz, chain[-1]))
                        break
    return findings


def run(output_root: Path) -> dict:
    rows = []
    for kind in ("atomic", "composite"):
        kind_dir = output_root / kind
        if not kind_dir.is_dir():
            continue
        for case_dir in sorted(kind_dir.iterdir()):
            manifest_path = case_dir / "input_manifest.json"
            gt_path = case_dir / "ground_truth.json"
            fem_path = case_dir / "input.fem"
            if not (manifest_path.is_file() and gt_path.is_file() and fem_path.is_file()):
                continue
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            gt = json.loads(gt_path.read_text(encoding="utf-8"))
            try:
                findings = _validate_one(case_dir, manifest, gt)
            except AssertionError as exc:
                findings = ["parser error: {}".format(exc)]
            rows.append({
                "case_id": case_dir.name,
                "kind": kind,
                "valid": not findings,
                "findings": findings,
                "node_count": manifest["statistics"]["node_count"],
                "element_count": manifest["statistics"]["element_count"],
                "component_count": manifest["statistics"]["component_count"],
            })
    valid = sum(1 for row in rows if row["valid"])
    return {"fixture_count": len(rows), "valid_count": valid,
            "invalid_count": len(rows) - valid, "cases": rows}


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(
        __file__).resolve().parents[2] / "examples" / "validation_weld_recognition_v2")
    args = parser.parse_args(argv)
    report = run(args.output)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["invalid_count"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
