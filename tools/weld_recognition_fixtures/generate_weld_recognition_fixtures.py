"""Generate the V2 weld-recognition fixture corpus.

Usage:
    python tools/weld_recognition_fixtures/generate_weld_recognition_fixtures.py
        [--output <root>]           # default examples/validation_weld_recognition_v2
        [--atomic TC001_standard_t,TC002_...]
        [--skip-atomic] [--skip-composite]

The output is deterministic: re-running the generator reproduces every GRID /
element / component / property ID and coordinate bit-for-bit.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

from atomic_tc001_010 import ATOMIC_CASES_001_010
from atomic_tc011_020 import ATOMIC_CASES_011_020
from atomic_tc021_030 import ATOMIC_CASES_021_030
from atomic_tc031_040 import ATOMIC_CASES_031_040
from atomic_tc041_048 import ATOMIC_CASES_041_048
from atomic_tc049_050 import ATOMIC_CASES_049_050
from wfc_catalogue import (ATOMIC_DIR, DEFAULT_OUTPUT_ROOT, atomic_subdir,
                           case_id_range, component_banners, write_json)
from wfc_csv import aggregate_case_csvs, write_weld_csv
from wfc_model import ModelBuilder
from wfc_writer import write_fem_bundle

# case-id prefix -> case index (drives the deterministic ID blocks)
CASE_INDEX = {}


def _case_index_for(case_key: str) -> int:
    """Map a TCxxx_* key to its numeric index from the leading TC number."""
    import re
    match = re.match(r"TC(\d{3})", case_key)
    if not match:
        raise ValueError("cannot derive case index from {!r}".format(case_key))
    return int(match.group(1))


ATOMIC_REGISTRY = {}
ATOMIC_REGISTRY.update(ATOMIC_CASES_001_010)
ATOMIC_REGISTRY.update(ATOMIC_CASES_011_020)
ATOMIC_REGISTRY.update(ATOMIC_CASES_021_030)
ATOMIC_REGISTRY.update(ATOMIC_CASES_031_040)
ATOMIC_REGISTRY.update(ATOMIC_CASES_041_048)
ATOMIC_REGISTRY.update(ATOMIC_CASES_049_050)


def _register(prefix):  # pragma: no cover - registration groups live in each module
    for key, factory in getattr(prefix, "ATOMIC_CASES", {}).items():
        ATOMIC_REGISTRY[key] = factory


def _finalise_ground_truth(builder, gt, hints):
    """Attach source_path geometry and every component name id mapping.

    The case builders normally pass a bare ``{"expected_node_ids": [...]}``
    chain; the physical start/end/length are derived here from the actual model
    coordinates so the GT always carries the weld location, not only ids.
    """
    by_name = {component.name: component_id for component_id, component in builder.model.components.items()}
    gt.analytic["component_names"] = dict(sorted(by_name.items()))
    for weld in gt.welds:
        source_name = weld["source_component"]
        path = weld.get("source_path")
        chain = None
        if path and path.get("expected_node_ids"):
            chain = [int(value) for value in path["expected_node_ids"]]
        elif hints.get(source_name):
            chain = [int(value) for value in hints[source_name]]
        if not chain:
            continue
        weld["source_path"] = {
            "component": source_name,
            "expected_node_ids": chain,
            "start_xyz": list(builder.xyz(chain[0])),
            "end_xyz": list(builder.xyz(chain[-1])),
            "length": round(
                sum(
                    sum((builder.xyz(a)[k] - builder.xyz(bb)[k]) ** 2 for k in range(3)) ** 0.5
                    for a, bb in zip(chain, chain[1:])
                ),
                6,
            ),
        }
    return gt


def _generate_atomic_cases(output_root: Path, selected: list):
    """Generate one directory per atomic case containing the FEM, manifest and GT."""
    generated = []
    for key, factory in ATOMIC_REGISTRY.items():
        if selected and key not in selected:
            continue
        index = _case_index_for(key)
        ranges = case_id_range(index)
        builder, gt, hints = factory(dict(ranges))
        gt = _finalise_ground_truth(builder, gt, hints)
        case_dir = atomic_subdir(output_root, key)
        case_dir.mkdir(parents=True, exist_ok=True)
        manifest = write_fem_bundle(
            builder.model,
            case_dir / "input.fem",
            case_dir / "input_manifest.json",
            section_banners=component_banners(builder.model),
        )
        gt_path = case_dir / "ground_truth.json"
        gt.write(gt_path)
        write_weld_csv(gt.to_dict(), case_dir / "ground_truth.csv")
        generated.append({
            "case_id": key,
            "kind": "atomic",
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
    return generated


def generate(output_root: Path, selected=None, skip_atomic=False, skip_composite=False) -> dict:
    output_root = Path(output_root)
    report = {"schema_version": "1.0", "output_root": str(output_root), "atomic": [], "composite": []}
    if not skip_atomic:
        report["atomic"] = _generate_atomic_cases(output_root, selected)
    if not skip_composite:
        # composite generation is registered incrementally
        from composite_cm001 import generate_composites
        report["composite"] = generate_composites(output_root, selected)
    manifest_path = output_root / "fixture_manifest.json"
    write_json(manifest_path, {
        "schema_version": "1.0",
        "generator": "tools/weld_recognition_fixtures/generate_weld_recognition_fixtures.py",
        "output_root": ".",
        "atomic_count": len(report["atomic"]),
        "composite_count": len(report["composite"]),
        "atomic": report["atomic"],
        "composite": report["composite"],
    })
    report["fixture_manifest"] = "fixture_manifest.json"
    # one flat ground_truth table across the whole corpus (welds + forbidden)
    case_dirs = [output_root / Path(entry["ground_truth"]).parent
                 for entry in report["atomic"] + report["composite"]]
    report["csv"] = aggregate_case_csvs(case_dirs, output_root / "ground_truth.csv")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--atomic", default=None, help="comma separated case keys; default all")
    parser.add_argument("--skip-atomic", action="store_true")
    parser.add_argument("--skip-composite", action="store_true")
    args = parser.parse_args(argv)
    selected = [value.strip() for value in args.atomic.split(",")] if args.atomic else None
    if selected and args.skip_atomic:
        parser.error("--atomic and --skip-atomic are mutually exclusive")
    _register(None)
    report = generate(args.output, selected, args.skip_atomic, args.skip_composite)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
