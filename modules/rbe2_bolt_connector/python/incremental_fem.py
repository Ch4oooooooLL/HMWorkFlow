"""Create an import-only FEM containing new bolt entities and existing endpoint GRIDs."""
from __future__ import annotations

import math
import re
from pathlib import Path
from typing import Any, Dict, Iterable, Tuple

try:
    from hmworkflow.core.fem_delta import EntityIdAllocator, entity_registry, new_manifest
except ImportError:  # Standalone HM2019 entry compatibility.
    from fem_delta import EntityIdAllocator, entity_registry, new_manifest


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


def _endpoint_coordinates(plans: Iterable[Dict[str, Any]]) -> Dict[int, Tuple[float, float, float]]:
    """Return one validated coordinate per existing RBE2 center GRID."""
    result = {}  # type: Dict[int, Tuple[float, float, float]]
    for plan in plans:
        for node_key, rigid_key in (("node_1", "rbe2_a"), ("node_2", "rbe2_b")):
            node_id = int(plan[node_key])
            raw = plan[rigid_key]["center"]
            point = tuple(float(raw[index]) for index in range(3))
            if not all(math.isfinite(value) for value in point):
                raise IncrementalFemError("endpoint GRID {} has non-finite coordinates".format(node_id))
            previous = result.get(node_id)
            if previous is not None and any(abs(previous[index] - point[index]) > 1.0e-7 for index in range(3)):
                raise IncrementalFemError("endpoint GRID {} has inconsistent coordinates".format(node_id))
            result[node_id] = point  # type: ignore[assignment]
    return result


def write_incremental_fem(
    path: Path, plans: Iterable[Dict[str, Any]], request: Dict[str, Any]
) -> Dict[str, Any]:
    settings = request["settings"]
    selected = [
        plan for plan in plans if plan.get("recommended_action", "CREATE") == "CREATE"
    ]
    manifest = new_manifest(Path(path), len(selected))
    manifest["temporary_node_ids"] = []
    manifest["endpoint_replacements"] = []
    manifest["reuse_existing_node_ids"] = True
    manifest["endpoint_coordinate_tolerance"] = 1.0e-7
    manifest["property_assignments"] = []
    if settings.get("dryRun") or not selected:
        return manifest

    state = request.get("id_state", {})
    allocator = EntityIdAllocator(state)
    properties = entity_registry(request, "properties")
    materials = entity_registry(request, "materials")
    components = entity_registry(request, "components")
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
        "$ Existing endpoint GRID IDs are imported with overwrite_flag=1.",
        "BEGIN BULK",
    ]
    endpoint_coordinates = _endpoint_coordinates(selected)
    for existing_node_id in sorted(endpoint_coordinates):
        point = endpoint_coordinates[existing_node_id]
        lines.append("GRID,{},,{:.12g},{:.12g},{:.12g}".format(existing_node_id, *point))
    required_property_names = {
        "{}_D{}_{}".format(prefix, "{:g}".format(float(plan["diameter"])), property_card)
        for plan in selected
    }
    needs_new_property = not custom_property and any(
        name not in properties for name in required_property_names
    )
    if needs_new_property and material_id is None:
        material_id = allocator.reserve("material")
        manifest["created_material_ids"].append(material_id)
        lines.extend((
            '$HMNAME MAT {} "steel"'.format(material_id),
            "MAT1,{},210000.0,,0.3,7.85E-9".format(material_id),
        ))

    property_ids = {}
    component_ids = {}
    property_assignments = {}
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
            property_id = allocator.reserve("property")
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
                component_id = allocator.reserve("component")
                manifest["created_component_ids"].append(component_id)
                lines.append('$HMNAME COMP {} "{}"'.format(component_id, component_name))
            component_ids[component_name] = component_id

        element_id = allocator.reserve("element")
        orientation = _orientation(plan)
        # Repeat the collector switch for every element. Plans can interleave
        # diameters, and relying on the previous active collector is unsafe.
        lines.append("$HMCOMP ID {}".format(component_ids[component_name]))
        original_node_1 = int(plan["node_1"])
        original_node_2 = int(plan["node_2"])
        import_node_1 = original_node_1
        import_node_2 = original_node_2
        lines.append(
            "{},{},{},{},{},{:.12g},{:.12g},{:.12g}".format(
                element_type,
                element_id,
                property_id,
                import_node_1,
                import_node_2,
                orientation[0],
                orientation[1],
                orientation[2],
            )
        )
        plan["generated_element_id"] = element_id
        plan["generated_property_id"] = property_id
        manifest["created_element_ids"].append(element_id)
        manifest["expected_segments"].append(
            {
                "element_id": element_id,
                "node_1": original_node_1,
                "node_2": original_node_2,
                "import_node_1": import_node_1,
                "import_node_2": import_node_2,
                "component_id": component_ids[component_name],
                "node_1_coordinates": list(endpoint_coordinates[original_node_1]),
                "node_2_coordinates": list(endpoint_coordinates[original_node_2]),
            }
        )
        assignment_key = (component_ids[component_name], property_id)
        if assignment_key not in property_assignments:
            property_assignments[assignment_key] = {
                "component_id": component_ids[component_name],
                "component_name": component_name,
                "property_id": property_id,
                "property_name": property_name,
                "property_card": property_card,
                "element_type": element_type,
                "diameter": diameter,
                "beam_section_name": "{}_D{}_SOLID_CIRCLE".format(prefix, diameter_label),
                "create_solid_circle": not bool(custom_property),
                "element_ids": [],
            }
        property_assignments[assignment_key]["element_ids"].append(element_id)
    manifest["property_assignments"] = list(property_assignments.values())
    lines.extend(("ENDDATA", ""))
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text("\n".join(lines), encoding="utf-8")
    return manifest
