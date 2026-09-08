"""ID scheme, paths and catalogue helpers for the V2 weld-recognition fixtures.

Deterministic ranges keep composite merging free of collisions while letting a
human recover the owning case from any ID:

    case TCXXX        -> GRID base      XXX000
                         element base   XXX000 + 10_000
                         component base XXX000 + 20_000
                         PSHELL base    XXX000 + 30_000
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent.parent
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "examples" / "validation_weld_recognition_v2"

ATOMIC_DIR = "atomic"
COMPOSITE_DIR = "composite"
PER_CASE_DIRS = True  # one folder per atomic case containing input.fem + manifest + ground_truth.json


def case_id_range(case_index: int) -> Dict[str, int]:
    """Return the ID block for an atomic/composite case index."""
    base = int(case_index) * 1000
    return {
        "node_base": base,
        "elem_base": base + 10_000,
        "comp_base": base + 20_000,
        "pid_base": base + 30_000,
    }


def atomic_subdir(output_root: Path, case_id: str) -> Path:
    return output_root / ATOMIC_DIR / case_id


def composite_subdir(output_root: Path, case_id: str) -> Path:
    return output_root / COMPOSITE_DIR / case_id


def section_banner(component_name: str) -> str:
    return component_name


def component_banners(model) -> Dict[int, str]:
    return {component_id: "CASE {}".format(component.name) for component_id, component in model.components.items()}


def write_json(path, payload) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
