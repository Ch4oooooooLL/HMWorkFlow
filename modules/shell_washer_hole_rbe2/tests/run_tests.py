import sys, unittest
from pathlib import Path
TEST_DIR=Path(__file__).resolve().parent; MODULE=TEST_DIR.parent/"python"; COMMON=TEST_DIR.parents[1]/"hybrid_core"/"python"
for directory in (str(MODULE),str(COMMON)):
    if directory in sys.path: sys.path.remove(directory)
for directory in (str(MODULE),str(COMMON)): sys.path.insert(0,directory)
if __name__=="__main__":
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.discover(str(TEST_DIR),"test_*.py")); raise SystemExit(0 if result.wasSuccessful() else 1)
