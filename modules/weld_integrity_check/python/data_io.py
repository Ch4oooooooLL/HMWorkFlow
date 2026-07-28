from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Tuple

try:
    from .fem_reader import read_fem_bundle
except ImportError:  # Standalone HM2019 entry compatibility.
    from fem_reader import read_fem_bundle


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8-sig") as stream:
        return json.load(stream)


def load_inputs(input_dir: Path) -> Tuple[List[Dict[str, Any]], Dict[int, Tuple[float, float, float]], List[Dict[str, Any]], Dict[str, Any]]:
    settings = load_json(input_dir / "settings.json")
    components, nodes, elements = read_fem_bundle(input_dir / "mesh_manifest.json")
    return components, nodes, elements, settings


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _quote_tcl(value: Any) -> str:
    text = str(value)
    for original, escaped in (("\\", "\\\\"), ("$", "\\$"), ("[", "\\["), ("]", "\\]"), ('"', '\\"'), ("\n", "\\n"), ("\r", "\\r")):
        text = text.replace(original, escaped)
    return '"{}"'.format(text)


def _to_tcl(value: Any) -> str:
    if value is None:
        return _quote_tcl("")
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return repr(value)
    if isinstance(value, dict):
        fields: List[str] = []
        for key, item in value.items():
            fields.extend((_quote_tcl(key), _to_tcl(item)))
        return "[dict create {}]".format(" ".join(fields))
    if isinstance(value, (list, tuple)):
        return "[list {}]".format(" ".join(_to_tcl(item) for item in value))
    return _quote_tcl(value)


def write_tcl(path: Path, variable_name: str, payload: Any) -> None:
    if not variable_name.startswith("::") or not all(c.isalnum() or c in "_:" for c in variable_name):
        raise ValueError("Unsafe Tcl variable name")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("# WELD_INTEGRITY_RESULT_V1\nset {} {}\n".format(variable_name, _to_tcl(payload)), encoding="utf-8")
