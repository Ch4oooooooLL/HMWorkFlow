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
    "boundary_split_source_normal_change_deg": 45.0,
    "t_angle_auto_min_deg": 70.0,
    "t_angle_auto_max_deg": 100.0,
    "t_angle_review_min_deg": 65.0,
    "t_angle_review_max_deg": 115.0,
    "t_coverage_auto": 0.98,
    "geometry_abs_floor_mm": 0.5,
    "geometry_mesh_ratio_auto": 0.35,
    "geometry_thickness_ratio_auto": 0.15,
    "geometry_review_multiplier": 3.0,
    "t_tangential_tolerance_ratio": 0.10,
    "t_bevel_clearance_mm": 2.0,
    "t_bevel_source_thickness_ratio": 0.50,
    "t_bevel_mesh_ratio": 0.25,
    "t_target_min_support_ratio": 0.12,
    "t_edge_review_coverage": 0.67,
    "t_recall_angle_min_deg": 20.0,
    "t_recall_angle_max_deg": 90.0,
    "t_recall_distance_multiplier": 3.0,
    "t_recall_tangential_mesh_ratio": 1.0,
    "t_recall_edge_review_coverage": 0.01,
    "t_recall_min_coverage": 0.5,
    "ignore_shared_nodes": True,
    "min_continuous_nodes": 3,
    "patch_review_min_coverage": 0.25,
    "ambiguity_auto_min_score_margin": 0.40,
    "ambiguity_sample_ratio": 0.25,
    "curved_target_auto_max_normal_variation_deg": 12.0,
    "target_normal_jump_auto_max_deg": 30.0,
    "projection_jump_ratio": 2.5,
    "small_gap_auto_length_over_h": 0.25,
    "patch_inner_loop_policy": "auto_all",
    "review_multi_target_realization": False,
    # Field-validation phase: prefer creating locally plausible T seams and
    # let engineers identify the false positives for the next iteration.
    "t_recall_first_mode": True,
    "submit_all_weld_candidates": True,
}


def validate_request(data):
    data = validate_common(data, "fem_auto_seam")
    supplied_settings = set(data["settings"])
    settings = dict(DEFAULTS)
    settings.update(data["settings"])
    # The public UI exposes perpendicular_angle_min.  V2 used to leave its
    # private 80 degree default in place, so changing (or simply trusting) the
    # visible 70 degree rule had no effect on AUTO recognition.
    if "t_angle_auto_min_deg" not in supplied_settings:
        settings["t_angle_auto_min_deg"] = settings["perpendicular_angle_min"]
    # REVIEW is the relaxed envelope around AUTO.  These V2-only fields are
    # not exposed by the Tcl dialog, so they must follow the visible angle and
    # potential-angle-margin settings.  Otherwise a perfectly valid UI value
    # below the old hidden 65 degree default makes validation abort before
    # recognition starts (for example AUTO min=60, REVIEW min=65).
    if "t_angle_review_min_deg" not in supplied_settings:
        settings["t_angle_review_min_deg"] = max(
            0.0,
            float(settings["t_angle_auto_min_deg"]) - float(settings["potential_angle_margin"]),
        )
    if "t_angle_review_max_deg" not in supplied_settings:
        settings["t_angle_review_max_deg"] = min(
            180.0,
            float(settings["t_angle_auto_max_deg"]) + float(settings["potential_angle_margin"]),
        )
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
        "geometry_review_multiplier", "t_tangential_tolerance_ratio",
        "t_bevel_clearance_mm", "t_bevel_source_thickness_ratio", "t_bevel_mesh_ratio",
        "t_target_min_support_ratio",
        "t_edge_review_coverage", "t_recall_angle_min_deg", "t_recall_angle_max_deg",
        "t_recall_distance_multiplier", "t_recall_tangential_mesh_ratio",
        "t_recall_edge_review_coverage", "t_recall_min_coverage",
        "min_continuous_nodes",
        "patch_review_min_coverage", "ambiguity_auto_min_score_margin",
        "ambiguity_sample_ratio",
        "curved_target_auto_max_normal_variation_deg", "projection_jump_ratio",
        "small_gap_auto_length_over_h", "target_normal_jump_auto_max_deg",
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
    if settings["t_tangential_tolerance_ratio"] > 1.0:
        raise SchemaError("t_tangential_tolerance_ratio must not exceed 1")
    if settings["t_target_min_support_ratio"] > 1.0:
        raise SchemaError("t_target_min_support_ratio must not exceed 1")
    if settings["t_edge_review_coverage"] > 1.0:
        raise SchemaError("t_edge_review_coverage must not exceed 1")
    if settings["t_recall_edge_review_coverage"] > 1.0:
        raise SchemaError("t_recall_edge_review_coverage must not exceed 1")
    if settings["t_recall_min_coverage"] > 1.0:
        raise SchemaError("t_recall_min_coverage must not exceed 1")
    if settings["patch_review_min_coverage"] > 1.0:
        raise SchemaError("patch_review_min_coverage must not exceed 1")
    if settings["t_angle_auto_min_deg"] > settings["t_angle_auto_max_deg"]:
        raise SchemaError("T AUTO angle range is inverted")
    if settings["t_angle_review_min_deg"] > settings["t_angle_auto_min_deg"] or settings["t_angle_review_max_deg"] < settings["t_angle_auto_max_deg"]:
        raise SchemaError("T REVIEW angle range must contain the AUTO range")
    settings["patch_inner_loop_policy"] = str(settings.get("patch_inner_loop_policy", "auto_all")).lower()
    if settings["patch_inner_loop_policy"] not in ("ignore", "review", "auto_all"):
        raise SchemaError("patch_inner_loop_policy must be ignore, review, or auto_all")
    settings["review_multi_target_realization"] = bool(settings.get("review_multi_target_realization", False))
    settings["ignore_shared_nodes"] = bool(settings.get("ignore_shared_nodes", True))
    settings["min_continuous_nodes"] = int(settings.get("min_continuous_nodes", 3))
    if settings["min_continuous_nodes"] < 1:
        raise SchemaError("min_continuous_nodes must be at least 1")
    settings["t_recall_first_mode"] = bool(settings.get("t_recall_first_mode", True))
    settings["submit_all_weld_candidates"] = bool(settings.get("submit_all_weld_candidates", True))
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
