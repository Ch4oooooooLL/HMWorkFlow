"""Validate generated candidate payloads before they cross back into Tcl."""
try:
    from .schema import validate_candidate
except ImportError:  # Standalone HM2019 entry compatibility.
    from schema import validate_candidate


def validate_results(candidates, model):
    seen = set()
    for candidate in candidates:
        identifier = candidate.get("candidate_id")
        if not identifier or identifier in seen:
            raise ValueError("candidate IDs must be unique and non-empty")
        seen.add(identifier)
        validate_candidate(candidate, model.nodes, model.components)
