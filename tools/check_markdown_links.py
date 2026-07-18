"""Validate local Markdown links in tracked project documentation."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Tuple


ROOT = Path(__file__).resolve().parents[1]
LINK = re.compile(r"\[[^\]]+\]\(([^)]+)\)")


def markdown_files() -> Iterable[Path]:
    yield ROOT / "README.md"
    yield ROOT / "CHANGELOG.md"
    yield from sorted((ROOT / "doc").rglob("*.md"))


def broken_links() -> List[Tuple[Path, str]]:
    broken: List[Tuple[Path, str]] = []
    for document in markdown_files():
        text = document.read_text(encoding="utf-8")
        for raw_target in LINK.findall(text):
            target = raw_target.strip().strip("<>")
            if not target or target.startswith(("#", "http://", "https://", "mailto:")):
                continue
            target = target.split("#", 1)[0]
            resolved = (document.parent / target).resolve()
            if not resolved.exists():
                broken.append((document.relative_to(ROOT), raw_target))
    return broken


def main(argv: Optional[Sequence[str]] = None) -> int:
    broken = broken_links()
    for document, target in broken:
        print("{}: missing {}".format(document.as_posix(), target))
    return 1 if broken else 0


if __name__ == "__main__":
    raise SystemExit(main())
