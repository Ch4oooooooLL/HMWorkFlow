"""Compatibility wrapper around the shared shell-weld detector."""
from __future__ import annotations

import sys
from pathlib import Path

COMMON_DIR = Path(__file__).resolve().parents[2] / "hybrid_core" / "python"
if str(COMMON_DIR) not in sys.path:
    sys.path.insert(0, str(COMMON_DIR))

from shell_weld_detection import (  # noqa: E402,F401
    ComponentTopology, SpatialHash, analyze_component_pair,
    build_component_bounds, build_component_topology, calculate_pair_metrics,
    detect, distance, extract_candidate_regions, find_candidate_component_pairs,
    merge_duplicate_pairs, midpoint,
)

__all__ = [name for name in globals() if not name.startswith("_")]
