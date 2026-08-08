"""Audit the Git index for generated, private, and local-only project data."""

from __future__ import annotations

import subprocess
from pathlib import Path, PurePosixPath
from typing import List


ROOT = Path(__file__).resolve().parents[1]

# Versioned acceptance fixtures that .gitignore intentionally tracks
# (see the !/examples/AutoShellSeamBackend/test_fem/ negation rules).
VERSIONED_EXAMPLE_FIXTURES = "examples/autoshellseambackend/test_fem/"


def tracked_paths() -> List[str]:
    completed = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=str(ROOT),
        check=True,
        capture_output=True,
    )
    return [item.decode("utf-8") for item in completed.stdout.split(b"\0") if item]


def violation(path: str) -> str:
    pure = PurePosixPath(path)
    lower = path.lower()

    if lower.startswith((".agents/", ".codex/", ".pytest_cache/", "dist/", "logs/", "temp/")):
        return "local/generated directory"
    if lower in {"command.tcl", "optistruct.msg", "doc/command.tcl"}:
        return "HyperMesh session output"
    if "__pycache__" in pure.parts or pure.suffix.lower() in {".pyc", ".pyo"}:
        return "Python cache"
    if lower.startswith("config/") and lower.endswith("_state.txt"):
        return "user UI state"
    if lower.startswith("examples/") and (
        pure.suffix.lower() == ".fem" or lower.endswith("_manifest.json")
    ):
        if lower.startswith(VERSIONED_EXAMPLE_FIXTURES):
            return ""  # versioned acceptance fixtures (see .gitignore)
        return "generated example model"
    if lower.startswith("runtime/") and not lower.startswith("runtime/python/"):
        return "non-distributable runtime data"
    if lower.startswith("runtime/python/"):
        parts = pure.parts
        allowed_file = len(parts) == 3 or (
            len(parts) == 4 and parts[2].lower() == "windows-x64"
        )
        if not allowed_file:
            return "nested/local portable-runtime data"
    return ""


def main() -> int:
    try:
        paths = tracked_paths()
    except (OSError, subprocess.CalledProcessError) as exc:
        print("ERROR: cannot inspect Git tracking list: {}".format(exc))
        return 1

    errors = [(path, violation(path)) for path in paths]
    errors = [(path, reason) for path, reason in errors if reason]
    if errors:
        for path, reason in errors:
            print("ERROR: tracked {}: {}".format(reason, path))
        return 1

    print("Repository tracking audit passed: {} tracked files".format(len(paths)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
