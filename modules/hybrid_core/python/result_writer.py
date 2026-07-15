"""Write auditable JSON and safely quoted Tcl sidecars."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from schema import validate_result


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )


def _quoted(value: Any) -> str:
    text = str(value)
    replacements = (
        ("\\", "\\\\"),
        ("$", "\\$"),
        ("[", "\\["),
        ("]", "\\]"),
        ('"', '\\"'),
        ("\n", "\\n"),
        ("\r", "\\r"),
        ("\t", "\\t"),
    )
    for original, escaped in replacements:
        text = text.replace(original, escaped)
    return '"{}"'.format(text)


def _tcl(value: Any) -> str:
    if value is None:
        return _quoted("")
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return repr(value)
    if isinstance(value, dict):
        fields = []
        for key, item in value.items():
            fields.extend((_quoted(key), _tcl(item)))
        return "[dict create {}]".format(" ".join(fields))
    if isinstance(value, (list, tuple)):
        return "[list {}]".format(" ".join(_tcl(item) for item in value))
    return _quoted(value)


def write_tcl(path: Path, variable_name: str, payload: Any) -> None:
    if not variable_name.startswith("::") or not all(
        character.isalnum() or character in "_:" for character in variable_name
    ):
        raise ValueError("unsafe Tcl variable name {!r}".format(variable_name))
    path.parent.mkdir(parents=True, exist_ok=True)
    content = (
        "# HYBRID_CORE_RESULT_V1 - generated file; do not edit.\n"
        "set {} {}\n".format(variable_name, _tcl(payload))
    )
    path.write_text(content, encoding="utf-8")


def write_result(path: Path, tcl_path: Path, variable_name: str, payload: Any) -> None:
    validate_result(payload)
    write_json(path, payload)
    write_tcl(tcl_path, variable_name, payload)
