"""Shared schema validation for hybrid module requests and results."""
from __future__ import annotations

from typing import Any, Dict, Iterable, List

SCHEMA_VERSION = "1.0"
MODULES = {
    "auto_hole_rbe2",
    "shell_washer_hole_rbe2",
    "rbe2_bolt_connector",
    "mesh_seam_weld",
    "hybrid_core_self_test",
}


class SchemaError(ValueError):
    """Raised when a bridge payload violates the versioned contract."""


def require_mapping(value: Any, label: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise SchemaError("{} must be an object".format(label))
    return value


def require_version(data: Dict[str, Any], label: str) -> None:
    if data.get("schema_version") != SCHEMA_VERSION:
        raise SchemaError("{}.schema_version must be {!r}".format(label, SCHEMA_VERSION))


def require_text(data: Dict[str, Any], key: str, label: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SchemaError("{}.{} must be a non-empty string".format(label, key))
    return value


def int_list(value: Any, label: str, unique: bool = True) -> List[int]:
    if not isinstance(value, list):
        raise SchemaError("{} must be an array".format(label))
    result = []
    for item in value:
        if isinstance(item, bool):
            raise SchemaError("{} contains a boolean ID".format(label))
        try:
            converted = int(item)
        except (TypeError, ValueError) as exc:
            raise SchemaError("{} contains a non-integer ID".format(label)) from exc
        if converted <= 0:
            raise SchemaError("{} contains a non-positive ID".format(label))
        result.append(converted)
    if unique and len(result) != len(set(result)):
        raise SchemaError("{} contains duplicate IDs".format(label))
    return result


def validate_request(data: Dict[str, Any], expected_module: str = "") -> Dict[str, Any]:
    data = require_mapping(data, "request")
    require_version(data, "request")
    module = require_text(data, "module", "request")
    if module not in MODULES:
        raise SchemaError("unsupported request.module: {!r}".format(module))
    if expected_module and module != expected_module:
        raise SchemaError("request.module {!r} does not match {!r}".format(module, expected_module))
    require_text(data, "run_id", "request")
    version = str(data.get("hypermesh_version", ""))
    if module != "hybrid_core_self_test" and not version:
        raise SchemaError("request.hypermesh_version is required")
    data["selected_component_ids"] = int_list(
        data.get("selected_component_ids", []), "request.selected_component_ids"
    )
    require_mapping(data.get("settings"), "request.settings")
    options = require_mapping(data.get("options", {}), "request.options")
    for key in ("debug", "keep_runtime_files"):
        if key in options and not isinstance(options[key], bool):
            raise SchemaError("request.options.{} must be boolean".format(key))
    return data


def new_result(module: str, run_id: str) -> Dict[str, Any]:
    if module not in MODULES:
        raise SchemaError("unsupported result module: {!r}".format(module))
    if not str(run_id).strip():
        raise SchemaError("result run_id is required")
    return {
        "schema_version": SCHEMA_VERSION,
        "module": module,
        "run_id": str(run_id),
        "status": "SUCCESS",
        "summary": {},
        "candidates": [],
        "warnings": [],
        "errors": [],
        "performance": {
            "read_seconds": 0.0,
            "detect_seconds": 0.0,
            "write_seconds": 0.0,
        },
    }


def validate_result(
    data: Dict[str, Any], expected_module: str = "", expected_run_id: str = ""
) -> Dict[str, Any]:
    data = require_mapping(data, "result")
    require_version(data, "result")
    module = require_text(data, "module", "result")
    run_id = require_text(data, "run_id", "result")
    if module not in MODULES:
        raise SchemaError("unsupported result.module: {!r}".format(module))
    if expected_module and module != expected_module:
        raise SchemaError("result.module {!r} does not match {!r}".format(module, expected_module))
    if expected_run_id and run_id != expected_run_id:
        raise SchemaError("result.run_id {!r} does not match current run".format(run_id))
    if data.get("status") not in {"SUCCESS", "PARTIAL", "ERROR"}:
        raise SchemaError("unsupported result.status: {!r}".format(data.get("status")))
    require_mapping(data.get("summary"), "result.summary")
    require_mapping(data.get("performance"), "result.performance")
    for key in ("candidates", "warnings", "errors"):
        if not isinstance(data.get(key), list):
            raise SchemaError("result.{} must be an array".format(key))
    seen = set()
    for index, candidate in enumerate(data["candidates"]):
        require_mapping(candidate, "result.candidates[{}]".format(index))
        candidate_id = require_text(candidate, "candidate_id", "candidate")
        if candidate_id in seen:
            raise SchemaError("duplicate candidate_id {!r}".format(candidate_id))
        seen.add(candidate_id)
    return data


def require_known_ids(ids: Iterable[int], known_ids: Iterable[int], label: str) -> None:
    known = set(known_ids)
    missing = sorted(set(ids) - known)
    if missing:
        raise SchemaError("{} references missing IDs: {}".format(label, missing))
