"""Long-lived stdio worker for Tcl, keeping CPython warm without a network service."""
from __future__ import annotations

import contextlib
import argparse
import hashlib
import importlib.util
import json
import os
import sys
import time
import traceback
from pathlib import Path
from typing import Dict

import worker_cache as _worker_cache


_PROTECTED_MODULES = {"worker_cache", "__main__"}
_WORKER_FILE = Path(__file__).resolve()


def _module_root(entry: Path) -> Path:
    for parent in entry.parents:
        if parent.name.lower() == "modules":
            return parent
    return entry.parent


def _is_below(module, root: Path) -> bool:
    filename = getattr(module, "__file__", None)
    if not filename:
        return False
    try:
        Path(filename).resolve().relative_to(root)
        return True
    except (OSError, ValueError):
        return False


class _EntryBundle:
    def __init__(self, root: Path, entry_module, modules: Dict[str, object]):
        self.root = root
        self.entry_module = entry_module
        self.modules = modules


class _EntryLoader:
    """Keep each entry's modules alive while isolating colliding module names."""

    def __init__(self):
        self.bundles = {}  # type: Dict[Path, _EntryBundle]
        self.active = None  # type: Path

    def _capture(self, root: Path) -> Dict[str, object]:
        return {
            name: module
            for name, module in sys.modules.items()
            if name not in _PROTECTED_MODULES
            and _is_below(module, root)
            and Path(module.__file__).resolve() != _WORKER_FILE
        }

    def _deactivate(self) -> None:
        if self.active is None:
            return
        bundle = self.bundles[self.active]
        bundle.modules.update(self._capture(bundle.root))
        for name, module in list(bundle.modules.items()):
            if sys.modules.get(name) is module:
                sys.modules.pop(name, None)

    def activate(self, entry: Path):
        if self.active == entry:
            return self.bundles[entry].entry_module
        self._deactivate()
        cached = self.bundles.get(entry)
        if cached is not None:
            sys.modules.update(cached.modules)
            self.active = entry
            return cached.entry_module

        root = _module_root(entry)
        module_name = "_hybrid_task_{}".format(
            hashlib.sha256(str(entry).encode("utf-8")).hexdigest()[:20]
        )
        spec = importlib.util.spec_from_file_location(module_name, str(entry))
        if spec is None or spec.loader is None:
            raise RuntimeError("cannot load entry {}".format(entry))
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module
        try:
            spec.loader.exec_module(module)
        except BaseException:
            sys.modules.pop(module_name, None)
            raise
        bundle = _EntryBundle(root, module, self._capture(root))
        bundle.modules[module_name] = module
        self.bundles[entry] = bundle
        self.active = entry
        return module

    def refresh(self) -> None:
        if self.active is not None:
            bundle = self.bundles[self.active]
            bundle.modules.update(self._capture(bundle.root))


_ENTRY_LOADER = _EntryLoader()


def _run(request):
    entry = Path(request["entry"]).resolve()
    task_dir = Path(request["task_dir"]).resolve()
    task_dir.mkdir(parents=True, exist_ok=True)
    stdout_path = task_dir / "python_stdout.log"
    stderr_path = task_dir / "python_stderr.log"
    started = time.perf_counter()
    exit_code = 2
    original_path = list(sys.path)
    _worker_cache.begin_request(request.get("input_fingerprints", {}))
    try:
        for directory in (entry.parent, entry.parents[2] / "hybrid_core" / "python" if len(entry.parents) > 2 else None):
            if directory is not None and directory.is_dir() and str(directory) not in sys.path:
                sys.path.insert(0, str(directory))
        with stdout_path.open("w", encoding="utf-8") as stdout_file, stderr_path.open("w", encoding="utf-8") as stderr_file:
            with contextlib.redirect_stdout(stdout_file), contextlib.redirect_stderr(stderr_file):
                try:
                    module = _ENTRY_LOADER.activate(entry)
                    exit_code = int(module.main(list(request.get("arguments", []))) or 0)
                except SystemExit as exc:
                    exit_code = int(exc.code or 0)
                except BaseException:
                    traceback.print_exc()
                    exit_code = 2
    finally:
        _ENTRY_LOADER.refresh()
        _worker_cache.end_request()
        sys.path[:] = original_path
    return exit_code, time.perf_counter() - started


def _arguments():
    parser = argparse.ArgumentParser(description="HMWorkFlow per-HyperMesh Python worker")
    parser.add_argument("--owner-pid", required=True, type=int)
    parser.add_argument("--instance-id", required=True)
    return parser.parse_args()


def main():
    args = _arguments()
    # These values are intentionally process-local.  They make diagnostics
    # unambiguous when several HyperMesh instances are running concurrently.
    os.environ["HMWORKFLOW_OWNER_PID"] = str(args.owner_pid)
    os.environ["HMWORKFLOW_INSTANCE_ID"] = args.instance_id
    for line in sys.stdin:
        request_id = "unknown"
        try:
            request = json.loads(line)
            if request.get("command") == "shutdown":
                return 0
            request_id = str(request["request_id"])
            exit_code, elapsed = _run(request)
            state = "OK" if exit_code == 0 else "ERROR"
        except BaseException:
            traceback.print_exc(file=sys.__stderr__)
            state, exit_code, elapsed = "ERROR", 2, 0.0
        cache_info = _worker_cache.info()
        sys.__stdout__.write(
            "HYBRID\t{}\t{}\t{}\t{:.6f}\t{}\t{}\t{}\n".format(
                request_id,
                state,
                exit_code,
                elapsed,
                cache_info["hits"],
                cache_info["misses"],
                cache_info["entries"],
            )
        )
        sys.__stdout__.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
