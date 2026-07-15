"""Module-specific request and existing-RBE2 validation."""
from __future__ import annotations

from typing import Any, Dict, List

from hybrid_schema import SchemaError, int_list, validate_request as validate_common_request


DEFAULTS = {
    "featureAngleDeg": 78.0,
    "loopNormalTolDeg": 35.0,
    "cylFitTol": 0.25,
    "loopRadiusTol": 0.35,
    "minWallNodes": 6,
    "minLoopNodes": 4,
    "minRadius": 0.0,
    "maxRadius": 0.0,
    "requireInnerNormal": False,
    "innerNormalMaxDot": -0.05,
    "eps": 1.0e-9,
}


def validate_request(data: Dict[str, Any]) -> Dict[str, Any]:
    data = validate_common_request(data, "auto_hole_rbe2")
    settings = dict(DEFAULTS)
    settings.update(data["settings"])
    for key in (
        "featureAngleDeg", "loopNormalTolDeg", "cylFitTol", "loopRadiusTol",
        "minRadius", "maxRadius", "innerNormalMaxDot", "eps",
    ):
        try:
            settings[key] = float(settings[key])
        except (TypeError, ValueError) as exc:
            raise SchemaError("request.settings.{} must be numeric".format(key)) from exc
    for key in ("minWallNodes", "minLoopNodes"):
        settings[key] = int(settings[key])
        if settings[key] < 3:
            raise SchemaError("request.settings.{} must be at least 3".format(key))
    settings["requireInnerNormal"] = bool(settings["requireInnerNormal"])
    if not 0.0 <= settings["featureAngleDeg"] <= 180.0:
        raise SchemaError("featureAngleDeg must be in [0, 180]")
    if settings["maxRadius"] > 0.0 and settings["maxRadius"] < settings["minRadius"]:
        raise SchemaError("maxRadius must not be smaller than minRadius")
    data["settings"] = settings
    return data


def validate_existing(data: Any) -> List[Dict[str, Any]]:
    if isinstance(data, dict):
        rows = data.get("rbe2", [])
    else:
        rows = data
    if not isinstance(rows, list):
        raise SchemaError("existing_entities.rbe2 must be an array")
    result = []
    for index, raw in enumerate(rows):
        if not isinstance(raw, dict):
            raise SchemaError("existing RBE2 {} must be an object".format(index))
        result.append({
            "element_id": int(raw["element_id"]),
            "independent_node_id": int(raw.get("independent_node_id", 0)),
            "dependent_node_ids": int_list(
                raw.get("dependent_node_ids", []),
                "existing_rbe2.dependent_node_ids",
            ),
            "component_id": int(raw.get("component_id", 0)),
        })
    return result
