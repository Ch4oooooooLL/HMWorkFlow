"""Deterministic OptiStruct FEM writer for the V2 weld-recognition fixtures.

The emitted free-field layout mirrors what HyperMesh writes for a shell
selection export and what the production reader
(``hmworkflow.mesh_seam_weld.fem_mesh_reader``) accepts:

    $ HMWF_OFFLINE_AUTO_SEAM_MODEL
    BEGIN BULK
    GRID,id,,x,y,z
    $HMNAME COMP <id> "<name>"
    $HMCOMP ID <id>
    CQUAD4,eid,pid,n1,n2,n3,n4[,<theta>,<zoffs>][\n+,,,T1,T2,T3,T4]
    ...
    PSHELL,pid,mid,T
    MAT1,mid,E,,NU
    ENDDATA

Only the standard library is used, matching the portable Python constraint.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Optional

from wfc_model import CaseModel, Node


def _format_number(value: float) -> str:
    return "{:.12g}".format(float(value))


def _element_lines(element, component, property_id) -> List[str]:
    """Return the physical-card line(s) for one shell element."""
    values = [element.element_type, str(element.element_id), str(property_id)]
    values.extend(str(node_id) for node_id in element.node_ids)
    needs_physical = element.zoffs is not None or element.nodal_thickness
    if not needs_physical:
        return [",".join(values)]
    # Logical column layout for a first-order shell card:
    #   card,eid,pid,node*N,theta,ZOFFS,(blank cols),(Ti on the + row)
    zoffs_text = "" if element.zoffs is None else _format_number(element.zoffs)
    values.extend(("", zoffs_text))
    values.extend("" for _ in range(10 - len(values)))
    lines = [",".join(values)]
    if element.nodal_thickness:
        thickness_values = ",".join(
            "" if value is None else _format_number(value)
            for value in element.nodal_thickness
        )
        lines.append("+,,,{}".format(thickness_values))
    return lines


def fem_lines(model: CaseModel, section_banners: Optional[Dict[int, str]] = None) -> List[str]:
    lines = ["$ HMWF_OFFLINE_AUTO_SEAM_MODEL", "BEGIN BULK"]
    for node_id in sorted(model.nodes):
        node = model.nodes[node_id]
        lines.append("GRID,{},,{},{},{}".format(node_id, _format_number(node.x), _format_number(node.y), _format_number(node.z)))
    by_component: Dict[int, List[int]] = {}
    for element in model.elements.values():
        by_component.setdefault(element.component_id, []).append(element.element_id)
    for component_id in sorted(model.components):
        component = model.components[component_id]
        banner = (section_banners or {}).get(component_id)
        if banner:
            lines.append("$ {}".format(banner))
            lines.append("$ {}".format("=" * len(banner)))
        lines.append('$HMNAME COMP {} "{}"'.format(component_id, component.name.replace('"', "")))
        lines.append("$HMCOMP ID {}".format(component_id))
        for element_id in sorted(by_component.get(component_id, [])):
            element = model.elements[element_id]
            lines.extend(_element_lines(element, component, element.property_id))
    for component_id in sorted(model.components):
        component = model.components[component_id]
        lines.append("PSHELL,{},{},{}".format(component.property_id, 1, _format_number(component.thickness)))
    lines.append("MAT1,1,210000,,0.3")
    lines.append("ENDDATA")
    lines.append("")
    return lines


def write_fem_bundle(model: CaseModel, fem_path, manifest_path=None, section_banners=None):
    """Write the .fem plus its HyperMesh component ownership manifest."""
    fem_path = Path(fem_path)
    if manifest_path is None:
        manifest_path = fem_path.with_suffix(".fem_manifest.json")
    fem_path.parent.mkdir(parents=True, exist_ok=True)
    fem_path.write_text("\n".join(fem_lines(model, section_banners)), encoding="utf-8")
    component_rows = []
    for component_id in sorted(model.components):
        component = model.components[component_id]
        component_rows.append({
            "component_id": component_id,
            "component_name": component.name,
            "element_ids": sorted(
                element.element_id for element in model.elements.values()
                if element.component_id == component_id
            ),
        })
    manifest = {
        "schema_version": "1.0",
        "format": "hm_auto_shell_seam_fem",
        "fem_path": fem_path.name,
        "components": component_rows,
        "statistics": {
            "node_count": len(model.nodes),
            "element_count": len(model.elements),
            "component_count": len(model.components),
            "element_type_counts": _element_type_counts(model),
        },
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def _element_type_counts(model: CaseModel) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for element in model.elements.values():
        counts[element.element_type] = counts.get(element.element_type, 0) + 1
    return counts


def node_chain_ids(model: CaseModel, node_ids) -> List[int]:
    return [int(value) for value in node_ids]
