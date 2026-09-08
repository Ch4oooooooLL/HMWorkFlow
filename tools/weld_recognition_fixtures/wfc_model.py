"""Independent analytical shell FEM model used to build V2 weld fixtures.

The generator never imports the production ``hmworkflow.fem_auto_seam``
recognition code: every surface is meshed here from explicit midsurface /
thickness / ZOFFS / normal definitions, so ground truth stays independent of
the recognizer.

Coordinate convention for the default T cases (mirrors the fixture spec):

    X = weld direction   Y = transverse   Z = vertical

A flat horizontal target (normal +Z) is meshed on a lattice whose element
winding yields a +Z analytic normal.  Web plates are meshed on the XZ plane
(y=0) so their analytic normal is +/-Y.
"""
from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence, Tuple


# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------


@dataclass
class Node:
    node_id: int
    x: float
    y: float
    z: float

    @property
    def xyz(self) -> Tuple[float, float, float]:
        return (self.x, self.y, self.z)


@dataclass
class Component:
    component_id: int
    name: str
    thickness: float
    property_id: int


@dataclass
class ShellElem:
    element_id: int
    component_id: int
    element_type: str  # CQUAD4 / CTRIA3
    node_ids: List[int]
    property_id: int
    zoffs: Optional[float] = None  # None means the FEM card field is blank
    nodal_thickness: Optional[List[Optional[float]]] = None  # Ti per vertex


@dataclass
class CaseModel:
    nodes: Dict[int, Node] = field(default_factory=dict)
    components: Dict[int, Component] = field(default_factory=dict)
    elements: Dict[int, ShellElem] = field(default_factory=dict)
    meta: Dict[str, object] = field(default_factory=dict)


class ModelBuilder:
    """Deterministic analytical mesher.

    IDs are allocated from three independent counters so a composite model can
    merge several atomic models without collision by offsetting the counters.
    """

    def __init__(self, node_base: int = 1, elem_base: int = 1,
                 comp_base: int = 1, pid_base: int = 1, material_id: int = 1):
        self.model = CaseModel()
        self._next_node = node_base
        self._next_elem = elem_base
        self._next_comp = comp_base
        self._next_pid = pid_base
        self._material = material_id

    # -- counters -----------------------------------------------------------

    def new_node_id(self) -> int:
        node_id = self._next_node
        self._next_node += 1
        return node_id

    def new_elem_id(self) -> int:
        element_id = self._next_elem
        self._next_elem += 1
        return element_id

    def new_component(self, name: str, thickness: float) -> Tuple[int, int]:
        component_id = self._next_comp
        self._next_comp += 1
        property_id = self._next_pid
        self._next_pid += 1
        self.model.components[component_id] = Component(component_id, name, float(thickness), property_id)
        return component_id, property_id

    # -- primitives ---------------------------------------------------------

    def node(self, point: Sequence[float]) -> int:
        node_id = self.new_node_id()
        x, y, z = (float(value) for value in point)
        self.model.nodes[node_id] = Node(node_id, x, y, z)
        return node_id

    def quad(self, component_id: int, property_id: int, node_ids: Sequence[int],
             zoffs: Optional[float] = None,
             nodal_thickness: Optional[Sequence[Optional[float]]] = None) -> int:
        element_id = self.new_elem_id()
        self.model.elements[element_id] = ShellElem(
            element_id, component_id, "CQUAD4", list(node_ids), property_id,
            zoffs=zoffs,
            nodal_thickness=None if nodal_thickness is None
            else [float(value) if value is not None else None for value in nodal_thickness],
        )
        return element_id

    def tri(self, component_id: int, property_id: int, node_ids: Sequence[int],
            zoffs: Optional[float] = None,
            nodal_thickness: Optional[Sequence[Optional[float]]] = None) -> int:
        element_id = self.new_elem_id()
        self.model.elements[element_id] = ShellElem(
            element_id, component_id, "CTRIA3", list(node_ids), property_id,
            zoffs=zoffs,
            nodal_thickness=None if nodal_thickness is None
            else [float(value) if value is not None else None for value in nodal_thickness],
        )
        return element_id

    # -- lattice mesh ---------------------------------------------------------

    def lattice_patch(
        self,
        name: str,
        origin: Sequence[float],
        u_vec: Sequence[float],
        v_vec: Sequence[float],
        u_count: int,
        v_count: int,
        thickness: float,
        zoffs: Optional[float] = None,
        *,
        omit: Optional[set] = None,
        flip: Optional[Callable[[int, int], bool]] = None,
        split_tris: Optional[set] = None,
        warp: Optional[Callable[[int, int], float]] = None,
        nodal_t: Optional[Callable[[int, int], Optional[float]]] = None,
        reuse: Optional[Tuple[int, int]] = None,
    ) -> Tuple[int, List[List[int]], Dict[Tuple[int, int], int]]:
        """Analytical parallelogram lattice of CQUAD4/CTRIA3 shell elements.

        Returns ``(component_id, lattice, cells)`` where ``lattice[j][i]`` is
        the node id of lattice position (i, j) and ``cells[(i, j)]`` is the
        element id covering cell (i, j) (absent when the cell is ``omit``-ed).

        Element winding produces an analytic normal along ``u_vec x v_vec``;
        pass ``flip(i, j)=True`` per cell to reverse the winding for
        deliberately inconsistent/inverted regions.  ``warp(i, j)`` adds an
        offset along the analytic-normal axis (conventionally Z) at lattice
        position (i, j).  ``nodal_t(i, j)`` optionally returns the Ti value at
        that lattice vertex (None => blank => PSHELL T applies).  ``split_tris``
        is a set of cell (i, j) indices whose quad is split into two CTRIA3.
        ``reuse`` is an optional ``(component_id, property_id)`` pair when the
        new lattice belongs to an existing component (same name/thickness).
        """
        if reuse is not None:
            component_id, property_id = reuse
        else:
            component_id, property_id = self.new_component(name, thickness)
        lattice: List[List[int]] = []
        for j in range(v_count + 1):
            row: List[int] = []
            for i in range(u_count + 1):
                x = origin[0] + i * u_vec[0] + j * v_vec[0]
                y = origin[1] + i * u_vec[1] + j * v_vec[1]
                z = origin[2] + i * u_vec[2] + j * v_vec[2]
                if warp is not None:
                    z += float(warp(i, j))
                row.append(self.node((x, y, z)))
            lattice.append(row)

        cells: Dict[Tuple[int, int], int] = {}
        for j in range(v_count):
            for i in range(u_count):
                if omit is not None and (i, j) in omit:
                    continue
                a, b = lattice[j][i], lattice[j][i + 1]
                c, d = lattice[j + 1][i + 1], lattice[j + 1][i]
                n0, n1, n2, n3 = (a, b, c, d)
                if flip is not None and flip(i, j):
                    n0, n1, n2, n3 = (a, d, c, b)
                nodes_quad = (n0, n1, n2, n3)
                node_t = None
                if nodal_t is not None:
                    node_t = [nodal_t(i, j), nodal_t(i + 1, j), nodal_t(i + 1, j + 1), nodal_t(i, j + 1)]
                if split_tris is not None and (i, j) in split_tris:
                    first = self.tri(component_id, property_id, (n0, n1, n2), zoffs=zoffs,
                                     nodal_thickness=None if node_t is None else (node_t[0], node_t[1], node_t[2]))
                    second = self.tri(component_id, property_id, (n0, n2, n3), zoffs=zoffs,
                                      nodal_thickness=None if node_t is None else (node_t[0], node_t[2], node_t[3]))
                    cells[(i, j)] = first  # first tri owns the cell for lookup
                else:
                    cells[(i, j)] = self.quad(component_id, property_id, nodes_quad, zoffs=zoffs,
                                              nodal_thickness=node_t)
        return component_id, lattice, cells

    # -- independent geometric helpers ---------------------------------------

    def xyz(self, node_id: int) -> Tuple[float, float, float]:
        node = self.model.nodes[node_id]
        return (node.x, node.y, node.z)

    def node_coords(self, node_ids: Sequence[int]) -> List[Tuple[float, float, float]]:
        return [self.xyz(node_id) for node_id in node_ids]


def translate_model(source: CaseModel, offset: Sequence[float]) -> None:
    """Translate every node of an existing model in place (composite staging)."""
    dx, dy, dz = (float(value) for value in offset)
    for node in source.nodes.values():
        node.x += dx
        node.y += dy
        node.z += dz


def node_xyz(model: CaseModel, node_id: int) -> Tuple[float, float, float]:
    node = model.nodes[node_id]
    return (node.x, node.y, node.z)


def component_thickness(model: CaseModel, component_id: int) -> float:
    return float(model.components[component_id].thickness)


def node_average_z(model: CaseModel, node_ids: Sequence[int]) -> float:
    return sum(node_xyz(model, node_id)[2] for node_id in node_ids) / len(node_ids)
