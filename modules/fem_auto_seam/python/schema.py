from __future__ import annotations

try:
    from hmworkflow.core.hybrid_schema import SchemaError, validate_request as validate_common
except ImportError:
    from hybrid_schema import SchemaError, validate_request as validate_common

DEFAULTS = {
    "mode": "detect",
    "search_distance": 12.0,
    "min_seam_length": 20.0,
    "parallel_angle_max": 15.0,
    "perpendicular_angle_min": 70.0,
    "max_distance_variation_ratio": 0.35,
    "near_edge_distance": 8.0,
    "small_hole_diameter": 30.0,
    "max_weld_tria_ratio": 0.75,
    "max_new_failed_elements": 0,
    "existing_weld_search_distance": 4.0,
    "auto_accept_confidence": 0.88,
    "review_confidence": 0.60,
    "criteria_path": "",
    "remesh_element_size": 8.0,
    "remesh_expand_layers": 2,
    "remesh_feature_angle": 30.0,
    "python_workers": 0,
}


def validate_request(data):
    data = validate_common(data, "fem_auto_seam")
    settings = dict(DEFAULTS)
    settings.update(data["settings"])
    settings["mode"] = str(settings["mode"]).lower()
    if settings["mode"] not in ("detect", "plan"):
        raise SchemaError("unsupported FEM automatic seam mode")
    for key in (
        "search_distance", "min_seam_length", "parallel_angle_max",
        "perpendicular_angle_min", "max_distance_variation_ratio",
        "near_edge_distance", "small_hole_diameter", "max_weld_tria_ratio",
        "existing_weld_search_distance", "auto_accept_confidence", "review_confidence",
    ):
        settings[key] = float(settings[key])
        if settings[key] < 0.0:
            raise SchemaError("{} must not be negative".format(key))
    for key in ("max_new_failed_elements", "remesh_expand_layers", "python_workers"):
        settings[key] = int(settings[key])
        if settings[key] < 0:
            raise SchemaError("{} must not be negative".format(key))
    settings["criteria_path"] = str(settings.get("criteria_path", "")).strip()
    for key in ("remesh_element_size", "remesh_feature_angle"):
        settings[key] = float(settings[key])
        if settings[key] <= 0.0:
            raise SchemaError("{} must be positive".format(key))
    data["settings"] = settings
    return data
