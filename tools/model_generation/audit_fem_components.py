#!/usr/bin/env python3
"""audit_fem_components.py -- verify every generated .fem groups ALL elements
into named components on HyperMesh import.

Two failure modes are caught:
  1. elements outside any $HMCOMP ID section -> HyperMesh puts them in misc;
  2. an element's property id differs from the id of a defined component ->
     HyperMesh links a property to the component of the SAME id on .fem
     import, so a mismatched property lands in misc and drags every element
     that references it along (this was the reported "all elements in misc").

Usage: python tools/model_generation/audit_fem_components.py [root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common

ELEM_RE = re.compile(r"^(CQUAD4|CQUAD8|CTRIA3|CTRIA6|CHEXA|CPENTA|CTETRA|CTETRA10|"
                     r"RBE2|RBE3|CBEAM|CBAR|CBUSH|CROD|CONM2|CELAS2|SPRING),(.*)$")
HMCOMP_RE = re.compile(r"^\$HMCOMP ID (\d+)\s*$")
HMCNAME_RE = re.compile(r'^\$HMNAME COMP (\d+) "(.*)"\s*$')
PROP_RE = re.compile(r"^(PSHELL|PSOLID|PBAR|PBUSH|PBEAM|PROD),(\d+),")

# cards that carry a property id in field 2
PID_CARDS = ("CQUAD4", "CQUAD8", "CTRIA3", "CTRIA6", "CHEXA", "CPENTA", "CTETRA",
             "CTETRA10", "CBEAM", "CBAR", "CBUSH", "CROD", "CONM2")


def audit_fem(path: Path) -> dict:
    lines = path.read_text(encoding="utf-8").splitlines()
    section = None
    sections = {}
    outside = []
    comp_names = {}
    prop_names = {}
    pids_used = set()
    errors = []
    for lineno, line in enumerate(lines, 1):
        m = HMCOMP_RE.match(line)
        if m:
            section = m.group(1)
            sections.setdefault(section, 0)
            continue
        m = HMCNAME_RE.match(line)
        if m:
            comp_names[m.group(1)] = m.group(2)
            continue
        m = PROP_RE.match(line)
        if m:
            prop_names.setdefault(m.group(2), []).append(m.group(1))
            continue
        m = ELEM_RE.match(line)
        if m:
            card = m.group(1)
            if section is None:
                outside.append((lineno, card))
            else:
                sections[section] += 1
            if card in PID_CARDS:
                try:
                    pid = int(line.split(",")[2])
                    pids_used.add(pid)
                except (IndexError, ValueError):
                    errors.append("line {}: bad {} card".format(lineno, card))
    # rule 1: every element-bearing component must have a $HMCOMP ID section
    for cid in comp_names:
        if cid not in sections:
            errors.append("component {} ({}) has NO $HMCOMP ID section".format(cid, comp_names[cid]))
    # rule 2: every used property id must belong to a defined component
    # (HyperMesh: property <-> component of the same id)
    for pid in sorted(pids_used):
        if str(pid) not in comp_names:
            errors.append("element property id {} has no component with the same id".format(pid))
    # rule 3: no element may reference a property that was not defined
    for pid in sorted(pids_used):
        if str(pid) not in prop_names:
            errors.append("element property id {} has no $HMNAME PROP definition".format(pid))
    return {
        "path": str(path),
        "element_count": sum(sections.values()) + len(outside),
        "sectioned": sum(sections.values()),
        "outside_any_section": len(outside),
        "sections": sections,
        "components": comp_names,
        "pids_used": sorted(pids_used),
        "errors": errors,
    }


def main() -> int:
    roots = [p for p in sys.argv[1:]] or [str(common.output_root())]
    total_errors = 0
    fem_files = []
    for root in roots:
        fem_files.extend(sorted(Path(root).rglob("*.fem")))
    legacy = common.REPO_ROOT / "examples" / "WasherHoleRBE2_Validation" / "WasherHoleRBE2_Validation.fem"
    if legacy.exists():
        fem_files.insert(0, legacy)

    for path in fem_files:
        report = audit_fem(path)
        status = "OK "
        if report["outside_any_section"] or report["errors"]:
            status = "BAD"
            total_errors += 1
            for e in report["errors"][:10]:
                print("  [{}] {}".format(path.name, e))
        print("{:<46} elems={:<7} sectioned={:<7} outside={:<5} pids={:<4} {}".format(
            path.name, report["element_count"], report["sectioned"],
            report["outside_any_section"], len(report["pids_used"]), status))
    print("\n{} fem files audited, {} bad".format(len(fem_files), total_errors))
    return 1 if total_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
