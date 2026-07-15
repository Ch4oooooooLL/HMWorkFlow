from __future__ import annotations

import csv
import json
from pathlib import Path
from typing import Any, Dict, List, Tuple


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8-sig") as stream:
        return json.load(stream)


def load_inputs(input_dir: Path) -> Tuple[List[Dict[str, Any]], Dict[int, Tuple[float, float, float]], List[Dict[str, Any]], Dict[str, Any]]:
    components = load_json(input_dir / "components.json")
    settings = load_json(input_dir / "settings.json")
    nodes: Dict[int, Tuple[float, float, float]] = {}
    with (input_dir / "nodes.csv").open("r", encoding="utf-8-sig", newline="") as stream:
        for row in csv.DictReader(stream):
            nodes[int(row["node_id"])] = (float(row["x"]), float(row["y"]), float(row["z"]))
    elements: List[Dict[str, Any]] = []
    with (input_dir / "elements.csv").open("r", encoding="utf-8-sig", newline="") as stream:
        for row in csv.DictReader(stream):
            node_ids = [int(value) for value in row["node_ids"].replace(";", " ").split()]
            elements.append({
                "element_id": int(row["element_id"]),
                "component_id": int(row["component_id"]),
                "element_type": row["element_type"],
                "node_ids": node_ids,
            })
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
