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
    "potential_search_multiplier": 1.25,
    "potential_angle_margin": 10.0,
    "potential_length_ratio": 0.75,
    "boundary_split_turn_angle_deg": 30.0,
    "boundary_split_source_normal_change_deg": 20.0,
    "t_angle_auto_min_deg": 80.0,
    "t_angle_auto_max_deg": 100.0,
    "t_angle_review_min_deg": 65.0,
    "t_angle_review_max_deg": 115.0,
    "t_coverage_auto": 0.98,
    "geometry_abs_floor_mm": 0.5,
    "geometry_mesh_ratio_auto": 0.35,
    "geometry_thickness_ratio_auto": 0.15,
    "geometry_review_multiplier": 3.0,
    "ambiguity_auto_min_score_margin": 0.50,
    "ambiguity_sample_ratio": 0.25,
    "curved_target_auto_max_normal_variation_deg": 12.0,
    "projection_jump_ratio": 2.5,
    "small_gap_auto_length_over_h": 0.25,
    "patch_inner_loop_policy": "review",
    "review_multi_target_realization": False,
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
        "potential_search_multiplier", "potential_angle_margin", "potential_length_ratio",
        "boundary_split_turn_angle_deg", "boundary_split_source_normal_change_deg",
        "t_angle_auto_min_deg", "t_angle_auto_max_deg", "t_angle_review_min_deg",
        "t_angle_review_max_deg", "t_coverage_auto", "geometry_abs_floor_mm",
        "geometry_mesh_ratio_auto", "geometry_thickness_ratio_auto",
        "geometry_review_multiplier", "ambiguity_auto_min_score_margin",
        "ambiguity_sample_ratio",
        "curved_target_auto_max_normal_variation_deg", "projection_jump_ratio",
        "small_gap_auto_length_over_h",
    ):
        settings[key] = float(settings[key])
        if settings[key] < 0.0:
            raise SchemaError("{} must not be negative".format(key))
    if settings["potential_search_multiplier"] < 1.0:
        raise SchemaError("potential_search_multiplier must be at least 1")
    if settings["potential_length_ratio"] > 1.0:
        raise SchemaError("potential_length_ratio must not exceed 1")
    if settings["t_coverage_auto"] > 1.0:
        raise SchemaError("t_coverage_auto must not exceed 1")
    if settings["t_angle_auto_min_deg"] > settings["t_angle_auto_max_deg"]:
        raise SchemaError("T AUTO angle range is inverted")
    if settings["t_angle_review_min_deg"] > settings["t_angle_auto_min_deg"] or settings["t_angle_review_max_deg"] < settings["t_angle_auto_max_deg"]:
        raise SchemaError("T REVIEW angle range must contain the AUTO range")
    settings["patch_inner_loop_policy"] = str(settings.get("patch_inner_loop_policy", "review")).lower()
    if settings["patch_inner_loop_policy"] not in ("ignore", "review", "auto_all"):
        raise SchemaError("patch_inner_loop_policy must be ignore, review, or auto_all")
    settings["review_multi_target_realization"] = bool(settings.get("review_multi_target_realization", False))
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
