"""Conservative joint classification and realization recommendation."""
from __future__ import annotations

try:
    from .geometry import angle_deg
except ImportError:  # Standalone HM2019 entry compatibility.
    from geometry import angle_deg

REALIZATION = {"T_JOINT": "PENTA_MIG_T", "LAP_JOINT": "PENTA_MIG_L", "BUTT_JOINT": "PENTA_MIG_B", "ANGLED_JOINT": "PENTA_MIG", "UNKNOWN": "PENTA_MIG"}


def classify(chain):
    source_normals = [normal for item in chain["items"] for normal in item.edge.face_normals]
    target_normals = [normal for item in chain["items"] for normal in item.target_normals]
    if not source_normals or not target_normals:
        return "UNKNOWN", REALIZATION["UNKNOWN"], 0.3
    angles = [min(angle_deg(source, target), 180.0 - angle_deg(source, target)) for source in source_normals for target in target_normals]
    closest = min(angles)
    perpendicular = min(abs(value - 90.0) for value in angles)
    boundary_ratio = sum(getattr(item, "target_boundary_ratio", 0.0) for item in chain["items"]) / len(chain["items"])
    if perpendicular <= 20.0:
        result, score = "T_JOINT", 0.95
    elif closest <= 20.0 and boundary_ratio >= 0.8:
        result, score = "BUTT_JOINT", 0.8
    elif closest <= 20.0:
        result, score = "LAP_JOINT", 0.85
    elif closest <= 40.0:
        result, score = "ANGLED_JOINT", 0.65
    else:
        result, score = "UNKNOWN", 0.4
    return result, REALIZATION[result], score
