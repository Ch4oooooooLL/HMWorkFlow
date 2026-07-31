"""Stable auto-seam pair-filter facade shared with integrity review."""
from __future__ import annotations

import sys
from pathlib import Path

COMMON_DIR = Path(__file__).resolve().parents[2] / "hybrid_core" / "python"
if str(COMMON_DIR) not in sys.path: sys.path.insert(0, str(COMMON_DIR))
from shell_weld_detection import build_component_bounds, find_candidate_component_pairs  # noqa: E402,F401

__all__ = ["build_component_bounds", "find_candidate_component_pairs"]
