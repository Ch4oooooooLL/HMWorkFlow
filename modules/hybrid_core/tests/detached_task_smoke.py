"""Minimal detached-task protocol target used by the HM2019 smoke matrix."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--status-file", required=True, type=Path)
    parser.add_argument("--task-token", required=True)
    arguments = parser.parse_args()
    arguments.output.write_text(arguments.task_token, encoding="utf-8")
    temporary = arguments.status_file.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(
            {
                "exit_code": 0,
                "pid": os.getpid(),
                "task_token": arguments.task_token,
            }
        ),
        encoding="utf-8",
    )
    temporary.replace(arguments.status_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
