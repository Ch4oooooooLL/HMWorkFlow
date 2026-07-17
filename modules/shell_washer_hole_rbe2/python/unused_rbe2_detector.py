"""Find RBE2 elements whose independent node has no other element reference."""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from collections import defaultdict
from pathlib import Path


MODULE_DIR = Path(__file__).resolve().parent
COMMON_DIR = MODULE_DIR.parents[1] / "hybrid_core" / "python"
for directory in (str(MODULE_DIR), str(COMMON_DIR)):
    if directory not in sys.path:
        sys.path.insert(0, directory)

from hybrid_schema import new_result
from logging_utils import close_logger, create_logger
from result_writer import write_result


class FemConnectivityError(ValueError):
    pass


# Zero-based positions after card name. Variable-length families are handled
# separately below. These cover standard OptiStruct structural elements.
_NODE_POSITIONS = {
    "CROD": (3, 4), "CTUBE": (3, 4), "CBAR": (3, 4), "CBEAM": (3, 4),
    "CBUSH": (3, 4), "CBUSH1D": (3, 4), "CGAP": (3, 4), "CVISC": (3, 4),
    "CONROD": (2, 3), "PLOTEL": (2, 3),
    "CELAS1": (3, 5), "CELAS2": (3, 5), "CDAMP1": (3, 5),
    "CDAMP2": (3, 5), "CMASS1": (3, 5), "CMASS2": (3, 5),
    "CONM1": (2,), "CONM2": (2,),
    "RBAR": (2, 3), "RBAR1": (2, 3), "RROD": (2, 3),
}
_NODE_RANGES = {
    "CTRIA3": (3, 6), "CTRIA6": (3, 9), "CTRIAR": (3, 6),
    "CQUAD4": (3, 7), "CQUAD8": (3, 11), "CQUADR": (3, 7),
    "CSHEAR": (3, 7),
    "CTETRA": (3, 13), "CPYRA": (3, 11), "CPENTA": (3, 18),
    "CHEXA": (3, 23),
}


def _fields(raw: str):
    if "," in raw:
        return [item.strip() for item in raw.rstrip("\r\n").split(",")]
    line = raw.rstrip("\r\n")
    large = "*" in line[:8]
    width = 16 if large else 8
    return [line[:8].strip().rstrip("*")] + [
        line[index:index + width].strip() for index in range(8, len(line), width)
    ]


def _cards(path: Path):
    current = None
    current_line = 0
    with Path(path).open("r", encoding="utf-8-sig", errors="replace") as stream:
        for line_number, raw in enumerate(stream, 1):
            stripped = raw.strip()
            if not stripped or stripped.startswith("$") or stripped.upper() in {
                "BEGIN BULK", "BEGINBULK", "ENDDATA",
            }:
                continue
            fields = _fields(raw)
            marker = fields[0].strip()
            if marker in {"", "*", "+"} or marker.startswith("+"):
                if current is None:
                    raise FemConnectivityError(
                        "orphan continuation at line {}".format(line_number)
                    )
                current.extend(fields[1:])
                continue
            if current is not None:
                yield current_line, current
            current, current_line = fields, line_number
    if current is not None:
        yield current_line, current


def _positive_int(value):
    text = str(value).strip()
    if not re.fullmatch(r"[+]?[0-9]+", text):
        return None
    number = int(text)
    return number if number > 0 else None


def _rbe3_nodes(fields):
    nodes = []
    if len(fields) > 3:
        reference = _positive_int(fields[3])
        if reference is not None:
            nodes.append(reference)

    index = 5
    while index < len(fields):
        token = fields[index].strip().upper()
        if token == "ALPHA":
            break
        if token == "UM":
            index += 1
            while index + 1 < len(fields):
                if fields[index].strip().upper() == "ALPHA":
                    break
                node_id = _positive_int(fields[index])
                if node_id is not None:
                    nodes.append(node_id)
                index += 2
            break

        # Weight and component fields precede one or more grid IDs.
        index += 2
        while index < len(fields):
            token = fields[index].strip()
            upper = token.upper()
            if upper in {"UM", "ALPHA"}:
                break
            if any(character in token for character in ".EeDd"):
                break
            node_id = _positive_int(token)
            if node_id is not None:
                nodes.append(node_id)
            index += 1
    return nodes


def _element_nodes(card, fields, candidate_centers):
    if card == "RBE2":
        values = fields[2:3] + fields[4:]
        return [value for value in (_positive_int(item) for item in values) if value]
    if card == "RBE3":
        return _rbe3_nodes(fields)
    if card in _NODE_POSITIONS:
        return [
            value for value in (_positive_int(fields[index]) for index in _NODE_POSITIONS[card] if index < len(fields))
            if value
        ]
    if card in _NODE_RANGES:
        start, stop = _NODE_RANGES[card]
        return [
            value for value in (_positive_int(item) for item in fields[start:stop]) if value
        ]

    # Unknown C*/R* element families are handled conservatively. If a token
    # equals a candidate center, retain that RBE2 rather than risk deleting it.
    if card.startswith(("C", "R")):
        return [
            value for value in (_positive_int(item) for item in fields[2:])
            if value in candidate_centers
        ]
    return []


def analyze_fem(path: Path):
    path = Path(path)
    candidates = {}
    # Two streaming passes keep memory bounded for large full-model decks.
    # Pass one discovers the RBE2 center nodes; pass two indexes only references
    # to those centers instead of materializing every FEM card in memory.
    for line_number, fields in _cards(path):
        card = fields[0].upper().rstrip("*")
        if card != "RBE2":
            continue
        if len(fields) < 5:
            raise FemConnectivityError("RBE2 has too few fields at line {}".format(line_number))
        element_id = _positive_int(fields[1])
        center_id = _positive_int(fields[2])
        if element_id is None or center_id is None:
            raise FemConnectivityError("invalid RBE2 ID/GN at line {}".format(line_number))
        candidates[element_id] = center_id
    if not candidates:
        return {"rbe2_count": 0, "used_rbe2_count": 0, "unused_rbe2_ids": []}

    candidate_centers = set(candidates.values())
    references = defaultdict(set)
    for line_number, fields in _cards(path):
        card = fields[0].upper().rstrip("*")
        element_id = _positive_int(fields[1]) if len(fields) > 1 else None
        if element_id is None:
            continue
        for node_id in _element_nodes(card, fields, candidate_centers):
            if node_id in candidate_centers:
                references[node_id].add(element_id)

    unused = []
    for element_id, center_id in candidates.items():
        other_elements = references.get(center_id, set()) - {element_id}
        if not other_elements:
            unused.append(element_id)
    unused.sort()
    return {
        "rbe2_count": len(candidates),
        "used_rbe2_count": len(candidates) - len(unused),
        "unused_rbe2_ids": unused,
    }


def main(argv=None):
    parser = argparse.ArgumentParser()
    for name in ("request", "mesh", "output", "tcl-output", "log"):
        parser.add_argument("--" + name, required=True, type=Path)
    arguments = parser.parse_args(argv)
    logger = create_logger("shell_washer_unused_rbe2", arguments.log)
    try:
        request = json.loads(arguments.request.read_text(encoding="utf-8"))
        started = time.perf_counter()
        summary = analyze_fem(arguments.mesh)
        elapsed = time.perf_counter() - started
        result = new_result("shell_washer_hole_rbe2", request["run_id"])
        result["summary"] = summary
        result["performance"]["detect_seconds"] = round(elapsed, 6)
        write_result(
            arguments.output,
            getattr(arguments, "tcl_output"),
            "::RB2W::unusedRBE2PythonResult",
            result,
        )
        return 0
    except Exception as exc:
        logger.exception("unused RBE2 analysis failed")
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 2
    finally:
        close_logger(logger)


if __name__ == "__main__":
    raise SystemExit(main())
