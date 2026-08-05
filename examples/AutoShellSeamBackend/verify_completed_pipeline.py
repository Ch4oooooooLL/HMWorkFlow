"""Verify the complete Python -> HyperMesh -> FEM round trip."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def _load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def verify(task_dir):
    task_dir = Path(task_dir).resolve()
    backup = task_dir / "before.hm"
    result_fem = task_dir / "result.fem"
    errors = []
    if not backup.is_file() or backup.stat().st_size == 0:
        errors.append("original HM backup is missing or empty")
    if not result_fem.is_file() or result_fem.stat().st_size == 0:
        errors.append("result FEM is missing or empty")
    retained = sorted(path.name for path in task_dir.iterdir()) if task_dir.is_dir() else []
    if retained != ["before.hm", "result.fem"]:
        errors.append("unexpected retained task files: {}".format(retained))
    text = result_fem.read_text(encoding="utf-8-sig", errors="replace") if result_fem.is_file() else ""
    node_count = sum(line.startswith("GRID") for line in text.splitlines())
    element_count = sum(line.startswith(("CTRIA3", "CQUAD4")) for line in text.splitlines())
    if node_count == 0 or element_count == 0:
        errors.append("result FEM contains no shell mesh")

    report = {
        "schema_version": "1.0",
        "status": "PASS" if not errors else "FAIL",
        "task_dir": str(task_dir),
        "backup_hm": str(backup),
        "result_fem": str(result_fem),
        "nodes": node_count,
        "elements": element_count,
        "retained_files": retained,
        "errors": errors,
    }
    return report


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("task_dir", type=Path)
    args = parser.parse_args(argv)
    report = verify(args.task_dir)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
