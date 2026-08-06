"""Prepare a production main.py plan for the HM2019 stage-2 smoke test."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from generate_fixtures import generate, generate_combined
from hmworkflow.mesh_seam_weld.fem_mesh_reader import read_shell_fem_bundle
from hmworkflow.fem_auto_seam.main import main as backend_main
from hmworkflow.fem_auto_seam.backend import detect_candidates


def prepare(output, combined=False):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    generated = generate(output / "fixtures")
    if combined:
        combined_row = generate_combined(output / "fixtures")
        mesh_manifest = Path(combined_row["manifest"]).resolve()
    else:
        selected = next(row for row in generated if row["name"] == "case_02_angled_t")
        mesh_manifest = Path(selected["manifest"]).resolve()
    model = read_shell_fem_bundle(mesh_manifest)
    candidates = [row for row in detect_candidates(model) if row.get("auto_eligible")]
    run_id = "HM2019_STAGE2_PIPELINE"
    criteria = Path(__file__).with_name("reference.criteria").resolve()
    request = {
        "schema_version": "1.0",
        "module": "fem_auto_seam",
        "run_id": run_id,
        "hypermesh_version": "2019",
        "selected_component_ids": sorted(model.components),
        "settings": {
            "mode": "plan",
            "search_distance": 10.0,
            "min_seam_length": 15.0,
            "parallel_angle_max": 15.0,
            "perpendicular_angle_min": 70.0,
            "near_edge_distance": 8.0,
            "max_weld_tria_ratio": 0.75,
            "max_new_failed_elements": 1000,
            "criteria_path": str(criteria),
            "remesh_element_size": 10.0,
            "remesh_expand_layers": 2,
            "remesh_feature_angle": 30.0,
        },
        "accepted_candidate_ids": [row["candidate_id"] for row in candidates],
        "candidate_type_overrides": {},
        "candidate_swap_ids": [],
        "id_state": {
            "max_node_id": max(model.nodes),
            "max_element_id": max(model.elements),
            "max_property_id": max(getattr(model, "pshell", {}) or {0: None}),
            "max_material_id": max(getattr(model, "materials", {}) or {0: None}),
            "max_component_id": max(model.components),
        },
        "entity_registry": {"components": {}, "properties": {}, "materials": {}},
        "options": {"debug": False, "keep_runtime_files": True},
    }
    request_path = output / "request.json"
    existing_path = output / "existing.json"
    result_path = output / "result.hmwfr"
    request_path.write_text(json.dumps(request, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    existing_path.write_text('{"schema_version":"1.0","seams":[]}\n', encoding="utf-8")
    code = backend_main([
        "--request", str(request_path),
        "--mesh", str(mesh_manifest),
        "--existing", str(existing_path),
        "--output", str(result_path),
        "--tcl-output", str(result_path),
        "--log", str(output / "operation.log"),
    ])
    if code:
        raise RuntimeError("production backend returned {}".format(code))
    manifest = {
        "schema_version": "1.0",
        "run_id": run_id,
        "task_dir": str(output),
        "input_fem": str((mesh_manifest.parent / json.loads(mesh_manifest.read_text(encoding="utf-8"))["fem_path"]).resolve()),
        "result": str(result_path),
        "backend_result_fem": str((output / "backend_result.fem").resolve()),
        "backend_result_manifest": str((output / "backend_result_manifest.json").resolve()),
        "transfer_manifest": str((output / "transfer_manifest.json").resolve()),
        "delta_manifest": str((output / "delta_manifest.json").resolve()),
        "remesh_plan": str((output / "remesh_plan.json").resolve()),
        "criteria": str(criteria),
        "candidate_count": len(candidates),
        "fixture": "combined_all_cases" if combined else "case_02_angled_t",
    }
    (output / "pipeline_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "runtime" / "tasks" / "fem_auto_seam" / "hm2019_pipeline")
    parser.add_argument("--combined", action="store_true", help="plan every automatic candidate in combined_all_cases.fem")
    args = parser.parse_args()
    print(json.dumps(prepare(args.output, args.combined), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
