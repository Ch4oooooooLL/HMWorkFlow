"""Conservative criteria metadata parser.

This parser is for display/report metadata only. HyperMesh remains the final
quality authority.
"""

from __future__ import annotations

from pathlib import Path
from typing import Dict, List


def parse_criteria_metadata(path: Path) -> Dict[str, object]:
    if not path.is_file():
        raise FileNotFoundError(str(path))
    size = path.stat().st_size
    if size <= 0:
        raise ValueError("Criteria file is empty")
    preview: List[str] = []
    with path.open("r", encoding="utf-8-sig", errors="replace") as stream:
        for raw_line in stream:
            line = raw_line.strip()
            if line and not line.startswith("#"):
                preview.append(line[:300])
            if len(preview) >= 20:
                break
    return {"path": str(path), "size_bytes": size, "preview": preview, "authority": "HyperMesh"}
