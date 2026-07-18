from __future__ import annotations

import sys
import unittest
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
ROOT = TEST_DIR.parents[2]
PACKAGE_DIR = ROOT / "python"
MODULE_DIR = TEST_DIR.parent / "python"
COMMON_DIR = TEST_DIR.parents[1] / "hybrid_core" / "python"
for directory in (str(PACKAGE_DIR), str(MODULE_DIR), str(COMMON_DIR)):
    if directory in sys.path:
        sys.path.remove(directory)
for directory in (str(COMMON_DIR), str(MODULE_DIR), str(PACKAGE_DIR)):
    sys.path.insert(0, directory)

if __name__ == "__main__":
    suite = unittest.defaultTestLoader.discover(str(TEST_DIR), "test_*.py")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
