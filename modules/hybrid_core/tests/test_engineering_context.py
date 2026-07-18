from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


class EngineeringContextContractTests(unittest.TestCase):
    def test_project_context_is_explicit_and_confirmed(self) -> None:
        text = (ROOT / "config.yaml").read_text(encoding="utf-8")
        expected = {
            "schema_version": "2.0",
            "unit_system": "mm_N_s_tonne",
            "solver_profile": "OptiStruct",
            "length_unit": "mm",
            "force_unit": "N",
            "time_unit": "s",
            "mass_unit": "tonne",
            "stress_unit": "MPa",
            "density_unit": "tonne_per_mm3",
            "units_confirmed": "true",
        }
        for key, value in expected.items():
            self.assertRegex(text, rf"(?m)^\s*{re.escape(key)}:\s*{re.escape(value)}\s*$")

    def test_preflight_has_pass_warning_and_blocked_contract(self) -> None:
        source = (ROOT / "modules" / "workflow_common.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn("proc ::HWFlow::engineeringPreflight", source)
        self.assertIn("proc ::HWFlow::requireEngineeringContext", source)
        self.assertIn("status BLOCKED", source)
        self.assertIn("status WARNING", source)
        self.assertIn("status PASS", source)
        self.assertIn("units_confirmed", source)
        self.assertIn("currentSolverContext", source)

    def test_toolkit_and_material_mutations_use_preflight(self) -> None:
        toolkit = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        material = (ROOT / "modules" / "component_workflow.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn("::HWFlow::requireEngineeringContext", toolkit)
        self.assertIn("::HWFlow::requireEngineeringContext", material)


if __name__ == "__main__":
    unittest.main()
