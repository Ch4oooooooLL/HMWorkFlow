"""Weld Integrity Check Python package compatibility namespace."""

from pathlib import Path

__path__ = [str(Path(__file__).resolve().parents[3] / "modules" / "weld_integrity_check" / "python")]
