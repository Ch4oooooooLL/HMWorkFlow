"""Audit an HMWorkFlow release archive before it can be published."""

from __future__ import annotations

import argparse
import json
import re
import zipfile
from pathlib import PurePosixPath, Path
from typing import Iterable, List, Optional, Sequence


MODEL_OR_RUNTIME_SUFFIXES = {
    ".fem",
    ".hm",
    ".h3d",
    ".op2",
    ".odb",
    ".pch",
    ".res",
    ".out",
    ".stat",
    ".mvw",
    ".ses",
    ".hmres",
    ".log",
    ".ok",
    ".pyc",
    ".pyo",
}
TEXT_SUFFIXES = {
    ".css",
    ".csv",
    ".html",
    ".json",
    ".md",
    ".ps1",
    ".py",
    ".sh",
    ".tcl",
    ".txt",
    ".yaml",
    ".yml",
}
WINDOWS_USER_PATH = re.compile(
    rb"[A-Za-z]:" + rb"[/\\]" + rb"Users" + rb"[/\\]", re.IGNORECASE
)
UNIX_USER_PATH = re.compile(rb"/" + rb"home/" + rb"[^/\s]+/", re.IGNORECASE)


def _relative_archive_path(name: str, root_name: str) -> str:
    prefix = root_name + "/"
    return name[len(prefix) :] if name.startswith(prefix) else name


def audit_archive(path: Path) -> List[str]:
    errors: List[str] = []
    with zipfile.ZipFile(path) as archive:
        names = [info.filename for info in archive.infolist() if not info.is_dir()]
        if not names:
            return ["archive contains no files"]
        roots = {name.split("/", 1)[0] for name in names if "/" in name}
        if len(roots) != 1:
            errors.append("archive must contain exactly one project root")
        root_name = next(iter(roots), "")

        for info in archive.infolist():
            name = info.filename
            if "\\" in name:
                errors.append("backslash ZIP entry: {}".format(name))
                continue
            pure = PurePosixPath(name)
            if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
                errors.append("absolute ZIP entry: {}".format(name))
            if ".." in pure.parts:
                errors.append("parent traversal ZIP entry: {}".format(name))
            if info.is_dir():
                continue

            relative = _relative_archive_path(name, root_name)
            lower = relative.lower()
            suffix = PurePosixPath(lower).suffix
            if lower.startswith(("logs/", "temp/", "dist/")):
                errors.append("runtime directory in release: {}".format(name))
            if lower.startswith("runtime/") and not lower.startswith("runtime/python/"):
                errors.append("non-distributable runtime entry: {}".format(name))
            if lower.startswith("runtime/python/windows-x64/python38/"):
                errors.append("unpacked Python standard library in release: {}".format(name))
            if "/__pycache__/" in "/" + lower or suffix in MODEL_OR_RUNTIME_SUFFIXES:
                errors.append("generated/runtime artifact: {}".format(name))
            if lower.startswith("examples/") and lower.endswith("_manifest.json"):
                errors.append("generated example manifest: {}".format(name))
            if lower == "doc/command.tcl":
                errors.append("HyperMesh command capture in release: {}".format(name))
            if lower.startswith("config/") and lower.endswith("_state.txt"):
                errors.append("user state in release: {}".format(name))

            if suffix in TEXT_SUFFIXES and info.file_size <= 2 * 1024 * 1024:
                payload = archive.read(info)
                if WINDOWS_USER_PATH.search(payload) or UNIX_USER_PATH.search(payload):
                    errors.append("absolute user path in text content: {}".format(name))

        required = {
            "VERSION",
            "release_manifest.json",
            "runtime/python/windows-x64/python.exe",
            "runtime/python/windows-x64/python38.zip",
            "runtime/python/windows-x64/python38._pth",
        }
        relative_names = {_relative_archive_path(name, root_name) for name in names}
        for required_name in sorted(required - relative_names):
            errors.append("required release file missing: {}".format(required_name))

        manifest_name = root_name + "/release_manifest.json"
        if manifest_name in names:
            try:
                manifest = json.loads(archive.read(manifest_name).decode("utf-8-sig"))
                for key in ("package_version", "build_time_utc", "source_commit", "runtime_version"):
                    if not manifest.get(key):
                        errors.append("release manifest is missing {}".format(key))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                errors.append("invalid release manifest: {}".format(exc))
    return errors


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip", required=True, type=Path)
    args = parser.parse_args(argv)
    errors = audit_archive(args.zip.resolve())
    if errors:
        for error in errors:
            print("ERROR: {}".format(error))
        return 1
    print("Release audit passed: {}".format(args.zip.resolve()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
