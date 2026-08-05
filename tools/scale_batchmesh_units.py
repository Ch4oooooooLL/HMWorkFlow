"""Scale length-valued fields in HyperMesh BatchMesh criteria/param files."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


PARAM_LENGTH_KEYS = {
    "element_size",
    "max_fillet_radius",
    "minimal_beads_height",
    "flange_max_width",
    "flange_min_width",
    "flange_max_remove_width",
    "max_thickness",
    "defeat_open_width",
    "supp_proxim_edges",
    "combine_nonmanifold",
    "defeature_ribs_width",
    "midmesh_extract_elem_size",
    "logo_max_size",
    "logo_max_height",
    "logo_min_concavity",
    "threads_toremove_max_depth",
    "move_normal_dist",
}


def scaled_number(text: str, factor: float) -> str:
    value = float(text)
    if value < 0:  # Preserve BatchMesher sentinel values such as -1.
        return text
    return format(value * factor, ".12g")


def scale_criteria_line(line: str, factor: float) -> str:
    patterns = (
        r"^(\s*(?:1 min length|2 max length|11 chordal dev)\s+\d+\s+\S+\s+)(\S+)(\s+)(\S+)(\s+)(\S+)(\s+)(\S+)(\s+)(\S+)(.*)$",
        r"^(\s*\d+\s+\{(?:Min Size|Max Size)\}\s+\d+\s+\S+\s+)(\S+)(\s+)(\S+)(\s+)(\S+)(\s+)(\S+)(\s+)(\S+)(.*)$",
    )
    for pattern in patterns:
        match = re.match(pattern, line)
        if not match:
            continue
        groups = list(match.groups())
        for index in (1, 3, 5, 7, 9):
            groups[index] = scaled_number(groups[index], factor)
        return "".join(groups)
    return line


def scale_function_arguments(line: str, name: str, factor: float) -> str:
    pattern = re.compile(rf"{re.escape(name)}\(([^)]*)\)")

    def replace(match: re.Match[str]) -> str:
        values = match.group(1).split(",")
        try:
            scaled = ",".join(scaled_number(value.strip(), factor) for value in values)
        except ValueError:
            return match.group(0)
        return f"{name}({scaled})"

    return pattern.sub(replace, line)


def scale_param_line(line: str, factor: float) -> str:
    stripped = line.lstrip()
    if not stripped or stripped.startswith("#"):
        return line
    key_match = re.match(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s+)(\S+)(.*)$", line)
    if key_match and key_match.group(2) in PARAM_LENGTH_KEYS:
        try:
            value = scaled_number(key_match.group(4), factor)
        except ValueError:
            pass
        else:
            return "".join((*key_match.groups()[:3], value, key_match.group(5)))
    line = scale_function_arguments(line, "rad", factor)
    line = scale_function_arguments(line, "flanged_suppr_height", factor)
    return scale_function_arguments(line, "chordal_deviation", factor)


def transform(path: Path, output: Path, factor: float, kind: str) -> None:
    transform_line = scale_criteria_line if kind == "criteria" else scale_param_line
    lines = path.read_text(encoding="utf-8").splitlines()
    output.write_text(
        "\n".join(transform_line(line, factor) for line in lines) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--criteria", type=Path, required=True)
    parser.add_argument("--param", type=Path, required=True)
    parser.add_argument("--output-criteria", type=Path, required=True)
    parser.add_argument("--output-param", type=Path, required=True)
    parser.add_argument("--factor", type=float, required=True)
    args = parser.parse_args()
    if args.factor <= 0:
        parser.error("--factor must be positive")
    transform(args.criteria, args.output_criteria, args.factor, "criteria")
    transform(args.param, args.output_param, args.factor, "param")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
