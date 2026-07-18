from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

# The persistent HyperMesh worker loads this file through importlib rather
# than executing it as a script. In that mode Python does not automatically
# add this module directory to sys.path, so make sibling imports explicit.
MODULE_DIR = Path(__file__).resolve().parent
if str(MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(MODULE_DIR))

try:
    from .data_io import load_inputs, write_json, write_tcl
    from .detector import detect
except ImportError:  # Standalone HM2019 entry compatibility.
    from data_io import load_inputs, write_json, write_tcl
    from detector import detect


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Shell-shell weld integrity candidate detector")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tcl-output", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    args = parser.parse_args(argv)
    args.log.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("weld_integrity_check.{}".format(id(args)))
    logger.setLevel(logging.INFO); logger.propagate = False
    handler = logging.FileHandler(str(args.log), encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s")); logger.addHandler(handler)
    try:
        components, nodes, elements, settings = load_inputs(args.input)
        logger.info("loaded components=%d nodes=%d elements=%d", len(components), len(nodes), len(elements))
        result = detect(components, nodes, elements, settings)
        write_json(args.output, result)
        write_tcl(args.tcl_output, "::WeldIntegrityCheck::pythonResult", result)
        logger.info("complete pairs=%d regions=%d", result["summary"]["candidate_pair_count"], result["summary"]["candidate_region_count"])
        return 0
    except Exception as exc:
        logger.exception("detection failed")
        failure = {"success": False, "message": str(exc), "summary": {}, "pairs": []}
        try: write_json(args.output, failure)
        except Exception: pass
        print("Weld integrity detection failed: {}".format(exc), file=sys.stderr)
        return 2
    finally:
        handler.flush(); handler.close(); logger.removeHandler(handler)


if __name__ == "__main__":
    raise SystemExit(main())
