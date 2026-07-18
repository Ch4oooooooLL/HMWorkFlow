"""Solid Seam Python package compatibility namespace."""

from pathlib import Path

__path__ = [str(Path(__file__).resolve().parents[3] / "modules" / "solid_seam" / "python")]
