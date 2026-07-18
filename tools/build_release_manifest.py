"""Generate reproducible HMWorkFlow package metadata."""

from __future__ import annotations

import argparse
import datetime as _datetime
import json
import os
import subprocess
from pathlib import Path
from typing import Optional, Sequence


def _source_commit(source_root: Path) -> str:
    environment_commit = os.environ.get("GITHUB_SHA", "").strip()
    if environment_commit:
        return environment_commit
    try:
        return subprocess.check_output(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def build_manifest(source_root: Path) -> dict:
    version = (source_root / "VERSION").read_text(encoding="utf-8").strip()
    runtime_manifest_path = source_root / "runtime/python/RUNTIME_MANIFEST.json"
    runtime_manifest = json.loads(runtime_manifest_path.read_text(encoding="utf-8"))
    return {
        "schema_version": "1.0",
        "package_version": version,
        "build_time_utc": _datetime.datetime.now(_datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "source_commit": _source_commit(source_root),
        "runtime_version": str(runtime_manifest.get("version", "unknown")),
        "supported_hypermesh_versions": ["2019"],
        "solver_profiles": ["OptiStruct"],
        "config_schema_version": "2.0",
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)

    source_root = args.source_root.resolve()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(build_manifest(source_root), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
