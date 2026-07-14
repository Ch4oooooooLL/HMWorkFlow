"""UTF-8 and atomic file helpers for Local Mesh Optimizer."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any, Iterable, List, Set


def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8-sig") as stream:
        return json.load(stream)


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=str(path.parent)
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, str(path))
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def atomic_write_json(path: Path, value: Any) -> None:
    atomic_write_text(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def read_id_file(path: Path) -> List[int]:
    values: Set[int] = set()
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8-sig") as stream:
        for raw_line in stream:
            token = raw_line.strip().split(",", 1)[0]
            if not token or token.startswith("#"):
                continue
            values.add(int(token))
    return sorted(values)


def write_id_file(path: Path, values: Iterable[int]) -> None:
    atomic_write_text(path, "".join("{}\n".format(value) for value in sorted(set(values))))
