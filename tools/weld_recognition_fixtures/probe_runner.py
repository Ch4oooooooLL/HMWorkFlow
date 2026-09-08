"""Convert fixture models to the production MeshModel and run recognition.

This is a *test-only* bridge used by probe scripts and by the regression
runner.  It converts the analytical fixture records into the production
``hmworkflow`` mesh records so the recognizer can consume them.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Dict, Optional

ROOT = Path(__file__).resolve().parent.parent.parent
if str(ROOT / "python") not in sys.path:
    sys.path.insert(0, str(ROOT / "python"))
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from hmworkflow.core.mesh_model import Component, Element, MeshModel  # noqa: E402
from hmworkflow.fem_auto_seam.backend import DEFAULT_SETTINGS, detect_candidates  # noqa: E402


def to_production_model(builder):
    """Map a wfc CaseModel (or ModelBuilder) to the production MeshModel."""
    model = builder.model if hasattr(builder, "model") else builder
    nodes = {
        node_id: (node.x, node.y, node.z)
        for node_id, node in model.nodes.items()
    }
    components = {
        component_id: Component(component_id, component.name, "SHELL")
        for component_id, component in model.components.items()
    }
    elements = {
        element.element_id: Element(
            element.element_id, element.component_id, element.element_type,
            tuple(element.node_ids),
        )
        for element in model.elements.values()
    }
    mesh = MeshModel(components, nodes, elements)
    mesh.element_properties = {
        element.element_id: element.property_id for element in model.elements.values()
    }
    mesh.pshell = {
        component.property_id: {"material_id": 1, "thickness": component.thickness}
        for component in model.components.values()
    }
    mesh.materials = {1: ["210000", "", "0.3"]}
    zoffs = {
        element.element_id: element.zoffs
        for element in model.elements.values()
        if element.zoffs is not None
    }
    if zoffs:
        mesh.element_zoffs = zoffs
    nodal = {
        element.element_id: element.nodal_thickness
        for element in model.elements.values()
        if element.nodal_thickness
    }
    if nodal:
        mesh.element_nodal_thicknesses = nodal
    return mesh


def detect(builder, settings: Optional[Dict] = None):
    mesh = to_production_model(builder)
    resolved = dict(DEFAULT_SETTINGS)
    if settings:
        resolved.update(settings)
    return detect_candidates(mesh, resolved)
