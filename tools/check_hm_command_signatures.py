# Compare HyperMesh Tcl command call sites against the installed 2022 Help
# signatures, for every native command used in production (non-test) files.
#
# Usage: python tools/check_hm_command_signatures.py
#   --help-dir D:/Program Files/Altair/help/hwdesktop/hwd/topics/reference/hm
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TAG = re.compile(r"<[^>]+>")
WS = re.compile(r"\s+")


def strip_html(text: str) -> str:
    return WS.sub(" ", TAG.sub("", text)).strip()


def doc_signature(help_dir: Path, command: str) -> str | None:
    stem = command.lstrip("*")
    candidates = [f"_{stem}.htm", f"{stem}.htm", f"hm_{stem}.htm"]
    for name in candidates:
        page = help_dir / name
        if page.exists():
            text = page.read_text(encoding="utf-8", errors="replace")
            plain = strip_html(text)
            m = re.search(r"Syntax\b", plain)
            if not m:
                return None
            segment = plain[m.end():m.end() + 600]
            cut = segment.find("Type")
            if cut >= 0:
                segment = segment[:cut]
            return segment.strip()
    return None


def call_sites(root: Path, command: str) -> list[tuple[str, int, str]]:
    sites: list[tuple[str, int, str]] = []
    token = re.escape(command)
    pattern = re.compile(rf"(?<![\w*])(?:eval\s+)?{token}(?![A-Za-z0-9_])\s+(.*)$")
    for path in sorted(root.glob("modules/**/*.tcl")):
        rel = path.relative_to(root).as_posix()
        if "/tests/" in rel:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith("proc "):
                continue
            m = pattern.search(line)
            if m and "info commands" not in line and "string map" not in line:
                sites.append((rel, lineno, m.group(1).strip()[:90]))
    return sites


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--help-dir", required=True)
    parser.add_argument("--min-sites", type=int, default=0)
    args = parser.parse_args()
    help_dir = Path(args.help_dir)
    report = json.loads((ROOT / "tools" / "audit_hm_commands_report.json").read_text(encoding="utf-8"))

    print(f"{'command':<38} {'doc params':<14} call sites")
    print("-" * 110)
    for command in sorted(report["native"]):
        sites = call_sites(ROOT, command)
        if not sites or len(sites) < args.min_sites:
            continue
        sig = doc_signature(help_dir, command)
        doc_params = ""
        if sig:
            tokens = sig.split()
            doc_params = " ".join(tokens[1:]) if len(tokens) > 1 else "(no params)"
        print(f"{command:<38} {doc_params[:46]:<48}")
        for rel, lineno, args_text in sites[:4]:
            print(f"    {rel}:{lineno}: {args_text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
