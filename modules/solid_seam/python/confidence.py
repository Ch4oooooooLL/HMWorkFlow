"""Confidence calculation with explicit sub-scores."""
from __future__ import annotations


def calculate(chain, settings, joint_score, unique_score=1.0, duplicate_score=1.0):
    average = sum(item.average_distance * item.edge.length for item in chain["items"]) / max(chain["length"], 1.0e-9)
    maximum = max(item.maximum_distance for item in chain["items"])
    ratio = sum(item.valid_ratio * item.edge.length for item in chain["items"]) / max(chain["length"], 1.0e-9)
    distance_score = max(0.0, 1.0 - 0.5 * average / float(settings["search_distance"]) - 0.5 * maximum / float(settings["max_search_distance"]))
    continuity = 0.65 if "BRANCH_POINT" in chain["warnings"] else 1.0
    score = 0.25 * distance_score + 0.25 * ratio + 0.18 * continuity + 0.14 * joint_score + 0.08 * unique_score + 0.10 * duplicate_score
    score = max(0.0, min(1.0, score))
    high = float(settings["high_confidence_threshold"])
    review = float(settings["review_confidence_threshold"])
    level = "HIGH" if score >= high else "REVIEW" if score >= review else "LOW"
    return score, level, average, maximum, ratio
