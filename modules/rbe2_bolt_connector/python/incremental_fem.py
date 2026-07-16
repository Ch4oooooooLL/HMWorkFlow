"""Create an import-only FEM containing new bolt entities and no source mesh."""
from __future__ import annotations

import math
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple


class IncrementalFemError(ValueError):
    pass


def _safe_name(value: str) -> str:
    cleaned = "_".join(filter(None, re.split(r"[^A-Za-z0-9]+", str(value))))
    return cleaned or "BOLT"


def _section(diameter: float) -> Tuple[float, float, float]:
    if diameter <= 0:
        raise IncrementalFemError("bolt diameter must be positive, got {}".format(diameter))
    area = math.pi * diameter * diameter / 4.0
    inertia = math.pi * diameter ** 4 / 64.0
    torsion = math.pi * diameter ** 4 / 32.0
    return area, inertia, torsion


def _orientation(plan: Dict[str, Any]) -> Tuple[float, float, float]:
    a = plan["rbe2_a"]["center"]
    b = plan["rbe2_b"]["center"]
    delta = [float(b[index]) - float(a[index]) for index in range(3)]
    length = math.sqrt(sum(value * value for value in delta))
    if length <= 0:
        raise IncrementalFemError("candidate {} has coincident endpoints".format(plan["candidate_id"]))
    return (0.0, 0.0, 1.0) if abs(delta[2] / length) < 0.90 else (0.0, 1.0, 0.0)


def _registry(request: Dict[str, Any], key: str) -> Dict[str, int]:
    raw = request.get("entity_registry", {}).get(key, {})
    return {str(name): int(value) for name, value in raw.items()}


def write_incremental_fem(
    path: Path, plans: Iterable[Dict[str, Any]], request: Dict[str, Any]
) -> Dict[str, Any]:
    settings = request["settings"]
    selected = [
        plan for plan in plans if plan.get("recommended_action", "CREATE") == "CREATE"
    ]
    manifest = {
        "incremental_fem": str(Path(path).resolve()),
        "planned_create_count": len(selected),
        "created_element_ids": [],
        "created_property_ids": [],
        "created_material_ids": [],
        "created_component_ids": [],
        "reused_property_ids": [],
        "reused_component_ids": [],
        "expected_segments": [],
    }
    if settings.get("dryRun") or not selected:
        return manifest

    state = request.get("id_state", {})
    next_element = int(state.get("max_element_id", 0)) + 1
    next_property = int(state.get("max_property_id", 0)) + 1
    next_material = int(state.get("max_material_id", 0)) + 1
    next_component = int(state.get("max_component_id", 0)) + 1
    properties = _registry(request, "properties")
    materials = _registry(request, "materials")
    components = _registry(request, "components")
    custom_property = str(settings.get("propName", "")).strip()
    if custom_property and custom_property not in properties:
        raise IncrementalFemError(
            "custom property {!r} is not present in the current HyperMesh model".format(
                custom_property
            )
        )

    element_type = str(settings.get("elemType", "CBEAM")).upper()
    property_card = "PBAR" if element_type == "CBAR" else "PBEAM"
    prefix = _safe_name(settings.get("compPrefix", "BOLT"))
    material_id = materials.get("steel")
    lines = [
        "$ HMWF_INCREMENTAL_BOLT_IMPORT_V1",
        "$ Import into the current HyperMesh model; contains no GRID or RBE2 cards.",
        "BEGIN BULK",
    ]
    required_property_names = {
        "{}_D{}_{}".format(prefix, "{:g}".format(float(plan["diameter"])), property_card)
        for plan in selected
    }
    needs_new_property = not custom_property and any(
        name not in properties for name in required_property_names
    )
    if needs_new_property and material_id is None:
        material_id = next_material
        next_material += 1
        manifest["created_material_ids"].append(material_id)
        lines.extend((
            '$HMNAME MAT {} "steel"'.format(material_id),
            "MAT1,{},210000.0,,0.3,7.85E-9".format(material_id),
        ))

    property_ids = {}
    component_ids = {}
    for plan in selected:
        diameter = float(plan["diameter"])
        diameter_label = "{:g}".format(diameter)
        property_name = custom_property or "{}_D{}_{}".format(
            prefix, diameter_label, property_card
        )
        component_name = "{}_D{}_{}".format(prefix, diameter_label, element_type)
        if property_name in properties:
            property_id = properties[property_name]
            if property_id not in manifest["reused_property_ids"]:
                manifest["reused_property_ids"].append(property_id)
        elif property_name in property_ids:
            property_id = property_ids[property_name]
        else:
            property_id = next_property
            next_property += 1
            property_ids[property_name] = property_id
            manifest["created_property_ids"].append(property_id)
            area, inertia, torsion = _section(diameter)
            lines.append('$HMNAME PROP {} "{}"'.format(property_id, property_name))
            if property_card == "PBAR":
                lines.append(
                    "PBAR,{},{},{:.12g},{:.12g},{:.12g},{:.12g},0.0".format(
                        property_id, material_id, area, inertia, inertia, torsion
                    )
                )
            else:
                lines.append(
                    "PBEAM,{},{},{:.12g},{:.12g},{:.12g},0.0,{:.12g},0.0".format(
                        property_id, material_id, area, inertia, inertia, torsion
                    )
                )

        if component_name not in component_ids:
            if component_name in components:
                component_id = components[component_name]
                manifest["reused_component_ids"].append(component_id)
            else:
                component_id = next_component
                next_component += 1
                manifest["created_component_ids"].append(component_id)
                lines.append('$HMNAME COMP {} "{}"'.format(component_id, component_name))
            component_ids[component_name] = component_id

        element_id = next_element
        next_element += 1
        orientation = _orientation(plan)
        # Repeat the collector switch for every element. Plans can interleave
        # diameters, and relying on the previous active collector is unsafe.
        lines.append("$HMCOMP ID {}".format(component_ids[component_name]))
        lines.append(
            "{},{},{},{},{},{:.12g},{:.12g},{:.12g}".format(
                element_type,
                element_id,
                property_id,
                int(plan["node_1"]),
                int(plan["node_2"]),
                orientation[0],
                orientation[1],
                orientation[2],
            )
        )
        plan["generated_element_id"] = element_id
        plan["generated_property_id"] = property_id
        manifest["created_element_ids"].append(element_id)
        manifest["expected_segments"].append(
            {"element_id": element_id, "node_1": int(plan["node_1"]), "node_2": int(plan["node_2"])}
        )
    lines.extend(("ENDDATA", ""))
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text("\n".join(lines), encoding="utf-8")
    return manifest
