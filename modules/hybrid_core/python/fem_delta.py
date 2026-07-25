"""Small, auditable OptiStruct incremental-deck primitives.

The production runtime intentionally avoids a general BDF dependency.  These
helpers only emit the card subset that HMWorkFlow imports back into the current
HyperMesh 2019 session and return an explicit manifest for Tcl verification.
"""
from __future__ import annotations

import math
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Sequence, Tuple


class FemDeltaError(ValueError):
    """Raised when an incremental deck cannot be generated safely."""


_ENTITY_STATE_KEYS = {
    "node": "max_node_id",
    "element": "max_element_id",
    "property": "max_property_id",
    "material": "max_material_id",
    "component": "max_component_id",
}


class EntityIdAllocator:
    """Allocate monotonically increasing IDs from an exported model snapshot."""

    def __init__(self, state: Mapping[str, Any]):
        if not isinstance(state, Mapping):
            raise FemDeltaError("id_state must be an object")
        self._next = {}
        for entity, key in _ENTITY_STATE_KEYS.items():
            value = int(state.get(key, 0))
            if value < 0:
                raise FemDeltaError("{} must not be negative".format(key))
            self._next[entity] = value + 1

    def reserve(self, entity: str) -> int:
        if entity not in self._next:
            raise FemDeltaError("unsupported entity ID kind {!r}".format(entity))
        value = self._next[entity]
        self._next[entity] += 1
        return value


def entity_registry(request: Mapping[str, Any], key: str) -> Dict[str, int]:
    registries = request.get("entity_registry", {})
    if not isinstance(registries, Mapping):
        raise FemDeltaError("entity_registry must be an object")
    raw = registries.get(key, {})
    if not isinstance(raw, Mapping):
        raise FemDeltaError("entity_registry.{} must be an object".format(key))
    result = {}
    for name, value in raw.items():
        entity_id = int(value)
        if not str(name).strip() or entity_id <= 0:
            raise FemDeltaError("entity_registry.{} contains an invalid entry".format(key))
        result[str(name)] = entity_id
    return result


def new_manifest(path: Path, planned_create_count: int) -> Dict[str, Any]:
    return {
        "incremental_fem": str(Path(path).resolve()),
        "planned_create_count": int(planned_create_count),
        "created_node_ids": [],
        "created_element_ids": [],
        "created_property_ids": [],
        "created_material_ids": [],
        "created_component_ids": [],
        "reused_property_ids": [],
        "reused_component_ids": [],
        "expected_segments": [],
        "expected_rigids": [],
    }


def _safe_component_name(value: Any) -> str:
    text = str(value).strip()
    if not text:
        raise FemDeltaError("output component name must not be empty")
    if any(character in text for character in "\r\n\x00\""):
        raise FemDeltaError("output component name contains an unsupported character")
    return text


def _dof(value: Any) -> str:
    text = str(value).strip()
    if not text or any(character not in "123456" for character in text):
        raise FemDeltaError("rigid DOF must contain only digits 1 through 6")
    if len(set(text)) != len(text):
        raise FemDeltaError("rigid DOF must not contain duplicate digits")
    return text


def _positive_ids(values: Iterable[Any], label: str) -> List[int]:
    result = []
    for value in values:
        converted = int(value)
        if converted <= 0:
            raise FemDeltaError("{} contains a non-positive ID".format(label))
        result.append(converted)
    if len(result) != len(set(result)):
        raise FemDeltaError("{} contains duplicate IDs".format(label))
    return result


def _coordinates(value: Sequence[Any]) -> Tuple[float, float, float]:
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        raise FemDeltaError("rigid center must contain exactly three coordinates")
    result = tuple(float(item) for item in value)
    if not all(math.isfinite(item) for item in result):
        raise FemDeltaError("rigid center coordinates must be finite")
    return result  # type: ignore[return-value]


def _continuations(prefix: Sequence[Any], remaining: Sequence[int], width: int = 7) -> List[str]:
    lines = [",".join(str(value) for value in prefix)]
    for offset in range(0, len(remaining), width):
        lines.append("+,{}".format(",".join(str(value) for value in remaining[offset:offset + width])))
    return lines


def rbe2_lines(element_id: int, independent_node_id: int, dof: str, dependent_node_ids: Sequence[int]) -> List[str]:
    first = list(dependent_node_ids[:4])
    return _continuations(
        ("RBE2", element_id, independent_node_id, dof, *first),
        dependent_node_ids[4:],
    )


def rbe3_lines(element_id: int, reference_node_id: int, dof: str, dependent_node_ids: Sequence[int]) -> List[str]:
    # One weight/component group is sufficient because HMWorkFlow applies the
    # same unit weight and DOF set to every dependent grid.
    first = list(dependent_node_ids[:2])
    return _continuations(
        ("RBE3", element_id, "", reference_node_id, dof, "1.0", dof, *first),
        dependent_node_ids[2:],
    )


def write_rigid_incremental_fem(
    path: Path,
    candidates: Iterable[MutableMapping[str, Any]],
    request: Mapping[str, Any],
) -> Dict[str, Any]:
    """Write new GRID and RBE2/RBE3 cards for CREATE candidates only."""
    settings = request.get("settings", {})
    if not isinstance(settings, Mapping):
        raise FemDeltaError("request.settings must be an object")
    selected = [
        row for row in candidates if row.get("recommended_action", "CREATE") == "CREATE"
    ]
    manifest = new_manifest(Path(path), len(selected))
    if bool(settings.get("dryRun", False)) or not selected:
        return manifest

    rigid_type = str(settings.get("rigidType", "RBE2")).strip().upper()
    if rigid_type not in {"RBE2", "RBE3"}:
        raise FemDeltaError("rigidType must be RBE2 or RBE3")
    dof = _dof(settings.get("dof", 123456))
    component_name = _safe_component_name(settings.get("outputComponentName", "AUTO_RBE2"))
    raw_component_names = settings.get("outputComponentNames", {})
    if not isinstance(raw_component_names, Mapping):
        raise FemDeltaError("outputComponentNames must be an object")
    component_names = {
        str(source_id): _safe_component_name(name)
        for source_id, name in raw_component_names.items()
    }
    state = request.get("id_state")
    if not isinstance(state, Mapping):
        raise FemDeltaError("request.id_state is required for incremental import")
    for key in ("max_node_id", "max_element_id", "max_component_id"):
        if key not in state:
            raise FemDeltaError("request.id_state.{} is required".format(key))
    components = entity_registry(request, "components")
    allocator = EntityIdAllocator(state)
    max_existing_node_id = int(state["max_node_id"])

    lines = [
        "$ HMWF_INCREMENTAL_RIGID_IMPORT_V1",
        "$ Contains only new GRID and {} entities.".format(rigid_type),
        "BEGIN BULK",
    ]
    resolved_components: Dict[str, int] = {}

    for candidate in selected:
        source_id = str(candidate.get("source_component_id", candidate.get("component_id", "")))
        output_name = component_names.get(source_id, component_name)
        if output_name not in resolved_components:
            if output_name in components:
                resolved_components[output_name] = components[output_name]
                manifest["reused_component_ids"].append(components[output_name])
            else:
                resolved_components[output_name] = allocator.reserve("component")
                manifest["created_component_ids"].append(resolved_components[output_name])
                lines.append('$HMNAME COMP {} "{}"'.format(resolved_components[output_name], output_name))
        component_id = resolved_components[output_name]

        # Set the collector before every GRID because a batch may alternate
        # between source components and their distinct output collectors.
        lines.append("$HMCOMP ID {}".format(component_id))
        center = _coordinates(candidate.get("center"))
        dependent = _positive_ids(
            candidate.get("dependent_node_ids", candidate.get("wall_node_ids", [])),
            "candidate dependent_node_ids",
        )
        if len(dependent) < 3:
            raise FemDeltaError("rigid candidate requires at least three dependent nodes")
        if max(dependent) > max_existing_node_id:
            raise FemDeltaError("rigid candidate references a GRID above max_node_id")
        node_id = allocator.reserve("node")
        element_id = allocator.reserve("element")
        candidate["generated_node_id"] = node_id
        candidate["generated_element_id"] = element_id
        candidate["generated_component_id"] = component_id

        lines.append("GRID,{},,{:.12g},{:.12g},{:.12g}".format(node_id, *center))
        if rigid_type == "RBE2":
            lines.extend(rbe2_lines(element_id, node_id, dof, dependent))
        else:
            lines.extend(rbe3_lines(element_id, node_id, dof, dependent))

        manifest["created_node_ids"].append(node_id)
        manifest["created_element_ids"].append(element_id)
        manifest["expected_rigids"].append({
            "candidate_id": str(candidate.get("candidate_id", "")),
            "element_id": element_id,
            "independent_node_id": node_id,
            "dependent_node_ids": dependent,
            "component_id": component_id,
            "rigid_type": rigid_type,
            "dof": dof,
            "center": list(center),
        })

    lines.extend(("ENDDATA", ""))
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines), encoding="utf-8")
    return manifest
