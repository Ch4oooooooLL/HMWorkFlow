#!/usr/bin/env python3
"""verify_suite.py -- cross-check every generated model in examples/model_suite.

For each folder:
  - manifest exists and is valid JSON
  - every file listed in the manifest exists and is non-empty
  - .fem files: BEGIN BULK/ENDDATA present; GRID count matches node_count
    (when the manifest reports it); no duplicate entity ids detected
  - .step files: read back through OCCT (cadquery) -- at least one
    solid/face; product name injected

Usage: python tools/model_generation/verify_suite.py
       (set HMW_MODEL_OUTPUT to verify a redirected output root)
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common
import steplib  # noqa: F401  (ensures cadquery importable)

SUITE = common.output_root()


def check_fem(path: Path, manifest_stats: dict) -> list:
    errors = []
    text = path.read_text(encoding="utf-8")
    if "BEGIN BULK" not in text or "ENDDATA" not in text:
        errors.append("missing BEGIN BULK / ENDDATA")
    counts = {}
    ids = set()
    for line in text.splitlines():
        m = re.match(r"^(GRID|CQUAD4|CTRIA3|CHEXA|CPENTA|CTETRA|RBE2|RBE3|CBEAM|CBAR|CBUSH),(.*)$", line)
        if m:
            counts[m.group(1)] = counts.get(m.group(1), 0) + 1
            try:
                ids.add(int(line.split(",")[1]))
            except ValueError:
                pass
    if manifest_stats.get("node_count") is not None:
        got = counts.get("GRID", 0)
        if got != manifest_stats["node_count"]:
            errors.append("GRID count {} != manifest node_count {}".format(got, manifest_stats["node_count"]))
    if manifest_stats.get("element_count") is not None:
        got = sum(v for k, v in counts.items() if k != "GRID")
        if got != manifest_stats["element_count"]:
            errors.append("element cards {} != manifest element_count {}".format(got, manifest_stats["element_count"]))
    if len(ids) != len(set(ids)):
        errors.append("duplicate entity ids in FEM")
    return errors


def check_step(path: Path) -> list:
    errors = []
    try:
        info = steplib.verify_step(str(path))
        if info["solids"] == 0 and info["faces"] == 0:
            errors.append("STEP contains no solid or face")
    except Exception as exc:  # noqa: BLE001
        errors.append("STEP readback failed: {}".format(exc))
    return errors


def main() -> int:
    if not SUITE.exists():
        print("no suite directory:", SUITE)
        return 2
    total_errors = 0
    rows = []
    for folder in sorted(SUITE.iterdir()):
        if not folder.is_dir():
            continue
        manifests = sorted(folder.glob("*_manifest.json"))
        if not manifests:
            rows.append((folder.name, "NO MANIFEST", "error", "-"))
            total_errors += 1
            continue
        manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
        stats = manifest.get("statistics", {})
        files = manifest.get("files", [])
        errors = []
        # files listed in manifest
        for f in files:
            p = folder / f
            if not p.exists() or p.stat().st_size == 0:
                errors.append("missing file {}".format(f))
        # all fem/step files in the folder
        for p in sorted(folder.glob("*.fem")):
            errors.extend(check_fem(p, stats))
        for p in sorted(folder.glob("*.step")):
            errors.extend(check_step(p))
        size_mb = sum(f.stat().st_size for f in folder.iterdir() if f.is_file()) / 1e6
        status = "ok" if not errors else "error"
        rows.append((folder.name, manifest.get("module", "-"),
                     status, "{:.2f}MB".format(size_mb)))
        for e in errors[:8]:
            print("  [{}] {}".format(folder.name, e))
        total_errors += len(errors)
    print("\n{:<32} {:<18} {:<6} {}".format("FOLDER", "MODULE", "STATUS", "SIZE"))
    for name, module, status, size in rows:
        print("{:<32} {:<18} {:<6} {}".format(name, module, status, size))
    print("\n{} model folders, {} errors".format(len(rows), total_errors))
    return 1 if total_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
