"""Long-lived stdio worker for Tcl, keeping CPython warm without a network service."""
from __future__ import annotations

import contextlib
import argparse
import importlib.util
import json
import os
import sys
import time
import traceback
import uuid
from pathlib import Path


def _purge_workspace_modules(entry: Path) -> None:
    modules_root = entry.parents[2]
    for name, module in list(sys.modules.items()):
        filename = getattr(module, "__file__", None)
        if not filename or name == __name__:
            continue
        try:
            Path(filename).resolve().relative_to(modules_root)
        except (OSError, ValueError):
            continue
        sys.modules.pop(name, None)


def _run(request):
    entry = Path(request["entry"]).resolve()
    task_dir = Path(request["task_dir"]).resolve()
    task_dir.mkdir(parents=True, exist_ok=True)
    stdout_path = task_dir / "python_stdout.log"
    stderr_path = task_dir / "python_stderr.log"
    started = time.perf_counter()
    exit_code = 2
    original_path = list(sys.path)
    _purge_workspace_modules(entry)
    try:
        with stdout_path.open("w", encoding="utf-8") as stdout_file, stderr_path.open("w", encoding="utf-8") as stderr_file:
            with contextlib.redirect_stdout(stdout_file), contextlib.redirect_stderr(stderr_file):
                try:
                    module_name = "_hybrid_task_{}".format(uuid.uuid4().hex)
                    spec = importlib.util.spec_from_file_location(module_name, str(entry))
                    if spec is None or spec.loader is None:
                        raise RuntimeError("cannot load entry {}".format(entry))
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                    exit_code = int(module.main(list(request.get("arguments", []))) or 0)
                except SystemExit as exc:
                    exit_code = int(exc.code or 0)
                except BaseException:
                    traceback.print_exc()
                    exit_code = 2
    finally:
        sys.path[:] = original_path
        _purge_workspace_modules(entry)
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
        sys.__stdout__.write("HYBRID\t{}\t{}\t{}\t{:.6f}\n".format(request_id, state, exit_code, elapsed))
        sys.__stdout__.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
