from __future__ import annotations

import re
import tkinter
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

    def test_version_and_solver_detection_are_advisory_only(self) -> None:
        source = (ROOT / "modules" / "workflow_common.tcl").read_text(
            encoding="utf-8"
        )
        preflight = source[
            source.index("proc ::HWFlow::engineeringPreflight") :
            source.index("proc ::HWFlow::formatEngineeringPreflight")
        ]
        self.assertIn(
            'preflightCheck solver WARNING "Expected $expected;', preflight
        )
        self.assertNotIn("preflightCheck solver BLOCKED", preflight)
        self.assertNotIn("hyperWorksCompatibility", preflight)
        self.assertIn("compatibility check is disabled", preflight)
        self.assertIn("informational only", preflight)

    def test_only_unwritable_task_storage_remains_blocking(self) -> None:
        source = (ROOT / "modules" / "workflow_common.tcl").read_text(
            encoding="utf-8"
        )
        preflight = source[
            source.index("proc ::HWFlow::engineeringPreflight") :
            source.index("proc ::HWFlow::formatEngineeringPreflight")
        ]
        self.assertEqual(preflight.count("preflightCheck units BLOCKED"), 0)
        self.assertEqual(preflight.count("preflightCheck solver BLOCKED"), 0)
        self.assertEqual(preflight.count("preflightCheck scratch BLOCKED"), 1)

    def test_inaccurate_hypermesh_context_does_not_block_launch(self) -> None:
        tcl = tkinter.Tcl()
        common = ROOT / "modules" / "workflow_common.tcl"
        tcl.eval(f"source -encoding utf-8 {{{common.as_posix()}}}")
        tcl.eval(
            r'''
            proc ::HWFlow::engineeringContext {{refresh 0}} {
                return [dict create unit_system "" solver_profile OptiStruct \
                    length_unit "" force_unit "" time_unit "" mass_unit "" \
                    stress_unit "" density_unit "" units_confirmed 0]
            }
            proc ::HWFlow::currentSolverContext {} {
                return [dict create profile unexpected_profile template unexpected_template]
            }
            proc ::HWFlow::hyperWorksVersion {} { return "unparseable-build-label" }
            set ::preflight_result [::HWFlow::requireEngineeringContext]
            '''
        )
        self.assertEqual(tcl.eval("dict get $::preflight_result status"), "WARNING")
        self.assertEqual(
            tcl.eval(
                "dict get [lindex [dict get $::preflight_result checks] 1] status"
            ),
            "WARNING",
        )
        self.assertEqual(
            tcl.eval(
                "dict get [lindex [dict get $::preflight_result checks] 2] status"
            ),
            "PASS",
        )

    def test_toolkit_and_material_mutations_use_preflight(self) -> None:
        toolkit = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        material = (ROOT / "modules" / "component_workflow.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn("::HWFlow::requireEngineeringContext", toolkit)
        self.assertIn("::HWFlow::requireEngineeringContext", material)


if __name__ == "__main__":
    unittest.main()
