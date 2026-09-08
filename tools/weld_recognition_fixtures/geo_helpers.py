"""Standard analytical shapes shared by the V2 weld fixture cases.

Everything in this module is geometry-only and independent of the production
recognizer.  The conventions follow the fixture specification:

    X = weld direction   Y = transverse   Z = vertical

Standard target midsurface:  X 0..400, Y -100..100, Z 0, thickness 10
(top physical skin Z +5).  Standard source web: X 50..350, Y 0, Z 5..105,
thickness 6, normal +/-Y, so the weld line sits exactly on the target top skin.
"""
from __future__ import annotations

import math
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from wfc_model import ModelBuilder, CaseModel


def _divisible_count(length: float, size: float) -> int:
    return max(1, int(round(length / float(size))))


def flat_target(
    b: ModelBuilder,
    name: str,
    x0: float, x1: float,
    y0: float, y1: float,
    z: float,
    thickness: float,
    h: float = 20.0,
    zoffs: Optional[float] = None,
    *,
    omit=None,
    flip: Optional[Callable[[int, int], bool]] = None,
    split: Optional[set] = None,
    warp: Optional[Callable[[float], float]] = None,
    nodal_t: Optional[Callable[[float], Optional[float]]] = None,
    reuse: Optional[Tuple[int, int]] = None,
) -> Tuple[int, List[List[int]], Dict[Tuple[int, int], int], Dict[str, float]]:
    """Flat target plate on the X-Y plane with +Z analytic normal.

    Returns ``(component_id, lattice, cells, geometry)``; ``geometry`` carries
    ``nx``/``ny`` element counts and the analytic physical skin Z values.
    Pass ``reuse=(component_id, property_id)`` to mesh a second island into an
    existing component (same thickness).
    """
    nx = _divisible_count(x1 - x0, h)
    ny = _divisible_count(y1 - y0, h)
    u_step = ((x1 - x0) / nx, 0.0, 0.0)
    v_step = (0.0, (y1 - y0) / ny, 0.0)
    component_id, lattice, cells = b.lattice_patch(
        name, (x0, y0, z), u_step, v_step, nx, ny, thickness, zoffs,
        omit=omit, flip=flip, split_tris=split,
        warp=(lambda i, j, _f=warp: _f(x0 + i * u_step[0])) if warp else None,
        nodal_t=(lambda i, j, _f=nodal_t: _f(x0 + i * u_step[0])) if nodal_t else None,
        reuse=reuse,
    )
    offset = zoffs if zoffs is not None else 0.0
    return component_id, lattice, cells, {
        "nx": nx, "ny": ny, "hx": u_step[0], "hy": v_step[1],
        "top_skin_z": z + 0.5 * thickness + offset,
        "bottom_skin_z": z - 0.5 * thickness + offset,
        "mid_z": z,
    }


def vertical_web(
    b: ModelBuilder,
    name: str,
    x0: float, x1: float,
    z0: float, z1: float,
    y: float = 0.0,
    h: float = 10.0,
    thickness: float = 6.0,
    *,
    lean_deg: float = 0.0,
    omit=None,
    flip: Optional[Callable[[int, int], bool]] = None,
) -> Tuple[int, List[List[int]], Dict[str, float]]:
    """Vertical (or leaned) web plate whose analytic normal is +/-Y.

    The plate lattice spans X (weld direction) and Z (rise).  ``lean_deg``
    rotates the plate around the X axis: the bottom row stays on the weld
    line (Y, Z0) while the top row leans by ``(Z1-Z0)*tan(lean)`` toward +Y.
    """
    nx = _divisible_count(x1 - x0, h)
    nz = _divisible_count(z1 - z0, h)
    rise = z1 - z0
    radians = math.radians(lean_deg)
    step_along = rise / nz / math.cos(radians)
    v_vec = (0.0, step_along * math.sin(radians), step_along * math.cos(radians))
    u_step = ((x1 - x0) / nx, 0.0, 0.0)
    component_id, lattice, cells = b.lattice_patch(
        name, (x0, y, z0), u_step, v_vec, nx, nz, thickness,
        omit=omit, flip=flip,
    )
    return component_id, lattice, {"nx": nx, "nz": nz, "z0": z0, "z1": z1, "hx": u_step[0]}


def ruled_xz_web(
    b: ModelBuilder,
    name: str,
    bottom_x: Sequence[float],
    bottom_z_fn: Callable[[float], float],
    z1: float,
    y: float = 0.0,
    thickness: float = 6.0,
    *,
    extra_layers: int = 0,
) -> Tuple[int, List[List[int]], List[int]]:
    """Web following an analytic bottom profile ``z = bottom_z_fn(x)``.

    The bottom row nodes are placed at ``(x, y, bottom_z_fn(x))`` for every
    sample ``x`` in ``bottom_x``, then the plate is extruded vertically to
    ``z1``.  Returns the component id, the node lattice and the bottom-chain
    node ids ordered along increasing X.
    """
    nz = int(round((z1 - bottom_z_fn(bottom_x[0])) / 10.0))
    nz = max(1, nz)
    component_id, property_id = b.new_component(name, thickness)
    lattice = []
    for k in range(nz + 1):
        row = []
        fraction = k / float(nz)
        for x in bottom_x:
            z = bottom_z_fn(x) + fraction * (z1 - bottom_z_fn(x))
            row.append(b.node((x, y, z)))
        lattice.append(row)
    for k in range(nz):
        for i in range(len(bottom_x) - 1):
            b.quad(component_id, property_id, (
                lattice[k][i], lattice[k][i + 1],
                lattice[k + 1][i + 1], lattice[k + 1][i],
            ))
    bottom_chain = list(lattice[0])
    return component_id, lattice, bottom_chain


def chain_from_lattice_row(lattice_row: List[int], x_ascending: bool = True) -> List[int]:
    """Return a lattice row's node ids ordered along the U (X) axis."""
    if x_ascending:
        return list(lattice_row)
    return list(reversed(lattice_row))


def weld_x_length(nodes_x: Sequence[float]) -> float:
    return float(max(nodes_x) - min(nodes_x))
