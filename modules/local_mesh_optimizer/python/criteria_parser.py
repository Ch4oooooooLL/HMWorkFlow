"""Conservative criteria metadata parser.

This parser is for display/report metadata only. HyperMesh remains the final
quality authority.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, List, Optional


_LIMIT_NAMES = {
    "min length": "minimum_length",
    "max length": "maximum_length",
    "aspect ratio": "maximum_aspect_ratio",
    "warpage": "maximum_warpage",
    "max angle quad": "maximum_angle_quad",
    "min angle quad": "minimum_angle_quad",
    "max angle tria": "maximum_angle_tria",
    "min angle tria": "minimum_angle_tria",
    "skew": "maximum_skew",
    "jacobian": "minimum_jacobian",
}

_LIMIT_PATTERN = "|".join(
    re.escape(name).replace(r"\ ", r"\s+")
    for name in sorted(_LIMIT_NAMES, key=len, reverse=True)
)


def _enabled_failure_limit(line: str) -> Optional[tuple]:
    match = re.match(
        r"^\s*\d+\s+({})\s+([01])\s+\S+\s+(.+?)\s*$".format(_LIMIT_PATTERN),
        line,
        flags=re.IGNORECASE,
    )
    if match is None or match.group(2) != "1":
        return None
    values = match.group(3).split()
    # After On and Wt, the standard Criteria Editor columns are Ideal, Good,
    # Warn, Fail, Worst and optional Solver. Both supported criteria values
    # have all five quality columns, so index 3 is the native failure limit.
    if len(values) < 5:
        return None
    try:
        failure_limit = float(values[3])
    except ValueError:
        return None
    if failure_limit <= 0.0:
        return None
    normalized = " ".join(match.group(1).lower().split())
    return _LIMIT_NAMES[normalized], failure_limit


def parse_criteria_metadata(path: Path) -> Dict[str, object]:
    if not path.is_file():
        raise FileNotFoundError(str(path))
    size = path.stat().st_size
    if size <= 0:
        raise ValueError("Criteria file is empty")
    preview: List[str] = []
    quality_limits: Dict[str, float] = {}
    with path.open("r", encoding="utf-8-sig", errors="replace") as stream:
        for raw_line in stream:
            line = raw_line.strip()
            parsed_limit = _enabled_failure_limit(line)
            if parsed_limit is not None:
                quality_limits[parsed_limit[0]] = parsed_limit[1]
            if line and not line.startswith("#"):
                preview.append(line[:300])
    return {
        "path": str(path),
        "size_bytes": size,
        "preview": preview[:20],
        "quality_limits": quality_limits,
        "authority": "HyperMesh",
    }
