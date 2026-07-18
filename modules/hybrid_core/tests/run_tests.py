"""Run hybrid_core tests without third-party packages."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
ROOT = TEST_DIR.parents[2]
PACKAGE_DIR = ROOT / "python"
PYTHON_DIR = TEST_DIR.parent / "python"
for directory in (str(PYTHON_DIR), str(PACKAGE_DIR)):
    if directory not in sys.path:
        sys.path.insert(0, directory)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.discover(str(TEST_DIR), pattern="test_*.py")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
