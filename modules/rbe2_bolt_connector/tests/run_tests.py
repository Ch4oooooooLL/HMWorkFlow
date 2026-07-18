import sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]; sys.path.insert(0,str(ROOT/"modules"/"hybrid_core"/"python")); sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"python")); sys.path.insert(0,str(ROOT/"python"))
suite=unittest.defaultTestLoader.discover(str(Path(__file__).parent),pattern="test_*.py"); raise SystemExit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
