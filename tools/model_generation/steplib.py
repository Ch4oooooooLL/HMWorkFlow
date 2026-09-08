#!/usr/bin/env python3
"""steplib.py -- shared STEP generation helpers for the HMWorkFlow model
generation suite (tools/model_generation), built on cadquery / OCP (OCCT).

Every exported STEP file gets its PRODUCT name replaced with the part name so
that HyperMesh 2019/2022 names the imported component after the part
(e.g. V01_BRACKET_T1.5).  Timestamps are normalised for deterministic output.

Two families of geometry are produced:

* solids  -- thin-wall sheet-metal brackets/panels (midsurf), feature blocks
             with chamfers/fillets/pockets (geometry_cleanup);
* shells  -- open surface faces with optional holes (seam_surface,
             batch_mesher).
"""

from __future__ import annotations

import math
import os
import re
from typing import Dict, List, Optional, Sequence, Tuple

import cadquery as cq

Point = Tuple[float, float, float]

_STAMP_RE = re.compile(r"'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'")


# ---------------------------------------------------------------------------
# Export helpers
# ---------------------------------------------------------------------------


def export_step(shape, path: str, name: str) -> None:
    """Export `shape` (cadquery Workplane/Shape) to a STEP file and embed
    `name` as the product name (component name in HyperMesh on import)."""
    if '"' in name or "'" in name:
        raise ValueError("part name must not contain quotes: " + name)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    cq.exporters.export(shape, path)
    text = open(path, encoding="latin-1").read()
    text = _STAMP_RE.sub("'2000-01-01T00:00:00'", text)
    # PRODUCT(name, description, frame, contexts) -- inject the part name.
    text = re.sub(
        r"(#\d+ = PRODUCT\()'[^']*'",
        lambda m: m.group(1) + "'" + name + "'",
        text, count=1)
    open(path, "w", encoding="latin-1").write(text)


def verify_step(path: str) -> dict:
    """Read a STEP file back through OCCT and report solids/faces/bbox."""
    shape = cq.importers.importStep(path)
    return shape_info(shape)


def shape_info(shape) -> dict:
    """Solids/faces/bbox of an in-memory cadquery Workplane/Shape."""
    val = shape.val()
    bb = val.BoundingBox()
    return {
        "solids": len(val.Solids()),
        "faces": len(val.Faces()),
        "bbox": [round(bb.xmin, 3), round(bb.ymin, 3), round(bb.zmin, 3),
                 round(bb.xmax, 3), round(bb.ymax, 3), round(bb.zmax, 3)],
    }


# ---------------------------------------------------------------------------
# Feature helpers
# ---------------------------------------------------------------------------


def drill(part: cq.Workplane, holes: Sequence[Tuple[float, float, float]],
          face_selector: str = ">Z") -> cq.Workplane:
    """Cut circular through-holes (x, y, diameter) into `part`, grouped by
    diameter.  Returns a new Workplane wrapping the updated solid."""
    if not holes:
        return part
    result = part
    by_d: Dict[float, List[Tuple[float, float]]] = {}
    for (x, y, d) in holes:
        by_d.setdefault(float(d), []).append((float(x), float(y)))
    for d, pts in by_d.items():
        work = result.faces(face_selector).workplane()
        if len(pts) == 1:
            work = work.center(pts[0][0], pts[0][1])
        else:
            work = work.pushPoints(pts)
        result = work.hole(d)
    return result


def drill_on_face(part: cq.Workplane, anchor: Tuple[float, float, float],
                  holes: Sequence[Tuple[float, float, float]]) -> cq.Workplane:
    """Cut through-holes from the face nearest `anchor`.  Hole coordinates
    (u, v, d) are relative to the face CENTRE in the face's own parameter
    frame (computed by cadquery's workplane())."""
    if not holes:
        return part
    result = part
    by_d: Dict[float, List[Tuple[float, float]]] = {}
    for (u, v, d) in holes:
        by_d.setdefault(float(d), []).append((float(u), float(v)))
    for d, pts in by_d.items():
        work = result.faces(cq.selectors.NearestToPointSelector(anchor)).workplane()
        if len(pts) == 1:
            work = work.center(pts[0][0], pts[0][1])
        else:
            work = work.pushPoints(pts)
        result = work.hole(d)
    return result


def cut_slot(part: cq.Workplane, u: float, v: float, length: float, width: float,
             face_selector: str = ">Z") -> cq.Workplane:
    """Cut an elongated slot (rounded ends) through the selected face.
    (u, v) are relative to the face centre; `length` along the face's u axis."""
    face = part.faces(face_selector).val()
    o = face.Center()
    r = width / 2.0
    straight = max(length - width, 1e-3)
    box = cq.Workplane("XY").box(straight, width, 20.0)
    c1 = cq.Workplane("XY").circle(r).extrude(20.0)
    c2 = c1.translate((straight, 0.0, 0.0))
    cutter = box.union(c1).union(c2).translate((o.x + u, o.y + v, o.z - 10.0))
    return part.cut(cutter)


def cut_counterbore(part: cq.Workplane, x: float, y: float,
                    hole_d: float, cb_d: float, cb_depth: float,
                    face_selector: str = ">Z") -> cq.Workplane:
    """Cut a counterbored hole: through hole + shallow wider pocket on top."""
    part = drill(part, [(x, y, hole_d)], face_selector)
    face = part.faces(face_selector).val()
    origin = face.Center()
    # pocket cylinder: from the top face down by cb_depth (+ small overshoot)
    pocket = cq.Workplane("XY").circle(cb_d / 2.0).extrude(cb_depth + 1.0)
    pocket = pocket.translate((origin.x + x, origin.y + y, origin.z - cb_depth - 1.0))
    return part.cut(pocket)


# ---------------------------------------------------------------------------
# Sheet-metal solid builders (midsurf / geometry_cleanup inputs)
# ---------------------------------------------------------------------------


def solid_from_profile(profile: Sequence[Tuple[float, float]], thickness: float,
                       depth: float, z0: float = 0.0) -> cq.Workplane:
    """Extrude a closed XY profile (list of (x, y) points) by `depth` along Z,
    starting at z0.  Returns a Workplane holding the solid."""
    wp = cq.Workplane("XY")
    for i, (x, y) in enumerate(profile):
        if i == 0:
            wp = wp.moveTo(x, y)
        else:
            wp = wp.lineTo(x, y)
    wp = wp.close()
    return wp.extrude(depth).translate((0.0, 0.0, z0))


def fillet_bend_edges(part: cq.Workplane, radius: float, t: float = 2.0) -> cq.Workplane:
    """Fillet the Z-parallel (bend) edges of an extruded profile part, one
    edge at a time with radius halving on failure.  Robust against short
    thickness edges where the full radius would consume the whole edge."""
    r = min(float(radius), 0.9 * float(t))
    result = part
    for e in list(result.edges("|Z").vals()):
        c = e.Center()
        sel = cq.selectors.NearestToPointSelector((c.x, c.y, c.z))
        for rr in (r, r * 0.5, r * 0.25):
            try:
                result = result.edges(sel).fillet(rr)
                break
            except Exception:
                continue
    return result


def flat_plate(w: float, h: float, t: float, z0: float = 0.0,
               holes: Sequence[Tuple[float, float, float]] = (),
               ) -> cq.Workplane:
    """Plain plate (centred at (0,0,z0)) with optional through holes."""
    part = cq.Workplane("XY").box(w, h, t).translate((0.0, 0.0, z0 + t / 2.0))
    if holes:
        part = drill(part, [(x + w / 2.0, y + h / 2.0, d) for x, y, d in holes])
    return part


def plate_with_flanges(w: float, h: float, t: float, flange: float,
                       bend_r: float = 2.0, z0: float = 0.0,
                       holes: Sequence[Tuple[float, float, float]] = (),
                       flange_holes: Sequence[Tuple[float, float, float]] = (),
                       ) -> cq.Workplane:
    """Flat plate with a 90-degree flange along one edge, built as an
    L-profile extrusion.  The plate is w (X) x h (Y) x t (Z); the flange is a
    t x flange strip on the X=t side.

    `holes`       = (x, z, d): through-thickness holes on the plate
                    (x in [0, h], z in [0, w]).
    `flange_holes`= (z, y, d): through-thickness holes on the flange
                    (z in [0, w], y in [t, flange])."""
    profile = [(0.0, 0.0), (h, 0.0), (h, t), (t, t), (t, flange), (0.0, flange)]
    part = fillet_bend_edges(solid_from_profile(profile, t, w, z0), bend_r, t)
    if holes:
        # plate top face (y = t), centre (h/2, t, w/2); frame u=x, v=z
        part = drill_on_face(part, (h / 2.0, t, w / 2.0),
                             [(x - h / 2.0, z - w / 2.0, d) for x, z, d in holes])
    if flange_holes:
        # flange outer face (x = t), centre (t, (t+flange)/2, w/2); frame u=z, v=y
        part = drill_on_face(part, (t, (t + flange) / 2.0, w / 2.0),
                             [(z - w / 2.0, y - (t + flange) / 2.0, d)
                              for z, y, d in flange_holes])
    return part


def l_bracket(leg1: float, leg2: float, w: float, t: float,
              bend_r: float = 3.0, z0: float = 0.0,
              holes: Sequence[Tuple[float, float, float]] = ()) -> cq.Workplane:
    """L-profile bracket extruded `w` wide.  Profile: horizontal leg `leg1`,
    vertical leg `leg2`, thickness `t` (profile origin at the outer corner).
    `holes` = (x_off, z_off, d) through-thickness holes on the horizontal
    leg, relative to the leg's top-face centre."""
    profile = [(0.0, 0.0), (leg1, 0.0), (leg1, t), (t, t), (t, leg2), (0.0, leg2)]
    part = fillet_bend_edges(solid_from_profile(profile, t, w, z0), bend_r, t)
    if holes:
        part = drill_on_face(part, (leg1 / 2.0, t, w / 2.0),
                             [(x, z, d) for x, z, d in holes])
    return part


def channel(span: float, legs: float, w: float, t: float, bend_r: float = 3.0,
            z0: float = 0.0, holes: Sequence[Tuple[float, float, float]] = ()) -> cq.Workplane:
    """U-channel: base `span` wide, two legs `legs` tall, extruded `w`.
    `holes` = (x_off, z_off, d) through-thickness holes on the base, relative
    to the base's top-face centre."""
    profile = [(0.0, 0.0), (0.0, legs), (t, legs), (t, t),
               (span - t, t), (span - t, legs), (span, legs), (span, 0.0)]
    part = fillet_bend_edges(solid_from_profile(profile, t, w, z0), bend_r, t)
    if holes:
        part = drill_on_face(part, (span / 2.0, t, w / 2.0),
                             [(x, z, d) for x, z, d in holes])
    return part


def hat_rib(length: float, top_w: float, base_w: float, h: float, t: float,
            bend_r: float = 2.0, z0: float = 0.0,
            holes: Sequence[Tuple[float, float, float]] = ()) -> cq.Workplane:
    """Hat-section rib: flat top, two angled webs, two base flanges.
    `holes` = (x_off, z_off, d) through-thickness holes on the flat top,
    relative to the top's face centre."""
    half_top = top_w / 2.0
    half_base = base_w / 2.0
    profile = [(-half_base - t, 0.0), (-half_top - t, h + t), (half_top + t, h + t),
               (half_base + t, 0.0), (half_base, 0.0), (half_top, h),
               (-half_top, h), (-half_base, 0.0)]
    part = fillet_bend_edges(solid_from_profile(profile, t, length, z0), bend_r, t)
    if holes:
        part = drill_on_face(part, (0.0, h + t, length / 2.0),
                             [(x, z, d) for x, z, d in holes])
    return part


def arc_bracket(radius: float, arc_deg: float, w: float, t: float,
                z0: float = 0.0, holes: Sequence[Tuple[float, float, float]] = ()) -> cq.Workplane:
    """Curved sheet bracket: sector of an annulus (radius, arc_deg) extruded
    `w` wide; arc centre at the origin.  `holes` are (angle_deg_from_0, d)
    placed on the mid-radius."""
    pts = []
    a0 = math.radians(90.0 - arc_deg / 2.0)
    a1 = math.radians(90.0 + arc_deg / 2.0)
    steps = max(8, int(arc_deg / 5.0))
    for i in range(steps + 1):
        ang = a0 + (a1 - a0) * i / steps
        pts.append((radius * math.cos(ang), radius * math.sin(ang)))
    for i in range(steps + 1):
        ang = a1 - (a1 - a0) * i / steps
        pts.append(((radius - t) * math.cos(ang), (radius - t) * math.sin(ang)))
    part = solid_from_profile(pts, t, w, z0)
    mid_r = radius - t / 2.0
    for (ang_deg, d) in holes:
        ang = math.radians(ang_deg)
        part = drill(part, [(mid_r * math.cos(ang), mid_r * math.sin(ang), d)])
    return part


def panel_with_ribs(w: float, h: float, t: float, rib_h: float, rib_w: float,
                    n_ribs: int, z0: float = 0.0,
                    holes: Sequence[Tuple[float, float, float]] = ()) -> cq.Workplane:
    """Flat plate with `n_ribs` longitudinal ribs on top (floor panel)."""
    part = flat_plate(w, h, t, z0)
    pitch = h / (n_ribs + 1)
    for i in range(1, n_ribs + 1):
        y = -h / 2.0 + i * pitch
        rib = cq.Workplane("XY").box(rib_w, t * 1.2, rib_h).translate(
            (0.0, y, z0 + t / 2.0 + rib_h / 2.0))
        part = part.union(rib)
    if holes:
        part = drill(part, [(x + w / 2.0, y + h / 2.0, d) for x, y, d in holes])
    return part


def stepped_bracket(segments: Sequence[Tuple[float, float, float]], w: float, t: float,
                    bend_r: float = 3.0, z0: float = 0.0,
                    holes: Sequence[Tuple[float, float, float]] = ()) -> cq.Workplane:
    """Multi-step sheet bracket: a monotone staircase cross-section (outer
    staircase minus its (-t,-t) offset), extruded `w` wide.

    `segments` = [(length, height_rise, bend_radius), ...]; every rise must
    be > 0.  The polygon is the standard shell construction: outer boundary
    CCW, inner boundary (offset by -t in both axes) CW."""
    if not segments or any(rise <= 0.0 for _ln, rise, _r in segments):
        raise ValueError("stepped_bracket requires strictly positive rises")
    xs: List[float] = []
    ys: List[float] = []
    x = y = 0.0
    for ln, rise, _r in segments:
        x += ln
        y += rise
        xs.append(x)
        ys.append(y)
    x_end, y_end = xs[-1], ys[-1]
    # outer staircase O (CCW)
    outer: List[Tuple[float, float]] = [(0.0, 0.0), (x_end, 0.0), (x_end, y_end)]
    for k in range(len(xs), 0, -1):
        outer.append((xs[k - 2] if k > 1 else 0.0, ys[k - 1]))
        if k > 1:
            outer.append((xs[k - 2], ys[k - 2]))
    # inner staircase I = O shifted by (-t, -t), traversed CW
    inner_cw = [(px - t, py - t) for px, py in reversed(outer)]
    profile = outer + inner_cw
    part = solid_from_profile(profile, t, w, z0)
    part = fillet_bend_edges(part, bend_r, t)
    if holes:
        part = drill(part, [(x + w / 2.0, y + t, d) for x, y, d in holes])
    return part


# ---------------------------------------------------------------------------
# Geometry-cleanup feature builders
# ---------------------------------------------------------------------------


def chamfer_block(w: float, h: float, t: float,
                  fillets: Sequence[Tuple[str, float]] = (),
                  chamfers: Sequence[Tuple[str, float]] = (),
                  holes: Sequence[Tuple[float, float, float]] = (),
                  z0: float = 0.0) -> cq.Workplane:
    """Box (cast-bracket blank) with selected edge fillets/chamfers and
    through holes.  Selectors are cadquery edge selectors like ('|Z', 2.0)."""
    part = cq.Workplane("XY").box(w, h, t).translate((0.0, 0.0, z0 + t / 2.0))
    for selector, r in chamfers:
        part = part.edges(selector).chamfer(r)
    for selector, r in fillets:
        part = part.edges(selector).fillet(r)
    if holes:
        part = drill(part, [(x + w / 2.0, y + h / 2.0, d) for x, y, d in holes])
    return part


def pocket_plate(w: float, h: float, t: float,
                 pockets: Sequence[Tuple[float, float, float, float, float]],
                 holes: Sequence[Tuple[float, float, float]] = (),
                 z0: float = 0.0) -> cq.Workplane:
    """Plate with counterbore pockets (x, y, hole_d, cb_d, cb_depth).
    Module rule: cb_depth < t/2 and cb_d > hole_d (shallow wide counterbore
    over a through hole)."""
    part = flat_plate(w, h, t, z0, holes=holes)
    for (x, y, hd, cbd, cbdepth) in pockets:
        part = cut_counterbore(part, x, y, hd, cbd, cbdepth, ">Z")
    return part


# ---------------------------------------------------------------------------
# Shell (open surface) builders -- seam_surface / batch_mesher inputs
# ---------------------------------------------------------------------------


def shell_face_from_profile(profile: Sequence[Tuple[float, float]],
                            holes: Sequence[Tuple[float, float, float]] = ()) -> cq.Workplane:
    """Open surface face from a closed XY profile, with optional circular
    holes.  Returns a Workplane wrapping the face."""
    wire = cq.Workplane("XY")
    for i, (x, y) in enumerate(profile):
        if i == 0:
            wire = wire.moveTo(x, y)
        else:
            wire = wire.lineTo(x, y)
    wire = wire.close().val()
    face = cq.Face.makeFromWires(wire)
    for (x, y, d) in holes:
        cyl = cq.Workplane("XY").circle(d / 2.0).extrude(1.0).translate((x, y, -0.5))
        face = face.cut(cyl.val())
    return cq.Workplane(obj=face)


def shell_rect(w: float, h: float, holes: Sequence[Tuple[float, float, float]] = ()) -> cq.Workplane:
    """Rectangular open surface face (centred at origin) with optional holes."""
    return shell_face_from_profile([(-w / 2.0, -h / 2.0), (w / 2.0, -h / 2.0),
                                    (w / 2.0, h / 2.0), (-w / 2.0, h / 2.0)], holes)


def shell_poly(pts: Sequence[Tuple[float, float]],
               holes: Sequence[Tuple[float, float, float]] = ()) -> cq.Workplane:
    """Open surface face from a general closed profile (L-shape, dog-leg,
    curved seam plates ...)."""
    return shell_face_from_profile(list(pts), holes)
