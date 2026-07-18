import sys
import unittest
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
ROOT = TEST_DIR.parents[2]
sys.path.insert(0, str(ROOT / "python"))
suite = unittest.defaultTestLoader.discover(str(TEST_DIR), "test_*.py")
result = unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
