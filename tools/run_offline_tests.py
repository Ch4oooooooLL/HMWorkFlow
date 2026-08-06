"""Run every offline HMWorkFlow test suite in an isolated Python process."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import List, Sequence


ROOT = Path(__file__).resolve().parents[1]


def commands() -> List[Sequence[str]]:
    wrappers = [
        "modules/auto_hole_rbe2/tests/run_tests.py",
        "modules/batch_property_assignment/tests/run_tests.py",
        "modules/hybrid_core/tests/run_tests.py",
        "modules/mesh_seam_weld/tests/run_tests.py",
        "modules/fem_auto_seam/tests/run_tests.py",
        "modules/rbe2_bolt_connector/tests/run_tests.py",
        "modules/shell_washer_hole_rbe2/tests/run_tests.py",
    ]
    pytest_suites = [
        "modules/batch_mesher/tests",
        "modules/bom_material_assignment/tests",
        "modules/cbush_creator/tests",
        "modules/batch_temp_nodes/tests",
        "modules/contact_setup/tests",
        "modules/local_mesh_optimizer/tests",
        "modules/solid_seam/tests",
        "modules/weld_integrity_check/tests",
    ]
    result: List[Sequence[str]] = [
        [sys.executable, str(ROOT / wrapper)] for wrapper in wrappers
    ]
    result.extend(
        [sys.executable, "-m", "pytest", "-q", str(ROOT / suite)]
        for suite in pytest_suites
    )
    return result


def main() -> int:
    repository_audit = subprocess.run(
        [sys.executable, str(ROOT / "tools/repository_audit.py")], cwd=str(ROOT)
    )
    if repository_audit.returncode:
        return repository_audit.returncode
    link_check = subprocess.run(
        [sys.executable, str(ROOT / "tools/check_markdown_links.py")], cwd=str(ROOT)
    )
    if link_check.returncode:
        return link_check.returncode
    for command in commands():
        completed = subprocess.run(command, cwd=str(ROOT))
        if completed.returncode:
            return completed.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
