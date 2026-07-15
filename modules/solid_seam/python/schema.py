"""Data contracts and validation for the solid seam detector."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Tuple

SCHEMA_VERSION = "1.0"
SOLID_TYPES = {"CHEXA", "CPENTA", "CTETRA", "CPYRA"}
SHELL_TYPES = {"CTRIA3", "CTRIA6", "CQUAD4", "CQUAD8"}


class SchemaError(ValueError):
    pass


@dataclass(frozen=True)
class Component:
    component_id: int
    component_name: str
    mesh_class: str


@dataclass(frozen=True)
class Element:
    element_id: int
    component_id: int
    element_type: str
    node_ids: Tuple[int, ...]


@dataclass
class MeshModel:
    components: Dict[int, Component]
    nodes: Dict[int, Tuple[float, float, float]]
    elements: List[Element]
    existing_connectors: List[Dict[str, Any]]


def require_version(data: Dict[str, Any], label: str) -> None:
    if data.get("schema_version") != SCHEMA_VERSION:
        raise SchemaError(f"{label}.schema_version must be {SCHEMA_VERSION!r}")


def int_list(value: Any, label: str) -> List[int]:
    if not isinstance(value, list):
        raise SchemaError(f"{label} must be an array")
    try:
        result = [int(item) for item in value]
    except (TypeError, ValueError) as exc:
        raise SchemaError(f"{label} contains a non-integer value") from exc
    if len(result) != len(set(result)):
        raise SchemaError(f"{label} contains duplicate IDs")
    return result


def validate_request(data: Dict[str, Any]) -> Dict[str, Any]:
    require_version(data, "request")
    if not str(data.get("run_id", "")).strip():
        raise SchemaError("request.run_id is required")
    mode = data.get("mode")
    if mode not in {"SOLID_SOLID_PAIR", "SOLID_SHELL_PAIR", "MULTI_SOLID_SHELL"}:
        raise SchemaError(f"unsupported request.mode: {mode!r}")
    selected = int_list(data.get("selected_component_ids"), "selected_component_ids")
    solids = int_list(data.get("solid_component_ids"), "solid_component_ids")
    shells = int_list(data.get("shell_component_ids"), "shell_component_ids")
    if len(selected) < 2 or not set(solids + shells).issubset(selected):
        raise SchemaError("component ID lists are inconsistent")
    if mode == "SOLID_SOLID_PAIR" and not (len(selected) == 2 and len(solids) == 2 and not shells):
        raise SchemaError("SOLID_SOLID_PAIR requires exactly two solids")
    if mode == "SOLID_SHELL_PAIR" and not (len(selected) == 2 and len(solids) == 1 and len(shells) == 1):
        raise SchemaError("SOLID_SHELL_PAIR requires one solid and one shell")
    if mode == "MULTI_SOLID_SHELL" and not (len(selected) > 2 and solids and shells):
        raise SchemaError("MULTI_SOLID_SHELL requires at least three components and both mesh classes")
    if not isinstance(data.get("settings"), dict):
        raise SchemaError("request.settings must be an object")
    return data


def validate_candidate(candidate: Dict[str, Any], node_ids: Iterable[int], component_ids: Iterable[int]) -> None:
    known_nodes, known_components = set(node_ids), set(component_ids)
    nodes = candidate.get("node_ids", [])
    if len(nodes) < 2 or any(node not in known_nodes for node in nodes):
        raise SchemaError(f"candidate {candidate.get('candidate_id')} has invalid node_ids")
    source = candidate.get("source_solid", {}).get("component_id")
    target = candidate.get("target_component", {}).get("component_id")
    if source not in known_components or target not in known_components or source == target:
        raise SchemaError(f"candidate {candidate.get('candidate_id')} has invalid components")
