"""Recognize hole loops and validate washer layers."""
from __future__ import annotations

from geometry import distance
from loop_geometry import calculate
from shell_topology import expand_layers


def validate_hole(model, loop, settings):
    if not loop["closed"] or loop.get("branched"): return None, "OPEN_OR_BRANCHED"
    count = len(loop["nodes"])
    if count < settings["MIN_HOLE_EDGE_NODES"]: return None, "TOO_FEW_EDGE_NODES"
    if count > settings["MAX_HOLE_EDGE_NODES"]: return None, "TOO_MANY_EDGE_NODES"
    geom = calculate(model, loop["nodes"]); diameter = 2.0 * geom["mean_radius"]
    if not settings["MIN_HOLE_DIAMETER"] <= diameter <= settings["MAX_HOLE_DIAMETER"]: return None, "DIAMETER_RANGE"
    if geom["radial_rel"] <= settings["CIRCULARITY_TOL"] and geom["axis_ratio"] <= 1.0 + 3.0 * settings["CIRCULARITY_TOL"]:
        geom["shape"] = "circular"
    elif settings["ALLOW_OVAL_HOLES"] and geom["axis_ratio"] <= settings["MAX_OVAL_AXIS_RATIO"] and geom["radial_rel"] <= settings["OVAL_RADIAL_FIT_TOL"]:
        geom["shape"] = "oval"
    else: return None, "NOT_CIRCULAR_OR_OVAL"
    return geom, ""


def validate_washer(model, loop, geom, incidence, neighbors, element_nodes, settings):
    loop_edges = {tuple(sorted(edge)) for edge in loop["edges"]}
    seeds = sorted({incidence[edge][0] for edge in loop_edges if edge in incidence and len(incidence[edge]) == 1})
    minimum = max(1, int(len(loop_edges) * (1.0 - settings["WASHER_ELEM_COUNT_TOL"])))
    if len(seeds) < minimum: return None, "INCOMPLETE_FIRST_WASHER_RING"
    tie_elements = expand_layers(seeds, neighbors, settings["INNER_WASHER_NODE_LOOPS"] - 1)
    dependent = sorted({node for element in tie_elements for node in element_nodes[element]})
    outer = sorted(set(dependent) - set(loop["nodes"]))
    if len(outer) < settings["MIN_HOLE_EDGE_NODES"]: return None, "NO_VALID_OUTER_LOOP"
    outer_ratio = len(outer) / float(len(loop["nodes"]))
    if not settings["MIN_OUTER_NODE_RATIO"] <= outer_ratio <= settings["MAX_OUTER_NODE_RATIO"]: return None, "OUTER_NODE_COUNT"
    outer_geom = calculate(model, outer)
    width_ok = outer_geom["mean_radius"] > geom["mean_radius"] + settings["MIN_WASHER_WIDTH_ABS"] or outer_geom["mean_radius"] > geom["mean_radius"] * (1.0 + settings["MIN_WASHER_WIDTH_RATIO"])
    if not width_ok: return None, "WASHER_WIDTH"
    if geom["shape"] == "oval":
        if outer_geom["min_radius"] <= geom["min_radius"] or outer_geom["max_radius"] <= geom["max_radius"]: return None, "OVAL_NOT_OUTSIDE"
        if outer_geom["radial_rel"] > settings["OUTER_OVAL_RADIAL_FIT_TOL"]: return None, "OUTER_OVAL_IRREGULAR"
        axis_dev = abs(outer_geom["axis_ratio"] - geom["axis_ratio"]) / geom["axis_ratio"]
        if axis_dev > settings["OUTER_OVAL_AXIS_RATIO_TOL"]: return None, "OUTER_OVAL_AXIS_MISMATCH"
    elif outer_geom["radial_rel"] > settings["OUTER_RING_CIRCULARITY_TOL"]: return None, "OUTER_RING_IRREGULAR"
    if distance(geom["center"], outer_geom["center"]) / geom["mean_radius"] > settings["CENTER_OFFSET_TOL"]: return None, "CENTER_OFFSET"
    return {"seed_element_ids": seeds, "dependent_node_ids": dependent, "washer_element_ids": tie_elements, "outer_node_ids": outer, "outer_geometry": outer_geom}, ""
