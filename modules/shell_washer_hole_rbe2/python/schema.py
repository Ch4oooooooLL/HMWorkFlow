"""Shell washer request validation."""
from __future__ import annotations

from hybrid_schema import SchemaError, validate_request as validate_common

DEFAULTS = {
    "MIN_HOLE_DIAMETER": 6.0, "MAX_HOLE_DIAMETER": 30.0,
    "CIRCULARITY_TOL": 0.08, "ALLOW_OVAL_HOLES": True,
    "MAX_OVAL_AXIS_RATIO": 3.50, "OVAL_RADIAL_FIT_TOL": 0.45,
    "MIN_HOLE_EDGE_NODES": 8, "MAX_HOLE_EDGE_NODES": 200,
    "INNER_WASHER_NODE_LOOPS": 2, "OUTER_RING_CIRCULARITY_TOL": 0.20,
    "OUTER_OVAL_RADIAL_FIT_TOL": 0.55, "OUTER_OVAL_AXIS_RATIO_TOL": 0.45,
    "CENTER_OFFSET_TOL": 0.20, "MIN_WASHER_WIDTH_ABS": 0.30,
    "MIN_WASHER_WIDTH_RATIO": 0.05, "WASHER_ELEM_COUNT_TOL": 0.50,
    "MIN_OUTER_NODE_RATIO": 0.50, "MAX_OUTER_NODE_RATIO": 2.50,
}


def validate_request(data):
    data = validate_common(data, "shell_washer_hole_rbe2")
    settings = dict(DEFAULTS); settings.update(data["settings"])
    for key, default in DEFAULTS.items():
        if isinstance(default, bool): settings[key] = bool(settings[key])
        elif isinstance(default, int): settings[key] = int(settings[key])
        else: settings[key] = float(settings[key])
    if settings["MIN_HOLE_DIAMETER"] > settings["MAX_HOLE_DIAMETER"]:
        raise SchemaError("hole diameter range is reversed")
    data["settings"] = settings
    return data


def validate_existing(data):
    rows = data.get("rbe2", []) if isinstance(data, dict) else []
    if not isinstance(rows, list): raise SchemaError("existing_entities.rbe2 must be an array")
    return [{"element_id": int(row["element_id"]), "dependent_node_ids": sorted(int(v) for v in row.get("dependent_node_ids", []))} for row in rows]
