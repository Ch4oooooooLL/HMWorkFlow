"""Write auditable JSON and safely quoted Tcl sidecars."""
from __future__ import annotations

import json
import struct
from pathlib import Path
from typing import Any

from schema import validate_result


_BINARY_RESULT_MAGIC = b"HMWFR1\x00\x00"
_TYPE_NULL = 0
_TYPE_FALSE = 1
_TYPE_TRUE = 2
_TYPE_INT64 = 3
_TYPE_FLOAT64 = 4
_TYPE_STRING = 5
_TYPE_LIST = 6
_TYPE_MAP = 7
_UINT32 = struct.Struct("<I")
_INT64 = struct.Struct("<q")
_FLOAT64 = struct.Struct("<d")


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


def _encode_binary_string(output: bytearray, value: str) -> None:
    data = value.encode("utf-8")
    if len(data) > 0xFFFFFFFF:
        raise ValueError("binary result string is too large")
    output.extend(_UINT32.pack(len(data)))
    output.extend(data)


def _encode_binary_value(output: bytearray, value: Any) -> None:
    if value is None:
        output.append(_TYPE_NULL)
    elif value is False:
        output.append(_TYPE_FALSE)
    elif value is True:
        output.append(_TYPE_TRUE)
    elif isinstance(value, int):
        output.append(_TYPE_INT64)
        try:
            output.extend(_INT64.pack(value))
        except struct.error as exc:
            raise ValueError("binary result integer is outside int64 range") from exc
    elif isinstance(value, float):
        output.append(_TYPE_FLOAT64)
        output.extend(_FLOAT64.pack(value))
    elif isinstance(value, str):
        output.append(_TYPE_STRING)
        _encode_binary_string(output, value)
    elif isinstance(value, (list, tuple)):
        output.append(_TYPE_LIST)
        output.extend(_UINT32.pack(len(value)))
        for item in value:
            _encode_binary_value(output, item)
    elif isinstance(value, dict):
        output.append(_TYPE_MAP)
        output.extend(_UINT32.pack(len(value)))
        for key, item in value.items():
            if not isinstance(key, str):
                raise ValueError("binary result mapping keys must be strings")
            _encode_binary_string(output, key)
            _encode_binary_value(output, item)
    else:
        raise ValueError("unsupported binary result type {}".format(type(value).__name__))


def write_binary_result(path: Path, payload: Any) -> None:
    validate_result(payload)
    output = bytearray(_BINARY_RESULT_MAGIC)
    _encode_binary_value(output, payload)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(output)


def write_result(path: Path, tcl_path: Path, variable_name: str, payload: Any) -> None:
    validate_result(payload)
    if Path(path) == Path(tcl_path) and Path(path).suffix.lower() == ".hmwfr":
        write_binary_result(Path(path), payload)
        return
    write_json(path, payload)
    if Path(tcl_path).suffix.lower() == ".hmwfr":
        write_binary_result(Path(tcl_path), payload)
    else:
        write_tcl(tcl_path, variable_name, payload)
